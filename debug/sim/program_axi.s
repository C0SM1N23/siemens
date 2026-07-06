# Test program for the pipelined RV32I CPU (run by tb_cpu_axi).
# TB map: imem @ 0x0000 (4KB), dmem @ 0x2000 (4KB), PIC registers @
# 0x3000_0000; anything else on the dbus answers DECERR (unmapped).
# TB preloads dmem[256] = 0xCAFE0001.
#
# Coverage on top of the basics (arith/forwarding, byte lanes, predictor
# loop, JAL/JALR):
#   - every sync trap cause: 0,1,2,3,4,5,6,7,11 (bitmask in x29, exact trap
#     count in dmem[192] — 15 entries: 13 CPU-side + 2 PIC SLVERR accesses)
#   - illegal ops must have no side effects (illegal store leaves mem alone)
#   - CSR negatives: unimplemented address, writes to RO mip/mhartid
#   - CSR immediate forms + mscratch round-trip + mhartid read
#   - PIC software interface: program IRQ_ENABLE over AXI, read back ENABLE/
#     RAW/PENDING, read IRQ_ACTIVE inside the irq handler; a read of an
#     unmapped PIC register and a write to a read-only one answer SLVERR ->
#     precise access faults (causes 5 and 7 again, from a real peripheral)
#   - irq masking: source 5 pending the whole run, enabled in the PIC but
#     never in mie -> never taken; ch2+ch3 raised together -> PIC priority
#     serves ch2 first; ch2 also taken DURING an AXI data stall (the
#     interrupt is held to the instruction boundary)
#   - vectored mtvec: irq -> BASE+4*cause, exception -> BASE
#   - BTB aliasing: three branches sharing an index, different tags
#   - CPI evidence: 32 dependent ALU ops in ~33 cycles (checked when imem
#     has no added latency)
#
# Reserved regs: x29 = sync trap bitmask, x31 = irq mcause,
#                x28/x30 = scratch (main / handlers).
# Scoreboard slots are dmem byte offsets 128..196 off x14 = 0x2000.

_start:
    addi x1, x0, 10          # x1 = 10
    addi x2, x1, 5           # x2 = 15  (forwards x1)
    add  x3, x1, x2          # x3 = 25  (forwards x2)
    sub  x4, x3, x1          # x4 = 15
    xori x5, x4, 255         # x5 = 240
    or   x6, x5, x1          # x6 = 250
    and  x7, x6, x2          # x7 = 10
    slli x8, x1, 4           # x8 = 160
    srli x9, x8, 2           # x9 = 40
    addi x10, x0, -100
    srai x10, x10, 2         # x10 = -25
    slt  x11, x10, x1        # x11 = 1
    sltu x12, x10, x1        # x12 = 0 (unsigned compare)
    lui  x13, 0x12345        # x13 = 0x12345000
    fence                    # NOP

    lui  x14, 2              # x14 = 0x2000, dmem base
    sw   x13, 0(x14)
    lw   x15, 0(x14)         # x15 = 0x12345000
    addi x16, x0, 122
    sb   x16, 5(x14)         # word1.byte1 = 0x7A
    lbu  x17, 5(x14)         # x17 = 122
    addi x18, x0, -1
    sh   x18, 10(x14)        # word2.half1 = 0xFFFF
    lh   x19, 10(x14)        # x19 = -1 (sign-extend)
    lhu  x20, 10(x14)        # x20 = 65535 (zero-extend)
    addi x21, x0, -128
    sb   x21, 4(x14)         # word1.byte0 = 0x80
    lb   x21, 4(x14)         # x21 = -128 (sign-extend)

    addi x22, x0, 0          # sum
    addi x23, x0, 5          # counter
loop:
    add  x22, x22, x23
    addi x23, x23, -1
    bne  x23, x0, loop       # x22 = 15; taken 4x, trains the predictor
    beq  x1, x2, never       # not taken
    addi x24, x0, 1          # x24 = 1

    jal  x25, subr           # x25 = address of `back`
