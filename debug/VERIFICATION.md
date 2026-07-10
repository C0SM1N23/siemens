# CPU verification plan & evidence

Verification strategy for the RV32I 3-stage pipeline CPU. Target is behavioral
RTL simulation in ModelSim, plain Verilog — no vendor IP, no UVM (not available
in the free edition), so the methodology leans on five pillars:

1. **Self-checking directed program** (`sim/program_axi.s`): every
   architectural feature is driven end-to-end through real instruction
   sequences; results land in registers and a dmem scoreboard checked by the
   TB. Trap handling is verified by *using* it (handlers dispatch on mcause,
   fix mepc, return), not by poking signals.
2. **Exact-count properties**: the sync-trap handler counts every entry
   (must be exactly 15) and x29 accumulates one bit per cause (must be
   exactly 0x1FF). A missing trap, a double trap, or a spurious one cannot
   cancel out — order-independent and airtight against "it passed by luck".
3. **Passive protocol monitors** (`hdl/axi_lite_monitor.v`) on both AXI
   master buses and on the PIC's slave port, every run: VALID/payload
   stability under stalled READY, response ordering, the CPU's 1-outstanding
   contract, X hygiene, no EXOKAY. Protocol legality is a checked property,
   not an assumption.
4. **Configuration sweep** (`sim/regress.do`): the same suite runs under
   default latencies, high fixed latencies, and seeded random READY
   backpressure (reproducible by seed), plus the dual-core TB. Each run
   echoes its parameters read back from the elaborated design, because we
   learned the hard way that a silently-ignored override looks exactly like
   a pass.
5. **SVA assertions + functional coverage** (`sva/`, run by
   `sim/run_verilator.sh`): the same contracts written as concurrent SVA
   properties, plus a measured functional-coverage table — run through
   Verilator (free, open source) because ModelSim ASE compiles neither.
   Everything is attached with `bind`; the RTL and the testbench see nothing.

## How to run

