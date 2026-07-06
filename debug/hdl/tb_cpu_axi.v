// Main testbench — the whole CPU + PIC system under one self-checking run.
//
// Setup (a small SoC):
// - cpu_top, imem model @ 0x0000 on the ibus
// - dbus goes through an address decoder:
//   - 0x3000_0000 window -> the real pic module
//   - everything else    -> dmem model @ 0x2000 (DECERR out of its range)
// - passive AXI protocol monitors on ibus, dbus and the PIC slave port
// - the TB plays the peripherals: it drives the PIC's irq_src lines the
//   way the DMA / DP-SRAM would (raise on event, hold until "cleared")
//
// What is tested and how the results come back:
// - the program (program_axi.s) exercises every ISA group, every sync trap
//   cause, the CSR rules and the PIC registers; results land in registers
//   and a dmem scoreboard, checked after the end marker (x23 = 0x123)
// - invariants are sampled every cycle (ack shape, PIC consistency)
// - monitor error counters must end at 0
//
// Interrupt choreography (why each source moves the way it does):
// - src5 rises right after reset and stays up
//   -> enabled in the PIC but never in mie: must never be taken (no ack[5])
//   -> proves the PIC mask and the CPU mask are independent gates
// - src2 + src3 rise in the same cycle once the program sets MIE
//   -> ch2 must be served first (priority), ch3 right after ch2's MRET
//   -> src3 stays high through its own handler: the in-service mask must
//      keep it out of cpu_irq (suppression), and it must be taken only once
// - src2 rises again while a data-bus read is in flight
//   -> the ack may only come after the R beat: interrupt held through an
//      AXI stall, taken at the instruction boundary, load result intact

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

wire [7:0]  cpu_irq;
wire [2:0]  cpu_irq_id;
wire [7:0]  cpu_irq_ack;
wire        cpu_in_trap;
reg  [7:0]  irq_src;        // peripheral lines into the PIC (DMA/SRAM stand-in)

// dbus legs after the address decoder: d0_* to dmem (default), p_* to the PIC
wire [31:0] d0_awaddr, d0_wdata, d0_araddr, d0_rdata;
wire [2:0]  d0_awprot, d0_arprot;
wire [3:0]  d0_wstrb;
wire        d0_awvalid, d0_awready, d0_wvalid, d0_wready, d0_bvalid, d0_bready;
wire        d0_arvalid, d0_arready, d0_rvalid, d0_rready;
wire [1:0]  d0_bresp, d0_rresp;

wire [31:0] p_awaddr, p_wdata, p_araddr, p_rdata;
wire [2:0]  p_awprot, p_arprot;
wire [3:0]  p_wstrb;
wire        p_awvalid, p_awready, p_wvalid, p_wready, p_bvalid, p_bready;
wire        p_arvalid, p_arready, p_rvalid, p_rready;
wire [1:0]  p_bresp, p_rresp;

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

// dbus interconnect: PIC config window at 0x3000_0000, dmem is the default
axi_lite_dec2 #(
    .S1_BASE(32'h3000_0000), .S1_MASK(32'hF000_0000)
) dbus_dec_inst (
    .clk(clk), .rst_n(rst_n),
    .m_awaddr(db_awaddr), .m_awprot(db_awprot), .m_awvalid(db_awvalid), .m_awready(db_awready),
    .m_wdata(db_wdata), .m_wstrb(db_wstrb), .m_wvalid(db_wvalid), .m_wready(db_wready),
    .m_bresp(db_bresp), .m_bvalid(db_bvalid), .m_bready(db_bready),
    .m_araddr(db_araddr), .m_arprot(db_arprot), .m_arvalid(db_arvalid), .m_arready(db_arready),
    .m_rdata(db_rdata), .m_rresp(db_rresp), .m_rvalid(db_rvalid), .m_rready(db_rready),
    .s0_awaddr(d0_awaddr), .s0_awprot(d0_awprot), .s0_awvalid(d0_awvalid), .s0_awready(d0_awready),
    .s0_wdata(d0_wdata), .s0_wstrb(d0_wstrb), .s0_wvalid(d0_wvalid), .s0_wready(d0_wready),
    .s0_bresp(d0_bresp), .s0_bvalid(d0_bvalid), .s0_bready(d0_bready),
    .s0_araddr(d0_araddr), .s0_arprot(d0_arprot), .s0_arvalid(d0_arvalid), .s0_arready(d0_arready),
    .s0_rdata(d0_rdata), .s0_rresp(d0_rresp), .s0_rvalid(d0_rvalid), .s0_rready(d0_rready),
    .s1_awaddr(p_awaddr), .s1_awprot(p_awprot), .s1_awvalid(p_awvalid), .s1_awready(p_awready),
    .s1_wdata(p_wdata), .s1_wstrb(p_wstrb), .s1_wvalid(p_wvalid), .s1_wready(p_wready),
    .s1_bresp(p_bresp), .s1_bvalid(p_bvalid), .s1_bready(p_bready),
    .s1_araddr(p_araddr), .s1_arprot(p_arprot), .s1_arvalid(p_arvalid), .s1_arready(p_arready),
    .s1_rdata(p_rdata), .s1_rresp(p_rresp), .s1_rvalid(p_rvalid), .s1_rready(p_rready)
);

