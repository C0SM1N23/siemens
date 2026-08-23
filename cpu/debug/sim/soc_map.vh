// SoC memory map for the testbench — one place to change the addresses the
// global map is still open on (README "Open points"). The decoders and models
// in tb_cpu_axi reference these instead of scattering literals.
`ifndef SOC_MAP_VH
`define SOC_MAP_VH

`define IMEM_BASE 32'h0000_0000   // instruction memory (ibus)
`define DMEM_BASE 32'h0000_2000   // data memory (dbus default leg)

// peripheral window on the dbus, split again into PIC + mtimer
`define PERIP_BASE 32'h3000_0000
`define PERIP_MASK 32'hF000_0000
`define PIC_BASE   32'h3000_0000  // PIC registers (default leg of the split)
`define TMR_BASE   32'h3001_0000  // mtimer registers
`define TMR_MASK   32'hFFFF_0000

`endif
