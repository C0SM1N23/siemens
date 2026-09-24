# CPU isolation in the SoC: every access outside the windows a bus can reach
# raises a precise trap, and none of them reaches a slave.
#
# SoC map: IMEM 0x0000_0000 (instruction bus only), DMEM 0x0000_2000,
#          DP-SRAM 0x1000_0000 (1 KiB), PIC 0x3000_0000 (256 B),
#          mtimer 0x3001_0000 (256 B), DMA 0x3002_0000 (256 B)
#
# Cases, in order; the handler records {mcause, mtval} for each:
#   1  SW  0x5000_0000       unmapped on the data bus        cause 7
#   2  LW  0x0000_0100       IMEM is not on the data bus     cause 5
#   3  SW  0x0000_0100       IMEM cannot be written          cause 7
#   4  SB  0x3000_0104       past the PIC window (SRC1 alias) cause 7
#   5  LH  0x1000_0400       past the SRAM window            cause 5
#   6  LW  0x3001_0100       past the timer window           cause 5
#   7  JALR to 0x0000_2000   DMEM is not on the instruction bus  cause 1
#   8  JALR to 0x3000_0000   the PIC is not executable           cause 1
#
# DMEM layout (x14 = 0x2000):
#   0x200  scoreboard: {mcause, mtval} per trap, eight entries
#   0x300  trap count                               expect 8
#   0x304  done marker                              0x15C0A7ED
#
# Reserved registers: x14 DMEM base, x20 scoreboard pointer, x21 trap count,
#                     x27 resume address after an instruction fault.

_start:
    lui  x14, 2                  # x14 = 0x2000
    addi x20, x14, 0x200
    addi x21, x0, 0
    lui  x5, %hi(handler)
    addi x5, x5, %lo(handler)
    csrrw x0, mtvec, x5

    # 1. store to an unmapped address
    lui  x6, 0x50000
    sw   x14, 0(x6)
    # 2. load from instruction memory through the data bus
    addi x6, x0, 0x100
    lw   x7, 0(x6)
    # 3. store to instruction memory through the data bus
    sw   x14, 0(x6)
    # 4. byte store just past the PIC window, where SRC1_CONFIG would alias
    lui  x6, 0x30000
    addi x6, x6, 0x104
    addi x7, x0, 0x7F
    sb   x7, 0(x6)
    # 5. halfword load just past the SRAM window
    lui  x6, 0x10000
    addi x6, x6, 0x400
    lh   x7, 0(x6)
    # 6. load just past the timer window, where MTIME_LO would alias
    lui  x6, 0x30010
    addi x6, x6, 0x100
    lw   x7, 0(x6)

    # 7. execute from data memory
    lui  x27, %hi(resume7)
    addi x27, x27, %lo(resume7)
    lui  x6, 2
    jalr x0, x6, 0
resume7:
    # 8. execute from a peripheral window
    lui  x27, %hi(resume8)
    addi x27, x27, %lo(resume8)
    lui  x6, 0x30000
    jalr x0, x6, 0
resume8:
    sw   x21, 0x300(x14)
    lui  x30, 0x15C0A
    addi x30, x30, 0x7ED
    sw   x30, 0x304(x14)
halt:
    beq  x0, x0, halt

# Record the trap. A load or store resumes after the faulting instruction; an
# instruction fault resumes at the address the case prepared in x27.
.org 0x400
handler:
    csrrs x30, mcause, x0
    csrrs x29, 0x343, x0         # mtval
    sw   x30, 0(x20)
    sw   x29, 4(x20)
    addi x20, x20, 8
    addi x21, x21, 1
    addi x28, x0, 1
    beq  x30, x28, fetch_fault
    csrrs x28, mepc, x0
    addi x28, x28, 4
    csrrw x0, mepc, x28
    mret
fetch_fault:
    csrrw x0, mepc, x27
    mret
