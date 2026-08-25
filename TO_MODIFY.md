# To modify

Everything found while integrating the three blocks into one SoC and then
reviewing the result. Each item says where it is, what is wrong, and what to do.

Ordered by severity inside each block:

- **Blocking** — the block does not compile, or it corrupts data.
- **Important** — it works, but a documented feature does not, or a defect is
  one parameter change away.
- **Hygiene** — no functional impact, but it costs the next person time.

Items marked **fixed on `master`** are already done in the integration branch.
Pull them back into your own branch, otherwise your branch stays broken.

---

## DMA — `dma/`

### Blocking

**1. The block does not compile.** *(fixed on `master`)*

`dma/hdl/mc_dma_top.v:103` reads `active_master_ch` in four continuous
assignments; the register is declared at `:117`, fourteen lines below.

```
** Error: (vlog-2730) Undefined variable: 'active_master_ch'.
** Error: (vlog-2388) 'active_master_ch' already declared in this scope.
```

Verilog requires a variable to be declared before it is referenced. Move the
declaration and its `always` block above the assignments. No logic changes.

**2. A transfer whose length is not a multiple of 32 bytes writes past the
destination.**

`dma/hdl/dma_channel.v:245` and `:249` hardcode `req_len = 8'h07`, so every
burst is 8 beats = 32 bytes. With `desc_len = 40`: the first chunk moves 32
bytes, 8 remain, and the last burst still writes a full 32 — **24 bytes land
outside the requested region.**

Either clamp the final burst to the remaining length, or reject a non-multiple
of 32 with `STATE_ERROR` and document the restriction. Silently overrunning is
the worst of the three options.

**3. `INT_STATUS` and `INT_ENABLE` were connected to nothing.**
*(fixed on `master`)*

`dma/hdl/mc_dma_top.v` drove `assign irq = hw_irq;` with both register-file
outputs left unconnected. Two registers software can write and read back did
nothing: masking had no effect, and write-1-to-clear did not release the line.
Now `assign irq = int_status_w[3:0] & int_enable_w[3:0];`.

### Important

**4. Write-1-to-clear on `INT_STATUS` cannot release the interrupt.**

`dma/hdl/dma_channel.v:269` holds `irq_out` as a *level* for as long as the
channel sits in `STATE_DONE`, and `dma/hdl/axi4_lite_slave.v:253` re-sets
`int_status` from it every cycle. W1C wins for one cycle and the bit comes
back, so the handler must clear `CONTROL.enable` first.

Make completion an **event**: a one-cycle pulse on entering `DONE`/`ERROR`,
latched into `INT_STATUS`. Then W1C works the way the register map says.

**5. `data_fifo` is not reset.**

`dma/hdl/axi4_full_master.v:209` resets exactly one location — the one indexed
by `active_ch_id` and `burst_cnt` at the moment of reset. The other 31 leave
reset holding X. Use a `for` loop over all 4 x 8 entries.

**6. Four AXI attribute registers have no `else` branch.**

`dma/hdl/axi4_full_master.v:172, 177, 240, 245` — `arsize`, `arburst`,
`awsize`, `awburst` are assigned only in the reset branch. They work, because
they then hold forever, but they are flip-flops that never change. Make them
`localparam` + `assign`.

**7. The masked interrupt path is untested.**

`dma/debug/hdl/tb_mc_dma_top.v` checks `irq[0]` after a transfer without ever
writing `INT_ENABLE`. It passed only because the mask was ignored. Add a case
where `INT_ENABLE = 0` and `irq` must **not** rise.

**8. Channels 1..3 and round-robin are only covered in the block bench.**

Nothing exercises them at system level. Worth one SoC test with two channels
active and `SCHED_POLICY = 1`.

### Hygiene

**9. `dma/debug/sim/sim.do` belongs to a different project.**

```
vlog ../../hdl/sistem_parcare.v
vlog ../hdl/sistem_parcare_tb.v
vsim -gui -voptargs=+acc work.sistem_parcare_tb
```

A parking-lot controller. Replace it with a script that compiles the DMA.

**10. Simulator output is committed:** `debug/sim/work/`, `vsim.wlf`,
`modelsim.ini`. Add them to `.gitignore`.

**11. Romanian comments in all four RTL files:** `axi4_full_master.v`,
`dma_channel.v`, `mc_dma_top.v`, `priority_arbiter.v`. The rest of the project
is in English.

**12. No compile-order filelist.** Add a `.f` listing modules bottom-up, like
`soc/debug/sim/soc_rtl.f`.

---

## DP-SRAM — `sram/`

### Blocking

**13. A byte write to a control register destroys the whole word.**

`sram/hdl/sram_regfile.v` has no `wstrb` port — `sram/hdl/dp_sram_top.v:173`
passes only `a_reg_wdata_i`. The slave FSM receives `wstrb` correctly and then
drops it on the way to the register bank. A `sb` from the CPU into
`INT_ENABLE` writes all 32 bits and clears the other 24.

Add `wstrb` and apply it per byte, the way `sram/hdl/mem_array.v:44-47` does.

### Important

**14. Register word 7 is a silent hole.**

