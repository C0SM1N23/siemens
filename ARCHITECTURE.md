# How this CPU works — module by module, and the data flow

A guide for learning the design, not just using it. Read top to bottom the
first time; afterwards each section stands on its own. Tag references
(`REQ#`, `D#`) point to the requirement/decision index in the README.

---

## 1. The big picture

This is an RV32I processor with a 3-stage pipeline. It talks to the rest of
the SoC through two AXI4-Lite master buses (one for instructions, one for
data) and to an interrupt controller (PIC) through four dedicated signals.
The PIC itself lives in this repo too (`hdl/pic.v`): every peripheral brief
points its interrupt line at a "system interrupt controller", but no brief
assigns building one — so the CPU block ships it (section 6 covers how it
works).

```
             ┌─────────────────────── cpu_top ───────────────────────┐
             │                                                       │
  ibus_axi   │  ┌────────────┐   ┌─────────────────────┐   ┌──────┐  │
 ◄──────────►│  │ fetch_unit │──►│  IF/DX pipeline reg  │──►│      │  │
 (AR/R only) │  │  PC + AXI  │   └─────────────────────┘   │  S2  │  │
             │  └─────▲──────┘                             │      │  │
             │        │ predict                            │decode│  │
             │  ┌─────┴──────┐        redirect / stall     │ exec │  │
             │  │ branch_    │◄──────────┬─────────────────│ CSR  │  │
             │  │ predictor  │           │                 │ trap │  │
             │  └────────────┘    ┌──────┴─────┐           └──┬───┘  │
             │                    │ hazard_unit│              │      │
  dbus_axi   │  ┌────────────┐    └────────────┘   ┌──────────▼───┐  │
 ◄──────────►│  │    lsu     │◄────────────────────│ DX/WB reg    │  │
 (full R/W)  │  │ AXI master │     load/store      └──────┬───────┘  │
             │  └────────────┘                            │ S3       │
             │                                     ┌──────▼───────┐  │
  cpu_irq ──►│                                     │ writeback →  │  │
  cpu_irq_id►│                                     │ regfile      │  │
  ◄─ irq_ack │                                     └──────────────┘  │
  ◄─ in_trap └───────────────────────────────────────────────────────┘
```

The three stages (REQ1):

| Stage | Name | What happens there |
|-------|------|--------------------|
| S1 | Fetch | Read the instruction word over `ibus_axi`; predict the next PC |
| S2 | Decode + Execute | Decode, read registers, ALU, branch resolve, CSR access, load/store over `dbus_axi`, all trap/interrupt decisions |
| S3 | Writeback | Write the result into the register file |

