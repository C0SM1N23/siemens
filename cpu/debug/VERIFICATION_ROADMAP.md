# Remaining verification work

Current executed evidence: [VERIFICATION.md](VERIFICATION.md). These are limits
of the current verification, not claims of known RTL failure.

| Area | Remaining work |
|---|---|
| External ISA validation | Run an architectural compliance suite or a second established ISA model. The current Python oracle is independent of the RTL but is part of this project. |
| Operand and sequence space | Expand deterministic seeds and long dependency/control-flow sequences beyond the current 1,287-instruction trace. |
| Trap interleavings | Extend nested synchronous/IRQ sequences and document software behaviour at the combined sixteen-level limit. |
| PIC state combinations | Reference current scheduling cases against a sequential model covering deadlines, claims, EOI and dynamic reconfiguration together. |
| Bus timing | Expand seeds and adversarial AXI schedules; current runs are bounded, not an exhaustive liveness proof. |
| System spurious claim | Exercise the offer-withdrawal race with a real CPU and a controllable source. Block-level spurious behaviour is already tested. |
| Coverage | Aggregate timing-variant functional coverage; currently the 92-bin gate measures only the nominal CPU system test. |

No synthesis/timing result or formal proof is claimed. Those activities are
outside the original behavioural CPU deliverable. The independent ISA/PIC
models, counter tests, mutation checks, lint and all-bench Verilator execution
are completed work, not backlog.
