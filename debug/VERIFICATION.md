# CPU verification plan & evidence

Verification strategy for the RV32I 3-stage pipeline CPU. Target: behavioral RTL
simulation in ModelSim, plain Verilog — no vendor IP, no UVM (not in the free
edition) — so the methodology leans on five pillars:

1. **Self-checking directed program** (`sim/program_axi.s`): every
   architectural feature is driven end-to-end through real instruction
   sequences; results land in registers and a dmem scoreboard checked by the
   TB. Trap handling is verified by *using* it (handlers dispatch on mcause,
   fix mepc, return), not by poking signals.
2. **Exact-count properties**: the direct-mode sync-trap handler counts
   every entry (must be exactly 17) and x29 accumulates one bit per cause
   (must be exactly 0x1FF); the hardware `mhpmcounter6` independently counts
   every trap entry of any kind (must be exactly 26 = 17 direct + 1 vectored
   + 8 irq). A missing trap, a double trap, or a spurious one cannot cancel
   out — order-independent and airtight against "it passed by luck".
3. **Passive protocol monitors** (`hdl/axi_lite_monitor.v`) on both AXI
   master buses and on the PIC and mtimer slave ports, every run:
   VALID/payload stability under stalled READY, response ordering, the CPU's
   1-outstanding contract, X hygiene, no EXOKAY. Protocol legality is a
   checked property, not an assumption.
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

All commands run from `debug/sim` (the .do scripts, filelists and hex live
there). ModelSim is the primary flow; Verilator adds the SVA + coverage layer.
Run only one `vsim` at a time — they share `work/` and a second one blocks on
`work/_lock`; if a run was killed, clear a stale lock with `rm work/_lock`.

**Prep — only after editing a `.s` program** (Windows shell: PowerShell / cmd /
git-bash). Regenerates the hex image and the `*_sym.vh` label table the checks
resolve against:

```
py asm.py program_axi.s  program_axi.hex
py asm.py program_dual.s program_dual.hex
```

### A. Batch, one command, no GUI (Windows shell)

```
vsim -c -do "do sim.do;     quit -f"     # quick single run (tb_cpu_axi)
vsim -c -do "do regress.do; quit -f"     # full 5-config regression + dual-core
```

`-c` is console mode. Each ends in `ALL TESTS PASSED` / `DUAL-CORE TEST PASSED`,
zero `FAIL:`, monitor error counters 0. The regression echoes every config's
parameters read back from the elaborated design, so a silently-ignored override
can't hide behind a green run.

### B. Interactive GUI with the AXI waveform (what to type, and where)

1. In a Windows shell, from `debug/sim`, launch the GUI: `vsim`
2. Everything below goes in ModelSim's **Transcript** pane (the command line at
   the bottom of the GUI):

   ```
   do compile.do                          ;# compile RTL + TB into work/
   vsim -voptargs=+acc work.tb_cpu_axi    ;# elaborate (+acc keeps signals visible)
   do wave.do                             ;# add the AXI-grouped waves
   run -all                               ;# run to $finish
   ```
3. The Wave window now shows every AXI link. Press `f` in the Wave pane (zoom
   full) to see the whole run. To rerun after editing RTL: `do compile.do` again,
   or `restart -f` then `run -all` for the same build.

**What `wave.do` shows — AXI at both ends.** Signals are grouped so each link
shows the master side (what the CPU drives OUT) and the slave side (what
memory/peripheral answers), split by channel with the VALID/READY pair right
next to the payload:

- **IBUS  CPU-M <-> imem** — AR (the address the fetch unit requests) and R (the
  instruction word + RRESP the memory returns). One link, both ends on `ib_*`.
- **DBUS @ CPU master** (`db_*`) — the load/store master before the decoder:
  AW/W/B (write address, data+WSTRB, response) and AR/R (read address,
  data+RRESP).
- **DBUS -> dmem (slave)** (`d0_*`) — the same five channels as the memory sees
  them after the address decoder (the default dbus leg).
- **DBUS -> PIC (slave)** (`pp_*`) and **DBUS -> mtimer (slave)** (`t_*`) — the
  peripheral register accesses (PIC ENABLE/PENDING/RAW/ACTIVE, mtimer
  MTIME/MTIMECMP), each on its own decoded port.
- **IRQ / TRAP** — `irq_src`, `tmr_irq`, `cpu_irq`, `cpu_irq_id`, `cpu_irq_ack`,
  `cpu_in_trap`, to line an interrupt up against the bus traffic around it.

Reading a beat: data transfers on the cycle where both VALID and READY are high;
the address/data must stay stable while VALID waits for READY (the core AXI rule
the monitors and SVA also enforce).

### C. SVA + functional coverage (Verilator, in WSL)

```
bash run_verilator.sh          # from Linux/WSL
.\run_verilator.ps1            # same, one command from Windows (spawns WSL)
```

