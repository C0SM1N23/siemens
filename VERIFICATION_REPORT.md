# Verification report — 23 September 2026

Detailed test inventories and commands:
[CPU/PIC](cpu/debug/VERIFICATION.md), [SoC](soc/docs/VERIFICATION.md).

## Evidence

| Flow | Result |
|---|---|
| ModelSim ASE 2020.1 | 39 CPU/PIC runs (17 benches) and 34 SoC runs (23 benches) pass; zero compile errors/warnings |
| Verilator 5.050 | The same benches in 53 CPU/PIC and 51 SoC runs with the bound SVA, every timing variant and random seed included |
| Functional coverage | 90/90 CPU bins merged over 28 runs; the two bins of the masked PIC source stay at zero |
| Cover properties | Every cover statement reached: 9/9 in the CPU/PIC runs, 27/27 in the SoC runs |
| Official riscv-tests | 53/58 rv32ui/rv32mi pass at nominal timing and 40% backpressure; the other 5 test features outside the implemented ISA |
| Independent ISA model | Directed program (1,287 instructions) and ten random programs (47,862 instructions), at several timings |
| Independent PIC models | 275 priority cases; random traffic compared cycle by cycle with a Python model in 15 runs of 20,000 cycles |
| Formal (SymbiYosys) | PIC: 3 tasks. Decoder, arbiter, bridge: induction, bounded liveness and cover, 9 tasks. 15 injected defects, each makes a proof fail |
| Mutations in simulation | 25/25 injected RTL defects detected after passing baselines |
| External comparison | Decoder against pulp-platform `axi_lite_demux` over 10 random seeds; register slave against `axi_lite_regs` |

The expected values were reviewed against the original Siemens scope, RISC-V
instruction/CSR rules, AXI handshake rules and explicitly identified project
choices. The authored specifications were corrected after checking code and
tests; they were not treated as independent proof.

Generated logs remain local build artifacts. Every result above is reproduced by
the `make` targets listed in the [README](README.md).

## Limits

Random stimulus runs a fixed set of seeds. The formal proofs cover the PIC and
the three fabric blocks; the CPU pipeline is checked by simulation. Five
official tests exercise features the core does not implement. Synthesis and
timing closure were not part of the behavioural deliverable. Remaining
verification work is listed in
[VERIFICATION_ROADMAP.md](cpu/debug/VERIFICATION_ROADMAP.md).

DMA/SRAM findings appear in [TO_MODIFY.md](TO_MODIFY.md).