Almost everything interesting happens in S2 — that's deliberate. With one
stage doing decode+execute+memory, every instruction resolves completely
before the next one commits, which is what makes the traps *precise* (an
instruction either fully happens or fully doesn't).

---

## 2. Life of an instruction

### A plain ALU op (`add x3, x1, x2`)

```
cycle 1  S1: AR handshake on ibus with the PC; R beat returns the word
cycle 2  S2: decode → read x1,x2 → ALU adds → result into DX/WB
cycle 3  S3: DX/WB.result written into x3
```
One instruction enters S2 per cycle, so throughput is 1 instruction/cycle
(CPI = 1.00, measured by the testbench) as long as nothing stalls.

### A load (`lw x5, 8(x2)`)

```
cycle 1  S2: ALU computes x2+8 → alignment checked → lsu issues AR on dbus
cycle 2+ S2: pipeline STALLED (REQ5) — lsu waits for the R beat
cycle n  S2: R beat arrives → byte-lane extract → instruction leaves S2
cycle n+1 S3: loaded value written into x5
```
While S2 waits, S1 may quietly finish its own fetch and park it in the
holding register (the two buses are independent, D6) — but nothing enters
or leaves S2 until the data response lands.

### A taken branch, predicted correctly

```
cycle 1  S1: fetch the branch; BTB hit says "taken, target T" → next fetch
             starts at T immediately
cycle 2  S2: branch resolves; prediction was right → no flush, no bubble
```
Zero cost. On a mispredict, S2 redirects the fetch and throws away the one
wrong-path instruction sitting in S1 — exactly one lost cycle.

---

## 3. Module guide

### cpu_top.v — the assembly of everything
Owns the two pipeline registers, wires all blocks together and makes the
three decisions that need a global view, in this priority order (D2):

1. **Interrupt?** Checked at the instruction boundary, before the
   instruction is allowed to issue any data transaction. If taken, the
   instruction in S2 is squashed and will re-run after MRET.
2. **Synchronous exception?** From `exception_unit` — if yes, squash and
   jump to the handler.
3. **Mispredict?** Compare what the predictor claimed (carried in IF/DX)
   with what `branch_unit` actually computed; on mismatch redirect fetch.

The pipeline registers each split into a *valid* bit (reset, drives all the
gating) and a *payload* (no reset — it is never believed when valid=0, D1).

### fetch_unit.v — S1, the instruction AXI master
A small machine around three questions:

- **What to fetch next?** Ask the predictor: BTB hit & taken → stored
  target; otherwise PC+4. On a redirect from S2, that address wins instead.
- **When to fetch?** Whenever its single transaction slot is free and the
  result will have somewhere to go. Back-to-back: the next ARVALID rises in
  the same cycle the current R beat is accepted (D6), which is what
  sustains 1 fetch/cycle on a fast memory.
- **What if S2 can't take it?** The finished word parks in a one-entry
  *holding register* and no new fetch starts (D7) — S1 never runs ahead.

One AXI subtlety lives here: an in-flight read cannot be cancelled. On a
redirect the unit sets a `discard` flag, politely accepts the stale beat
when it arrives, drops it, and only then fetches from the new address.
Fetch bus errors don't act here either — the word is delivered with a
`fetch_fault` tag and becomes a trap only if it actually reaches S2 (D8);
wrong-path fetch errors just get flushed.

### branch_predictor.v — BHT + BTB in one table
128 direct-mapped entries (D9), each: `valid`, `tag` (PC[31:9]), one
direction bit = last outcome (REQ8), and the 32-bit target. The stored
target is the whole point: at fetch time the immediate isn't decoded yet,
so a direction bit alone couldn't redirect anything. Misses predict
not-taken (D10). Entries are written only when a branch/jump actually
commits in S2 (D11) — never speculatively — and survive traps.

### decode.v / imm_gen.v / control.v — instruction cracking
`decode` slices the fixed RV32I fields (opcode/rd/rs1/rs2/funct3/funct7).
`imm_gen` rebuilds the immediate for each of the five encoding formats.
`control` (REQ7) turns the opcode into the set of control lines the rest of
S2 consumes — and polices legality: any unknown opcode or bad funct field
raises `illegal` while forcing every other control line inactive, so an
illegal instruction can't have side effects (it traps instead). FENCE
decodes to a NOP: one hart, in-order, blocking memory — there is nothing to
order.

### regfile.v — the architectural registers (REQ10)
32×32 bits, x0 hardwired to zero, two combinational read ports used by S2,
one write port driven by S3.

### The forwarding path (in cpu_top + hazard_unit)
S2 reads the regfile combinationally, but the instruction one step ahead
(in S3) hasn't written its result yet. If S3's destination matches one of
S2's sources, the S3 result is *bypassed* directly into the operand mux
(D13). That single bypass removes the classic load-use stall entirely,
because a load's data is already in S3 by the time any consumer sits in S2.

### alu.v / alu_top.v / branch_unit.v — the execute datapath
`alu_top` picks operands (register vs immediate; PC for AUIPC) and derives
the ALU opcode from funct3/funct7; `alu` does the arithmetic. `branch_unit`
computes the *real* direction and target of any control transfer — that
truth is compared against the prediction, feeds the predictor's learning
port, and (for JALR) masks bit 0 of the target as the ISA requires.

### csr_file.v — machine-mode state (REQ9)
The seven required CSRs plus read-only `mcycle`/`minstret`/`mhartid` (D5).
Reads are combinational; software writes commit at the end of S2. Two
hardware sequences override software:

- **Trap entry**: `mepc ← return address`, `mcause ← cause`,
  `MPIE ← MIE`, `MIE ← 0` — all in one edge, so the state can never be
  half-updated.
- **MRET**: `MIE ← MPIE`, `MPIE ← 1`.

Each CSR sits in its own always block; `mstatus.MIE/MPIE` stay paired
because they swap as a unit. Accessing a CSR that doesn't exist, or writing
a read-only one, is an illegal-instruction trap (D15) — CSRs are inside the
core, so a bus error code would be the wrong abstraction. `mtvec` supports
vectored mode (D16): interrupts land at `BASE + 4×cause`, exceptions at
`BASE`.

### exception_unit.v — the synchronous trap causes (D3)
Watches the instruction in S2 and raises exactly one cause through a
priority chain: fetch fault, illegal, EBREAK, ECALL, misaligned jump
target, misaligned load/store, load/store bus fault. Misalignment is
checked *before* the access, so a bad address never even reaches the bus
(D17); bus errors are checked *after* the response and become access
faults, not "illegal instruction" (D18).

### lsu.v — S2's data AXI master
Gets a command only when the op is legal, aligned and not squashed. Latches
address and write data in the first cycle (the forwarded operands are only
valid then, and AXI wants them stable anyway — D12), issues AR (load) or
AW+W (store), and holds `busy` until the response beat. Store data is
replicated across byte lanes with the matching WSTRB (REQ11) — exactly the
convention the DP-SRAM expects. Loads pass the returned word through one
right-shifter and sign/zero-extend the byte or half.

### hazard_unit.v — the one place stall/flush is decided (REQ6)
Everything about pipeline motion is expressed in five signals computed
here: does S2 advance, does fetch redirect, does IF/DX load, is it a
bubble, does the S2 instruction commit. Two rules fall out of a single gate
(`s2_advance`) (D14):

- *flush beats stall* — a redirect reaches S1 even if S1 is mid-fetch;
- *an S2 stall finishes before S2 can flush* — an access fault, known only
  when the response lands, waits for that exact cycle.

The forwarding compare (S3.rd vs S2.rs1/rs2) also lives here.

### writeback_mux.v — S3
Selects what goes into rd: ALU result, load data, PC+4 (the JAL/JALR link),
or the CSR read value. The write itself is gated by DX/WB's valid bit, so
bubbles and squashed instructions write nothing.

### pic.v — the interrupt hub of the SoC (D19–D22)
Not part of the CPU pipeline: this is the block the peripherals' interrupt
lines plug into, and the counterpart of the CPU's `cpu_irq*` interface. The
core of it is one line of combinational logic:

```
pending = irq_src & enable & ~in_service
```

- `irq_src[7:0]` — level-sensitive request lines from the peripherals
  (planned hookup: DMA channels 0..3, DP-SRAM on 4). A peripheral holds its
  line high until software clears its own INT_STATUS register (D19).
- `enable` — the PIC's software mask (its IRQ_ENABLE register), a second,
  independent gate in front of the CPU's per-cause `mie` mask.
- `in_service` — set from `cpu_irq_ack` when the CPU accepts a channel,
  cleared when `cpu_in_trap` drops at MRET. This is what "suppress
  re-assertion of the same interrupt" means in practice: the level line is
  still high while its handler runs, and this mask keeps it from re-entering
  a handler that re-enables interrupts (D21).

`cpu_irq` and `cpu_irq_id` are both registered from the same `pending`
vector, so the pair the CPU sees is always consistent; the id is simply the
lowest-numbered pending channel — fixed priority, channel 0 highest (D20).

Software talks to it over an AXI4-Lite slave port (D22):

| Offset | Register | Access | Meaning |
|--------|----------|--------|---------|
| 0x0 | IRQ_ENABLE | R/W | per-channel gate, bit i = channel i |
| 0x4 | IRQ_PENDING | RO | what the CPU is being offered (= `cpu_irq`) |
| 0x8 | IRQ_RAW | RO | the source lines, unmasked |
| 0xC | IRQ_ACTIVE | RO | the in-service mask |

Any other offset — and any write to a read-only register — answers SLVERR,
which the CPU turns into a precise access fault.

---

## 4. The AXI4-Lite buses

Both ports follow the same rules (REQ2, REQ12); the CPU keeps at most one
transaction in flight per port and never does read+write at once.

Every channel uses the same handshake: the sender raises VALID with stable
payload, the receiver raises READY, the transfer happens on the clock edge
where both are high. VALID must never wait for READY, and once VALID is up
the payload must not change — the fetch unit and LSU are built around
exactly these two obligations.

**Read (fetch or load):**
```
            cycle:   1     2     3
ARVALID  ▔▔▔▔▔╲_____
ARREADY  _____╱▔▔▔▔▔        (address accepted end of cycle 1)
RVALID   ___________╱▔▔▔▔▔
RREADY   ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔  (data beat lands cycle 2..n, RRESP says OKAY/error)
```

**Write (store):** AW (address) and W (data+WSTRB) go out together, each
with its own READY; when both have handshaked, the slave answers on B with
the status. The LSU tracks the three channels independently, which is also
what makes a future move to full AXI4 an extension instead of a rewrite.

Error codes: `OKAY` is normal; `SLVERR`/`DECERR` turn into precise traps —
instruction access fault for fetch, load/store access fault for data (D8,
D18). `DECERR` is what the interconnect answers for an unmapped address.

---

## 5. Stalls, bubbles, flushes — who moves when

Three distinct mechanisms, often confused:

- **Stall** — a stage holds its content. Only S2 stalls, and only while a
  data transaction is in flight. S1 freezes with it (nowhere to deliver).
- **Bubble** — a pipeline register loads "nothing" (valid=0). Happens when
  fetch hasn't delivered yet, and behind every flush. A bubble flows
  through S2/S3 doing nothing — every side effect is gated by valid (D1).
- **Flush** — S2 decided the instruction(s) behind it are wrong-path:
  mispredict, trap entry, MRET. Exactly one fetch is thrown away (the
  pipeline is only 3 deep), and fetch restarts at the corrected address.

Worked example — mispredicted branch:
```
cycle 1  S1 fetches B (predicted not-taken) ; next fetch = B+4 starts
cycle 2  S2 resolves B: actually taken, target T → mispredict
         hazard_unit: redirect=1 → fetch drops the B+4 word, IF/DX ← bubble
cycle 3  S1 fetches T          ; S2 executes the bubble (does nothing)
cycle 4  S2 executes T's instruction        → total cost: 1 cycle
```

---

## 6. Traps and interrupts, step by step

**Synchronous exception** (say, a load from an unmapped address):
```
1. lsu issues the read; the interconnect answers DECERR
2. exception_unit raises cause 5 in the response cycle
3. same cycle: DX/WB gets valid=0 (the load never commits), IF/DX flushed
4. csr_file commits atomically: mepc ← load's PC, mcause ← 5,
   MPIE ← MIE, MIE ← 0
5. fetch redirects to the handler (mtvec BASE, or BASE+4×cause if vectored
   and it's an interrupt); cpu_in_trap goes high
```

**External interrupt** (REQ4, D2), end to end through the PIC:
```
1. a peripheral raises its level-sensitive line into pic.v and holds it
2. the PIC gates it (IRQ_ENABLE, in-service mask), picks the lowest pending
   channel, and presents cpu_irq / cpu_irq_id one cycle later
3. the core takes it only when mstatus.MIE and that channel's mie bit are
   set, and only at an instruction boundary — a pending interrupt during a
   multi-cycle AXI stall politely waits for the stall to finish
4. the victim instruction is squashed *before* doing anything (so it can
   safely re-run), mepc points at it, cpu_irq_ack[id] pulses one cycle
5. the PIC moves the channel into its in-service mask: even though the
   peripheral's line is still high, it disappears from cpu_irq until MRET —
   the handler cannot be re-entered by the interrupt it is serving
6. the handler clears the peripheral's INT_STATUS (dropping the line) and
   MRETs; cpu_in_trap falls, the PIC releases the in-service mask
```
Two masks stack up on purpose: the PIC's IRQ_ENABLE says "this source may
reach the CPU at all", the CPU's `mie` says "the software running right now
cares". A channel can be visible in `mip` yet never taken — that exact case
(channel 5) runs in the testbench.

**MRET**: `MIE ← MPIE`, jump to `mepc`, `cpu_in_trap` drops, and the
preempted instruction executes as if nothing happened (D4).

Nothing here consults the branch predictor — trap and MRET redirects are
architectural, and the predictor neither learns from them nor steers them.

---

## 7. Data flow, condensed

```
        ibus_axi.R ──► fetch_unit ──► IF/DX ──► decode ─┬─► regfile read
                            ▲                           │       │
   branch_predictor ────────┘ (next PC)                 │   forward from S3?
                                                        ▼       ▼
                                              control lines   operands
                                                        │       │
                              ┌─────────────────────────┼───────┤
                              ▼                         ▼       ▼
                         branch_unit                  ALU     csr_file
                              │                         │       │
                        taken/target             addr/result  rdata
                              │                         │       │
        mispredict/trap ◄─────┴──── exception_unit ◄────┤       │
              │                                         ▼       │
              ▼                                    lsu ◄─► dbus_axi
        redirect to fetch                               │
                                                   load data
                                                        ▼
                                    DX/WB ──► writeback_mux ──► regfile write
                                                        │
                                                        └──► forwarding to S2
```

Follow any instruction along this graph and you have its complete story:
in through the R beat, out through the regfile write port (or, for stores,
out through the W channel; for branches, back into the predictor).

---

## 8. Running more than one core

The core carries no global state: memories are outside, identity comes from
two parameters (`RESET_PC`, `HART_ID` → the read-only `mhartid` CSR, D5),
and each instance is a well-behaved AXI master an interconnect can
arbitrate. Software tells cores apart by reading `mhartid`. There is no
LR/SC in RV32I, but every core here executes memory operations in order and
one at a time — sequentially consistent — so plain flag handshakes through
shared memory are sound. `debug/hdl/tb_dual_core.v` runs exactly that: two
cores, one shared memory behind a 2:1 arbiter, a flag handshake, both
results checked.

---

## 9. Where the testbench fits

`debug/` mirrors this document in executable form: `tb_cpu_axi.v` builds a
small SoC — CPU, imem, an address decoder that maps the PIC's registers at
0x3000_0000 next to the dmem, and the real `pic.v` with the TB playing the
peripherals on `irq_src` — and drives a real program
(`debug/sim/program_axi.s`) through every path described above: every
instruction group, every trap cause, PIC priority/suppression/masking, the
predictor corner cases. Passive AXI monitors check the bus rules on every
cycle on all three ports (ibus, dbus, PIC). `debug/VERIFICATION.md` maps
each behavior to the exact check that proves it.
