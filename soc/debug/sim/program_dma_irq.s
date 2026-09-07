# A DMA channel whose interrupt output is masked must stay silent.
#
# The DMA drives irq = INT_STATUS & INT_ENABLE, so a completed transfer on a
# channel software has not enabled must set the status bit and raise nothing.
# Every other program in this tree writes INT_ENABLE before it starts a
# transfer, so all of them prove the positive half and none prove the negative
# one: a design that ignored INT_ENABLE entirely would pass them all.
#
# This program runs a complete transfer with INT_ENABLE at its reset value of
# zero, and records four independent views of "nothing was raised":
#   - the CPU's own interrupt count is still zero
#   - the interrupt controller's source 0 is not pending
#   - the CPU's mip shows nothing waiting
#   - and the DMA's INT_STATUS says the event really did happen anyway
#
# The last one matters as much as the first three. Without it, a DMA that
# silently failed to complete the transfer would look identical to a DMA that
# correctly masked its interrupt.
#
# It then unmasks and requires the same, still-pending event to arrive.
#
# SoC map: IMEM 0x0000_0000, DMEM 0x0000_2000, DP-SRAM 0x1000_0000,
#          PIC 0x3000_0000, mtimer 0x3001_0000, DMA 0x3002_0000
#
# DMEM layout (x14 = 0x2000):
#   0x000  descriptor: src, dst, len, ctrl
#   0x100  16 source words
#   0x200  scoreboard, checked by the bench
#
# Scoreboard (byte offset off x14):
#   0x200  mismatched words after the transfer        expect 0
#   0x204  interrupts taken while the DMA was masked  expect 0
#   0x208  DMA INT_STATUS while masked                expect 1
#   0x20C  PIC SRC0_STATUS while masked               expect 0
#   0x210  CPU mip while masked                       expect 0
#   0x214  CH0_STATUS while masked                    expect 4 (STATE_DONE)
#   0x218  interrupts taken after unmasking           expect 1
#   0x21C  PIC ACTIVE_VEC inside the handler          expect 0x100
#   0x220  done marker                                0xD05ED01E
#
# Reserved registers: x14 DMEM base, x29 DMA base, x31 interrupt count,
#                     x28/x30 scratch.

_start:
    lui  x14, 2                  # x14 = 0x2000, DMEM base

    # ---- fill 16 source words --------------------------------------------
    addi x5, x14, 0x100
    lui  x6, 0xBEEF0             # x6 = 0xBEEF0000
    addi x7, x0, 16
fill_loop:
    sw   x6, 0(x5)
    addi x6, x6, 1
    addi x5, x5, 4
    addi x7, x7, -1
    bne  x7, x0, fill_loop

    # ---- descriptor: DMEM 0x2100 -> SRAM data, 64 bytes -------------------
    addi x6, x14, 0x100
    sw   x6, 0(x14)              # desc[0] = src
    lui  x5, 0x10000
    addi x5, x5, 0x20            # SRAM data starts after its 8 registers
    sw   x5, 4(x14)              # desc[1] = dst
    addi x6, x0, 64
    sw   x6, 8(x14)              # desc[2] = length in bytes
    addi x6, x0, 1
    sw   x6, 12(x14)             # desc[3] = ctrl, bit0 = last segment

    # ---- the interrupt path is fully armed EXCEPT at the DMA -------------
    # Everything downstream of the DMA is open, so if anything arrives it is
    # the DMA's mask that failed and nothing else.
    lui  x28, 0x30000            # PIC
    addi x30, x0, 1
    sw   x30, 0xD8(x28)          # PIC INT_ENABLE = source 0

    addi x28, x0, irq_handler
    csrrw x0, mtvec, x28         # direct mode
    lui  x28, 0x10               # mie[16] = controller source 0
    csrrw x0, mie, x28
    addi x31, x0, 0
    addi x28, x0, 8
    csrrs x0, mstatus, x28       # mstatus.MIE = 1

    # ---- program the DMA with its interrupt output masked ----------------
    lui  x29, 0x30020            # x29 = DMA base
    sw   x0, 0x48(x29)           # SCHED_POLICY = 0 (fixed priority)
    lui  x6, 0x07D00
    addi x6, x6, 0xC8            # max_tokens = 2000, refill = 200 per window
    sw   x6, 0x08(x29)           # CH0_BW_CAP
    sw   x0, 0x44(x29)           # DMA INT_ENABLE = 0  <- the subject of the test
    sw   x14, 0x00(x29)          # CH0_DESC_ADDR = 0x2000
    addi x6, x0, 1
    sw   x6, 0x04(x29)           # CH0_CONTROL.enable = 1 -> the transfer starts

    # ---- poll, because there is deliberately no interrupt to sleep on ----
poll_done:
    lw   x30, 0x0C(x29)          # CH0_STATUS
    addi x5, x0, 4               # STATE_DONE
    bne  x30, x5, poll_done

    # ---- give an interrupt that should not exist time to arrive ----------
    addi x7, x0, 60
settle:
    addi x7, x7, -1
    bne  x7, x0, settle

    # ---- four independent views of "nothing was raised" -------------------
    sw   x31, 0x204(x14)         # interrupts taken so far
    lw   x30, 0x40(x29)
    sw   x30, 0x208(x14)         # DMA INT_STATUS: the event did happen
    lui  x28, 0x30000
    lw   x30, 0x80(x28)
    sw   x30, 0x20C(x14)         # PIC SRC0_STATUS: not pending
    csrrs x30, mip, x0
    sw   x30, 0x210(x14)         # mip: nothing waiting at the CPU either
    lw   x30, 0x0C(x29)
    sw   x30, 0x214(x14)         # CH0_STATUS: still STATE_DONE

    # ---- unmask: the same pending event must now arrive -------------------
    addi x6, x0, 0xF
    sw   x6, 0x44(x29)           # DMA INT_ENABLE = all four channels
wait_irq:
    beq  x31, x0, wait_irq
    sw   x31, 0x218(x14)         # interrupts taken after unmasking

    # ---- the data has to be right either way ------------------------------
    lui  x5, 0x10000
    addi x5, x5, 0x20            # SRAM data pointer
    addi x6, x14, 0x100          # source pointer
    addi x7, x0, 16
    addi x8, x0, 0               # mismatch counter
cmp_loop:
    lw   x9,  0(x5)
    lw   x10, 0(x6)
    beq  x9, x10, cmp_ok
    addi x8, x8, 1
cmp_ok:
    addi x5, x5, 4
    addi x6, x6, 4
    addi x7, x7, -1
    bne  x7, x0, cmp_loop
    sw   x8, 0x200(x14)

    # done marker last, so the bench never samples a half-filled scoreboard
    lui  x30, 0xD05ED
    addi x30, x30, 0x01E
    sw   x30, 0x220(x14)

halt:
    beq  x0, x0, halt

# ---------------------------------------------------------------------------
# interrupt handler
# ---------------------------------------------------------------------------
# The channel's line is a level that stays asserted while the channel sits in
# STATE_DONE, so the enable goes first: it lets the channel fall back to IDLE
# and drop its request. Only then does writing 1 to INT_STATUS release it.
irq_handler:
    lui  x28, 0x30020            # DMA
    sw   x0,  0x04(x28)          # CH0_CONTROL = 0 -> channel back to IDLE
    addi x30, x0, 0xF
    sw   x30, 0x40(x28)          # write-1-to-clear INT_STATUS
    lui  x28, 0x30000            # PIC
    lw   x30, 0xCC(x28)          # ACTIVE_VEC: the source being serviced
    sw   x30, 0x21C(x14)
    addi x31, x31, 1
    mret
