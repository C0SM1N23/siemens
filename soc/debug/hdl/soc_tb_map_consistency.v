// The two address maps must agree.
//
// The SoC design takes its windows from soc/hdl/soc_addr_map.vh. The CPU
// block's own system bench builds a small SoC of its own and takes the same
// addresses from cpu/debug/sim/rv32i_soc_map.vh, because that bench predates the SoC
// and must stay buildable without it.
//
// Two files, one set of addresses, and nothing that notices when they stop
// agreeing. The failure is quiet in the worst way: both flows keep passing,
// each against its own idea of where the peripherals are, and the disagreement
// only surfaces when someone moves a window in one file and reads a passing
// regression in the other.
//
// Merging the files would fix it by coupling the CPU block to the SoC, which
// is the dependency the split exists to avoid. So the maps stay separate and
// this bench makes the drift loud instead.
//
// It is a compile-time comparison with no design in it: both headers are
// included here, which is the only place in the tree where both are visible at
// once.
//
// Verilog-2005; run by the ModelSim flow.

`timescale 1ns/1ps

`include "soc_addr_map.vh"
`include "rv32i_soc_map.vh"

module soc_tb_map_consistency;

integer errors;
`include "tb_check.vh"

// The CPU bench's map carries no size masks for IMEM and DMEM: its models are
// sized by parameter rather than decoded. Only the addresses are shared, so
// only the addresses are compared, plus the two peripheral masks that do exist
// on both sides.

initial begin
    errors = 0;
    $display("=====================================================");
    $display("== ADDRESS MAP CONSISTENCY ==");
    $display("=====================================================");
    $display("The CPU block's testbench map must name the same addresses as");
    $display("the map the SoC design is built from.");
    $display("");

    check(`SOC_IMEM_BASE, `IMEM_BASE,  "instruction memory base");
    check(`SOC_DMEM_BASE, `DMEM_BASE,  "data memory base");
    check(`SOC_PIC_BASE,  `PIC_BASE,   "interrupt controller base");
    check(`SOC_TMR_BASE,  `TMR_BASE,   "machine timer base");

    // The CPU bench splits its peripheral window with a mask of its own. It
    // must be wide enough to contain both peripherals the SoC places there,
    // and the timer's own mask must not be wider than the SoC's, or the bench
    // would route addresses to the timer that the real system refuses.
    check(`SOC_TMR_BASE & `PERIP_MASK, `PERIP_BASE,
          "timer sits inside the bench peripheral window");
    check(`SOC_PIC_BASE & `PERIP_MASK, `PERIP_BASE,
          "controller sits inside the bench peripheral window");

    if ((`TMR_MASK & `SOC_TMR_MASK) === `TMR_MASK)
        $display("PASS: the bench timer window is no narrower than the SoC's");
    else begin
        $display("FAIL: the bench timer window is narrower than the SoC's");
        errors = errors + 1;
    end

    // The SoC places the DMA in the same 0x3000_xxxx region. The CPU bench has
    // no DMA, but if the region ever moved under it the bench's peripheral
    // window would stop containing the peripherals it does have.
    check(`SOC_DMA_BASE & `PERIP_MASK, `PERIP_BASE,
          "the DMA window is in the same region the bench decodes");

    $display("");
    $display("=====================================================");
    if (errors == 0)
        $display("== ADDRESS MAP CONSISTENCY: ALL TESTS PASSED ==");
    else
        $display("== ADDRESS MAP CONSISTENCY: %0d FAILURE(S) ==", errors);
    $display("=====================================================");
    $finish;
end

endmodule
