# A DMA burst that runs off the end of its window mid-transfer.
#
# The burst bridge folds the responses of a burst's beats into one, worst-case
# first, so a write that failed part way through cannot report success. Nothing
# at system level has ever produced that: the only error responses any run sees
# come from requests the bridge itself refuses before touching the bus, and the
# DMA has never been pointed anywhere that could answer with an error.
#
# The dual-port memory's window is exactly the size of the memory behind it, so
# an address past its end misses every window and the decoder answers with an
# error. A transfer aimed at the last words of that window therefore has some
# beats land and the rest fail, inside one burst - which is the case the fold
# exists for, and the case a driver hits when a descriptor is one segment too
# long.
#
# Two things have to be true afterwards, and they pull in opposite directions:
# the channel must report the failure rather than completing, and the beats that
# did land must have landed. A design that abandoned the burst at the first
# error would satisfy the first and not the second; one without the fold would
# satisfy the second and not the first.
#
# The program runs a clean transfer first, into the same memory, so the run
# distinguishes "this address fails" from "this memory never worked".
#
# SoC map: IMEM 0x0000_0000, DMEM 0x0000_2000, DP-SRAM 0x1000_0000,
#          PIC 0x3000_0000, mtimer 0x3001_0000, DMA 0x3002_0000
#
# The memory's window is 1 KB. Its last word is at 0x1000_03FC, so a 32-byte
# transfer starting at 0x1000_03F0 puts four beats inside it and four past it.
#
# DMEM layout (x14 = 0x2000):
#   0x000  descriptor
#   0x100  8 source words
#   0x200  scoreboard
#
# Scoreboard (byte offset off x14):
#   0x200  CH0_STATUS after the clean transfer      expect 4 (STATE_DONE)
#   0x204  mismatched words after the clean one     expect 0
#   0x208  CH0_STATUS after the overrunning one     expect 5 (STATE_ERROR)
#   0x20C  first in-window word of the bad burst    expect 0xBAD00000
#   0x210  last in-window word of the bad burst     expect 0xBAD00003
#   0x214  done marker                              0xD05ED01E
#
# Reserved registers: x14 DMEM base, x29 DMA base.

_start:
    lui  x14, 2                  # x14 = 0x2000, DMEM base
    lui  x29, 0x30020            # x29 = DMA base

    # ---- the scheduler and the bandwidth cap ------------------------------
    sw   x0, 0x48(x29)           # SCHED_POLICY = fixed priority
    lui  x6, 0x07D00
    addi x6, x6, 0xC8
    sw   x6, 0x08(x29)           # CH0_BW_CAP
    addi x6, x0, 0xF
    sw   x6, 0x44(x29)           # INT_ENABLE, so INT_STATUS is observable

    # =====================================================================
    # 1. a clean transfer into the same memory, well inside the window
    # =====================================================================
    addi x5, x14, 0x100
    lui  x6, 0xC0DE0
    addi x7, x0, 8
fill_good:
    sw   x6, 0(x5)
    addi x6, x6, 1
    addi x5, x5, 4
    addi x7, x7, -1
    bne  x7, x0, fill_good

    addi x6, x14, 0x100
    sw   x6, 0(x14)              # desc[0] = src
    lui  x5, 0x10000
    addi x5, x5, 0x20            # well inside the window
    sw   x5, 4(x14)              # desc[1] = dst
    addi x6, x0, 32
    sw   x6, 8(x14)              # desc[2] = 32 bytes
    addi x6, x0, 1
    sw   x6, 12(x14)             # desc[3] = last segment

    sw   x14, 0x00(x29)          # CH0_DESC_ADDR
    addi x6, x0, 1
    sw   x6, 0x04(x29)           # start

wait_good:
    lw   x30, 0x0C(x29)
    addi x5, x0, 4               # STATE_DONE
    beq  x30, x5, good_done
    addi x5, x0, 5               # STATE_ERROR, so a failure here is not a hang
    bne  x30, x5, wait_good
good_done:
    sw   x30, 0x200(x14)

    lui  x5, 0x10000
    addi x5, x5, 0x20
    addi x6, x14, 0x100
    addi x7, x0, 8
    addi x8, x0, 0
cmp_good:
    lw   x9,  0(x5)
    lw   x10, 0(x6)
    beq  x9, x10, cmp_ok
    addi x8, x8, 1
cmp_ok:
    addi x5, x5, 4
    addi x6, x6, 4
    addi x7, x7, -1
    bne  x7, x0, cmp_good
    sw   x8, 0x204(x14)

    # release the channel and its status bit before re-arming it
    sw   x0,  0x04(x29)          # CH0_CONTROL = 0 -> back to IDLE
    addi x6, x0, 0xF
    sw   x6, 0x40(x29)           # write-1-to-clear INT_STATUS

    # =====================================================================
    # 2. the same shape of transfer, aimed at the end of the window
    # =====================================================================
    addi x5, x14, 0x100
    lui  x6, 0xBAD00             # a different pattern, so the landed beats
    addi x7, x0, 8               # cannot be confused with the clean transfer
fill_bad:
    sw   x6, 0(x5)
    addi x6, x6, 1
    addi x5, x5, 4
    addi x7, x7, -1
    bne  x7, x0, fill_bad

    addi x6, x14, 0x100
    sw   x6, 0(x14)              # desc[0] = src
    lui  x5, 0x10000
    addi x5, x5, 0x3F0           # four words from the end of the window
    sw   x5, 4(x14)              # desc[1] = dst
    addi x6, x0, 32
    sw   x6, 8(x14)              # desc[2] = 32 bytes: four in, four past it
    addi x6, x0, 1
    sw   x6, 12(x14)

    sw   x14, 0x00(x29)          # CH0_DESC_ADDR
    addi x6, x0, 1
    sw   x6, 0x04(x29)           # start

wait_bad:
    lw   x30, 0x0C(x29)
    addi x5, x0, 5               # STATE_ERROR
    beq  x30, x5, bad_done
    addi x5, x0, 4               # STATE_DONE, so a wrong pass is not a hang
    bne  x30, x5, wait_bad
bad_done:
    sw   x30, 0x208(x14)

    # ---- the beats that were inside the window must have landed -----------
    lui  x5, 0x10000
    addi x5, x5, 0x3F0
    lw   x30, 0(x5)
    sw   x30, 0x20C(x14)
    lw   x30, 12(x5)
    sw   x30, 0x210(x14)

    lui  x30, 0xD05ED
    addi x30, x30, 0x01E
    sw   x30, 0x214(x14)

halt:
    beq  x0, x0, halt