// data memory (dbus default leg, with latency -> multi-cycle stalls)
axi_lite_mem_model #(
    .WORDS(1024), .BASE(32'h0000_2000),
    .READ_LAT(1), .WRITE_LAT(1), .SEED(23)
) dmem_inst (
    .clk(clk), .rst_n(rst_n),
    .awaddr(d0_awaddr), .awvalid(d0_awvalid), .awready(d0_awready),
    .wdata(d0_wdata), .wstrb(d0_wstrb), .wvalid(d0_wvalid), .wready(d0_wready),
    .bresp(d0_bresp), .bvalid(d0_bvalid), .bready(d0_bready),
    .araddr(d0_araddr), .arvalid(d0_arvalid), .arready(d0_arready),
    .rdata(d0_rdata), .rresp(d0_rresp), .rvalid(d0_rvalid), .rready(d0_rready)
);

// the device under second test: the real PIC on the decoded window
pic pic_inst (
    .clk(clk), .rst_n(rst_n),
    .irq_src(irq_src),
    .cpu_irq(cpu_irq), .cpu_irq_id(cpu_irq_id),
    .cpu_irq_ack(cpu_irq_ack), .cpu_in_trap(cpu_in_trap),
    .s_axi_awaddr(p_awaddr), .s_axi_awprot(p_awprot),
    .s_axi_awvalid(p_awvalid), .s_axi_awready(p_awready),
    .s_axi_wdata(p_wdata), .s_axi_wstrb(p_wstrb),
    .s_axi_wvalid(p_wvalid), .s_axi_wready(p_wready),
    .s_axi_bresp(p_bresp), .s_axi_bvalid(p_bvalid), .s_axi_bready(p_bready),
    .s_axi_araddr(p_araddr), .s_axi_arprot(p_arprot),
    .s_axi_arvalid(p_arvalid), .s_axi_arready(p_arready),
    .s_axi_rdata(p_rdata), .s_axi_rresp(p_rresp),
    .s_axi_rvalid(p_rvalid), .s_axi_rready(p_rready)
);

// protocol monitors on both CPU buses and on the PIC slave port
// (err counts must end at 0)
wire [15:0] ib_mon_err, db_mon_err, p_mon_err;
wire [31:0] ib_mon_rd, db_mon_rd, db_mon_wr, p_mon_rd, p_mon_wr;

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

axi_lite_monitor #(.NAME("pic"), .HAS_WRITE(1)) pic_mon (
    .clk(clk), .rst_n(rst_n),
    .awaddr(p_awaddr), .awvalid(p_awvalid), .awready(p_awready),
    .wdata(p_wdata), .wstrb(p_wstrb), .wvalid(p_wvalid), .wready(p_wready),
    .bresp(p_bresp), .bvalid(p_bvalid), .bready(p_bready),
    .araddr(p_araddr), .arvalid(p_arvalid), .arready(p_arready),
    .rdata(p_rdata), .rresp(p_rresp), .rvalid(p_rvalid), .rready(p_rready),
    .err_cnt(p_mon_err), .rd_cnt(p_mon_rd), .wr_cnt(p_mon_wr)
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
integer    ack2_count, ack3_count;
reg        id_bad;         // cpu_irq_id must be the lowest pending channel
reg        suppress_fail;  // an in-service channel must stay out of cpu_irq
reg [3:0]  ack3_age;       // cycles since ack[3], to skip the update pipeline

