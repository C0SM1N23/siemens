# Interrupt preemption and nesting driven through the real CPU.
#
# The controller's own bench proves preemption by driving the claim and
# end-of-interrupt pulses itself, at times it chooses. That leaves the question
# this program answers: does it still work when the pulses come from a real
# core, at instruction boundaries, with the core's own global enable in the
# loop and a real handler running in between.
#
# Two software-triggered sources are used rather than peripheral lines. Slots 8
# and 9 have no hardware line in this system - they are tied low - so their
# software channels are the only requester, which makes the sequence exact and
# keeps it independent of what the DMA or the timer happen to be doing.
#
# The outer handler is entered for the less urgent source, re-enables the core's
# global interrupt enable, raises the more urgent one, and spins. If preemption
# works the inner handler runs inside that spin, at depth two, and returns to
# it. If it does not, the spin simply ends and the depth never reaches two.
#
# SoC map: IMEM 0x0000_0000, DMEM 0x0000_2000, DP-SRAM 0x1000_0000,
#          PIC 0x3000_0000, mtimer 0x3001_0000, DMA 0x3002_0000
#
# Scoreboard (byte offset off x14 = 0x2000):
#   0x200  handler entries in total                      expect 2
#   0x204  ACTIVE_VEC inside the outer handler           expect 0x109
#   0x208  nesting depth inside the outer handler        expect 1
#   0x20C  ACTIVE_VEC inside the inner handler           expect 0x108
#   0x210  nesting depth inside the inner handler        expect 2
#   0x214  nesting depth after the inner one returned    expect 1
#   0x218  nesting depth after both returned             expect 0
#   0x21C  entries for the less urgent source            expect 1
#   0x220  entries for the more urgent source            expect 1
#   0x224  done marker                                   0xD05ED01E
#
# Reserved registers: x14 DMEM base, x25 PIC base, x31 total entries,
#                     x24 entries for slot 9, x23 entries for slot 8,
#                     x27 the outer handler's spin counter, x22/x21 its saved
#                     mepc and mstatus (the inner path writes none of the
#                     three, so they survive being preempted),
#                     x28/x30 scratch, shared by both handler paths.

_start:
    lui  x14, 2                  # x14 = 0x2000, DMEM base
    lui  x25, 0x30000            # x25 = PIC base, kept live for the handler

    # ---- two sources, two bands ------------------------------------------
    # Slot 8 in band 0, slot 9 in band 2. Under the reset band ordering band 0
    # is the most urgent and band 2 is not, so 8 outranks 9.
    sw   x0, 0x20(x25)           # SRC8_CONFIG  = band 0, level, no deadline
    addi x30, x0, 4
    sw   x30, 0x24(x25)          # SRC9_CONFIG  = band 2, level, no deadline
    addi x30, x0, 0x300          # slots 8 and 9
    sw   x30, 0xD8(x25)          # PIC INT_ENABLE

    # ---- the core takes both ---------------------------------------------
    addi x28, x0, irq_handler
    csrrw x0, mtvec, x28         # direct mode
    lui  x28, 0x3000             # mie[25:24] = controller sources 9 and 8
    csrrw x0, mie, x28
    addi x31, x0, 0
    addi x24, x0, 0
    addi x23, x0, 0
    addi x28, x0, 8
    csrrs x0, mstatus, x28       # mstatus.MIE = 1

    # ---- raise the LESS urgent source first ------------------------------
    lui  x6, 0xA5A50
    addi x6, x6, 1               # keyed software trigger, request bit set
    sw   x6, 0x64(x25)           # SRC9_SW_TRIG

wait_both:
    addi x30, x0, 2
    bne  x31, x30, wait_both

    # ---- what is left behind ---------------------------------------------
    sw   x31, 0x200(x14)
    lw   x30, 0xC4(x25)          # NEST_STATUS
    andi x30, x30, 0x1F
    sw   x30, 0x218(x14)         # depth after both returned
    sw   x24, 0x21C(x14)
    sw   x23, 0x220(x14)

    lui  x30, 0xD05ED
    addi x30, x30, 0x01E
    sw   x30, 0x224(x14)

halt:
    beq  x0, x0, halt

# ---------------------------------------------------------------------------
# interrupt handler, entered for both sources
# ---------------------------------------------------------------------------
# One handler, dispatching on the source the controller says it is serving.
# The two paths must not share a live register across the preemption: the outer
# path keeps its spin counter in x27, which the inner path never writes.
irq_handler:
    lw   x30, 0xCC(x25)          # ACTIVE_VEC
    andi x28, x30, 0xF
    addi x31, x31, 1

    addi x29, x0, 8
    beq  x28, x29, inner

# ---- outer: the less urgent source ----------------------------------------
outer:
    # Before anything can preempt this handler, save the two pieces of state a
    # second trap would overwrite. mepc and mstatus are single registers: the
    # inner trap writes both, so without this the outer handler's mret would
    # return to wherever the inner one was interrupted instead of to the
    # program.
    csrrs x22, mepc, x0
    csrrs x21, mstatus, x0

    sw   x30, 0x204(x14)         # ACTIVE_VEC as the outer handler sees it
    lw   x30, 0xC4(x25)
    andi x30, x30, 0x1F
    sw   x30, 0x208(x14)         # depth: one level open
    addi x24, x24, 1

    # raise the more urgent source, then open the door for it
    lui  x28, 0xA5A50
    addi x28, x28, 1
    sw   x28, 0x60(x25)          # SRC8_SW_TRIG
    addi x28, x0, 8
    csrrs x0, mstatus, x28       # mstatus.MIE = 1 -> nesting allowed

    # spin long enough for the preemption to land inside this handler
    addi x27, x0, 40
outer_spin:
    addi x27, x27, -1
    bne  x27, x0, outer_spin

    lw   x30, 0xC4(x25)
    andi x30, x30, 0x1F
    sw   x30, 0x214(x14)         # depth after the inner handler returned

    csrrw x0, mepc, x22          # put back what the inner trap overwrote
    csrrw x0, mstatus, x21
    mret

# ---- inner: the more urgent source, running inside the outer one -----------
inner:
    sw   x30, 0x20C(x14)         # ACTIVE_VEC as the inner handler sees it
    lw   x30, 0xC4(x25)
    andi x30, x30, 0x1F
    sw   x30, 0x210(x14)         # depth: two levels open
    addi x23, x23, 1
    mret
