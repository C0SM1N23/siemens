# To modify

Found while integrating the three blocks into one SoC and reviewing the result.
Items marked *(fixed on master)* are already done in the integration branch.

---

## DMA — `dma/`

### Blocking

**1. The block does not compile.** *(fixed on master)*

`dma/hdl/mc_dma_top.v:103` reads `active_master_ch`; the register is declared at
`:117`.

```
** Error: (vlog-2730) Undefined variable: 'active_master_ch'.
** Error: (vlog-2388) 'active_master_ch' already declared in this scope.
```

Move the declaration and its `always` block above the assignments.

**2. A length that is not a multiple of 32 bytes writes past the destination.**

`dma/hdl/dma_channel.v:245` and `:249` hardcode `req_len = 8'h07`, so every burst
is 8 beats = 32 bytes. With `desc_len = 40` the last burst still writes 32 bytes:
24 of them land outside the requested region.

Clamp the final burst to the remainder, or reject a non-multiple of 32 with
`STATE_ERROR`.

**3. `INT_STATUS` and `INT_ENABLE` were connected to nothing.** *(fixed on master)*

`dma/hdl/mc_dma_top.v` drove `assign irq = hw_irq;` with both register-file
outputs unconnected: masking had no effect and write-1-to-clear did not release
the line. Now `assign irq = int_status_w[3:0] & int_enable_w[3:0];`.

### Important

**4. Write-1-to-clear on `INT_STATUS` cannot release the interrupt.**

`dma/hdl/dma_channel.v:269` holds `irq_out` as a level while the channel is in
`STATE_DONE`, and `dma/hdl/axi4_lite_slave.v:253` re-sets `int_status` from it
every cycle. W1C wins one cycle and the bit returns, so the handler has to clear
`CONTROL.enable` first.

Make completion a one-cycle pulse on entering `DONE`/`ERROR`, latched into
`INT_STATUS`.

**5. `data_fifo` is not reset.**

`dma/hdl/axi4_full_master.v:209` resets one location, the one indexed at the
moment of reset. The other 31 leave reset holding X. Use a loop over all 4 x 8
entries.

**6. The masked interrupt path is untested.**

`dma/debug/hdl/tb_mc_dma_top.v` checks `irq[0]` without ever writing
`INT_ENABLE`. Add a case where `INT_ENABLE = 0` and `irq` must not rise.

**7. Channels 1..3 and round-robin are covered only in the block bench.**

**8. `dma/debug/sim/sim.do` compiles a different project.**

```
vlog ../../hdl/sistem_parcare.v
vlog ../hdl/sistem_parcare_tb.v
```

The script does not build the DMA, so it fails for anyone who runs it.

---

## DP-SRAM — `sram/`

### Important

**9. The register bank ignores `WSTRB`.**

`sram/hdl/sram_regfile.v` has no `wstrb` port; `sram/hdl/dp_sram_top.v:173`
passes only `a_reg_wdata_i`. An AXI4-Lite slave is expected to honour the write
strobes.

Most registers survive it by luck: the CPU replicates the byte across all four
lanes (`cpu/hdl/lsu.v:92`), and the bank takes `wdata[7:0]` or `wdata[0]` for
the narrow ones. The exception is `INT_ENABLE`, stored as a full 32-bit word:
after `sb` of `0x01` it holds `0x01010101`, so a read-back returns garbage in
the upper bits. Behaviour is still correct today because only bits 0..1 are
used, but any register that uses the upper bits, or any read-modify-write,
breaks.

Add `wstrb` and apply it per byte, as `sram/hdl/mem_array.v:44-47` does.

**10. Register word 7 is a silent hole.**

`sram/hdl/dp_sram_top.v` sets `REG_WORD_MAX = 7`, so words 0..7 route to the
register bank, but `sram/hdl/sram_regfile.v:49-55` defines only 0..6. Word 7
reads 0, swallows writes, answers OKAY. Define it or return SLVERR.

**11. The register region can never return an error.**

`sram/hdl/dp_sram_top.v:120`: `a_mem_error_final = a_is_reg ? 1'b0 : ...`.

**12. The last eight words of the array cannot be addressed.**

