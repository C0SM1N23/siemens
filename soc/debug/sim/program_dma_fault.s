# DMA transfers that meet error responses, and the recovery after them.
#
# Every case builds one descriptor, starts channel 0 (channels 0 and 1 in case
# 7), waits for STATE_DONE or STATE_ERROR with a bounded poll, records the final
# state and returns the channel to IDLE. The current case number is kept in
# DMEM so the bench can attribute every bus beat to its case.
#
#   1  source unmapped (0x5000_0000)                     every read beat DECERR
#   2  source runs off the SRAM window (0x1000_03F0)     4 beats OKAY, 4 DECERR
#   3  descriptor at an unmapped address                 descriptor fetch DECERR
#   4  destination is the PIC (not on the DMA's map)     write DECERR, PIC intact
#   5  destination is IMEM (not on the DMA's map)        write DECERR, IMEM intact
#   6  source not word-aligned (0x0000_2102)             refused by the bridge: SLVERR
#   7  channel 0 moves 64 bytes while channel 1 fails    only channel 1 in error
#   8  channel 0 again after all of the above            a clean transfer
#
# SoC map: IMEM 0x0000_0000, DMEM 0x0000_2000, DP-SRAM 0x1000_0000,
#          PIC 0x3000_0000, mtimer 0x3001_0000, DMA 0x3002_0000
#
# DMEM layout (x14 = 0x2000):
#   0x000  descriptor, channel 0          0x010  descriptor, channel 1
#   0x100  16 source words 0xD0A00000 + i
#   0x200  scoreboard
#   0x300  destination of case 2, pre-filled with 0xEEEEEEEE
#   0x3F0  current case number
#
# Scoreboard (byte offset off x14), final CH_STATUS per case unless noted:
#   0x200..0x21C  cases 1..8 (channel 0)       4 = STATE_DONE, 5 = STATE_ERROR,
#   0x220         case 7, channel 1              0xFF = no final state in time
#   0x224  words of case 7 that differ from the source      expect 0
#   0x228  words of case 8 that differ from the source      expect 0
#   0x22C  destination words of cases 1 and 2 still 0xEEEEEEEE   expect 16
#   0x230  done marker                                         0xFA17_ED0E
#
# Reserved registers: x14 DMEM base, x29 DMA base, x25 SRAM data base,
#                     x13 status address for poll, x1 return address.

_start:
    lui  x14, 2                  # x14 = 0x2000
    lui  x29, 0x30020            # x29 = DMA base
    lui  x25, 0x10000
    addi x25, x25, 0x20          # x25 = SRAM data base, after its 8 registers

    sw   x0, 0x48(x29)           # SCHED_POLICY = fixed priority
    lui  x6, 0x07D00
    addi x6, x6, 0xC8
    sw   x6, 0x08(x29)           # CH0_BW_CAP
    sw   x6, 0x18(x29)           # CH1_BW_CAP
    addi x6, x0, 0xF
    sw   x6, 0x44(x29)           # INT_ENABLE, so INT_STATUS is observable

    # source pattern, and the regions no failed transfer may touch
    addi x5, x14, 0x100
    lui  x6, 0xD0A00
    addi x7, x0, 16
fill_src:
    sw   x6, 0(x5)
    addi x6, x6, 1
    addi x5, x5, 4
    addi x7, x7, -1
    bne  x7, x0, fill_src
    lui  x6, 0xEEEEF
    addi x6, x6, -0x112          # 0xEEEEEEEE
    addi x5, x25, 0x40           # case 1 destination: SRAM data + 0x40
    addi x7, x0, 8
fill_dst1:
    sw   x6, 0(x5)
    addi x5, x5, 4
    addi x7, x7, -1
    bne  x7, x0, fill_dst1
    addi x5, x14, 0x300          # case 2 destination: DMEM 0x2300
    addi x7, x0, 8
