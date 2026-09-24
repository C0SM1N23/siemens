# Remaining verification work

Current executed evidence: [VERIFICATION.md](VERIFICATION.md). These are limits
of the current verification, not claims of known RTL failure.

| Area | Remaining work |
|---|---|
| Pipeline proof | Prove the core against the ISA formally, for example with riscv-formal. Today the core is checked by simulation: the official tests, the independent ISA model and SVA. |
| Features outside the ISA subset | If Zifencei, the Zicntr user aliases, misaligned access in hardware, PMP or a trigger module are added, their five riscv-tests become required passes. |
| Seeds | Random ISA programs and PIC traffic run a fixed set of seeds; a nightly run with fresh seeds would keep widening the explored space. |
| Multicore interrupts | The PIC serves one CPU. Routing interrupts to several harts is a design extension and would need its own tests. |

No synthesis or timing result is claimed; those activities are outside the
original behavioural CPU deliverable.
