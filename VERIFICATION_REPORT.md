# Independent verification report

A review of the integrated SoC on `master`, run on the assumption that a test
which passes may be passing for the wrong reason until shown otherwise.

Scope: the three merged blocks and the interconnect written for the
integration. No RTL was changed to make anything pass; every temporary edit was
reverted and the tree confirmed clean.

Two passes. The first, at `7ff7da4`, is sections 1 to 4 and covered the merge,
the fabric and the three blocks. The second, at `fd0403e`, went after the CPU,
the PIC and the address map specifically, and is section 5; it found nine
defects, all of them fixed, and it contradicts the first pass in one place -
"no functional defect was found in the RTL" was wrong.

Each verdict carries the command that produced it and the line from the log that
decides it.

---

## 1. Verification results

### Build and baseline regressions

| Check | Verdict | Evidence |
|---|---|---|
| One library, 0 errors / 0 warnings | PASS | `do compile.do` → 5 vlog invocations, every one `Errors: 0, Warnings: 0` |
| No `vsim-2685` / `vsim-3722` at elaboration | PASS | elaborated `soc_top`, `tb_soc_top`, `tb_soc_stress`, `tb_full2lite` → `port-warnings=0` on each |
| CPU regression 15/15 | PASS | `make modelsim` → `PASS banners = 15`, `FAIL lines = 0` |
| SoC regression 10/10 | PASS | `make soc` → `PASS banners = 10`, `FAIL = 0` |
| Verilator lint + SVA | PASS | `make soc-sva` → `lint clean`, 4 benches PASS, `%Error total: 0` |
| DMA block bench | PASS | `REZULTAT: TOATE TESTELE AU TRECUT (0 erori)` |
| DP-SRAM block bench 67/67 | PASS | `Rezultate: 67 PASS, 0 FAIL din 67 verificari` |
| Block branches not rewritten | PASS | `origin/RISCV\|DMA\|SDRAM : ANCESTOR OK`; reflog shows only `push` / `fast-forward` |

### The five source changes claimed in INTEGRATION.md

| Check | Verdict | Evidence |
|---|---|---|
| `active_master_ch` moved, logic unchanged | PASS | normalised diff of the `always` block vs `origin/DMA` → `IDENTIC`; declaration line 97, first use line 117 |
| `INT_ENABLE = 0` ⇒ irq stays low though the channel is DONE | PASS | `tb_irq_seq` → `A: INT_ENABLE=0 -> irq stays low though channel is DONE = 0x00000000` |
| Unmasking raises irq with no new event | PASS | `B: unmasking raises irq with no new event = 0x00000001` |
| W1C on `INT_STATUS` releases irq **without** disabling the channel | **FAIL** | `C: irq after W1C with channel still enabled = 0001` — see finding E |
| Documented order (clear `CONTROL`, then W1C) releases irq | PASS | `D: clear CONTROL then W1C -> irq released = 0x00000000` |
| `regfile` and `sram_regfile` distinct and correctly instantiated | PASS | `vdir`: `MODULE regfile`, `MODULE sram_regfile`; hierarchy: `/soc_top/cpu_inst/regfile_inst (regfile)`, `/soc_top/sram_inst/u_regfile (sram_regfile)` |
| `compile.do` updated, block bench runs | PASS | 67/67 |
| `WIN_W = $clog2(WINDOW_CYCLES)` works off the default | PASS | 1024→`WIN_W=10`, BW=512; 2048→`11`, BW=1024; 256→`8`, BW=128; `RESULT: WINDOW OK` ×3 |

The bandwidth figures scale exactly with the window — half the window, half the
count — so the counter is right, not merely alive.

### The new fabric

| Check | Verdict | Evidence |
|---|---|---|
| 8-beat INCR both directions, WRAP/narrow ⇒ SLVERR, recovery, WLAST/RLAST | PASS | `tb_full2lite`, regression run 1/9 `ALL TESTS PASSED` |
| BRESP sticky with an error on a **middle** beat | PASS (design) | purpose-built bench: `BRESP = 11`; per-beat `rresp = 00,00,11,11,00,00,00,00` |
| DECERR on an unmapped address | PASS | address-map bench, 25/25 |
| Response phase routed by the latched select, loop does not return | PASS | mutant 5 reintroduces it → `vsim-3601 Iteration limit 5000 reached at time 125 ns` |
| Arbiter: one-hot grant, held to the response, parked master sees nothing | PASS (by assertion) | `soc_fabric_sva` bound and live in all three benches, zero firings |
| No aliasing past the end of a block | PASS | `SRAM +1KB must DECERR`, `SRAM +2KB must DECERR`, `DMEM +8KB must DECERR` |
| Reachability: ibus→IMEM only, dbus→all but IMEM, DMA→DMEM+SRAM only | PASS | 12 forbidden paths driven explicitly, all DECERR |
| SRAM at the same address from both sides | PASS | `dbus -> SRAM` and `dma -> SRAM` at `SOC_SRAM_BASE`, both OKAY |

