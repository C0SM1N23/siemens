module dma_channel (
    input               clk,
    input               rst_n,

    // Register File configuration inputs
    input       [31:0]  desc_addr_in,
    input       [31:0]  control_in,
    input       [31:0]  bw_cap_in,
    
    // Status and Interrupt outputs
    output reg  [31:0]  status_out,
    output reg          irq_out,

    // Priority Arbiter interface
    output reg          req_valid,
    output reg  [31:0]  req_addr,
    output reg  [7:0]   req_len,
    output reg          req_is_write,
    input               arb_gnt,

    // Master execution feedback
    input               burst_done,
    input               axi_error,
    input       [31:0]  fetch_data_in,
    input               fetch_data_valid
);

    // FSM State encoding
    localparam STATE_IDLE       = 3'd0;
    localparam STATE_FETCHING   = 3'd1;
    localparam STATE_ACTIVE     = 3'd2;
    localparam STATE_SUSPENDED  = 3'd3;
    localparam STATE_DONE       = 3'd4;
    localparam STATE_ERROR      = 3'd5;

    // Control bits decoding
    wire enable = control_in[0];
    wire abort  = control_in[1];
    wire resume = control_in[2];

    // Bandwidth configuration decoding
    wire [15:0] refill_rate = bw_cap_in[15:0];
    wire [15:0] max_tokens  = bw_cap_in[31:16];

    // Internal registers
    reg  [2:0]  state;
    reg  [7:0]  window_timer;
    reg  [15:0] token_bucket;
    wire        has_tokens  = (token_bucket >= 16'd8); // Require enough tokens for a burst

    // Descriptor Internal Registers
    reg  [31:0] desc_src;
    reg  [31:0] desc_dst;
    reg  [31:0] desc_len;
    reg  [31:0] desc_ctrl;
    reg  [2:0]  fetch_word_cnt;
    reg         active_is_write;

    // 1. Bandwidth Throttling Logic
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)                     window_timer <= 8'h00;                  else 
        if (window_timer == 8'd99)      window_timer <= 8'h00;                  else 
                                        window_timer <= window_timer + 1'b1;
    end

    // Token bucket counter
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)                     token_bucket <= 16'h0000;               else 
        if (window_timer == 8'd99)
            if (token_bucket + refill_rate > max_tokens)
                                        token_bucket <= max_tokens;             else
                                        token_bucket <= token_bucket + refill_rate;
        else 
        if (req_valid && arb_gnt)       token_bucket <= token_bucket - 16'd8; // Spent tokens
    end

    // 2. Descriptor Fetching and Execution Logic
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)                     fetch_word_cnt <= 3'd0;                 else 
        if (state == STATE_IDLE)        fetch_word_cnt <= 3'd0;                 else 
        if (state == STATE_FETCHING && 
            fetch_data_valid && arb_gnt) 
                                        fetch_word_cnt <= fetch_word_cnt + 1'b1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)                     desc_src <= 32'h0;                      else 
        if (state == STATE_FETCHING && fetch_data_valid && arb_gnt && fetch_word_cnt == 3'd0) 
                                        desc_src <= fetch_data_in;              else 
        if (state == STATE_ACTIVE && burst_done && active_is_write)
                                        desc_src <= desc_src + 32'd32; // Advance 8 words
    end

    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)                     desc_dst <= 32'h0;                      else 
        if (state == STATE_FETCHING && fetch_data_valid && arb_gnt && fetch_word_cnt == 3'd1) 
                                        desc_dst <= fetch_data_in;              else 
        if (state == STATE_ACTIVE && burst_done && active_is_write)
                                        desc_dst <= desc_dst + 32'd32; 
    end

    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)                     desc_len <= 32'h0;                      else 
        if (state == STATE_FETCHING && fetch_data_valid && arb_gnt && fetch_word_cnt == 3'd2) 
                                        desc_len <= fetch_data_in;              else 
        if (state == STATE_ACTIVE && burst_done && active_is_write)
            if (desc_len >= 32'd32)     desc_len <= desc_len - 32'd32;          else
                                        desc_len <= 32'd0;
    end

    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)                     desc_ctrl <= 32'h0;                     else 
        if (state == STATE_FETCHING && fetch_data_valid && arb_gnt && fetch_word_cnt == 3'd3) 
                                        desc_ctrl <= fetch_data_in;
    end

    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)                     active_is_write <= 1'b0;                else 
        if (state == STATE_FETCHING)    active_is_write <= 1'b0;                else 
        if (state == STATE_ACTIVE && burst_done) 
            if (active_is_write)        active_is_write <= 1'b0;                else 
                                        active_is_write <= 1'b1;
    end

    // 3. FSM
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)                     state <= STATE_IDLE;                    else 
        case (state)
            STATE_IDLE: begin
                if (enable)             state <= STATE_FETCHING;
            end
            
            STATE_FETCHING: begin
                if (axi_error)          state <= STATE_ERROR;                   else 
                if (burst_done) begin
                    if (abort)          state <= STATE_SUSPENDED;               else 
                                        state <= STATE_ACTIVE;
                end
            end
            
            STATE_ACTIVE: begin
                if (axi_error)          state <= STATE_ERROR;                   else
                if (burst_done) begin
                    if (abort)          state <= STATE_SUSPENDED;               else 
                    if (desc_len <= 32'd32 && desc_ctrl[0])
                                        state <= STATE_DONE;
                end
            end
            
            STATE_SUSPENDED: begin
                if (resume)             state <= STATE_FETCHING;
            end
            
            STATE_DONE: begin
                if (~enable)            state <= STATE_IDLE; // Clear state
            end
            
            STATE_ERROR: begin
                if (~enable)            state <= STATE_IDLE; // Clear state
            end
            
            default:                    state <= STATE_IDLE;
        endcase
    end

    // 4. Arbiter Request Logic
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)                     req_valid <= 1'b0;                      else 
        if (state == STATE_FETCHING && 
            has_tokens && ~arb_gnt)     req_valid <= 1'b1;                      else 
        if (state == STATE_ACTIVE && 
            has_tokens && ~arb_gnt)     req_valid <= 1'b1;                      else 
        if (arb_gnt)                    req_valid <= 1'b0;
    end

    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)                     req_is_write <= 1'b0;                   else 
        if (state == STATE_FETCHING)    req_is_write <= 1'b0;                   else 
        if (state == STATE_ACTIVE)      req_is_write <= active_is_write; 
    end

    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)                     req_len <= 8'h00;                       else 
        if (state == STATE_FETCHING)    req_len <= 8'h07; /* Burst of 8 */      else 
        if (state == STATE_ACTIVE)      req_len <= 8'h07;
    end

    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)                     req_addr <= 32'h00000000;               else 
        if (state == STATE_FETCHING)    req_addr <= desc_addr_in;               else   
        if (state == STATE_ACTIVE)
            if (active_is_write)        req_addr <= desc_dst;                   else 
                                        req_addr <= desc_src;
    end

    // 5. Status and Interrupts
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)                     status_out <= 32'h00000000;             else 
                                        status_out <= {29'd0, state};
    end

    // Interrupt asserted on completion or error 
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)                     irq_out <= 1'b0;                        else 
        if (state == STATE_DONE || 
            state == STATE_ERROR)       irq_out <= 1'b1;                        else 
        if (~enable)                    irq_out <= 1'b0;
    end

endmodule