module mc_dma (
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

    localparam N_CHANNELS = 4;

    wire [N_CHANNELS-1:0][31:0] ch_desc_addr;
    wire [N_CHANNELS-1:0][31:0] ch_control;
    wire [N_CHANNELS-1:0][31:0] ch_bw_cap;
    wire [N_CHANNELS-1:0][31:0] ch_status;
    wire [N_CHANNELS-1:0]       hw_irq;
    wire [N_CHANNELS-1:0]       ch_req;
    wire [N_CHANNELS-1:0][31:0] ch_req_addr;
    wire [N_CHANNELS-1:0][7:0]  ch_req_len;
    wire [N_CHANNELS-1:0]       ch_req_is_wr;
    wire [N_CHANNELS-1:0]       ch_gnt;
    reg  [N_CHANNELS-1:0]       active_master_ch;
    // 1. Between Register File and Channels (CH0 - CH3)
   
    wire [31:0] sched_policy;

   
    wire [31:0] int_status_w, int_enable_w;

  

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

    wire [N_CHANNELS-1:0] fetch_data_valid_ch;

    genvar i;


    // active_master_ch remembers which channel owns the transaction the master
    // is currently running. It is declared here, ahead of the continuous
    // assignments that read it below: Verilog requires a variable to be
    // declared before it is referenced, and vlog rejects the other order with
    // "Undefined variable" followed by "already declared in this scope".
    
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            active_master_ch <= 4'b0000;
        else if (ch_gnt) // one-cycle grant pulse: latch the channel id
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
    for (i = 0; i < N_CHANNELS; i = i + 1) begin : gen_fetch_data_valid_ch
        assign fetch_data_valid_ch[i] = fetch_data_valid && active_master_ch[i];
    end
    
    
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
    mc_dma_axi4_lite_slave #(.NO_CHANNELS(N_CHANNELS)) slave_inst (
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

        .ch_desc_addr  (ch_desc_addr),
        .ch_control    (ch_control),
        .ch_bw_cap     (ch_bw_cap),
        .ch_status_in  (ch_status),

        .sched_policy   (sched_policy),
        .int_status     (int_status_w),
        .int_enable     (int_enable_w),
        .hw_irq_in      (hw_irq)
    );
    
    for (i = 0; i < N_CHANNELS; i = i + 1) begin : gen_dma_channels
        mc_dma_channel ch_inst (
            .clk            (clk),
            .rst_n          (rst_n),
            .desc_addr_in   (ch_desc_addr[i]),
            .control_in     (ch_control[i]),
            .bw_cap_in      (ch_bw_cap[i]),
            .status_out     (ch_status[i]),
            .irq_out        (hw_irq[i]),
            
            .req_valid      (ch_req[i]),
            .req_addr       (ch_req_addr[i]),
            .req_len        (ch_req_len[i]),
            .req_is_write   (ch_req_is_wr[i]),
            .arb_gnt        (ch_gnt[i]),

            .burst_done     (global_burst_done && active_master_ch[i]), 
            .axi_error      (global_axi_error  && active_master_ch[i]), 
            .fetch_data_in  (fetch_data_out),
            .fetch_data_valid(fetch_data_valid_ch[i])
        );
    end
   
    // 3. Priority Arbiter
    mc_dma_priority_arbiter arbiter_inst (
        .clk                (clk),
        .rst_n              (rst_n),
        .sched_policy       (sched_policy),
        
        .ch_req             (ch_req),
        .ch_req_addr        (ch_req_addr),
        .ch_req_len         (ch_req_len),
        .ch_req_is_write    (ch_req_is_wr),
        
        .ch_gnt             (ch_gnt),
        
        .master_req_valid   (master_req_valid),
        .master_req_addr    (master_req_addr),
        .master_req_len     (master_req_len),
        .master_req_is_write(master_req_is_write),
        .master_req_ch_id   (master_req_ch_id),
        .master_req_ready   (master_req_ready)
    );

    // 4. AXI4-Full Master
    mc_dma_axi4_full_master master_inst (
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