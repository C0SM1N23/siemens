# CPU / PIC verification

Results of 23 September 2026. Register contracts and detailed verification plans
are in the [four specifications](../docs/).

## Method

- Original Siemens briefs define the scope. RISC-V defines instruction/CSR
  semantics; AXI defines bus handshakes. Register offsets, interrupt wiring and
  response policies absent from those sources are identified as project decisions.
- `isa_reference.py` independently encodes and interprets a directed program and
  ten seeded random programs. It imports neither the assembler nor RTL constants.
  The bench compares each completed PC, destination and result, then all final
  data words. Full-word reads immediately after SB/SH detect corruption of
  untouched lanes.
- The official [riscv-tests](https://github.com/riscv-software-src/riscv-tests)
  (rv32ui and rv32mi, physical environment) run at a pinned revision, built with
  a bare-metal RISC-V GCC.
- `pic_reference.py` sorts by urgency, intra-band priority and source index.
  Its 275 cases cover all 256 band encodings, ties, masks, empty requests and
  sixteen contenders.
- `pic_tb_random` drives the PIC with random register writes, sources, masks,
  claims and EOIs, reconfiguration while nested included, and writes every
  cycle's inputs and outputs to a trace. `pic_model.py`, a cycle-level Python
  model written from the specification, replays the inputs and must produce the
  same outputs and state on every cycle.
- Directed programs and block benches check architectural constants, trap state,
  memory results, interrupt order, reset and access rules. Procedural AXI
  monitors run on both simulators.
- Verilator runs every bench and timing variant with the bound SVA. Functional
  coverage is merged over the runs, and every cover property must be reached.
- SymbiYosys proves invariants of the PIC for every input sequence.
- `mutation_check.py` runs passing baselines in a temporary copy, injects one
  defect at a time and requires a behavioural failure. Compile errors do not
  count as detection.

## Executed test matrix

| Bench | ModelSim runs | Checks / scope |
|---|---:|---|
| `rv32i_tb_cpu_axi` | 4 | 97/95/95/95: system program, forwarding, traps, IRQs, WFI, protocol, timing |
| `rv32i_tb_dual_core` | 1 | 5: two harts, shared-memory handshake and protocol |
| `pic_tb_feature` | 1 | 145: priority, nesting, empty EOI, spurious, escalation, triggers, responses |
| `pic_tb_reference` | 1 | 5,741: 275 priority cases and register transactions |
| `pic_tb_sched` | 1 | 26: mask, edge at claim, reordered bands, software key strobes |
| `pic_tb_reset` | 1 | 388: reset defaults, loaded state before the next edge, AW-only, W-only, B-held, R-held and recovery |
| `rv32i_tb_reset` | 1 | 217: fetch/load stall, nonzero GPRs, clock stopped high, off-edge reset and restart |
| `pic_tb_ro` | 1 | 478: access classes, reserved bits, W1C and WARL |
| `pic_tb_status` | 1 | 424: pending, active, spurious, deadline and effective band |
| `pic_tb_random` | 4 | 20,000 cycles per seed, each compared with `pic_model.py`; per seed about 1,500 bench checks, 1,092–1,182 claims, 308–328 spurious claims |
| `mtimer_tb_regs` | 1 | 226: reset, rate, byte writes, compare at the exact cycle, invalid offsets |
| `rv32i_tb_counters` | 1 | 159: seven 64-bit counters, halves, carry, write priority, event IDs |
| `rv32i_tb_csr_ro` | 1 | 293: read-only, WARL, fixed, absent and reset CSR behaviour |
| `rv32i_tb_traps` | 1 | 131: supported causes, priority, mepc/mtval, vectored entry, masking, an interrupt and an exception on one instruction, an interrupt pending when MRET re-enables interrupts |
| `rv32i_tb_bp` | 1 | 68: predictor indexing, aliasing, RAS boundaries and reset |
| `rv32i_tb_alu` | 1 | 57: operation decode, signed boundaries, all shift amounts |
| `rv32i_tb_isa` | 17 | Directed program, 1,287 instructions, at four timings. Ten random programs, 47,862 instructions in total, three of them again at stressed timing |
| **Total** | **39** | **All runs completed with zero errors** |

The system program runs at nominal latency, higher fixed latency and two seeded
backpressure settings; the ISA programs at nominal timing, READ_LAT=2 and
STALL_PROB=25/40. Requested parameters are checked after elaboration. Labelled
counts include AXI response checks and are not coverage percentages.

Verilator runs the same 17 benches in 53 runs, with the bound SVA on every run:
the four system-bench timings, eleven PIC random seeds, the directed ISA program
at four timings, and each random ISA program at nominal and at one stressed
timing.

## Coverage

The functional coverage model is bound into the system bench and the ISA bench.
Merged over their 28 Verilator runs, it reaches 90 of 90 bins. The two bins of
PIC source 5, which the system program masks, must stay at zero and do. All 9
cover properties of the CPU and PIC assertion files are reached over the 53
runs. Both gates fail the flow when a bin or a cover is missed.

## Official ISA tests

53 of the 58 rv32ui/rv32mi tests pass at nominal timing and at 40% backpressure,
with the core's SVA bound. The other five must fail, each for a feature the core
does not implement; the runner fails if one of them starts passing.

| Test | Reason |
|---|---|
| `rv32ui-p-fence_i` | Zifencei: instruction memory is not written through the data port |
| `rv32ui-p-ma_data` | Misaligned loads and stores trap (causes 4 and 6) instead of completing |
| `rv32mi-p-breakpoint` | No Sdtrig trigger module (`tselect`) |
| `rv32mi-p-pmpaddr` | No physical memory protection |
| `rv32mi-p-zicntr` | The user aliases `cycle`, `time`, `instret` are absent; the machine counters exist |

## Formal verification of the PIC

`debug/formal/pic_formal.sv` leaves the sources, the CPU mask and the register
port free; the port only obeys AXI4-Lite, and the CPU claims only an offer it was
shown. Proven by induction for every input sequence: the stack never exceeds
sixteen levels; NEST_MAX stays in 1..16; a claim at the limit and an EOI on an
empty stack change nothing; a software request appears only through a keyed
write with both key bytes enabled; only an enabled, unmasked, inactive source is
offered. For every 24-cycle sequence from reset, the active sources equal the
open levels and the spurious flag marks only active sources. Cover statements
show each situation is reachable.

Five injected defects (claim past the limit, EOI on an empty stack, a trigger
without the key strobes, an offer that ignores the mask, NEST_MAX of zero) each
make the proof fail.

## Mutation check

25 injected defects are detected after passing baselines: subtraction,
arithmetic shift, load sign extension, byte/halfword strobes, counter
write/carry priority, signed compare, PIC mask/tie-break/empty EOI, a claim past
the nesting limit (caught by the random traffic and the model), an interrupt
that still decodes its instruction (caught by the trap races), a timer that
fires one cycle late or is armed at reset, and ten fabric
defects listed in the [SoC verification](../../soc/docs/VERIFICATION.md).

## Run

ModelSim commands from `cpu/debug/sim`:

```text
python isa_reference.py --random-set
python pic_reference.py
python asm.py program_axi.s program_axi.hex
python asm.py program_dual.s program_dual.hex
vsim -c -do "do regress.do; quit -f"
```

One bench with the regression's completion checks:

```text
vsim -c -do "do compile.do; do run_common.do; run_case pic_tb_feature feature; quit -f"
```

Set environment variable `VERBOSE=1` to print successful individual comparisons,
or pass `+verbose` when elaborating a bench. Failures and final verdicts are
always printed. Use one ModelSim process per simulation directory because it
owns that directory's `work` library. `regress.do` runs `pic_model.py` with
`$PYTHON` when it is set.

From the repository root in Bash/WSL:

```text
bash cpu/debug/sim/run_verilator.sh
bash cpu/debug/sim/run_riscv_tests.sh
bash cpu/debug/formal/run_formal.sh
```

The riscv-tests runner looks for `riscv-none-elf-gcc` (xPack) or
`riscv64-unknown-elf-gcc`, or takes `RISCV_PREFIX`; it fetches the pinned
revision on its first run. The formal run needs yosys, sby, yosys-abc and z3.
Windows entry point for the Verilator flow: `cpu/debug/sim/run_verilator.ps1`.
GUI: `python cpu/debug/sim/verif_gui.py`.

Mutation checks from the repository root, with `vsim` on PATH:

```text
python cpu/debug/sim/mutation_check.py
```

## Result handling and tools

`finish_test` requires zero errors and sets `test_done`. Watchdogs call `$fatal`.
`run_common.do` checks completion, errors and parameter readback, returning
nonzero on failure. The GUI requires exact run counts and final regression
markers. The Verilator shell flow propagates pipeline errors and requires every
bench verdict plus the coverage and cover gates.

ModelSim ASE 2020.1 compiles CPU RTL as Verilog and runs all functional benches
without SVA, with zero compile errors/warnings. Verilator 5.050 runs SVA and
coverage. `check_lint.py cpu` reports no unexpected diagnostics. The lint options
waive unused signals, empty named connections, filename/module naming and final
newlines; they do not waive width, latch or multiple-driver diagnostics.

CPU/SoC RTL has no `timescale`. Benches and the Verilator command line define
simulation time units. Bench inputs change 1 ns after the rising edge;
handshakes are sampled at the rising edge.

## Limits

Random programs and random PIC traffic are finite seeds. The formal results
cover the PIC invariants listed above, not every register behaviour. The
dual-core run establishes shared-memory progress for two instances, not
multicore interrupt routing. No synthesis or timing result is claimed.
Remaining work: [VERIFICATION_ROADMAP.md](VERIFICATION_ROADMAP.md).

Waveform provenance is recorded in [waves/manifest.json](../docs/waves/manifest.json);
the AXI reference comparison is in [soc/docs/VERIFICATION.md](../../soc/docs/VERIFICATION.md).
