module priority_arbiter (
    input               clk,
    input               rst_n,

    // Global scheduling policy
    input       [31:0]  sched_policy, // 0 = Fixed Priority, 1 = Round Robin

    // Requests from the 4 Channels
    input       [3:0]   ch_req,
    
    input       [31:0]  ch0_req_addr,
    input       [7:0]   ch0_req_len,
    input               ch0_req_is_write,

    input       [31:0]  ch1_req_addr,
    input       [7:0]   ch1_req_len,
    input               ch1_req_is_write, 

    input       [31:0]  ch2_req_addr,
    input       [7:0]   ch2_req_len,
    input               ch2_req_is_write,

    input       [31:0]  ch3_req_addr,
    input       [7:0]   ch3_req_len,
    input               ch3_req_is_write,

    // Grants sent back to the Channels
    output reg  [3:0]   ch_gnt,

    // Unified Request sent to the AXI-Full Master
    output reg          master_req_valid,
    output reg  [31:0]  master_req_addr,
    output reg  [7:0]   master_req_len,
    output reg          master_req_is_write,
    input               master_req_ready
);

    reg  [1:0]  last_gnt;       // Remembers who got the bus last time for Round-Robin
    reg  [3:0]  fixed_gnt;      // Winner if we use Fixed Priority
    reg  [3:0]  rr_gnt;         // Winner if we use Round-Robin
    reg  [3:0]  selected_gnt;   // The final winner based on policy

    // Winner for Fixed Priority (CH0 > CH1 > CH2 > CH3)
    always @(*) begin
        fixed_gnt = 4'b0000;
        if (ch_req[0])                  fixed_gnt = 4'b0001;        else 
        if (ch_req[1])                  fixed_gnt = 4'b0010;        else 
        if (ch_req[2])                  fixed_gnt = 4'b0100;        else 
        if (ch_req[3])                  fixed_gnt = 4'b1000;
    end

    // Winner for Round-Robin
    always @(*) begin
        rr_gnt = 4'b0000;
        if (last_gnt == 2'd0) begin
            if (ch_req[1])              rr_gnt = 4'b0010;           else 
            if (ch_req[2])              rr_gnt = 4'b0100;           else 
            if (ch_req[3])              rr_gnt = 4'b1000;           else 
            if (ch_req[0])              rr_gnt = 4'b0001;
        end 
                                                                    else 
        if (last_gnt == 2'd1) begin
            if (ch_req[2])              rr_gnt = 4'b0100;           else 
            if (ch_req[3])              rr_gnt = 4'b1000;           else 
            if (ch_req[0])              rr_gnt = 4'b0001;           else 
            if (ch_req[1])              rr_gnt = 4'b0010;
        end 
                                                                    else 
        if (last_gnt == 2'd2) begin
            if (ch_req[3])              rr_gnt = 4'b1000;           else 
            if (ch_req[0])              rr_gnt = 4'b0001;           else 
            if (ch_req[1])              rr_gnt = 4'b0010;           else 
            if (ch_req[2])              rr_gnt = 4'b0100;
        end 
                                                                    else 
        if (last_gnt == 2'd3) begin
            if (ch_req[0])              rr_gnt = 4'b0001;           else 
            if (ch_req[1])              rr_gnt = 4'b0010;           else 
            if (ch_req[2])              rr_gnt = 4'b0100;           else 
            if (ch_req[3])              rr_gnt = 4'b1000;
        end
    end

    // Final winner based on global policy
    always @(*) begin
        if (sched_policy == 32'd0)      selected_gnt = fixed_gnt;   else 
                                        selected_gnt = rr_gnt;
    end

    // Update last_gnt when a request is accepted
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)                     last_gnt <= 2'd0;           else 
        if (master_req_valid && 
            master_req_ready) begin
            if (selected_gnt[0])        last_gnt <= 2'd0;           else 
            if (selected_gnt[1])        last_gnt <= 2'd1;           else 
            if (selected_gnt[2])        last_gnt <= 2'd2;           else 
            if (selected_gnt[3])        last_gnt <= 2'd3;
        end
    end

    // Assert the grant signal to the winning channel
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)                     ch_gnt <= 4'b0000;          else 
        if (master_req_valid && 
            master_req_ready)           ch_gnt <= selected_gnt;     else 
                                        ch_gnt <= 4'b0000;
    end

    // Send data to the Master based on the winner
    always @(*) begin
        if (selected_gnt != 4'b0000)    master_req_valid = 1'b1;    else 
                                        master_req_valid = 1'b0;
    end

    always @(*) begin
        master_req_addr = 32'h00000000;
        if (selected_gnt[0])            master_req_addr = ch0_req_addr; else 
        if (selected_gnt[1])            master_req_addr = ch1_req_addr; else 
        if (selected_gnt[2])            master_req_addr = ch2_req_addr; else 
        if (selected_gnt[3])            master_req_addr = ch3_req_addr;
    end

    always @(*) begin
        master_req_len = 8'h00;
        if (selected_gnt[0])            master_req_len = ch0_req_len;   else 
        if (selected_gnt[1])            master_req_len = ch1_req_len;   else 
        if (selected_gnt[2])            master_req_len = ch2_req_len;   else 
        if (selected_gnt[3])            master_req_len = ch3_req_len;
    end

    always @(*) begin
        master_req_is_write = 1'b0;
        if (selected_gnt[0])            master_req_is_write = ch0_req_is_write; else 
        if (selected_gnt[1])            master_req_is_write = ch1_req_is_write; else 
        if (selected_gnt[2])            master_req_is_write = ch2_req_is_write; else 
        if (selected_gnt[3])            master_req_is_write = ch3_req_is_write;
    end

endmodule