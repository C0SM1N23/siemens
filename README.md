# RISC-V RV32I CPU — 3-stage pipeline with AXI4-Lite

The CPU block of the SoC (CPU + DMA + DP-SRAM), in Verilog. A 3-stage RV32I
pipeline with two AXI4-Lite master ports, a branch predictor with a
return-address stack, precise traps, WFI, and an M-mode CSR file with
performance counters. The repo also carries two blocks no brief assigned but
the system needs: the interrupt controller ([pic.v](hdl/pic.v)) every
peripheral irq line points at, and the machine timer ([mtimer.v](hdl/mtimer.v))
for scheduling and timing out a hung DMA transfer.

Block diagrams and per-module detail: [ARCHITECTURE.md](ARCHITECTURE.md). Test
plan and results: [debug/VERIFICATION.md](debug/VERIFICATION.md).

## Architecture

```
S1 FETCH ──────────── S2 DECODE + EXECUTE ─────────── S3 WRITEBACK
ibus_axi (AR/R)       decode, regfile, ALU, branch,    rd write
+ branch predictor    CSR, load/store on dbus_axi      (S3->S2 forwarding)
  (BTB/BHT, 128,      traps/interrupts resolve here;
   + 8-entry RAS)     WFI sleeps here (ibus goes idle)
```

One clock, async active-low reset. Pipeline registers carry a `valid` bit, so a
flushed or reset stage is a guaranteed no-op. Load-use hazards go through S3→S2
forwarding (no stall); the two AXI ports are independent, one outstanding
transaction each, so a fetch and a load/store overlap.

## Spec requirements vs. design decisions

The brief separates two kinds of item, so does this repo:

- **Spec requirements** (`REQ#`) — behavior the brief fixed. Implemented to
  spec; no choice to make, only to match.
- **Design decisions** (`D#`) — points the brief left "for the intern to
  define". Each a deliberate choice with a rationale.

Both tagged in the code (grep `REQ` or `D<n>`); each file header explains its
own in full. These tables are the index.

### Spec requirements (implemented to spec)

| Tag | Requirement | File(s) |
|-----|-------------|---------|
| REQ1  | 3-stage pipeline: Fetch / Decode+Execute / Writeback | [cpu_top.v](hdl/cpu_top.v) |
| REQ2  | Two AXI4-Lite master ports: ibus (read-only), dbus (read+write) | [cpu_top.v](hdl/cpu_top.v) |
| REQ3  | Top interface: 1 sync clock, async active-low reset, PIC lines | [cpu_top.v](hdl/cpu_top.v) |
| REQ4  | Interrupts sampled under `mstatus.MIE` at instruction boundaries; ack 1-cycle pulse; `cpu_in_trap` entry→MRET | [cpu_top.v](hdl/cpu_top.v) |
| REQ5  | Pipeline stalls until AXI response valid; data op stalls the whole round-trip | [fetch_unit.v](hdl/fetch_unit.v), [lsu.v](hdl/lsu.v) |
| REQ6  | Dedicated centralized hazard/stall/flush unit | [hazard_unit.v](hdl/hazard_unit.v) |
| REQ7  | RV32I instruction set; FENCE = NOP; ECALL/EBREAK trap-handled | [control.v](hdl/control.v) (+ reused alu/decode/imm_gen) |
| REQ8  | 1-bit saturating branch predictor | [branch_predictor.v](hdl/branch_predictor.v) |
| REQ9  | The 7 required M-mode CSRs at their addresses; `mip` read-only, PIC-driven | [csr_file.v](hdl/csr_file.v) |
| REQ10 | Register file: 32×32, x0=0, 1 write / 2 combinational reads, reset 0 | [regfile.v](hdl/regfile.v) |
| REQ11 | WSTRB byte-lane writes (SB/SH/SW) as AXI / DP-SRAM require | [lsu.v](hdl/lsu.v) |
| REQ12 | Handle all AXI response codes (OKAY/SLVERR/DECERR) on both ports | [fetch_unit.v](hdl/fetch_unit.v), [lsu.v](hdl/lsu.v) |

### Design decisions (intern-defined)

