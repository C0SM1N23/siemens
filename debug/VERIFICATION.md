# CPU verification plan & evidence

Verification strategy for the RV32I 3-stage pipeline CPU. Target is behavioral
RTL simulation in ModelSim, plain Verilog — no vendor IP, no UVM (not available
in the free edition), so the methodology leans on four pillars:

1. **Self-checking directed program** (`sim/program_axi.s`): every
   architectural feature is driven end-to-end through real instruction
   sequences; results land in registers and a dmem scoreboard checked by the
   TB. Trap handling is verified by *using* it (handlers dispatch on mcause,
   fix mepc, return), not by poking signals.
2. **Exact-count properties**: the sync-trap handler counts every entry
   (must be exactly 13) and x29 accumulates one bit per cause (must be
   exactly 0x1FF). A missing trap, a double trap, or a spurious one cannot
   cancel out — order-independent and airtight against "it passed by luck".
3. **Passive protocol monitors** (`hdl/axi_lite_monitor.v`) on both AXI
   buses, every run: VALID/payload stability under stalled READY, response
   ordering, the CPU's 1-outstanding contract, X hygiene, no EXOKAY.
   Protocol legality is a checked property, not an assumption.
4. **Configuration sweep** (`sim/regress.do`): the same suite runs under
   default latencies, high fixed latencies, and seeded random READY
   backpressure (reproducible by seed), plus the dual-core TB. Each run
   echoes its parameters read back from the elaborated design, because we
   learned the hard way that a silently-ignored override looks exactly like
   a pass.

## How to run

```
cd debug/sim
py asm.py program_axi.s  program_axi.hex    # only after editing a program
py asm.py program_dual.s program_dual.hex
vsim -c -do "do regress.do; quit -f"        # full 5-config regression
vsim -c -do "do sim.do; quit -f"            # quick single run
```

Pass criterion: every run ends in `ALL TESTS PASSED` / `DUAL-CORE TEST
PASSED`, zero `FAIL:` lines, monitor error counters zero.

## Test plan

The "Area" column links each test to the spec requirement (`REQ#`) or design
decision (`D#`) it exercises — the same tags used in the README index and the
code.

| Area | Behavior under test | Why it matters | Checked by |
|------|--------------------|----------------|------------|
| REQ7 | All ISA groups incl. FENCE=NOP | baseline correctness | x1..x22 checks, minstret sane |
| D13 | S3->S2 forwarding into every consumer (ALU, branch, address, store data, CSR wdata) | load-use must cost 0 cycles and stay correct | dependent chains in phase A; CPI window |
| REQ11 | WSTRB lanes + load extract for SB/SH/SW/LB(U)/LH(U) | DP-SRAM compatibility contract | dmem word checks + sign/zero-extend reg checks |
| REQ8,D9-D11 | Predictor learns taken loops; not-taken default; alias eviction stays correct | predictor may only affect *time*, never results | BNE loop sum; 3 branches sharing index 0x12 with different tags (0x448/0x648/0x848), sum = 18 |
| D7 | Mispredict recovery incl. JALR, rd==rs1 | link write must use pre-jump value, 1-cycle flush path | JAL/JALR round-trip; `jalr x30,x30` link check; skipped-word poison jumps to a hang loop |
| D3 | Every sync cause: 0,1,2,3,4,5,6,7,11 | trap table complete, mepc per cause | x29 = 0x1FF, trap count = 13, handler returns resume execution |
| REQ7,D3 | Illegal instruction has **no side effects** | an illegal store must not reach the bus | `.word 0x04D73023` targets dmem[64]; word must stay 0 (this check caught a real RTL bug) |
| D17 | Misaligned access issues **no** AXI transaction | must trap before issuing any transaction | LH/SH @odd trap cause 4/6; dmem[0] untouched; monitors see no extra transaction |
| D8,D18 | SLVERR/DECERR on fetch/load/store -> mcause 1/5/7 | bus errors must be precise traps | jumps/accesses into unmapped space; cause-1 handler resumes via mscratch (its intended purpose) |
| REQ9,D15 | CSRRW/S/C + immediate forms; read-only CSR write and unimplemented CSR -> illegal; CSRRS x0 = pure read | CSR access rules, incl. negatives | mscratch round-trip 21/31; csrrs 0x7C0, csrrw mip/mhartid all trap; csrrs mip with x0 does *not* trap |
| D16 | Vectored mtvec: irq -> BASE+4*cause, exception -> BASE | the two vectored paths differ | irq lands at 0x348 slot (cause 18); ecall in vectored mode records at BASE |
| REQ4 | irq sampled only under MIE, only enabled channels, held through AXI stalls, taken at instruction boundaries | the PIC contract | ch5 pending whole run, never acked; ch2 raised mid-load: ack timestamp > R-beat timestamp, mepc = boundary instruction, load value intact |
| REQ4 | ack = 1-cycle pulse on the right bit; cpu_in_trap spans entry..MRET | PIC handshake shape | pulse-width invariant, ack count = 2 = handler entry count, in_trap sampled in handler and after |
| REQ10 | x0 hardwired, regfile reset | | `addi x0,x0,5` then read; regs[0] === 0 |
| D6 | Back-to-back fetch: 1 instr/cycle on a latency-1 memory | the throughput claim, measured not asserted | mcycle delta across 33 straight-line instrs = 33 (gated to the latency-1 config) |
| REQ2,REQ12 | AXI4-Lite legality on both master ports | interoperability with DMA/DP-SRAM | protocol monitors, all runs, all configs |
| D5 | 2 cores + shared memory via arbiter, mhartid split, flag handshake | "2-3 cores in a bigger SoC" | `tb_dual_core`: flags + both results + clean shared bus |

