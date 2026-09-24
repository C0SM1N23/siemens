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
make modelsim      # CPU/PIC ModelSim regression, 39 runs
make soc           # SoC ModelSim regression, 34 runs
make test          # 17 CPU/PIC benches on Verilator: SVA, merged coverage, covers
make soc-sva       # 23 SoC benches on Verilator: SVA and covers
make riscv-tests   # official rv32ui/rv32mi tests (needs a RISC-V GCC)
make formal        # SymbiYosys: PIC, decoder, arbiter, bridge
make mutations     # injected RTL defects, each must fail its bench
make soc-pulp      # comparison with pulp-platform/axi
```

ModelSim runs the functional tests and procedural monitors. Verilator runs every
bench and timing variant with the bound SVA, the functional coverage model and
the cover properties. Detailed commands are in each block's verification
document.