### Coverage, not just green

| Check | Verdict | Evidence |
|---|---|---|
| Coverage counters | PASS | nominal run: contended 171, grants 751/288, port A/B 325/128, both ports 10, same address 3, real conflicts 3, DECERR 1 |
| The floors are checked, not printed | PASS | removing the DMA tracking from the stress program → `SOC STRESS TESTBENCH: 3 FAILURE(S)`; reverted → green again |
| Floors hold under all four bus timings | PASS | contended 171 / 161 / 224 / 170; at least one real conflict in each |
| Timing controls inert at defaults | PASS | `STALL_PROB=0`: no `g_backpressure/*` signal exists; forced to 30: `ar_stall_q, aw_stall_q, rseed, w_stall_q` appear |
| Collision end to end | PASS | 3 conflicts → 3 CPU traps → 3 interrupts on PIC source 4, handled and cleared; `the transfer is bit-perfect despite the contention` |

### The assertion layer

| Check | Verdict | Evidence |
|---|---|---|
| SVA actually bound, not just present | PASS | same mutant built without `--assert`: 0 assertions; with `--assert`: 1. Path proves binding inside the DUT: `tb_soc_top.dut.bridge_inst.full_port_sva_i.r_no_last_before_final` |
| `CHECK_SUBSET` on for the DMA port, off for the bridge's slave side | PASS | `soc_bind_sva.sv:180` `CHECK_SUBSET(0)`, `:291` `CHECK_SUBSET(1)` |
| `tb_full2lite` really drives a WRAP burst | PASS | `tb_full2lite.v:263` and `:267` drive `BURST_WRAP` |

---

## 2. Mutation testing

Eight defects injected one at a time, full regression run for each, reverted
after each.

| # | Injected defect | Caught by | Caught |
|---|---|---|---|
| 1 | SRAM collision priority inverted (reader wins) | stress bench (`bit-perfect` → 0x38 words wrong) + SRAM block bench 61/67 | **yes** |
| 2 | BRESP stickiness removed in the bridge | — SoC 9/9, Verilator 3/3, no assertion | **no** |
| 3 | SRAM address window widened to 4 KB for a 1 KB block | since the second pass: `tb_addr_map` | **yes** |
| 4 | Arbiter grant released at the address handshake | system bench `never reached its end marker` (SoC 1/9) | **yes** |
| 5 | Decoder response routed by the live address | `vsim-3601 Iteration limit 5000` (SoC 1/9), Verilator 0/3 | **yes** |
| 6 | RLAST one beat early | `tb_full2lite` + all 8 system runs + SVA `r_no_last_before_final` | **yes** |
| 7 | `INT_ENABLE` ignored when forming irq | — SoC 9/9, Verilator 3/3, DMA block bench passes | **no** |
| 8 | `WIN_W` back to literal 10 with `WINDOW_CYCLES = 2048` | — SoC 9/9, Verilator 3/3, SRAM block bench 67/67 | **no** |

**Four of eight survived the suite as delivered.** All four were caught by
benches written during this review, so the design was right and the tests were
not looking:

| Mutant | Caught by the independent bench |
|---|---|
| 2 | `BRESP = 00` → `mid-burst error was lost, burst reported OKAY` |
| 3 | `SRAM +1KB must DECERR -> expected 0x3, got 0x0` (3 failures) |
| 7 | `A: INT_ENABLE=0 -> irq stays low -> expected 0x0, got 0x1` |
| 8 | at `WINDOW_CYCLES=2048`: `window_done pulses = 0`, `WINDOW DEAD` |

Mutant 3 is closed: `soc/debug/hdl/tb_addr_map.v` is now in the repository and
in both regressions. Mutants 2, 7 and 8 are still open, and 7 and 8 are in
blocks this integration does not modify; they are items 28, 4 and 14 of
[TO_MODIFY.md](TO_MODIFY.md).

---

## 3. Real defects found in the first pass