`sram/hdl/mem_array.v:33` declares `mem[0:255]`, but `sram/hdl/dp_sram_top.v`
subtracts `MEM_BASE_OFFSET` from a 10-bit address before indexing it, so the
reachable range is words 8..255 of the address space mapped onto `mem[0..247]`.
`mem[248..255]` has no address. The block therefore offers 248 data words where
the specification asks for 256, and widening the SoC window does not help: the
port is 10 bits wide.

Either widen `ADDR_W` to 11 so the registers and a full 256-word array both fit,
or declare the array `[0:247]` so its size states what is actually reachable.

**13. Module `regfile` collides with the CPU's register file.** *(fixed on master)*

In one library the second definition overrides the first. Renamed to
`sram_regfile`.

**14. `WIN_W` was independent of `WINDOW_CYCLES`.** *(fixed on master)*

`sram/hdl/sram_regfile.v` had `localparam WIN_W = 10;` while `WINDOW_CYCLES` is a
parameter. At 2048 the counter never reaches the end of its window: measured 0
`window_done` pulses, `BANDWIDTH_A/B` stop updating. Now `$clog2(WINDOW_CYCLES)`.

**15. The sources were duplicated and had drifted.**

One copy in the repository root, one under `Siemens/`; the last upload updated
only `Siemens/`, so the two no longer matched.

**16. `tb_regfile.v` no longer compiles.**

It uses the old port names (`clk`, `a_reg_valid`, `irq`) after they were renamed
to `clk_i`, `a_reg_valid_i`, `irq_o`. The register bank is now covered only
indirectly through `tb_dp_sram_top`.

---

## CPU, PIC and integration - `cpu/`, `soc/`

An adversarial review of this side of the SoC found nine defects. All nine are
fixed on master and each has a test that fails without the fix.

### Fixed

**17. `MRET` could not tell which trap it was returning from.** *(fixed on master)*

`cpu/hdl/cpu_top.v` tracked one `in_irq` bit, set on any interrupt and cleared on
any `MRET`. Two nested interrupt handlers produced one end-of-interrupt instead
of two, so the outer level stayed on the PIC's nesting stack forever with its
source active. A synchronous exception inside an interrupt handler was worse: the
exception's `MRET` sent the end-of-interrupt early and popped the interrupt while
its handler was still running.

Now one bit per open trap level records whether that level was an interrupt, and
`MRET` pops it. `cpu_in_trap_o` follows the same stack, so a nested trap keeps it
high instead of releasing it at the inner return. Covered by the two nesting
cases in `cpu/debug/hdl/tb_traps.v`.

**18. A source masked in `mie` starved every source behind it.** *(fixed on master)*

The PIC chose the winner without knowing `mie`, and the CPU applied `mie` to the
winner it was handed. A source enabled in `INT_ENABLE` but masked in `mie` was
selected and never claimed: the resolver parked on it, nothing less urgent was
ever offered, and a `WFI` waiting on one of those sources never woke.

`cpu/hdl/pic.v` now takes `cpu_mask_i` and skips masked sources when resolving.
The source stays pending, so its deadline counter keeps running and it is offered
as soon as software unmasks it. The channel sweep in
`cpu/debug/sim/program_axi.s` used to disable source 5 to dodge this; it now
leaves it enabled and masked for the whole run, and hangs without the fix.

**19. `mip` showed only the offered source.** *(fixed on master)*

`mip[31:16]` was a one-hot of `cpu_irq_vec_i`, so software could not see the
sources queued behind the winner. The PIC now exports `pending_o`, every pending
source, and that drives `mip`.

**20. Peripheral windows were 64 KB over 256-byte blocks.** *(fixed on master)*

`cpu/hdl/axi_lite_slave.v` decodes `addr[7:2]` and the DMA's slave `addr[7:0]`,
but `soc/hdl/soc_addr_map.vh` gave the PIC, the timer and the DMA 64 KB each.
Every register was aliased 255 times above itself: `PIC_BASE+0x100` reached
`SRC0_CONFIG` and answered `OKAY`. Windows are now 256 B, exactly the register
file behind them. `soc/debug/hdl/tb_addr_map.v` checks each window's first and
last register and the first address past it.

**21. PIC bump escalation could lower a source's priority.** *(fixed on master)*

