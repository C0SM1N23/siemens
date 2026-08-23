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

[VERIFICATION_REPORT.md](VERIFICATION_REPORT.md) is an independent review of
the result: mutation testing, coverage measurement, and — the part worth
reading — the list of what no test covers.

Each block keeps its own documentation: [cpu/README.md](cpu/README.md) and
[cpu/ARCHITECTURE.md](cpu/ARCHITECTURE.md) for the core.

## The system

### Data path

Three panels, read top to bottom: the masters, the fabric that routes them, the
slaves. Arrows are drawn only where a path is unambiguous; where a block has
more than one source, the sources are named inside its box. The exact routing
table follows below.

```
MASTERS
  +----------------------------------------------------+        +--------------------------------+
  |  cpu_top      RV32I, 3 stages, + pic, mtimer       |        |  mc_dma_top                    |
  |                                                    |        |  4 channels, scatter-gather    |
  |  ibus : AXI4-Lite, read only                       |        |                                |
  |  dbus : AXI4-Lite, read + write                    |        |  s_axi : AXI4-Lite slave (regs)|
  +----------------------------------------------------+        |  m_axi : AXI4-FULL master      |
        | ibus                        | dbus                    |          INCR, 8 x 32-bit      |
        |                             |                         +--------------------------------+
        |                             |                                 | m_axi, bursts
        |                             |                                 |
FABRIC   (AXI4-Lite from here down)   |                                 |
  +----------------------+    +----------------------------+    +--------------------------------+
  |  dec_i               |    |  dec_d                     |    |  axi_full2lite                 |
  |  1 -> 1  + DECERR    |    |  1 -> 5  + DECERR          |    |  splits a burst into one Lite  |
  +----------------------+    +----------------------------+    |  transaction per beat          |
        |                             | leg 0                   +--------------------------------+
        |                             |                                 |
        |                             |                                 |
        |                             |                         +--------------------------------+
        |                             |                         |  dec_x                         |
        |                             |                         |  1 -> 2  + DECERR              |
        |                             |                         +--------------------------------+
        |                             |                                 | leg 1
        |                             |                                 |
        |                     +----------------------------+            |
        |                     |  arb_dmem                  |            |
        |                     |  2 -> 1  round-robin       |            |
        |                     |  in: dec_d leg 0           |            |
        |                     |      dec_x leg 0           |            |
        |                     +----------------------------+            |
        |                             |                                 |
        |                             |                                 |
SLAVES  |                             |                                 |
  +----------------------+    +----------------------------+    +--------------------------------+
  |  imem                |    |  dmem                      |    |  dp_sram_top   1 KB            |
  |  axi_lite_ram 8 KB   |    |  axi_lite_ram 8 KB         |    |  0x1000_0000                   |
  |  0x0000_0000         |    |  0x0000_2000               |    |                                |
  |                      |    |                            |    |  port A  <- dec_d leg 1        |
  |  from ibus           |    |  from dbus and DMA         |    |  port B  <- dec_x leg 1        |
  +----------------------+    +----------------------------+    +--------------------------------+

                              dec_d legs 2..4, peripherals on the CPU data bus only
                              +----------------------------+    +--------------------------------+
                              |  pic     16 sources        |    |  mtimer      0x3001_0000       |
                              |  0x3000_0000               |    |  dma regs    0x3002_0000       |
                              +----------------------------+    +--------------------------------+
```

Two paths worth following by hand:

- **CPU load from the SRAM.** `dbus` -> `dec_d` leg 1 -> `dp_sram_top` port A.
  No arbiter anywhere on that path, because port A belongs to the CPU alone.
- **DMA moving one 32-byte chunk out of DMEM.** `m_axi` issues a single 8-beat
  INCR burst -> `axi_full2lite` turns it into eight AXI4-Lite reads -> `dec_x`
  leg 0 -> `arb_dmem`, where each of those eight queues against whatever the
  CPU is doing on `dec_d` leg 0 -> `dmem`.

### Inside the dual-port SRAM

It is the only slave two masters reach without an arbiter, because it has two
physical ports. Stacked boxes below, top to bottom, are the stages a request
passes through.

```
                       +---------------------------------------------+
                       |  dp_sram_top          1 KB                  |
                       |                       0x1000_0000           |
                       +---------------------------------------------+
  CPU dbus   --------->|  port A   axi4lite_slave_fsm                |
  dec_d leg 1          |           one transaction at a time         |
                       +---------------------------------------------+
  DMA bridge --------->|  port B   axi4lite_slave_fsm                |
  dec_x leg 1          |           one transaction at a time         |
                       +---------------------------------------------+
                       |  collision_det                              |
                       |    same word, same cycle, at least one      |
                       |    write:  the writer wins, the reader      |
                       |            gets SLVERR                      |
                       |    past COLLISION_THRESHOLD: both ports     |
                       |            stall for COOLDOWN_CYCLES        |
                       +---------------------------------------------+
                       |  word 0..7    sram_regfile                  |
                       |               INT_STATUS, INT_ENABLE,       |
                       |               FORCE_PRIORITY, BANDWIDTH_A/B |
                       |               ------> irq_o, PIC source 4   |
                       +---------------------------------------------+
                       |  word 8..255  mem_array  256 x 32           |
                       |               byte enables, offset -8       |
                       +---------------------------------------------+
```

