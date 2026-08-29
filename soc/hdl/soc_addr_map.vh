// SoC address map - the single place the windows are defined.
//
// Every window's mask is exactly its size, so an access that lands inside the
// window but past the end of the block it decodes to cannot alias back onto
// the block: it misses every window and the decoder answers DECERR. That
// matters most for the DP-SRAM, whose 1 KB is much smaller than the 256 MB
// granularity the top address nibble suggests.
//
// Reachability is deliberately not uniform, and that is the design, not an
// omission:
//
//   ibus  IMEM only. The core fetches instructions; nothing else is
//         executable, and an errant PC gets DECERR instead of quietly
//         executing peripheral registers.
//   dbus  everything except IMEM. Software cannot rewrite its own program
//         memory, so there is no self-modifying-code path to reason about.
//   DMA   DMEM and the DP-SRAM. The DMA moves bulk data; it has no business
//         reading a peripheral's status register or writing the PIC's
//         configuration, and a runaway descriptor cannot reprogram the
//         interrupt controller.

`ifndef SOC_ADDR_MAP_VH
`define SOC_ADDR_MAP_VH

// instruction memory, 8 KB, ibus only
`define SOC_IMEM_BASE  32'h0000_0000
`define SOC_IMEM_MASK  32'hFFFF_E000
`define SOC_IMEM_WORDS 2048

// data memory, 8 KB, shared by the CPU data bus and the DMA
`define SOC_DMEM_BASE  32'h0000_2000
`define SOC_DMEM_MASK  32'hFFFF_E000
`define SOC_DMEM_WORDS 2048

// dual-port SRAM, 1 KB: words 0..7 are its control registers, 8..255 its data.
// The CPU reaches it on port A, the DMA on port B, both at this same address.
`define SOC_SRAM_BASE  32'h1000_0000
`define SOC_SRAM_MASK  32'hFFFF_FC00

// Peripherals, based 64 KB apart but each only 256 B wide, CPU data bus only.
// The window is the size of the block's register file, not the size of the gap
// between blocks. All three decode a byte offset of 8 bits and no more - the
// PIC and the machine timer take addr[7:2] in axi_lite_slave.v, the DMA takes
// addr[7:0] in its own slave - so a 64 KB window would leave 255 aliases of
// every register above each block. Writing PIC_BASE+0x100 would land on
// SRC0_CONFIG and TMR_BASE+0x100 on MTIME_LO, both answering OKAY, which is the
// one failure mode the decoder exists to prevent. At 256 B those addresses miss
// every window and come back DECERR.
`define SOC_PIC_BASE   32'h3000_0000
`define SOC_PIC_MASK   32'hFFFF_FF00
`define SOC_TMR_BASE   32'h3001_0000
`define SOC_TMR_MASK   32'hFFFF_FF00
`define SOC_DMA_BASE   32'h3002_0000
`define SOC_DMA_MASK   32'hFFFF_FF00

// PIC hardware source assignment (irq_src_i bit -> device)
//   0..3  DMA channels 0..3 (done or error)
//   4     DP-SRAM collision / cooldown
//   5,6   unused, tied low
//   7     machine timer
//   8..15 unused, tied low
`define SOC_IRQ_DMA_LSB 0
`define SOC_IRQ_SRAM    4
`define SOC_IRQ_TIMER   7

`endif
