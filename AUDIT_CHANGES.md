# CPU / SoC audit — 15 September 2026, fabric ordering review 16 September 2026, verification extension 23 September 2026

Scope: CPU, PIC, timer, SoC fabric and their verification. DMA/SRAM findings are
recorded only in [TO_MODIFY.md](TO_MODIFY.md).

## Verification extension, 23 September 2026

The CPU, PIC, timer and fabric RTL is unchanged in this round; every new test
passed against it. What changed is the depth of the evidence.

### Findings

| Area | Finding | How it was found | Correction |
|---|---|---|---|
| PIC SVA | `depth_within_max` asserted depth ≤ NEST_MAX. Software may lower NEST_MAX below the current depth; the RTL keeps the open levels and masks offers until the stack drains, which is the intended behaviour. | Random PIC traffic under Verilator fired the assertion; the cycle model agreed with the RTL. | Replaced by depth ≤ 16 and "a claim pushes only below NEST_MAX". `ARCHITECTURE.md` states the lowering behaviour. |
| Regression script | ModelSim's Tcl `exec` cannot start the Windows `python` app alias, so the PIC model step stopped the regression. | Full ModelSim regression. | `regress.do` uses `$PYTHON` when set, otherwise `python` through `cmd` on Windows and `python3` elsewhere. |
| Mutation list | An arbiter that sends read responses to both masters was not caught. The decoders accept a response only after their own address handshake, so the stray RVALID never reaches a master: the defect is invisible from outside. | Mutation run. | Replaced with an arbiter that releases the grant before the write response is taken, which the random fabric bench detects. |
| Timer bench | The interrupt was checked only once mtime had passed mtimecmp, so a compare that fired one cycle late (mtime > mtimecmp) still passed. | New timer mutation. | `mtimer_tb_regs` checks that the interrupt rises in the cycle mtime equals mtimecmp. |
| Random fabric bench | One Verilator seed produced no refused burst, so its "every kind of traffic occurred" check failed. | Verilator seeds 1–20. | One burst in ten is now refused, and refused reads are counted as well as writes. |

The DMA/SRAM items found in this round (a control word that never finishes, an
eight-word descriptor fetch, resume restarting the transfer, collisions failing
the losing access, the owner benches not elaborating) are in
[TO_MODIFY.md](TO_MODIFY.md).

### Added

- Bench inputs change 1 ns after the rising edge; handshakes are sampled at the
  rising edge. This replaces the falling-edge drivers described below.
- Verilator runs every timing variant and random seed with the bound SVA.
  Functional coverage is merged over runs (90/90 bins) and every cover property
  must be reached (`merge_fcov.py`, `check_covers.py`).
- CPU: ten seeded random programs from `isa_reference.py` (47,862 instructions);
  interrupt/exception races in `rv32i_tb_traps`; the official riscv-tests
  (`run_riscv_tests.sh`, 53/58 with five features outside the ISA).
- PIC: `pic_tb_random` with the cycle model `pic_model.py`; SymbiYosys harness
  `pic_formal.sv` with five injected defects.
- SoC: `soc_tb_isolation`, `soc_tb_dma_fault`, `soc_tb_reset_traffic`,
  `soc_tb_pic_spurious`, `soc_tb_pic_deep_nest`, `soc_tb_same_addr`,
  `soc_tb_fabric_random`; the PULP decoder comparison over 10 random seeds;
  SymbiYosys harnesses for the decoder, arbiter and bridge with ten injected
  defects.
- Mutations in simulation: 25, up from 16.
- `soc_probe_upstream` observes the DMA control word, descriptor fetch and
  resume.

### Results

| Check | Result |
|---|---|
| ModelSim ASE 2020.1 CPU/PIC | 39/39 runs |
| ModelSim ASE 2020.1 SoC | 34/34 runs; 767 labelled checks |
| Verilator 5.050 | 17 CPU/PIC and 23 SoC benches, every run with SVA; coverage and cover gates pass |
| riscv-tests | 53/58; the five others outside the implemented ISA |
| Formal | PIC 3 tasks, fabric 9 tasks; 15/15 injected defects detected |
| Mutations | 25/25 detected |

