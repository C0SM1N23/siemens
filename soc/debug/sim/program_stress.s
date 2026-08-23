# SoC stress test: the CPU works the bus *while* the DMA is transferring.
# Run by tb_soc_stress.
#
# WHY THIS EXISTS, SEPARATELY FROM program_soc.s
# The first system test has the CPU sleep on WFI while the DMA runs. It proves
# the data path, but a coverage probe on that run showed three things were
# never actually exercised:
#
#   - the DMEM arbiter was never contended: zero cycles with both masters
#     requesting, so round-robin and master parking were dead logic
#   - the dual-port SRAM never had both ports active in the same cycle, so its
#     collision detector never fired and the SRAM -> PIC interrupt was wired
#     but unproven
#   - no unmapped access was ever made, so the decoder's DECERR path was
#     untested at system level
#
# A test that passes without touching the logic it is supposed to cover is
# worse than no test, because it reads like proof.
#
# TWO PHASES, BECAUSE THE TWO TARGETS PULL IN OPPOSITE DIRECTIONS
# Forcing an SRAM address collision needs the CPU parked on the SRAM, polling
# in the tightest loop possible. Contending the DMEM arbiter needs the CPU
# hammering DMEM instead. Doing both in one loop halves each and covers neither
# convincingly - that attempt reached 25 contended cycles. So the run is split,
# and the DMA does one transfer per phase:
#
#   phase A  descriptor A, CPU parked on the SRAM one burst ahead of the DMA
#   phase B  descriptor B, CPU in a tight DMEM read/write loop
#
# The two destinations are contiguous, so the check at the end is still one
# 128-word comparison.
#
# WHAT MUST STILL HOLD UNDER CONTENTION
# The DMA's 256-byte transfer must be bit-perfect at the end regardless of how
# much the CPU interferes. That is the real assertion here: contention may cost
# the CPU (its colliding reads get SLVERR and trap), but it must never corrupt
# what the DMA moved. The SRAM resolves a read-vs-write collision in favour of
# the writer, so the DMA always wins and the CPU always takes the fault - which
# is exactly why the transfer staying clean is a meaningful check.
#
# SoC map: IMEM 0x0000_0000, DMEM 0x0000_2000, DP-SRAM 0x1000_0000,
#          PIC 0x3000_0000, mtimer 0x3001_0000, DMA 0x3002_0000
#
# DMEM layout (x14 = 0x2000):
#   0x000  descriptor A: src, dst, len, ctrl
#   0x010  descriptor B: src, dst, len, ctrl
#   0x100  64 source words
#   0x340  scratch word the CPU hammers, to contend for the DMEM arbiter
#   0x400  scoreboard
#
# Scoreboard (byte offset off x14):
#   0x400  mismatched words after the transfer   expect 0
#   0x404  SRAM collision interrupts taken       expect > 0
#   0x408  synchronous faults during the stress  informational
#   0x40C  CH0_STATUS inside the DMA handler     expect 4 (STATE_DONE)
#   0x410  fault count before the unmapped access
#   0x414  fault count after  the unmapped access   expect [0x410] + 1
#   0x418  SRAM INT_STATUS as left by the handler   informational
#   0x420  mcause of that last fault              expect 5 (load access fault)
#   0x41C  done marker                           0x5772_E55D
#
# Reserved registers: x14 DMEM base, x25 SRAM base, x29 DMA base,
#                     x31 completed transfers, x27 collision irq count,
#                     x26 synchronous fault count, x28/x30 handler scratch.

_start:
    lui  x14, 2                  # x14 = 0x2000, DMEM base
    lui  x25, 0x10000            # x25 = 0x1000_0000, SRAM base
    lui  x29, 0x30020            # x29 = 0x3002_0000, DMA base
    addi x31, x0, 0
    addi x27, x0, 0
    addi x26, x0, 0

    # ---- fill 128 source words -------------------------------------------
    addi x5, x14, 0x100
    lui  x6, 0x5A5A0
    addi x7, x0, 128
fill_loop:
    sw   x6, 0(x5)
    addi x6, x6, 1
    addi x5, x5, 4
    addi x7, x7, -1
    bne  x7, x0, fill_loop

    # ---- zero the SRAM data region ---------------------------------------
    # The SRAM array holds X out of reset. The CPU is about to read this region
    # concurrently with the DMA writing it, and an X pulled into a register is
    # a fault that surfaces somewhere else entirely. Zero it first.
    addi x5, x25, 0x20
    addi x7, x0, 128