### Routing table

The column layout above cannot show a shared slave twice, so here it is
exhaustively. A blank cell means that master has no path to that slave, and an
access there is answered `DECERR` rather than left to hang.

| Slave | Base | Size | CPU ibus | CPU dbus | DMA master |
|---|---|---|---|---|---|
| imem | `0x0000_0000` | 8 KB | `dec_i` | - | - |
| dmem | `0x0000_2000` | 8 KB | - | `dec_d` leg 0 -> `arb_dmem` | `dec_x` leg 0 -> `arb_dmem` |
| dp_sram | `0x1000_0000` | 1 KB | - | `dec_d` leg 1 -> port A | `dec_x` leg 1 -> port B |
| pic | `0x3000_0000` | 64 KB | - | `dec_d` leg 2 | - |
| mtimer | `0x3001_0000` | 64 KB | - | `dec_d` leg 3 | - |
| dma regs | `0x3002_0000` | 64 KB | - | `dec_d` leg 4 | - |

Each window's mask is exactly its size, so an address inside a window but past
the end of the block behind it misses every window and gets `DECERR` instead of
aliasing back onto the block.

### Interrupt map

```
   mc_dma_top.irq[0] --> src 0 --+
   mc_dma_top.irq[1] --> src 1   |
   mc_dma_top.irq[2] --> src 2   |    +---------------+
   mc_dma_top.irq[3] --> src 3   |    |      pic      |   cpu_irq        +--------------+
   dp_sram_top.irq_o --> src 4   +--->|               |----------------->|              |
                   0 --> src 5   |    | priority      |   cpu_irq_vec    |   cpu_top    |
                   0 --> src 6   |    | bands         |----------------->|              |
   mtimer.irq_o      --> src 7   |    | preemptive    |                  | mie[16+n]    |
                   0 --> 8..15 --+    | nesting       |<-----------------| mstatus.MIE  |
                                      | spurious      |   cpu_irq_ack    |              |
                                      | deadline esc. |   cpu_irq_eoi    +--------------+
                                      +---------------+
```

A DMA channel interrupt passes three independent masks before it reaches a
handler: the DMA's own `INT_ENABLE`, then the PIC's `INT_ENABLE`, then the
CPU's `mie[16+n]` gated by `mstatus.MIE`.

### What is inside each block

```
  cpu_top (cpu/)              mc_dma_top (dma/)           dp_sram_top (sram/)
  --------------------------  --------------------------  --------------------------
  fetch_unit                  axi4_lite_slave  (regs)     axi4lite_slave_fsm  x2
  branch_predictor + RAS      dma_channel      x4         collision_det
  decode / control            priority_arbiter            mem_array  256 x 32
  alu_top / branch_unit       axi4_full_master            sram_regfile
  csr_file / exception_unit
  lsu / hazard_unit           descriptor, 4 words:        registers: INT_STATUS,
  regfile / writeback_mux       src, dst, len, ctrl       INT_ENABLE, FORCE_PRIORITY,
                              32-byte chunks per burst    BANDWIDTH_A/B,
  pic, mtimer (same branch)                               COLLISION_THRESHOLD,
                                                          COOLDOWN_CYCLES

  new for the SoC (soc/): axi_lite_dec, axi_lite_arb, axi_full2lite, axi_lite_ram
```

### Three decisions worth a sentence each

**The DMA speaks a different protocol from every slave.** It is an AXI4-Full
master issuing eight-beat INCR bursts; every slave in the system is AXI4-Lite,
which has no bursts at all. [axi_full2lite.v](soc/hdl/axi_full2lite.v) splits
each burst into one AXI4-Lite transaction per beat and reassembles `RLAST` and
the single write response the DMA expects.

**The SRAM is not arbitrated, on purpose.** It has two independent AXI ports,
so the CPU gets port A and the DMA gets port B, both mapped at the same
address. Neither ever queues behind the other, and the block's own collision
detector stays reachable in the assembled system - put an arbiter in front and
that logic would be dead code. Only DMEM has a single port, so only DMEM gets
an arbiter.

**Reachability is deliberately not uniform.** The instruction bus reaches only
IMEM, so a runaway PC gets a decode error instead of executing peripheral
registers. The data bus reaches everything except IMEM, so there is no
self-modifying-code path. The DMA reaches only DMEM and the SRAM, so a bad
descriptor cannot reprogram the interrupt controller.

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