always @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
        ack5_seen  <= 0;
        ack_double <= 0;
        ack_in_stall <= 0;
        ack_prev   <= 8'b0;
        ack2_count <= 0;
        ack3_count <= 0;
        id_bad     <= 0;
        suppress_fail <= 0;
        ack3_age   <= 4'd0;
    end else begin
        if (cpu_irq_ack[5])            ack5_seen  <= 1;
        if (|(cpu_irq_ack & ack_prev)) ack_double <= 1;
        if (|cpu_irq_ack && uut.lsu_inst.active) ack_in_stall <= 1;
        if (cpu_irq_ack[2])            ack2_count <= ack2_count + 1;
        if (cpu_irq_ack[3])            ack3_count <= ack3_count + 1;
        ack_prev <= cpu_irq_ack;

        // the id must point at a set cpu_irq bit with nothing below it
        if (|cpu_irq && (cpu_irq[cpu_irq_id] !== 1'b1 ||
                         (cpu_irq & ((8'h01 << cpu_irq_id) - 8'h01)) != 8'b0))
            id_bad <= 1;

        // source 3 is held high through its handler; once the ack has had
        // time to propagate, cpu_irq[3] must be low until MRET
        if (cpu_irq_ack[3])
            ack3_age <= 4'd1;
        else if (!cpu_in_trap)
            ack3_age <= 4'd0;
        else if (ack3_age != 4'd0 && ack3_age != 4'd15)
            ack3_age <= ack3_age + 4'd1;
        if (ack3_age >= 4'd3 && cpu_in_trap && irq_src[3] && cpu_irq[3])
            suppress_fail <= 1;
    end
end

// peripheral model: drives the PIC source lines the way the DMA / DP-SRAM
// would — raise on an event, hold until "the handler clears the peripheral"
time t_rbeat2, t_ack2, t_ack2_first, t_ack3;

initial begin
    irq_src      = 8'b0;
    t_rbeat2     = 0;
    t_ack2       = 0;
    t_ack2_first = 0;
    t_ack3       = 0;

    wait (rst_n === 1'b1);
    @(posedge clk);

    // src 5: pending from the start; PIC-enabled by the program but never
    // enabled in mie -> must never be taken
    irq_src[5] = 1'b1;

    // irq #1 + #2: ch2 and ch3 rise together once the program sets
    // mstatus.MIE; the PIC must serve ch2 first (lower channel wins)
    wait (uut.csr_file_inst.mstatus_mie_q === 1'b1);
    repeat (3) @(posedge clk);
    irq_src[2] = 1'b1;
    irq_src[3] = 1'b1;
    while (cpu_irq_ack[2] !== 1'b1) @(posedge clk);
    t_ack2_first = $time;
    if (cpu_in_trap !== 1'b1)
        $display("FAIL: cpu_in_trap not set on irq ack");
    irq_src[2] = 1'b0;                       // ch2 handler cleared its source

    // ch3 is taken right after ch2's MRET; its source stays high through the
    // handler so the in-service mask is what keeps it out of cpu_irq (the
    // suppress_fail invariant watches this window), then drops at MRET
    while (cpu_irq_ack[3] !== 1'b1) @(posedge clk);
    t_ack3 = $time;
    while (cpu_in_trap === 1'b1) @(posedge clk);
    irq_src[3] = 1'b0;

    // irq #3: raise ch2 while the magic load (0x2100) is in flight; the take
    // must wait for the response (interrupt held through the stall)
    while (!(db_arvalid === 1'b1 && db_araddr === 32'h0000_2100)) @(posedge clk);
    irq_src[2] = 1'b1;
    while (!(db_rvalid === 1'b1 && db_rready === 1'b1)) @(posedge clk);
    t_rbeat2 = $time;
    while (cpu_irq_ack[2] !== 1'b1) @(posedge clk);
    t_ack2 = $time;
    irq_src[2] = 1'b0;
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

    // arithmetic / logic / forwarding — each value depends on the previous
    // one, so a broken S3->S2 forward shows up as a wrong result
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

    // CSRs + sync traps — exact counting: 15 handler entries and one bit
    // per cause in x29, so a missing/double/spurious trap cannot cancel out
    check(32'h00000200,  uut.regfile_inst.regs[27], "x27 mtvec readback");
    check(32'd511,       uut.regfile_inst.regs[29], "x29 all 9 sync causes seen");
    check(32'd15,        dmem_inst.mem[48],         "sync trap count exact");
    check(32'd0,         dmem_inst.mem[16],         "illegal store: no mem write");
    check(32'd21,        dmem_inst.mem[32],         "CSRRWI/CSRRSI old value");
    check(32'd31,        dmem_inst.mem[33],         "mscratch round-trip");
    check(32'd0,         dmem_inst.mem[43],         "x0 write ignored");
    check(32'd0,         dmem_inst.mem[44],         "mhartid reads HART_ID (0)");

    // interrupts through the real PIC — priority, suppression, masking and
    // the stall case, all observed at the CPU boundary (ack/mepc/mcause)
    check(32'h80000012,  uut.regfile_inst.regs[31], "x31 irq mcause");
    check(32'h00200000,  dmem_inst.mem[34],         "mip shows masked ch5 only");
    check(32'd3,         dmem_inst.mem[49],         "irq handler entered 3x");
    check(32'd2,         ack2_count,                "exactly two ack[2] pulses");
    check(32'd1,         ack3_count,                "exactly one ack[3] pulse");
    check(32'd0,         {31'b0, ack5_seen},        "masked ch5 never acked");
    check(32'd0,         {31'b0, ack_double},       "ack is a 1-cycle pulse");
    check(32'd0,         {31'b0, ack_in_stall},     "no ack during a data stall");
    check(32'd0,         {31'b0, id_bad},           "cpu_irq_id = lowest pending");
    check(32'd0,         {31'b0, suppress_fail},    "in-service ch3 suppressed");
    if (t_ack2_first != 0 && t_ack3 > t_ack2_first)
        $display("PASS: ch2 served before ch3 (ack2 @%0t, ack3 @%0t)",
                 t_ack2_first, t_ack3);
    else begin
        $display("FAIL: PIC priority order (ack2 @%0t, ack3 @%0t)",
                 t_ack2_first, t_ack3);
        errors = errors + 1;
    end
    check(32'hCAFE0001,  dmem_inst.mem[40],         "load retired before irq #3");
    check(32'h00000168,  dmem_inst.mem[42],         "irq #3 mepc = boundary instr");
    if (t_rbeat2 != 0 && t_ack2 > t_rbeat2)
        $display("PASS: irq #3 held through the AXI stall (R @%0t, ack @%0t)",
                 t_rbeat2, t_ack2);
    else begin
        $display("FAIL: irq #3 ordering (R @%0t, ack @%0t)", t_rbeat2, t_ack2);
        errors = errors + 1;
    end

    // PIC software interface, read back by the program over real AXI
    // transactions (IRQ_ACTIVE is read from inside the irq handler itself)
    check(32'h0000002C,  dmem_inst.mem[45],         "PIC IRQ_ENABLE readback");
    check(32'h00000020,  dmem_inst.mem[46],         "PIC IRQ_RAW: src5 high");
    check(32'h00000020,  dmem_inst.mem[47],         "PIC IRQ_PENDING: ch5 only");
    check(32'h00000004,  dmem_inst.mem[41],         "PIC IRQ_ACTIVE in handler");

    // vectored mtvec
    check(32'h00000301,  uut.csr_file_inst.mtvec_q, "mtvec vectored");
    check(32'd11,        dmem_inst.mem[39],         "vectored exception -> BASE");
    check(32'h00000178,  uut.csr_file_inst.mepc_q,  "final mepc = vec_ecall+4");
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
    check(32'd0,         {16'b0, p_mon_err},        "PIC port protocol clean");
    if (ib_mon_rd > 0 && db_mon_rd > 0 && db_mon_wr > 0 &&
        p_mon_rd > 0 && p_mon_wr > 0)
        $display("PASS: traffic seen (ibus rd %0d, dbus rd %0d wr %0d, pic rd %0d wr %0d)",
                 ib_mon_rd, db_mon_rd, db_mon_wr, p_mon_rd, p_mon_wr);
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
