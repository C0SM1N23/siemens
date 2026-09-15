// CPU RTL; dependencies precede users. Paths are relative to debug/sim.
+incdir+../../hdl

// --- Level 0: leaf modules (no submodule instances) --------------------------
// Order within the level is irrelevant; alphabetical by convention.
../../hdl/rv32i_alu.v              // ALU datapath                    (leaf)
../../hdl/axi_lite_slave.v   // reusable AXI4-Lite slave port    (leaf)
../../hdl/rv32i_branch_predictor.v // BHT + BTB + RAS                  (leaf)
../../hdl/rv32i_branch_unit.v      // branch condition + target        (leaf)
../../hdl/rv32i_control.v          // main instruction decoder         (leaf)
../../hdl/rv32i_csr_file.v         // M-mode CSR file                  (leaf)
../../hdl/rv32i_decode.v           // instruction field extraction     (leaf)
../../hdl/rv32i_exception_unit.v   // synchronous exception detect     (leaf)
../../hdl/rv32i_fetch_unit.v       // PC + ibus AXI4-Lite read master  (leaf)
../../hdl/rv32i_hazard_unit.v      // stall / flush / forwarding       (leaf)
../../hdl/rv32i_imm_gen.v          // immediate generator              (leaf)
../../hdl/rv32i_lsu.v              // dbus AXI4-Lite master            (leaf)
../../hdl/rv32i_regfile.v          // 32 x 32-bit GPRs                 (leaf)
../../hdl/rv32i_writeback_mux.v    // writeback source select          (leaf)

// --- Level 1: depend on Level 0 only -----------------------------------------
../../hdl/rv32i_alu_top.v          // alu_top      -> alu
../../hdl/mtimer.v           // mtimer       -> axi_lite_slave
../../hdl/pic.v              // pic          -> axi_lite_slave

// --- Level 2: system top ------------------------------------------------------
// rv32i_cpu_top -> alu_top (L1) + branch_predictor, branch_unit, control, csr_file,
//            decode, exception_unit, fetch_unit, hazard_unit, imm_gen, lsu,
//            regfile, writeback_mux (all L0)
../../hdl/rv32i_cpu_top.v
