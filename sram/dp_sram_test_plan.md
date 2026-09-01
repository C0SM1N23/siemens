# DP-SRAM — Stress and Exhaustive Test Plan

This document lists directed test scenarios for the DP-SRAM block (`dp_sram_top.v` and its submodules) that go beyond the base functional tests already covered in `dp_sram_top_test_vectors.txt`. Randomized / constrained-random testing is intentionally excluded — every test below is fully directed, with a known expected result.

Signal names refer to `dp_sram_top.v`'s top-level ports (`a_*_i`/`a_*_o` for Port A, `b_*_i`/`b_*_o` for Port B, `irq_o`). Register addresses are byte offsets in the local address space (word 0–7 = registers, word 8–255 = memory).

---

## 1. AXI4-Lite Write Channel Timing

These tests target the independent `AW`/`W` latching (`aw_have`/`w_have`) in `axi4lite_slave_fsm.v`.

### 1.1 — Write address held before write data

**Objective:** confirm the write address is latched and preserved while waiting for write data, and that no other transaction is accepted in the meantime.

1. Drive `a_awvalid_i = 1`, `a_awaddr_i = 0x04` (`INT_ENABLE`). Keep `a_wvalid_i = 0`.
2. Wait for `a_awready_o = 1` (address accepted).
3. Deassert `a_awvalid_i`. Do **not** assert `a_wvalid_i` yet.
4. Hold this state for 5 clock cycles. Each cycle, check `a_arready_o = 0` (a read must not be accepted while a write is half-assembled) — issue `a_arvalid_i = 1`, `a_araddr_i = 0x08` during this window to confirm it is not accepted.
5. After 5 cycles, drive `a_wvalid_i = 1`, `a_wdata_i = 0x0000_0003`, `a_wstrb_i = 0xF`.
6. Wait for `a_wready_o = 1`, then `a_bvalid_o = 1`.
7. Read back `INT_ENABLE` (address `0x04`) and confirm it equals `0x0000_0003` — the address latched in step 1 was preserved correctly.

### 1.2 — Write data held before write address

**Objective:** symmetric case to 1.1, confirming `w_have` behaves the same way as `aw_have`.

1. Drive `a_wvalid_i = 1`, `a_wdata_i = 0x0000_0007`, `a_wstrb_i = 0xF`. Keep `a_awvalid_i = 0`.
2. Wait for `a_wready_o = 1`.
3. Deassert `a_wvalid_i`. Hold for 5 cycles without asserting `a_awvalid_i`.
4. Confirm `a_arready_o = 0` throughout, same as in 1.1 step 4.
5. Drive `a_awvalid_i = 1`, `a_awaddr_i = 0x04`.
6. Wait for `a_awready_o = 1`, then `a_bvalid_o = 1`.
7. Read `INT_ENABLE` and confirm it equals `0x0000_0007`.

### 1.3 — Back-to-back writes with no idle cycle

**Objective:** confirm `aw_have`/`w_have` are cleared cleanly at the end of one transaction and do not leak into the next.

1. Perform a normal write: `AWADDR=0x04`, `WDATA=0x1`, both asserted together, `BREADY=1` from the start.
2. In the exact cycle the write completes (`BVALID && BREADY`), immediately assert a new `AWVALID`/`WVALID` pair for a second write (`AWADDR=0x08`, `WDATA=0x1`).
3. Confirm the second write is accepted and completes normally (no stall, no leftover state from the first transaction).
4. Read back both `INT_ENABLE` (`0x04`) and `FORCE_PRIORITY` (`0x08`) and confirm both values.

### 1.4 — Read request arriving while a write is only half-assembled

**Objective:** confirm a read cannot "jump ahead" of a write that has only its address (or only its data) accepted.

