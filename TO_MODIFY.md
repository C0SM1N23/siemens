# To modify

Open problems found while integrating the three blocks into one SoC. Anything
already fixed has been dropped from this list.

---

## DMA — `dma/`

**1. A descriptor shorter than 4 bytes overruns the destination and hangs the channel.**

`dma/hdl/dma_channel.v:249`:

```verilog
req_len = (desc_len >= 32) ? 8'd7 : (desc_len[7:2] - 1);
```

`desc_len[7:2]` is 6 bits wide, so for any length below 4 the subtraction wraps
to `6'b111111` before it is zero-extended into the 8-bit `req_len`, and the
channel asks for a 64-beat burst. Measured at SoC level with a 2-byte transfer:

```
channel 0 FSM state = 5  (2=ACTIVE 4=DONE 5=ERROR)
AWLEN the channel asked for = 63 (64 beats)
SRAM words no longer holding the guard = 248 (asked for 1)
```

The whole SRAM data region is overwritten, the channel ends in `STATE_ERROR`,
and software polling for `STATE_DONE` never exits. Widening the expression to 8
bits is not the fix — it turns 64 beats into 256. The sub-word case has to be
handled, or rejected with `STATE_ERROR` before any burst is issued.

Verilator flags this as `WIDTHEXPAND`; it is listed in `KNOWN_LINT` in
`soc/debug/sim/run_verilator.sh` so the SoC lint gate still runs, and the entry
has to be removed once this is fixed.

**2. A length that is not a multiple of 4 is silently truncated.**

Same line. `desc_len[7:2]` is an integer division, so 22 bytes becomes 5 beats
= 20 bytes. The last 2 bytes are never written and nothing reports it. Needs
`WSTRB` on the final beat.

**3. `tb_mc_dma_top` fails on the DMA branch.**

`dma/debug/hdl/tb_mc_dma_top.v:357` checks `irq[0] !== 1'b1`, but the bench never
writes `INT_ENABLE`, which resets to 0. Since `irq` became
`INT_STATUS & INT_ENABLE`, `irq[0]` can no longer rise. Add
`axil_write(ADDR_INT_ENABLE, 32'h0000_000F)` before the check.

**4. `dma/debug/sim/sim.do` is empty.**

It used to compile a different project (`sistem_parcare.v`); it is now a 0-byte
file, so the block has no working ModelSim script.

**5. Channels 1..3 and round-robin arbitration are covered only in the block bench.**

---

## DP-SRAM — `sram/`

**6. The register bank ignores `WSTRB`.**

`sram/hdl/sram_regfile.v` has no `wstrb` port; `sram/hdl/dp_sram_top.v:173` passes
only `a_reg_wdata_i`. Most registers survive by luck — the CPU replicates the byte
across all four lanes (`cpu/hdl/lsu.v:92`) and the bank takes `wdata[7:0]`. The
exception is `INT_ENABLE`, stored as a full 32-bit word: after `sb` of `0x01` it
holds `0x01010101` and reads back garbage in the upper bits. Correct today only
because bits 0..1 are the only ones used; any use of the upper bits, or any
read-modify-write, breaks.

Apply `wstrb` per byte, as `sram/hdl/mem_array.v:44-47` already does.

**7. Register word 7 is a silent hole.**

`REG_WORD_MAX = 7` routes words 0..7 to the bank, but
`sram/hdl/sram_regfile.v:49-55` defines only 0..6. Word 7 reads 0, swallows
writes, answers OKAY.

**8. The register region can never return an error.**

`sram/hdl/dp_sram_top.v:120`: `a_mem_error_final = a_is_reg ? 1'b0 : ...`.

**9. The last eight words of the array cannot be addressed.**

`sram/hdl/mem_array.v:33` declares `mem[0:255]`, but `dp_sram_top` subtracts
`MEM_BASE_OFFSET` from a 10-bit address before indexing, so words 8..255 of the
address space map onto `mem[0..247]`. `mem[248..255]` has no address. The block
offers 248 data words where the specification asks for 256, and widening the SoC
window does not help — the port is 10 bits wide.

Widen `ADDR_W` to 11, or declare the array `[0:247]` so its size states what is
reachable.

**10. `tb_regfile.v` no longer compiles.**

It uses the pre-rename port names (`clk`, `a_reg_valid`, `irq`). The register
bank is now covered only indirectly through `tb_dp_sram_top`.

---

## CPU, PIC and integration — `cpu/`, `soc/`

**11. Two address maps that can drift.**

`cpu/debug/sim/soc_map.vh` and `soc/hdl/soc_addr_map.vh` define the same base
addresses independently. They agree today and nothing enforces it.

**12. Two injected defects still survive the suite.**

| Defect | Why nothing catches it |
|---|---|
| `BRESP` stickiness removed in the bridge | no test produces an error on a beat inside a burst |
| `WIN_W` back to a literal | every test runs at `WINDOW_CYCLES = 1024` |

**13. The CPU brief and the PIC brief specify different interrupt interfaces.**

The CPU brief asks for `cpu_irq[7:0]`, a one-hot `cpu_irq_ack[7:0]` and a 3-bit
`cpu_irq_id`; the PIC brief asks for 16 sources. Sixteen identifiers do not fit
in three bits, so the RTL follows the PIC brief and adds an end-of-interrupt
pulse that neither brief mentions, plus `cpu_mask_i` and `pending_o`. The PIC
brief also says the acknowledge clears the active state, while the RTL uses it to
push and the end-of-interrupt to pop, which is what nesting requires.

Needs a decision from the mentor before the interface can be signed off.

**14. No synthesis run.** No `.qsf` / `.xdc` / `.sdc` in the repository.

**15. Untested at system level:** DMA channels 1..3 and round-robin; the machine
timer, wired to PIC source 7 but never armed by an SoC program; PIC preemption,
spurious detection and deadline escalation through the CPU rather than in the
block bench; PIC sources 8..15; backpressure on the SRAM and the peripherals,
since the timing sweep reaches only IMEM and DMEM; an error response on a beat
inside a DMA burst.