## Bugs and verification gaps

| Area | Finding | How it was found | Correction |
|---|---|---|---|
| CPU counters | CSR set/clear used the incremented value; a write could carry into the untouched half. | Zicsr/RV32 counter rules, independent instruction trace and counter boundary tests. | Explicit writes use the old value, preserve the other half and override the increment. |
| CPU retirement | `minstret` updated at S3, out of order with CSR accesses in S2. | Instruction-by-instruction reference trace: nine mismatches before correction. | Count non-trapping S2 completion in program order. |
| HPM selectors | Active counters reported event zero, which denotes no event. | Compare CSR readback with the fixed event definitions. | Selectors 3–7 report fixed WARL IDs 1–5; unused selectors remain zero. |
| SoC decoder | W before AW could reach the slave selected by the previous write. | Directed transaction after a write to a different slave: six mismatches. | Track address/data acceptance and retain routing through B completion. |
| SoC decoder | A second read was accepted while the first read's response was still unread. The single read route was re-pointed, so RDATA changed under RVALID with RREADY low and the answer came from the wrong slave. | Directed read-ordering test: RDATA moved from `0x50000000` to `0x50000002`; 24 mismatches. Confirmed against `axi_lite_demux` (`MaxTrans=1`) on the same stimulus. | Track the accepted read the same way writes were already tracked. Refuse the next AR on both the master and the slave side until its R is taken. |
| SoC decoder | The DECERR responder's internal READY signals ignored the outstanding gate the master port applies, so it could record an acceptance the port had refused. Latent: reaching it needs an unmapped AW while an earlier mapped write's B is unread, which no master in this SoC issues. | Reading the acceptance paths while adding the read gate. | One `aw_accept` / `w_accept` / `ar_accept` wire per channel, used by the master READY, the slave VALID and the responder's own bookkeeping alike. |
| SoC arbiter | A grant is one transaction, but nothing stopped a second address or data beat reaching the slave inside it. Latent against these slaves, which withhold READY while they owe a response; a slave that does not would have been handed two transactions. | Arbiter bench re-run behind a slave that keeps AWREADY/WREADY/ARREADY asserted while a response is owed. | Per-grant `aw_taken_q` / `w_taken_q` / `ar_taken_q`; each channel is forwarded once and they clear when the grant is released. |
| Burst bridge | A 32-bit burst starting off a word boundary was translated as if it were aligned. The Lite slaves ignore `ADDR[1:0]`, so it would have read and written the containing words and reported OKAY. | Reviewing the accepted transfer profile against what the Lite side can express. | Word alignment joins FIXED/INCR and 32-bit beats in the accepted profile; anything else answers SLVERR on every beat without reaching the bus. |
| SoC arbiter | Simultaneous read/write from one master could lose its grant after the first response. | Two-master test with AW/W/AR together and delayed BREADY: timeout before correction. | Select one direction and hold the grant until its response completes. |
| Burst bridge | A later SLVERR replaced an earlier DECERR. | Mixed-response bursts in both orders: one mismatch. | Preserve the project's response priority, DECERR > SLVERR > OKAY. This ordering is a project policy. |
| AXI test drivers | READY could drop before the response acceptance edge. | Review of edge scheduling and transaction traces. | Drive at falling edges and sample handshakes at rising edges; timer checks use observed AR cycle intervals. |
| Fabric SVA | DECERR was assumed to imply an unmapped address. | Compare assertion with mapped-slave response forwarding. | Check unmapped response generation separately; exercise mapped DECERR. |
| Fabric SVA | Nothing asserted that a response stays put until it is taken, that a request is accepted only once, or that a response comes from the selected slave. | Reviewing the assertion set against the decoder defect above: every existing property held while the defect was present. | Added to `soc_fabric_sva.sv`: R/B payload and route stability, one acceptance per channel on both sides, response-from-selected-slave, one burst per direction and the refused-profile decision in the bridge, one address and one data beat per grant in the arbiter. |
| Result reporting | Banner counts and early completion could produce incomplete evidence. | Review of Tcl, shell and GUI result handling; negative result cases. | Require explicit completion, zero errors, exact run counts, applied parameters and successful process status. |
| ISA test oracle | A bad partial-store strobe could escape the initial new trace. | A byte-strobe mutation survived. | Read the full word immediately after each SB/SH; byte and halfword mutations now fail. |
| PIC verification | Empty-stack EOI assertion had no triggering stimulus. | Review of assertion antecedents against test stimulus. | Add two empty EOIs and status checks; removing the underflow guard is detected. |

