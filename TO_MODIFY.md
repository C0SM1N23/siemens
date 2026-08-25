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

**6. Four AXI attribute registers have no `else` branch.**

`dma/hdl/axi4_full_master.v:172, 177, 240, 245` — `arsize`, `arburst`, `awsize`,
`awburst` are assigned only under reset. Make them `localparam` + `assign`.

**7. The masked interrupt path is untested.**

`dma/debug/hdl/tb_mc_dma_top.v` checks `irq[0]` without ever writing
`INT_ENABLE`. Add a case where `INT_ENABLE = 0` and `irq` must not rise.

**8. Channels 1..3 and round-robin are covered only in the block bench.**

### Hygiene

**9. `dma/debug/sim/sim.do` is from a different project.**

```
vlog ../../hdl/sistem_parcare.v
vlog ../hdl/sistem_parcare_tb.v
```

**10. Committed simulator output:** `debug/sim/work/`, `vsim.wlf`, `modelsim.ini`.

**11. Romanian comments** in `axi4_full_master.v`, `dma_channel.v`,
`mc_dma_top.v`, `priority_arbiter.v`.

---

## DP-SRAM — `sram/`

### Blocking

**12. A byte write to a control register destroys the whole word.**

`sram/hdl/sram_regfile.v` has no `wstrb` port; `sram/hdl/dp_sram_top.v:173`
passes only `a_reg_wdata_i`. The slave FSM receives `wstrb` and drops it on the
way to the register bank, so `sb` into `INT_ENABLE` writes all 32 bits.

Add `wstrb` and apply it per byte, as `sram/hdl/mem_array.v:44-47` does.

### Important

**13. Register word 7 is a silent hole.**

`sram/hdl/dp_sram_top.v` sets `REG_WORD_MAX = 7`, so words 0..7 route to the
register bank, but `sram/hdl/sram_regfile.v:49-55` defines only 0..6. Word 7
reads 0, swallows writes, answers OKAY. Define it or return SLVERR.

**14. The register region can never return an error.**

`sram/hdl/dp_sram_top.v:120`: `a_mem_error_final = a_is_reg ? 1'b0 : ...`.

**15. Module `regfile` collides with the CPU's register file.** *(fixed on master)*

In one library the second definition overrides the first. Renamed to
`sram_regfile`.

**16. `WIN_W` was independent of `WINDOW_CYCLES`.** *(fixed on master)*

`sram/hdl/sram_regfile.v` had `localparam WIN_W = 10;` while `WINDOW_CYCLES` is a
parameter. At 2048 the counter never reaches the end of its window: measured 0
`window_done` pulses, `BANDWIDTH_A/B` stop updating. Now `$clog2(WINDOW_CYCLES)`.

**17. `mem_array` leaves reset holding X.**

`sram/hdl/mem_array.v:6`. Add an `initial` that zeroes the array for simulation.

### Hygiene

**18. Sources duplicated** in the repository root and under `Siemens/`, and the
two had drifted — the last upload updated only `Siemens/`.

**19. `tb_regfile.v` is dead.** It uses the old port names (`clk`,
`a_reg_valid`, `irq`) and no longer compiles against its own DUT. The register
bank is covered only indirectly through `tb_dp_sram_top`.

**20. Committed artifacts:** `.vcd`, `transcript`, `work/`, `.bak`.

---

## CPU and integration — `cpu/`, `soc/`

No defects found in the CPU RTL so far. The items below are repository and
verification level.

**21. Two address maps that can drift.**

`cpu/debug/sim/soc_map.vh` defines `IMEM_BASE`, `DMEM_BASE`, `PIC_BASE`,
`TMR_BASE`; `soc/hdl/soc_addr_map.vh` defines `SOC_*` versions of the same
addresses. They agree today and nothing enforces it.

**22. Four injected defects survive the whole suite.**

| Defect | Why nothing caught it |
|---|---|
| `BRESP` stickiness removed in the bridge | no test produces an error on a beat inside a burst |
| an address window widened past its block | nothing checks window sizes |
| `INT_ENABLE` ignored when forming `irq` | every test writes `INT_ENABLE = 0xF` first |
| `WIN_W` back to a literal | every test runs at `WINDOW_CYCLES = 1024` |

Benches that catch all four exist in the review but are not in the repository.

**23. The SoC is not in CI.** `.github/workflows/ci.yml` runs `make test` only —
the CPU Verilator flow. Neither `make soc` nor `make soc-sva` is automated.

**24. No synthesis run.** No `.qsf` / `.xdc` / `.sdc` in the repository.

**25. Untested at system level:** DMA channels 1..3 and round-robin; the machine
timer, wired to PIC source 7 but never armed by an SoC program; PIC preemption,
nesting, spurious detection and deadline escalation; backpressure on the SRAM and
the peripherals, since the timing sweep reaches only IMEM and DMEM.
