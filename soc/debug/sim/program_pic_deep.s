# Sixteen nested interrupts through the real CPU: the documented maximum.
#
# Source s is configured with intra-band priority s, so each one outranks every
# source below it. NEST_MAX is raised to its ceiling of 16. The main program
# triggers source 0 in software; every handler saves its context on a software
# stack, triggers the next source, re-enables interrupts and is preempted at
# once, so the controller's stack and the core's trap-kind stack both fill to
# sixteen levels. Unwinding, every MRET must return to the handler it
# interrupted and send exactly one EOI, in reverse order.
#
# PIC (base 0x3000_0000): SRCx_CONFIG 0x00 + 4x, SRCx_SW_TRIG 0x40 + 4x,
# NEST_STATUS 0xC4, NEST_MAX 0xC8, INT_ENABLE 0xD8.
#
# DMEM layout (x14 = 0x2000):
#   0x200  entry record n: {source, depth} at 0x200 + 8n      16 entries
#   0x300  exit record m: source at 0x300 + 4m                 16 exits
#   0x380  NEST_STATUS after everything returned      expect 0
#   0x384  entries                                    expect 16
#   0x388  exits                                      expect 16
#   0x38C  done marker                                0xDEE9_DEE9
#   0x400..0x4FF  software stack, growing down from 0x500
#
# Reserved registers: x14 DMEM base, x25 PIC base, x13 stack pointer,
#                     x31 entries, x29 exits. The handler saves what it reuses.

_start:
    lui  x14, 2
    lui  x25, 0x30000
    addi x13, x14, 0x500
    addi x31, x0, 0
    addi x29, x0, 0

    addi x5, x0, 0               # SRCs_CONFIG = s << 4: intra priority s, band 0, level
    addi x6, x25, 0
config:
    slli x7, x5, 4
    sw   x7, 0(x6)
    addi x6, x6, 4
    addi x5, x5, 1
    addi x7, x0, 16
    bne  x5, x7, config
    addi x6, x0, 16
    sw   x6, 0xC8(x25)           # NEST_MAX = 16
    lui  x6, 0x10
    addi x6, x6, -1
    sw   x6, 0xD8(x25)           # INT_ENABLE = all sixteen sources

    lui  x5, %hi(handler)
    addi x5, x5, %lo(handler)
    csrrw x0, mtvec, x5
    lui  x5, 0xFFFF0
    csrrw x0, mie, x5            # mie[31:16]: every controller source
    csrrsi x0, mstatus, 8

    lui  x6, 0xA5A50
    addi x6, x6, 1
    sw   x6, 0x40(x25)           # SRC0_SW_TRIG
wait:
    addi x6, x0, 16
    bne  x29, x6, wait

    lw   x6, 0xC4(x25)
    sw   x6, 0x380(x14)
    sw   x31, 0x384(x14)
    sw   x29, 0x388(x14)
    lui  x30, 0xDEE9E
    addi x30, x30, -0x117        # 0xDEE9DEE9
    sw   x30, 0x38C(x14)
halt:
    beq  x0, x0, halt

.org 0x200
handler:
    addi x13, x13, -16           # push mepc, mstatus and the source number
    sw   x5, 12(x13)
    csrrs x5, mepc, x0
    sw   x5, 0(x13)
    csrrs x5, mstatus, x0
    sw   x5, 4(x13)
    csrrs x5, mcause, x0
    andi x5, x5, 0xF             # source number
    sw   x5, 8(x13)

    slli x6, x31, 3              # entry record {source, depth}
    add  x6, x6, x14
    sw   x5, 0x200(x6)
    lw   x7, 0xC4(x25)
    andi x7, x7, 0x1F
    sw   x7, 0x204(x6)
    addi x31, x31, 1

    addi x6, x0, 15
    beq  x5, x6, unwind          # the innermost level raises nothing
    slli x6, x5, 2               # trigger source s + 1
    add  x6, x6, x25
    lui  x7, 0xA5A50
    addi x7, x7, 1
    sw   x7, 0x44(x6)
    csrrsi x0, mstatus, 8        # nested interrupts on: preempted here
    addi x0, x0, 0
    addi x0, x0, 0
    addi x0, x0, 0
    addi x0, x0, 0
    addi x0, x0, 0
    addi x0, x0, 0
    addi x0, x0, 0
    addi x0, x0, 0
    csrrci x0, mstatus, 8

unwind:
    lw   x5, 8(x13)              # exit record: this level's source
    slli x6, x29, 2
    add  x6, x6, x14
    sw   x5, 0x300(x6)
    addi x29, x29, 1
    lw   x5, 0(x13)
    csrrw x0, mepc, x5
    lw   x5, 4(x13)
    csrrw x0, mstatus, x5
    lw   x5, 12(x13)
    addi x13, x13, 16
    mret