| Tag | Decision | File(s) |
|-----|----------|---------|
| D1  | `valid`-bit pipeline registers → guaranteed safe bubble (not the NOP encoding) | [cpu_top.v](hdl/cpu_top.v) |
| D2  | S2 priority: interrupt > sync exception > mispredict, as a sequential check | [cpu_top.v](hdl/cpu_top.v) |
| D3  | Supported mcause set 0,1,2,3,4,5,6,7,11 + external interrupts on 16 PIC sources (causes 16..31) | [exception_unit.v](hdl/exception_unit.v), [csr_file.v](hdl/csr_file.v) |
| D4  | Trap return: exceptions → offending PC, interrupts → resume PC | [cpu_top.v](hdl/cpu_top.v) |
| D5  | `RESET_PC` + `HART_ID` params → `mhartid` (multi-core; beyond spec) | [cpu_top.v](hdl/cpu_top.v), [csr_file.v](hdl/csr_file.v) |
| D6  | ibus master fully independent, ≤1 outstanding, back-to-back fetch (1 instr/cycle) | [fetch_unit.v](hdl/fetch_unit.v) |
| D7  | Holding register keeps PC correct in a stall; in-flight fetch discarded on redirect | [fetch_unit.v](hdl/fetch_unit.v) |
| D8  | Fetch bus error → instruction access fault (mcause 1), not "illegal" | [fetch_unit.v](hdl/fetch_unit.v) |
| D9  | Predictor structure: BHT+BTB, direct-mapped, 128 entries, index PC[8:2], tag + stored target | [branch_predictor.v](hdl/branch_predictor.v) |
| D10 | Miss predicts not-taken | [branch_predictor.v](hdl/branch_predictor.v) |
| D11 | Learned at S2 resolution (non-speculative); entries kept across traps | [branch_predictor.v](hdl/branch_predictor.v) |
| D12 | ≤1 outstanding transaction; address/data latched at start | [lsu.v](hdl/lsu.v) |
| D13 | Load-use solved by S3→S2 forwarding, zero stall cycles | [hazard_unit.v](hdl/hazard_unit.v) |
| D14 | Flush beats stall; both priority rules gated by `s2_advance` | [hazard_unit.v](hdl/hazard_unit.v) |
| D15 | Unimplemented / read-only CSR access → illegal instruction (not DECERR) | [csr_file.v](hdl/csr_file.v) |
| D16 | Vectored mtvec: interrupts → BASE+4·cause, exceptions → BASE | [csr_file.v](hdl/csr_file.v) |
| D17 | Misalignment checked pre-access → no AXI transaction issued | [exception_unit.v](hdl/exception_unit.v) |
| D18 | Bus error → access fault (load 5 / store 7) | [exception_unit.v](hdl/exception_unit.v) |
| D19 | PIC implements the "Advanced Scheduling" brief: 16 hardware + 16 software sources → one prioritised `cpu_irq`/`cpu_irq_vec`, registered off the source timing path (D-LAT) | [pic.v](hdl/pic.v) |
| D20 | Custom priority grouping: 4 bands (per-band urgency in `BAND_CONFIG`) + per-source intra-band priority + lowest-index tie-break; deadline-aware escalation bumps a starved source's effective band (D-BAND / D-DDL) | [pic.v](hdl/pic.v) |
| D21 | Preemption with a nesting stack (depth ≤ `NEST_MAX`): `cpu_irq_ack` claims/pushes, `cpu_irq_eoi` returns/pops; a source that deasserts before its claim is flagged spurious + logged, never corrupts the stack (D-NEST / D-SPUR) | [pic.v](hdl/pic.v) |
| D22 | Full register map (SRCx_CONFIG/SW_TRIG/STATUS, BAND_CONFIG, NEST_STATUS/MAX, ACTIVE_VEC, SPURIOUS_LOG, ESCALATION_CFG, INT_ENABLE/STATUS); keyed software triggers; unmapped or read-only-write access answers SLVERR (D-SW / D-AXI) | [pic.v](hdl/pic.v) |
| D23 | WFI (Priv. spec 3.3.3): S2 sleeps, S1 parks → zero ibus traffic; wake on any mie-enabled pending irq, `mstatus.MIE` decides trap-vs-fall-through; interrupt wake sets mepc = wfi+4 | [control.v](hdl/control.v), [cpu_top.v](hdl/cpu_top.v), [hazard_unit.v](hdl/hazard_unit.v) |
| D24 | Return-address stack (8 entries, parameterized, 0 = off): calls/returns keyed on the ISA JALR hint regs (x1/x5); BTB entries tagged `is_ret` predict the RAS top; learned at commit like the BTB (never speculative) | [branch_predictor.v](hdl/branch_predictor.v) |
| D25 | `mhpmcounter3..7`: mispredicts, fetch-starved cycles, dbus stall cycles, traps taken, WFI sleep cycles — the CPU-side numbers that pair with DP-SRAM BANDWIDTH_A/B and DMA throttling. All counters are 64-bit with an upper half at base+0x80 and writable from M-mode (Priv. 3.1.11); the counters not provided are hardwired zero, not unimplemented | [csr_file.v](hdl/csr_file.v) |
| D26 | Machine timer (unassigned in the briefs): 64-bit mtime/mtimecmp, level irq = compare, born disarmed; handler clears by moving mtimecmp — feeds PIC source 7 | [mtimer.v](hdl/mtimer.v) |
| D27 | mtimer AXI4-Lite slave port, same discipline as the PIC's (D-AXI): 4 R/W word registers, SLVERR elsewhere, WSTRB honored per lane | [mtimer.v](hdl/mtimer.v) |