The first pass found no functional defect. That verdict did not survive the
second pass, which found nine - see section 5. What the first pass did find was
one behaviour that differs from what the register map implies:

**E — `INT_STATUS` write-1-to-clear cannot release the interrupt while the
channel is still enabled.**
`dma/hdl/mc_dma_top.v:144`, `dma/hdl/axi4_lite_slave.v:253`,
`dma/hdl/dma_channel.v:269`.

`irq_out` is a level held for as long as the channel sits in `STATE_DONE`, and
`int_status` is re-set unconditionally from it every cycle. A W1C wins for one
cycle and the bit comes straight back. The handler must write
`CONTROL.enable = 0` first.

Severity: **low.** Ordinary behaviour for a status bit fed by a level rather
than an event, and the SoC's own handler uses the correct order. But the W1C is
only half functional: software cannot acknowledge a completion without also
disabling the channel.

The other surviving mutants are verification gaps, not defects.

---

## 4. What no verification covers

Everything here passed, and none of it was tested. Items 2, 10 and 12 were
closed by the second pass and are struck through; the rest still stand.

1. **BRESP stickiness** (`soc/hdl/axi_full2lite.v:278`). No delivered test
   produces an error on a beat inside a burst; `tb_full2lite` only exercises
   the refusals the bridge generates itself (WRAP, narrow). A partially failed
   DMA transfer would report OKAY and software would believe it. The
   `bresp_sticky` assertion exists but cannot fire if the situation never
   arises.
2. ~~**Address window masks** (`soc/hdl/soc_addr_map.vh`). Nothing checks window
   sizes. A widened mask aliases silently. The only unmapped access in the
   suite is `0x5000_0000`, which stays unmapped however the existing windows
   are widened.~~ Closed: `soc/debug/hdl/tb_addr_map.v`, run 1 of the SoC
   regression. Three of the six windows turned out to be oversized.
3. **DMA interrupt masking** (`dma/hdl/mc_dma_top.v:144`). Both SoC programs
   and the DMA's own bench write `INT_ENABLE = 0xF` before any check. The
   masked path is never taken.
4. **Re-parameterising `WINDOW_CYCLES`** (`sram/hdl/sram_regfile.v:62`). Every
   test runs at 1024, where the old defect was invisible.
5. **DMA channels 1–3 and round-robin at system level.** The SoC programs never
   touch `CH1/CH2/CH3` (0 occurrences) and both set `SCHED_POLICY = 0` (fixed).
   Round-robin appears only in the DMA's own block bench.
6. **PIC preemption and nesting in the SoC.** The system uses sources 0 and 4.
   Priority bands, spurious detection and deadline escalation are covered only
   by `tb_pic` and `tb_pic_sched` in isolation. Nesting through a real core is
   covered by `tb_traps`, but on a hand-built two-level case rather than in the
   assembled system. Sources 8–15 are unused everywhere.
7. **The machine timer in the SoC.** Wired to PIC source 7, but no SoC program
   arms it — the timer → PIC → CPU path is unexercised at system level.
8. **Backpressure on the SRAM and the peripherals.** The timing sweep reaches
   IMEM and DMEM only. The SRAM, PIC, timer and DMA registers always answer at
   fixed timing.
9. **`tb_regfile.v` for the SRAM register bank** is absent from the repository;
   `sram_regfile` is covered only indirectly through `tb_dp_sram_top`.
10. ~~**Mutant 5 is caught by a simulator error, not by a check.**~~ Still true
    of `vsim-3601` itself, but the SoC flow is now in CI, so a decoder that
    loops is caught by the Verilator run rather than only by a human reading a
    ModelSim log.
11. **No synthesis run.** No `.qsf` / `.xdc` / `.sdc` in the repository. Area,
    frequency and timing closure are unknown.
12. ~~**CI runs the CPU flow only.**~~ Closed: CI runs `make test` and
    `make soc-sva` on `master`, `RISCV`, `DMA` and `SDRAM`. Pushes to `master`
    were not checked at all before, only pull requests into it.

---

## 5. Second pass: the CPU, the PIC and the address map

The first pass concentrated on the merge and the fabric and took the CPU side
largely at its documentation's word. The second pass did not, and the
documentation turned out to be describing intent rather than behaviour in three
places. Nine defects, all fixed, each with a test that fails without its fix.