1. Drive `a_awvalid_i = 1`, `a_awaddr_i = 0x04`. Do not assert `a_wvalid_i`.
2. Wait for acceptance (`a_awready_o = 1` observed once).
3. Continuously assert `a_arvalid_i = 1`, `a_araddr_i = 0x08` for 10 cycles.
4. Confirm `a_arready_o` stays `0` for all 10 cycles.
5. Assert `a_wvalid_i = 1`, `a_wdata_i = 0x1`, complete the write.
6. Confirm the read is accepted only after the write transaction fully completes.

---

## 2. Delayed Response Handshake (`BREADY`/`RREADY`)

### 2.1 — Delayed `BREADY` on `INT_STATUS` overlapping a real collision (regression test)

**Objective:** regression test for the write-pulse issue discussed earlier — a slow master must not cause a single software write to `INT_STATUS` to be re-applied multiple times.

1. Enable both interrupt sources: write `INT_ENABLE = 0x3` via Port A.
2. Force a real collision so bit 0 of `INT_STATUS` is set (e.g. a Read/Write collision between Port A and Port B on the same memory address).
3. Confirm `INT_STATUS` bit 0 = 1 via a normal read.
4. Issue a write of `INT_STATUS = 0x1` (W1C, clearing bit 0) via Port A, but hold `a_bready_i = 0` for 5 cycles after `a_bvalid_o` goes high.
5. During those 5 cycles, force a **new** real collision (setting bit 0 again).
6. Assert `a_bready_i` to let the write complete.
7. Read `INT_STATUS` and confirm bit 0 = **1** (the new collision event must survive, not be silently cleared by the stale write).

### 2.2 — Delayed `BREADY` on a plain R/W register

**Objective:** confirm the same delayed-`BREADY` scenario is harmless on a register without W1C semantics.

1. Write `INT_ENABLE = 0x1` via Port A, holding `a_bready_i = 0` for 5 cycles after `a_bvalid_o` is asserted.
2. Assert `a_bready_i` to complete the transaction.
3. Read `INT_ENABLE` and confirm it equals `0x1` (single, correct write — no unexpected side effect from the extended response window).

### 2.3 — Delayed `RREADY`

**Objective:** confirm `RDATA`/`RRESP` remain stable while the master delays taking the response.

1. Write a known value (e.g. `0xAAAA_5555`) to a memory word via Port A.
2. Issue a read of the same word. Once `a_rvalid_o = 1`, hold `a_rready_i = 0` for 5 cycles.
3. Sample `a_rdata_o` and `a_rresp_o` every cycle during the wait; confirm both remain constant.
4. Assert `a_rready_i` and confirm the transaction completes normally.

---

## 3. Byte Strobe (`WSTRB`) Coverage

### 3.1 — Single-byte writes

**Objective:** confirm each `WSTRB` bit controls exactly its own byte lane, no more and no less.

1. Write `0xFFFF_FFFF` to a memory word with `WSTRB = 0xF` (initialize all bytes to a known value).
2. Write `0x0000_00AA` with `WSTRB = 0x1` (byte 0 only). Read back and confirm the word is `0xFFFF_FFAA`.
3. Write `0x0000_BB00` with `WSTRB = 0x2` (byte 1 only). Read back and confirm `0xFFFF_BBAA`.
4. Write `0x00CC_0000` with `WSTRB = 0x4` (byte 2 only). Read back and confirm `0xFFCC_BBAA`.
5. Write `0xDD00_0000` with `WSTRB = 0x8` (byte 3 only). Read back and confirm `0xDDCC_BBAA`.

### 3.2 — `WSTRB = 0x0` (minimum, no byte selected)

**Objective:** confirm a write with no active byte lanes still completes with `BRESP = OKAY`, but changes nothing.

1. Write a known value (e.g. `0x1234_5678`) to a memory word with `WSTRB = 0xF`.
2. Issue a second write to the same word with `WDATA = 0xFFFF_FFFF`, `WSTRB = 0x0`.
3. Confirm `BRESP = OKAY` for the second write.
4. Read the word back and confirm it is unchanged (`0x1234_5678`).

### 3.3 — `WSTRB = 0xF` (maximum, all byte lanes)

