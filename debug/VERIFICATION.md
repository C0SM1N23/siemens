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
4. **Configuration sweep** (`sim/regress.do`): six runs off one compile — the
   same suite under default latencies, high fixed latencies, and two seeded
   random-READY backpressure configs (reproducible by seed), plus the dual-core
   TB and the standalone PIC feature bench. Each run echoes its parameters read
   back from the elaborated design, because we learned the hard way that a
   silently-ignored override looks exactly like a pass.
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
vsim -c -do "do regress.do; quit -f"     # full regression, 12 runs off one compile
```

The twelve regression runs. Runs 1-6 are the system and feature regression;
runs 7-12 are block-level benches that isolate the properties a system run
cannot — reset values, read-only enforcement, individual status fields and one
trap cause at a time.

| # | Bench | Configuration / scope | Checks |
|---|---|---|---|
| 1 | `tb_cpu_axi` | default latencies (the CPI check is active only here) | 90 |
| 2 | `tb_cpu_axi` | high fixed AXI latencies (imem RL=2, dmem RL=3 / WL=2) | 90 |
| 3 | `tb_cpu_axi` | random READY backpressure, seeds 101/202 | 90 |
| 4 | `tb_cpu_axi` | random READY backpressure, seeds 777/888 | 90 |
| 5 | `tb_dual_core` | 2 cores + shared memory behind a 2:1 arbiter | — |
| 6 | `tb_pic` | standalone PIC feature bench | 139 |
| 7 | `tb_pic_reset` | PIC reset values, X-freedom, asynchronous reset | 350 |
| 8 | `tb_pic_ro` | PIC read-only registers and reserved bits | 478 |
| 9 | `tb_pic_status` | PIC `SRCx_STATUS`, field by field | 424 |
| 10 | `tb_mtimer_regs` | machine-timer registers, reset and access rules | 224 |
| 11 | `tb_csr_ro` | CSR file: read-only / WARL / tied-off / absent | 282 |
| 12 | `tb_traps` | one directed test per trap cause | 111 |

`-c` is console mode. Every run ends in its own banner (`ALL TESTS PASSED`,
`DUAL-CORE TEST PASSED`, `PIC RESET TESTBENCH: ALL TESTS PASSED`, and so on),
zero `FAIL:`, monitor error counters 0. The banners are distinct per bench so
the log can be checked by counting them rather than by trusting an exit code —
a bench that dies early prints no banner and also no `FAIL:` line. The
regression echoes every parameterised config's values read back from the
elaborated design, so a silently-ignored override can't hide behind a green run.

**Compile order.** `rtl.f` is written bottom-up by dependency level (leaf
modules, then `alu_top`/`mtimer`/`pic`, then `cpu_top`), and `compile.do`
compiles the filelists in the same order. Verilog-2005 resolves instances at
elaboration rather than at compile time, so this is not strictly required by
the simulator; it is kept because macro and `` `include `` visibility *is*
order-dependent, because a missing module is then reported at the level that
needed it instead of as one unresolved instance at the top, and because lint,
synthesis and formal front-ends do require definition before use. The reasoning
is written out in the header of `rtl.f`.

To run just one bench (compile once, then elaborate it alone) — substitute any
of `tb_pic`, `tb_pic_reset`, `tb_pic_ro`, `tb_pic_status`, `tb_mtimer_regs`,
`tb_csr_ro`, `tb_traps`, `tb_dual_core`:

```
vsim -c -do "do compile.do; vsim -onfinish stop work.tb_pic; run -all; quit -f"
```

