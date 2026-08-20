// ---------------------------------------------------------------------------
// RTL source list and COMPILE ORDER — single source of truth, shared by the
// ModelSim and the Verilator flows (vlog -f rtl.f / verilator -f rtl.f).
// Paths are relative to debug/sim, where both flows run. A module is added
// here once, not per flow.
//
// WHY THE ORDER IS FIXED
// ---------------------
// Verilog-2005 does not require a module to be compiled after the modules it
// instantiates: the tools resolve instances at elaboration, not at compile
// time. So a randomly ordered list usually still works. "Usually" is the
// problem. Two things are resolved at COMPILE time, in file order:
//
//   1. `include / `define. defines.vh is textually included by the modules
//      that use its encodings. A macro is only visible from the point it is
//      defined onwards in the compilation unit, so a file that relies on a
//      macro defined elsewhere must be compiled after it. Here every consumer
//      includes defines.vh itself under an include guard, and +incdir+ below
//      makes it findable, which is what keeps that class of failure away.
//   2. Module redefinition and cross-file parameter/name clashes are reported
//      against whichever copy is seen first.
//
// On top of that, a bottom-up order makes an actual error legible: if a module
// is missing from this list, the failure is reported at the level that needed
// it, not as one unresolved instance at the top of the hierarchy. And several
// downstream tools (lint, synthesis scripts, formal front-ends) do require a
// definition-before-use order.
//
// So the list is written bottom-up by dependency level and kept that way even
// though the two simulators tolerate any order. It costs nothing and removes a
// whole class of "it worked on my machine" failures.
//
// LEVELS (a module may only instantiate modules from a STRICTLY lower level)
//   L0  leaf modules: instantiate nothing
//   L1  instantiate L0 only
//   L2  the top level: instantiates L0 and L1
//
// Adding a module: put it at the lowest level that is still above everything
// it instantiates, in alphabetical order within that level.
// ---------------------------------------------------------------------------

// --- include path -----------------------------------------------------------
// Resolves `include "defines.vh" (shared encodings) in both flows.
+incdir+../../hdl

// --- Level 0: leaf modules (no submodule instances) --------------------------
// Order within the level is irrelevant; alphabetical by convention.
../../hdl/alu.v              // ALU datapath                    (leaf)
../../hdl/axi_lite_slave.v   // reusable AXI4-Lite slave port    (leaf)
../../hdl/branch_predictor.v // BHT + BTB + RAS                  (leaf)
../../hdl/branch_unit.v      // branch condition + target        (leaf)
../../hdl/control.v          // main instruction decoder         (leaf)
../../hdl/csr_file.v         // M-mode CSR file                  (leaf)
../../hdl/decode.v           // instruction field extraction     (leaf)
../../hdl/exception_unit.v   // synchronous exception detect     (leaf)
../../hdl/fetch_unit.v       // PC + ibus AXI4-Lite read master  (leaf)
../../hdl/hazard_unit.v      // stall / flush / forwarding       (leaf)
../../hdl/imm_gen.v          // immediate generator              (leaf)
../../hdl/lsu.v              // dbus AXI4-Lite master            (leaf)
../../hdl/regfile.v          // 32 x 32-bit GPRs                 (leaf)
../../hdl/writeback_mux.v    // writeback source select          (leaf)

// --- Level 1: depend on Level 0 only -----------------------------------------
../../hdl/alu_top.v          // alu_top      -> alu
../../hdl/mtimer.v           // mtimer       -> axi_lite_slave
../../hdl/pic.v              // pic          -> axi_lite_slave

// --- Level 2: system top ------------------------------------------------------
// cpu_top -> alu_top (L1) + branch_predictor, branch_unit, control, csr_file,
//            decode, exception_unit, fetch_unit, hazard_unit, imm_gen, lsu,
//            regfile, writeback_mux (all L0)
../../hdl/cpu_top.v
