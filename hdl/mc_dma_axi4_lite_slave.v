module mc_dma_axi4_lite_slave #(parameter NO_CHANNELS = 4) (
    input               clk,
    input               rst_n, 

    // AXI4-Lite Slave Interface
    // Write Address Channel
    input       [31:0] s_axi_awaddr,
    input              s_axi_awvalid,
    output reg         s_axi_awready,
    
    // Write Data Channel
    input       [31:0] s_axi_wdata,
    input       [3:0]  s_axi_wstrb,
    input              s_axi_wvalid,
    output reg         s_axi_wready,
    
    // Write Response Channel
    output reg  [1:0]  s_axi_bresp,
    output reg         s_axi_bvalid,
    input              s_axi_bready,
    
    // Read Address Channel
    input       [31:0] s_axi_araddr,
    input              s_axi_arvalid,
    output reg         s_axi_arready,
    
    // Read Data Channel
    output reg  [31:0] s_axi_rdata,
    output reg  [1:0]  s_axi_rresp,
    output reg         s_axi_rvalid,
    input              s_axi_rready,

    // Internal Interface to DMA Channels
    // CH0 Outputs (R/W)
    output reg [NO_CHANNELS-1:0][31:0] ch_desc_addr,
    output reg [NO_CHANNELS-1:0][31:0] ch_control,
    output reg [NO_CHANNELS-1:0][31:0] ch_bw_cap,
    input      [NO_CHANNELS-1:0][31:0] ch_status_in,
    

    // Global Outputs (R/W)
    output reg  [31:0] int_enable,
    output reg  [31:0] sched_policy,
    
    // INT_STATUS is R/W1C 
    output reg  [31:0] int_status,
    input       [3:0]  hw_irq_in 
);

    // Memory Map
    localparam ADDR_CH_DESC_ADDR_BASE   = 8'h00;  
    localparam ADDR_CH_CONTROL_BASE     = 8'h04;
    localparam ADDR_CH_BW_CAP_BASE      = 8'h08;  
    localparam ADDR_CH_STATUS_BASE      = 8'h0C;
    localparam CH_OFFSET                = 8'h10; // Offset between channels
    
    localparam ADDR_INT_STATUS    = 8'h40;
    localparam ADDR_INT_ENABLE    = 8'h44;
    localparam ADDR_SCHED_POLICY  = 8'h48;

    integer i, j;

    // Helper signals for handshaking
    wire       slv_reg_wren = s_axi_wready && s_axi_wvalid && s_axi_awready && s_axi_awvalid;
    wire       slv_reg_rden = s_axi_arready && s_axi_arvalid && ~s_axi_rvalid;
    wire [7:0] write_addr   = s_axi_awaddr[7:0];
    wire [7:0] read_addr    = s_axi_araddr[7:0];

    
    // 1. AXI4-Lite Write Control Signals
    
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            s_axi_awready <= 1'b0;
        else if (~s_axi_awready && s_axi_awvalid && s_axi_wvalid)
            s_axi_awready <= 1'b1;
        else
            s_axi_awready <= 1'b0;
    end

    // s_axi_wready
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            s_axi_wready <= 1'b0;
        else if (~s_axi_wready && s_axi_wvalid && s_axi_awvalid)
            s_axi_wready <= 1'b1;
        else
            s_axi_wready <= 1'b0;
    end

    // s_axi_bvalid (write response valid to CPU)
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            s_axi_bvalid <= 1'b0;
        else if (s_axi_awready && s_axi_awvalid && s_axi_wready && s_axi_wvalid && ~s_axi_bvalid)
            s_axi_bvalid <= 1'b1;
        else if (s_axi_bready && s_axi_bvalid)
            s_axi_bvalid <= 1'b0;
    end

    // s_axi_bresp (write response status to CPU)
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            s_axi_bresp <= 2'b00;
        else if (s_axi_awready && s_axi_awvalid && s_axi_wready && s_axi_wvalid && ~s_axi_bvalid)
            s_axi_bresp <= 2'b00;
    end

    // 2. Hardware Registers Write Logic 
    // CH_DESC_ADDR (R/W)
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            for(i = 0; i < NO_CHANNELS; i = i + 1)
                ch_desc_addr[i] <= 32'h0;
        else if (slv_reg_wren) 
            for(i = 0; i < NO_CHANNELS; i = i + 1)
                if(write_addr == (i*CH_OFFSET + ADDR_CH_DESC_ADDR_BASE))
                    ch_desc_addr[i] <= s_axi_wdata;
    end

    // CH_CONTROL (R/W)
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            for(i = 0; i < NO_CHANNELS; i = i + 1)
                ch_control[i] <= 32'h0;
        else if (slv_reg_wren) 
            for(i = 0; i < NO_CHANNELS; i = i + 1)
                if(write_addr == (i*CH_OFFSET + ADDR_CH_CONTROL_BASE)) begin
                    ch_control[i] <= s_axi_wdata;
                    if(s_axi_wdata[1] == 1'b1)
                        ch_control[i][2] <= 1'b0; // Resume is ignored if Abort is set
                end
    end

    // CH_BW_CAP (R/W)
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            for(i = 0; i < NO_CHANNELS; i = i + 1)
                ch_bw_cap[i] <= 32'h0;
        else if (slv_reg_wren) 
            for(i = 0; i < NO_CHANNELS; i = i + 1)
                if(write_addr == (i*CH_OFFSET + ADDR_CH_BW_CAP_BASE))
                    ch_bw_cap[i] <= s_axi_wdata;
    end

    // INT_ENABLE (R/W) 
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            int_enable <= 32'h0;
        else if (slv_reg_wren && write_addr == ADDR_INT_ENABLE)
            int_enable <= s_axi_wdata;
    end

    // SCHED_POLICY (R/W) 
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            sched_policy <= 32'h0;
        else if (slv_reg_wren && write_addr == ADDR_SCHED_POLICY)
            sched_policy <= s_axi_wdata;
    end

    // INT_STATUS (R/W1C - Write 1 to Clear) 
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n) begin
            int_status <= 32'h0;
        end else begin
            if (hw_irq_in[0]) int_status[0] <= 1'b1;
            if (hw_irq_in[1]) int_status[1] <= 1'b1;
            if (hw_irq_in[2]) int_status[2] <= 1'b1;
            if (hw_irq_in[3]) int_status[3] <= 1'b1;
            
            if (slv_reg_wren && write_addr == ADDR_INT_STATUS)
                int_status <= int_status & ~s_axi_wdata;
        end
    end
    
    // 3. AXI4-Lite Read Control Signals
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            s_axi_arready <= 1'b0;
        else if (~s_axi_arready && s_axi_arvalid)
            s_axi_arready <= 1'b1;
        else
            s_axi_arready <= 1'b0;
    end

    // s_axi_rvalid
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            s_axi_rvalid <= 1'b0;
        else if (slv_reg_rden)
            s_axi_rvalid <= 1'b1;
        else if (s_axi_rvalid && s_axi_rready)
            s_axi_rvalid <= 1'b0;
    end

    // s_axi_rresp
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            s_axi_rresp <= 2'b00;
        else if (slv_reg_rden)
            s_axi_rresp <= 2'b00;
    end

    // s_axi_rdata 
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            s_axi_rdata <= 32'h0; 
        else if (slv_reg_rden) begin
            s_axi_rdata <= 32'h0; // Default value
            if(read_addr == ADDR_INT_STATUS)
                s_axi_rdata <= int_status;
            else if(read_addr == ADDR_INT_ENABLE)
                s_axi_rdata <= int_enable;
            else if(read_addr == ADDR_SCHED_POLICY)
                s_axi_rdata <= sched_policy;
            else begin
            for(j = 0; j < NO_CHANNELS; j = j + 1)
                if(read_addr == (j*CH_OFFSET + ADDR_CH_DESC_ADDR_BASE))
                    s_axi_rdata <= ch_desc_addr[j];
                else if(read_addr == (j*CH_OFFSET + ADDR_CH_CONTROL_BASE))
                    s_axi_rdata <= ch_control[j];
                else if(read_addr == (j*CH_OFFSET + ADDR_CH_BW_CAP_BASE))
                    s_axi_rdata <= ch_bw_cap[j];
                else if(read_addr == (j*CH_OFFSET + ADDR_CH_STATUS_BASE))
                    s_axi_rdata <= ch_status_in[j];
            end
        end     
    end
endmodule