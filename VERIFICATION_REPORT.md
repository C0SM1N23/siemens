# Verification report — 15 September 2026

Detailed test inventories and commands:
[CPU/PIC](cpu/debug/VERIFICATION.md), [SoC](soc/docs/VERIFICATION.md).

## Evidence

| Flow | Executed result |
|---|---|
| ModelSim ASE 2020.1 | 21 CPU/PIC + 25 SoC configurations pass; zero compile errors/warnings |
| Verilator 5.050 | All 15 CPU/PIC + 16 SoC benches pass with applicable SVA |
| CPU nominal user coverage | 88/92 bins; all required bins hit |
| Independent ISA trace | 1,287 instructions and 256 memory words, four ModelSim configurations and one Verilator run |
| Independent PIC reference | 275 cases, all 256 band encodings, on both simulators |
| Mutations | 13/13 injected behavioural defects detected after passing baselines |

The expected values were reviewed against the original Siemens scope, RISC-V
instruction/CSR rules, AXI handshake rules and explicitly identified project
choices. The authored specifications were corrected after checking code and
tests; they were not treated as independent proof.

Generated logs remain local build artifacts. Reproduce the results using the
commands in the block verification documents and
`python cpu/debug/sim/mutation_check.py` from the repository root.

## Limits

Finite operands, seeds and timing scenarios do not prove exhaustive correctness.
The independent ISA model does not replace an external architectural compliance
suite. Nominal CPU coverage is not aggregated SoC coverage. Synthesis, timing
closure and formal proofs were not performed. Remaining verification work is
listed in [VERIFICATION_ROADMAP.md](cpu/debug/VERIFICATION_ROADMAP.md).

DMA/SRAM findings appear only in [TO_MODIFY.md](TO_MODIFY.md).