zero_loop:
    sw   x0, 0(x5)
    addi x5, x5, 4
    addi x7, x7, -1
    bne  x7, x0, zero_loop

    # ---- descriptor A: first 256 bytes, DMEM -> SRAM ---------------------
    addi x6, x14, 0x100
    sw   x6, 0(x14)              # desc[0] = src
    addi x5, x25, 0x20
    sw   x5, 4(x14)              # desc[1] = dst
    addi x6, x0, 256
    sw   x6, 8(x14)              # desc[2] = length, eight 32-byte chunks
    addi x6, x0, 1
    sw   x6, 12(x14)             # desc[3] = ctrl, last segment

    # ---- descriptor B: the next 256 bytes, straight after it -------------
    addi x6, x14, 0x200
    sw   x6, 16(x14)
    addi x5, x25, 0x120
    sw   x5, 20(x14)
    addi x6, x0, 256
    sw   x6, 24(x14)
    addi x6, x0, 1
    sw   x6, 28(x14)

    # ---- arm the SRAM's own interrupt ------------------------------------
    # SRAM register words: 0 = INT_STATUS, 1 = INT_ENABLE.
    # Enable collision (bit 0) and cooldown (bit 1) so a real conflict reaches
    # the PIC on source 4.
    addi x30, x0, 3
    sw   x30, 4(x25)             # SRAM INT_ENABLE = collision | cooldown

    # ---- arm the PIC: source 0 (DMA ch0) and source 4 (SRAM) -------------
    lui  x28, 0x30000
    addi x30, x0, 0x11
    sw   x30, 0xD8(x28)          # PIC INT_ENABLE = src0 | src4

    addi x28, x0, trap_handler
    csrrw x0, mtvec, x28         # direct mode: every trap goes here
    lui  x28, 0x110              # mie[16] = PIC ch0, mie[20] = PIC ch4
    csrrw x0, mie, x28
    addi x28, x0, 8
    csrrs x0, mstatus, x28       # mstatus.MIE = 1

    # ---- one-time DMA configuration --------------------------------------
    sw   x0, 0x48(x29)           # SCHED_POLICY = fixed
    lui  x6, 0x07D00
    addi x6, x6, 0xC8            # max_tokens = 2000, refill = 200 per window
    sw   x6, 0x08(x29)           # CH0_BW_CAP
    addi x6, x0, 0xF
    sw   x6, 0x44(x29)           # DMA INT_ENABLE = all four channels

    # =====================================================================
    # PHASE A: hunt SRAM collisions
    # =====================================================================
    # Getting the CPU and the DMA onto the same word in the same cycle took
    # three attempts, and the failures are the instructive part:
    #
    #   sweep the region independently   -> 3 cycles with both ports busy
    #   sweep it densely, 8 loads a pass -> 32 cycles, still no shared address
    #   follow the DMA word by word      -> the CPU trails it, so every word is
    #                                       already written when it arrives and
    #                                       it never waits anywhere
    #
    # The measurement that explained it: port A was busy 162 cycles out of 2781
    # and port B exactly 64 - one per word written - and the two were
    # independent. Chasing a moving pointer cannot correlate them.
    #
    # Jumping a whole 32-byte burst PAST the word that just arrived puts the
    # CPU on the exact address the DMA's next write burst starts at. That alone
    # was still not enough: polling a single address gave port A a one-cycle
    # access every four, and a trace showed the DMA's write landing at cycle
    # 2518 with the CPU's accesses at 2515 and 2519 - missing by one cycle, and
    # missing by the same one cycle on every burst, because both loops are
    # periodic. A fixed phase offset never resolves itself.
    #
    # So the CPU sweeps all eight words of that burst instead of one. The DMA
    # writes those same eight words two cycles apart, the CPU walks them at a
    # different rate, and the two phases differ per word.
    #
    # That still was not enough, and the reason is worth writing down. A full
    # cycle-by-cycle trace of the two ports showed them alternating perfectly:
    #
    #     2517 A=054          2518 B=040
    #     2519 A=058          2520 B=044
    #     2521 A=05c          2522 B=048
    #
    # Every CPU access on an odd cycle, every DMA write on an even one. The
    # CPU's loads inside the sweep are two cycles apart - an even step - so
    # they all keep whatever parity the sweep started on, and the DMA's writes
    # are also two cycles apart. The one-cycle offset between the two was an
    # invariant of the schedule: they could not meet however long the run went,
    # and no amount of extra bursts would have changed it.
    #
    # Padding the sweep with NOPs does not fix it: a NOP costs two cycles here,
    # so the step went from two to four and stayed even. The schedule has to be
    # made irregular, not merely longer.
    #
    # The DMEM loads sprinkled through the sweep do that. DMEM sits behind the
    # arbiter, so its latency depends on whether the DMA happens to hold the
    # grant at that moment - which is exactly the kind of variability no fixed
    # instruction sequence can produce. The CPU's SRAM accesses stop landing on
    # a fixed grid, and the two ports can finally coincide. It also contends
    # the arbiter during phase A, which is free coverage.
    sw   x14, 0x00(x29)          # CH0_DESC_ADDR = descriptor A
    addi x6, x0, 1
    sw   x6, 0x04(x29)           # CH0_CONTROL.enable = 1

    addi x5, x25, 0x20           # base of the burst we are waiting on
