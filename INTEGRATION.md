# SoC integration

Current audit: 15 September 2026. Architecture and routing are documented in
[soc/README.md](soc/README.md); test results in
[CPU verification](cpu/debug/VERIFICATION.md) and
[SoC verification](soc/docs/VERIFICATION.md).

## Integrated revisions

| Source | Revision | Integration |
|---|---|---|
| `origin/DMA` | `b3d0422`, 14 September 2026 | `integrate/dma-latest`, merged into `master` by `c045d29` |
| `origin/SDRAM` | `28cd380` | `integrate/sram-latest`, merged into `master` by `d7de749` |
| SoC interface update | `22362bb` | New module names and ports connected in top level and benches |

Integration used separate branches/worktrees to relocate upstream directories.
The colleagues' `RISCV`, `DMA` and `SDRAM` refs were not reset, rebased or rewritten.
DMA and SRAM RTL match their integrated upstream Git
blobs after line-ending normalization; the audit makes no algorithm changes in
either block.

## Connections

| Block | Current interface |
|---|---|
| CPU | `rv32i_cpu_top`, independent instruction/data AXI4-Lite masters |
| DMA | `mc_dma`, `_i`/`_o` ports, `clk_i`, active-low `rst_ni`, AXI4-Full master |
| SRAM | `dp_sram`, independent AXI4-Lite ports A/B |
| PIC | 16 sources, registered request/vector, scalar claim and EOI, pending and CPU mask buses |

CPU data traffic reaches SRAM port A; DMA traffic reaches port B. CPU and DMA
share DMEM through the arbiter. The DMA bridge expands bursts into Lite
transactions. IRQ sources are DMA channels 0–3, SRAM 4 and timer 7; other hardware
source inputs are tied low. Software triggers address all sixteen PIC slots.

## CPU/SoC audit changes

Counter write/retirement semantics, decoder write routing, arbiter direction
ownership and burst response aggregation were corrected. RTL and verification
were reorganized by function, with one state signal per `always` and no RTL
`timescale`. Shared drivers and result handling were corrected and independently
checked. The block verification documents record the methods and results.

The memory map, custom interrupt cause encoding and merged-response priority
are project decisions. The original CPU and PIC briefs specify different
interrupt interfaces; agreement on the implemented common contract remains an
open integration item in [TO_MODIFY.md](TO_MODIFY.md).

## Validation

ModelSim: CPU/PIC 21/21 and SoC 25/25 configurations pass. Verilator: all 31
distinct benches pass with applicable SVA; all required nominal CPU coverage
bins are reached. Mutation checks detect 13/13 injected CPU/PIC/fabric defects.
DMA/SRAM diagnostics and all remaining findings are recorded only in
[TO_MODIFY.md](TO_MODIFY.md).