| # | Defect | Test that fails without the fix |
|---|---|---|
| 1 | `MRET` could not tell an interrupt return from an exception return | `tb_traps`, both nesting cases |
| 2 | a source masked in `mie` starved every source behind it | channel sweep in `program_axi.s` |
| 3 | `mip` reported the offered source, not the pending set | channel sweep, `mip` check |
| 4 | 64 KB peripheral windows over blocks that decode 8 address bits | `tb_addr_map` |
| 5 | bump escalation assumed band 0 is always the most urgent | `tb_pic_sched`, case 4 |
| 6 | an edge arriving in the claim cycle was dropped | `tb_pic_sched`, case 3 |
| 7 | the software-trigger key was compared, not required to be written | `tb_pic_sched`, case 5 |
| 8 | `mtvec.MODE` stored the reserved encodings 2 and 3 | `tb_csr_ro`, step 5 |
| 9 | `CSRRS`/`CSRRC` on a counter dropped that cycle's event | none; behaviour was defensible, the comment was wrong |

Each of the eight with a test was mutation-checked the same way as section 2:
the old code was put back, the bench was run, and the failure recorded.

| Mutant | Failure observed |
|---|---|
| single-bit `in_irq` | `no EOI had been sent when the exception's MRET had retired -> expected 0, got 1` and `two EOIs came back -> expected 2, got 1` |
| resolver ignores `cpu_mask_i` | `sweep: one ack[6] -> expected 1, got 0`, then `timeout - program never reached the end marker` |
| 64 KB windows | 12 failures in `tb_addr_map`, `PIC + 0x100` answering `OKAY` with the PIC's tag |
| bump to band-1 | `after the bump the escalated source outranks it (vec=1 after 40 cycles)` |
| claim clears the edge first | `the edge that arrived with the claim is still pending (cpu_irq=0)` |
| key checked by value only | `an unstrobed key does not arm the channel (it was offered)` |

### What this pass says about the first one

Three of the nine had already been observed and written up as something other
than a defect: the interrupt-mask starvation as an "integration rule", the
nesting limitation as "a software addition, not a hardware gap", and
`mtvec.MODE` as a deviation with "no functional risk". The first two were wrong
on the facts, and the third was correct but left open. A finding recorded as a
design decision stops being looked at, which is the more useful lesson than any
individual bug here.

The 64 KB windows are a different failure: the map's own header claimed every
window was exactly the size of its block, and three of six were not. Nothing
checked the claim, because no working program issues an address that should not
decode. That is the class of property that needs its own bench rather than a
system run.

### What has not changed

The three block-level items the first pass raised against the DMA and the SRAM
are untouched - they belong to their owners and are in
[TO_MODIFY.md](TO_MODIFY.md). Section 4's list of what no verification covers
still stands, less the address map.

---

## 6. Verdict

**The SoC works, demonstrably, on its main path** — an end-to-end DMA transfer
that stays bit-perfect under four bus timings, with the arbiter contended for
161 to 224 cycles, real SRAM address collisions resolved in favour of the
writer, and a complete interrupt chain. **The interrupt path now also works off
its main path**: nested handlers, an exception inside a handler, a masked source
that must not block the ones behind it, and an address that must not decode are
all covered by tests that fail without their fix.

**It remains untested on: burst response stickiness, DMA interrupt masking, DMA
channels 1–3 with round-robin scheduling, the machine timer in system context,
PIC sources 8–15, and any re-parameterisation of the blocks.** Address window
sizing was on this list and is not any more.

Not ready for sign-off, for a reason no test can settle: the CPU brief and the
PIC brief specify different interrupt interfaces, the RTL follows neither
exactly, and nothing records that as an agreed decision. See item 13 of
[TO_MODIFY.md](TO_MODIFY.md).

---

## Reproducing

```
make modelsim    # CPU regression, 15 runs
make soc         # SoC regression, 14 runs over four bus timings
make test        # CPU lint + SVA + functional coverage on Verilator
make soc-sva     # SoC lint + SVA assertion run on Verilator
```

Block benches:

```
cd dma/debug/sim  && vsim -c -do "do ...; run -all"     # tb_mc_dma_top
cd sram/debug/sim && vsim -c -do "do compile.do; ..."   # tb_dp_sram_top
```

Repository state after the first pass: working tree clean, `HEAD` unchanged at
`7ff7da4`, control regressions re-run green (SoC 9/9, CPU 14/14).

After the second pass the RTL did change, in the CPU, the PIC and the address
map only. All four flows re-run green: CPU 15/15, SoC 10/10, `make test` PASS
with 88/92 coverage bins, `make soc-sva` lint clean with four benches passing.
No block owned by anyone else was modified.
