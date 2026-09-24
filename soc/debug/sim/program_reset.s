# Restartable workload for the reset-under-traffic bench (soc_tb_reset_traffic).
#
# The bench resets the SoC at chosen moments; every reset restarts this program
# from the first instruction. Memory contents survive a reset, so the program
# counts its own starts and rebuilds everything else from scratch each time:
# one load that no window accepts, a stream of data-memory loads and stores, and
# a 64-byte DMA transfer from DMEM into the SRAM, checked word by word.
#
# DMEM layout (x14 = 0x2000):
#   0x000  descriptor
#   0x100  16 source words 0xB0070000 + i
#   0x200  scoreboard
#   0x3FC  number of starts (survives resets)
#
# Scoreboard (byte offset off x14):
#   0x200  CH0_STATUS after the transfer            expect 4 (STATE_DONE)
#   0x204  destination words that differ            expect 0
#   0x208  mcause of the unmapped load               expect 5
#   0x20C  number of starts when this run finished   expect resets + 1
#   0x210  done marker                               0x0DD5_EED5
#
# Reserved registers: x14 DMEM base, x29 DMA base, x25 SRAM data base.

_start:
    lui  x14, 2
    lui  x29, 0x30020
    lui  x25, 0x10000
    addi x25, x25, 0x20

    sw   x0, 0x210(x14)          # no result from an earlier, interrupted run
    lw   x5, 0x3FC(x14)
    addi x5, x5, 1
    sw   x5, 0x3FC(x14)

    lui  x5, %hi(handler)
    addi x5, x5, %lo(handler)
    csrrw x0, mtvec, x5
    sw   x0, 0x208(x14)
    lui  x6, 0x50000
    lw   x7, 0(x6)               # DECERR -> load access fault, cause 5

    # source words, written and read back one by one
    addi x5, x14, 0x100
    lui  x6, 0xB0070
    addi x7, x0, 16
fill:
    sw   x6, 0(x5)
    lw   x8, 0(x5)
    addi x6, x6, 1
    addi x5, x5, 4
    addi x7, x7, -1
    bne  x7, x0, fill

    # clear the destination, so a stale copy from an interrupted run cannot pass
    addi x5, x25, 0
    addi x7, x0, 16
clear:
    sw   x0, 0(x5)
    addi x5, x5, 4
    addi x7, x7, -1
    bne  x7, x0, clear

    sw   x0, 0x48(x29)           # SCHED_POLICY = fixed priority
    lui  x6, 0x07D00
    addi x6, x6, 0xC8
    sw   x6, 0x08(x29)           # CH0_BW_CAP
    addi x6, x14, 0x100
    sw   x6, 0x00(x14)           # desc: src
    sw   x25, 0x04(x14)          # dst = SRAM data base
    addi x6, x0, 64
    sw   x6, 0x08(x14)           # 64 bytes, two bursts of eight beats each way
    addi x6, x0, 1
    sw   x6, 0x0C(x14)
    sw   x14, 0x00(x29)          # CH0_DESC_ADDR
    sw   x6, 0x04(x29)           # start

    addi x12, x0, 0
wait_dma:
    lw   x30, 0x0C(x29)
    addi x5, x0, 4
    beq  x30, x5, dma_end
    addi x5, x0, 5
    beq  x30, x5, dma_end
    lw   x8, 0x100(x14)          # data-memory traffic beside the transfer
    addi x12, x12, 1
    lui  x5, 1
    blt  x12, x5, wait_dma
    addi x30, x0, 0xFF
dma_end:
    sw   x30, 0x200(x14)

    addi x8, x0, 0
    addi x5, x25, 0
    addi x9, x14, 0x100
    addi x10, x0, 16
compare:
    lw   x12, 0(x5)
    lw   x13, 0(x9)
    beq  x12, x13, same
    addi x8, x8, 1
same:
    addi x5, x5, 4
    addi x9, x9, 4
    addi x10, x10, -1
    bne  x10, x0, compare
    sw   x8, 0x204(x14)

    lw   x5, 0x3FC(x14)
    sw   x5, 0x20C(x14)
    lui  x30, 0x0DD5F
    addi x30, x30, -0x12B        # 0x0DD5EED5
    sw   x30, 0x210(x14)
halt:
    beq  x0, x0, halt

.org 0x300
handler:
    csrrs x30, mcause, x0
    sw   x30, 0x208(x14)
    csrrs x28, mepc, x0
    addi x28, x28, 4
    csrrw x0, mepc, x28
    mret
