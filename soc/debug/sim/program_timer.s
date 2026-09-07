# The machine timer, armed by software and delivered through the controller.
#
# The timer is wired to interrupt source 7 in this system, but no system program
# has ever armed it: its compare register resets to all-ones, so it sits
# disarmed and its line stays low through every run. The block bench checks its
# registers directly and never lets it fire into a real core. That leaves the
# whole delivery path - compare match, level output, controller source 7, the
# core's enable bit, the handler, and clearing the condition at the peripheral -
# untested as one piece.
#
# The clearing step is the part worth having a system test for. The timer's line
# is a level held by the comparison itself, so a handler that returns without
# moving the compare register is re-entered immediately and the program never
# makes progress. That is a real trap for a driver author, and it is invisible
# to a bench that only reads and writes the registers.
#
# The compare register is written high half first. It resets to all-ones, so
# writing the low half first would leave a value that never matches; and writing
# the high half to zero first cannot cause a spurious match, because the low
# half is still all-ones at that moment.
#
# SoC map: IMEM 0x0000_0000, DMEM 0x0000_2000, DP-SRAM 0x1000_0000,
#          PIC 0x3000_0000, mtimer 0x3001_0000, DMA 0x3002_0000
#
# Timer registers: 0x00 MTIME_LO, 0x04 MTIME_HI, 0x08 MTIMECMP_LO, 0x0C HI
#
# Scoreboard (byte offset off x14 = 0x2000):
#   0x200  interrupts taken                     expect 1
#   0x204  mcause inside the handler            expect 0x80000017 (16 + 7)
#   0x208  ACTIVE_VEC inside the handler        expect 0x107
#   0x20C  MTIME_LO read inside the handler     bench: >= the compare value
#   0x210  the compare value that was armed     bench: reads it back
#   0x214  SRC7_STATUS inside the handler       expect bit 1 set (in service)
#   0x218  SRC7_STATUS after disarming          expect 0 (no longer pending)
#   0x21C  interrupts taken after the handler   expect 1, so it fired once
#   0x220  done marker                          0xD05ED01E
#
# Reserved registers: x14 DMEM base, x25 PIC base, x26 timer base,
#                     x31 interrupt count, x28/x30 scratch.

_start:
    lui  x14, 2                  # x14 = 0x2000, DMEM base
    lui  x25, 0x30000            # x25 = PIC base
    lui  x26, 0x30010            # x26 = machine timer base

    # ---- let source 7 through the controller ------------------------------
    addi x30, x0, 0x80
    sw   x30, 0xD8(x25)          # PIC INT_ENABLE = source 7

    addi x28, x0, irq_handler
    csrrw x0, mtvec, x28         # direct mode
    lui  x28, 0x800              # mie[23] = controller source 7
    csrrw x0, mie, x28
    addi x31, x0, 0
    addi x28, x0, 8
    csrrs x0, mstatus, x28       # mstatus.MIE = 1

    # ---- arm the timer a short way ahead of now ---------------------------
    sw   x0, 0x0C(x26)           # MTIMECMP_HI = 0 (the low half is still ones)
    lw   x30, 0x00(x26)          # MTIME_LO
    addi x30, x30, 200
    sw   x30, 0x210(x14)         # remember what was armed, for the bench
    sw   x30, 0x08(x26)          # MTIMECMP_LO -> the timer is now armed

    # ---- sleep until it fires ---------------------------------------------
    wfi
wait_irq:
    beq  x31, x0, wait_irq

    # ---- the line really was released -------------------------------------
    lw   x30, 0x9C(x25)          # SRC7_STATUS
    sw   x30, 0x218(x14)
    sw   x31, 0x21C(x14)         # and it fired exactly once

    lui  x30, 0xD05ED
    addi x30, x30, 0x01E
    sw   x30, 0x220(x14)

halt:
    beq  x0, x0, halt

# ---------------------------------------------------------------------------
# interrupt handler
# ---------------------------------------------------------------------------
# The timer's request is the comparison itself, held as a level. Moving the
# compare register out of reach is the only way to release it; returning
# without doing so re-enters this handler immediately.
irq_handler:
    csrrs x30, mcause, x0
    sw   x30, 0x204(x14)
    lw   x30, 0xCC(x25)          # ACTIVE_VEC
    sw   x30, 0x208(x14)
    lw   x30, 0x9C(x25)          # SRC7_STATUS while in service
    sw   x30, 0x214(x14)
    lw   x30, 0x00(x26)          # MTIME_LO at the moment it fired
    sw   x30, 0x20C(x14)

    addi x30, x0, -1             # 0xFFFFFFFF
    sw   x30, 0x08(x26)          # MTIMECMP_LO -> out of reach, line drops
    sw   x30, 0x0C(x26)          # MTIMECMP_HI -> fully disarmed again

    addi x31, x31, 1
    sw   x31, 0x200(x14)
    mret
