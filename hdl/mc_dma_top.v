module mc_dma_top (
    input         clk,
    input         rst_n,
    output  [3:0] irq,

    // AXI4-Lite Slave Interface
    // Write Address Channel
    input  [31:0] s_axi_awaddr,
    input         s_axi_awvalid,
    output        s_axi_awready,
    // Write Data Channel
    input  [31:0] s_axi_wdata,
    input  [ 3:0] s_axi_wstrb,
    input         s_axi_wvalid,
    output        s_axi_wready,
    // Write Response Channel
    output [ 1:0] s_axi_bresp,
    output        s_axi_bvalid,
    input         s_axi_bready,
    // Read Address Channel
    input  [31:0] s_axi_araddr,
    input         s_axi_arvalid,
    output        s_axi_arready,
    // Read Data Channel
    output [31:0] s_axi_rdata,
    output [ 1:0] s_axi_rresp,
    output        s_axi_rvalid,
    input         s_axi_rready,

    // AXI4-Full Master Interface
    // Write Address Channel
    output [31:0] m_axi_awaddr,
    output [ 7:0] m_axi_awlen,
    output [ 2:0] m_axi_awsize,
    output [ 1:0] m_axi_awburst,
    output        m_axi_awvalid,
    input         m_axi_awready,
    // Write Data Channel
    output [31:0] m_axi_wdata,
    output [ 3:0] m_axi_wstrb,
    output        m_axi_wlast,
    output        m_axi_wvalid,
    input         m_axi_wready,
    // Write Response Channel
    input  [ 1:0] m_axi_bresp,
    input         m_axi_bvalid,
    output        m_axi_bready,
    // Read Address Channel
    output [31:0] m_axi_araddr,
    output [ 7:0] m_axi_arlen,
    output [ 2:0] m_axi_arsize,
    output [ 1:0] m_axi_arburst,
    output        m_axi_arvalid,
    input         m_axi_arready,
    // Read Data Channel
    input  [31:0] m_axi_rdata,
    input  [ 1:0] m_axi_rresp,
    input         m_axi_rlast,
    input         m_axi_rvalid,
    output        m_axi_rready
);
    // 1. Between Register File and Channels (CH0 - CH3)
    wire [31:0] ch0_desc_addr, ch1_desc_addr, ch2_desc_addr, ch3_desc_addr;
    wire [31:0] ch0_control,   ch1_control,   ch2_control,   ch3_control;
    wire [31:0] ch0_bw_cap,    ch1_bw_cap,    ch2_bw_cap,    ch3_bw_cap;
    wire [31:0] sched_policy;

    wire [31:0] ch0_status,    ch1_status,    ch2_status,    ch3_status;
    wire [3:0]  hw_irq;
    wire [31:0] int_status_w, int_enable_w;

    // 2. Between Channels (CH0 - CH3) and Priority Arbiter
    wire [ 3:0] ch_req;
    wire [31:0] ch0_req_addr,  ch1_req_addr,  ch2_req_addr,  ch3_req_addr;
    wire [7:0]  ch0_req_len,   ch1_req_len,   ch2_req_len,   ch3_req_len;
    wire        ch0_req_is_wr, ch1_req_is_wr, ch2_req_is_wr, ch3_req_is_wr;
    wire [ 3:0] ch_gnt;

    // 3. Between Priority Arbiter and AXI4-Full Master
    wire        master_req_valid;
    wire [31:0] master_req_addr;
    wire [ 7:0] master_req_len;
    wire        master_req_is_write;
    // FIX BUG 2: identitatea canalului caruia ii apartine cererea curenta
    wire [ 1:0] master_req_ch_id;
    wire        master_req_ready;

    // 4. Scatter-Gather Loop (Master to Channels)
    wire [31:0] fetch_data_out;
    wire        fetch_data_valid;

    // active_master_ch remembers which channel owns the transaction the master
    // is currently running. It is declared here, ahead of the continuous
    // assignments that read it below: Verilog requires a variable to be
    // declared before it is referenced, and vlog rejects the other order with
    // "Undefined variable" followed by "already declared in this scope".
    reg [3:0] active_master_ch;
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            active_master_ch <= 4'b0000;
        else if (|ch_gnt) // one-cycle grant pulse: latch the channel id
            active_master_ch <= ch_gnt;
    end

    // ==== FIX BUG 2: date de fetch calificate per-canal ====
    // fetch_data_out/fetch_data_valid erau transmise nefiltrat (broadcast)
    // catre toate cele 4 instante dma_channel. Fiecare canal le absorbea
    // ori de cate ori era in STATE_FETCHING/STATE_ACTIVE, indiferent daca
    // datele intoarse de master apartineau efectiv lui sau altui canal activ
    // in acel moment. Cand doua canale erau concurent in FETCHING/ACTIVE
    // (ex: politica Round-Robin), acest lucru producea coruperea datelor
    // intre canale (un canal primea datele altuia).
    //
    // Solutia mentine acelasi tipar folosit deja pentru burst_done/axi_error:
    // se calific fetch_data_valid cu active_master_ch[i], astfel incat doar
    // canalul caruia ii apartine efectiv tranzactia curenta sa capteze datele.
    wire fetch_data_valid_ch0 = fetch_data_valid && active_master_ch[0];
    wire fetch_data_valid_ch1 = fetch_data_valid && active_master_ch[1];
    wire fetch_data_valid_ch2 = fetch_data_valid && active_master_ch[2];
    wire fetch_data_valid_ch3 = fetch_data_valid && active_master_ch[3];
    
    
    // Global feedback derived from AXI responses
    wire        global_burst_done = (m_axi_bvalid && m_axi_bready) || 
                                    (m_axi_rvalid && m_axi_rready && m_axi_rlast);
    
    wire        global_axi_error  = (m_axi_bvalid && m_axi_bready && m_axi_bresp[1]) || 
                                    (m_axi_rvalid && m_axi_rready && m_axi_rresp[1]);


    // Top-level interrupt: the LATCHED status masked by the enable, not the raw
    // per-channel line.
    //
    // The register file already implements INT_STATUS (sticky, write-1-to-clear,
    // set by hw_irq) and INT_ENABLE, but both outputs used to be left
    // unconnected and irq was driven straight from hw_irq. That made two
    // software-writable registers do nothing: masking an interrupt had no
    // effect and clearing INT_STATUS did not drop the line, so the only way to
    // deassert it was to disable the channel.
    //
    // The handler sequence this enables is the usual one: read INT_STATUS to
    // find the channel, clear that channel's CONTROL.enable so hw_irq drops,
    // then write 1 to the INT_STATUS bit to release the request.
    assign irq = int_status_w[3:0] & int_enable_w[3:0];

    
    // Module Instantiations
    

    // 1. AXI4-Lite Slave (Register File)
    axi4_lite_slave slave_inst (
        .clk            (clk),
        .rst_n          (rst_n),
        
        .s_axi_awaddr   (s_axi_awaddr),
        .s_axi_awvalid  (s_axi_awvalid),
        .s_axi_awready  (s_axi_awready),
        .s_axi_wdata    (s_axi_wdata),
        .s_axi_wstrb    (s_axi_wstrb),
        .s_axi_wvalid   (s_axi_wvalid),
        .s_axi_wready   (s_axi_wready),
        .s_axi_bresp    (s_axi_bresp),
        .s_axi_bvalid   (s_axi_bvalid),
        .s_axi_bready   (s_axi_bready),
        .s_axi_araddr   (s_axi_araddr),
        .s_axi_arvalid  (s_axi_arvalid),
        .s_axi_arready  (s_axi_arready),
        .s_axi_rdata    (s_axi_rdata),
        .s_axi_rresp    (s_axi_rresp),
        .s_axi_rvalid   (s_axi_rvalid),
        .s_axi_rready   (s_axi_rready),

        .ch0_desc_addr  (ch0_desc_addr),
        .ch0_control    (ch0_control),
        .ch0_bw_cap     (ch0_bw_cap),
        .ch0_status_in  (ch0_status),
        
        .ch1_desc_addr(ch1_desc_addr), 
        .ch1_control(ch1_control), 
        .ch1_bw_cap(ch1_bw_cap), 
        .ch1_status_in(ch1_status),

        .ch2_desc_addr(ch2_desc_addr), 
        .ch2_control(ch2_control), 
        .ch2_bw_cap(ch2_bw_cap), 
        .ch2_status_in(ch2_status),
        
        .ch3_desc_addr(ch3_desc_addr), 
        .ch3_control(ch3_control), 
        .ch3_bw_cap(ch3_bw_cap), 
        .ch3_status_in(ch3_status),

        .sched_policy   (sched_policy),
        .int_status     (int_status_w),
        .int_enable     (int_enable_w),
        .hw_irq_in      (hw_irq)
    );

    // 2. DMA Channels
    dma_channel ch0_inst (
        .clk            (clk),
        .rst_n          (rst_n),
        .desc_addr_in   (ch0_desc_addr),
        .control_in     (ch0_control),
        .bw_cap_in      (ch0_bw_cap),
        .status_out     (ch0_status),
        .irq_out        (hw_irq[0]),
        
        .req_valid      (ch_req[0]),
        .req_addr       (ch0_req_addr),
        .req_len        (ch0_req_len),
        .req_is_write   (ch0_req_is_wr),
        .arb_gnt        (ch_gnt[0]), // Partea de acordare a grantului rămâne neschimbată
        
        .burst_done     (global_burst_done && active_master_ch[0]), // Am modificat
        .axi_error      (global_axi_error  && active_master_ch[0]), // Am modificat
        .fetch_data_in  (fetch_data_out),
        .fetch_data_valid(fetch_data_valid_ch0)
    );

    dma_channel ch1_inst (
        .clk            (clk),
        .rst_n          (rst_n),
        .desc_addr_in   (ch1_desc_addr),
        .control_in     (ch1_control),
        .bw_cap_in      (ch1_bw_cap),
        .status_out     (ch1_status),
        .irq_out        (hw_irq[1]),
        
        .req_valid      (ch_req[1]),
        .req_addr       (ch1_req_addr),
        .req_len        (ch1_req_len),
        .req_is_write   (ch1_req_is_wr),
        .arb_gnt        (ch_gnt[1]),
        
        .burst_done     (global_burst_done && active_master_ch[1]), // Am modificat
        .axi_error      (global_axi_error  && active_master_ch[1]), // Am modificat
        .fetch_data_in  (fetch_data_out),
        .fetch_data_valid(fetch_data_valid_ch1)
    );

    dma_channel ch2_inst (
        .clk            (clk),
        .rst_n          (rst_n),
        .desc_addr_in   (ch2_desc_addr),
        .control_in     (ch2_control),
        .bw_cap_in      (ch2_bw_cap),
        .status_out     (ch2_status),
        .irq_out        (hw_irq[2]),
        
        .req_valid      (ch_req[2]),
        .req_addr       (ch2_req_addr),
        .req_len        (ch2_req_len),
        .req_is_write   (ch2_req_is_wr),
        .arb_gnt        (ch_gnt[2]),
        
        .burst_done     (global_burst_done && active_master_ch[2]), // Am modificat
        .axi_error      (global_axi_error  && active_master_ch[2]), // Am modificat
        .fetch_data_in  (fetch_data_out),
        .fetch_data_valid(fetch_data_valid_ch2)
    );

    dma_channel ch3_inst (
        .clk            (clk),
        .rst_n          (rst_n),
        .desc_addr_in   (ch3_desc_addr),
        .control_in     (ch3_control),
        .bw_cap_in      (ch3_bw_cap),
        .status_out     (ch3_status),
        .irq_out        (hw_irq[3]),
        
        .req_valid      (ch_req[3]),
        .req_addr       (ch3_req_addr),
        .req_len        (ch3_req_len),
        .req_is_write   (ch3_req_is_wr),
        .arb_gnt        (ch_gnt[3]),
        
        .burst_done     (global_burst_done && active_master_ch[3]), // Am modificat
        .axi_error      (global_axi_error  && active_master_ch[3]), // Am modificat
        .fetch_data_in  (fetch_data_out),
        .fetch_data_valid(fetch_data_valid_ch3)
    );

    // 3. Priority Arbiter
    priority_arbiter arbiter_inst (
        .clk                (clk),
        .rst_n              (rst_n),
        .sched_policy       (sched_policy),
        
        .ch_req             (ch_req),
        .ch0_req_addr       (ch0_req_addr),
        .ch0_req_len        (ch0_req_len),
        .ch0_req_is_write   (ch0_req_is_wr),
        .ch1_req_addr       (ch1_req_addr),
        .ch1_req_len        (ch1_req_len),
        .ch1_req_is_write   (ch1_req_is_wr),
        .ch2_req_addr       (ch2_req_addr),
        .ch2_req_len        (ch2_req_len),
        .ch2_req_is_write   (ch2_req_is_wr),
        .ch3_req_addr       (ch3_req_addr),
        .ch3_req_len        (ch3_req_len),
        .ch3_req_is_write   (ch3_req_is_wr),
        
        .ch_gnt             (ch_gnt),
        
        .master_req_valid   (master_req_valid),
        .master_req_addr    (master_req_addr),
        .master_req_len     (master_req_len),
        .master_req_is_write(master_req_is_write),
        .master_req_ch_id   (master_req_ch_id),
        .master_req_ready   (master_req_ready)
    );

    // 4. AXI4-Full Master
    axi4_full_master master_inst (
        .clk                (clk),
        .rst_n              (rst_n),
        
        .m_axi_awaddr       (m_axi_awaddr),
        .m_axi_awlen        (m_axi_awlen),
        .m_axi_awsize       (m_axi_awsize),
        .m_axi_awburst      (m_axi_awburst),
        .m_axi_awvalid      (m_axi_awvalid),
        .m_axi_awready      (m_axi_awready),
        .m_axi_wdata        (m_axi_wdata),
        .m_axi_wstrb        (m_axi_wstrb),
        .m_axi_wlast        (m_axi_wlast),
        .m_axi_wvalid       (m_axi_wvalid),
        .m_axi_wready       (m_axi_wready),
        .m_axi_bresp        (m_axi_bresp),
        .m_axi_bvalid       (m_axi_bvalid),
        .m_axi_bready       (m_axi_bready),
        .m_axi_araddr       (m_axi_araddr),
        .m_axi_arlen        (m_axi_arlen),
        .m_axi_arsize       (m_axi_arsize),
        .m_axi_arburst      (m_axi_arburst),
        .m_axi_arvalid      (m_axi_arvalid),
        .m_axi_arready      (m_axi_arready),
        .m_axi_rdata        (m_axi_rdata),
        .m_axi_rresp        (m_axi_rresp),
        .m_axi_rlast        (m_axi_rlast),
        .m_axi_rvalid       (m_axi_rvalid),
        .m_axi_rready       (m_axi_rready),
        
        .master_req_valid   (master_req_valid),
        .master_req_addr    (master_req_addr),
        .master_req_len     (master_req_len),
        .master_req_is_write(master_req_is_write),
        .master_req_ch_id   (master_req_ch_id),
        .master_req_ready   (master_req_ready),
        
        .fetch_data_out     (fetch_data_out),
        .fetch_data_valid   (fetch_data_valid)
    );

endmodule