fill_dst2:
    sw   x6, 0(x5)
    addi x5, x5, 4
    addi x7, x7, -1
    bne  x7, x0, fill_dst2

    # 1. unmapped source
    addi x6, x0, 1
    sw   x6, 0x3F0(x14)
    lui  x6, 0x50000
    addi x7, x25, 0x40
    jal  x1, run_ch0
    sw   x30, 0x200(x14)

    # 2. a source that runs past the end of the SRAM window
    addi x6, x0, 2
    sw   x6, 0x3F0(x14)
    lui  x6, 0x10000
    addi x6, x6, 0x3F0
    addi x7, x14, 0x300
    jal  x1, run_ch0
    sw   x30, 0x204(x14)

    # 3. descriptor at an unmapped address
    addi x6, x0, 3
    sw   x6, 0x3F0(x14)
    lui  x6, 0x50000
    sw   x6, 0x00(x29)           # CH0_DESC_ADDR
    addi x6, x0, 1
    sw   x6, 0x04(x29)           # start
    addi x13, x29, 0x0C
    jal  x1, poll
    sw   x30, 0x208(x14)
    jal  x1, release_ch0

    # 4. destination on the PIC, which the DMA cannot reach
    addi x6, x0, 4
    sw   x6, 0x3F0(x14)
    addi x6, x14, 0x100
    lui  x7, 0x30000
    jal  x1, run_ch0
    sw   x30, 0x20C(x14)

    # 5. destination in IMEM, which the DMA cannot reach
    addi x6, x0, 5
    sw   x6, 0x3F0(x14)
    addi x6, x14, 0x100
    addi x7, x0, 0x100
    jal  x1, run_ch0
    sw   x30, 0x210(x14)

    # 6. a source that is not word-aligned
    addi x6, x0, 6
    sw   x6, 0x3F0(x14)
    addi x6, x14, 0x102
    addi x7, x25, 0x100
    jal  x1, run_ch0
    sw   x30, 0x214(x14)

    # 7. channel 0 moves 64 bytes while channel 1 reads from nowhere
    addi x6, x0, 7
    sw   x6, 0x3F0(x14)
    addi x6, x14, 0x100
    sw   x6, 0x00(x14)           # ch0 desc: src = 16 source words
    addi x6, x25, 0x80
    sw   x6, 0x04(x14)           # dst = SRAM data + 0x80
    addi x6, x0, 64
    sw   x6, 0x08(x14)
    addi x6, x0, 1
    sw   x6, 0x0C(x14)
    lui  x6, 0x50000
    sw   x6, 0x10(x14)           # ch1 desc: unmapped source
    addi x6, x25, 0x100
    sw   x6, 0x14(x14)
    addi x6, x0, 32
    sw   x6, 0x18(x14)
    addi x6, x0, 1
    sw   x6, 0x1C(x14)
    sw   x14, 0x00(x29)          # CH0_DESC_ADDR
    addi x6, x14, 0x10
    sw   x6, 0x10(x29)           # CH1_DESC_ADDR
    addi x6, x0, 1
    sw   x6, 0x04(x29)           # start channel 0
    sw   x6, 0x14(x29)           # start channel 1
    addi x13, x29, 0x0C
    jal  x1, poll
    sw   x30, 0x218(x14)
    addi x13, x29, 0x1C
    jal  x1, poll
    sw   x30, 0x220(x14)
    sw   x0, 0x14(x29)           # channel 1 back to IDLE
    jal  x1, release_ch0
    addi x5, x25, 0x80
    addi x10, x0, 16
    jal  x1, compare
    sw   x8, 0x224(x14)

    # 8. a clean transfer on channel 0 after every failure above
    addi x6, x0, 8
    sw   x6, 0x3F0(x14)
    addi x6, x14, 0x100
    addi x7, x25, 0xC0
    jal  x1, run_ch0
    sw   x30, 0x21C(x14)
    addi x5, x25, 0xC0
    addi x10, x0, 8
    jal  x1, compare
    sw   x8, 0x228(x14)

    # the destinations of cases 1 and 2 must still hold their fill pattern
    addi x8, x0, 0
    lui  x6, 0xEEEEF
    addi x6, x6, -0x112
    addi x5, x25, 0x40
    addi x7, x0, 8
check_dst1:
    lw   x9, 0(x5)
    bne  x9, x6, skip_dst1
    addi x8, x8, 1
skip_dst1:
    addi x5, x5, 4
    addi x7, x7, -1
    bne  x7, x0, check_dst1
    addi x5, x14, 0x300
    addi x7, x0, 8
check_dst2:
    lw   x9, 0(x5)
    bne  x9, x6, skip_dst2
    addi x8, x8, 1
skip_dst2:
    addi x5, x5, 4
    addi x7, x7, -1
    bne  x7, x0, check_dst2
    sw   x8, 0x22C(x14)

    addi x6, x0, 0
    sw   x6, 0x3F0(x14)
    lui  x30, 0xFA17F
    addi x30, x30, -0x2F2        # 0xFA17ED0E
    sw   x30, 0x230(x14)
halt:
    beq  x0, x0, halt

# run_ch0: x6 = source, x7 = destination; 32 bytes, last segment. Returns the
# final CH0_STATUS in x30 with the channel back in IDLE.
run_ch0:
    addi x11, x1, 0
    sw   x6, 0x00(x14)
    sw   x7, 0x04(x14)
    addi x6, x0, 32
    sw   x6, 0x08(x14)
    addi x6, x0, 1
    sw   x6, 0x0C(x14)
    sw   x14, 0x00(x29)          # CH0_DESC_ADDR
    sw   x6, 0x04(x29)           # start
    addi x13, x29, 0x0C
    jal  x1, poll
    jal  x1, release_ch0
    jalr x0, x11, 0

# poll: wait for STATE_DONE (4) or STATE_ERROR (5) at the address in x13;
# x30 = the state, or 0xFF after 4096 reads without either.
poll:
    addi x12, x0, 0
poll_loop:
    lw   x30, 0(x13)
    addi x5, x0, 4
    beq  x30, x5, poll_done
    addi x5, x0, 5
    beq  x30, x5, poll_done
    addi x12, x12, 1
    lui  x5, 1
    blt  x12, x5, poll_loop
    addi x30, x0, 0xFF
poll_done:
    jalr x0, x1, 0

# release_ch0: channel 0 back to IDLE, interrupt status cleared.
release_ch0:
    sw   x0, 0x04(x29)
    addi x5, x0, 0xF
    sw   x5, 0x40(x29)
    jalr x0, x1, 0

# compare: x10 words at x5 against the source at DMEM 0x100; x8 = mismatches.
compare:
    addi x8, x0, 0
    addi x9, x14, 0x100
compare_loop:
    lw   x12, 0(x5)
    lw   x13, 0(x9)
    beq  x12, x13, compare_same
    addi x8, x8, 1
compare_same:
    addi x5, x5, 4
    addi x9, x9, 4
    addi x10, x10, -1
    bne  x10, x0, compare_loop
    jalr x0, x1, 0
