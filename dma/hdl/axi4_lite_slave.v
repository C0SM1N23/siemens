module axi4_lite_slave (
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
    output reg  [31:0] ch0_desc_addr,
    output reg  [31:0] ch0_control,
    output reg  [31:0] ch0_bw_cap,
    // CH0 Inputs (RO)
    input       [31:0] ch0_status_in,

    // CH1 Outputs (R/W)
    output reg  [31:0] ch1_desc_addr,
    output reg  [31:0] ch1_control,
    output reg  [31:0] ch1_bw_cap,
    // CH1 Inputs (RO)
    input       [31:0] ch1_status_in,

    // CH2 Outputs (R/W)
    output reg  [31:0] ch2_desc_addr,
    output reg  [31:0] ch2_control,
    output reg  [31:0] ch2_bw_cap,
    // CH2 Inputs (RO)
    input       [31:0] ch2_status_in,

    // CH3 Outputs (R/W)
    output reg  [31:0] ch3_desc_addr,
    output reg  [31:0] ch3_control,
    output reg  [31:0] ch3_bw_cap,
    // CH3 Inputs (RO)
    input       [31:0] ch3_status_in,

    // Global Outputs (R/W)
    output reg  [31:0] int_enable,
    output reg  [31:0] sched_policy,
    
    // INT_STATUS is R/W1C 
    output reg  [31:0] int_status,
    input       [3:0]  hw_irq_in 
);

    // Memory Map
    localparam ADDR_CH0_DESC_ADDR = 8'h00;  localparam ADDR_CH0_CONTROL = 8'h04;
    localparam ADDR_CH0_BW_CAP    = 8'h08;  localparam ADDR_CH0_STATUS  = 8'h0C;
    localparam ADDR_CH1_DESC_ADDR = 8'h10;  localparam ADDR_CH1_CONTROL = 8'h14;
    localparam ADDR_CH1_BW_CAP    = 8'h18;  localparam ADDR_CH1_STATUS  = 8'h1C;
    localparam ADDR_CH2_DESC_ADDR = 8'h20;  localparam ADDR_CH2_CONTROL = 8'h24;
    localparam ADDR_CH2_BW_CAP    = 8'h28;  localparam ADDR_CH2_STATUS  = 8'h2C;
    localparam ADDR_CH3_DESC_ADDR = 8'h30;  localparam ADDR_CH3_CONTROL = 8'h34;
    localparam ADDR_CH3_BW_CAP    = 8'h38;  localparam ADDR_CH3_STATUS  = 8'h3C;
    
    localparam ADDR_INT_STATUS    = 8'h40;
    localparam ADDR_INT_ENABLE    = 8'h44;
    localparam ADDR_SCHED_POLICY  = 8'h48;

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
    

    // CH0_DESC_ADDR (R/W)
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            ch0_desc_addr <= 32'h0;
        else if (slv_reg_wren && write_addr == ADDR_CH0_DESC_ADDR)
            ch0_desc_addr <= s_axi_wdata;
    end

    // CH0_CONTROL (R/W) 
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            ch0_control <= 32'h0;
        else if (slv_reg_wren && write_addr == ADDR_CH0_CONTROL)
            ch0_control <= s_axi_wdata;
    end

    // CH0_BW_CAP (R/W) 
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            ch0_bw_cap <= 32'h0;
        else if (slv_reg_wren && write_addr == ADDR_CH0_BW_CAP)
            ch0_bw_cap <= s_axi_wdata;
    end

    // CH1_DESC_ADDR (R/W) 
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            ch1_desc_addr <= 32'h0;
        else if (slv_reg_wren && write_addr == ADDR_CH1_DESC_ADDR)
            ch1_desc_addr <= s_axi_wdata;
    end

    // CH1_CONTROL (R/W) 
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            ch1_control <= 32'h0;
        else if (slv_reg_wren && write_addr == ADDR_CH1_CONTROL)
            ch1_control <= s_axi_wdata;
    end

    // CH1_BW_CAP (R/W) 
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            ch1_bw_cap <= 32'h0;
        else if (slv_reg_wren && write_addr == ADDR_CH1_BW_CAP)
            ch1_bw_cap <= s_axi_wdata;
    end

    // CH2_DESC_ADDR (R/W) 
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            ch2_desc_addr <= 32'h0;
        else if (slv_reg_wren && write_addr == ADDR_CH2_DESC_ADDR)
            ch2_desc_addr <= s_axi_wdata;
    end

    // CH2_CONTROL (R/W) 
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            ch2_control <= 32'h0;
        else if (slv_reg_wren && write_addr == ADDR_CH2_CONTROL)
            ch2_control <= s_axi_wdata;
    end

    // CH2_BW_CAP (R/W) 
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            ch2_bw_cap <= 32'h0;
        else if (slv_reg_wren && write_addr == ADDR_CH2_BW_CAP)
            ch2_bw_cap <= s_axi_wdata;
    end

    // CH3_DESC_ADDR (R/W) 
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            ch3_desc_addr <= 32'h0;
        else if (slv_reg_wren && write_addr == ADDR_CH3_DESC_ADDR)
            ch3_desc_addr <= s_axi_wdata;
    end

    // CH3_CONTROL (R/W) 
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            ch3_control <= 32'h0;
        else if (slv_reg_wren && write_addr == ADDR_CH3_CONTROL)
            ch3_control <= s_axi_wdata;
    end

    // CH3_BW_CAP (R/W) 
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            ch3_bw_cap <= 32'h0;
        else if (slv_reg_wren && write_addr == ADDR_CH3_BW_CAP)
            ch3_bw_cap <= s_axi_wdata;
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
        else if (slv_reg_rden) 
            case (read_addr)
                ADDR_CH0_DESC_ADDR: s_axi_rdata <= ch0_desc_addr;
                ADDR_CH0_CONTROL:   s_axi_rdata <= ch0_control;
                ADDR_CH0_BW_CAP:    s_axi_rdata <= ch0_bw_cap;
                ADDR_CH0_STATUS:    s_axi_rdata <= ch0_status_in; 

                ADDR_CH1_DESC_ADDR: s_axi_rdata <= ch1_desc_addr;
                ADDR_CH1_CONTROL:   s_axi_rdata <= ch1_control;
                ADDR_CH1_BW_CAP:    s_axi_rdata <= ch1_bw_cap;
                ADDR_CH1_STATUS:    s_axi_rdata <= ch1_status_in;

                ADDR_CH2_DESC_ADDR: s_axi_rdata <= ch2_desc_addr;
                ADDR_CH2_CONTROL:   s_axi_rdata <= ch2_control; 
                ADDR_CH2_BW_CAP:    s_axi_rdata <= ch2_bw_cap;
                ADDR_CH2_STATUS:    s_axi_rdata <= ch2_status_in;

                ADDR_CH3_DESC_ADDR: s_axi_rdata <= ch3_desc_addr;
                ADDR_CH3_CONTROL:   s_axi_rdata <= ch3_control;
                ADDR_CH3_BW_CAP:    s_axi_rdata <= ch3_bw_cap;
                ADDR_CH3_STATUS:    s_axi_rdata <= ch3_status_in;
                
                ADDR_INT_STATUS:    s_axi_rdata <= int_status;
                ADDR_INT_ENABLE:    s_axi_rdata <= int_enable;
                ADDR_SCHED_POLICY:  s_axi_rdata <= sched_policy;
                
                default:            s_axi_rdata <= 32'h0;
            endcase
    end

endmodule