# SoC project — CPU + DMA + Dual-Port SRAM

Siemens summer internship, "Digital IC Design & Advanced Verification".
A small System-on-Chip built from three blocks, each developed and verified
on its own branch. This is the project landing page; the actual RTL lives on
the block branches (see below).

## The blocks

A CPU runs the software and sets things up, a DMA moves data in the
background without the CPU, and a shared dual-port SRAM is the buffer they
exchange data through. Everything talks over AMBA AXI.

**CPU — RV32I, 3-stage pipeline** (`RISCV` branch)
General-purpose core, RISC-V RV32I. Fetch / decode-execute / writeback,
two AXI4-Lite master ports (one for instructions, one for load/store),
a branch predictor, precise traps and M-mode CSRs. The branch also carries
two system blocks no brief assigned but the SoC needs: the interrupt
controller (PIC) and the machine timer.

**DMA — multi-channel, AXI4 master** (`DMA` branch)
Moves data on its own once configured. AXI4-Lite slave for the CPU to
program it, AXI4 full master for the transfers, 4 channels, scatter-gather
via descriptors, bandwidth throttling, per-channel completion/error
interrupts.

**DP-SRAM — dual-port, AXI4-Lite** (`SDRAM` branch)
1 KB shared memory with two independent AXI4-Lite slave ports (one for the
CPU, one for the DMA), byte-lane writes via WSTRB, collision handling and an
interrupt. Used as a ping-pong buffer between CPU and DMA.

## How it fits together

```
   CPU ──┬── instruction bus ── instruction memory
         └── data bus ─────────┐
                               │  AXI interconnect
   DMA ── config (slave) ──────┤
       └─ transfer (master) ───┤
                               ├── DP-SRAM (port A = CPU, port B = DMA)
   PIC ◄─ irq lines from DMA / DP-SRAM / timer ── CPU
```

Typical flow: the CPU programs the DMA over AXI4-Lite, the DMA moves data
through the DP-SRAM, and it raises an interrupt when done so the CPU can
pick up the result.

## Standards

- RISC-V RV32I (unprivileged v20191213, M-mode privileged v20211203)
- AMBA AXI4 / AXI4-Lite per ARM IHI0022E
- Verilog IEEE 1364-2005, behavioural RTL simulation (no vendor IP)

## Branches

| Branch | Block | Owner |
|--------|-------|-------|
| `master` | project overview (this page) | — |
| `RISCV` | CPU + PIC + timer | Cosmin |
| `DMA` | DMA engine | Andrei |
| `SDRAM` | dual-port SRAM | Gabriel |

Each block is developed on its own branch. `master` stays a clean overview;
a block gets merged in once it is stable and reviewed.
