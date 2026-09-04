module mc_dma_axi4_lite_slave #(parameter NO_CHANNELS = 4) (
    input               clk_i,
    input               rst_ni, 

    // AXI4-Lite Slave Interface
    // Write Address Channel
    input       [31:0] s_axi_awaddr_i,
    input              s_axi_awvalid_i,
    output reg         s_axi_awready_o,
    
    // Write Data Channel
    input       [31:0] s_axi_wdata_i,
    input       [3:0]  s_axi_wstrb_i,
    input              s_axi_wvalid_i,
    output reg         s_axi_wready_o,
    
    // Write Response Channel
    output reg  [1:0]  s_axi_bresp_o,
    output reg         s_axi_bvalid_o,
    input              s_axi_bready_i,
    
    // Read Address Channel
    input       [31:0] s_axi_araddr_i,
    input              s_axi_arvalid_i,
    output reg         s_axi_arready_o,
    
    // Read Data Channel
    output reg  [31:0] s_axi_rdata_o,
    output reg  [1:0]  s_axi_rresp_o,
    output reg         s_axi_rvalid_o,
    input              s_axi_rready_i,

    // Internal Interface to DMA Channels
    // CH0 Outputs (R/W)
    output reg [NO_CHANNELS-1:0][31:0] ch_desc_addr_o,
    output reg [NO_CHANNELS-1:0][31:0] ch_control_o,
    output reg [NO_CHANNELS-1:0][31:0] ch_bw_cap_o,
    input      [NO_CHANNELS-1:0][31:0] ch_status_i,
    

    // Global Outputs (R/W)
    output reg  [31:0] int_enable_o,
    output reg  [31:0] sched_policy_o,
    
    // int_status_o is R/W1C 
    output reg  [31:0] int_status_o,
    input       [3:0]  hw_irq_i 
);

    // Memory Map
    localparam ADDR_CH_DESC_BASE   = 8'h00;  
    localparam ADDR_CH_CONTROL_BASE     = 8'h04;
    localparam ADDR_CH_BW_CAP_BASE      = 8'h08;  
    localparam ADDR_CH_STATUS_BASE      = 8'h0C;
    localparam CH_OFFSET                = 8'h10; // Offset between channels
    
    localparam ADDR_INT_STATUS     = 8'h40;
    localparam ADDR_INT_ENABLE     = 8'h44;
    localparam ADDR_SCHED_POLICY   = 8'h48;

    integer i, j;

    // Helper signals for handshaking
    wire       slv_reg_wren = s_axi_wready_o && s_axi_wvalid_i && s_axi_awready_o && s_axi_awvalid_i;
    wire       slv_reg_rden = s_axi_arready_o && s_axi_arvalid_i && ~s_axi_rvalid_o;
    wire [7:0] write_addr   = s_axi_awaddr_i[7:0];
    wire [7:0] read_addr    = s_axi_araddr_i[7:0];

    
    // 1. AXI4-Lite Write Control Signals
    
    always @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni)
            s_axi_awready_o <= 1'b0;
        else if (~s_axi_awready_o && s_axi_awvalid_i && s_axi_wvalid_i)
            s_axi_awready_o <= 1'b1;
        else
            s_axi_awready_o <= 1'b0;
    end

    // s_axi_wready_o
    always @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni)
            s_axi_wready_o <= 1'b0;
        else if (~s_axi_wready_o && s_axi_wvalid_i && s_axi_awvalid_i)
            s_axi_wready_o <= 1'b1;
        else
            s_axi_wready_o <= 1'b0;
    end

    // s_axi_bvalid_o (write response valid to CPU)
    always @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni)
            s_axi_bvalid_o <= 1'b0;
        else if (s_axi_awready_o && s_axi_awvalid_i && s_axi_wready_o && s_axi_wvalid_i && ~s_axi_bvalid_o)
            s_axi_bvalid_o <= 1'b1;
        else if (s_axi_bready_i && s_axi_bvalid_o)
            s_axi_bvalid_o <= 1'b0;
    end

    // s_axi_bresp_o (write response status to CPU)
    always @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni)
            s_axi_bresp_o <= 2'b00;
        else if (s_axi_awready_o && s_axi_awvalid_i && s_axi_wready_o && s_axi_wvalid_i && ~s_axi_bvalid_o)
            s_axi_bresp_o <= 2'b00;
    end

    // 2. Hardware Registers Write Logic 
    // ch_desc_addr_o (R/W)
    always @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni)
            for(i = 0; i < NO_CHANNELS; i = i + 1)
                ch_desc_addr_o[i] <= 32'h0;
        else if (slv_reg_wren) 
            for(i = 0; i < NO_CHANNELS; i = i + 1)
                if(write_addr == (i*CH_OFFSET + ADDR_CH_DESC_BASE))
                    ch_desc_addr_o[i] <= s_axi_wdata_i;
    end

    // ch_control_o (R/W)
    always @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni)
            for(i = 0; i < NO_CHANNELS; i = i + 1)
                ch_control_o[i] <= 32'h0;
        else if (slv_reg_wren) 
            for(i = 0; i < NO_CHANNELS; i = i + 1)
                if(write_addr == (i*CH_OFFSET + ADDR_CH_CONTROL_BASE)) begin
                    ch_control_o[i] <= s_axi_wdata_i;
                    if(s_axi_wdata_i[1] == 1'b1)
                        ch_control_o[i][2] <= 1'b0; // Resume is ignored if Abort is set
                end
    end

    // ch_bw_cap_o (R/W)
    always @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni)
            for(i = 0; i < NO_CHANNELS; i = i + 1)
                ch_bw_cap_o[i] <= 32'h0;
        else if (slv_reg_wren) 
            for(i = 0; i < NO_CHANNELS; i = i + 1)
                if(write_addr == (i*CH_OFFSET + ADDR_CH_BW_CAP_BASE))
                    ch_bw_cap_o[i] <= s_axi_wdata_i;
    end

    // int_enable_o (R/W) 
    always @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni)
            int_enable_o <= 32'h0;
        else if (slv_reg_wren && write_addr == ADDR_INT_ENABLE)
            int_enable_o <= s_axi_wdata_i;
    end

    // sched_policy_o (R/W) 
    always @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni)
            sched_policy_o <= 32'h0;
        else if (slv_reg_wren && write_addr == ADDR_SCHED_POLICY)
            sched_policy_o <= s_axi_wdata_i;
    end

    // int_status_o (R/W1C - Write 1 to Clear) 
    always @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
            int_status_o <= 32'h0;
        end else begin
            if (hw_irq_i[0]) int_status_o[0] <= 1'b1;
            if (hw_irq_i[1]) int_status_o[1] <= 1'b1;
            if (hw_irq_i[2]) int_status_o[2] <= 1'b1;
            if (hw_irq_i[3]) int_status_o[3] <= 1'b1;
            
            if (slv_reg_wren && write_addr == ADDR_INT_STATUS)
                int_status_o <= int_status_o & ~s_axi_wdata_i;
        end
    end
    
    // 3. AXI4-Lite Read Control Signals
    always @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni)
            s_axi_arready_o <= 1'b0;
        else if (~s_axi_arready_o && s_axi_arvalid_i)
            s_axi_arready_o <= 1'b1;
        else
            s_axi_arready_o <= 1'b0;
    end

    // s_axi_rvalid_o
    always @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni)
            s_axi_rvalid_o <= 1'b0;
        else if (slv_reg_rden)
            s_axi_rvalid_o <= 1'b1;
        else if (s_axi_rvalid_o && s_axi_rready_i)
            s_axi_rvalid_o <= 1'b0;
    end

    // s_axi_rresp_o
    always @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni)
            s_axi_rresp_o <= 2'b00;
        else if (slv_reg_rden)
            s_axi_rresp_o <= 2'b00;
    end

    // s_axi_rdata_o 
    always @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni)
            s_axi_rdata_o <= 32'h0; 
        else if (slv_reg_rden) begin
            s_axi_rdata_o <= 32'h0; // Default value
            if(read_addr == ADDR_INT_STATUS)
                s_axi_rdata_o <= int_status_o;
            else if(read_addr == ADDR_INT_ENABLE)
                s_axi_rdata_o <= int_enable_o;
            else if(read_addr == ADDR_SCHED_POLICY)
                s_axi_rdata_o <= sched_policy_o;
            else begin
            for(j = 0; j < NO_CHANNELS; j = j + 1)
                if(read_addr == (j*CH_OFFSET + ADDR_CH_DESC_BASE))
                    s_axi_rdata_o <= ch_desc_addr_o[j];
                else if(read_addr == (j*CH_OFFSET + ADDR_CH_CONTROL_BASE))
                    s_axi_rdata_o <= ch_control_o[j];
                else if(read_addr == (j*CH_OFFSET + ADDR_CH_BW_CAP_BASE))
                    s_axi_rdata_o <= ch_bw_cap_o[j];
                else if(read_addr == (j*CH_OFFSET + ADDR_CH_STATUS_BASE))
                    s_axi_rdata_o <= ch_status_i[j];
            end
        end     
    end
endmodule