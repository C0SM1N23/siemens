# SoC integration

A guide to how three separately developed blocks — the RV32I CPU, the
multi-channel DMA and the dual-port SRAM — became one SoC, and what had to
change in them to make that possible.

The block branches `RISCV`, `DMA` and `SDRAM` are untouched: nothing was
rebased, rewritten or force-pushed. All the work is on `master`.

For the system diagram and the address map see [README.md](README.md); for the
full list of defects and gaps see [TO_MODIFY.md](TO_MODIFY.md); for the
independent review see [VERIFICATION_REPORT.md](VERIFICATION_REPORT.md).

---

## 1. What was changed in the blocks

Five source changes. None of them touches a block's algorithm — no state
machine, no arbitration, no collision detection was modified.

| Block | Change | Why |
|---|---|---|
| DMA | `active_master_ch` declared above its use | the block did not compile |
| DMA | `irq` driven from `INT_STATUS & INT_ENABLE` | two writable registers did nothing |
| DP-SRAM | module `regfile` renamed `sram_regfile` | name collision with the CPU |
| DP-SRAM | its `compile.do` follows the rename | the block bench stopped compiling |
| DP-SRAM | `WIN_W` derived from `WINDOW_CYCLES` | the two could silently disagree |

### DMA: `active_master_ch` used before it was declared

`mc_dma_top.v` read the register in four continuous assignments at line 103 and
declared it at line 117. Verilog requires declaration before reference, so the
block did not compile at all:

```
** Error: (vlog-2730) Undefined variable: 'active_master_ch'.
** Error: (vlog-2388) 'active_master_ch' already declared in this scope.
```

The declaration and its `always` block moved above the assignments. Same
register, same reset value, same update condition.

### DMA: `INT_STATUS` and `INT_ENABLE` were connected to nothing

The register file implements both correctly — `INT_STATUS` sticky and
write-1-to-clear, `INT_ENABLE` a plain mask — but `mc_dma_top` left both
outputs unconnected and drove the interrupt from the raw channel lines:

```verilog
assign irq = hw_irq;                                  // before
assign irq = int_status_w[3:0] & int_enable_w[3:0];   // after
```

Masking an interrupt had no effect and clearing `INT_STATUS` did not release
it. The handler sequence this enables: read `INT_STATUS`, clear that channel's
`CONTROL.enable`, then write 1 to the status bit.

One line was added to the DMA's own bench, which checked `irq[0]` without ever
unmasking it.

### DP-SRAM: `regfile` renamed to `sram_regfile`

Both blocks defined a module called `regfile` — the CPU's 32 GPRs and the
SRAM's control/status bank. Compiled into one library the second definition
overwrites the first (`vlog-2275`) and the elaborated design gets whichever was
compiled last. The SRAM's bank was renamed; the CPU's was left alone, since its
testbenches, assertions and documentation all refer to it.

`sram/debug/sim/compile.do` was updated to match. The block's own bench then
runs unchanged: 67 checks, 67 pass.

### DP-SRAM: bandwidth window width

`WIN_W` was a literal 10 while `WINDOW_CYCLES` is a parameter. At the default
1024 they agree. At 2048 the counter is too narrow to reach the end of its own
window, so `window_done` never asserts and `BANDWIDTH_A/B` stop updating —
measured as 0 pulses. Now `WIN_W = $clog2(WINDOW_CYCLES)`.

### What was deliberately not changed

**Port naming.** The DMA still uses unsuffixed `clk` / `rst_n` and `s_axi_*` /
`m_axi_*`; the CPU and the SRAM use `_i`/`_o`. Rewriting a block's port list
changes its interface and invalidates its own testbenches. The SoC top level
connects to the names as they are.

**Everything else that was found.** The remaining defects — including a DMA
buffer overrun on non-multiple-of-32 transfers and a missing byte-enable on the
SRAM register bank — were reported, not repaired. They are in
[TO_MODIFY.md](TO_MODIFY.md).

---

## 2. How the three were merged

`master` had deleted every file in its tip commit, so the CPU merge produced
~88 `modify/delete` conflicts, all of the same kind and all resolved by keeping
the CPU side. Two files, the dual-core test program, were dropped silently —
Git resolves "deleted on one side, untouched on the other" without reporting a
conflict — and were restored explicitly.

