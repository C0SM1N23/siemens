// Testbench for the pipelined RV32I CPU (cpu_top).
//
// Setup: cpu_top + two AXI4-Lite slave models (imem @ 0x0000 on the ibus,
// dmem @ 0x2000 on the dbus) + a passive AXI protocol monitor on each bus +
// a PIC stub. Any dbus address outside the dmem window answers DECERR.
//
// PIC stub script:
//   - channel 5 goes up right after reset and stays up: it is never enabled
//     in mie, so it must never be taken (no ack[5], ever) — negative test
//   - channel 2 fires once when the program enables MIE (normal take), and
//     once more while a data-bus read is in flight — the ack must come only
//     after the R beat (interrupts are held through an AXI stall and taken at
//     the instruction boundary)
//
// The program (program_axi.s) leaves results in regs and a dmem scoreboard;
// the TB checks them after the end marker (x23 = 0x123), plus invariants
// sampled every cycle and the monitors' error counters.

module tb_cpu_axi;

wire clk, rst_n;

ck_rst_tb #(.CK_SEMIPERIOD(5)) ck_rst_inst (
    .clk   (clk),
    .rst_n (rst_n)
);

// DUT
wire [31:0] ib_araddr, ib_rdata;
wire [2:0]  ib_arprot;
wire        ib_arvalid, ib_arready, ib_rvalid, ib_rready;
wire [1:0]  ib_rresp;

wire [31:0] db_awaddr, db_wdata, db_araddr, db_rdata;
wire [2:0]  db_awprot, db_arprot;
wire [3:0]  db_wstrb;
wire        db_awvalid, db_awready, db_wvalid, db_wready, db_bvalid, db_bready;
wire        db_arvalid, db_arready, db_rvalid, db_rready;
wire [1:0]  db_bresp, db_rresp;

reg  [7:0]  cpu_irq;
reg  [2:0]  cpu_irq_id;
wire [7:0]  cpu_irq_ack;
wire        cpu_in_trap;

cpu_top uut (
    .clk              (clk),
    .rst_n            (rst_n),
    .ibus_axi_araddr  (ib_araddr),
    .ibus_axi_arprot  (ib_arprot),
    .ibus_axi_arvalid (ib_arvalid),
    .ibus_axi_arready (ib_arready),
    .ibus_axi_rdata   (ib_rdata),
    .ibus_axi_rresp   (ib_rresp),
    .ibus_axi_rvalid  (ib_rvalid),
    .ibus_axi_rready  (ib_rready),
    .dbus_axi_awaddr  (db_awaddr),
    .dbus_axi_awprot  (db_awprot),
    .dbus_axi_awvalid (db_awvalid),
    .dbus_axi_awready (db_awready),
    .dbus_axi_wdata   (db_wdata),
    .dbus_axi_wstrb   (db_wstrb),
    .dbus_axi_wvalid  (db_wvalid),
    .dbus_axi_wready  (db_wready),
    .dbus_axi_bresp   (db_bresp),
    .dbus_axi_bvalid  (db_bvalid),
    .dbus_axi_bready  (db_bready),
    .dbus_axi_araddr  (db_araddr),
    .dbus_axi_arprot  (db_arprot),
    .dbus_axi_arvalid (db_arvalid),
    .dbus_axi_arready (db_arready),
    .dbus_axi_rdata   (db_rdata),
    .dbus_axi_rresp   (db_rresp),
    .dbus_axi_rvalid  (db_rvalid),
    .dbus_axi_rready  (db_rready),
    .cpu_irq          (cpu_irq),
    .cpu_irq_ack      (cpu_irq_ack),
    .cpu_irq_id       (cpu_irq_id),
    .cpu_in_trap      (cpu_in_trap)
);

