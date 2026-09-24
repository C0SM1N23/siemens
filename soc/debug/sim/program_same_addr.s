# The CPU and the DMA writing the same words at the same time.
#
#   phase 1  DMEM. The DMA copies 8 words from DMEM 0x100 to DMEM 0x300 while
#            the CPU keeps writing its own pattern to the same 8 words. The
#            arbiter serialises the two masters; the bench checks that every
#            word ends as the last write the memory received.
#   phase 2  SRAM, FORCE_PRIORITY = 0: port A (the CPU) wins a write/write
#            collision, so a colliding DMA beat is answered SLVERR.
#   phase 3  SRAM, FORCE_PRIORITY = 1: port B (the DMA) wins, so a colliding
#            CPU store is answered SLVERR and traps as a store access fault.
# A collision needs both ports on one word in one cycle, so in the SRAM phases
# the CPU hammers a single destination word, and the transfer is repeated until
# the SRAM's INT_STATUS reports a collision (at most 40 transfers).
#
# DMEM layout (x14 = 0x2000):
#   0x000  descriptor           0x100  8 source words 0xD0A00000 + i
#   0x200  scoreboard           0x300  phase-1 destination
#
# Scoreboard (byte offset off x14):
#   0x200  phase 1: final CH0_STATUS
#   0x204  phase 2: final CH0_STATUS        0x208  phase 2: CPU store faults
#   0x20C  phase 3: final CH0_STATUS        0x210  phase 3: CPU store faults
#   0x214  current phase, for the bench
#   0x218  done marker                      0x5A3E_5A3E
#
# Reserved registers: x14 DMEM base, x29 DMA base, x25 SRAM base,
#                     x21 store-fault count (the handler increments it).

_start:
    lui  x14, 2
    lui  x29, 0x30020
    lui  x25, 0x10000
    lui  x5, %hi(handler)
    addi x5, x5, %lo(handler)
    csrrw x0, mtvec, x5

    sw   x0, 0x48(x29)           # SCHED_POLICY = fixed priority
    lui  x6, 0x07D00
    addi x6, x6, 0xC8
    sw   x6, 0x08(x29)           # CH0_BW_CAP
    addi x5, x14, 0x100          # source words
    lui  x6, 0xD0A00
    addi x7, x0, 8
fill:
    sw   x6, 0(x5)
    addi x6, x6, 1
    addi x5, x5, 4
    addi x7, x7, -1
    bne  x7, x0, fill

    # phase 1: both masters on the same DMEM words
    addi x6, x0, 1
    sw   x6, 0x214(x14)
    addi x10, x14, 0x300         # x10 = destination
    jal  x1, race
    sw   x30, 0x200(x14)

    # phase 2: the same on the SRAM, the CPU's port winning
    addi x6, x0, 2
    sw   x6, 0x214(x14)
    sw   x0, 8(x25)              # FORCE_PRIORITY = 0
    addi x21, x0, 0
    addi x10, x25, 0x40          # x10 = SRAM data word 8 onward
    jal  x1, race_sram
    sw   x30, 0x204(x14)
    sw   x21, 0x208(x14)

    # phase 3: the DMA's port winning
    addi x6, x0, 3
    sw   x6, 0x214(x14)
    addi x6, x0, 1
    sw   x6, 8(x25)              # FORCE_PRIORITY = 1
    addi x21, x0, 0
    addi x10, x25, 0x60
    jal  x1, race_sram
    sw   x30, 0x20C(x14)
    sw   x21, 0x210(x14)

    sw   x0, 0x214(x14)
    lui  x30, 0x5A3E6
    addi x30, x30, -0x5C2        # 0x5A3E5A3E
    sw   x30, 0x218(x14)
halt:
    beq  x0, x0, halt

# race_sram: repeat race_one until the SRAM has seen a write/write collision.
# x30 = the channel's final state in the last transfer.
race_sram:
    addi x11, x1, 0
    addi x9, x0, 40              # attempts left
race_again:
    addi x6, x0, 1
    sw   x6, 0(x25)              # SRAM INT_STATUS: clear the collision flag
    jal  x1, race_one
    lw   x6, 0(x25)
    andi x6, x6, 1
    bne  x6, x0, race_done       # collided
    addi x9, x9, -1
    bne  x9, x0, race_again
race_done:
    jalr x0, x11, 0

# race_one: start the same copy, store to word 3 of the destination (the DMA's
# fourth beat) 64 times, then wait for the channel. x30 = final state.
race_one:
    addi x6, x14, 0x100
    sw   x6, 0x00(x14)
    sw   x10, 0x04(x14)
    addi x6, x0, 32
    sw   x6, 0x08(x14)
    addi x6, x0, 1
    sw   x6, 0x0C(x14)
    sw   x14, 0x00(x29)
    sw   x6, 0x04(x29)
    lui  x8, 0xC0C0C
    addi x8, x8, 0x0C0
    addi x12, x0, 64
hammer_one:
    sw   x8, 12(x10)
    addi x12, x12, -1
    bne  x12, x0, hammer_one
    addi x12, x0, 0
wait_one:
    lw   x30, 0x0C(x29)
    addi x5, x0, 4
    beq  x30, x5, race_end
    addi x5, x0, 5
    beq  x30, x5, race_end
    addi x12, x12, 1
    addi x5, x0, 500
    blt  x12, x5, wait_one
    addi x30, x0, 0xFF
    beq  x0, x0, race_end

# race: start a 32-byte copy from DMEM 0x100 to x10, and store 0xC0C0C0C0 to
# the same 8 words, over and over, until the channel finishes. x30 = final state.
race:
    addi x6, x14, 0x100
    sw   x6, 0x00(x14)           # desc: src
    sw   x10, 0x04(x14)          # dst
    addi x6, x0, 32
    sw   x6, 0x08(x14)
    addi x6, x0, 1
    sw   x6, 0x0C(x14)
    sw   x14, 0x00(x29)          # CH0_DESC_ADDR
    sw   x6, 0x04(x29)           # start
    lui  x8, 0xC0C0C
    addi x8, x8, 0x0C0           # 0xC0C0C0C0
    addi x12, x0, 0
hammer:
    sw   x8, 0(x10)
    sw   x8, 4(x10)
    sw   x8, 8(x10)
    sw   x8, 12(x10)
    sw   x8, 16(x10)
    sw   x8, 20(x10)
    sw   x8, 24(x10)
    sw   x8, 28(x10)
    lw   x30, 0x0C(x29)          # CH0_STATUS
    addi x5, x0, 4
    beq  x30, x5, race_end
    addi x5, x0, 5
    beq  x30, x5, race_end
    addi x12, x12, 1
    addi x5, x0, 500
    blt  x12, x5, hammer
    addi x30, x0, 0xFF           # no final state in time
race_end:
    sw   x0, 0x04(x29)           # channel back to IDLE
    addi x5, x0, 0xF
    sw   x5, 0x40(x29)           # clear INT_STATUS
    jalr x0, x1, 0

.org 0x300
handler:                         # a store the SRAM refused: count it, skip it
    addi x21, x21, 1
    csrrs x28, mepc, x0
    addi x28, x28, 4
    csrrw x0, mepc, x28
    mret
