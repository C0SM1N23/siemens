# SoC system test: the CPU sets up a DMA transfer into the dual-port SRAM,
# sleeps, is woken by the DMA's interrupt through the PIC, and verifies what
# the DMA moved. Run by tb_soc_top.
#
# This is the end-to-end path the whole integration exists for. Everything the
# fabric does is on it: the CPU data bus decoder (four different slaves), the
# DMEM arbiter (CPU and DMA both reach data memory), the burst bridge (the
# DMA's 8-beat AXI4-Full bursts become AXI4-Lite beats), the dual-port SRAM
# used from both sides, and the DMA -> PIC -> CPU interrupt chain.
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
#   0x200  mismatched words after the transfer   expect 0
#   0x204  CH0_STATUS inside the handler        expect 4 (STATE_DONE)
#   0x208  DMA INT_STATUS seen in the handler    expect 1 (channel 0)
#   0x20C  PIC ACTIVE_VEC in the handler         expect 0x100 (valid, src 0)
#   0x210  interrupts taken                      expect 1
#   0x214  first word read back from the SRAM    expect 0xC0DE0000
#   0x218  last  word read back from the SRAM    expect 0xC0DE000F
#   0x21C  done marker                           0xD05ED01E
#   0x220  CH0_STATUS after the handler cleared  expect 0 (STATE_IDLE)
#
# Reserved registers: x14 DMEM base, x29 DMA base, x31 interrupt count,
#                     x28/x30 handler scratch.

_start:
    lui  x14, 2                  # x14 = 0x2000, DMEM base

    # ---- fill 16 source words with a recognisable pattern ----------------
    addi x5, x14, 0x100          # x5 = source pointer
    lui  x6, 0xC0DE0             # x6 = 0xC0DE0000
    addi x7, x0, 16
fill_loop:
    sw   x6, 0(x5)
    addi x6, x6, 1
    addi x5, x5, 4
    addi x7, x7, -1
    bne  x7, x0, fill_loop

    # ---- build the descriptor at 0x2000 ----------------------------------
    # src = DMEM 0x2100, dst = SRAM data region, 64 bytes, last segment.
    # 64 bytes is two of the DMA's 32-byte chunks, so the channel has to loop
    # rather than finish on its first pass.
    addi x6, x14, 0x100
    sw   x6, 0(x14)              # desc[0] = src
    lui  x5, 0x10000
    addi x5, x5, 0x20            # SRAM data starts after its 8 registers
    sw   x5, 4(x14)              # desc[1] = dst
    addi x6, x0, 64
    sw   x6, 8(x14)              # desc[2] = length in bytes
    addi x6, x0, 1
    sw   x6, 12(x14)             # desc[3] = ctrl, bit0 = last segment

    # ---- arm the interrupt path: PIC source 0, mie bit 16, mstatus.MIE ---
    lui  x28, 0x30000            # PIC
    addi x30, x0, 1
    sw   x30, 0xD8(x28)          # PIC INT_ENABLE = source 0 (DMA channel 0)

    addi x28, x0, irq_handler
    csrrw x0, mtvec, x28         # direct mode
    lui  x28, 0x10               # mie[16] = PIC channel 0
    csrrw x0, mie, x28
    addi x31, x0, 0
    addi x28, x0, 8
    csrrs x0, mstatus, x28       # mstatus.MIE = 1

    # ---- program the DMA -------------------------------------------------
    lui  x29, 0x30020            # x29 = DMA base, kept live for the checks
    sw   x0, 0x48(x29)           # SCHED_POLICY = 0 (fixed priority)
    lui  x6, 0x07D00
    addi x6, x6, 0xC8            # max_tokens = 2000, refill = 200 per window
    sw   x6, 0x08(x29)           # CH0_BW_CAP
    addi x6, x0, 0xF
    sw   x6, 0x44(x29)           # DMA INT_ENABLE = all four channels
    sw   x14, 0x00(x29)          # CH0_DESC_ADDR = 0x2000
    addi x6, x0, 1
    sw   x6, 0x04(x29)           # CH0_CONTROL.enable = 1 -> the transfer starts

    # ---- sleep until the DMA is done -------------------------------------
    # WFI, not a spin loop: the CPU is genuinely idle while the DMA works, and
    # this exercises the wake path as well as the interrupt path.
    wfi
wait_irq:
    beq  x31, x0, wait_irq

    # ---- verify what the DMA moved ---------------------------------------
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
    sw   x8, 0x200(x14)          # [0x200] = mismatches

    lw   x30, 0x0C(x29)          # CH0_STATUS: back to IDLE now the handler
    sw   x30, 0x220(x14)         # cleared CONTROL.enable
    sw   x31, 0x210(x14)         # interrupts taken

    lui  x5, 0x10000
    addi x5, x5, 0x20
    lw   x30, 0(x5)
    sw   x30, 0x214(x14)         # first word straight out of the SRAM
    lw   x30, 60(x5)
    sw   x30, 0x218(x14)         # last word

    # done marker last, so the bench never samples a half-filled scoreboard
    lui  x30, 0xD05ED
    addi x30, x30, 0x01E
    sw   x30, 0x21C(x14)

halt:
    beq  x0, x0, halt

# ---------------------------------------------------------------------------
# interrupt handler
# ---------------------------------------------------------------------------
# Clearing order matters. The channel's line is a level that stays asserted
# while the channel sits in STATE_DONE, so the enable has to go first: it lets
# the channel fall back to IDLE and drop hw_irq. Only then does writing 1 to
# INT_STATUS actually release the request - do it the other way round and the
# status bit is set again on the next cycle and the handler is re-entered.
irq_handler:
    lui  x28, 0x30020            # DMA
    lw   x30, 0x40(x28)          # INT_STATUS: which channel asked
    sw   x30, 0x208(x14)
    lw   x30, 0x0C(x28)          # CH0_STATUS while still in service
    sw   x30, 0x204(x14)
    sw   x0,  0x04(x28)          # CH0_CONTROL = 0 -> channel back to IDLE
    addi x30, x0, 0xF
    sw   x30, 0x40(x28)          # write-1-to-clear INT_STATUS
    lui  x28, 0x30000            # PIC
    lw   x30, 0xCC(x28)          # ACTIVE_VEC: the source being serviced
    sw   x30, 0x20C(x14)
    addi x31, x31, 1
    mret
