# Deadline escalation changing the service order, observed through the CPU.
#
# The controller escalates a source that has waited longer than its deadline,
# moving it to a more urgent band so it stops losing. The controller's own bench
# checks that by watching the offer directly. What it cannot show is the thing
# the feature exists for: that the escalation changes which handler a real
# processor enters first.
#
# The order is the whole proof here. Slot 8 sits in band 1 and slot 9 in band 3,
# so under the reset band ordering slot 8 outranks slot 9 and would be serviced
# first. Slot 9 carries a deadline. Both are raised while the core's global
# interrupt enable is still clear, so neither can be claimed and slot 9 is left
# to miss its deadline. When the core finally opens up, an escalation that
# worked puts slot 9 first and one that did not leaves slot 8 first.
#
# Raising them with interrupts disabled is what makes the wait deterministic.
# The counter runs while a source is a pending request awaiting service, and a
# source the core has not yet allowed through is exactly that.
#
# SoC map: IMEM 0x0000_0000, DMEM 0x0000_2000, DP-SRAM 0x1000_0000,
#          PIC 0x3000_0000, mtimer 0x3001_0000, DMA 0x3002_0000
#
# Scoreboard (byte offset off x14 = 0x2000):
#   0x200  ACTIVE_VEC in the first handler entered   expect 0x109 (the escalated one)
#   0x204  ACTIVE_VEC in the second                  expect 0x108
#   0x208  SRC9_STATUS while it was still waiting    bench: ESC set, band 0
#   0x20C  SRC8_STATUS while it was still waiting    bench: ESC clear, band 1
#   0x210  INT_STATUS while they were waiting        expect bit 1 set
#   0x214  handler entries                           expect 2
#   0x218  done marker                               0xD05ED01E
#
# Reserved registers: x14 DMEM base, x25 PIC base, x31 handler entries,
#                     x21 scoreboard write pointer, x30 handler scratch.

_start:
    lui  x14, 2                  # x14 = 0x2000, DMEM base
    lui  x25, 0x30000            # x25 = PIC base

    # ---- slot 8 more urgent than slot 9, and only slot 9 has a deadline ---
    addi x30, x0, 2
    sw   x30, 0x20(x25)          # SRC8_CONFIG = band 1, no deadline
    lui  x30, 0x20               # deadline 32 in [31:16]
    addi x30, x30, 6             # band 3, level-triggered
    sw   x30, 0x24(x25)          # SRC9_CONFIG
    sw   x0, 0xD4(x25)           # ESCALATION_CFG = jump to band 0, once
    addi x30, x0, 0x300
    sw   x30, 0xD8(x25)          # PIC INT_ENABLE = slots 8 and 9

    # ---- the core is told about both, but keeps its door shut for now -----
    addi x28, x0, irq_handler
    csrrw x0, mtvec, x28         # direct mode
    lui  x28, 0x3000             # mie[25:24] = sources 9 and 8
    csrrw x0, mie, x28
    addi x31, x0, 0
    addi x21, x14, 0x200         # scoreboard write pointer

    # ---- raise both while nothing can be claimed --------------------------
    lui  x6, 0xA5A50
    addi x6, x6, 1
    sw   x6, 0x64(x25)           # SRC9_SW_TRIG, the one with the deadline
    sw   x6, 0x60(x25)           # SRC8_SW_TRIG, the one that outranks it

    # ---- wait, comfortably longer than the deadline -----------------------
    addi x7, x0, 100
esc_wait:
    addi x7, x7, -1
    bne  x7, x0, esc_wait

    # ---- the escalation is visible before anything is serviced ------------
    lw   x30, 0xA4(x25)          # SRC9_STATUS: ESC set, effective band moved
    sw   x30, 0x208(x14)
    lw   x30, 0xA0(x25)          # SRC8_STATUS: untouched, still band 1
    sw   x30, 0x20C(x14)
    lw   x30, 0xDC(x25)          # INT_STATUS: the global escalation flag
    sw   x30, 0x210(x14)

    # ---- now let them through, most urgent first --------------------------
    addi x28, x0, 8
    csrrs x0, mstatus, x28       # mstatus.MIE = 1

wait_both:
    addi x30, x0, 2
    bne  x31, x30, wait_both
    sw   x31, 0x214(x14)

    lui  x30, 0xD05ED
    addi x30, x30, 0x01E
    sw   x30, 0x218(x14)

halt:
    beq  x0, x0, halt

# ---------------------------------------------------------------------------
# interrupt handler
# ---------------------------------------------------------------------------
# No nesting here, so no saved state to restore: this test is about the order
# the two handlers are entered in, and each one runs to completion.
irq_handler:
    lw   x30, 0xCC(x25)          # ACTIVE_VEC
    sw   x30, 0(x21)
    addi x21, x21, 4
    addi x31, x31, 1
    mret
