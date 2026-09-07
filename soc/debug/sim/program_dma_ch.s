# All four DMA channels running at once, under round-robin arbitration.
#
# Every system program in this tree uses channel 0 and only channel 0, with the
# scheduler left in fixed-priority mode. Channels 1 to 3 and the round-robin
# path exist only in the DMA's own block bench, so nothing says a channel other
# than the first can reach the fabric at all: a descriptor fetch that ignored
# the channel index, a register decode that aliased the upper channels onto the
# lower one, or an arbiter grant that never left channel 0 would all pass
# unnoticed.
#
# Four descriptors are built, one per channel, each moving a different pattern
# into its own quarter of the dual-port memory. All four are then started in the
# same instruction sequence, so they contend for the bridge and the arbiter has
# something to arbitrate. Each channel's data is checked separately afterwards,
# which is what turns "something moved" into "channel 2 moved channel 2's
# bytes".
#
# The patterns differ per channel on purpose. If two channels wrote each other's
# regions, or one channel wrote all four, the totals would still be right and
# only the per-channel comparison would notice.
#
# SoC map: IMEM 0x0000_0000, DMEM 0x0000_2000, DP-SRAM 0x1000_0000,
#          PIC 0x3000_0000, mtimer 0x3001_0000, DMA 0x3002_0000
#
# DMEM layout (x14 = 0x2000):
#   0x000  descriptor for channel 0   (4 words)
#   0x010  descriptor for channel 1
#   0x020  descriptor for channel 2
#   0x030  descriptor for channel 3
#   0x100  8 source words for channel 0
#   0x120  8 source words for channel 1
#   0x140  8 source words for channel 2
#   0x160  8 source words for channel 3
#   0x200  scoreboard
#
# SRAM layout: data starts at 0x1000_0020, each channel takes 32 bytes.
#
# Scoreboard (byte offset off x14):
#   0x200  mismatched words, channel 0        expect 0
#   0x204  mismatched words, channel 1        expect 0
#   0x208  mismatched words, channel 2        expect 0
#   0x20C  mismatched words, channel 3        expect 0
#   0x210  DMA INT_STATUS once all are done   expect 0xF
#   0x214  CH0_STATUS                         expect 4 (STATE_DONE)
#   0x218  CH1_STATUS                         expect 4
#   0x21C  CH2_STATUS                         expect 4
#   0x220  CH3_STATUS                         expect 4
#   0x224  done marker                        0xD05ED01E
#
# Reserved registers: x14 DMEM base, x29 DMA base, x25 SRAM data base.

_start:
    lui  x14, 2                  # x14 = 0x2000, DMEM base
    lui  x29, 0x30020            # x29 = DMA base
    lui  x25, 0x10000
    addi x25, x25, 0x20          # x25 = SRAM data base, after its 8 registers

    # ---- four source blocks, one recognisable pattern each ----------------
    # Channel n gets 0xC0DEn000 upward, so a word tells you which channel was
    # supposed to have written it.
    addi x20, x0, 0              # channel index
fill_ch:
    slli x21, x20, 5             # 32 bytes per channel
    add  x21, x21, x14
    addi x21, x21, 0x100         # source pointer for this channel
    slli x22, x20, 12            # 0xn000
    lui  x6, 0xC0DE0
    add  x6, x6, x22             # 0xC0DEn000
    addi x7, x0, 8
fill_word:
    sw   x6, 0(x21)
    addi x6, x6, 1
    addi x21, x21, 4
    addi x7, x7, -1
    bne  x7, x0, fill_word
    addi x20, x20, 1
    addi x23, x0, 4
    bne  x20, x23, fill_ch

    # ---- four descriptors, one per channel --------------------------------
    addi x20, x0, 0