`BAND_CONFIG` lets software reorder the bands, but the bump escalation moved to
band-1, assuming band 0 is always the most urgent. After a reorder that moves the
source to a *less* urgent band. It now steps one place up the urgency order
`BAND_CONFIG` defines; under the default ordering that is still band-1.

**22. An edge arriving in the claim cycle was dropped.** *(fixed on master)*

In `cpu/hdl/pic.v` the claim cleared `edge_pend` before a new rising edge could
set it. The two are separate events and the second still needs servicing, so the
edge now wins.

**23. The software-trigger key was checked by value, not by write.** *(fixed on master)*

`SRCx_SW_TRIG` compared `wdata[31:16]` against `0xA5A5` without requiring those
lanes to be strobed. On a byte write the unstrobed lanes carry whatever the
master left on the bus, so an unrelated narrow write could arm a channel. Both
key lanes must now be strobed.

**24. `mtvec.MODE` stored the reserved encodings.** *(fixed on master)*

MODE is WARL with only `00` and `01` defined. `cpu/hdl/csr_file.v` stored `10`
and `11` and read them back unchanged, telling software the core implements a
vectoring mode it does not. A reserved MODE now folds to direct.

**25. The SoC ran without the CPU and PIC assertions.** *(fixed on master)*

`soc/debug/sim/run_verilator.sh` compiled only `axi_lite_sva`, so `cpu_core_sva`
and `pic_sva` were dark in every SoC run while `soc_bind_sva.sv` claimed they
were reused. The assertion binds are now in `cpu/debug/sva/bind_core_sva.sv`,
which both flows compile; the functional-coverage bind stayed behind because its
gate is calibrated for the CPU block's own program.

**26. CI ran one CPU bench on one branch.** *(fixed on master)*

`.github/workflows/ci.yml` ran `make test` on pushes to `RISCV` only, so nothing
in the interconnect was ever elaborated in CI and pushes to `master` were not
checked at all. It now runs `make test` and `make soc-sva` on all four branches.

### Open

**27. Two address maps that can drift.**

`cpu/debug/sim/soc_map.vh` defines `IMEM_BASE`, `DMEM_BASE`, `PIC_BASE`,
`TMR_BASE`; `soc/hdl/soc_addr_map.vh` defines `SOC_*` versions of the same
addresses. They agree today and nothing enforces it.

**28. Two injected defects still survive the suite.**

| Defect | Why nothing catches it |
|---|---|
| `BRESP` stickiness removed in the bridge | no test produces an error on a beat inside a burst |
| `WIN_W` back to a literal | every test runs at `WINDOW_CYCLES = 1024` |

The other two from the earlier review are closed: the address-window mutant by
`soc/debug/hdl/tb_addr_map.v`, and the `INT_ENABLE` mutant by item 6 once the
DMA bench covers the masked path.

**29. The CPU brief and the PIC brief specify different interrupt interfaces.**

The CPU brief asks for `cpu_irq[7:0]`, a one-hot `cpu_irq_ack[7:0]` and a 3-bit
`cpu_irq_id`; the PIC brief asks for 16 sources. Sixteen identifiers do not fit
in three bits, so the RTL follows the PIC brief and adds an end-of-interrupt
pulse that neither brief mentions, plus `cpu_mask_i` and `pending_o` from item 18
and item 19. The PIC brief also says the acknowledge clears the active state,
while the RTL uses it to push and the end-of-interrupt to pop, which is what
nesting requires.

The deviation is written up in the report but not agreed anywhere. It needs a
decision from the mentor before the interface can be signed off.

**30. No synthesis run.** No `.qsf` / `.xdc` / `.sdc` in the repository.

**31. Untested at system level:** DMA channels 1..3 and round-robin; the machine
timer, wired to PIC source 7 but never armed by an SoC program; PIC preemption,
spurious detection and deadline escalation through the CPU rather than in the
block bench; PIC sources 8..15; backpressure on the SRAM and the peripherals,
since the timing sweep reaches only IMEM and DMEM; an error response on a beat
inside a DMA burst.

**32. The 104-page report is behind the RTL.** It was written at `d534045` and
the SoC integration came after it, so the integration chapters are the only part
that tracks the current design. The passages this review contradicted have been
corrected in `docs/`, but the PDF has not been rebuilt.
