# Every one of the sixteen sources reaches the CPU.
#
# Eight of the controller's slots have a hardware line in this system: the DMA
# on 0 to 3, the dual-port SRAM on 4, the machine timer on 7. Slots 5, 6 and 8
# to 15 are tied low, so no system run has ever produced a request on them and
# nothing says the resolver, the vector output or the core's enable mask handle
# the upper half of the range at all. A one-bit-too-narrow index would be
# invisible from every existing test.
#
# The software trigger channels reach all sixteen regardless of what is wired to
# them, so this program walks the whole range: it raises one slot at a time and
# records the source number the controller reported to the handler. The peers
# stay quiet - nothing is armed on the DMA, the timer's compare register is at
# its disarmed reset value and the memory sees no collisions - so the software
# channel is the only requester in every step.
#
# One at a time is the point. Raising them together would test priority, which
# is the controller bench's job; raising them separately tests that each slot
# individually can be requested, offered, claimed and released.
#
# SoC map: IMEM 0x0000_0000, DMEM 0x0000_2000, DP-SRAM 0x1000_0000,
#          PIC 0x3000_0000, mtimer 0x3001_0000, DMA 0x3002_0000
#
# Scoreboard (byte offset off x14 = 0x2000):
#   0x200 .. 0x23C  ACTIVE_VEC recorded by the handler, one word per slot,
#                   in the order the slots were raised: expect 0x100 | index
#   0x240  handler entries in total    expect 16
#   0x244  nesting depth at the end    expect 0
#   0x248  done marker                 0xD05ED01E
#
# Reserved registers: x14 DMEM base, x25 PIC base, x31 handler entries,
#                     x21 scoreboard write pointer (the handler advances it),
#                     x20 slot index, x30 handler scratch.

_start:
    lui  x14, 2                  # x14 = 0x2000, DMEM base
    lui  x25, 0x30000            # x25 = PIC base

    # ---- every slot enabled, all at the same priority ---------------------
    # Left at their reset configuration: band 0, intra 0, level-triggered. The
    # only thing that separates them is the slot number, which is what makes a
    # wrong vector obvious.
    lui  x30, 0x10
    addi x30, x30, -1            # 0x0000FFFF
    sw   x30, 0xD8(x25)          # PIC INT_ENABLE = all sixteen

    addi x28, x0, irq_handler
    csrrw x0, mtvec, x28         # direct mode
    lui  x28, 0xFFFF0            # mie[31:16] = all sixteen sources
    csrrw x0, mie, x28
    addi x31, x0, 0
    addi x28, x0, 8
    csrrs x0, mstatus, x28       # mstatus.MIE = 1

    # ---- raise one slot at a time, lowest first ---------------------------
    addi x20, x0, 0              # slot index
    addi x21, x14, 0x200         # scoreboard write pointer
slot_loop:
    slli x22, x20, 2             # byte offset of this slot's trigger register
    add  x22, x22, x25
    lui  x6, 0xA5A50
    addi x6, x6, 1               # keyed trigger, request bit set
    sw   x6, 0x40(x22)           # SRCx_SW_TRIG

    addi x23, x20, 1             # wait for this slot's handler to finish
wait_slot:
    bne  x31, x23, wait_slot

    addi x20, x20, 1
    addi x24, x0, 16
    bne  x20, x24, slot_loop

    # ---- what is left behind ---------------------------------------------
    sw   x31, 0x240(x14)
    lw   x30, 0xC4(x25)          # NEST_STATUS
    andi x30, x30, 0x1F
    sw   x30, 0x244(x14)         # every level was released

    lui  x30, 0xD05ED
    addi x30, x30, 0x01E
    sw   x30, 0x248(x14)

halt:
    beq  x0, x0, halt

# ---------------------------------------------------------------------------
# interrupt handler
# ---------------------------------------------------------------------------
# Nothing to acknowledge at the peripheral: a software-triggered request is
# consumed by the claim itself, so returning is all that is needed.
irq_handler:
    lw   x30, 0xCC(x25)          # ACTIVE_VEC: valid bit and source number
    sw   x30, 0(x21)
    addi x21, x21, 4
    addi x31, x31, 1
    mret
