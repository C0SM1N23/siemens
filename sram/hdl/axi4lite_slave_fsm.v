// =============================================================================
//
// AXI4-Lite slave FSM, must be instantiated twice for the two top-level ports
// One transaction at a time
// The stall signal comes from the collision arbitration module and blocks
// transactions (holds the ready signals low)
// Read has priority over write
//
// =============================================================================

module axi4lite_slave_fsm #(
    parameter ADDR_W = 10   // address width
) (
    // clock and reset
    input  wire              clk_i,
    input  wire              rst_n_i,

    // write address
    input  wire [ADDR_W-1:0] awaddr_i,   // write address
    input  wire               awvalid_i, // address is valid
    output wire               awready_o, // can accept the address

    // write data
    input  wire [31:0]        wdata_i,   // data to write
    input  wire [3:0]         wstrb_i,   // which byte
    input  wire                wvalid_i, // write data received is valid
    output wire                wready_o, // can accept data

    // write response
    output wire [1:0]         bresp_o,
    output wire                bvalid_o,
    input  wire                bready_i, // response can be taken

    // read address
    input  wire [ADDR_W-1:0]  araddr_i,  // read address
    input  wire                arvalid_i,// araddr is valid
    output wire                arready_o,// can accept araddr

    // read data
    output wire [31:0]        rdata_o,   // data read
    output wire [1:0]         rresp_o,
    output wire                rvalid_o, // rdata/rresp are valid
    input  wire                rready_i, // master is ready to take the data

    // Backend (collision arbiter and memory)
    output wire [ADDR_W-1:0]  mem_addr_o,  // request address for backend
    output wire                mem_write_o, // 1-write 0-read
    output wire [31:0]        mem_wdata_o, // write data for backend
    output wire [3:0]         mem_wstrb_o,
    output wire                mem_valid_o, // 1-there is an active request
    input  wire                mem_error_i, // 1-SLVERR 0-OKAY
    input  wire [31:0]        mem_rdata_i, // data read
    input  wire                stall_i      // stall signal
);

    localparam [1:0] RESP_OKAY   = 2'b00;
    localparam [1:0] RESP_SLVERR = 2'b10;

    // fsm states
    localparam [1:0] S_IDLE    = 2'd0;
    localparam [1:0] S_WR_RESP = 2'd1;
    localparam [1:0] S_RD_RESP = 2'd2;

    reg [1:0] state;
    reg [1:0] next_state;

    reg aw_have; // write address register available
    reg w_have;  // write data available

    reg [ADDR_W-1:0] awaddr_reg;
    reg [31:0]       wdata_reg;
    reg [3:0]        wstrb_reg;
    reg [ADDR_W-1:0] araddr_reg;

    wire aw_done = aw_have | awready_o;
    wire w_done  = w_have  | wready_o;

    // transition logic
    always @(*) begin
        case (state)
            S_IDLE: begin
                if (stall_i)
                    next_state = S_IDLE;
                else if (aw_done && w_done)
                    next_state = S_WR_RESP; // write requested
                else if (arvalid_i && !aw_have && !w_have)
                    next_state = S_RD_RESP; // read requested
                else
                    next_state = S_IDLE;
            end
            S_WR_RESP: begin
                next_state = bready_i ? S_IDLE : S_WR_RESP;
            end
            S_RD_RESP: begin
                next_state = rready_i ? S_IDLE : S_RD_RESP;
            end
            default: begin
                next_state = S_IDLE;
            end
        endcase
    end

    // advance to next state
    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i)
            state <= S_IDLE;
        else
            state <= next_state;
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i)
            aw_have <= 1'b0;
        else if (state == S_WR_RESP && bready_i)
            aw_have <= 1'b0;
        else if (awready_o)
            aw_have <= 1'b1;
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i)
            w_have <= 1'b0;
        else if (state == S_WR_RESP && bready_i)
            w_have <= 1'b0;
        else if (wready_o)
            w_have <= 1'b1;
    end

    // latch address value
    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i)
            awaddr_reg <= {ADDR_W{1'b0}};
        else if (awready_o)
            awaddr_reg <= awaddr_i;
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i)
            wdata_reg <= 32'd0;
        else if (wready_o)
            wdata_reg <= wdata_i;
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i)
            wstrb_reg <= 4'd0;
        else if (wready_o)
            wstrb_reg <= wstrb_i;
    end

    always @(posedge clk_i or negedge rst_n_i) begin
        if (~rst_n_i)
            araddr_reg <= {ADDR_W{1'b0}};
        else if (state == S_IDLE && arvalid_i && !aw_have && !w_have && !stall_i)
            araddr_reg <= araddr_i;
    end

    // handshake signals
    assign awready_o = (state == S_IDLE) && awvalid_i && !aw_have && !stall_i;
    assign wready_o  = (state == S_IDLE) && wvalid_i  && !w_have  && !stall_i;
    assign arready_o = (state == S_IDLE) && arvalid_i && !aw_have && !w_have && !stall_i;

    assign bvalid_o  = (state == S_WR_RESP);
    assign bresp_o   = mem_error_i ? RESP_SLVERR : RESP_OKAY;

    assign rvalid_o  = (state == S_RD_RESP);
    assign rdata_o   = mem_rdata_i;
    assign rresp_o   = mem_error_i ? RESP_SLVERR : RESP_OKAY;

    // signals for collision arbiter and memory
    assign mem_valid_o = (state == S_WR_RESP) || (state == S_RD_RESP);
    assign mem_write_o = (state == S_WR_RESP);
    assign mem_addr_o  = (state == S_RD_RESP) ? araddr_reg : awaddr_reg;
    assign mem_wdata_o = wdata_reg;
    assign mem_wstrb_o = wstrb_reg;

endmodule