// instruction memory (ibus, read-only)
axi_lite_mem_model #(
    .WORDS(1024), .BASE(32'h0000_0000), .INIT_FILE("program_axi.hex"),
    .READ_LAT(0), .SEED(11)
) imem_inst (
    .clk(clk), .rst_n(rst_n),
    .awaddr(32'b0), .awvalid(1'b0), .awready(),
    .wdata(32'b0), .wstrb(4'b0), .wvalid(1'b0), .wready(),
    .bresp(), .bvalid(), .bready(1'b0),
    .araddr(ib_araddr), .arvalid(ib_arvalid), .arready(ib_arready),
    .rdata(ib_rdata), .rresp(ib_rresp), .rvalid(ib_rvalid), .rready(ib_rready)
);

// data memory (dbus, with latency -> multi-cycle stalls)
axi_lite_mem_model #(
    .WORDS(1024), .BASE(32'h0000_2000),
    .READ_LAT(1), .WRITE_LAT(1), .SEED(23)
) dmem_inst (
    .clk(clk), .rst_n(rst_n),
    .awaddr(db_awaddr), .awvalid(db_awvalid), .awready(db_awready),
    .wdata(db_wdata), .wstrb(db_wstrb), .wvalid(db_wvalid), .wready(db_wready),
    .bresp(db_bresp), .bvalid(db_bvalid), .bready(db_bready),
    .araddr(db_araddr), .arvalid(db_arvalid), .arready(db_arready),
    .rdata(db_rdata), .rresp(db_rresp), .rvalid(db_rvalid), .rready(db_rready)
);

// protocol monitors on both buses (err counts must end at 0)
wire [15:0] ib_mon_err, db_mon_err;
wire [31:0] ib_mon_rd, db_mon_rd, db_mon_wr;

axi_lite_monitor #(.NAME("ibus"), .HAS_WRITE(0)) ibus_mon (
    .clk(clk), .rst_n(rst_n),
    .awaddr(32'b0), .awvalid(1'b0), .awready(1'b0),
    .wdata(32'b0), .wstrb(4'b0), .wvalid(1'b0), .wready(1'b0),
    .bresp(2'b0), .bvalid(1'b0), .bready(1'b0),
    .araddr(ib_araddr), .arvalid(ib_arvalid), .arready(ib_arready),
    .rdata(ib_rdata), .rresp(ib_rresp), .rvalid(ib_rvalid), .rready(ib_rready),
    .err_cnt(ib_mon_err), .rd_cnt(ib_mon_rd), .wr_cnt()
);

axi_lite_monitor #(.NAME("dbus"), .HAS_WRITE(1)) dbus_mon (
    .clk(clk), .rst_n(rst_n),
    .awaddr(db_awaddr), .awvalid(db_awvalid), .awready(db_awready),
    .wdata(db_wdata), .wstrb(db_wstrb), .wvalid(db_wvalid), .wready(db_wready),
    .bresp(db_bresp), .bvalid(db_bvalid), .bready(db_bready),
    .araddr(db_araddr), .arvalid(db_arvalid), .arready(db_arready),
    .rdata(db_rdata), .rresp(db_rresp), .rvalid(db_rvalid), .rready(db_rready),
    .err_cnt(db_mon_err), .rd_cnt(db_mon_rd), .wr_cnt(db_mon_wr)
);

integer errors;

task check;
    input [31:0] expected;
    input [31:0] got;
    input [255:0] test_name;
    begin
        if (expected === got)
            $display("PASS: %0s = 0x%08h", test_name, got);
        else begin
            $display("FAIL: %0s -> expected 0x%08h, got 0x%08h",
                     test_name, expected, got);
            errors = errors + 1;
        end
    end
endtask

// cycle-by-cycle invariants
reg        ack5_seen;      // masked channel must never be acknowledged
reg        ack_double;     // ack is a 1-cycle pulse
reg        ack_in_stall;   // never accept an irq mid data transaction
reg [7:0]  ack_prev;
integer    ack2_count;

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        ack5_seen  <= 0;
        ack_double <= 0;
        ack_in_stall <= 0;
        ack_prev   <= 8'b0;
        ack2_count <= 0;
    end else begin
        if (cpu_irq_ack[5])            ack5_seen  <= 1;
        if (|(cpu_irq_ack & ack_prev)) ack_double <= 1;
        if (|cpu_irq_ack && uut.lsu_inst.active) ack_in_stall <= 1;
        if (cpu_irq_ack[2])            ack2_count <= ack2_count + 1;
        ack_prev <= cpu_irq_ack;
    end
end

// PIC stub
time t_rbeat2, t_ack2;

initial begin
    cpu_irq    = 8'b0;
    cpu_irq_id = 3'd0;
    t_rbeat2   = 0;
    t_ack2     = 0;

    wait (rst_n === 1'b1);
    @(posedge clk);

    // ch5: pending from the start, enabled nowhere -> must never be taken
    cpu_irq[5] = 1'b1;
    cpu_irq_id = 3'd5;

    // irq #1: normal take once the program sets mstatus.MIE
    wait (uut.csr_file_inst.mstatus_mie_q === 1'b1);
    repeat (3) @(posedge clk);
    cpu_irq[2] = 1'b1;
    cpu_irq_id = 3'd2;                       // ch2 outranks ch5 in this PIC
    while (cpu_irq_ack[2] !== 1'b1) @(posedge clk);
    if (cpu_in_trap !== 1'b1)
        $display("FAIL: cpu_in_trap not set on irq ack");
    cpu_irq[2] = 1'b0;
    cpu_irq_id = 3'd5;
    while (cpu_in_trap === 1'b1) @(posedge clk);   // handler done (MRET)

    // irq #2: raise the line while the magic load (0x2100) is in flight;
    // the take must wait for the response (interrupt held through the stall)
    while (!(db_arvalid === 1'b1 && db_araddr === 32'h0000_2100)) @(posedge clk);
    cpu_irq[2] = 1'b1;
    cpu_irq_id = 3'd2;
    while (!(db_rvalid === 1'b1 && db_rready === 1'b1)) @(posedge clk);
    t_rbeat2 = $time;
    while (cpu_irq_ack[2] !== 1'b1) @(posedge clk);
    t_ack2 = $time;
    cpu_irq[2] = 1'b0;
    cpu_irq_id = 3'd5;
end

// main sequence
integer i, tmo;

initial begin
    errors = 0;

    // dmem starts zeroed + the magic word the stall-irq test loads
    for (i = 0; i < 1024; i = i + 1)
        dmem_inst.mem[i] = 32'b0;
    dmem_inst.mem[64] = 32'hCAFE0001;        // byte address 0x2100

    wait (rst_n === 1'b1);

    tmo = 0;
    while (uut.regfile_inst.regs[23] !== 32'h123 && tmo < 20000) begin
        @(posedge clk);
        tmo = tmo + 1;
    end
    repeat (5) @(posedge clk);

    if (tmo >= 20000) begin
        $display("FAIL: timeout - program never reached the end marker");
        errors = errors + 1;
    end

    // arithmetic / logic / forwarding
    check(32'd10,        uut.regfile_inst.regs[1],  "x1  ADDI");
    check(32'd15,        uut.regfile_inst.regs[2],  "x2  ADDI fwd");
    check(32'd25,        uut.regfile_inst.regs[3],  "x3  ADD fwd");
    check(32'd15,        uut.regfile_inst.regs[4],  "x4  SUB");
    check(32'd240,       uut.regfile_inst.regs[5],  "x5  XORI");
    check(32'd250,       uut.regfile_inst.regs[6],  "x6  OR");
    check(32'd10,        uut.regfile_inst.regs[7],  "x7  AND");
    check(32'd160,       uut.regfile_inst.regs[8],  "x8  SLLI");
    check(32'd40,        uut.regfile_inst.regs[9],  "x9  SRLI");
    check(32'hFFFFFFE7,  uut.regfile_inst.regs[10], "x10 SRAI");
    check(32'd1,         uut.regfile_inst.regs[11], "x11 SLT");
    check(32'd0,         uut.regfile_inst.regs[12], "x12 SLTU");
    check(32'h12345000,  uut.regfile_inst.regs[13], "x13 LUI");
    check(32'd0,         uut.regfile_inst.regs[0],  "x0 stays zero");

    // byte-lane load/store
    check(32'h00002000,  uut.regfile_inst.regs[14], "x14 dmem base");
    check(32'h12345000,  uut.regfile_inst.regs[15], "x15 LW");
    check(32'd122,       uut.regfile_inst.regs[17], "x17 LBU");
    check(32'hFFFFFFFF,  uut.regfile_inst.regs[19], "x19 LH sign-ext");
    check(32'd65535,     uut.regfile_inst.regs[20], "x20 LHU");
    check(32'hFFFFFF80,  uut.regfile_inst.regs[21], "x21 LB sign-ext");
    check(32'h12345000,  dmem_inst.mem[0],          "dmem[0] SW");
    check(32'h00007A80,  dmem_inst.mem[1],          "dmem[1] SB lanes");
    check(32'hFFFF0000,  dmem_inst.mem[2],          "dmem[2] SH lane");
    check(32'h12345000,  dmem_inst.mem[36],         "RAW store->load result");

    // branches, JAL/JALR
    check(32'd15,        uut.regfile_inst.regs[22], "x22 BNE loop");
    check(32'd1,         uut.regfile_inst.regs[24], "x24 BEQ not-taken");
    check(32'h00000090,  uut.regfile_inst.regs[25], "x25 JAL link");
    check(32'd107,       uut.regfile_inst.regs[26], "x26 JAL/JALR round-trip");
    check(32'd18,        dmem_inst.mem[38],         "BTB aliasing sum");
    check(32'h0000092C,  dmem_inst.mem[37],         "JALR rd==rs1 link");

    // CSRs + sync traps
    check(32'h00000200,  uut.regfile_inst.regs[27], "x27 mtvec readback");
    check(32'd511,       uut.regfile_inst.regs[29], "x29 all 9 sync causes seen");
    check(32'd13,        dmem_inst.mem[48],         "sync trap count exact");
    check(32'd0,         dmem_inst.mem[16],         "illegal store: no mem write");
    check(32'd21,        dmem_inst.mem[32],         "CSRRWI/CSRRSI old value");
    check(32'd31,        dmem_inst.mem[33],         "mscratch round-trip");
    check(32'd0,         dmem_inst.mem[43],         "x0 write ignored");
    check(32'd0,         dmem_inst.mem[44],         "mhartid reads HART_ID (0)");

    // interrupts
    check(32'h80000012,  uut.regfile_inst.regs[31], "x31 irq mcause");
    check(32'h00200000,  dmem_inst.mem[34],         "mip shows masked ch5 only");
    check(32'd2,         dmem_inst.mem[49],         "irq handler entered twice");
    check(32'd2,         ack2_count,                "exactly two ack[2] pulses");
    check(32'd0,         {31'b0, ack5_seen},        "masked ch5 never acked");
    check(32'd0,         {31'b0, ack_double},       "ack is a 1-cycle pulse");
    check(32'd0,         {31'b0, ack_in_stall},     "no ack during a data stall");
    check(32'hCAFE0001,  dmem_inst.mem[40],         "load retired before irq #2");
    check(32'h00000134,  dmem_inst.mem[42],         "irq #2 mepc = boundary instr");
    if (t_rbeat2 != 0 && t_ack2 > t_rbeat2)
        $display("PASS: irq #2 held through the AXI stall (R @%0t, ack @%0t)",
                 t_rbeat2, t_ack2);
    else begin
        $display("FAIL: irq #2 ordering (R @%0t, ack @%0t)", t_rbeat2, t_ack2);
        errors = errors + 1;
    end

    // vectored mtvec
    check(32'h00000301,  uut.csr_file_inst.mtvec_q, "mtvec vectored");
    check(32'd11,        dmem_inst.mem[39],         "vectored exception -> BASE");
    check(32'h00000144,  uut.csr_file_inst.mepc_q,  "final mepc = vec_ecall+4");
    check(32'd11,        uut.csr_file_inst.mcause_q,"final mcause");
    check(32'd0,         {31'b0, uut.csr_file_inst.mstatus_mie_q}, "mstatus.MIE after CSRRC");
    check(32'd0,         {31'b0, cpu_in_trap},      "cpu_in_trap after MRET");

    // CPI evidence: only meaningful with an un-stalled instruction bus
    if (imem_inst.READ_LAT == 0 && imem_inst.STALL_PROB == 0) begin
        if (dmem_inst.mem[35] >= 32'd33 && dmem_inst.mem[35] <= 32'd44)
            $display("PASS: CPI window = %0d cycles for 33 instrs", dmem_inst.mem[35]);
        else begin
            $display("FAIL: CPI window = %0d cycles for 33 instrs", dmem_inst.mem[35]);
            errors = errors + 1;
        end
    end else
        $display("SKIP: CPI check (imem latency/backpressure active)");

    // protocol monitors
    check(32'd0,         {16'b0, ib_mon_err},       "ibus protocol clean");
    check(32'd0,         {16'b0, db_mon_err},       "dbus protocol clean");
    if (ib_mon_rd > 0 && db_mon_rd > 0 && db_mon_wr > 0)
        $display("PASS: traffic seen (ibus rd %0d, dbus rd %0d wr %0d)",
                 ib_mon_rd, db_mon_rd, db_mon_wr);
    else begin
        $display("FAIL: a bus saw no traffic");
        errors = errors + 1;
    end

    // performance counters sane
    if (uut.csr_file_inst.minstret_q > 0 &&
        uut.csr_file_inst.mcycle_q > uut.csr_file_inst.minstret_q)
        $display("PASS: counters (mcycle %0d > minstret %0d)",
                 uut.csr_file_inst.mcycle_q, uut.csr_file_inst.minstret_q);
    else begin
        $display("FAIL: counters (mcycle %0d, minstret %0d)",
                 uut.csr_file_inst.mcycle_q, uut.csr_file_inst.minstret_q);
        errors = errors + 1;
    end

    // end marker
    check(32'h00000123,  uut.regfile_inst.regs[23], "x23 end marker");

    if (errors == 0)
        $display("== ALL TESTS PASSED ==");
    else
        $display("== %0d TESTS FAILED ==", errors);
    $finish;
end

endmodule