phase_a_loop:
poll_burst:
    lw   x13,  0(x5)             # word 0 is written first, so it is the flag
    bne  x13, x0, burst_arrived
    lw   x13,  4(x5)
    lw   x12, 0x340(x14)         # the jitter source - see the note above
    lw   x13,  8(x5)
    lw   x13, 12(x5)
    lw   x12, 0x340(x14)
    lw   x13, 16(x5)
    lw   x13, 20(x5)
    lw   x12, 0x340(x14)
    lw   x13, 24(x5)
    lw   x13, 28(x5)
    beq  x0, x0, poll_burst
burst_arrived:
    addi x5, x5, 32              # one whole burst ahead of the DMA
    addi x6, x25, 0x120          # wrap at the end of phase A's window
    blt  x5, x6, phase_a_range
    addi x5, x25, 0x20
phase_a_range:
    beq  x31, x0, phase_a_loop

    # =====================================================================
    # PHASE B: contend the DMEM arbiter
    # =====================================================================
    # Both masters now want the same single-ported memory: the DMA reads its
    # descriptor and its source data out of DMEM while the CPU does nothing but
    # write and read DMEM back. Every pass checks the round trip, so a grant
    # handed to two masters at once would show up as corrupted data and not
    # only as a coverage number.
    addi x6, x14, 0x10
    sw   x6, 0x00(x29)           # CH0_DESC_ADDR = descriptor B
    addi x6, x0, 1
    sw   x6, 0x04(x29)           # re-arm channel 0
    addi x9, x0, 2               # phase B ends at the second completion
    addi x11, x0, 0
phase_b_loop:
    addi x11, x11, 1
    sw   x11, 0x340(x14)
    lw   x12, 0x340(x14)
    beq  x12, x11, phase_b_ok
    addi x26, x26, 1             # a corrupted round trip counts as a fault
phase_b_ok:
    blt  x31, x9, phase_b_loop

    # ---- both transfers must be intact despite everything above ----------
    addi x5, x25, 0x20
    addi x6, x14, 0x100
    addi x7, x0, 128
    addi x8, x0, 0
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
    sw   x8, 0x400(x14)          # mismatches after the whole stress run

    sw   x27, 0x404(x14)         # SRAM collision interrupts taken
    sw   x26, 0x408(x14)         # synchronous faults during the stress
    sw   x31, 0x424(x14)         # DMA transfers completed
    lw   x30, 0(x25)
    sw   x30, 0x418(x14)         # SRAM INT_STATUS as left by the handler

    # ---- deliberate unmapped access: the decoder must answer DECERR ------
    # Nothing is mapped at 0x5000_0000. The access must fault rather than hang,
    # which is the whole point of having a decode-error responder.
    sw   x26, 0x410(x14)         # fault count before
    lui  x28, 0x50000
    lw   x30, 0(x28)             # -> DECERR -> load access fault, cause 5
    sw   x26, 0x414(x14)         # fault count after: must be one higher
    csrrs x30, mcause, x0
    sw   x30, 0x420(x14)         # last mcause, expect 5 (load access fault)

    lui  x30, 0x5772E
    addi x30, x30, 0x55D
    sw   x30, 0x41C(x14)         # done marker, written last

halt:
    beq  x0, x0, halt

# ---------------------------------------------------------------------------
# one handler for everything: mtvec is in direct mode
# ---------------------------------------------------------------------------
trap_handler:
    csrrs x30, mcause, x0
    blt  x30, x0, is_interrupt   # mcause[31] set reads as negative

    # synchronous exception: count it and step over the offending instruction
    addi x26, x26, 1
    csrrs x30, mepc, x0
    addi x30, x30, 4
    csrrw x0, mepc, x30
    mret

is_interrupt:
    andi x30, x30, 0x1F          # interrupt causes are 16 + PIC source
    addi x28, x0, 16
    beq  x30, x28, irq_dma

    # PIC source 4: the SRAM saw a real collision. Clear its sticky status so
    # the line drops; the DMA's write won the conflict, ours was the read that
    # got SLVERR.
    addi x27, x27, 1
    addi x30, x0, 3
    sw   x30, 0(x25)             # SRAM INT_STATUS write-1-to-clear
    mret

irq_dma:
    lw   x30, 0x0C(x29)          # CH0_STATUS while still in service
    sw   x30, 0x40C(x14)
    sw   x0,  0x04(x29)          # CH0_CONTROL = 0 -> channel back to IDLE
    addi x30, x0, 0xF
    sw   x30, 0x40(x29)          # DMA INT_STATUS write-1-to-clear
    addi x31, x31, 1
    mret
