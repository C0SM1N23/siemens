# SoC verification

Results of 23 September 2026, using the integrated sources listed in
[INTEGRATION.md](../../INTEGRATION.md). Address map and topology:
[../README.md](../README.md).

## Executed test matrix

| Bench | ModelSim runs | Labelled checks | Main checks |
|---|---:|---:|---|
| `soc_tb_map_consistency` | 1 | 8 | CPU test map agrees with SoC constants |
| `soc_tb_addr_map` | 1 | 92 | Window boundaries, unmapped access, W-before-AW, mapped DECERR, read ordering against an unread response |
| `soc_tb_arb` | 1 | 23 | Two masters, simultaneous directions, held B response, one transaction per grant against a permissive slave, AW/W in both orders |
| `soc_tb_full2lite` | 1 | 57 | INCR/FIXED bursts, strobes, rejected WRAP/narrow/unaligned transfers, recovery |
| `soc_tb_full2lite_err` | 1 | 31 | Per-beat read errors, mixed write responses, later clean bursts, the same folds with late acceptance |
| `soc_tb_perip_backpressure` | 1 | 41 | Split AW/W, stalled responses, peripheral state preservation |
| `soc_tb_top` | 4 | 27 each | CPU programs transfer, WFI, completion through PIC |
| `soc_tb_stress` | 4 | 12 each | CPU/DMA contention, both memory ports, collisions, decode errors |
| `soc_tb_dma_len` | 4 | 2 each | Supported word-aligned transfer lengths and destination guards |
| `soc_tb_dma_irq` | 1 | 10 | Peripheral mask, sticky status and interrupt after unmask |
| `soc_tb_dma_channels` | 1 | 22 | Four channels, per-channel data and grant activity |
| `soc_tb_dma_err` | 1 | 9 | Bus error propagated to transfer status |
| `soc_tb_timer` | 1 | 12 | Compare timing, source identity, clear and single service |
| `soc_tb_pic_sources` | 1 | 36 | All sixteen software-triggered source IDs through the CPU |
| `soc_tb_pic_nest` | 1 | 16 | Nested handler order and balanced claim/EOI counts |
| `soc_tb_pic_escalate` | 1 | 12 | Deadline escalation changes handler and claim order |
| `soc_tb_isolation` | 1 | 21 | Eight CPU accesses outside every reachable window: each traps precisely with the right cause and address, and no slave sees a transaction |
| `soc_tb_dma_fault` | 1 | 13 | Eight DMA cases: unmapped source, a read off the SRAM's end, an unmapped descriptor, PIC and IMEM destinations, an unaligned source, one channel failing while another copies, a clean restart; every beat checked against the address map |
| `soc_tb_reset_traffic` | 1 | 89 | Asynchronous reset in a DMA write burst, a DMA read burst, a stalled CPU load, an untaken DECERR, a held arbiter grant, and with the clock stopped; nothing stale afterwards, then a full restart |
| `soc_tb_pic_spurious` | 1 | 15 | A source that drops in the claim cycle with the real CPU: spurious log, EOI, the next source served normally |
| `soc_tb_pic_deep_nest` | 1 | 54 | Sixteen nested interrupts through the real CPU and PIC: entry order, unwind order, both stacks empty |
| `soc_tb_same_addr` | 1 | 27 | CPU and DMA on the same DMEM words, serialised whole; same-cycle SRAM collisions with either port winning, each refusal reported to its master |
| `soc_tb_fabric_random` | 3 | 5 each | Random traffic through the real decoder, arbiter and bridge against slaves with random stalls and injected errors, checked against a memory model |
| **Total** | **34** | **767** | **All runs completed with zero errors** |

Labelled checks are the named comparisons a bench prints with `+verbose`.
Several benches also check every beat or cycle with monitors that print only on
failure, so the count does not measure what a bench covers.

`soc_tb_top`, `soc_tb_stress` and `soc_tb_dma_len` run at nominal timing, higher
fixed latency and two seeded backpressure settings. `soc_tb_same_addr` stalls
the instruction memory at random: at full speed the CPU's stores and the DMA's
beats move on the same two-cycle rhythm and never meet on one cycle.
`soc_tb_fabric_random` runs seeds 1–3 here and 1–20 on Verilator; seed 1 alone
makes 800 Lite-master transactions, 896 burst read beats and 20 refused bursts;
over a third of the beats are answered SLVERR or DECERR, and 2,623 cycles are
contended.

## Assertions and cover properties

Verilator runs all 23 benches, the latency and backpressure variants and the 20
random-fabric seeds, 51 runs, with the CPU, PIC, AXI and fabric SVA bound. All
27 cover statements of those files are reached; the flow fails when one is not.

## Formal verification

SymbiYosys checks each fabric block with its neighbours left free apart from
the AXI rules (`soc/debug/formal/`):