## AXI4-Lite interface (SoC integration)

Both ports are conformant AXI4-Lite masters — no proprietary extensions — so the
DMA config port and DP-SRAM Port A see a standard master.

- `ibus_axi` — read only (AR/R), instruction fetch.
- `dbus_axi` — read + write (AW/W/B/AR/R), load/store, `WSTRB` per byte lane (REQ11).
- One outstanding transaction per port; the FSMs split per channel, so a later
  move to AXI4-Full (bursts, IDs) stays additive, not a rewrite (D6, D12).
- All three response codes handled (REQ12): OKAY, plus SLVERR/DECERR → precise
  access-fault traps (D8, D18). DP-SRAM only emits OKAY/SLVERR; DECERR comes
  from the interconnect on an unmapped address — the CPU covers both.

## Interrupts (PIC)

The PIC implements the *Programmable Interrupt Controller with Advanced
Scheduling* brief ([pic/](pic/)): 16 hardware sources + 16 software channels
(32 logical sources), custom priority grouping, preemption with nesting,
spurious detection, deadline-aware escalation, and software-triggered
interrupts. Full design in [pic.v](hdl/pic.v) and [ARCHITECTURE.md](ARCHITECTURE.md) §5.

The CPU side: `cpu_irq` in (single level request), `cpu_irq_vec[3:0]` in (id of
the offered source), `cpu_irq_ack` out (1-cycle claim pulse at handler entry),
`cpu_irq_eoi` out (1-cycle pulse on an interrupt-returning MRET). A source maps
to mcause `16+vec`; the CPU builds a one-hot `mip[16+vec]` from the offer, and
`mie[16+vec]` is the per-source CPU enable. An irq is taken only at an
instruction boundary, only under `mstatus.MIE`, held through a multi-cycle AXI
stall (REQ4; priority D2).

