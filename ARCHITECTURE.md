# Architecture

RV32I CPU, 3-stage pipeline, two AXI4-Lite master ports. This file describes
the block structure, the pipeline timing and the implementation choices per
module. Requirement tags (`REQ#`) and design-decision tags (`D#`) match the
index in the README and the comments in the code.

## 1. Top level

```
             ┌─────────────────────── cpu_top ───────────────────────┐
             │                                                       │
  ibus_axi   │  ┌────────────┐   ┌─────────────────────┐   ┌──────┐  │
 ◄──────────►│  │ fetch_unit │──►│  IF/DX pipeline reg │──►│      │  │
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

Interfaces (REQ2, REQ3):

| Signal | Dir | Description |
|---|---|---|
| `ibus_axi_*` | master | instruction fetch, AR/R channels only |
| `dbus_axi_*` | master | load/store, all 5 channels, WSTRB per byte lane |
| `clk`, `rst_n` | in | one clock domain, async active-low reset |
| `cpu_irq[7:0]` | in | pending interrupt per PIC channel |
| `cpu_irq_id[2:0]` | in | highest-priority pending channel |
| `cpu_irq_ack[7:0]` | out | 1-cycle pulse on the accepted channel |
| `cpu_in_trap` | out | high from trap entry until MRET |

Parameters: `RESET_PC` (boot address) and `HART_ID` (drives `mhartid`, D5).
The port list has not changed since the first pipeline version; all later
features (WFI, RAS, counters) are internal, and the PIC/mtimer are separate
blocks.

The repo also contains two blocks that are not part of the CPU but that the
system needs and no other block owns: the interrupt controller `pic.v`
(section 7) and the machine timer `mtimer.v` (section 8).

## 2. Pipeline

| Stage | Name | Work done there |
|---|---|---|
| S1 | Fetch | AXI read on `ibus`, next-PC prediction |
| S2 | Decode + Execute | decode, regfile read, ALU, branch resolve, CSR access, load/store on `dbus`, all trap/interrupt decisions |
| S3 | Writeback | register file write |

Everything interesting is in S2 on purpose: with decode+execute+memory in
one stage, an instruction either completes fully or not at all, which is
what makes the traps precise (REQ1).

Pipeline registers (D1): each one is a `valid` bit plus a payload. Only the
valid bit has a reset; the payload is ignored whenever valid=0, so a flush
or a reset produces a guaranteed safe bubble without caring what the
payload holds.

### Timing of the common cases

ALU op — 1 instruction per cycle, measured CPI = 1.00:

| cycle | S1 | S2 | S3 |
|---|---|---|---|
| 1 | fetch `add` | | |
| 2 | fetch next | decode+execute | |
| 3 | ... | next instr | write rd |

Load/store — S2 stalls for the whole AXI round-trip (REQ5):

| cycle | activity |
|---|---|
| 1 | ALU computes the address, alignment check, LSU issues AR (or AW+W) |
| 2..n-1 | S2 stalled, S1 may finish its own fetch and park it |
| n | response beat arrives, data extracted, instruction leaves S2 |
| n+1 | writeback |

Mispredict — costs exactly 1 cycle:

| cycle | activity |
|---|---|
| 1 | S2 resolves the branch, direction/target differ from the prediction |
| 1 | hazard_unit: redirect, the wrong-path fetch in S1 is dropped |
| 2 | S1 fetches the correct target, S2 executes a bubble |
| 3 | correct-path instruction in S2 |

### Stall / bubble / flush

Three different mechanisms, all owned by `hazard_unit` (REQ6):

- **stall** — S2 holds its instruction. Sources: data AXI in flight
  (`lsu_busy`) and WFI sleep (`wfi_wait`, D23). S1 freezes with it.
- **bubble** — a pipeline register loads valid=0. Happens when fetch has
  not delivered yet and behind every flush.
- **flush** — S2 decided the younger instruction is wrong-path
  (mispredict, trap entry, MRET). Exactly one fetch is dropped.

Priority (D14): flush beats stall, and an S2 stall finishes before S2 can
raise a flush that depends on the result of the stalled op (e.g. a bus
error only known when the response lands). Both rules come from gating
everything with one signal, `s2_advance`.

## 3. Module descriptions

### fetch_unit.v — S1 (REQ5, REQ12; D6, D7, D8)

Owns the PC and the `ibus` AXI master. One transaction in flight, next
ARVALID raised in the same cycle the current R beat is accepted, so a
latency-1 memory sustains 1 fetch/cycle (D6).

Implementation choices:
- **Holding register** (D7): if S2 stalls, the finished fetch parks in a
  1-entry buffer and no new fetch is issued. S1 never runs ahead of S2.
  This is also why WFI needs no extra logic to silence the bus: once the
  holding register is full, no AR is issued.
- **Redirect with a read in flight** (D7): AXI reads cannot be cancelled.
  A `discard` flag is set, the stale beat is accepted and dropped, then
  fetching restarts at the redirect address.
- **Fetch bus errors** (D8): SLVERR/DECERR does not trap in S1. The word
  is tagged `fetch_fault` and traps as instruction access fault (cause 1)
  only if it reaches S2 — a wrong-path faulting fetch just gets flushed.
- **ARVALID is gated with `rst_n`**: the issue logic is combinational and
  would otherwise request `RESET_PC` while reset is still asserted, which
  AXI forbids (found by the SVA layer, see debug/VERIFICATION.md).

### branch_predictor.v — BHT + BTB + RAS (REQ8; D9, D10, D11, D24)

```
lookup (S1):  PC ──► index [8:2] ──► {valid, tag, dir bit, is_ret, target}
                                          │
              hit && dir ──► pred_taken   ├─ is_ret && RAS not empty ─► RAS top
                                          └─ otherwise ─────────────► stored target