back:
    addi x26, x26, 100       # x26 = 7 + 100 = 107

    # ---- sync traps, mtvec in direct mode -------------------------------
    addi x28, x0, handler_sync
    csrrw x0, mtvec, x28
    csrrs x27, mtvec, x0     # x27 = mtvec readback

    addi x29, x0, 0
    ecall                    # cause 11 -> x29 |= 1
    .word 0xFFFFFFFF         # cause 2  -> x29 |= 2
    ebreak                   # cause 3  -> x29 |= 32
    .word 0x04D73023         # store with funct3=011: illegal, must NOT
                             # write dmem[64] (TB checks) -> x29 |= 2
    lh   x28, 1(x14)         # cause 4  -> x29 |= 4   (no AXI op issued)
    sh   x0, 1(x14)          # cause 6  -> x29 |= 64  (no AXI op issued)
    lui  x28, 8              # x28 = 0x8000, unmapped
    lw   x28, 0(x28)         # cause 5  -> x29 |= 8   (DECERR on read)
    lui  x28, 8              # reload: the handler trashes x28
    sw   x0, 0(x28)          # cause 7  -> x29 |= 16  (DECERR on write)

    # same two causes again, but as SLVERR from a real peripheral (the PIC)
    lui  x28, 0x30000        # PIC config window
    lw   x30, 16(x28)        # unmapped PIC register -> SLVERR -> cause 5
    lui  x28, 0x30000        # reload: the handler trashes x28
    sw   x0, 4(x28)          # IRQ_PENDING is read-only -> SLVERR -> cause 7

    csrrs x30, 0x7C0, x0     # unimplemented CSR, even a read -> cause 2
    csrrw x0, mip, x28       # write to RO mip -> cause 2
    csrrw x0, mhartid, x28   # write to RO mhartid -> cause 2

    # CSR immediate forms + mscratch round-trip (no traps)
    csrrwi x0, mscratch, 21
    csrrsi x30, mscratch, 10 # x30 = 21 (old value), mscratch = 31
    csrrs x28, mscratch, x0  # x28 = 31
    sw   x30, 128(x14)       # [128] = 21
    sw   x28, 132(x14)       # [132] = 31

    # cause 0: taken JALR whose target has bit1 set (bit0 is cleared by JALR)
    addi x28, x0, handler_sync
    jalr x0, x28, 2          # cause 0 -> x29 |= 128, mepc+4 resumes here+4

    # cause 1: jump into unmapped ifetch space; handler returns via mscratch
    addi x30, x0, ff_resume
    csrrw x0, mscratch, x30
    lui  x28, 8
    jalr x0, x28, 0          # fetch of 0x8000 faults -> cause 1 -> x29 |= 256
ff_resume:

    # ---- interrupts + vectored mtvec ------------------------------------
    # program the PIC over AXI: enable ch2, ch3, ch5 (0x2C) and read back.
    # ch5 stays masked at the CPU (mie) to prove the two masks are independent.
    lui  x28, 0x30000
    addi x30, x0, 0x2C
    sw   x30, 0(x28)         # IRQ_ENABLE = 0x2C
    lw   x30, 0(x28)
    sw   x30, 180(x14)       # [180] = 0x2C readback
    lw   x30, 8(x28)         # IRQ_RAW: source 5 held high by the TB
    sw   x30, 184(x14)       # [184] = 0x20
    lw   x30, 4(x28)         # IRQ_PENDING: ch5 enabled + pending, MIE still 0
    sw   x30, 188(x14)       # [188] = 0x20

    addi x28, x0, vec_base
    ori  x28, x28, 1         # MODE = 01 (vectored)
    csrrw x0, mtvec, x28
    lui  x28, 0xC0           # mie bits 18+19 = PIC ch2+ch3 (ch5 stays masked)
    csrrw x0, mie, x28
    addi x31, x0, 0
    addi x28, x0, 8
    csrrs x0, mstatus, x28   # mstatus.MIE = 1