**Compile hygiene.** Both flows are warning-free, and that is part of the pass
criterion: ModelSim reports `Errors: 0, Warnings: 0` for RTL, TB and the
dual-core/PIC benches, and Verilator's default warning set is empty. Two habits
keep it that way — every source file carries its own `` `timescale `` (so the
result never depends on filelist order), and every comparison/index/assignment is
width-explicit rather than relying on implicit extension or truncation.

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
  peripheral register accesses (PIC INT_ENABLE / SRCx_STATUS / INT_STATUS /
  ACTIVE_VEC, mtimer MTIME/MTIMECMP), each on its own decoded port.
- **IRQ / TRAP** — `irq_src`, `tmr_irq`, `cpu_irq`, `cpu_irq_vec`, `cpu_irq_ack`,
  `cpu_irq_eoi`, `cpu_in_trap`, to line an interrupt up against the bus traffic
  around it.

Reading a beat: data transfers on the cycle where both VALID and READY are high;
the address/data must stay stable while VALID waits for READY (the core AXI rule
the monitors and SVA also enforce).

### C. SVA + functional coverage (Verilator, in WSL)

```
bash run_verilator.sh          # from Linux/WSL
.\run_verilator.ps1            # same, one command from Windows (spawns WSL)
```

Ends in `ALL TESTS PASSED`, a `[FCOV]` table, and `COVERAGE GATE PASSED`.

### D. GUI launcher

`debug/sim/verif_gui.py` (tkinter, no extra packages) wraps the same flows for
anyone who does not want the ModelSim/Verilator command lines: it launches each
job, streams its output, and shows PASS/FAIL per job. It recognises
infrastructure failures (missing tool, stale `work/_lock`, WSL not provisioned)
separately from real test failures, so "the flow could not run" never gets
reported as "the design is broken".

```
py verif_gui.py                # from debug/sim
```

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
| REQ4 | claim (`cpu_irq_ack`) and eoi (`cpu_irq_eoi`) are 1-cycle pulses; `cpu_in_trap` spans entry..MRET | PIC handshake shape | pulse-width invariants; per-source claim counts ch2=2 / ch3=1 (attributed via the PIC's own claim signals); in_trap sampled in handler and after |
| D20 (D-BAND) | PIC priority: two sources pending together are served by band / intra-priority / index — default config = lowest index first | "highest-priority pending" must be deterministic | src2+src3 raised in the same cycle: claim2 timestamp < claim3 timestamp; strict-priority + offer-consistency invariants proven by `pic_sva` on the internal signals |
| D21 (D-NEST) | In-service suppression: a claimed source with its line still high stays out of `cpu_irq` until its handler's eoi | a handler that re-enables MIE must not be re-entered by its own interrupt | src3 held high through its whole handler; `suppress_fail` checks `cpu_irq`/vec=3 never reappears in that window; claim3 count stays 1 |
| D19,D22 (D-AXI) | PIC software interface: INT_ENABLE write+readback, SRC5_STATUS / INT_STATUS / ACTIVE_VEC reads; PIC enable and `mie` are independent masks | the programmable half of the PIC, over real AXI | scoreboard: INT_ENABLE=0x2C, SRC5_STATUS pending=0x1, INT_STATUS=0, ACTIVE_VEC=0x107 (valid\|src7) read *inside* the handler; src5 visible in mip yet never taken |
| D22 (D-AXI) | Unmapped PIC word read and read-only register write answer SLVERR -> precise access faults | error responses from a real peripheral, not just the TB model | both accesses trap (causes 5 and 7, counted in the exact 17); PIC-port monitor stays clean |
| D-BAND/NEST/SPUR/DDL/SW | Advanced-scheduling features driven directly in `tb_pic.v` | the system bench uses the default config; the feature set needs a dedicated bench | priority bands (inter/intra/tie), preemptive nesting + `NEST_MAX` overflow, a source re-banded while active keeping its claimed priority (grouping Q4), spurious detection + `SPURIOUS_LOG` W1C, deadline escalation that flips the offer *and* preempts an active lower source, bump+multi escalation, keyed software triggers, edge latching, SLVERR/OKAY responses — 139 checks, all pass |
| REQ10 | x0 hardwired, regfile reset | | `addi x0,x0,5` then read; regs[0] === 0 |
| D23 | WFI: sleep until wake, ibus silent, mepc = wfi+4 on an interrupt wake, fall-through (no trap) when MIE=0 | the CPU must idle without burning interconnect bandwidth the DMA needs | timer irq wakes the first WFI (mepc readback = wfi+4); second WFI with MIE=0 falls through to a marker store with the handler-entry count unchanged; TB measures ≤1 ibus read per sleep window + SVA `wfi_ibus_quiet` |
| D24 | RAS: returns from 3 different call sites + a nested call chain (h→g→g) predict correctly and stay correct | the BTB's last-target scheme is systematically wrong for returns; the RAS may only change *time*, never results | accumulated signature 0x243 checked; FCOV separates returns predicted correctly vs mispredicted (first encounters only) |
| D25 | mhpmcounter3..7 count mispredicts / fetch-starved / dbus-stall / traps / WFI cycles | the CPU-side observability numbers for tuning DMA throttling | end-of-run readbacks: traps exactly 26 (17 direct + 1 vectored + 8 irq), the latency-dependent ones nonzero |
| Priv | Counter compliance: every counter is 64-bit with an upper half at base+0x80, M-mode may write either half, and the counters the design does not provide are hardwired zero instead of unimplemented | strict Priv. spec 3.1.11 — a reviewer checking compliance looks here first, and a 32-bit-only `mcycle` wraps in seconds | `mcycleh`/`minstreth`/`mhpm3h`/`mhpm7h` all read 0 on a short run; `mhpmcounter3h` written and read back = 0xDEADBEEF; `mhpmcounter6` low half written and read back = 0x2C1 exactly; `mcycle` written then read back at the written base and strictly higher a few instructions later (bounded check, so it holds in every latency config, plus an exact check gated to the latency-1 config); `mhpmcounter8`, `mhpmcounter8h`, `mhpmevent3`, `mhpmevent31` all read 0 and swallow writes — and the exact sync-trap count staying at 17 is what proves none of these accesses trapped |
| D26,D27 | mtimer end to end: disarmed at reset, armed CMP_LO-then-CMP_HI without false fires, level irq through PIC source 7, handler clears by moving mtimecmp, software register write, unmapped offset SLVERR | the timer is a real peripheral on a real bus — and the WFI wake source | timer irq taken exactly once (claim7 = 1, cause 23 vectored slot), mtime monotonic readback, MTIME_HI write/read-back = 0x2AB, bad-offset read+write both trap (cause 5/7, counted in the 17), mtimer port protocol monitor + SVA clean |
| D20 | Channel sweep: ch0/1/4/6 each raised once and served; ch5 PIC-disabled first because a mie-masked source sits as the PIC's offer and starves the rest | the starvation discipline every peripheral hookup must respect | one claim per swept channel, handler-entry count exactly 8, claim5 still never seen |
| D6 | Back-to-back fetch: 1 instr/cycle on a latency-1 memory | the throughput claim, measured not asserted | mcycle delta across 33 straight-line instrs = 33 (gated to the latency-1 config) |
| REQ2,REQ12 | AXI4-Lite legality on both master ports | interoperability with DMA/DP-SRAM | protocol monitors, all runs, all configs |
| D5 | 2 cores + shared memory via arbiter, mhartid split, flag handshake | "2-3 cores in a bigger SoC" | `tb_dual_core`: flags + both results + clean shared bus |
| D28 (D-RST) | Reset: every flop in the PIC is reset; every mapped register reads its documented reset value; nothing leaves reset holding X; reset is asynchronous and dominant | a reset defect is a first-cycle defect, and a bench that spends its first hundred cycles configuring the block cannot see one | `tb_pic_reset`: all 59 mapped registers read back twice (out of power-on reset and out of a reset asserted off a clock edge from a fully configured, nested state); BVALID/RVALID low and BRESP/RRESP/RDATA X-free during reset; the nesting-stack arrays probed directly; the block proven disarmed (a held source line produces nothing until `INT_ENABLE` is written) — 350 checks |
| D22, D-RSV | Read-only enforcement across the whole PIC map: the write is rejected **and** the value is unchanged; reserved bits are hardwired to zero; W1C ignores a written 0; `NEST_MAX` is WARL | "read-only" is two promises, and the second one is vacuous unless the register holds a non-trivial value at the time of the attempt | `tb_pic_ro`: all 16 `SRCx_STATUS` (driven non-zero by real hardware activity first), `NEST_STATUS`, `ACTIVE_VEC`, the 8 unmapped words in both directions, reserved bits register by register, the write-only `KEY` field, narrow byte-lane writes to a read-only register, and a byte-lane write to a *writable* register as the control — 478 checks |
| D-BAND/NEST/SPUR/DDL | Every `SRCx_STATUS` field on its own, in both directions: `PEND`, `ACTIVE`, `ESC`, `SPUR`, `EFF_BAND`, `DDL_TIMER` | a status bit stuck at 1 is as useless as one stuck at 0, and only a two-sided check finds the first | `tb_pic_status`: each field raised and cleared under its own condition; the deadline counter proven to run only while pending-and-unserviced; bump escalation watched on **every clock edge** so a 3→0 jump cannot pass as three correct steps; a full idle→pending→in-service→returned life cycle read at every transition — 424 checks |
| D26, D27 | Machine-timer registers as a block: reset values (including `mtimecmp` = all-ones, i.e. born disarmed), free-running rate, round-trips, byte lanes, unmapped offsets, arm/fire/clear | the mtimer's only defence against a stray pointer is the slave's address decode, and its reset values are the unusual ones | `tb_mtimer_regs`: mtime proven to advance *exactly* one count per clock (two deltas over gaps differing by a known number of cycles, which cancels the fixed AXI overhead); all 60 unmapped words SLVERR in both directions with the 4 mapped ones still OKAY as the control; the documented LO-then-HI arming order proven not to false-fire — 224 checks |
| REQ9, D15, Priv | CSR access classes kept distinct: read-only (write traps, value unchanged) vs WARL (write accepted and ignored, must **not** trap) vs tied-off (reads 0, swallows writes) vs absent (read and write both trap) | mixing these up is the classic CSR bug: a WARL field that traps breaks conforming software, a read-only register that silently accepts breaks the software that trusted it | `tb_csr_ro`: all five read-only CSRs attacked with CSRRW/CSRRS/CSRRC; read-only *fields* inside writable CSRs (mstatus WPRI, `mie[15:0]`, `mepc[1:0]`) with `mtvec`/`mscratch` as the fully-writable control; `misa` proven WARL rather than read-only; all 77 tied-off hpm addresses; the boundaries one address either side of each tied-off range; reset of every implemented CSR — 282 checks |
| D3, D16, D17, D18 | One isolated directed test per trap cause, with `mcause`, `mepc`, `mtval` and the handler entry address each checked individually | the system bench proves every cause is *reachable* and counts them exactly; it cannot show that cause 6 records the right `mtval`, because one failing cause is one line in a hundred | `tb_traps`: causes 0, 1, 2, 3, 4 (LW and LH forms), 5, 6 (SW and SH forms), 7, 11, and machine-external 16/19/31; cause priority when an address is both misaligned *and* unmapped (4 must win, with zero bus transactions); negatives for a vector masked in `mie` and for `mstatus.MIE`=0, each followed by the positive that proves the negative was masking and not a dead path; vectored `mtvec` sending an interrupt to BASE+4·cause while an exception still enters at BASE — 111 checks |

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
- `pic_sva.sv` — the PIC contract (D-LAT/D-BAND/D-NEST): `cpu_irq`/`cpu_irq_vec`
  equal the registered offer (compared against a same-edge shadow register, so a
  TB that moves `irq_src` right after the clock edge cannot race the check), the
  offered source is a pending, non-in-service request, preemption is strict over
  the top of the nesting stack, depth stays within `[0, NEST_MAX]` and moves only
  by claim/eoi, and the depth limit masks further offers.
- `cpu_func_cov.sv` — functional coverage: instruction classes, load/store
  sizes, each branch × taken/not-taken, predictor outcome matrix, every
  trap cause, CSR op forms, forwarding paths, irq scenarios, per-channel
  acks, bus response/backpressure bins. Prints the `[FCOV]` table with a
  hit/MISS verdict per bin and a summary percentage at end of run.

Current evidence: **all system-bench TB checks pass (ModelSim and Verilator),
plus the standalone `tb_pic.v` (139 checks) for the PIC's advanced features,
zero assertion violations, 88/92 functional bins hit (95%)**. The first measurement of this
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
  logic and asks for `RESET_PC` while `rst_n_i` is still low. AXI forbids it
  (IHI0022E A3.1.2: VALID low in reset), and a slave whose READY is high in
  reset would accept a phantom address. Invisible to the procedural monitor,
  which arms only after reset. Fixed by gating `ibus_arvalid_o` with `rst_n_i`.
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
- The PIC is the real advanced-scheduling `pic.v`, exercised in-system (the TB
  plays the peripherals on `irq_src`, default config = lowest-index priority)
  and, feature by feature, by the standalone `tb_pic.v` (bands, nesting,
  spurious, deadline escalation, software triggers, AXI responses).
- The PIC supports preemptive nesting natively (hardware stack, `NEST_MAX`),
  verified in `tb_pic.v`. In the integrated CPU, handlers run with MIE=0, so the
  CPU exercises one nesting level via `cpu_irq_ack`/`cpu_irq_eoi`; multi-level
  nesting through the CPU needs handler software to re-enable MIE and save
  mepc/mcause/mstatus (standard RISC-V) — a small addition on top of the eoi
  path, not an RTL gap. Randomized many-source toggling in `tb_pic.v` would
  still add value.
- The dbus decoder covers 2 slaves; richer fabrics (more slaves, DECERR from
  the fabric's own decoder) come with the real interconnect.
- Reset assertion mid-transaction is not exercised (models and CPU reset
  together); relevant once the SoC defines its reset controller. What *is*
  exercised since the reset generator was reworked: reset is asserted from time
  0 and released at 123 ns, deliberately between clock edges (posedges are at
  125/135/145 ns), so removal of the asynchronous reset happens off-edge rather
  than at a convenient one.
- Counter compliance is now closed (64-bit halves, M-mode writes, tied-off
  hpm registers). What is still open by choice: `mcountinhibit` is not
  implemented — legal, since the spec makes it optional and defines the absent
  case as "all counters run", but it means software cannot freeze a counter
  around a measurement window.
- **X hygiene on idle buses.** Several dbus payload signals (`db_awaddr`,
  `db_araddr`, `db_wdata`, `db_wstrb` and their decoded copies) read X from
  time 0 until the CPU's first load/store, and `RRESP[1]`/`BRESP[1]` on the
  peripheral ports read X until the first transaction there. Both come from
  registers deliberately left unreset — the LSU command latch (`lsu.v`, "no
  reset, see header") and `rresp_err_q`/`bresp_err_q` in `axi_lite_slave.v`.
  This is legal: AXI only requires the payload to be stable and meaningful
  while the matching VALID is high, and VALID is low the whole time, which is
  why the monitors and the SVA X-hygiene checks pass. It is still visual noise
  in the waveform, so `s_axi_rdata_o` has been given a reset value of 0 and the
  remaining latches are a candidate for the same treatment — the trade-off is
  reset-tree size versus a clean-looking wave, and it is a documented design
  decision (D1), not an oversight.
