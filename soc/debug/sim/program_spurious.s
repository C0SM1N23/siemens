# A spurious claim with the real CPU, then a normal interrupt behind it.
#
# PIC sources 5 and 6 are unused in the SoC; soc_tb_pic_spurious drives them.
# Source 5 is withdrawn in the cycle the CPU's claim reaches the PIC, so the
# claim is spurious: the handler still runs for source 5, the PIC logs the event,
# and the handler's MRET closes the nesting level as for any other interrupt.
# Source 6 then raises and stays up until the PIC has taken the claim: a normal
# service, proving the controller came through the spurious one intact.
#
# PIC registers (base 0x3000_0000): SRC5_CONFIG 0x14, SRC6_CONFIG 0x18,
# NEST_STATUS 0xC4, SPURIOUS_LOG 0xD0 (W1C), INT_ENABLE 0xD8, INT_STATUS 0xDC.
#
# DMEM layout (x14 = 0x2000):
#   0x200  per interrupt: mcause, SPURIOUS_LOG, INT_STATUS, NEST_STATUS (4 words)
#   0x300  NEST_STATUS after both                    expect 0
#   0x304  SPURIOUS_LOG after both                   expect 0x20
#   0x308  SPURIOUS_LOG after writing it back (W1C)  expect 0
#   0x30C  interrupts taken                          expect 2
#   0x310  done marker                               0x5B0B_5B0B
#   0x3F0  ready flag for the bench                  1
#
# Reserved registers: x14 DMEM base, x15 PIC base, x20 record pointer, x21 count.

_start:
    lui  x14, 2
    lui  x15, 0x30000
    addi x20, x14, 0x200
    addi x21, x0, 0
    lui  x5, %hi(handler)
    addi x5, x5, %lo(handler)
    csrrw x0, mtvec, x5

    addi x6, x0, 0x10            # level-triggered, intra priority 1, band 0
    sw   x6, 0x14(x15)           # SRC5_CONFIG
    sw   x6, 0x18(x15)           # SRC6_CONFIG
    addi x6, x0, 0x60
    sw   x6, 0xD8(x15)           # INT_ENABLE: sources 5 and 6
    lui  x6, 0x600
    csrrs x0, mie, x6            # mie[21] and mie[22]
    csrrsi x0, mstatus, 8        # mstatus.MIE

    addi x6, x0, 1
    sw   x6, 0x3F0(x14)          # ready: the bench may raise the sources
    addi x7, x0, 2
wait:
    blt  x21, x7, wait

    lw   x5, 0xC4(x15)
    sw   x5, 0x300(x14)
    lw   x5, 0xD0(x15)
    sw   x5, 0x304(x14)
    sw   x5, 0xD0(x15)           # write-1-to-clear
    lw   x5, 0xD0(x15)
    sw   x5, 0x308(x14)
    sw   x21, 0x30C(x14)
    lui  x30, 0x5B0B6
    addi x30, x30, -0x4F5        # 0x5B0B5B0B
    sw   x30, 0x310(x14)
halt:
    beq  x0, x0, halt

.org 0x200
handler:
    csrrs x30, mcause, x0
    sw   x30, 0(x20)
    lw   x5, 0xD0(x15)           # SPURIOUS_LOG
    sw   x5, 4(x20)
    lw   x5, 0xDC(x15)           # INT_STATUS
    sw   x5, 8(x20)
    lw   x5, 0xC4(x15)           # NEST_STATUS while in service
    sw   x5, 12(x20)
    addi x20, x20, 16
    addi x21, x21, 1
    mret
