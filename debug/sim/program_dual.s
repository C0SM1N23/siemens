# Dual-core smoke test: both harts boot the same binary from the same reset
# vector, split on mhartid, then handshake through shared memory @ 0x2000.
#
# No LR/SC needed: each core is in-order with blocking memory ops, i.e.
# sequentially consistent, so plain flag protocols are sound. Same reasoning
# the SoC's ping-pong buffering relies on.
#
# Shared layout: [0] flag A (hart0 -> hart1), [4] flag B (hart1 -> hart0),
#                [8] hart0 result, [12] hart1 result.

_start:
    csrrs x5, mhartid, x0
    lui  x14, 2
    bne  x5, x0, hart1

    # hart 0: publish A, wait for B, leave result
    addi x6, x0, 0xA0
    sw   x6, 0(x14)
    addi x7, x0, 0xB1
h0_wait:
    lw   x8, 4(x14)
    bne  x8, x7, h0_wait
    addi x8, x0, 111
    sw   x8, 8(x14)
h0_done:
    jal  x0, h0_done

hart1:
    # hart 1: wait for A, publish B, leave result
    addi x7, x0, 0xA0
h1_wait:
    lw   x8, 0(x14)
    bne  x8, x7, h1_wait
    addi x6, x0, 0xB1
    sw   x6, 4(x14)
    addi x8, x0, 222
    sw   x8, 12(x14)
h1_done:
    jal  x0, h1_done
