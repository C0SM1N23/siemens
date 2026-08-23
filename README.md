# SoC — RV32I CPU + multi-channel DMA + dual-port SRAM

Siemens summer internship, "Digital IC Design & Advanced Verification".

Three blocks were developed and verified separately, one per branch. This
branch joins them into a working System-on-Chip: an AXI4-Lite fabric, a
burst bridge, an address map, an interrupt map, and a system test in which
real software on the real CPU drives a real DMA transfer into the real SRAM.

The block branches (`RISCV`, `DMA`, `SDRAM`) are untouched — nothing was
rebased or rewritten to make the integration fit.

## Layout

Every block has the same shape: `hdl/` for the design, `debug/` for its
verification.

| Path | Block | From |
|---|---|---|
| [cpu/](cpu/) | RV32I core, 3-stage pipeline, PIC, machine timer | `RISCV` |
| [dma/](dma/) | 4-channel DMA, AXI4-Full master, scatter-gather | `DMA` |
| [sram/](sram/) | dual-port SRAM, collision detection | `SDRAM` |
| [soc/](soc/) | interconnect, SoC top level, system verification | new |
| [docs/](docs/) | engineering documentation (LaTeX) | `RISCV` |

[INTEGRATION.md](INTEGRATION.md) records every change made to the three blocks
to make them work together, and why each one was needed. Start there if the
question is "what did you have to touch in their code".

Each block keeps its own documentation: [cpu/README.md](cpu/README.md) and
[cpu/ARCHITECTURE.md](cpu/ARCHITECTURE.md) for the core.

## The system

```
                     +--------- ibus (read only) --------> IMEM   0x0000_0000
   cpu_top ----------+
                     +-- dbus --> decoder --+-- [arb] ---> DMEM   0x0000_2000
                                            +------------> SRAM A 0x1000_0000
                                            +------------> PIC    0x3000_0000
                                            +------------> timer  0x3001_0000
                                            +------------> DMA    0x3002_0000

   mc_dma_top --(AXI4-Full)--> full2lite --> decoder --+-- [arb] --> DMEM
                                                       +----------> SRAM B

   interrupts: DMA irq[3:0] -> PIC 0..3, SRAM -> PIC 4, timer -> PIC 7,
               PIC -> CPU
```

Three things in that picture are worth a sentence each.

**The DMA speaks a different protocol from every slave.** It is an AXI4-Full
master issuing eight-beat INCR bursts; every slave in the system is AXI4-Lite,
which has no bursts at all. [axi_full2lite.v](soc/hdl/axi_full2lite.v) splits
each burst into one AXI4-Lite transaction per beat and reassembles `RLAST` and
the single write response the DMA expects.

**The SRAM is not arbitrated, on purpose.** It has two independent AXI ports,
so the CPU gets port A and the DMA gets port B, both mapped at the same
address. Neither ever queues behind the other, and the block's own collision
detector stays reachable in the assembled system — put an arbiter in front and
that logic would be dead code. Only DMEM has a single port, so only DMEM gets
an arbiter.

**Reachability is deliberately not uniform.** The instruction bus reaches only
IMEM, so a runaway PC gets a decode error instead of executing peripheral
registers. The data bus reaches everything except IMEM, so there is no
self-modifying-code path. The DMA reaches only DMEM and the SRAM, so a bad
descriptor cannot reprogram the interrupt controller. Anything outside every
window is answered with `DECERR` rather than left to hang the master.

The full map, including the interrupt source assignment, is in
[soc/hdl/soc_addr_map.vh](soc/hdl/soc_addr_map.vh).

## Running it

Needs ModelSim (`vsim` on `PATH`) and Python 3.

```
make soc         # SoC regression, 9 runs over four bus timings (ModelSim)
make soc-sva     # SoC lint + SVA assertion run (Verilator)
make modelsim    # CPU regression, 14 runs
make test        # CPU Verilator SVA + coverage flow (what CI runs)
make asm         # rebuild the test program images
```

`make soc` runs three benches from one compile, the two system-level ones under
four bus timings each (nominal, high fixed latency, and two seeds of random
READY backpressure):

1. **[tb_full2lite](soc/debug/hdl/tb_full2lite.v)** — the burst bridge on its
   own: 8-beat bursts, single-beat bursts, byte strobes, FIXED bursts,
   `RLAST` placement, and the unsupported cases (WRAP, narrow transfers) which
   must come back `SLVERR` with memory untouched rather than be mistranslated.

2. **[tb_soc_top](soc/debug/hdl/tb_soc_top.v)** — the whole SoC. The bench only
   supplies a clock, a reset and a program image; the checking is done by
   [program_soc.s](soc/debug/sim/program_soc.s) running on the CPU, which
   builds a descriptor, programs a DMA channel, sleeps on `WFI`, is woken by
   the DMA's completion interrupt through the PIC, and compares what the DMA
   moved against what it was asked to move.

3. **[tb_soc_stress](soc/debug/hdl/tb_soc_stress.v)** — the same SoC with the
   CPU working the bus for the whole transfer instead of sleeping through it.
   This is the run that reaches the contention logic: the arbiter with both
   masters asking, both SRAM ports busy in the same cycle, real address
   collisions, and an unmapped access that must come back `DECERR`. It
   measures each of those and **fails if they did not happen** — a run that
   passes without exercising what it was written for is not a passing run.
   The transfers must come out bit-perfect regardless of the interference.

`make soc-sva` lints the whole SoC with `-Wall` and re-runs every bench with the
assertion layer in [soc/debug/sva/](soc/debug/sva/) bound live: AXI4-Lite and
AXI4-Full protocol on every port, plus the fabric's own decisions — disjoint
address windows, one-hot grants, a grant held until its response beat, a parked
master that sees nothing, and a burst whose beat counter and `RLAST` agree.

## Status

| Regression | Result |
|---|---|
| CPU, 14 runs | all pass |
| SoC, 9 runs | all pass |
| SoC lint + SVA (Verilator) | lint clean, all benches pass |
| DMA block bench | passes |
| DP-SRAM block bench | 67/67 checks pass |

All three blocks compile into a single library with no errors and no warnings,
and the whole SoC lints clean under `verilator -Wall`.
