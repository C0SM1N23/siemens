// Verilator harness for tb_cpu_axi — exists only because Verilator 5.020's
// auto-generated main does not dump the cover-property database. This is the
// canonical --timing event loop from the Verilator manual plus one line that
// writes coverage.dat at the end of the run.

#include "Vtb_cpu_axi.h"
#include "verilated.h"
#include "verilated_cov.h"

int main(int argc, char** argv) {
    VerilatedContext ctx;
    ctx.commandArgs(argc, argv);

    Vtb_cpu_axi top{&ctx};

    // event-driven loop: eval, then jump to the next scheduled time slot
    while (!ctx.gotFinish()) {
        top.eval();
        if (!top.eventsPending()) break;
        ctx.time(top.nextTimeSlot());
    }
    top.final();

#if VM_COVERAGE
    ctx.coveragep()->write("coverage.dat");
#endif
    return 0;
}
