# RISC-V RV32I CPU — 3-stage pipeline with AXI4-Lite

The CPU block of the SoC project (CPU + DMA + DP-SRAM), in Verilog
(IEEE 1364-2005). The original single-cycle core became a 3-stage pipeline with
two AXI4-Lite master ports, a branch predictor, precise traps, an M-mode CSR
file, and a PIC interrupt interface.

## Architecture

```
S1 FETCH ──────────── S2 DECODE + EXECUTE ─────────── S3 WRITEBACK
ibus_axi (AR/R)       decode, regfile, ALU, branch,    rd write
+ branch predictor    CSR, load/store on dbus_axi      (S3->S2 forwarding)
  (BTB/BHT, 128)      traps/interrupts resolve here
```

One clock, async active-low reset. The pipeline registers carry a `valid` bit,
so a flushed or reset stage is a guaranteed no-op. Load-use hazards are covered
by S3→S2 forwarding (no stall), and the two AXI ports are independent with one
outstanding transaction each, so a fetch and a load/store overlap.

## Spec requirements vs. design decisions

The project brief separates two kinds of item, and so does this repo:

- **Spec requirements** (`REQ#`) — behavior the brief fixed. These are
  implemented *to spec*; there was no choice to make, only to match it.
- **Design decisions** (`D#`) — the points the brief explicitly left "for the
  intern to define." Each is a deliberate choice with a rationale.

Both are tagged in the code (grep `REQ` or `D<n>`) and the file header explains
each in full. These two tables are the index.

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
| D3  | Supported mcause set 0,1,2,3,4,5,6,7,11 + external interrupts on 8 PIC channels (causes 16..23) | [exception_unit.v](hdl/exception_unit.v), [csr_file.v](hdl/csr_file.v) |
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

## AXI4-Lite interface (SoC integration)

Both ports are conformant AXI4-Lite masters — no proprietary extensions — so the
DMA config port and DP-SRAM Port A see a standard master.

- `ibus_axi` — read only (AR/R), instruction fetch.
- `dbus_axi` — read + write (AW/W/B/AR/R), load/store, `WSTRB` per byte lane (REQ11).
- One outstanding transaction per port; the FSMs are split per channel so a
  later move to AXI4-Full (bursts, IDs) is additive rather than a rewrite (D6, D12).
- All three response codes are handled (REQ12): OKAY, plus SLVERR/DECERR →
  precise access-fault traps (D8, D18). DP-SRAM only emits OKAY/SLVERR; DECERR
  comes from the interconnect on an unmapped address — the CPU covers both.

## Interrupts (PIC interface)

`cpu_irq[7:0]` in, `cpu_irq_id[2:0]` in (highest-priority pending channel),
`cpu_irq_ack[7:0]` out (1-cycle pulse), `cpu_in_trap` out (held until MRET).
Channels map to mcause 16..23; `mip[16+i]` mirrors `cpu_irq[i]`, `mie[16+i]`
enables. An irq is taken only at an instruction boundary, only under
`mstatus.MIE`, and is held through a multi-cycle AXI stall (REQ4; priority D2).

## Multi-core

Nothing is shared between instances: no static state, memories are external,
and identity comes only from the `HART_ID`/`RESET_PC` parameters (D5). Two or
more cores work behind a standard AXI interconnect. RV32I has no LR/SC, but each
core is in-order with blocking memory ops (sequentially consistent per hart), so
flag-based sharing through memory is sound — the same property the SoC's
ping-pong buffering relies on. `debug/hdl/tb_dual_core.v` demonstrates two cores
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
  regfile.v            32x32 register file                      (REQ10)
  branch_unit.v        real branch/jump direction + target
  decode.v  imm_gen.v  alu.v  alu_top.v  writeback_mux.v   (reused, combinational)
debug/
  VERIFICATION.md      test plan: what is checked, why, and known gaps
debug/hdl/
  tb_cpu_axi.v         self-checking TB: CPU + 2 AXI slaves + monitors + PIC stub
  tb_dual_core.v       2 CPUs + shared memory behind an arbiter (scalability proof)
  axi_lite_monitor.v   passive AXI4-Lite protocol checker (both buses, every run)
  axi_lite_mem_model.v behavioral AXI4-Lite slave (OKAY/DECERR, latency + seeded
                       random READY backpressure)
  axi_lite_arb2.v      2:1 AXI4-Lite arbiter (TB stand-in for the interconnect)
  ck_rst_tb.v          clock/reset generator
debug/sim/
  program_axi.s        main test program   (py asm.py program_axi.s program_axi.hex)
  program_dual.s       dual-core handshake (py asm.py program_dual.s program_dual.hex)
  asm.py               tiny RV32I assembler (range-checked imms, %hi/%lo, .org)
  sim.do               quick single run     regress.do  full 5-config regression
```

## Simulation

```
cd debug/sim
vsim -c -do "do regress.do; quit -f"      # full regression (5 configs)
vsim -c -do "do sim.do; quit -f"          # quick single run; drop -c for GUI
```

Coverage, per-case reasoning and the evidence trail are in
[debug/VERIFICATION.md](debug/VERIFICATION.md): every mcause exercised with
exact trap counting, CSR negative tests, interrupt masking and an interrupt held
through an AXI stall, BTB aliasing, measured CPI = 1.00 on a latency-1 memory,
AXI protocol monitors on every run, seeded random backpressure, and the
dual-core handshake.

## Open points (system level)

- Global memory map undecided — the reset vector is the `RESET_PC` parameter (default 0x0).
- PIC has no spec of its own — the CPU-side interface is fixed; the TB uses a stub.
- Reset type differs between blocks (CPU/DMA async, DP-SRAM sync).