```
cd debug/sim
py asm.py program_axi.s  program_axi.hex    # only after editing a program
py asm.py program_dual.s program_dual.hex
vsim -c -do "do regress.do; quit -f"        # full 5-config regression
vsim -c -do "do sim.do; quit -f"            # quick single run

bash run_verilator.sh                       # SVA + functional coverage (Linux/WSL)
.\run_verilator.ps1                         # same, one command from Windows
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
| D3 | Every sync cause: 0,1,2,3,4,5,6,7,11 | trap table complete, mepc per cause | x29 = 0x1FF, trap count = 15, handler returns resume execution |
| REQ7,D3 | Illegal instruction has **no side effects** | an illegal store must not reach the bus | `.word 0x04D73023` targets dmem[64]; word must stay 0 (this check caught a real RTL bug) |
| D17 | Misaligned access issues **no** AXI transaction | must trap before issuing any transaction | LH/SH @odd trap cause 4/6; dmem[0] untouched; monitors see no extra transaction |
| D8,D18 | SLVERR/DECERR on fetch/load/store -> mcause 1/5/7 | bus errors must be precise traps | jumps/accesses into unmapped space; cause-1 handler resumes via mscratch (its intended purpose) |
| REQ9,D15 | CSRRW/S/C + immediate forms; read-only CSR write and unimplemented CSR -> illegal; CSRRS x0 = pure read | CSR access rules, incl. negatives | mscratch round-trip 21/31; csrrs 0x7C0, csrrw mip/mhartid all trap; csrrs mip with x0 does *not* trap |
| D16 | Vectored mtvec: irq -> BASE+4*cause, exception -> BASE | the two vectored paths differ | irq lands at 0x348 slot (cause 18); ecall in vectored mode records at BASE |
| REQ4 | irq sampled only under MIE, only enabled channels, held through AXI stalls, taken at instruction boundaries | the CPU side of the PIC contract | src5 pending whole run, never acked; ch2 raised mid-load: ack timestamp > R-beat timestamp, mepc = boundary instruction, load value intact |
| REQ4 | ack = 1-cycle pulse on the right bit; cpu_in_trap spans entry..MRET | PIC handshake shape | pulse-width invariant, ack counts (ch2=2, ch3=1) = handler entry count (3), in_trap sampled in handler and after |
| D20 | PIC priority: two channels pending together are served lowest-first | "highest-priority pending" must be deterministic | src2+src3 raised in the same cycle: ack2 timestamp < ack3 timestamp; per-cycle invariant `cpu_irq_id` = lowest set `cpu_irq` bit |
| D21 | In-service suppression: an acked channel with its line still high disappears from `cpu_irq` until MRET | a handler that re-enables MIE must not be re-entered by its own interrupt | src3 held high through its whole handler; invariant checks `cpu_irq[3]`=0 in that window; ack3 count stays 1 |
| D19,D22 | PIC software interface: ENABLE write+readback, RAW/PENDING/ACTIVE reads; PIC enable and `mie` are independent masks | the programmable half of the PIC, over real AXI | scoreboard: ENABLE=0x2C, RAW=PENDING=0x20 (src5), ACTIVE=0x04 read *inside* the handler; ch5 visible in mip yet never taken |
| D22 | Unmapped PIC register read and read-only register write answer SLVERR -> precise access faults | error responses from a real peripheral, not just the TB model | both accesses trap (causes 5 and 7, counted in the exact 15); PIC-port monitor stays clean |
| REQ10 | x0 hardwired, regfile reset | | `addi x0,x0,5` then read; regs[0] === 0 |
| D23 | WFI: sleep until wake, ibus silent, mepc = wfi+4 on an interrupt wake, fall-through (no trap) when MIE=0 | the CPU must idle without burning interconnect bandwidth the DMA needs | timer irq wakes the first WFI (mepc readback = wfi+4); second WFI with MIE=0 falls through to a marker store with the handler-entry count unchanged; TB measures ≤1 ibus read per sleep window + SVA `wfi_ibus_quiet` |
| D24 | RAS: returns from 3 different call sites + a nested call chain (h→g→g) predict correctly and stay correct | the BTB's last-target scheme is systematically wrong for returns; the RAS may only change *time*, never results | accumulated signature 0x243 checked; FCOV separates returns predicted correctly vs mispredicted (first encounters only) |
| D25 | mhpmcounter3..7 count mispredicts / fetch-starved / dbus-stall / traps / WFI cycles; writes to them trap | the CPU-side observability numbers for tuning DMA throttling | end-of-run readbacks: traps exactly 24 (15 direct + 1 vectored + 8 irq), the latency-dependent ones nonzero; RO-write trap covered by the existing mcycle negative |
| D26,D27 | mtimer end to end: disarmed at reset, armed CMP_LO-then-CMP_HI without false fires, level irq through PIC ch7, handler clears by moving mtimecmp, unmapped offset SLVERR | the timer is a real peripheral on a real bus — and the WFI wake source | timer irq taken exactly once (ack7 = 1, cause 23 vectored slot), mtime monotonic readback, mtimer port protocol monitor + SVA clean |
| D20 | Channel sweep: ch0/1/4/6 each raised once and served; ch5 PIC-disabled first because a mie-masked pending source pins `cpu_irq_id` and starves lower-priority channels | the starvation discipline every peripheral hookup must respect | one ack per swept channel, handler-entry count exactly 8, ack5 still never seen |
| D6 | Back-to-back fetch: 1 instr/cycle on a latency-1 memory | the throughput claim, measured not asserted | mcycle delta across 33 straight-line instrs = 33 (gated to the latency-1 config) |
| REQ2,REQ12 | AXI4-Lite legality on both master ports | interoperability with DMA/DP-SRAM | protocol monitors, all runs, all configs |
| D5 | 2 cores + shared memory via arbiter, mhartid split, flag handshake | "2-3 cores in a bigger SoC" | `tb_dual_core`: flags + both results + clean shared bus |

## SVA + functional coverage (the Verilator flow)

ModelSim ASE has no SVA and no coverage, so this layer lives in `debug/sva/`
and runs the same `tb_cpu_axi` through Verilator
(`--timing --assert --coverage`, plus `sim_main.cpp` to dump the coverage
database). Nothing is edited to attach it — `bind_sva.sv` binds the checkers
into `cpu_top` and `pic`, so every instance (dual-core included) gets them:

- `axi_lite_sva.sv` — the AXI4-Lite contract as concurrent properties, one
  instance per port (ibus, dbus, PIC slave): VALID/payload stability under a
  stalled READY, R-only-after-AR / B-only-after-AW+W ordering, the
  ≤1-outstanding claim (D6, D12), legal response codes (no EXOKAY), VALID
  low during reset, word-aligned fetch addresses. Cover properties record
  backpressure and error-response events for `verilator_coverage`.
- `cpu_core_sva.sv` — pipeline promises as properties: ack one-hot and
  one-cycle (REQ4), interrupts only at instruction boundaries (D2), trap
  entry raises `cpu_in_trap` / MRET drops it, a trapping instruction never
  commits (D3), a stalled S2 feeds S3 bubbles, x0 reads zero (REQ10), WSTRB
  only ever carries an SB/SH/SW lane shape (REQ11), never read+write at
  once on the dbus (D12).
- `pic_sva.sv` — the PIC contract (D19–D21): `cpu_irq` equals the registered
  gated pending vector (compared against a same-edge shadow register, so a
  TB that moves `irq_src` right after the clock edge cannot race the check),
  id points at the lowest pending channel, ack lands in the in-service mask,
  an in-service channel stays out of `cpu_irq`, MRET releases the mask.
- `cpu_func_cov.sv` — functional coverage: instruction classes, load/store
  sizes, each branch × taken/not-taken, predictor outcome matrix, every
  trap cause, CSR op forms, forwarding paths, irq scenarios, per-channel
  acks, bus response/backpressure bins. Prints the `[FCOV]` table with a
  hit/MISS verdict per bin and a summary percentage at end of run.

Current evidence: **all 86 TB checks pass under Verilator, zero assertion
violations, 88/92 functional bins hit (95%)**. The first measurement of this
table (59/85) exposed real test-plan holes — AUIPC never committed,
BLT/BGE/BLTU/BGEU and CSRRCI never executed, both-operand forwarding never
hit, PIC channels 0/1/4/6/7 never taken — and `program_axi.s` now covers all
of them. The four remaining MISS bins are deliberate: the two ch5 negatives
(a masked channel must never trap or ack — that *is* the test) and the two
AR-backpressure bins the regress.do random-READY configs exercise instead of
the default run.

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

- **RTL (found by the SVA layer on its first run)**: the fetch unit drove
  `ARVALID` high *during reset* — `issue_now` is combinational free-slot
  logic and asks for `RESET_PC` while `rst_n` is still low. AXI forbids it
  (IHI0022E A3.1.2: VALID low in reset), and a slave whose READY is high in
  reset would accept a phantom address. Invisible to the procedural monitor,
  which arms only after reset. Fixed by gating `ibus_arvalid` with `rst_n`.
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
- Functional coverage is measured by the Verilator flow: 88/92 bins. The
  holes its first run exposed (AUIPC, the four missing branches, CSRRCI,
  both-operand forwarding, five untaken PIC channels) are closed; the four
  remaining misses are deliberate (ch5 negatives, backpressure covered by
  the regress configs).
- RAS depth is a parameter (8, 0 = off); a regress config sweeping it would
  quantify the return-mispredict win on a bigger program.
- The PIC is now the real `pic.v`, exercised in-system (the TB plays the
  peripherals on `irq_src`); a standalone PIC unit bench with randomized
  line movement would still add value, esp. many channels toggling at once.
- Nested interrupt handlers (a handler that sets MIE=1 and takes a *different*
  channel) are not exercised; the PIC's in-service clear is tied to the single
  `cpu_in_trap` bit, so nesting is documented as out of scope (D21).
- The dbus decoder covers 2 slaves; richer fabrics (more slaves, DECERR from
  the fabric's own decoder) come with the real interconnect.
- Reset assertion mid-transaction is not exercised (models and CPU reset
  together); relevant once the SoC defines its reset controller.