desc_ch:
    slli x21, x20, 4             # 16 bytes per descriptor
    add  x21, x21, x14           # descriptor pointer

    slli x22, x20, 5
    add  x6, x22, x14
    addi x6, x6, 0x100
    sw   x6, 0(x21)              # desc[0] = src

    add  x6, x22, x25
    sw   x6, 4(x21)              # desc[1] = dst, this channel's own quarter

    addi x6, x0, 32
    sw   x6, 8(x21)              # desc[2] = 32 bytes = one full burst
    addi x6, x0, 1
    sw   x6, 12(x21)             # desc[3] = ctrl, last segment

    addi x20, x20, 1
    addi x23, x0, 4
    bne  x20, x23, desc_ch

    # ---- round-robin, and a bandwidth cap wide enough not to throttle -----
    addi x6, x0, 1
    sw   x6, 0x48(x29)           # SCHED_POLICY = 1 (round robin)
    lui  x6, 0x07D00
    addi x6, x6, 0xC8            # max_tokens = 2000, refill = 200 per window
    sw   x6, 0x08(x29)           # CH0_BW_CAP
    sw   x6, 0x18(x29)           # CH1_BW_CAP
    sw   x6, 0x28(x29)           # CH2_BW_CAP
    sw   x6, 0x38(x29)           # CH3_BW_CAP
    addi x6, x0, 0xF
    sw   x6, 0x44(x29)           # INT_ENABLE, so INT_STATUS is observable

    # ---- point each channel at its descriptor -----------------------------
    addi x6, x14, 0x00
    sw   x6, 0x00(x29)           # CH0_DESC_ADDR
    addi x6, x14, 0x10
    sw   x6, 0x10(x29)           # CH1_DESC_ADDR
    addi x6, x14, 0x20
    sw   x6, 0x20(x29)           # CH2_DESC_ADDR
    addi x6, x14, 0x30
    sw   x6, 0x30(x29)           # CH3_DESC_ADDR

    # ---- start all four back to back, so they overlap ---------------------
    addi x6, x0, 1
    sw   x6, 0x04(x29)           # CH0_CONTROL.enable
    sw   x6, 0x14(x29)           # CH1_CONTROL.enable
    sw   x6, 0x24(x29)           # CH2_CONTROL.enable
    sw   x6, 0x34(x29)           # CH3_CONTROL.enable

    # ---- wait for every channel to report DONE ----------------------------
    # No interrupt is used: this program is about the data path and the
    # arbiter, and polling keeps the CPU on the bus while the channels work,
    # which is the condition the arbiter is meant to handle.
wait_all:
    lw   x5,  0x0C(x29)
    lw   x6,  0x1C(x29)
    lw   x7,  0x2C(x29)
    lw   x8,  0x3C(x29)
    addi x9,  x0, 4              # STATE_DONE
    bne  x5, x9, wait_all
    bne  x6, x9, wait_all
    bne  x7, x9, wait_all
    bne  x8, x9, wait_all

    sw   x5, 0x214(x14)
    sw   x6, 0x218(x14)
    sw   x7, 0x21C(x14)
    sw   x8, 0x220(x14)
    lw   x30, 0x40(x29)
    sw   x30, 0x210(x14)         # INT_STATUS: all four channels reported

    # ---- compare each channel's quarter against its own source ------------
    addi x20, x0, 0
cmp_ch:
    slli x22, x20, 5
    add  x5, x22, x25            # this channel's SRAM quarter
    add  x6, x22, x14
    addi x6, x6, 0x100           # this channel's source block
    addi x7, x0, 8
    addi x8, x0, 0               # mismatch counter
cmp_word:
    lw   x9,  0(x5)
    lw   x10, 0(x6)
    beq  x9, x10, cmp_ok
    addi x8, x8, 1
cmp_ok:
    addi x5, x5, 4
    addi x6, x6, 4
    addi x7, x7, -1
    bne  x7, x0, cmp_word

    slli x21, x20, 2
    add  x21, x21, x14
    sw   x8, 0x200(x21)          # mismatches for this channel

    addi x20, x20, 1
    addi x23, x0, 4
    bne  x20, x23, cmp_ch

    lui  x30, 0xD05ED
    addi x30, x30, 0x01E
    sw   x30, 0x224(x14)

halt:
    beq  x0, x0, halt