The PIC side (D19–D22): a slot's request is `(level ? irq_src : edge_latch |
sw) & INT_ENABLE`. The resolver builds an effective priority key
`{band_urgency, intra_priority, ~index}` per source and offers the most urgent
one that is strictly above the top of the nesting stack, so a higher source
**preempts** a lower one; `cpu_irq_ack` pushes it (claim), `cpu_irq_eoi` pops it
(return). A source whose deadline elapses before it is serviced has its band
**escalated** (`ESCALATION_CFG`). A source that deasserts before its claim is
flagged **spurious** (`SPURIOUS_LOG`, `INT_STATUS.SPUR`) without corrupting the
stack. Software injects an interrupt with a keyed `SRCx_SW_TRIG` write. Everything
is programmed over an AXI4-Lite slave port (register map in ARCHITECTURE.md §5);
unmapped words and read-only writes answer SLVERR. The PIC's `INT_ENABLE` and the
CPU's `mie` are two independent masks: a source PIC-enabled but `mie`-masked sits
as the PIC's offer forever and starves the rest, so route a source into the PIC
only if some handler will service it.

The timer ([mtimer.v](hdl/mtimer.v), D26/D27) sits on PIC source 7:
64-bit `mtime`/`mtimecmp` behind an AXI4-Lite slave port, level irq while
`mtime >= mtimecmp`, disarmed at reset. With WFI (D23) it gives the SoC an
idle mode: program the DMA, arm the timer as a deadline, execute WFI. The CPU
stops fetching while the DMA works; either the completion interrupt or the
timer wakes it. A timeout handler can abort a stuck DMA channel over
`CHx_CONTROL`.

## Multi-core

Nothing shared between instances: no static state, memories external, identity
only from the `HART_ID`/`RESET_PC` parameters (D5). Two or more cores work
behind a standard AXI interconnect. RV32I has no LR/SC, but each core is
in-order with blocking memory ops (sequentially consistent per hart), so
flag-based sharing through memory is sound — the same property the SoC's
ping-pong buffering relies on. `debug/hdl/tb_dual_core.v` shows two cores
sharing one memory through an arbiter.

## Layout

```
hdl/
  cpu_top.v            top level: pipeline + AXI + PIC          (REQ1-4; D1,D2,D4,D5)
  fetch_unit.v         S1: PC + ibus master + holding/redirect  (REQ5,12; D6-D8)
  branch_predictor.v   BTB/BHT                                  (REQ8; D9-D11)
  lsu.v                S2: dbus master, alignment + WSTRB       (REQ5,11,12; D12)
  hazard_unit.v        centralized stall/flush/forwarding       (REQ6; D13,D14)
  control.v            decoder (RV32I, FENCE=NOP, SYSTEM)       (REQ7)
  csr_file.v           M-mode CSRs + trap/MRET sequencing       (REQ9; D3,D5,D15,D16)
  exception_unit.v     sync exception detect                    (D3,D17,D18)
  pic.v                advanced-scheduling interrupt controller (D19-D22)
  mtimer.v             machine timer, AXI4-Lite + irq to PIC 7  (D26,D27)
  axi_lite_slave.v     reusable AXI4-Lite register interface (shared by pic/mtimer)
  regfile.v            32x32 register file                      (REQ10)
  branch_unit.v        real branch/jump direction + target
  decode.v  imm_gen.v  alu.v  alu_top.v  writeback_mux.v   (reused, combinational)
debug/
  VERIFICATION.md      test plan: what is checked, why, and known gaps
debug/sva/
  axi_lite_sva.sv      AXI4-Lite contract as SVA (per port: ibus/dbus/PIC)
  cpu_core_sva.sv      pipeline invariants as SVA (REQ4,10,11; D2,D3,D12)
  pic_sva.sv           PIC invariants as SVA (D-LAT/D-BAND/D-NEST)
  cpu_func_cov.sv      functional coverage bins + end-of-run [FCOV] table
  bind_sva.sv          attaches everything with bind - zero RTL edits
debug/hdl/
  tb_cpu_axi.v         self-checking TB: CPU + real PIC @ 0x3000_0000 + AXI
                       memories + monitors; the TB plays the peripherals
  tb_pic.v             standalone PIC feature bench: bands, nesting, spurious,
                       deadline escalation, software triggers, AXI responses
  tb_dual_core.v       2 CPUs + shared memory behind an arbiter (scalability proof)
  axi_lite_monitor.v   passive AXI4-Lite protocol checker (ibus, dbus, PIC port)
  axi_lite_mem_model.v behavioral AXI4-Lite slave (OKAY/DECERR, latency + seeded
                       random READY backpressure)
  axi_lite_arb2.v      2:1 AXI4-Lite arbiter (TB stand-in for the interconnect)
  axi_lite_dec2.v      1-master/2-slave address decoder (TB interconnect for
                       the PIC window)
  ck_rst_tb.v          clock/reset generator (async reset, released at 123 ns)
  tb_check.vh          shared self-check task (=== compare, PASS/FAIL per check)
  axi_lite_macros.vh   bare AXI read/write helper macros shared by the benches
