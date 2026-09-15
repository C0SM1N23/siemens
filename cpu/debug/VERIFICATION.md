# CPU / PIC verification

Measured on 15 September 2026. Register contracts and detailed verification
plans are in the [four specifications](../docs/).

## Method

- Original Siemens briefs define the scope. RISC-V defines instruction/CSR
  semantics; AXI defines bus handshakes. Register offsets, interrupt wiring and
  response policies absent from those sources are identified as project decisions.
- `isa_reference.py` independently encodes and interprets the program. It imports
  neither the assembler nor RTL constants. The bench compares each completed PC,
  destination and result, then all final data words. Full-word reads immediately
  after SB/SH detect corruption of untouched lanes.
- `pic_reference.py` sorts by urgency, intra-band priority and source index.
  Its 275 cases cover all 256 band encodings, ties, masks, empty requests and
  sixteen contenders. Directed tests cover sequential nesting and deadlines.
- Existing programs check architectural constants, trap state, memory results,
  interrupt order and traffic. Block tests isolate reset, access rules, carry
  boundaries and simultaneous events. Procedural AXI monitors run on both tools.
- SVA run on Verilator. A property is credited only where its antecedent occurs.
  The empty-stack EOI case now explicitly drives two pulses and checks state.
- `mutation_check.py` runs passing baselines in a temporary copy, injects one
  defect at a time and requires a behavioural failure. Compile errors do not
  count as detection.

These are finite tests, not an external compliance certification or a formal
proof of every operand and event interleaving.

## Executed test matrix

| Bench | ModelSim runs | Checks / scope |
|---|---:|---|
| `rv32i_tb_cpu_axi` | 4 | 97/95/95/95: system program, forwarding, traps, IRQs, WFI, protocol, timing |
| `rv32i_tb_dual_core` | 1 | 5: two harts, shared-memory handshake and protocol |
| `pic_tb_feature` | 1 | 145: priority, nesting, empty EOI, spurious, escalation, triggers, responses |
| `pic_tb_reference` | 1 | 5,741: 275 priority cases and register transactions |
| `pic_tb_sched` | 1 | 26: mask, edge at claim, reordered bands, software key strobes |
| `pic_tb_reset` | 1 | 350: reset fields, interfaces, asynchronous reset |
| `pic_tb_ro` | 1 | 478: access classes, reserved bits, W1C and WARL |
| `pic_tb_status` | 1 | 424: pending, active, spurious, deadline and effective band |
| `mtimer_tb_regs` | 1 | 225: reset, rate, byte writes, compare, invalid offsets |
| `rv32i_tb_counters` | 1 | 159: seven 64-bit counters, halves, carry, write priority, event IDs |
| `rv32i_tb_csr_ro` | 1 | 293: read-only, WARL, fixed, absent and reset CSR behaviour |
| `rv32i_tb_traps` | 1 | 120: supported causes, priority, mepc/mtval, vectored entry, masking |
| `rv32i_tb_bp` | 1 | 68: predictor indexing, aliasing, RAS boundaries and reset |
| `rv32i_tb_alu` | 1 | 57: operation decode, signed boundaries, all shift amounts |
| `rv32i_tb_isa` | 4 | Per run: 1,287 completed instructions and 256 final data words |
| **Total** | **21** | **8,473 labelled checks plus four ISA traces; zero failures** |

The system program runs at nominal latency, higher fixed latency and two seeded
backpressure settings. The ISA trace runs at nominal timing, READ_LAT=2 and
STALL_PROB=25/40. Requested parameters are checked after elaboration. Labelled
counts include AXI response checks and are not coverage percentages.

Verilator executes all 15 distinct benches at their default configurations with
applicable bound SVA. It also measures user coverage in the nominal CPU system
test. Every listed bench passed on both simulators.

## Run

ModelSim commands from `cpu/debug/sim`:

```text
python isa_reference.py
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
owns that directory's `work` library.

Verilator commands from the repository root in Bash/WSL:

```text
bash cpu/debug/sim/run_verilator.sh
bash soc/debug/sim/run_verilator.sh
```

Windows entry point: `cpu/debug/sim/run_verilator.ps1`. GUI:
`python cpu/debug/sim/verif_gui.py`. Assemble regenerates both independent
reference images as well as the assembly programs.

Mutation checks from the repository root, with `vsim` on PATH:

```text
python cpu/debug/sim/mutation_check.py
```

All 13 mutations were detected after passing baselines: subtraction, arithmetic
shift, load sign extension, byte/halfword strobes, counter write/carry priority,
PIC mask/tie-break/empty EOI, decoder write routing, arbiter direction and burst
response aggregation. A surviving initial strobe mutation prompted the
untouched-lane checks; both partial-store mutations then failed.

## Result handling and tools

`finish_test` requires zero errors and sets `test_done`. Watchdogs call `$fatal`.
`run_common.do` checks completion, errors and parameter readback, returning
nonzero on failure. The GUI requires exact run counts and final regression
markers. Two real passing logs were accepted; seven modified, incomplete or
failed-process result cases were rejected. The Verilator shell flow propagates
pipeline errors and requires every bench verdict plus final completion markers.

ModelSim ASE 2020.1 compiles CPU RTL as Verilog and runs all functional benches
without SVA, with zero compile errors/warnings. Verilator 5.050 runs SVA and user
coverage. `check_lint.py cpu` reports no unexpected diagnostics. The lint options
waive unused signals, empty named connections, filename/module naming and final
newlines; they do not waive width, latch or multiple-driver diagnostics.

CPU/SoC RTL has no `timescale`. Benches and the Verilator command-line option
define simulation time units.

## Coverage and limits

The nominal CPU run reaches 88/92 user bins, including every required bin. Four
optional misses remain: source-5 trap and claim (deliberately masked), instruction
AR backpressure and data AR backpressure. ModelSim timing variants exercise the
latter but do not contribute to the nominal Verilator coverage total.

The ISA generator reaches 50 named instruction categories. Directed tests also
check nine synchronous trap causes, exact entry counts, handler state, nested
returns, masking and WFI. A straight-line 33-instruction window takes 33 cycles
with the nominal instruction memory.

The dual-core run establishes shared-memory progress for two instances, not
multicore interrupt routing. No synthesis/timing result or formal proof is
claimed. Remaining work: [VERIFICATION_ROADMAP.md](VERIFICATION_ROADMAP.md).
