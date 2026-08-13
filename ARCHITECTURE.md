# Architecture

RV32I CPU, 3-stage pipeline, two AXI4-Lite master ports. Describes the block
structure, pipeline timing, and per-module implementation choices. Requirement
tags (`REQ#`) and design-decision tags (`D#`) match the README index and the
code comments.

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
  cpu_irq ───►│                                     │ writeback →  │  │
  cpu_irq_vec►│                                     │ regfile      │  │
  ◄─ irq_ack  │                                     └──────────────┘  │
  ◄─ irq_eoi  └───────────────────────────────────────────────────────┘
```

Interfaces (REQ2, REQ3):

| Signal | Dir | Description |
|---|---|---|
| `ibus_axi_*` | master | instruction fetch, AR/R channels only |
| `dbus_axi_*` | master | load/store, all 5 channels, WSTRB per byte lane |
| `clk`, `rst_n` | in | one clock domain, async active-low reset |
| `cpu_irq` | in | interrupt request from the PIC (single level line) |
| `cpu_irq_vec[3:0]` | in | id (0..15) of the highest-priority offered source |
| `cpu_irq_ack` | out | 1-cycle claim pulse at handler entry |
| `cpu_irq_eoi` | out | 1-cycle pulse on an interrupt-returning MRET (PIC pops its nesting stack) |
| `cpu_in_trap` | out | high from trap entry until MRET (observability / SVA) |

Parameters: `RESET_PC` (boot address), `HART_ID` (drives `mhartid`, D5), and
`BP_ENTRIES` / `RAS_DEPTH`, forwarded to the branch predictor (D9/D24) so a
SoC can size it without editing the module. The port list hasn't changed since
the first pipeline version; all later features (WFI, RAS, counters) internal,
PIC/mtimer separate blocks.

The repo also carries two blocks not part of the CPU but that the system needs
and no block owns: the interrupt controller `pic.v` (section 5) and the machine
timer `mtimer.v` (section 6).

## 2. Pipeline

| Stage | Name | Work done there |
|---|---|---|
| S1 | Fetch | AXI read on `ibus`, next-PC prediction |
| S2 | Decode + Execute | decode, regfile read, ALU, branch resolve, CSR access, load/store on `dbus`, all trap/interrupt decisions |
| S3 | Writeback | register file write |

Everything interesting is in S2 on purpose: decode+execute+memory in one stage
means an instruction either completes fully or not at all — that's what makes
the traps precise (REQ1).

Pipeline registers (D1): each a `valid` bit plus a payload. Only the valid bit
has a reset; the payload is ignored when valid=0, so a flush or reset produces
a safe bubble no matter what the payload holds.

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

Priority (D14): flush beats stall, and an S2 stall finishes before S2 can raise
a flush that depends on the stalled op's result (e.g. a bus error known only
when the response lands). Both rules come from gating everything with one
signal, `s2_advance`.

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
| mie | 0x304 | bits 16..31 = the 16 PIC sources (D3) |
| mtvec | 0x305 | BASE[31:2], MODE[1:0] direct/vectored (D16) |
| mscratch | 0x340 | full 32 bits |
| mepc | 0x341 | [1:0] forced to 0 |
| mcause | 0x342 | bit31 = interrupt, code in the low bits |
| mip | 0x344 | read-only, one-hot of the PIC's offered source on 16..31 |
| mcycle / minstret | 0xB00/0xB02 | 64-bit counters, low half (D5) |
| mcycleh / minstreth | 0xB80/0xB82 | upper halves of the same counters |
| mhpmcounter3..7 | 0xB03..07 | event counters, low half (D25) |
| mhpmcounter3h..7h | 0xB83..87 | upper halves |
| mhpmcounter8..31 (+h) | 0xB08..1F, 0xB88..9F | hardwired zero (WARL) |
| mhpmevent3..31 | 0x323..33F | hardwired zero (WARL) — events are fixed |
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
- Counters follow Priv. spec 3.1.11: each is architecturally 64-bit, read on
  RV32 through a base / base+0x80 pair, and writable from M-mode. A write
  replaces the addressed half while the other half still takes the increment,
  so the event landing in the same cycle as the write is not lost. The counters
  the design does not provide (`mhpmcounter8..31`, their upper halves, and
  `mhpmevent3..31`) are hardwired zero — they read 0 and ignore writes, rather
  than trapping, because the spec permits tying off counters but not making
  them disappear. `mcountinhibit` (0x320) is absent on purpose: it is optional,
  and its not-implemented behaviour ("all counters run") is exactly this design.

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

### axi_lite_slave.v — shared register interface (D-AXI)

The slave-side AXI4-Lite handshake written once and instantiated by both `pic.v`
and `mtimer.v` (and open to any register-mapped peripheral — the DP-SRAM ports or
the DMA config port would use it unchanged). It owns AW/W collection, the B
response and the AR/R response; the peripheral only describes its registers.

- **Write**: AW and W are collected independently and may arrive in either
  order; when both are in, one `wr_en` pulse hands the peripheral
  `wr_addr`/`wr_data`/`wr_strb`. `wr_ok` is a combinational function of the
  offset — a non-writable word answers SLVERR.
- **Read**: `rd_addr` is valid while ARVALID; the peripheral drives `rd_data`
  and `rd_ok` combinationally, and the slave registers them into RDATA/RRESP on
  the AR handshake. RDATA resets to 0, so the port reads as zero rather than X
  before the first transaction.
- **Contract**: ≤1 transaction per direction, matching the CPU's 1-outstanding
  master.
- **Integration note**: the offset decode uses only `addr[7:2]`, so inside an
  interconnect window larger than 256 B high addresses alias onto the first
  registers instead of answering SLVERR. Open point until the memory map is
  fixed (see README "Open points").

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

## 5. Interrupts — PIC with Advanced Scheduling

The PIC implements the *Programmable Interrupt Controller with Advanced
Scheduling* brief (`pic/*.jpeg`): 16 hardware sources + 16 software channels
(32 logical sources) through one priority-resolution pipeline, with custom
priority grouping, preemptive nesting, spurious detection, deadline escalation,
and software triggers. The brief is a draft that delegates the "non-standard
design challenges" to the intern; the choices below (tagged `D-*` to match
`pic.v`) are that feature spec.

```
DMA/DP-SRAM ─┐ irq_src[15:0]  ┌─────────────── pic.v (advanced scheduling) ──┐
mtimer ──────┤ (level/edge) ─►│ req  = (level?src : edge_latch | sw) & INT_ENABLE
sw triggers ─┘ SRCx_SW_TRIG   │ key  = {band_urgency, intra_priority, ~index}  │
                              │ offer = most-urgent req strictly above nest top│
   AXI4-Lite slave ──────────►│ cpu_irq / cpu_irq_vec  registered (D-LAT)      │
   (config + status)          └──────────────────┬─────────────────────────────┘
                                                 ▼
                          cpu_irq / cpu_irq_vec ───►  CPU
                          cpu_irq_ack (claim) / cpu_irq_eoi (return) ◄──
```

CPU side (REQ4): an interrupt is taken only under `mstatus.MIE`, only if the
source's `mie[16+vec]` bit is set, only at an instruction boundary — a pending
interrupt during a multi-cycle AXI stall waits for the response beat. The victim
instruction is squashed before doing anything, so it re-runs after MRET. mepc
holds the resume PC (D4); the one exception is a WFI wake, where mepc = wfi+4
per the privileged spec. The CPU pulses `cpu_irq_ack` when it enters the handler
(the PIC's *claim*) and `cpu_irq_eoi` on an interrupt-returning MRET (the PIC's
*end-of-interrupt*).

### Sources (D-SW)
Each of the 16 slots has a hardware line `irq_src[i]` (level- or edge-triggered
per `SRCx_CONFIG.TRIG`) and a software channel. A slot's request is
`req = (level ? irq_src[i] : edge_latch[i] | sw_pend[i]) & INT_ENABLE[i]`, so a
software-injected interrupt is indistinguishable from a hardware one once in the
pipeline. Software sets a channel with a *keyed* `SRCx_SW_TRIG` write (bit0=1
with `0xA5A5` in [31:16], so a stray single-bit write cannot trigger it) and
clears it by writing bit0=0; a claim also auto-clears it, like an edge source.

### Priority grouping (D-BAND)
Four priority **bands**. `BAND_CONFIG` assigns each band a 2-bit urgency
(default band 0 highest … band 3 lowest), so software can reorder bands without
touching per-source config. Each source carries a 2-bit band and a 4-bit
intra-band priority. The resolver compares an effective key
`{band_urgency, intra_priority, ~index}`: band dominates, then intra-priority,
then the lowest index wins the final tie (deterministic, no starvation within a
fully-specified config). Reconfiguring a source's band while it is in service
cannot corrupt nesting — the key is snapshotted onto the stack at claim time.

### Preemption + nesting (D-NEST)
A hardware **nesting stack** (depth 0..`NEST_MAX`, `NEST_MAX` in [1,16], default
8) holds the key+id of every in-service source. Only a source *strictly more
urgent* than the top of the stack is offered, so a higher source preempts a
lower one. `cpu_irq_ack` pushes (claim, depth++), `cpu_irq_eoi` pops (return,
depth--). At `depth == NEST_MAX` offers are masked so the CPU can never claim
past the limit; a preemption blocked that way sets `INT_STATUS.OVF` /
`NEST_STATUS.OVF` (visible, non-destructive).

### Spurious detection (D-SPUR)
A source may deassert between being offered and the CPU's claim. Detected at the
claim: if the offered source's `req` is gone when `cpu_irq_ack` lands, the claim
is *spurious* — `SRCx_STATUS.SPUR` + sticky `SPURIOUS_LOG[x]` + `INT_STATUS.SPUR`
are set, and the claim is still accounted on the stack so the ack/eoi handshake
stays balanced (a vectored CPU has already committed to the handler; it reads the
flag and early-outs). A source still asserted at the claim, and only cleared
later in the handler, is legitimate — not spurious.

### Deadline escalation (D-DDL)
Each source has a 16-bit deadline (cycles, 0 = disabled). A per-source counter
runs while the slot is a pending request awaiting service; on reaching the
deadline the source's effective band is escalated per `ESCALATION_CFG` (jump to a
target band, or bump one band more urgent; `MULTI` re-arms for repeated
escalation) and `SRCx_STATUS.ESC` / `INT_STATUS.ESC` are set. On claim / return
to idle the band and counter reset to the configured values.

### Register map (D-AXI)
Word registers from the base address; unmapped words and read-only writes answer
SLVERR, byte strobes are honoured on writes.

| Offset | Register | Access | Reset | Fields |
|---|---|---|---|---|
| 0x00–0x3C | `SRCx_CONFIG` (x=0..15) | R/W | `0x0000_0000` | `TRIG`[0], `BAND`[2:1], `INTRA`[7:4], `DEADLINE`[31:16] |
| 0x40–0x7C | `SRCx_SW_TRIG` | R/W | `0x0000_0000` | software request bit0 (set needs key `0xA5A5` in [31:16]) |
| 0x80–0xBC | `SRCx_STATUS` | RO | `0x0000_0000` | `PEND`[0], `ACTIVE`[1], `ESC`[2], `SPUR`[3], `EFF_BAND`[5:4], `DDL_TIMER`[31:16] |
| 0xC0 | `BAND_CONFIG` | R/W | `0x0000_001B` | 2-bit urgency per band {b3,b2,b1,b0} — band0=3 (most urgent) … band3=0 |
| 0xC4 | `NEST_STATUS` | RO | `0x0000_0000` | `DEPTH`[4:0], `TOP_ID`[11:8], `OVF`[16] |
| 0xC8 | `NEST_MAX` | R/W | `0x0000_0008` | max nesting depth, writes clamped to [1,16] |
| 0xCC | `ACTIVE_VEC` | RO | `0x0000_0000` | `ID`[3:0], `VALID`[8] |
| 0xD0 | `SPURIOUS_LOG` | R/W1C | `0x0000_0000` | per-source sticky spurious flags |
| 0xD4 | `ESCALATION_CFG` | R/W | `0x0000_0000` | `TARGET`[1:0], `MODE`[4] (0 jump / 1 bump), `MULTI`[8] |
| 0xD8 | `INT_ENABLE` | R/W | `0x0000_0000` | per-source master enable mask |
| 0xDC | `INT_STATUS` | R/W1C | `0x0000_0000` | global sticky {`SPUR`[0], `ESC`[1], `OVF`[2]} |

Every register resets to 0 except the two that would be dangerous as zero:
`BAND_CONFIG` needs a sane default ordering, and `NEST_MAX` = 0 would mask every
offer. So out of reset the PIC is fully disarmed (`INT_ENABLE` = 0, nothing can
reach the CPU) with all 16 sources at band 0, intra-priority 0, level-triggered,
deadlines disabled — i.e. plain lowest-index-first priority until software
programs something else.

`SRCx_CONFIG.TRIG` is one bit because the PIC only distinguishes **level** (0)
from **rising edge** (1). Active-low or falling-edge sources are not a PIC mode:
the SoC convention is active-high, and a source with the opposite polarity is
inverted at the integration boundary rather than adding a second config bit per
slot. Level means "the request follows the line, the handler clears the
peripheral"; edge means "the rising transition is latched into `edge_pend` and
consumed by the claim".

Two masks stack on purpose: `INT_ENABLE` = "this source may reach the CPU",
`mie` = "current software cares". A consequence found while testing: a source
PIC-enabled but mie-masked sits as the PIC's offer forever (the CPU never claims
it) and starves the rest. Integration rule: route a source into the PIC only if
some handler will service it.

## 6. WFI + mtimer

WFI (D23) is decoded in `control` and implemented as a third stall source:
S2 freezes on the WFI, S1 parks its fetch, and the instruction bus goes
idle (measured: at most the one already-issued fetch completes per sleep).
Wake condition is `cpu_irq && mie[16+cpu_irq_vec]` — `mstatus.MIE` is intentionally not
part of it, per privileged spec 3.3.3:

- MIE = 1: the wake becomes a normal interrupt, with mepc = wfi+4 so MRET
  resumes after the WFI;
- MIE = 0: the WFI completes as a NOP and execution falls through.

mtimer (D26, D27) is the standard RISC-V machine timer as a memory-mapped
peripheral: 64-bit free-running `mtime`, 64-bit `mtimecmp`, level
interrupt `irq = (mtime >= mtimecmp)` wired to PIC source 7 (kept in a low
band by config so a tick does not outrank DMA/DP-SRAM service).

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

Together they give the SoC an idle mode: program the DMA, arm the timer as a
deadline, execute WFI. The CPU generates zero interconnect traffic while the DMA
works; either the completion interrupt or the timer wakes it, and a timeout
handler can abort a stuck channel over the DMA's CHx_CONTROL register.

## 7. Multi-core

The core keeps no global state: memories external, identity from
`RESET_PC`/`HART_ID`, each instance a normal AXI master an interconnect can
arbitrate. RV32I has no LR/SC, but every memory op here is in-order and blocking
(one outstanding, no store buffer), so each hart is sequentially consistent and
flag handshakes through shared memory work. `debug/hdl/tb_dual_core.v` runs two
cores against one shared memory behind a 2:1 arbiter and checks both results.

## 8. Verification

Two benches, on purpose:

- `debug/hdl/tb_cpu_axi.v` — the **system** bench. Builds a small SoC around the
  CPU: instruction memory, two address decoders (PIC at 0x3000_0000, mtimer at
  0x3001_0000, data memory as default), the real `pic.v` and `mtimer.v`, protocol
  monitors on all four AXI ports, a directed self-checking program. It runs the
  PIC in its default configuration and proves the CPU↔PIC contract end to end.
- `debug/hdl/tb_pic.v` — the **feature** bench for the PIC alone, so the
  advanced-scheduling features are visible as their own named checks instead of
  being buried in a full-system run: priority bands (inter/intra/tie),
  preemptive nesting and `NEST_MAX` overflow, spurious detection and
  `SPURIOUS_LOG` W1C, deadline escalation (jump / bump / multi), keyed software
  triggers, edge latching, and the AXI error responses. 139 checks.

A separate SVA + functional-coverage layer (`debug/sva/`) binds the same
contracts as assertions and runs under Verilator. Test plan, coverage results,
and the bugs found along the way: `debug/VERIFICATION.md`.

Clock and reset in both benches come from `debug/hdl/ck_rst_tb.v`: 10 ns period
(`CK_SEMIPERIOD` = 5), reset asserted from time 0 and released at 123 ns —
deliberately *not* aligned to a clock edge, so the asynchronous reset's removal
is exercised off-edge rather than in a convenient spot.