**Objective:** confirm a full-word write behaves correctly (already exercised implicitly elsewhere, but included here for completeness alongside the boundary cases above).

1. Write `0xA5A5_5A5A` with `WSTRB = 0xF`.
2. Read back and confirm the full word matches exactly.

### 3.4 — Complementary partial writes merge correctly

**Objective:** confirm two half-word writes combine into the expected full word, rather than one overwriting the other's untouched bytes.

1. Write `0x0000_1122` with `WSTRB = 0x3` (bytes 0–1).
2. Write `0x3344_0000` with `WSTRB = 0xC` (bytes 2–3), to the same word.
3. Read back and confirm the result is `0x3344_1122`.

---

## 4. Collision Arbitration

### 4.1 — Mixed collision-type sequence

**Objective:** confirm `collision_cnt` accumulates correctly across different collision types, not just repeats of the same type.

1. Reset the module, confirm `INT_STATUS = 0x0`.
2. Force a Read/Write collision (real collision #1).
3. Force a Write/Write collision (real collision #2).
4. Force a Read/Write collision (real collision #3).
5. With `COLLISION_THRESHOLD` at its default (4), force one more real collision (#4) and confirm `COOLDOWN` is entered (`INT_STATUS` bit 1 = 1).

### 4.2 — Real collision exactly as `COOLDOWN` ends

**Objective:** confirm the collision counter restarts cleanly and does not carry over a stale count from the previous round.

1. Set `COLLISION_THRESHOLD = 2`, `COOLDOWN_CYCLES = 4`.
2. Force two real collisions to enter `COOLDOWN`.
3. Wait until the last cycle of `COOLDOWN` (both ports still stalled).
4. On the exact cycle `COOLDOWN` ends, immediately force a new real collision.
5. Confirm this collision is counted as the first of a fresh sequence (i.e. two more real collisions are required before the next `COOLDOWN`, not one).

### 4.3 — Second full `COOLDOWN` cycle

**Objective:** confirm the mechanism is repeatable, not one-shot.

1. With default settings, drive the arbiter into `COOLDOWN` once (4 real collisions).
2. Wait for `COOLDOWN` to end and confirm normal operation resumes (a plain write succeeds with `OKAY`).
3. Drive 4 more real collisions and confirm a **second** `COOLDOWN` is entered correctly.

### 4.4 — `COLLISION_THRESHOLD` boundary and mid-range values

**Objective:** confirm correct behavior at the extremes of the 8-bit range, plus one representative mid-range value.

1. **Minimum (`1`):** write `COLLISION_THRESHOLD = 1`. Force a single real collision. Confirm `COOLDOWN` is entered immediately, after exactly one collision.
2. **Mid-range (`16`):** write `COLLISION_THRESHOLD = 16`. Force 15 real collisions and confirm `COOLDOWN` is **not** yet entered. Force one more (16th) and confirm `COOLDOWN` is entered on that exact collision.
3. **Maximum (`255`):** write `COLLISION_THRESHOLD = 255`. Force 254 real collisions and confirm `COOLDOWN` is still not entered. Force the 255th and confirm `COOLDOWN` is entered, with no overflow or wraparound of the 8-bit counter.

### 4.5 — `COOLDOWN_CYCLES` boundary and mid-range values

**Objective:** confirm the stall duration is correct at the extremes and at a mid-range value.

1. **Minimum (`1`):** write `COOLDOWN_CYCLES = 1`. Trigger `COOLDOWN` and confirm both `a_awready_o` and `b_awready_o` are stalled for exactly 1 cycle before returning to normal.
2. **Mid-range (`16`):** write `COOLDOWN_CYCLES = 16`. Trigger `COOLDOWN` and confirm the stall lasts exactly 16 cycles.
3. **Maximum (`255`):** write `COOLDOWN_CYCLES = 255`. Trigger `COOLDOWN` and confirm the stall lasts exactly 255 cycles, with no early exit and no overflow of the 8-bit counter.

### 4.6 — `FORCE_PRIORITY` updated immediately before a Write/Write collision

**Objective:** confirm the arbiter uses the current register value, not a stale one.

1. Confirm `FORCE_PRIORITY = 0` (Port A wins by default) after reset.
2. Write `FORCE_PRIORITY = 1` via Port A.
3. In the very next cycle, force a Write/Write collision between Port A and Port B on the same address.
4. Confirm Port B wins (`BRESP = OKAY` on Port B, `SLVERR` on Port A), reflecting the newly written value, not the old default.

### 4.7 — Simultaneous register-region and memory-region access, no false collision

**Objective:** confirm a register access on one port never registers as a collision with a memory access on the other port, even if the pre-decode addresses would numerically overlap.

1. On Port A, issue a read of `INT_ENABLE` (word 0, register region) in the same cycle that Port B issues a write to a memory word.
2. Confirm neither `INT_STATUS` bit 0 (collision) is set nor either port receives `SLVERR` as a result of this overlap — the accesses target entirely different regions and must not interact.

---

## 5. `dp_sram_regfile.v` — Additional Cases

### 5.1 — Simultaneous writes to different registers

**Objective:** confirm `write_conflict` only triggers on address match, not on simultaneous activity in general.

1. In the same cycle, Port A writes `INT_ENABLE = 0x1` and Port B writes `FORCE_PRIORITY = 0x1`.
2. Confirm both writes succeed (`BRESP = OKAY` on both ports).
3. Read back both registers and confirm each holds its own written value.

### 5.2 — Read during a same-cycle write (different port)

**Objective:** confirm the combinational read mux reflects the pre-write value, not the value being written in the same cycle.

1. Write `INT_ENABLE = 0x5` via Port A and let it complete.
2. In one cycle, Port A issues a write of `INT_ENABLE = 0xA`, while Port B simultaneously issues a read of `INT_ENABLE`.
3. Confirm Port B's read returns the **old** value (`0x5`), since the register only updates on the clock edge, and reads the new value only starting from the next cycle.

### 5.3 — Blocked write has no partial effect

**Objective:** confirm a write blocked by `write_conflict` has zero effect, not a partial one.

1. In the same cycle, Port A writes `INT_ENABLE = 0x1` and Port B writes `INT_ENABLE = 0xFFFF_FFFF` (same address).
2. Confirm Port A's value wins completely.
3. Read `INT_ENABLE` and confirm it equals exactly `0x1` — no bits from Port B's attempted write leaked through.

### 5.4 — `BANDWIDTH` read exactly at window rollover

**Validated via:** `tb_dp_sram_regfile.v` (unit-level), not `tb_dp_sram_top.v`. `dp_sram_top.v` does not expose `WINDOW_CYCLES` as a pass-through parameter, so the default 1024-cycle window cannot be shortened from the top-level testbench — the regfile-level testbench already supports a shortened `WINDOW_CYCLES` override and drives `a_mem_valid_i` directly.

**Objective:** confirm no torn/half-updated value is visible at the exact rollover boundary.

1. Reset the module. Hold `a_mem_valid_i` high for the entire first measurement window.
2. Read `BANDWIDTH_A` on the exact cycle the window rolls over.
3. Confirm the value read is the **completed** count from the window that just ended, not a partially reset value.
4. On the following cycle, confirm the internal active-cycle counter has already restarted from zero for the new window.

### 5.5 — Rapidly toggling activity within a window

**Validated via:** `tb_dp_sram_regfile.v` (unit-level) — same reason as 5.4.

**Objective:** confirm the active-cycle count has no off-by-one error under alternating activity.

1. Reset the module. For one full measurement window, alternate `a_mem_valid_i` between `1` and `0` every other cycle.
2. At the end of the window, read `BANDWIDTH_A` and confirm it equals exactly half the window length (rounded per the actual toggle pattern used).

### 5.6 — Write to the reserved word (word 7)

**Objective:** confirm the unmapped register slot is inert.

1. Write an arbitrary non-zero value (e.g. `0xDEAD_BEEF`) to byte address `0x1C` (word 7).
2. Confirm `BRESP = OKAY` (the write is accepted at the protocol level).
3. Read back address `0x1C` and confirm it returns `0x0000_0000`.

### 5.7 — `BANDWIDTH` activity-duration boundary and mid-range values

**Validated via:** `tb_dp_sram_regfile.v` (unit-level) — same reason as 5.4/5.5.

**Objective:** confirm correct counting at the extremes of possible activity within one window.

1. **Minimum (0 active cycles):** keep `a_mem_valid_i = 0` for an entire window. Confirm `BANDWIDTH_A` reads `0` at the next window boundary.
2. **Mid-range (half the window):** hold `a_mem_valid_i = 1` for exactly half of `WINDOW_CYCLES`, then `0` for the remainder. Confirm `BANDWIDTH_A` equals exactly `WINDOW_CYCLES / 2`.
3. **Maximum (every cycle active):** hold `a_mem_valid_i = 1` for the entire window. Confirm `BANDWIDTH_A` equals `WINDOW_CYCLES - 1` — this is the true achievable maximum, not `WINDOW_CYCLES` (see the known limitation noted in `dp_sram_regfile.v` and `dp_sram_register_map.md`: the last cycle of each window always seeds the next window's count instead of completing the current one).

---

## 6. System-Level Integration (`dp_sram_top.v`)

### 6.1 — Rapid alternation across the register/memory boundary

**Objective:** stress the `a_is_reg`/`b_is_reg` address decode logic for glitches at the exact boundary.

1. Issue a read of word 7 (byte `0x1C`, last register slot).
2. Immediately issue a write to word 8 (byte `0x20`, first memory word).
3. Immediately issue a read of word 7 again.
4. Repeat this alternation for at least 20 consecutive transactions.
5. Confirm every register-region access returns/accepts correctly (word 7 always reads `0`) and every memory-region access behaves as ordinary memory, with no crossed or corrupted values.

### 6.2 — Reset applied mid-transaction

**Objective:** confirm a clean recovery from reset asserted while a transaction is in flight.

1. Start a write transaction on Port A (`AWVALID`/`WVALID` accepted, now waiting in `WR_RESP` for `BREADY`).
2. Assert `rst_n_i = 0` while still waiting for `BREADY`.
3. Hold reset for 3 cycles, then release it.
4. Confirm the FSM is back in `IDLE` (`a_awready_o` and `a_arready_o` behave normally for a fresh transaction), `aw_have`/`w_have` are both clear, and no partial write reached the memory array.
5. Issue a fresh, complete write and confirm it succeeds normally.

### 6.3 — Sustained mixed workload

**Objective:** representative of real operating conditions — CPU on the register region, DMA on the memory region, running concurrently for an extended period.

1. On Port A, continuously issue a mix of register reads and writes (e.g. polling `INT_STATUS`, occasionally writing `INT_ENABLE`) for several hundred cycles.
2. On Port B, concurrently issue continuous memory writes and reads to a range of addresses, for the same duration.
3. Confirm no transaction on either port ever stalls indefinitely, no `BRESP`/`RRESP` is unexpectedly `SLVERR` (register accesses never collide with memory accesses — see test 4.7), and all data written by Port B is correctly readable afterward.

### 6.4 — Full address range coverage

**Objective:** confirm basic read/write correctness across the entire usable address range, at the extremes and at a representative mid-range point.

1. **Minimum register address (word 0):** write and read back `INT_STATUS`-adjacent behavior is already covered elsewhere; here simply confirm word 0 (byte `0x00`) is reachable and responds with `OKAY`.
2. **Minimum memory address (word 8, byte `0x20`):** write `0x1111_1111` and read it back.
3. **Mid-range memory address (word 130, byte `0x208`):** write `0x2222_2222` and read it back.
4. **Maximum memory address (word 255, byte `0x3FC`):** write `0x3333_3333` and read it back.
5. Confirm all three memory locations hold distinct, correct values simultaneously (i.e. writing to one did not alias onto another).