Ends in `ALL TESTS PASSED`, a `[FCOV]` table, and `COVERAGE GATE PASSED`.

**Pass criterion (all flows):** every run ends green, zero `FAIL:` lines, zero
assertion violations, monitor error counters 0.

## Test plan

The "Area" column links each test to the `REQ#` / `D#` it exercises — the same
tags as the README index and the code.

| Area | Behavior under test | Why it matters | Checked by |
|------|--------------------|----------------|------------|
| REQ7 | All ISA groups incl. FENCE=NOP | baseline correctness | x1..x22 checks, minstret sane |
| D13 | S3->S2 forwarding into every consumer (ALU, branch, address, store data, CSR wdata) | load-use must cost 0 cycles and stay correct | dependent chains in phase A; CPI window |
| REQ11 | WSTRB lanes + load extract for SB/SH/SW/LB(U)/LH(U) | DP-SRAM compatibility contract | dmem word checks + sign/zero-extend reg checks |
| REQ8,D9-D11 | Predictor learns taken loops; not-taken default; alias eviction stays correct | predictor may only affect *time*, never results | BNE loop sum; 3 branches sharing index 0x12 with different tags (0x448/0x648/0x848), sum = 18 |
| D7 | Mispredict recovery incl. JALR, rd==rs1 | link write must use pre-jump value, 1-cycle flush path | JAL/JALR round-trip; `jalr x30,x30` link check; skipped-word poison jumps to a hang loop |
| D3 | Every sync cause: 0,1,2,3,4,5,6,7,11 | trap table complete, mepc per cause | x29 = 0x1FF, direct-mode trap count = 17, handler returns resume execution |
| REQ7,D3 | Illegal instruction has **no side effects** | an illegal store must not reach the bus | `.word 0x04D73023` targets dmem[64]; word must stay 0 (this check caught a real RTL bug) |
| D17 | Misaligned access issues **no** AXI transaction | must trap before issuing any transaction | LH/SH @odd trap cause 4/6; dmem[0] untouched; monitors see no extra transaction |
| D8,D18 | SLVERR/DECERR on fetch/load/store -> mcause 1/5/7 | bus errors must be precise traps | jumps/accesses into unmapped space; cause-1 handler resumes via mscratch (its intended purpose) |
| REQ9,D15 | CSRRW/S/C + immediate forms; read-only CSR write and unimplemented CSR -> illegal; CSRRS x0 = pure read | CSR access rules, incl. negatives | mscratch round-trip 21/31; csrrs 0x7C0, csrrw mip/mhartid all trap; csrrs mip with x0 does *not* trap |
| Priv | `mtval` records the fault address (load/store access fault) / the instruction on illegal; `misa`/`mvendorid`/`marchid`/`mimpid` are readable (0 is valid), not illegal | strict M-mode compliance: these CSRs must exist and read back, and a fault must leave its address in mtval | mtval readback after a DECERR load = 0x8000; misa = 0x40000100 (RV32I); the three id CSRs read 0; none of the reads trap (sync trap count stays exactly 17) |
| D16 | Vectored mtvec: irq -> BASE+4*cause, exception -> BASE | the two vectored paths differ | irq lands at 0x348 slot (cause 18); ecall in vectored mode records at BASE |
| REQ4 | irq sampled only under MIE, only enabled channels, held through AXI stalls, taken at instruction boundaries | the CPU side of the PIC contract | src5 pending whole run, never acked; ch2 raised mid-load: ack timestamp > R-beat timestamp, mepc = boundary instruction, load value intact |
| REQ4 | ack = 1-cycle pulse on the right bit; cpu_in_trap spans entry..MRET | PIC handshake shape | pulse-width invariant, ack counts ch2=2 / ch3=1, in_trap sampled in handler and after |
| D20 | PIC priority: two channels pending together are served lowest-first | "highest-priority pending" must be deterministic | src2+src3 raised in the same cycle: ack2 timestamp < ack3 timestamp; per-cycle invariant `cpu_irq_id` = lowest set `cpu_irq` bit |
| D21 | In-service suppression: an acked channel with its line still high disappears from `cpu_irq` until MRET | a handler that re-enables MIE must not be re-entered by its own interrupt | src3 held high through its whole handler; invariant checks `cpu_irq[3]`=0 in that window; ack3 count stays 1 |
| D19,D22 | PIC software interface: ENABLE write+readback, RAW/PENDING/ACTIVE reads; PIC enable and `mie` are independent masks | the programmable half of the PIC, over real AXI | scoreboard: ENABLE=0x2C, RAW=PENDING=0x20 (src5), ACTIVE=0x04 read *inside* the handler; ch5 visible in mip yet never taken |
| D22 | Unmapped PIC register read and read-only register write answer SLVERR -> precise access faults | error responses from a real peripheral, not just the TB model | both accesses trap (causes 5 and 7, counted in the exact 17); PIC-port monitor stays clean |
| REQ10 | x0 hardwired, regfile reset | | `addi x0,x0,5` then read; regs[0] === 0 |
| D23 | WFI: sleep until wake, ibus silent, mepc = wfi+4 on an interrupt wake, fall-through (no trap) when MIE=0 | the CPU must idle without burning interconnect bandwidth the DMA needs | timer irq wakes the first WFI (mepc readback = wfi+4); second WFI with MIE=0 falls through to a marker store with the handler-entry count unchanged; TB measures ≤1 ibus read per sleep window + SVA `wfi_ibus_quiet` |
| D24 | RAS: returns from 3 different call sites + a nested call chain (h→g→g) predict correctly and stay correct | the BTB's last-target scheme is systematically wrong for returns; the RAS may only change *time*, never results | accumulated signature 0x243 checked; FCOV separates returns predicted correctly vs mispredicted (first encounters only) |
| D25 | mhpmcounter3..7 count mispredicts / fetch-starved / dbus-stall / traps / WFI cycles; writes to them trap | the CPU-side observability numbers for tuning DMA throttling | end-of-run readbacks: traps exactly 26 (17 direct + 1 vectored + 8 irq), the latency-dependent ones nonzero; RO-write trap covered by the existing mcycle negative |
| D26,D27 | mtimer end to end: disarmed at reset, armed CMP_LO-then-CMP_HI without false fires, level irq through PIC ch7, handler clears by moving mtimecmp, software register write, unmapped offset SLVERR | the timer is a real peripheral on a real bus — and the WFI wake source | timer irq taken exactly once (ack7 = 1, cause 23 vectored slot), mtime monotonic readback, MTIME_HI write/read-back = 0x2AB, bad-offset read+write both trap (cause 5/7, counted in the 17), mtimer port protocol monitor + SVA clean |
| D20 | Channel sweep: ch0/1/4/6 each raised once and served; ch5 PIC-disabled first because a mie-masked pending source pins `cpu_irq_id` and starves lower-priority channels | the starvation discipline every peripheral hookup must respect | one ack per swept channel, handler-entry count exactly 8, ack5 still never seen |
| D6 | Back-to-back fetch: 1 instr/cycle on a latency-1 memory | the throughput claim, measured not asserted | mcycle delta across 33 straight-line instrs = 33 (gated to the latency-1 config) |
| REQ2,REQ12 | AXI4-Lite legality on both master ports | interoperability with DMA/DP-SRAM | protocol monitors, all runs, all configs |
| D5 | 2 cores + shared memory via arbiter, mhartid split, flag handshake | "2-3 cores in a bigger SoC" | `tb_dual_core`: flags + both results + clean shared bus |

