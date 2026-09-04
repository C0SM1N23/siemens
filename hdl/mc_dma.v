module mc_dma (
    input         clk_i,
    input         rst_ni,
    output  [3:0] irq_o,

    // AXI4-Lite Slave Interface
    // Write Address Channel
    input  [31:0] s_axi_awaddr_i,
    input         s_axi_awvalid_i,
    output        s_axi_awready_o,
    // Write Data Channel
    input  [31:0] s_axi_wdata_i,
    input  [ 3:0] s_axi_wstrb_i,
    input         s_axi_wvalid_i,
    output        s_axi_wready_o,
    // Write Response Channel
    output [ 1:0] s_axi_bresp_o,
    output        s_axi_bvalid_o,
    input         s_axi_bready_i,
    // Read Address Channel
    input  [31:0] s_axi_araddr_i,
    input         s_axi_arvalid_i,
    output        s_axi_arready_o,
    // Read Data Channel
    output [31:0] s_axi_rdata_o,
    output [ 1:0] s_axi_rresp_o,
    output        s_axi_rvalid_o,
    input         s_axi_rready_i,

    // AXI4-Full Master Interface
    // Write Address Channel
    output [31:0] m_axi_awaddr_o,
    output [ 7:0] m_axi_awlen_o,
    output [ 2:0] m_axi_awsize_o,
    output [ 1:0] m_axi_awburst_o,
    output        m_axi_awvalid_o,
    input         m_axi_awready_i,
    // Write Data Channel
    output [31:0] m_axi_wdata_o,
    output [ 3:0] m_axi_wstrb_o,
    output        m_axi_wlast_o,
    output        m_axi_wvalid_o,
    input         m_axi_wready_i,
    // Write Response Channel
    input  [ 1:0] m_axi_bresp_i,
    input         m_axi_bvalid_i,
    output        m_axi_bready_o,
    // Read Address Channel
    output [31:0] m_axi_araddr_o,
    output [ 7:0] m_axi_arlen_o,
    output [ 2:0] m_axi_arsize_o,
    output [ 1:0] m_axi_arburst_o,
    output        m_axi_arvalid_o,
    input         m_axi_arready_i,
    // Read Data Channel
    input  [31:0] m_axi_rdata_i,
    input  [ 1:0] m_axi_rresp_i,
    input         m_axi_rlast_i,
    input         m_axi_rvalid_i,
    output        m_axi_rready_o
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
    
    always @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni)
            active_master_ch <= 4'b0000;
        else if (ch_gnt) // one-cycle grant pulse: latch the channel id
            active_master_ch <= ch_gnt;
    end

    for (i = 0; i < N_CHANNELS; i = i + 1) begin : gen_fetch_data_valid_ch
        assign fetch_data_valid_ch[i] = fetch_data_valid && active_master_ch[i];
    end
    
    // Global feedback derived from AXI responses
    wire global_burst_done = (m_axi_bvalid_i && m_axi_bready_o) || 
                             (m_axi_rvalid_i && m_axi_rready_o && m_axi_rlast_i);
    
    wire global_axi_error  = (m_axi_bvalid_i && m_axi_bready_o && m_axi_bresp_i[1]) || 
                             (m_axi_rvalid_i && m_axi_rready_o && m_axi_rresp_i[1]);

    assign irq_o = int_status_w[3:0] & int_enable_w[3:0];
 
    // Module Instantiations 

    // 1. AXI4-Lite Slave (Register File)
    mc_dma_axi4_lite_slave #(.NO_CHANNELS(N_CHANNELS)) slave_inst (
        .clk_i            (clk_i),
        .rst_ni          (rst_ni),
        
        .s_axi_awaddr_i   (s_axi_awaddr_i),
        .s_axi_awvalid_i  (s_axi_awvalid_i),
        .s_axi_awready_o  (s_axi_awready_o),
        .s_axi_wdata_i    (s_axi_wdata_i),
        .s_axi_wstrb_i    (s_axi_wstrb_i),
        .s_axi_wvalid_i   (s_axi_wvalid_i),
        .s_axi_wready_o   (s_axi_wready_o),
        .s_axi_bresp_o    (s_axi_bresp_o),
        .s_axi_bvalid_o   (s_axi_bvalid_o),
        .s_axi_bready_i   (s_axi_bready_i),
        .s_axi_araddr_i   (s_axi_araddr_i),
        .s_axi_arvalid_i  (s_axi_arvalid_i),
        .s_axi_arready_o  (s_axi_arready_o),
        .s_axi_rdata_o    (s_axi_rdata_o),
        .s_axi_rresp_o    (s_axi_rresp_o),
        .s_axi_rvalid_o   (s_axi_rvalid_o),
        .s_axi_rready_i   (s_axi_rready_i),

        .ch_desc_addr_o  (ch_desc_addr),
        .ch_control_o    (ch_control),
        .ch_bw_cap_o     (ch_bw_cap),
        .ch_status_i     (ch_status),

        .sched_policy_o   (sched_policy),
        .int_status_o     (int_status_w),
        .int_enable_o     (int_enable_w),
        .hw_irq_i         (hw_irq)
    );
    
    for (i = 0; i < N_CHANNELS; i = i + 1) begin : gen_dma_channels
        mc_dma_channel ch_inst (
            .clk_i            (clk_i),
            .rst_ni           (rst_ni),
            .desc_addr_i      (ch_desc_addr[i]),
            .control_i        (ch_control[i]),
            .bw_cap_i         (ch_bw_cap[i]),
            .status_o         (ch_status[i]),
            .irq_o            (hw_irq[i]),
            
            .req_valid_o      (ch_req[i]),
            .req_addr_o       (ch_req_addr[i]),
            .req_len_o        (ch_req_len[i]),
            .req_is_write_o   (ch_req_is_wr[i]),
            .arb_gnt_i        (ch_gnt[i]),

            .burst_done_i     (global_burst_done && active_master_ch[i]), 
            .axi_error_i      (global_axi_error  && active_master_ch[i]), 
            .fetch_data_i     (fetch_data_out),
            .fetch_data_valid_i(fetch_data_valid_ch[i])
        );
    end
   
    // 3. Priority Arbiter
    mc_dma_priority_arbiter arbiter_inst (
        .clk_i                  (clk_i),
        .rst_ni                 (rst_ni),
        .sched_policy_i         (sched_policy),
        
        .ch_req_i               (ch_req),
        .ch_req_addr_i          (ch_req_addr),
        .ch_req_len_i           (ch_req_len),
        .ch_req_is_write_i      (ch_req_is_wr),
        
        .ch_gnt_o               (ch_gnt),
        
        .master_req_valid_o     (master_req_valid),
        .master_req_addr_o      (master_req_addr),
        .master_req_len_o       (master_req_len),
        .master_req_is_write_o  (master_req_is_write),
        .master_req_ch_id_o     (master_req_ch_id),
        .master_req_ready_i     (master_req_ready)
    );

    // 4. AXI4-Full Master
    mc_dma_axi4_full_master master_inst (
        .clk_i                (clk_i),
        .rst_ni              (rst_ni),
        
        .m_axi_awaddr_o       (m_axi_awaddr_o),
        .m_axi_awlen_o        (m_axi_awlen_o),
        .m_axi_awsize_o       (m_axi_awsize_o),
        .m_axi_awburst_o      (m_axi_awburst_o),
        .m_axi_awvalid_o      (m_axi_awvalid_o),
        .m_axi_awready_i      (m_axi_awready_i),
        .m_axi_wdata_o        (m_axi_wdata_o),
        .m_axi_wstrb_o        (m_axi_wstrb_o),
        .m_axi_wlast_o        (m_axi_wlast_o),
        .m_axi_wvalid_o       (m_axi_wvalid_o),
        .m_axi_wready_i       (m_axi_wready_i),
        .m_axi_bresp_i        (m_axi_bresp_i),
        .m_axi_bvalid_i       (m_axi_bvalid_i),
        .m_axi_bready_o       (m_axi_bready_o),
        .m_axi_araddr_o       (m_axi_araddr_o),
        .m_axi_arlen_o        (m_axi_arlen_o),
        .m_axi_arsize_o       (m_axi_arsize_o),
        .m_axi_arburst_o      (m_axi_arburst_o),
        .m_axi_arvalid_o      (m_axi_arvalid_o),
        .m_axi_arready_i      (m_axi_arready_i),
        .m_axi_rdata_i        (m_axi_rdata_i),
        .m_axi_rresp_i        (m_axi_rresp_i),
        .m_axi_rlast_i        (m_axi_rlast_i),
        .m_axi_rvalid_i       (m_axi_rvalid_i),
        .m_axi_rready_o       (m_axi_rready_o),
        
        .master_req_valid_i   (master_req_valid),
        .master_req_addr_i    (master_req_addr),
        .master_req_len_i     (master_req_len),
        .master_req_is_write_i(master_req_is_write),
        .master_req_ch_id_i   (master_req_ch_id),
        .master_req_ready_o   (master_req_ready),
        
        .fetch_data_o         (fetch_data_out),
        .fetch_data_valid_o   (fetch_data_valid)
    );

endmodule