`sram/hdl/dp_sram_top.v` sets `REG_WORD_MAX = 7`, so words 0..7 route to the
register bank, but `sram/hdl/sram_regfile.v:49-55` defines only 0..6. Word 7
reads 0 and swallows writes, answering **OKAY**. Either define it or return
SLVERR.

**15. The register region can never return an error.**

`sram/hdl/dp_sram_top.v:120`: `a_mem_error_final = a_is_reg ? 1'b0 : ...` is
hardwired to 0. Any bad access inside the register region answers OKAY. Drive
SLVERR for invalid register addresses.

**16. Module `regfile` collides with the CPU's register file.**
*(fixed on `master`)*

Both blocks defined a module called `regfile`. In one library the second
definition overrides the first and the elaborated design silently gets the
wrong module. Renamed to `sram_regfile`. Adopt the name — any future
integration hits this again otherwise.

**17. `WIN_W` was independent of `WINDOW_CYCLES`.** *(fixed on `master`)*

`sram/hdl/sram_regfile.v` had `localparam WIN_W = 10;` while `WINDOW_CYCLES` is
a parameter. At `WINDOW_CYCLES = 2048` the counter is too narrow to reach the
end of its own window: measured **0 `window_done` pulses**, and `BANDWIDTH_A/B`
stop updating silently. Now `$clog2(WINDOW_CYCLES)`.

**18. `mem_array` leaves reset holding X.**

`sram/hdl/mem_array.v:6` documents it. In the SoC an X read by the CPU reaches
the register file, then an address, and the failure surfaces hundreds of cycles
later somewhere unrelated. Add an `initial` that zeroes the array for
simulation.

### Hygiene

**19. The sources were duplicated** in the repository root and under `Siemens/`,
and the two had **drifted** — the last upload updated only `Siemens/`. Keep one
copy.

**20. `tb_regfile.v` is dead.** It instantiates the module with the old
unsuffixed port names (`clk`, `a_reg_valid`, `irq`) after they were renamed to
`clk_i`, `a_reg_valid_i`, `irq_o`. It can no longer compile against its own
DUT. Rewrite it — the register bank is currently covered only indirectly
through `tb_dp_sram_top`.

**21. Committed artifacts:** `.vcd`, `transcript`, `work/`,
`tb_dp_sram_top.v.bak`.

---

## CPU and integration — `cpu/`, `soc/`

The CPU RTL is clean: `verilator --lint-only -Wall` reports 11 unused-signal
warnings and **nothing** in the categories that indicate a defect — no width
mismatch, no latch, no multiply-driven signal, no combinational loop, no
incomplete case. The items below are repository and verification level.

### Important

**22. Two address maps that can drift apart.**

`cpu/debug/sim/soc_map.vh` defines `IMEM_BASE`, `DMEM_BASE`, `PIC_BASE`,
`TMR_BASE`; `soc/hdl/soc_addr_map.vh` defines `SOC_*` versions of the same
addresses. They agree today and nothing enforces that they keep agreeing.
Make the CPU testbench include the SoC map, or state in both files that they
must be changed together.

**23. Four verification gaps let a real defect through.**

Mutation testing injected eight defects; **four survived the whole suite**:

| Injected defect | Why nothing caught it |
|---|---|
| `BRESP` stickiness removed in the bridge | no test produces an error on a beat *inside* a burst |
| an address window widened past its block | nothing checks window sizes |
| `INT_ENABLE` ignored when forming `irq` | every test writes `INT_ENABLE = 0xF` first |
| `WIN_W` back to a literal | every test runs at `WINDOW_CYCLES = 1024` |

All four are caught by benches written during the review. Adding them is the
highest-value work left: it closes four holes at once. See
[VERIFICATION_REPORT.md](VERIFICATION_REPORT.md).

**24. The SoC is not in CI.**

`.github/workflows/ci.yml` runs `make test` only — the CPU Verilator flow.
Neither `make soc` (9 runs) nor `make soc-sva` is automated. A combinational
loop reintroduced in the decoder is reported by ModelSim as `vsim-3601`, which
a flow that only counts PASS banners would miss.

**25. No synthesis run.** No `.qsf` / `.xdc` / `.sdc` anywhere. Area, frequency
and timing closure are unknown. A clean lint says nothing about any of them.

### Coverage still missing at system level

- DMA channels 1..3 and round-robin scheduling
- the machine timer: wired to PIC source 7, but no SoC program arms it
- PIC preemption, nesting, spurious detection and deadline escalation
- backpressure on the SRAM and the peripherals — the timing sweep reaches only
  IMEM and DMEM

---

## Rules that would have prevented most of this

1. **Prefix generic module names with the block name.** `regfile`, `arbiter`,
   `fsm` will collide. `sram_regfile`, `dma_priority_arbiter`.
2. **Keep a `.f` filelist with the compile order**, bottom-up, as the single
   source of truth.
3. **Reset every flop, including arrays.** The rule the CPU block uses: no flop
   leaves reset holding X.
4. **Run `verilator --lint-only -Wall` before every push.** It is free, it is
   already installed in WSL, and it catches exactly the class of problems
   above.
5. **Compile your block together with the other two before calling it done.**
   Both blocking compile failures would have shown up in ten seconds.
6. **Never commit `work/`, `*.wlf`, `*.vcd`, `transcript`, `modelsim.ini`.**
