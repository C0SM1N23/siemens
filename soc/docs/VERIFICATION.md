# SoC verification

Measured on 15 September 2026 using the integrated sources listed in
[INTEGRATION.md](../../INTEGRATION.md). Address map and topology:
[../README.md](../README.md).

## Executed test matrix

| Bench | ModelSim runs | Main checks |
|---|---:|---|
| `soc_tb_map_consistency` | 1 | CPU test map agrees with SoC constants |
| `soc_tb_addr_map` | 1 | Window boundaries, unmapped access, W-before-AW, mapped DECERR |
| `soc_tb_arb` | 1 | Two masters, simultaneous directions, held B response, read completion |
| `soc_tb_full2lite` | 1 | INCR/FIXED bursts, strobes, rejected WRAP/narrow transfers, recovery |
| `soc_tb_full2lite_err` | 1 | Per-beat read errors, mixed write responses, later clean bursts |
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
| **Total** | **25** | **444 labelled checks, zero failures** |

Verilator executes each of the 16 distinct benches at its default configuration
with bound CPU/PIC, AXI and fabric SVA. ModelSim additionally runs the fixed
latency and seeded backpressure variants. All listed runs passed. A positive
check count includes transaction response checks; it is not functional coverage.

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
```

Direct ModelSim command, from `soc/debug/sim`:

```text
vsim -c -do "do regress.do; quit -f"
```

Direct Verilator command, from the repository root in Bash/WSL:

```text
bash soc/debug/sim/run_verilator.sh
```

The separate `soc_probe_upstream` diagnostic ran on both simulators. Its
observations and the sole list of DMA/SRAM findings are in
[TO_MODIFY.md](../../TO_MODIFY.md); it is excluded from the passing regression.

## Limits

Finite timing seeds do not exhaust AXI interleavings. The PIC's spurious-claim
race is tested at block level; the integrated peripheral wiring does not expose
a test-controlled source for that exact cycle. No synthesis, timing closure or
formal liveness proof is claimed. CPU coverage bins are measured only in the
nominal CPU system test, not accumulated over the SoC matrix.