wait_irq:
    beq  x31, x0, wait_irq   # irq #1 lands on this boundary
    csrrs x30, mip, x0
    sw   x30, 136(x14)       # [136] = mip: only ch5 pending = 0x00200000
    lw   x30, 256(x14)       # magic load; TB raises ch2 when it sees this AR
irq2_victim:
    sw   x30, 160(x14)       # [160] = 0xCAFE0001; irq #2 preempts this sw,
                             # which reruns after MRET (load already retired)
    csrrs x30, mepc, x0
    sw   x30, 168(x14)       # [168] = &irq2_victim (boundary, not mid-load)
vec_ecall:
    ecall                    # vectored: exceptions go to BASE -> [156] = 11
    addi x28, x0, 8
    csrrc x0, mstatus, x28   # mstatus.MIE = 0
    jal  x0, phase_g

subr:
    addi x26, x0, 7
    jalr x0, x25, 0          # back to `back`

never:
    addi x24, x0, 99         # must not be reached
    jal  x0, never

# ---- sync trap handler (direct mode) ------------------------------------
# counts every entry in [192], logs the cause bit in x29, then steps over the
# offending instruction — except cause 1, where mepc+4 would land back in
# unmapped space, so the resume address is taken from mscratch instead
# (mscratch doing its spec job, 5.8).
.org 0x200
handler_sync:
    lw   x28, 192(x14)
    addi x28, x28, 1
    sw   x28, 192(x14)
    csrrs x30, mcause, x0
    addi x28, x0, 1
    bne  x30, x28, hs_c11
    ori  x29, x29, 256       # cause 1: instruction access fault
    csrrs x30, mscratch, x0
    csrrw x0, mepc, x30
    mret
hs_c11:
    addi x28, x0, 11
    bne  x30, x28, hs_c2
    ori  x29, x29, 1
    jal  x0, hs_ret
hs_c2:
    addi x28, x0, 2
    bne  x30, x28, hs_c3
    ori  x29, x29, 2
    jal  x0, hs_ret
hs_c3:
    addi x28, x0, 3
    bne  x30, x28, hs_c4
    ori  x29, x29, 32
    jal  x0, hs_ret
hs_c4:
    addi x28, x0, 4
    bne  x30, x28, hs_c5
    ori  x29, x29, 4
    jal  x0, hs_ret
hs_c5:
    addi x28, x0, 5
    bne  x30, x28, hs_c6
    ori  x29, x29, 8
    jal  x0, hs_ret
hs_c6:
    addi x28, x0, 6
    bne  x30, x28, hs_c7
    ori  x29, x29, 64
    jal  x0, hs_ret
hs_c7:
    addi x28, x0, 7
    bne  x30, x28, hs_c0
    ori  x29, x29, 16
    jal  x0, hs_ret
hs_c0:
    bne  x30, x0, hs_bad     # cause 0
    ori  x29, x29, 128
    jal  x0, hs_ret
hs_bad:
    ori  x29, x29, 1024      # unexpected cause -> error flag
hs_ret:
    csrrs x30, mepc, x0
    addi x30, x30, 4
    csrrw x0, mepc, x30
    mret

# ---- vectored base: sync exceptions land here ---------------------------
.org 0x300
vec_base:
    csrrs x30, mcause, x0
    sw   x30, 156(x14)       # [156] = cause (11 expected)
    csrrs x30, mepc, x0
    addi x30, x30, 4
    csrrw x0, mepc, x30
    mret

# vectored slots for causes 18 and 19 (PIC ch2 @ BASE+0x48, ch3 @ BASE+0x4C)
.org 0x348
    jal  x0, irq_handler
    jal  x0, irq_handler

