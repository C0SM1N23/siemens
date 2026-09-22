# RV32I SoC

Siemens internship project: a three-stage RV32I CPU, programmable interrupt
controller, timer, four-channel DMA and dual-port SRAM.

| Block | RTL and verification | Documentation |
|---|---|---|
| CPU, PIC, timer | [cpu/](cpu/) | [CPU specifications](cpu/docs/), [verification](cpu/debug/VERIFICATION.md) |
| SoC fabric and integration | [soc/](soc/) | [Architecture](soc/README.md), [verification](soc/docs/VERIFICATION.md) |
| DMA | [dma/](dma/) | Upstream block content retained |
| SRAM | [sram/](sram/) | Upstream block content retained |

The integration branch is `master`. The original `RISCV`, `DMA` and `SDRAM`
branches retain their layout and content.

- [INTEGRATION.md](INTEGRATION.md): upstream revisions, interfaces and integration decisions.
- [TO_MODIFY.md](TO_MODIFY.md): current open items; the sole list of DMA/SRAM findings.
- [VERIFICATION_REPORT.md](VERIFICATION_REPORT.md): verification evidence and limits.
- [AUDIT_CHANGES.md](AUDIT_CHANGES.md): findings of the CPU/SoC audit and their corrections.
- [docs/](docs/): shared project material and faculty report.

## Run

From the repository root, with Python, ModelSim and/or Verilator installed:

```text
make modelsim    # assemble and run 22 CPU/PIC configurations
make soc         # assemble and run 25 SoC configurations
make test        # all 16 CPU/PIC benches, SVA and nominal functional coverage
make soc-sva     # all 16 SoC benches with SVA
```

ModelSim runs the functional tests and procedural monitors. Verilator runs all
distinct functional benches with applicable SVA and the nominal CPU coverage
model. Detailed commands are in each block's verification document.
