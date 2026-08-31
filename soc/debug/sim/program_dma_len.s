# SoC test: DMA transfer lengths that are not whole 32-byte chunks.
# Run by tb_soc_dma_len.
#
# Why this exists. The DMA issues 8-beat bursts, 32 bytes at a time, and the
# channel derives the burst length from what is left of the descriptor. Both
# other SoC programs move 64 and 256 bytes - exact multiples of 32 - so the
# whole short-burst path is never entered by the system tests, and a transfer
# that ends mid-chunk is precisely where a DMA writes past what it was asked to
# move. This program walks five lengths through the same channel and leaves the
# result where the bench can read it out of the SRAM array directly.
#
# The five: 64 (two full chunks, the baseline the other tests already cover),
# 40 (one full chunk plus a 2-beat remainder), 20 (5 beats, no full chunk),
# 8 (2 beats) and 4 (a single beat).
#
# Each transfer goes to its own 128-byte slot, and the whole destination area
# is filled with a guard word first, so "wrote too much" and "wrote too little"
# are both visible: the bench checks the words inside the requested length
# against the source, and every word after it against the guard.
#
# Completion is polled rather than taken as an interrupt. The interrupt path is
# already covered end to end by program_soc.s; repeating it here would only add
# a way for this test to fail for an unrelated reason.
#
# SoC map: IMEM 0x0000_0000, DMEM 0x0000_2000, DP-SRAM 0x1000_0000,
#          PIC 0x3000_0000, mtimer 0x3001_0000, DMA 0x3002_0000
#
# DMEM layout (x14 = 0x2000):
#   0x000  descriptor: src, dst, len, ctrl
#   0x100  16 source words, 0xC0DE0000 + i
#   0x300  the five lengths
#   0x400  done marker, read by the bench
#
# SRAM layout: data region starts at 0x1000_0020 (after the 8 registers).
#   slot k is 128 bytes at 0x1000_0020 + k*128, i.e. array words k*32..k*32+31
#
# Reserved registers: x14 DMEM base, x29 DMA base, x5 destination,
#                     x6 length, x8 length pointer, x9 slots left,
#                     x28/x30 scratch.

_start:
    lui  x14, 2                  # x14 = 0x2000, DMEM base

    # ---- 16 source words at 0x2100 ---------------------------------------
    addi x5, x14, 0x100
    lui  x6, 0xC0DE0
    addi x7, x0, 16
fill_src:
    sw   x6, 0(x5)
    addi x6, x6, 1
    addi x5, x5, 4
    addi x7, x7, -1
    bne  x7, x0, fill_src

    # ---- guard the whole destination area --------------------------------
    # 160 words = the five 32-word slots. Written by the CPU on port A, so the
    # DMA's writes on port B later land on top of a known pattern.
    lui  x5, 0x10000
    addi x5, x5, 0x20
    lui  x6, 0xBADD0
    addi x7, x0, 160
fill_guard:
    sw   x6, 0(x5)
    addi x5, x5, 4
    addi x7, x7, -1
    bne  x7, x0, fill_guard

    # ---- the five lengths, at 0x2300 -------------------------------------
    addi x8, x14, 0x300
    addi x6, x0, 64
    sw   x6, 0(x8)
    addi x6, x0, 40
    sw   x6, 4(x8)
    addi x6, x0, 20
    sw   x6, 8(x8)
    addi x6, x0, 8
    sw   x6, 12(x8)
    addi x6, x0, 4
    sw   x6, 16(x8)

    # ---- DMA setup, once -------------------------------------------------
    lui  x29, 0x30020            # DMA base
    sw   x0, 0x48(x29)           # SCHED_POLICY = fixed priority
    lui  x6, 0x07D00
    addi x6, x6, 0xC8            # max_tokens = 2000, refill = 200
    sw   x6, 0x08(x29)           # CH0_BW_CAP
    addi x6, x0, 0xF
    sw   x6, 0x44(x29)           # INT_ENABLE, so INT_STATUS is observable

    # ---- walk the five lengths -------------------------------------------
    lui  x5, 0x10000
    addi x5, x5, 0x20            # destination of slot 0
    addi x8, x14, 0x300          # length pointer
    addi x9, x0, 5               # slots left

xfer_loop:
    lw   x6, 0(x8)               # this slot's length in bytes

    # descriptor at 0x2000: src, dst, len, ctrl
    addi x28, x14, 0x100
    sw   x28, 0(x14)             # src  = 0x2100
    sw   x5,  4(x14)             # dst  = this slot
    sw   x6,  8(x14)             # len
    addi x28, x0, 1
    sw   x28, 12(x14)            # ctrl bit0 = last segment

    sw   x14, 0x00(x29)          # CH0_DESC_ADDR = 0x2000
    addi x28, x0, 1
    sw   x28, 0x04(x29)          # CH0_CONTROL.enable = 1, transfer starts

    # poll CH0_STATUS until STATE_DONE (4)
    addi x30, x0, 4
poll_done:
    lw   x28, 0x0C(x29)
    andi x28, x28, 7
    bne  x28, x30, poll_done

    sw   x0,  0x04(x29)          # enable = 0, channel back to IDLE
    addi x28, x0, 0xF
    sw   x28, 0x40(x29)          # write-1-to-clear INT_STATUS

    addi x5, x5, 128             # next slot
    addi x8, x8, 4               # next length
    addi x9, x9, -1
    bne  x9, x0, xfer_loop

    # ---- done marker last ------------------------------------------------
    lui  x30, 0xD05ED
    addi x30, x30, 0x01E
    sw   x30, 0x400(x14)

halt:
    beq  x0, x0, halt
