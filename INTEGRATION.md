# SoC integration log

Every change made to the CPU, DMA and DP-SRAM blocks in order to make them
work together as one SoC, and why each one was needed.

The three blocks were developed independently on the `RISCV`, `DMA` and
`SDRAM` branches. Those branches are untouched by this integration: nothing
was rebased, rewritten or force-pushed. The work happens on `master`, which
now carries all three blocks plus the interconnect that joins them.

Read this as the answer to "what did you have to change in their code, and
why?". The short version is five source changes, none of them touching a
block's algorithm.

| # | Block | Change | Reason |
|---|---|---|---|
| [2.1](#21-active_master_ch-was-used-before-it-was-declared) | DMA | `active_master_ch` declaration moved above its use | the block did not compile |
| [2.2](#22-int_status-and-int_enable-were-connected-to-nothing) | DMA | `irq` driven from `INT_STATUS & INT_ENABLE` | two registers software could write did nothing |
| [3.1](#31-module-regfile-renamed-to-sram_regfile) | DP-SRAM | module `regfile` renamed `sram_regfile` | name collision with the CPU's register file |
| [3.2](#32-compile-list-updated-for-the-rename) | DP-SRAM | its `compile.do` follows the rename | the block bench would not compile |
| [3.3](#33-the-bandwidth-window-width-was-independent-of-its-parameter) | DP-SRAM | `WIN_W` derived from `WINDOW_CYCLES` | a width mismatch Verilator caught; the two could disagree |

---

## 1. Repository layout

`master` merges the three block branches into one tree. To make that possible
without path collisions, two of the blocks were relocated on temporary staging
branches (`dma-stage`, `sram-stage`) cut from the branch tips, and those
staging branches were merged. The original branches were never modified.

Every block now has the same shape — `hdl/` for the design, `debug/` for its
verification — so nothing about the tree depends on which block you happen to
be looking at.

| Path | Origin | Contents |
|---|---|---|
| `cpu/` | `RISCV` | CPU, PIC, machine timer + their verification and docs |
| `dma/` | `DMA` | multi-channel DMA engine + its verification |
| `sram/` | `SDRAM` | dual-port SRAM + its verification |
| `soc/` | new | interconnect, SoC top level, system verification |
| `docs/` | `RISCV` | engineering documentation (LaTeX) |

The CPU's build system refers to roughly fifty paths, but all of them are
relative *within* the block (`../../hdl/alu.v` from `debug/sim/`), so moving
`hdl/` and `debug/` together under `cpu/` left every one of them correct. The
same held for the links inside `README.md` and `ARCHITECTURE.md`, which is why
both moved into `cpu/` rather than being rewritten. Only four things outside
the block needed updating: the `Makefile`, the SoC filelist, the SoC bench
include path, and the root `README.md`, which is now the SoC landing page.

### Collisions the relocation resolved

| File | Present in | Resolution |
|---|---|---|
| `README.md`, `.gitignore` | all three | only `RISCV` had modified them; taken from there |
| `debug/sim/sim.do`, `debug/sim/wave.do` | `RISCV` and `DMA` | DMA's copies moved to `dma/debug/sim/` |

Two files, `debug/sim/program_dual.hex` and `debug/sim/program_dual.s`, were
silently dropped by the CPU merge: `master`'s tip commit had deleted every
file in the tree, and Git resolves "deleted on one side, untouched on the
other" as a delete without reporting a conflict. They are the dual-core
regression's test program, so they were restored explicitly.

### Files not carried over

The `DMA` and `SDRAM` branches had simulator output committed: ModelSim `work/`
libraries, `vsim.wlf`, `transcript`, `modelsim.ini`, `.vcd` dumps and a `.bak`
file. These are build artifacts, regenerated on every run, and are already
covered by `.gitignore`.

The `SDRAM` branch also carried a full copy of its sources in the repository
root alongside the copy under `Siemens/`. The two had drifted apart — the last
upload updated only the `Siemens/` copy — so the root copies were stale. Only
`Siemens/` was kept, as `sram/`.

One file existed only in that stale root copy: `tb_regfile.v`, a bench for the
register bank. It was not carried over, and it was already dead before this
integration: it instantiates the module with the old unsuffixed port names
(`clk`, `a_reg_valid`, `irq`), which the block renamed to `clk_i`,
`a_reg_valid_i`, `irq_o` in a later upload. It could no longer compile against
its own DUT on its own branch. Rewriting it is listed under
[open points](#7-open-points).

---

## 2. Changes to the DMA block

### 2.1 `active_master_ch` was used before it was declared

**Symptom.** The block did not compile. ModelSim:

```
** Error: mc_dma_top.v(103): (vlog-2730) Undefined variable: 'active_master_ch'.
** Error (suppressible): mc_dma_top.v(117): (vlog-2388) 'active_master_ch'
   already declared in this scope (mc_dma_top) at mc_dma_top.v(103).
```

**Cause.** `mc_dma_top` read `active_master_ch` in four continuous assignments
at line 103, but declared the register fourteen lines further down:

```verilog
    wire fetch_data_valid_ch0 = fetch_data_valid && active_master_ch[0];   // line 103
    ...
    reg [3:0] active_master_ch;                                            // line 117
```

Verilog requires a variable to be declared before it is referenced. The name
is not an implicit net either, because it is later declared as a `reg`, which
is what produces the second, contradictory-looking error.

**Fix.** The declaration and the `always` block that drives it were moved above
the assignments that read them. No logic changed — same register, same reset
value, same update condition.

This was present on the branch tip as fetched, not introduced by the
integration. It was still present after the branch was updated mid-work, so it
was re-checked against the newer tip and fixed there.

### 2.2 `INT_STATUS` and `INT_ENABLE` were connected to nothing

**Symptom.** Elaborating the SoC reported:

```
** Warning: (vsim-2685) Too few port connections for 'slave_inst'. Expected 39, found 37.
** Warning: (vsim-3722) Missing connection for port 'int_enable'.
** Warning: (vsim-3722) Missing connection for port 'int_status'.
```

**Cause.** The DMA's register file implements both registers properly —
`INT_STATUS` is sticky, set by the per-channel lines, write-1-to-clear;
`INT_ENABLE` is a plain read/write mask. But `mc_dma_top` left both outputs
unconnected and drove the top-level interrupt straight from the raw
per-channel lines:

```verilog
    assign irq = hw_irq;
```

So two registers that software can write and read back did nothing at all.
Masking an interrupt had no effect, and writing 1 to `INT_STATUS` did not
release the request — the only way to deassert the line was to disable the
channel itself.

**Fix.** The outputs are connected and the interrupt is taken from them:

```verilog
    assign irq = int_status_w[3:0] & int_enable_w[3:0];
```

This makes the documented register map real and gives the handler the usual
sequence: read `INT_STATUS` to find the channel, clear that channel's
`CONTROL.enable` so the raw line drops, then write 1 to the `INT_STATUS` bit to
release the request. The SoC's own test handler
([program_soc.s](soc/debug/sim/program_soc.s)) does exactly that.

**Consequence for the DMA's own bench.** `tb_mc_dma_top` checked `irq[0]`
after a transfer without ever unmasking it, which used to work because the mask
was ignored. One line was added to its setup:

```verilog
    axil_write({24'h0, ADDR_INT_ENABLE}, 32'h0000_000F);
```

The bench passes unchanged otherwise, and the elaboration warnings are gone.

---

## 3. Changes to the DP-SRAM block

### 3.1 Module `regfile` renamed to `sram_regfile`

**Cause.** Both blocks define a module called `regfile`:

- `cpu/hdl/regfile.v` — the CPU's 32 general-purpose registers
- `sram/hdl/regfile.v` — the DP-SRAM's control/status register bank

On their own branches that was fine. In the SoC they compile into the same
library, where the second definition overrides the first and the elaborated
design silently gets the wrong module.

**Fix.** The DP-SRAM's bank was renamed:

| Before | After |
|---|---|
| `sram/hdl/regfile.v` | `sram/hdl/sram_regfile.v` |
| `module regfile #(...)` | `module sram_regfile #(...)` |
| `regfile #(.REG_ADDR_W(3)) u_regfile (...)` in `dp_sram_top.v` | `sram_regfile #(.REG_ADDR_W(3)) u_regfile (...)` |
| `sram/hdl/regfile_test_vectors.txt` | `sram/hdl/sram_regfile_test_vectors.txt` |

The instance name `u_regfile` was left alone: instance names are scoped to
their parent module and cannot collide.

The CPU's `regfile` was not renamed. It is referenced by the CPU's own
testbenches, assertions and documentation, so renaming it would have touched
far more code for the same result.

### 3.2 Compile list updated for the rename

`sram/debug/sim/compile.do` still named `regfile.v`. One line changed:

```
vlog -work work ../../hdl/sram_regfile.v
```

The block's own bench then runs unchanged: **67 checks, 67 pass**.

### 3.3 The bandwidth window width was independent of its parameter

**Symptom.** Verilator lint:

```
%Warning-WIDTHEXPAND: sram_regfile.v:80: Operator EQ expects 32 or 11 bits on
the LHS, but LHS's VARREF 'window_cnt' generates 10 bits.
```

**Cause.** The bandwidth counters run over a window of `WINDOW_CYCLES`, a
module parameter. The counter's width was a separate literal:

```verilog
    localparam WIN_W = 10;
    ...
    wire window_done = (window_cnt == WINDOW_CYCLES-1);
```

At the default `WINDOW_CYCLES = 1024` the two agree and the code is correct.
They are not tied together, though, so raising `WINDOW_CYCLES` past 1024 would
leave the counter too narrow ever to reach the end of its own window:
`window_done` would never assert, and the `BANDWIDTH_A` / `BANDWIDTH_B`
registers would silently stop updating. A parameter that quietly breaks the
block when changed is worse than one that does not exist.

**Fix.** The width is derived from the parameter, and the comparison is between
two values of the same width:

```verilog
    localparam WIN_W = $clog2(WINDOW_CYCLES);
    localparam WINDOW_LAST = WINDOW_CYCLES - 1;
    wire window_done = ({{(32-WIN_W){1'b0}}, window_cnt} == WINDOW_LAST);
```

Behaviour at the default parameter is identical; the block's own bench still
reports 67 of 67 checks passing.

---

## 4. What was deliberately *not* changed

**Port naming.** The DMA still uses unsuffixed `clk` / `rst_n` and
`s_axi_*` / `m_axi_*`. The CPU and the DP-SRAM use the `_i`/`_o` convention.
Rewriting a block's port list is a change to its interface: it would invalidate
that block's own testbenches for no functional gain. The SoC top level connects
to the names as they are, and says so where it does.

(The `SDRAM` branch had already converted itself to `_i`/`_o` before this
integration, so no adaptation was needed there either.)

**The blocks' algorithms.** No change was made to the DMA's channel state
machine, arbitration or scatter-gather logic, nor to the SRAM's collision
detection, bandwidth counters or slave FSM. Everything above is a connection
or a name.

---

## 5. New RTL written for the integration

None of this replaces anything in the three blocks; it is the fabric between
them. It lives in [soc/hdl/](soc/hdl/).

### `axi_full2lite.v` — the reason an interconnect was not enough

The DMA is an AXI4-Full master: it issues INCR bursts of eight 32-bit beats
and expects `WLAST`/`RLAST` and one write response per burst. Every slave in
the system is AXI4-Lite, which has no bursts at all. Without a bridge the two
simply cannot be wired together.

The bridge splits each burst into one AXI4-Lite transaction per beat and
reassembles what the DMA expects. Two decisions in it are worth stating:

- **The write response is sticky.** AXI4 gives a burst exactly one write
  response, so the burst's response is the worst response any beat received.
  Losing an error inside a burst would let a failed transfer look clean.
- **Unsupported requests are refused, not approximated.** It handles INCR and
  FIXED bursts of 32-bit beats. A WRAP burst or a narrow transfer is answered
  `SLVERR` with nothing issued on the bus, rather than being translated into
  the wrong addresses.

### `axi_lite_dec.v` — 1 master to N slaves, with `DECERR`

Generalises `cpu/debug/hdl/axi_lite_dec2.v`, which the CPU block had written as
a testbench stand-in for exactly this. Anything outside every window is
answered `DECERR` instead of being left to hang the master.

**One real bug was found here, and it is worth recording.** The original
routing rule — inherited from `axi_lite_dec2` — selects the slave from the live
address whenever `xVALID` is high, for the response path as well as the address
path. On the CPU's data bus that is harmless. On its *instruction* bus it is a
combinational loop: the fetch unit issues the `AR` for fetch N+1 in the same
cycle the `R` beat of fetch N lands, so `RVALID` came to depend on `ARVALID`,
which already depended on the `R` beat. ModelSim stopped with

```
** Error (suppressible): (vsim-3601) Iteration limit 5000 reached at time 125 ns.
```

The fix is to route the *response* phase by the select latched at the address
handshake, and only the address phase by the live address. That is correct on
its own terms — a response can only follow its own address handshake — and it
breaks the loop. The reasoning is written into the module header so the next
person does not reintroduce it.

### `axi_lite_arb.v` — M masters to 1 slave

Round-robin, one transaction per grant, released on the response beat. Used
only in front of the data memory, which is single-ported. The dual-port SRAM
deliberately has no arbiter: each master gets its own physical port.

### `axi_lite_ram.v` — the instruction and data memories

A synthesizable AXI4-Lite RAM with byte enables and a `$readmemh` image, so the
SoC is a complete design rather than something that only elaborates with a
behavioural model attached. The array is zeroed before the image loads: an `X`
returned on `RDATA` propagates into the register file, from there into an
address, and surfaces hundreds of cycles later somewhere unrelated.

### `soc_top.v` and `soc_addr_map.vh`

The top level and the address map. Three properties of the map are design
decisions rather than defaults, and they are argued in the header of
[soc_addr_map.vh](soc/hdl/soc_addr_map.vh):

- **Each window's mask is exactly its size**, so an access inside a window but
  past the end of the block behind it cannot alias back onto that block — it
  misses every window and gets `DECERR`. This matters most for the SRAM, whose
  1 KB is far smaller than its address granularity suggests.
- **Reachability is not uniform.** The instruction bus reaches only IMEM; the
  data bus reaches everything except IMEM; the DMA reaches only DMEM and the
  SRAM. So there is no self-modifying-code path, and a runaway descriptor
  cannot reprogram the interrupt controller.
- **The SRAM is reached at the same address from both sides**, the CPU on port
  A and the DMA on port B. That is what a dual-port memory is for, and it is
  also what keeps the block's collision detector reachable in the assembled
  system instead of being dead logic behind an arbiter.

### Address map

| Window | Base | Size | Reached by |
|---|---|---|---|
| IMEM | `0x0000_0000` | 8 KB | CPU instruction bus |
| DMEM | `0x0000_2000` | 8 KB | CPU data bus, DMA (arbitrated) |
| DP-SRAM | `0x1000_0000` | 1 KB | CPU data bus (port A), DMA (port B) |
| PIC | `0x3000_0000` | 64 KB | CPU data bus |
| machine timer | `0x3001_0000` | 64 KB | CPU data bus |
| DMA registers | `0x3002_0000` | 64 KB | CPU data bus |

### Interrupt map

| PIC source | Device |
|---|---|
| 0..3 | DMA channels 0..3 (done or error) |
| 4 | DP-SRAM collision / cooldown |
| 5, 6 | unused, tied low |
| 7 | machine timer |
| 8..15 | unused, tied low |

Channel 7 for the timer follows the convention the CPU block's own system
bench already used, so nothing there had to be renumbered.

---

## 6. Verification

### Baseline, before anything was changed

The CPU's existing regression was run first, so that "the merge broke nothing"
is a measured claim rather than an assumption:

```
14/14 runs PASSED, 0 FAIL lines, 0 compile errors
```

It was run again after the block was relocated into `cpu/`: **still 14/14**.

### After integration

| Regression | Result |
|---|---|
| CPU, 14 runs (`make modelsim`) | all pass |
| SoC, 9 runs (`make soc`) | all pass |
| SoC lint + SVA on Verilator (`make soc-sva`) | lint clean, all benches pass |
| DMA block bench (`tb_mc_dma_top`) | passes |
| DP-SRAM block bench (`tb_dp_sram_top`) | 67/67 checks pass |

All three blocks compile into a single ModelSim library with **0 errors and
0 warnings**, and the whole SoC lints clean under `verilator -Wall`.

### What the SoC regression proves

**`tb_full2lite`** drives the bridge directly against a real RAM: 8-beat
bursts (the DMA's actual traffic), single-beat bursts, odd lengths with partial
byte strobes, FIXED bursts, `RLAST` placement, the unsupported WRAP and narrow
cases, and recovery to a clean burst afterwards.

**`tb_soc_top`** runs real software on the real CPU. The bench supplies only a
clock, a reset and a program image; the checking is done by the program, which
builds a descriptor in data memory, programs DMA channel 0, sleeps on `WFI`, is
woken by the DMA's completion interrupt through the PIC, and compares what the
DMA moved against what it was asked to move. One run covers:

- the CPU data bus decoded to four different slaves
- the DMA fetching its descriptor and source data from DMEM, arbitrated
  against the CPU's own data bus
- 64 bytes, so the channel loops over two 32-byte chunks rather than finishing
  on its first pass
- eight-beat AXI4-Full bursts crossing the bridge in both directions
- the SRAM written by the DMA on port B and read back by the CPU on port A
- DMA completion to PIC source 0 to CPU interrupt to handler to `MRET`,
  including the `WFI` wake and the release of the interrupt line

The bench also reads the SRAM array directly, not only through the CPU, so a
symmetric addressing error on both the write and the read path could not hide.

**`tb_soc_stress`** exists because of what measuring `tb_soc_top` showed. A
coverage probe over that run reported:

```
DMEM arbiter contended cycles : 0
SRAM both ports active        : 0
SRAM real conflicts           : 0
DECERR responses seen         : 0
```

The system test passed without ever contending the arbiter, ever driving both
SRAM ports in the same cycle, or ever making an unmapped access. The CPU sleeps
on `WFI` while the DMA works, so the two never compete. Round-robin arbitration,
master parking, the SRAM's collision detection and the decoder's error responder
were all passing by not being tried, which is worse than not being tested,
because the green run reads like proof.

The stress bench keeps the CPU working the bus for the whole of a 512-byte
transfer and then asserts the transfer is still bit-perfect. Getting the CPU and
the DMA to actually touch the same word in the same cycle took three attempts,
and the failures are recorded in the program's header because they are the
instructive part:

| attempt | result |
|---|---|
| sweep the SRAM independently of the DMA | 3 cycles with both ports busy, no shared address |
| sweep it densely, 8 loads per pass | 32 cycles with both ports busy, still no shared address |
| follow the DMA word by word | the CPU trails it, so every word is already written on arrival and it never waits |

The measurement that explained it: port A was busy 162 cycles out of 2781 and
port B exactly 64, one per word written, and the two were statistically
independent. Chasing a moving pointer cannot correlate them.

What works is parking the CPU one whole 32-byte burst *ahead* of the word it
just saw arrive, polling in a two-instruction loop. It is then hammering the
exact address the DMA's next write burst starts at, for every one of the
sixteen bursts. That turns a single coincidence into sixteen chances.

Current run:

```
DMEM arbiter contended cycles : 25
DMEM grants  CPU / DMA        : 601 / 272
SRAM port A / port B active   : 341 / 128
SRAM both ports active        : 10
SRAM same address, both active: 5
SRAM real conflicts           : 5
DECERR responses seen         : 1
```

Those numbers are checked, not printed. The bench **fails** if the arbiter was
never contended, if only one master ever used the shared memory, if the SRAM
never saw both ports at once, if no conflict occurred, or if no DECERR was
observed. A coverage number nobody checks decays into a comment; this one
cannot, because the run goes red the moment it stops covering.

The run also confirms the collision behaviour end to end: the SRAM resolves a
read-versus-write conflict in favour of the writer, so the DMA always wins and
the CPU's colliding read takes a `SLVERR` and traps. Five collisions were
raised, delivered to the CPU through PIC source 4, handled and cleared - and
the 512-byte transfer came out bit-perfect regardless.

---

## 7. The assertion layer

The CPU block already had an SVA layer bound to its own ports. The fabric had
none, so it grew one: `soc/debug/sva/`, bound to the RTL and never touching it.
ModelSim ASE cannot compile assertions, so it runs on Verilator, the same split
the CPU block uses.

`axi_lite_sva.sv` was reused as-is - it is a generic AXI4-Lite port checker -
and bound to every fabric port the CPU block's own bind file does not reach:
the bridge's Lite master side, the arbiter's slave side, both memories, the
DMA's register slave, and both SRAM ports.

Two checkers are new:

**`axi_full_sva.sv`** watches the one port that is not AXI4-Lite: the DMA's
AXI4-Full master. It shadows the burst - length, beat counter, outstanding
state - and asserts that `WLAST` lands on beat `AWLEN` and `RLAST` on beat
`ARLEN`, that neither lands early, and that one burst is outstanding per
direction. It also asserts the burst is inside the subset the bridge supports,
under a `CHECK_SUBSET` parameter: that is a contract on the master, so it is on
for the DMA's port and off where the same checker watches the bridge's slave
side, because `tb_full2lite` drives a WRAP burst on purpose to prove the bridge
refuses it. (The assertion fired the first time it was run, on that test,
correctly - which is how the parameter came to exist.)

**`soc_fabric_sva.sv`** asserts the fabric's *decisions* rather than its
protocol. A decoder that routes a response to the wrong slave, or an arbiter
that hands the memory to two masters at once, can be perfectly protocol-legal
on every individual port. The properties worth naming:

- the address windows are disjoint (`$onehot0` on the hit vector) - the
  soundness argument for the whole decoder, now checked instead of asserted in
  a comment on `soc_addr_map.vh`
- a response is routed to exactly one target, and `DECERR` never comes from a
  leg that decoded to a real slave
- the grant is one-hot, is only taken by a master that was requesting, and is
  held until the response beat that ends its transaction
- a parked master sees no `READY` and no response at all - what makes waiting
  for a grant indistinguishable from a slow slave, and so protocol-legal
- the bridge's beat counter stays inside the burst length, `RLAST` tracks it,
  an INCR burst advances exactly one word per beat, and an error response is
  never lost inside a burst

---

## 8. Bus timing

Every system-level bench runs under four bus timings rather than one:

| | IMEM | DMEM |
|---|---|---|
| nominal | - | - |
| high fixed latency | RL=2 | RL=3, WL=2 |
| random backpressure A | 25% stalls | 35% stalls |
| random backpressure B | 40% stalls | 20% stalls, RL=1 |

The controls live on `axi_lite_ram` and are surfaced through `soc_top` so the
regression can set them with `-G` without editing anything. They are inert at
their defaults: `STALL_PROB = 0` leaves the backpressure generator out of the
elaborated design entirely (it is inside a `generate`), and with the latencies
at zero the wait counters are never loaded. The synthesised SoC is the RAM it
always was.

This matters more than a coverage number. The decoder holds a latched routing
select across a response, the arbiter holds a grant across it, and the bridge
holds a beat counter across it. All three are exactly the kind of state that
only breaks when a slave takes its time, and at one-cycle memory none of it is
ever held for more than a cycle.

The stress bench's coverage floors are enforced in **all four** timings, not
only the nominal one. That was not a given - injected latency changes the
schedule - so it was measured: the arbiter is contended for 161 to 224 cycles
and at least one real SRAM address conflict occurs in every configuration.

---

## 9. Open points

Things a following iteration should pick up. None of them block the SoC as it
stands.

- **`tb_regfile.v` for the SRAM register bank.** Dead since the block renamed
  its ports; the register bank is currently covered only indirectly, through
  `tb_dp_sram_top`.
- **The DMA's multi-channel paths in the SoC.** The system test drives channel
  0. The other three channels and the round-robin scheduling policy are
  covered by the DMA's own bench, not yet at system level.
- **The SoC is not in CI.** `make soc` and `make soc-sva` are run locally.
  The GitHub workflow still runs only the CPU block's Verilator flow.
- **No synthesis run.** The design lints clean but has not been through a
  synthesis tool, so area and timing closure are unknown.