debug/sim/
  program_axi.s        main test program   (py asm.py program_axi.s program_axi.hex)
  program_dual.s       dual-core handshake (py asm.py program_dual.s program_dual.hex)
  asm.py               tiny RV32I assembler (range-checked imms, %hi/%lo, .org)
  rtl.f  tb_cpu.f      shared filelists — one module list for both flows
  compile.do           the single canonical vlog compile both .do scripts use
  soc_map.vh           TB address map (PIC / mtimer / dmem bases) in one place
  sim.do               quick single run     regress.do  full 6-run regression
  wave.do              AXI-grouped waveform set for the ModelSim GUI
  run_verilator.sh     SVA + functional coverage run (Verilator, free)
  run_verilator.ps1    same, one command from Windows (via WSL)
  verif_gui.py         tkinter front-end that launches the flows and shows
                       PASS/FAIL per job (no ModelSim/Verilator CLI needed)
```

## Simulation

```
cd debug/sim
vsim -c -do "do regress.do; quit -f"      # full regression (6 runs: 4 single-core
                                          # configs + dual-core + tb_pic)
vsim -c -do "do sim.do; quit -f"          # quick single run; drop -c for GUI

.\run_verilator.ps1                       # SVA + functional coverage —
                                          # ModelSim ASE has neither, so the
                                          # debug/sva layer runs on Verilator

py verif_gui.py                           # same flows behind a small GUI
```

Both flows are **lint- and warning-clean**: the ModelSim compile reports
`Errors: 0, Warnings: 0` for RTL, TB and SVA, and Verilator's default warning
set is empty (every file carries its own `` `timescale ``, so the result does not
depend on filelist order, and every width is explicit).

The SVA layer found a real bug on its first run: the fetch unit drove
`ARVALID` during reset (the issue logic is combinational, requested `RESET_PC`
while `rst_n` was still low), which the AXI spec forbids. The procedural
monitor missed it — it only arms after reset. One-line fix in
[fetch_unit.v](hdl/fetch_unit.v); details in
[debug/VERIFICATION.md](debug/VERIFICATION.md).

Test plan and results: [debug/VERIFICATION.md](debug/VERIFICATION.md). Short
version: every mcause exercised with exact trap counting (every PIC source
except the deliberately-masked one), CSR negative tests, PIC priority /
in-service suppression / double masking / SLVERR negatives, an interrupt held
through an AXI stall, BTB aliasing, RAS call/return nesting, WFI wake both ways
with the instruction bus checked silent, the mtimer end to end, CPI = 1.00 on a
latency-1 memory, protocol monitors on all four AXI ports, seeded random
backpressure, the dual-core handshake. The standalone `tb_pic.v` then drives the
PIC's advanced features directly — priority bands, preemptive nesting, spurious
detection, deadline escalation, keyed software triggers, AXI error responses.
Functional coverage: 88/92 bins hit; the four misses are the two intentional ch5
negatives and the two backpressure bins the regression configs cover instead of
the default run.

## Open points (system level)

- Global memory map undecided — the reset vector is the `RESET_PC` parameter
  (default 0x0); PIC / mtimer bases are TB decoder parameters (0x3000_0000 /
  0x3001_0000 for now).
- The PIC implements the *Advanced Scheduling* brief ([pic/](pic/)); the
  quantitative choices it delegates to the intern (4 bands, `NEST_MAX` default 8,
  16-bit deadlines, jump-to-band escalation, the `0xA5A5` software key, exact
  register offsets) are documented in [pic.v](hdl/pic.v)/[ARCHITECTURE.md](ARCHITECTURE.md)
  and open to confirm with the team/mentor. The mtimer has no spec of its own
  (D26–D27), same status.
  Source-to-channel mapping: DMA 0..3, DP-SRAM 4, mtimer 7; 5–6 free.
- Reset type differs between blocks (CPU/DMA async, DP-SRAM sync).
- With more than one core, "which PIC channel targets which core" is undefined
  — the current PIC serves one CPU; each core would want its own mtimer compare.
