# To modify

Open DMA and dual-port SRAM items, found on 23 September 2026 against the
integrated `origin/DMA b3d0422` and `origin/SDRAM 28cd380`. The newer
`origin/DMA 43d0126` renames three internal wires and translates comments; it
changes no port and no behaviour, so every DMA item below applies to it too.
The DMA and SRAM RTL is left as its owners wrote it; each item says what the
owner has to change.

Evidence comes from three places:

- `soc_probe_upstream`, a diagnostic that drives the DMA channel and the SRAM
  register bank through their ports. It prints `OBSERVE` lines and is not part
  of the passing regression. Commands are at the end of this file.
- `soc_tb_same_addr` and `soc_tb_dma_fault`, SoC benches of the regression.
- The owners' own benches, run unchanged from a copy of `dma/` and `sram/`.

## DMA

### 1. A descriptor with control bit 0 clear never finishes

**What happens.** `mc_dma_channel.v` reaches DONE only when the last write
burst completes with `desc_ctrl[0]` set. With a control word of 0, the probe
copies the 32 bytes of the descriptor and the channel stays ACTIVE. Its length
is now 0, so the next request has ARLEN=255: a 1 KiB read from the next source
block (0x2120), then a 1 KiB write, then another, with the source and
destination pointers advancing 32 bytes per block.

**Why it is a problem.** One descriptor turns into an unbounded copy that
overwrites memory past its destination, block after overlapping block, until an
address falls outside the DMA's windows and ends the channel in ERROR. In the
SoC that memory is DMEM and the SRAM: the CPU's data, stack and buffers. The
control word has no documented meaning, so leaving it at 0 is an easy mistake,
and no DONE interrupt ever arrives to show it.

**Owner action.** Document the descriptor control word. End the transfer when
its length is exhausted, whatever the control bits; if bit 0 is meant as "last
descriptor" for chaining, implement the next-descriptor fetch and test both
values.

### 2. A length of 0 to 3 bytes becomes a 1 KiB burst

**What happens.** `req_len_o = desc_len[7:2] - 1` underflows for 0, 1, 2 and 3
bytes: the probe sees ARLEN=255, a 256-beat request of 1024 bytes.

**Why it is a problem.** A request for a few bytes, or for none, writes 1 KiB
at the destination. In the SoC that is the whole SRAM or 1 KiB of DMEM, and in
DMEM the channel still ends in DONE.

**Owner action.** Reject lengths below one word before any request, or
implement partial transfers with the right write strobes. Add these lengths to
the owner bench.

### 3. The last partial word is dropped

**What happens.** Low length bits are discarded: the probe sees 5 bytes
requested as 4 and 22 bytes as 20.

**Why it is a problem.** The last one to three bytes are never copied, and the
channel still reports DONE, so software has no sign that the copy is short.

**Owner action.** Define the alignment contract. Either reject a length that is
not a multiple of four, or copy the final partial word with a partial strobe.

### 4. The descriptor fetch reads eight words and uses four

**What happens.** In FETCHING the channel requests ARLEN=7, eight words, and
keeps words 0 to 3 (source, destination, length, control). The probe shows the
eight-beat fetch.

**Why it is a problem.** A valid four-word descriptor placed in the last 16
bytes of DMEM or the SRAM makes the fetch run past the end of the window; the
extra beats get DECERR and the channel ends in ERROR although the descriptor is
correct. Every fetch also costs twice the bus traffic it needs.

**Owner action.** Fetch four words (ARLEN=3), or document a 32-byte descriptor
with its alignment so software can place it safely.

### 5. Resume after abort restarts the transfer

**What happens.** Abort takes the channel to SUSPENDED at the end of the current
burst. Resume goes back to FETCHING, which reloads the descriptor. In the probe,
a 64-byte copy aborted after its first 32 bytes resumes by reading 0x2100 and
writing 0x40000020 again: the first half is copied a second time.

**Why it is a problem.** "Resume" suggests continuing where the transfer
stopped. Restarting transfers the finished part again, and if software changed
the descriptor or the source while the channel was suspended, the two halves of
the destination no longer come from the same copy.

**Owner action.** Keep the current source, destination and remaining length
across a suspension and continue from them, or document that resume restarts
the descriptor.

### 6. Token refill can overflow before saturation

**What happens.** With refill 40000 and maximum 65535, two refill periods give
40000 and then 14464. The 16-bit sum wraps before it is compared with the
maximum. The upstream fix `b3d0422` does not cover this setting.

**Why it is a problem.** A channel configured for a high rate ends up with fewer
tokens than one configured for a lower rate, so throttling does the opposite of
what was set.

**Owner action.** Add in 17 bits, compare, then saturate to the maximum. Test the
overflow boundary.

### 7. The owner benches do not elaborate