update (S2 commit): PC, taken, real target, is_ret, push/pop
```

- 128 direct-mapped entries, index PC[8:2], tag PC[31:9] (D9). The stored
  target exists because at fetch time the immediate is not decoded yet; a
  direction bit alone could not redirect anything.
- 1-bit direction = last outcome (REQ8). Miss predicts not-taken (D10).
- Updates happen only when a branch/jump commits in S2 (D11). Nothing is
  speculative and entries survive traps (trap/MRET redirects are
  architectural, they bypass the predictor).
- **RAS** (D24): 8 entries (parameter, 0 disables). The BTB stores the
  last target, which is wrong for a return called from several places.
  Committed calls (rd = x1/x5, the JALR hint convention from the ISA
  spec) push pc+4, committed returns pop, and a BTB entry learned from a
  return is flagged `is_ret` so its prediction comes from the RAS top.
  Overflow wraps, underflow falls back to the stored target. Both cases
  only cost accuracy — correctness always comes from branch_unit.

### decode.v / imm_gen.v / control.v (REQ7; D23)

`decode` slices the fixed RV32I fields, `imm_gen` builds the immediate for
the 5 encoding formats, `control` turns the opcode into S2's control
lines. Anything unknown sets `illegal` and forces every other control line
inactive, so an illegal instruction has no side effects — it traps.

- FENCE = NOP: single hart, in-order, blocking memory, nothing to order.
- SYSTEM decodes exact encodings only: ECALL, EBREAK, MRET, WFI
  (imm12 = 0x105, D23) and the six CSR forms. funct3=100 is reserved →
  illegal.

### regfile.v (REQ10)

32×32, x0 hardwired to zero, two combinational read ports (S2), one write
port (S3), reset to zero.

### alu.v / alu_top.v / branch_unit.v

`alu_top` selects the operands (register vs immediate, PC for AUIPC) and
derives the ALU opcode from funct3/funct7. `branch_unit` computes the real
direction and target of every control transfer; that result is compared
against the prediction, trains the predictor and masks bit 0 for JALR as
the ISA requires.

### csr_file.v (REQ9; D3, D5, D15, D16, D25)

| CSR | Addr | Implemented fields |
|---|---|---|
| mstatus | 0x300 | MIE(3), MPIE(7); MPP fixed 2'b11 |
| mie | 0x304 | bits 16..23 = the 8 PIC channels (D3) |
| mtvec | 0x305 | BASE[31:2], MODE[1:0] direct/vectored (D16) |
| mscratch | 0x340 | full 32 bits |
| mepc | 0x341 | [1:0] forced to 0 |
| mcause | 0x342 | bit31 = interrupt, code in the low bits |
| mip | 0x344 | read-only, mirrors `cpu_irq` on 16..23 |
| mcycle / minstret | 0xB00/0xB02 | read-only counters (D5) |
| mhpmcounter3..7 | 0xB03..07 | read-only event counters (D25) |
| mhartid | 0xF14 | read-only, `HART_ID` parameter (D5) |

- Reads are combinational, software writes commit at the end of S2.
- Trap entry writes mepc/mcause/MPIE←MIE/MIE←0 in one clock edge, MRET
  swaps back — hardware sequences always win over a software write.
- Access to a missing CSR or an effective write to a read-only one raises
  illegal instruction (D15). CSRs are inside the core, so a bus error
  code would be the wrong abstraction. CSRRS/C with rs1=x0 counts as a
  pure read and does not trap on read-only CSRs.
- Vectored mode (D16): interrupts jump to BASE + 4×cause, exceptions to
  BASE.
- Performance counters (D25): 3 = mispredicts, 4 = cycles with S2 empty,
  5 = dbus stall cycles, 6 = trap entries, 7 = WFI sleep cycles. These
  pair with the DP-SRAM bandwidth registers and the DMA throttling knobs,
  so software can measure contention instead of guessing.

### exception_unit.v (D3, D17, D18)

Watches the instruction in S2 and raises at most one cause:
fetch fault (1) → illegal (2) → EBREAK (3) → ECALL (11) → misaligned jump
target (0) → misaligned load/store (4/6) → load/store bus fault (5/7).

- Alignment is checked before the access, so a misaligned address never
  produces an AXI transaction (D17).
- Bus errors are checked after the response and become access faults, not
  illegal instruction (D18).

### lsu.v — S2's data AXI master (REQ5, REQ11, REQ12; D12)

Gets a command only for a legal, aligned, not-squashed memory op. Address
and store data are latched in the first cycle: forwarded operands are only
guaranteed valid then, and AXI wants a stable payload anyway (D12).

- FSM: IDLE → RD or WR → IDLE, one transaction in flight. Handshake
  progress is tracked per AXI channel (`ar_sent`, `aw_sent`, `w_sent`),
  which keeps a later AXI4-Full upgrade additive.
- WSTRB (REQ11): SB = `0001 << addr[1:0]`, SH = `0011 << addr[1:0]`,
  SW = `1111`, data replicated across lanes — the exact convention the
  DP-SRAM expects.
- Loads: one right-shifter serves both byte and halfword extraction
  (misaligned halves already trapped, so addr[0]=0 holds), then
  sign/zero-extension by funct3.

### hazard_unit.v (REQ6; D13, D14, D23)

```verilog
s2_advance   = ~lsu_busy & ~wfi_wait;
redirect     = (trap_take | mret_exec | mispredict) & s2_advance;
if_dx_we     = s2_advance;
if_dx_bubble = redirect | ~fetch_valid;
dx_squash    = trap_take;
```

Also computes the forwarding hits (S3.rd vs S2.rs1/rs2, x0 excluded).
Load-use costs zero cycles (D13): a load's data is already in S3 when its
consumer sits in S2, so a single S3→S2 bypass covers it.

### writeback_mux.v — S3

Selects rd's value: ALU result, load data, PC+4 (JAL/JALR link) or CSR
read value. The write enable is gated by the DX/WB valid bit.

## 4. AXI4-Lite

Both master ports follow the same rules (REQ2, REQ12):

- VALID never waits for READY; once VALID is high the payload holds until
  the handshake.
- At most one transaction in flight per port, never read+write at the
  same time on `dbus`.
- Read: AR handshake, then the R beat. Write: AW and W issued together,
  each with its own READY, response on B.

```
            cycle:   1     2     3