| Block | Proven for every input sequence (induction) | Bounded liveness |
|---|---|---|
| `soc_axi_lite_dec` | Protocol on both sides, one transaction per channel, each request reaches exactly the slave its address selects, each response comes from that slave or the DECERR responder, nothing reaches a slave unasked | Every request accepted and answered within a fixed bound when the neighbours answer within two cycles |
| `soc_axi_lite_arb` | One master at a time, one transaction and one direction per grant, each beat carries its owner's payload, each response returns to its owner, a waiting master sees nothing | With sequential masters, every request granted and completed within a bound |
| `soc_axi_full2lite` | For every length from 1 to 256 beats: exactly LEN+1 Lite transactions at the right addresses, data and per-beat responses passed through, RLAST on the last beat only, the write response is the worst beat response and arrives once; any other burst is answered SLVERR on every beat and never reaches the Lite side | A burst of up to 16 beats completes within a bound |

Cover tasks show each interesting state is reachable. Ten injected defects
(decoder read gate, stale write route, early DECERR response, second address in
one grant, both directions in one grant, early grant release, alignment check,
response fold, write address stride, RLAST) each make a proof fail.

## Comparison against an external implementation

`soc_tb_pulp_compare` drives `soc_axi_lite_dec` and `axi_lite_demux` from
[pulp-platform/axi](https://github.com/pulp-platform/axi), configured with
`MaxTrans = 1`, from one shared stimulus generator (`soc_lite_seq_master`) and
behind identical slave stubs. Each run sends ten fixed transactions, then 300
random ones; the runner repeats it for seeds 1 to 10. It compares the data,
response and order of every completed transaction, and how many address
handshakes each slave saw. Timing is not compared: each side runs its own
handshakes at its own pace.

The runner also instantiates the actual PULP `axi_lite_regs` beside the local
`axi_lite_slave`, with a matched four-RW/one-RO-word register bank. It checks
96 combinations (16 WSTRB masks × 3 AW/W orders × 2 response-stall settings),
RO writes, unmapped accesses and asynchronous reset with B and R responses held.
Each side has its own AXI SVA monitor and is checked against expected values.
An unmapped read returns SLVERR on both sides; local RDATA is zero, whereas the
pinned PULP module returns `0xBA5E1E55`.

The sources are fetched into ignored `soc/debug/sim/pulp_ref/`. The completed
comparison uses axi `70b8e54fd460e3308e58be596ceb3566a6e3576e` and common_cells
`03d98106aa19952a10360d2230def85144a0008b`. Existing default checkouts must match
the requested revision and be clean. Explicit `PULP_AXI_DIR` / `PULP_CC_DIR`
are supported; their actual revisions are logged and must be recorded when
reporting a different run. Local wrappers and benches contain no copied
upstream implementation.

Two behaviours are outside the comparison because they are structural
differences rather than disagreements: upstream takes the routing decision as an
input and has no built-in DECERR responder, and its burst splitter rewrites any
failing beat to SLVERR where this project keeps DECERR > SLVERR > OKAY. Both are
recorded in [../README.md](../README.md).

## Expected results and checker validation

Expected addresses come from the implemented memory-map contract. AXI handshake
expectations come from the protocol; CPU results and trap causes come from the
ISA and the documented interrupt interface. DECERR > SLVERR > OKAY for merged
write responses is an explicit bridge policy, not a requirement attributed to
the Siemens brief or AXI standard.

The DMA and SRAM belong to their owners. Benches that exercise them check the
fabric's part strictly and compare the DMA's own reactions with its documented
behaviour; a difference is reported and recorded in
[TO_MODIFY.md](../../TO_MODIFY.md) rather than failing the run.

Ten fabric mutations run in simulation: stale write routing, both grant
directions, response aggregation, read routing, a second address per grant,
alignment, a decoder without DECERR (`soc_tb_isolation`), a decoder that keeps a
write across reset (`soc_tb_reset_traffic`), a bridge that drops a beat's error
(`soc_tb_same_addr`) and an arbiter that releases before the write response
(`soc_tb_fabric_random`). Each selected bench rejects its mutation.

All functional benches use bounded completion and shared failure handling.
`run_common.do` verifies `test_done`, zero errors and parameter readback;
`run_verilator.sh` rejects process failures and missing verdicts. RTL lint uses
an exact diagnostic inventory in `known_lint.json`; new and stale entries fail.

## Commands

From the repository root, with the named tools installed:

```text
make asm
make soc
make soc-sva
make soc-pulp
make formal
```

Direct ModelSim command, from `soc/debug/sim`:

```text
vsim -c -do "do regress.do; quit -f"
```

From the repository root in Bash/WSL:

```text
bash soc/debug/sim/run_verilator.sh
bash soc/debug/formal/run_formal.sh
```

Comparison against the external implementation, from `soc/debug/sim` in
Bash/WSL. It needs network access on the first run, or an existing checkout:

```text
bash run_pulp_compare.sh
PULP_AXI_DIR=/path/to/axi PULP_CC_DIR=/path/to/common_cells bash run_pulp_compare.sh
```

The separate `soc_probe_upstream` diagnostic runs on both simulators; its
observations and the DMA/SRAM findings are in [TO_MODIFY.md](../../TO_MODIFY.md).
It is excluded from the passing regression.

## Limits

Random traffic runs a fixed set of seeds, and the external comparison covers the
AXI4-Lite decoder and register slave. The fabric's liveness is proven with
bounded response times from its neighbours, not for arbitrary delays. The
fabric relies on masters that finish one transaction before starting one that
depends on it (see [../README.md](../README.md)). No synthesis or timing closure
is claimed.
