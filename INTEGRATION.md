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

Four source changes, none of which touches a block's algorithm — no state
machine, no arbitration, no collision detection was modified.

| Block | Change | Why |
|---|---|---|
| DMA | its bench writes `INT_ENABLE` before checking `irq` | the bench never unmasked the line it asserts on |
| DP-SRAM | module `regfile` renamed `sram_regfile` | name collision with the CPU |
| DP-SRAM | its `compile.do` follows the rename | the block bench stopped compiling |
| DP-SRAM | `WIN_W` derived from `WINDOW_CYCLES` | the two could silently disagree |

### DMA: the RTL is now identical to its own branch

Integration originally needed two changes to `mc_dma_top.v` — `active_master_ch`
was read before it was declared, so the block did not compile, and `irq` was
driven from the raw channel lines with `INT_STATUS` and `INT_ENABLE` left
unconnected, so masking did nothing and write-1-to-clear could not release the
line. Both were reported, and both are now fixed on the `DMA` branch itself. All
five RTL files under `dma/hdl/` are byte-identical to that branch; nothing in
the DMA's design is carried here as a local edit.

What does still differ is one line in the block's own bench:

```verilog
axil_write({24'h0, ADDR_INT_ENABLE}, 32'h0000_000F);
```

`tb_mc_dma_top` checks `irq[0]` but never writes `INT_ENABLE`, which resets to
zero. Now that `irq` is `INT_STATUS & INT_ENABLE`, the bench cannot pass without
it. See item 3 of [TO_MODIFY.md](TO_MODIFY.md).

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

**Everything else that was found in someone else's block.** The remaining
defects - including a burst length that overruns the destination for a
descriptor shorter than four bytes, a missing byte-enable on the SRAM register
bank, and eight words of the SRAM array with no address - were reported, not
repaired. They are in [TO_MODIFY.md](TO_MODIFY.md). Defects in the CPU, the PIC
and the fabric were fixed, and are in section 4 below.

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

The DMA was merged again later, the same way, when its branch gained the
transfer-length fix, the interrupt pulse and the `data_fifo` reset. That merge
took the block's RTL wholesale; the only conflict was `sim.do`, which the branch
had emptied and `master` still held an unrelated project in.

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

## 4. What was fixed in the CPU, the PIC and the fabric

A later adversarial review of this side of the SoC found nine defects. They are
listed here because several of them were previously written up as design
decisions or integration rules, which is what a defect with a workaround looks
like from the inside.

| Where | Defect | Fix |
|---|---|---|
| `cpu_top.v` | one in-progress bit could not tell an interrupt return from an exception return | one bit per open trap level |
| `pic.v` + `cpu_top.v` | a source masked in `mie` was still selected, so it starved everything behind it | `mie[31:16]` takes part in the resolution |
| `pic.v` + `cpu_top.v` | `mip` showed only the offered source | the PIC exports its whole pending set |
| `soc_addr_map.vh` | 64 KB windows over blocks that decode 8 address bits | 256 B windows, the size of each register file |
| `pic.v` | bump escalation assumed band 0 is always the most urgent | it steps up the urgency order `BAND_CONFIG` defines |
| `pic.v` | an edge arriving in the claim cycle was cleared | the edge outranks the claim |
| `pic.v` | the software-trigger key was compared, not required to be written | both key lanes must be strobed |
| `csr_file.v` | `mtvec.MODE` stored the reserved encodings 2 and 3 | a reserved MODE folds to direct |
| `csr_file.v` | `CSRRS`/`CSRRC` on a counter dropped that cycle's event | they apply to the incremented value |

Two of these deserve more than a table row.

**The two interrupt masks did not compose.** The PIC resolved a winner without
knowing `mie`, and the core applied `mie` to the winner it was handed. A source
enabled in `INT_ENABLE` but masked in `mie` was therefore selected and never
claimed: the resolver parked on it, nothing less urgent was ever offered, and a
`WFI` waiting on one of those sources never woke. This had been documented as an
integration rule - do not enable a source no handler will service - and the CPU's
own test program disabled the source in question before its channel sweep, so the
suite passed by avoiding the case. The core now hands `mie[31:16]` to the PIC and
the resolver skips masked sources; the sweep leaves the source enabled and masked
for the whole run, and hangs without the fix.

**`MRET` did not know which trap it was returning from.** The core tracked one
`in_irq` bit, set on any interrupt and cleared on any `MRET`. Two nested handlers
sent one end-of-interrupt instead of two, leaving the outer level on the PIC's
nesting stack with its source active forever; a synchronous exception inside a
handler sent the end-of-interrupt on the exception's return, popping the
interrupt while its handler was still running. The core now keeps one bit per
open trap level, 16 deep, which is the largest `NEST_MAX` the PIC accepts.

---

## 5. Verification

The CPU's existing regression was run before anything changed, so "the merge
broke nothing" is measured rather than assumed: **14/14**, and 14/14 again
after the block was relocated.

| Regression | Result |
|---|---|
| CPU, 15 runs (`make modelsim`) | all pass |
| SoC, 14 runs (`make soc`) | all pass |
| CPU lint + SVA + coverage on Verilator (`make test`) | passes, 88/92 bins |
| SoC lint + SVA on Verilator (`make soc-sva`) | lint clean, all benches pass |
| DMA block bench | passes |
| DP-SRAM block bench | 67/67 |

The fourteen SoC runs are five benches: the address map, the burst bridge, the
system with the CPU asleep while the DMA works, the system with the CPU working
the bus throughout, and a walk over DMA transfer lengths — the last three over
four bus timings each. Three of them exist because a working program cannot
reach what they cover. The stress bench was written after measuring the plain
system bench, which never contended the arbiter, never drove both SRAM ports in
one cycle and never made an unmapped access; it measures those and fails if they
did not happen. The address-map bench checks a property no correct program can
exercise, since correct software never issues an address that should not decode.
The length bench moves 64, 40, 20, 8 and 4 bytes, because the other two system
programs move exact multiples of the DMA's 32-byte burst and so never make the
channel issue a short final burst — which is where a DMA writes past what it was
asked to move.

An SVA layer under `soc/debug/sva/` is bound to the fabric and runs on
Verilator, since ModelSim ASE cannot compile assertions. It checks AXI4-Lite
and AXI4-Full protocol on every port, plus the fabric's own decisions: disjoint
address windows, one-hot grants, a grant held until its response beat, a parked
master that sees nothing, and a burst whose beat counter and `RLAST` agree. The
CPU block's own assertion binds - the pipeline invariants and the PIC's - are
compiled into the SoC flow too; until they were split out of the coverage bind
they were dark in every SoC run.

Every defect in section 4 has a test that fails without its fix. The three PIC
ones are in `cpu/debug/hdl/tb_pic_sched.v`, the two nesting ones in
`cpu/debug/hdl/tb_traps.v`, the address map in `soc/debug/hdl/tb_addr_map.v`,
`mtvec.MODE` in `cpu/debug/hdl/tb_csr_ro.v`, and the interrupt mask in the
channel sweep of `cpu/debug/sim/program_axi.s`.

Details, including mutation testing and the list of what no test covers, are in
[VERIFICATION_REPORT.md](VERIFICATION_REPORT.md).