The DMA and the SRAM overlapped the CPU on paths, so each was relocated on a
temporary staging branch cut from its own tip (`dma-stage`, `sram-stage`) and
those were merged. The original branches were never modified.

Every block ends up with the same shape — `hdl/` for the design, `debug/` for
its verification:

| Path | From | Contents |
|---|---|---|
| `cpu/` | `RISCV` | CPU, PIC, machine timer |
| `dma/` | `DMA` | multi-channel DMA engine |
| `sram/` | `SDRAM` | dual-port SRAM |
| `soc/` | new | interconnect, SoC top, system verification |

Not carried over: committed simulator output (`work/`, `.wlf`, `.vcd`,
`transcript`, `modelsim.ini`), and the SRAM's duplicate source tree in the
repository root, which had drifted from the copy under `Siemens/`.

---

## 3. What was written to join them

Nothing here replaces anything in the three blocks; it is the fabric between
them, in [soc/hdl/](soc/hdl/).

**`axi_full2lite.v` — the reason a plain interconnect was not enough.** The DMA
is an AXI4-Full master issuing eight-beat INCR bursts; every slave in the
system is AXI4-Lite, which has no bursts. The bridge splits each burst into one
Lite transaction per beat and rebuilds `RLAST` and the single write response.
Two decisions: the burst's write response is the worst response any beat got,
so an error inside a burst cannot be lost; and an unsupported burst (WRAP, or a
narrow transfer) is answered `SLVERR` with nothing issued on the bus, rather
than mistranslated into the wrong addresses.

**`axi_lite_dec.v` — one master to N slaves, with `DECERR`.** Anything outside
every window is answered rather than left to hang. One real bug surfaced here:
routing the *response* phase by the live address closes a combinational loop on
the instruction bus, because the fetch unit issues the next `AR` in the same
cycle the previous `R` beat lands. ModelSim stopped with `vsim-3601 Iteration
limit 5000`. The fix is to route the response by the select latched at the
address handshake — correct on its own terms, since a response can only follow
its own address handshake.

**`axi_lite_arb.v` — M masters to one slave.** Round-robin, one transaction per
grant, released on the response beat. Used only in front of the data memory,
which is single-ported.

**`axi_lite_ram.v` — the instruction and data memories.** A synthesizable
AXI4-Lite RAM with byte enables and a `$readmemh` image, so the SoC is a
complete design rather than one that only elaborates with a behavioural model
attached. The array is zeroed before the image loads, so no X reaches the CPU.
Latency and backpressure parameters, inert at their defaults, let the
regression sweep bus timing.

**`soc_top.v` and `soc_addr_map.vh`.** Three properties of the map are
decisions rather than defaults: each window's mask is exactly its size, so an
access past the end of a block cannot alias back onto it; reachability is not
uniform, so the instruction bus reaches only IMEM and the DMA reaches only DMEM
and the SRAM; and the SRAM is reached at the same address from both sides, the
CPU on port A and the DMA on port B, which is what keeps its collision detector
alive in the assembled system.

---

## 4. Verification

The CPU's existing regression was run before anything changed, so "the merge
broke nothing" is measured rather than assumed: **14/14**, and 14/14 again
after the block was relocated.

| Regression | Result |
|---|---|
| CPU, 14 runs (`make modelsim`) | all pass |
| SoC, 9 runs (`make soc`) | all pass |
| SoC lint + SVA on Verilator (`make soc-sva`) | lint clean, all benches pass |
| DMA block bench | passes |
| DP-SRAM block bench | 67/67 |

The nine SoC runs are three benches over four bus timings: the burst bridge
alone, the system with the CPU asleep while the DMA works, and the system with
the CPU working the bus throughout. The third exists because measuring the
second showed it never contended the arbiter, never drove both SRAM ports in
one cycle and never made an unmapped access. The stress bench measures those
and fails if they did not happen.

An SVA layer under `soc/debug/sva/` is bound to the fabric and runs on
Verilator, since ModelSim ASE cannot compile assertions. It checks AXI4-Lite
and AXI4-Full protocol on every port, plus the fabric's own decisions: disjoint
address windows, one-hot grants, a grant held until its response beat, a parked
master that sees nothing, and a burst whose beat counter and `RLAST` agree.

Details, including mutation testing and the list of what no test covers, are in
[VERIFICATION_REPORT.md](VERIFICATION_REPORT.md).