**What happens.** All eight benches in `dma/debug/hdl` instantiate modules that
no longer exist (`mc_dma_top`, `dma_channel`, `priority_arbiter`,
`axi4_full_master`, `axi4_lite_slave`). ModelSim stops each one with
`vsim-3033`. `dma/debug/sim/sim.do` is empty. `tb_mc_dma_top.v` also expects an
interrupt without first setting `INT_ENABLE`.

**Why it is a problem.** The current DMA RTL has no block-level test of its own,
so nothing at block level checks lengths, control words, abort or refill, where
items 1 to 6 are.

**Owner action.** Port the benches to the current module names and ports, give
each a pass/fail verdict, and fill `sim.do` with a script that runs them all.

## Dual-port SRAM

### 1. A same-cycle collision fails the losing access

**What happens.** When both ports write one word in the same cycle,
`FORCE_PRIORITY` picks the winner and the loser is answered SLVERR; its data is
dropped. A read that meets a write on the same word is answered SLVERR the same
way. `soc_tb_same_addr` produces both write outcomes in the SoC. With the CPU on
port A winning, the refused DMA beat fails the burst and the channel ends in
ERROR. With the DMA on port B winning, the refused CPU store traps as a store
access fault (cause 7).

**Why it is a problem.** Both masters issued legal writes. An AXI slave normally
serialises contending accesses with READY and completes both; here one of them
fails, and which one depends on cycle alignment. At nominal memory speed the
CPU's stores and the DMA's beats move on the same two-cycle rhythm and never
meet, so the failure appears only when some latency shifts that rhythm: rare,
timing-dependent and hard to reproduce. Software has to treat every SRAM access
as able to fail and retry it, and a DMA transfer can end in ERROR only because
the CPU touched the same word.

**Owner action.** Hold the losing port for a cycle with READY low and complete
it after the winner. If the error is kept as the contract, document it in the
SRAM interface and give software a retry rule.

### 2. Undefined register word 7 returns success

**What happens.** The top routes register words 0 to 7, the bank defines 0 to 6.
The probe reads word 7 as zero with error 0, and the bank's error outputs do not
report unmapped offsets.

**Why it is a problem.** A wrong register address, such as a typo or a driver
for another revision, looks like a valid access, so the bug stays silent.

**Owner action.** Answer SLVERR for reads and writes of undefined offsets on both
ports.

### 3. Only 248 of the 256 data words are addressable

**What happens.** The default 10-bit byte address includes 32 bytes of
registers, so data offsets 0x020 to 0x3FC address array entries 0 to 247. The
array has 256 entries. Fixed `[9:2]` slices also keep `ADDR_W` alone from
solving it.

**Why it is a problem.** The block is described as 1 KB of shared memory, but
software gets 992 bytes of data; a buffer sized for the full 1 KB runs past the
end of the SRAM's window.

**Owner action.** Reconcile the 256-word requirement with the register window,
make the decode follow `ADDR_W`, and test the top data address on both ports.

### Owner benches

`tb_dp_sram_top` (1399 checks) and `tb_dp_sram_regfile` (38 checks) pass
unchanged. They do not cover items 1 to 3 above.

## Lint

`soc/debug/sim/known_lint.json` lists 17 upstream Verilator diagnostics; any new
or vanished one fails the lint step.

| Diagnostic | Source | Meaning |
|---|---|---|
| 14 × WIDTHEXPAND | `mc_dma_axi4_lite_slave.v` lines 117–225 | Loop index times the channel offset compared with the 8-bit register address. The values fit; harmless. |
| WIDTHEXPAND | `mc_dma_channel.v:242` | `desc_len[7:2] - 1`: the six-bit subtraction behind DMA item 2. |
| WIDTHEXPAND | `dp_sram_regfile.v:105` | Window counter compared with `WINDOW_CYCLES-1`. The values fit; harmless. |
| WIDTHTRUNC | `mc_dma.v:102` | The grant vector used as a condition, meaning "any grant". Intended; harmless. |

After an owner fix, rerun the probe and remove the lint entries that disappear.

## Reproduce

Probe, from `soc/debug/sim`:

```text
vsim -c -do "do probe_upstream.do"
```

The same probe on Verilator, from `soc/debug/sim` in Bash/WSL:

```text
verilator --binary --timing --timescale 1ns/1ps -Wno-fatal --unroll-count 64 -j 4 --top-module soc_probe_upstream --Mdir obj_dir/probe -f soc_rtl.f ../hdl/soc_probe_upstream.v
./obj_dir/probe/Vsoc_probe_upstream
```

Both simulators print the same observations. The SRAM collisions come from the
regression bench, from `soc/debug/sim`:

```text
vsim -c -do "do compile.do; do ../../../cpu/debug/sim/run_common.do; run_case soc_tb_same_addr same; quit -f"
```

The owner benches run from a copy of the block, so that nothing is written into
`dma/` or `sram/`: in `sram/debug/sim`, `do compile.do` and then
`vsim work.tb_dp_sram_top`; in `dma/debug/sim`, compile `../../hdl/*.v` and the
bench, then elaborate it.