## SVA + functional coverage (the Verilator flow)

ModelSim ASE has no SVA and no coverage, so this layer lives in `debug/sva/`
and runs the same `tb_cpu_axi` through Verilator
(`--timing --assert --coverage`, plus `sim_main.cpp` to dump the coverage
database). Nothing is edited to attach it — `bind_sva.sv` binds the checkers
into `cpu_top`, `pic` and `mtimer`, so every instance (dual-core included) gets
them:

- `axi_lite_sva.sv` — the AXI4-Lite contract as concurrent properties, one
  instance per port (ibus, dbus, PIC, mtimer): VALID/payload stability under a
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

Current evidence: **all 90 TB checks pass (ModelSim and Verilator), zero
assertion violations, 88/92 functional bins hit (95%)**. The first measurement of this
table (59/85) exposed real test-plan holes — AUIPC never committed,
BLT/BGE/BLTU/BGEU and CSRRCI never executed, both-operand forwarding never
hit, PIC channels 0/1/4/6/7 never taken — and `program_axi.s` now covers all
of them. The four remaining MISS bins are deliberate: the two ch5 negatives
(a masked channel must never trap or ack — that *is* the test) and the two
AR-backpressure bins the regress.do random-READY configs exercise instead of
the default run.

## Performance evidence

CPI = 1.00 measured (33 cycles / 33 straight-line instructions) with a
latency-1 instruction memory. The only remaining stalls are unavoidable:
blocking load/store round-trips and the 1-cycle mispredict bubble. The 1-bit
predictor and ≤1 outstanding transaction per port are fixed design choices
(REQ8, D12), so this is the design's ceiling.

## Multi-core reasoning

Nothing in the core shared between instances (no static state, memories private
to each instance, all identity via the `HART_ID`/`RESET_PC` parameters); both
bus ports are standard AXI4-Lite masters an interconnect can arbitrate; `mhartid`
gives software its identity. RV32I has no LR/SC, but each core executes memory
ops in order and blocking (one outstanding, no store buffer) — sequentially
consistent — so flag / Peterson-style protocols through shared memory are sound,
the same property the SoC's ping-pong buffering relies on. `tb_dual_core` shows
it end to end.

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