## Performance evidence

CPI = 1.00 measured (33 cycles / 33 straight-line instructions) with a
latency-1 instruction memory. The only remaining stalls are the unavoidable
ones: blocking load/store round-trips and the 1-cycle mispredict bubble. The
1-bit predictor and ≤1 outstanding transaction per port are fixed design
choices (REQ8, D12), so this is the performance ceiling of this design.

## Multi-core reasoning

Nothing in the core is shared between instances (no static state, memories
private to each instance, all identity via the `HART_ID`/`RESET_PC`
parameters), both bus ports are standard AXI4-Lite masters an interconnect
can arbitrate, and `mhartid` gives software its identity. RV32I has no
LR/SC, but each core executes memory ops in order and blocking (one
outstanding, no store buffer) — i.e. sequentially consistent — so flag/
Peterson-style protocols through shared memory are sound. That is the same
property the SoC's ping-pong buffering relies on. `tb_dual_core`
demonstrates it end to end.

## Bugs this flow has caught (why the method earns its keep)

- **RTL**: illegal load/store encodings issued their AXI transaction before
  trapping — an illegal store could write memory. Caught by the
  illegal-store scoreboard check; fixed by gating `lsu_req` with the
  decoder's `illegal`.
- **Testware**: the assembler silently truncated a label immediate
  (`addi` limit is ±2048); now it range-checks and supports `%hi/%lo`.
- **Testware**: the memory model couldn't do latency-1 reads, so the CPI
  check measured the model, not the CPU. The model got a true latency-1
  fast path.
- **Infrastructure**: `-g` parameter overrides were silently swallowed by
  vopt folding — one regression config ran at defaults while reporting
  green. Switched to `-G` + per-run parameter echo.

## Known gaps / next steps

- No riscv-arch-test / random instruction streams — the directed program is
  broad but hand-picked. Next step once toolchain access exists.
- No functional coverage metrics (not supported by ModelSim ASE); the
  test-plan table above is the manual coverage argument.
- PIC is stubbed to the interface contract (REQ4); re-verify against the real
  PIC when it exists, esp. `cpu_irq_id` changing while lines move.
- Interconnect behaviors beyond 1 slave per bus (out-of-order completion is
  N/A for AXI4-Lite, but multi-slave decode/DECERR paths come from the real
  fabric).
- Reset assertion mid-transaction is not exercised (models and CPU reset
  together); relevant once the SoC defines its reset controller.