# ---- irq handler: preserves x30 through mscratch, counts entries,
# snapshots the PIC's in-service mask (proves the ack was registered) ------
.org 0x380
irq_handler:
    csrrw x30, mscratch, x30
    csrrs x31, mcause, x0    # x31 = 0x800000(16+ch)
    lw   x30, 196(x14)
    addi x30, x30, 1
    sw   x30, 196(x14)       # [196] = irq entry count
    lui  x30, 0x30000
    lw   x30, 12(x30)        # PIC IRQ_ACTIVE = 1 << current channel
    sw   x30, 164(x14)       # [164] = in-service mask of the last irq taken
    csrrw x30, mscratch, x30
    mret                     # rerun the preempted instruction

# ---- BTB aliasing: three loops, branches 0x200 apart = same index,
# different tags; each eviction re-predicts not-taken and must stay correct
.org 0x400
phase_g:
    addi x30, x0, 0
    addi x28, x0, 3
    jal  x0, alias_a
.org 0x440
alias_a:
    add  x30, x30, x28
    addi x28, x28, -1
    bne  x28, x0, alias_a    # branch @ 0x448
    addi x28, x0, 3
    jal  x0, alias_b
.org 0x640
alias_b:
    add  x30, x30, x28
    addi x28, x28, -1
    bne  x28, x0, alias_b    # branch @ 0x648, evicts 0x448's entry
    addi x28, x0, 3
    jal  x0, alias_c
.org 0x840
alias_c:
    add  x30, x30, x28
    addi x28, x28, -1
    bne  x28, x0, alias_c    # branch @ 0x848, third tag on the same index
    sw   x30, 152(x14)       # [152] = 6+6+6 = 18
    jal  x0, phase_g2

.org 0x900
phase_g2:
    addi x0, x0, 5           # write to x0 must be ignored
    add  x30, x0, x0
    sw   x30, 172(x14)       # [172] = 0
    csrrs x30, mhartid, x0
    sw   x30, 176(x14)       # [176] = 0 (HART_ID of a single-core setup)

    # store -> load of the same address, back to back on the bus
    sw   x13, 240(x14)
    lw   x30, 240(x14)
    sw   x30, 144(x14)       # [144] = 0x12345000

    # JALR with rd == rs1: the OLD value must be the jump target
    lui  x30, %hi(jl_tgt)
    addi x30, x30, %lo(jl_tgt)
    jalr x30, x30, 0
jl_skip:
    jal  x0, hang            # skipped when the JALR jumps correctly
jl_tgt:
    sw   x30, 148(x14)       # [148] = &jl_skip (the link value)

    # CPI evidence: 32 dependent ALU ops between two mcycle reads.
    # At 1 instr/cycle the delta is 33 (32 addi + the closing csrrs).
    csrrs x28, mcycle, x0
    addi x30, x30, 1
    addi x30, x30, 1
    addi x30, x30, 1
    addi x30, x30, 1
    addi x30, x30, 1
    addi x30, x30, 1
    addi x30, x30, 1
    addi x30, x30, 1
    addi x30, x30, 1
    addi x30, x30, 1
    addi x30, x30, 1
    addi x30, x30, 1
    addi x30, x30, 1
    addi x30, x30, 1
    addi x30, x30, 1
    addi x30, x30, 1
    addi x30, x30, 1
    addi x30, x30, 1
    addi x30, x30, 1
    addi x30, x30, 1
    addi x30, x30, 1
    addi x30, x30, 1
    addi x30, x30, 1
    addi x30, x30, 1
    addi x30, x30, 1
    addi x30, x30, 1
    addi x30, x30, 1
    addi x30, x30, 1
    addi x30, x30, 1
    addi x30, x30, 1
    addi x30, x30, 1
    addi x30, x30, 1
    csrrs x30, mcycle, x0
    sub  x30, x30, x28
    sw   x30, 140(x14)       # [140] = cycle delta

    addi x23, x0, 0x123      # end marker for the TB
end:
    jal  x0, end
hang:
    jal  x0, hang            # a skipped-instruction test failed -> timeout