ARVALID  ▔▔▔▔▔╲_____
ARREADY  _____╱▔▔▔▔▔        address accepted end of cycle 1
RVALID   ___________╱▔▔▔▔▔
RREADY   ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔  data beat in cycle 2..n, RRESP = OKAY/error
```

Error handling: OKAY is the normal case; SLVERR (from a real slave, e.g. a
read-only PIC register) and DECERR (from the interconnect, unmapped
address) both become precise traps — cause 1 on fetch, cause 5/7 on data
(D8, D18).

## 5. Interrupts

```
DMA ch0..3 ──┐
DP-SRAM ─────┤ irq_src[7:0]   ┌──────────────── pic.v ───────────────┐
mtimer ──────┘ (level) ──────►│ pending = src & enable & ~in_service │
                              │ cpu_irq    <= pending                │
   AXI4-Lite slave ──────────►│ cpu_irq_id <= lowest pending channel │
   (IRQ_ENABLE etc.)          └──────────────────┬───────────────────┘
                                                 ▼
                                    cpu_irq / cpu_irq_id  ──►  CPU
                                    cpu_irq_ack / cpu_in_trap ◄──
```

CPU side (REQ4): an interrupt is taken only under `mstatus.MIE`, only if
the channel's `mie` bit is set, and only at an instruction boundary — a
pending interrupt during a multi-cycle AXI stall waits for the response
beat. The victim instruction is squashed before it does anything, so it
can re-run after MRET. mepc holds the resume PC (D4); the one exception is
a WFI wake, where mepc = wfi+4 per the privileged spec.

PIC side (D19..D22):
- Level-sensitive inputs, no latching (D19): a peripheral holds its line
  until software clears its own status register. `cpu_irq` and
  `cpu_irq_id` are registered from the same pending vector, so the pair
  the CPU samples is always consistent.
- Fixed priority, channel 0 highest (D20).
- In-service suppression (D21): the acked channel is masked out of
  `cpu_irq` until MRET, so a handler that re-enables MIE cannot be
  re-entered by the interrupt it is serving.
- Register map (D22), word registers from the base address:

| Offset | Register | Access |
|---|---|---|
| 0x0 | IRQ_ENABLE | R/W |
| 0x4 | IRQ_PENDING | RO (= cpu_irq) |
| 0x8 | IRQ_RAW | RO (source lines) |
| 0xC | IRQ_ACTIVE | RO (in-service mask) |

Anything else, and any write to a read-only register, answers SLVERR.

Two masks stack on purpose: PIC IRQ_ENABLE = "this source may reach the
CPU", `mie` = "current software cares". A consequence of the fixed
priority, found while testing: a source that is PIC-enabled but
mie-masked keeps `cpu_irq_id` pointed at itself and starves all
lower-priority channels. Integration rule: only route a source into the
PIC if some handler will actually clear it.

## 6. WFI + mtimer

WFI (D23) is decoded in `control` and implemented as a third stall source:
S2 freezes on the WFI, S1 parks its fetch, and the instruction bus goes
idle (measured: at most the one already-issued fetch completes per sleep).
Wake condition is `|(cpu_irq & mie)` — `mstatus.MIE` is intentionally not
part of it, per privileged spec 3.3.3:

- MIE = 1: the wake becomes a normal interrupt, with mepc = wfi+4 so MRET
  resumes after the WFI;
- MIE = 0: the WFI completes as a NOP and execution falls through.

mtimer (D26, D27) is the standard RISC-V machine timer as a memory-mapped
peripheral: 64-bit free-running `mtime`, 64-bit `mtimecmp`, level
interrupt `irq = (mtime >= mtimecmp)` wired to PIC channel 7 (lowest
priority: a tick should not outrank DMA/DP-SRAM service).

| Offset | Register | Access |
|---|---|---|
| 0x0 / 0x4 | MTIME_LO / HI | R/W |
| 0x8 / 0xC | MTIMECMP_LO / HI | R/W |

- Reset value of mtimecmp is all-ones, so the timer starts disarmed.
- Arming order LO-then-HI cannot fire early (the compare cannot pass the
  all-ones high half).
- There is no separate status register: the compare is the status, and
  the handler clears the line by moving mtimecmp — consistent with the
  level-sensitive contract of the PIC (D19).

Together they give the SoC an idle mode: program the DMA, arm the timer
as a deadline, execute WFI. The CPU generates zero interconnect traffic
while the DMA works, and either the completion interrupt or the timer
wakes it; a timeout handler can abort a stuck channel over the DMA's
CHx_CONTROL register.

## 7. Multi-core

The core keeps no global state: memories are external, identity comes
from `RESET_PC`/`HART_ID`, and each instance is a normal AXI master an
interconnect can arbitrate. RV32I has no LR/SC, but every memory op here
is in-order and blocking (one outstanding, no store buffer), so each hart
is sequentially consistent and flag handshakes through shared memory
work. `debug/hdl/tb_dual_core.v` runs two cores against one shared memory
behind a 2:1 arbiter and checks both results.

## 8. Verification

The testbench (`debug/hdl/tb_cpu_axi.v`) builds a small SoC around the
CPU: instruction memory, two address decoders (PIC at 0x3000_0000, mtimer
at 0x3001_0000, data memory as default), the real `pic.v` and `mtimer.v`,
protocol monitors on all four AXI ports, and a directed self-checking
program. A separate SVA + functional-coverage layer (`debug/sva/`) binds
the same contracts as assertions and runs under Verilator. The test plan,
the coverage results and the bugs found along the way are documented in
`debug/VERIFICATION.md`.
