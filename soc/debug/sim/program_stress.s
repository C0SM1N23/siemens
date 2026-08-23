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
# worse than no test, because it reads like proof. This one keeps the CPU busy
# on both DMEM and the SRAM for the whole transfer, so all three happen.
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
#   0x000  descriptor: src, dst, len, ctrl
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
#                     x31 DMA-done flag, x27 collision irq count,
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

    # ---- descriptor: 512 bytes, DMEM -> SRAM -----------------------------
    addi x6, x14, 0x100
    sw   x6, 0(x14)              # desc[0] = src
    addi x5, x25, 0x20
    sw   x5, 4(x14)              # desc[1] = dst
    addi x6, x0, 512
    sw   x6, 8(x14)              # desc[2] = length, sixteen 32-byte chunks
    addi x6, x0, 1
    sw   x6, 12(x14)             # desc[3] = ctrl, last segment

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

    # ---- start the DMA ---------------------------------------------------
    sw   x0, 0x48(x29)           # SCHED_POLICY = fixed
    lui  x6, 0x07D00
    addi x6, x6, 0xC8
    sw   x6, 0x08(x29)           # CH0_BW_CAP
    addi x6, x0, 0xF
    sw   x6, 0x44(x29)           # DMA INT_ENABLE
    sw   x14, 0x00(x29)          # CH0_DESC_ADDR
    addi x6, x0, 1
    sw   x6, 0x04(x29)           # CH0_CONTROL.enable = 1

    # ---- stress loop: wait one burst AHEAD of the DMA ---------------------
    # Getting the two to touch the same word in the same cycle took three
    # attempts, and the failures are worth recording:
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
    # So the CPU jumps a whole 32-byte burst PAST the word it just saw arrive
    # and parks there, polling in a two-instruction loop. It is then sitting on
    # the first word of the DMA's next write burst, hammering that exact
    # address, when the DMA gets there. The transfer is sixteen bursts long,
    # so there are sixteen such meetings rather than a single lucky one.
    addi x5, x25, 0x20           # the word we are waiting on
    addi x11, x0, 0              # DMEM scratch pattern
track_loop:
poll_word:
    lw   x13, 0(x5)              # zero until the DMA writes this word
    beq  x13, x0, poll_word      # tight on purpose: keeps port A busy here

    # one DMEM round trip per burst boundary, to contend for the shared memory
    addi x11, x11, 1
    sw   x11, 0x340(x14)
    lw   x12, 0x340(x14)
    beq  x12, x11, dmem_ok
    addi x26, x26, 1             # a corrupted round trip counts as a fault
dmem_ok:
    addi x5, x5, 32              # one whole burst ahead of the DMA
    addi x6, x25, 0x220          # wrap at the end of the 128-word window
    blt  x5, x6, in_range
    addi x5, x25, 0x20
in_range:
    beq  x31, x0, track_loop
tracking_done:

    # ---- the transfer must be intact despite everything above ------------
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
