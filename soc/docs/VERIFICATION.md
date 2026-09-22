# SoC verification

Measured on 15 September 2026 using the integrated sources listed in
[INTEGRATION.md](../../INTEGRATION.md). Address map and topology:
[../README.md](../README.md).

## Executed test matrix

| Bench | ModelSim runs | Main checks |
|---|---:|---|
| `soc_tb_map_consistency` | 1 | CPU test map agrees with SoC constants |
| `soc_tb_addr_map` | 1 | Window boundaries, unmapped access, W-before-AW, mapped DECERR, read ordering against an unread response |
| `soc_tb_arb` | 1 | Two masters, simultaneous directions, held B response, one transaction per grant against a permissive slave, AW/W in both orders, accepted against completed |
| `soc_tb_full2lite` | 1 | INCR/FIXED bursts, strobes, rejected WRAP/narrow/unaligned transfers, recovery |
| `soc_tb_full2lite_err` | 1 | Per-beat read errors, mixed write responses, later clean bursts, the same folds with late acceptance |
| `soc_tb_perip_backpressure` | 1 | Split AW/W, stalled responses, peripheral state preservation |
| `soc_tb_top` | 4 | CPU programs transfer, WFI, completion through PIC |
| `soc_tb_stress` | 4 | CPU/DMA contention, both memory ports, collisions, decode errors |
| `soc_tb_dma_len` | 4 | Supported word-aligned transfer lengths and destination guards |
| `soc_tb_dma_irq` | 1 | Peripheral mask, sticky status and interrupt after unmask |
| `soc_tb_dma_channels` | 1 | Four channels, per-channel data and grant activity |
| `soc_tb_dma_err` | 1 | Bus error propagated to transfer status |
| `soc_tb_timer` | 1 | Compare timing, source identity, clear and single service |
| `soc_tb_pic_sources` | 1 | All sixteen software-triggered source IDs through the CPU |
| `soc_tb_pic_nest` | 1 | Nested handler order and balanced claim/EOI counts |
| `soc_tb_pic_escalate` | 1 | Deadline escalation changes handler and claim order |
| **Total** | **25** | **533 labelled checks, zero failures** |

Verilator executes each of the 16 distinct benches at its default configuration
with bound CPU/PIC, AXI and fabric SVA. ModelSim additionally runs the fixed
latency and seeded backpressure variants. All listed runs passed. A positive
check count includes transaction response checks; it is not functional coverage.

## Comparison against an external implementation

`soc_tb_pulp_compare` drives `soc_axi_lite_dec` and `axi_lite_demux` from
[pulp-platform/axi](https://github.com/pulp-platform/axi), configured with
`MaxTrans = 1`, from one shared stimulus generator (`soc_lite_seq_master`) and
behind identical slave stubs. It compares the data, response and order of every
completed transaction, and how many address handshakes each slave saw. Timing is
not compared: each side runs its own handshakes at its own pace.

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

The directed decoder and arbiter tests drive channels independently and observe
actual acceptance edges. The bridge test supplies response sequences explicitly.
Mutation testing reinstates stale write routing, permits both grant directions
and replaces response aggregation; each selected test rejects its mutation.
Mapped DECERR traffic also validates the corrected assertion premise.

The one-transaction-per-channel rules were checked the same way. Removing the
decoder's read gate makes `soc_tb_addr_map` fail on the first ordering check,
fires the bound `ar_needs_free_route` assertion, and makes the upstream
comparison diverge: for the read whose response was left unread, upstream
returns the addressed slave's word and the ungated decoder returns the other
slave's, then strands the orphaned response and completes eight of the ten
transactions. Removing the arbiter's per-grant address gate makes `soc_tb_arb`
report a second AW inside one grant. The arbiter bench's second half runs behind
a slave that keeps its READY signals asserted while it owes a response, because
against the strict slave the slave's own back-pressure hides the obligation.

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
```

Direct ModelSim command, from `soc/debug/sim`:

```text
vsim -c -do "do regress.do; quit -f"
```

Direct Verilator command, from the repository root in Bash/WSL:

```text
bash soc/debug/sim/run_verilator.sh
```

Comparison against the external implementation, from `soc/debug/sim` in
Bash/WSL. It needs network access on the first run, or an existing checkout:

```text
bash run_pulp_compare.sh
PULP_AXI_DIR=/path/to/axi PULP_CC_DIR=/path/to/common_cells bash run_pulp_compare.sh
```

The separate `soc_probe_upstream` diagnostic ran on both simulators. Its
observations and the sole list of DMA/SRAM findings are in
[TO_MODIFY.md](../../TO_MODIFY.md); it is excluded from the passing regression.

## Limits

The comparison against the external implementation covers the AXI4-Lite decoder
only, on one fixed ten-transaction sequence; the arbiter and the burst bridge are
not compared against upstream equivalents, and no randomised or formal
equivalence is claimed. Finite timing seeds do not exhaust AXI interleavings.
The PIC's spurious-claim race is tested at block level; the integrated
peripheral wiring does not expose a test-controlled source for that exact cycle. No synthesis, timing closure or
formal liveness proof is claimed. CPU coverage bins are measured only in the
nominal CPU system test, not accumulated over the SoC matrix.