## Fabric ordering review, 16 September 2026

Prompted by a comparison with [pulp-platform/axi](https://github.com/pulp-platform/axi),
read at `da8793b`. Four differences were put forward; all four were checked
against the upstream source and all four were right. One of them was a live bug
in this project.

| Claim | Verdict | Evidence in upstream |
|---|---|---|
| The decoder keeps one read route and does not block the next request. | Correct, and a real defect. | `axi_demux_simple.sv` accepts AR only `if (!ar_id_cnt_full)` and only when `(!ar_select_occupied \|\| (slv_ar_select_i == lookup_ar_select))`; with `MaxTrans = 1` the counter is full after one push and pops on the R handshake. The write side is the same shape, with `w_select = (\|w_open) ? w_select_q : slv_aw_select_i`. |
| The arbiter serialises reads and writes where upstream arbitrates them separately with response FIFOs. | Correct as a difference; not a defect. | `axi_xbar.sv` instantiates `axi_mux` per slave port, which arbitrates AW and AR independently. |
| The bridge is fixed at 32 bits, FIXED/INCR, no IDs, one burst per direction. | Correct. Upstream rejects WRAP the same way. | `axi_burst_splitter_gran.sv` routes `burst == axi_pkg::BURST_WRAP` to an `axi_err_slv` with `RESP_SLVERR`. |
| Upstream's error aggregation can report an earlier DECERR as SLVERR. | Correct. | `axi_burst_splitter_gran.sv` sets `act_resp.b.resp = axi_pkg::RESP_SLVERR` whenever the burst's error flag is set, whatever the beat returned. |

The decoder defect is the one that mattered. The others are recorded so the
difference is a decision rather than an oversight: the arbiter's serialisation is
a throughput trade-off to revisit if the CPU and DMA are shown to block each
other, and this project's DECERR > SLVERR > OKAY is kept, so a decode error
inside a burst is still reported as a decode error.

Ordering is not free in general, but it is here: every slave in this SoC already
withholds its own READY while it owes a response, so the cycle the decoder now
refuses was never available. The 25-run SoC regression is cycle-identical before
and after, run for run, except for the bench that grew new tests.

### Verification of the fabric ordering changes

| Check | Result |
|---|---|
| ModelSim ASE 2020.1 SoC | 25/25 runs; 533 labelled checks, up from 444 |
| ModelSim ASE 2020.1 CPU/PIC | 21/21 runs, unchanged |
| Verilator 5.050 SoC | 16/16 benches with bound SVA, from a cleared `obj_dir`; lint clean against the same diagnostic inventory |
| External comparison | 10/10 transactions agree with `axi_lite_demux` (`MaxTrans = 1`) on data, response, order and destination counts |
| Mutation: decoder read gate removed | `soc_tb_addr_map` fails on the first ordering check; `ar_needs_free_route` fires; the external comparison diverges — upstream returns the addressed slave's word, the ungated decoder returns the other slave's, then strands the orphaned response and completes 8 of 10 transactions |
| Mutation: arbiter per-grant address gate removed | `soc_tb_arb` reports a second AW inside one grant |

Two bench faults were found and fixed while writing these tests: a handshake
watcher started after the delay it was meant to span, so an address accepted
during the skew went unnoticed and the master left VALID asserted. It appeared
once in `soc_tb_arb` and once in `soc_lite_seq_master`; both now start their
watchers before offering the request.

## Code and test changes

- Split CPU/SoC state updates by signal; align ports, declarations and assignments.
  Simplify decode, priority resolution, state tracking and memory models; retain
  existing parameters and functional module boundaries.
- Remove RTL `timescale` directives and obsolete simulator comments. Keep time
  units in verification and the Verilator command line. Use concise test sections;
  detailed successful comparisons require `+verbose`.
- Add `rv32i_tb_isa`: independent Python encoder/interpreter, 1,287 completed
  instructions and 256 final memory words, four ModelSim timing configurations.
- Add `rv32i_tb_counters`: 159 checks across seven 64-bit counters.
- Add `pic_tb_reference`: independent priority ordering, 275 cases including all
  256 band encodings, 16 contenders, ties and masks.
- Add `soc_tb_arb`; extend decoder, bridge-error, CSR and PIC feature tests.
- Fabric ordering (16 September): one outstanding transaction per channel in
  `soc_axi_lite_dec`, one address and one data beat per grant in
  `soc_axi_lite_arb`, word alignment in `soc_axi_full2lite`'s accepted profile.
  Read-ordering tests in `soc_tb_addr_map`, a permissive-slave second half in
  `soc_tb_arb`, unaligned-address tests in `soc_tb_full2lite`, late-acceptance
  folds in `soc_tb_full2lite_err`, and the response-stability, single-acceptance
  and correct-destination properties in `soc_fabric_sva.sv`.
- Add `soc_tb_pulp_compare` with `soc_lite_seq_master`, `soc_lite_slave_stub` and
  `run_pulp_compare.sh`: the project decoder and an external one driven from one
  shared stimulus generator, compared on data, response, order and destination.
  Upstream is fetched, never vendored; `pulp_lite_demux_wrap.sv` is ours and
  holds no upstream code. No other flow depends on it.
- Add mutation testing in a temporary copy, strict RTL lint checks and shared
  ModelSim/Verilator result handling. Every new functional bench ran on both tools.

## Results, 15 September 2026

| Check | Result |
|---|---|
| ModelSim ASE 2020.1 CPU/PIC | 21/21 runs; 8,473 labelled checks plus four ISA traces |
| ModelSim ASE 2020.1 SoC | 25/25 runs; 444 labelled checks |
| Verilator 5.050 | 15 CPU/PIC + 16 SoC benches pass with applicable bound SVA |
| Nominal CPU functional coverage | 88/92 bins; all required bins reached |
| Mutation checks | 13/13 behavioural defects detected; all baselines pass |
| Compilation / lint | ModelSim: zero errors/warnings. CPU lint clean; SoC accepts only the exact upstream diagnostic inventory. |

Counts describe executed checks, not exhaustive correctness. Remaining
verification limits are in [cpu/debug/VERIFICATION_ROADMAP.md](cpu/debug/VERIFICATION_ROADMAP.md).

## Integration and documents

- Integrate `origin/DMA` at `b3d0422` and `origin/SDRAM` at `28cd380` on `master`.
  Adapt SoC connections to the current module/port names. Colleagues' branches
  retain their commits, layout and content; no force push or branch rewrite.
- Place CPU briefs, technical notes and diagrams under `cpu/docs/`; keep SoC
  architecture and verification under `soc/`.
- Correct the four design/verification specifications to revision 1.1, including
  counter semantics, test methods, results and implementation limits.
  Correct the `mstatus` reset readback (0x1800), exclude absent CSR 0xB81 from the
  upper-counter map, and remove duplicate PDF page anchors.
  Rebuild and inspect the PDFs; retain their detailed structure.
- Update `INTEGRATION.md`, `TO_MODIFY.md`, verification indexes and run instructions.
