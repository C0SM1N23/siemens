# SoC integration

Current audit: 23 September 2026. Architecture and routing are documented in
[soc/README.md](soc/README.md); test results in
[CPU verification](cpu/debug/VERIFICATION.md) and
[SoC verification](soc/docs/VERIFICATION.md).

## Integrated revisions

| Source | Revision | Integration |
|---|---|---|
| `origin/DMA` | `b3d0422`, 14 September 2026 | `integrate/dma-latest`, merged into `master` by `c045d29` |
| `origin/SDRAM` | `28cd380` | `integrate/sram-latest`, merged into `master` by `d7de749` |
| SoC interface update | `22362bb` | New module names and ports connected in top level and benches |
| `origin/DMA` | `43d0126`, after `b3d0422` | Not integrated: renames three internal wires and translates comments, with no port or behaviour change |

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
are project decisions.

## CPU / PIC interface decision

The CPU brief specifies eight IRQ inputs, a three-bit ID and an eight-bit
acknowledge; the PIC brief specifies sixteen sources. The implemented common
interface follows the PIC brief: sixteen pending and mask bits, a four-bit
vector, and scalar claim and EOI signals. A claim pushes the offered source onto
the PIC's nesting stack and an EOI pops it. The CPU reports source *n* as
interrupt cause 16 + *n* and enables it with `mie[16+n]`.

## Validation

ModelSim: CPU/PIC 39/39 and SoC 34/34 runs pass. Verilator: all 17 CPU/PIC and
23 SoC benches pass with the bound SVA, including every timing variant and
random seed; the merged functional coverage and every cover property are
reached. The official riscv-tests pass 53 of 58, the other five being features
outside the implemented ISA. SymbiYosys proves the PIC, decoder, arbiter and
bridge properties, and 25 of 25 injected RTL defects are detected in simulation.
DMA/SRAM findings are recorded in [TO_MODIFY.md](TO_MODIFY.md).
