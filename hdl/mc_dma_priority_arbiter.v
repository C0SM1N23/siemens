module mc_dma_priority_arbiter (
    input               clk,
    input               rst_n,

    // Global scheduling policy
    input       [31:0]  sched_policy, // 0 = Fixed Priority, 1 = Round Robin

    // Requests from the 4 Channels
    input       [3:0]   ch_req,
    
    input [3:0] [31:0] ch_req_addr,
    input [3:0] [7:0]  ch_req_len,
    input [3:0]        ch_req_is_write,

    // Grants sent back to the Channels
    output reg  [3:0]   ch_gnt,

    // Unified Request sent to the AXI-Full Master
    output reg          master_req_valid,
    output reg  [31:0]  master_req_addr,
    output reg  [7:0]   master_req_len,
    output reg          master_req_is_write,
    // FIX BUG 2: identitatea canalului caruia ii apartine cererea curenta.
    // Master-ul foloseste acest ID pentru a izola datele fiecarui canal in
    // propriul "sertar" din data_fifo, in loc sa foloseasca un singur buffer
    // global partajat (vezi axi4_full_master.v).
    output reg  [1:0]   master_req_ch_id,
    input               master_req_ready
);

    reg  [1:0]  last_gnt;       
    reg  [3:0]  fixed_gnt;      
    reg  [3:0]  rr_gnt;         
    reg  [3:0]  selected_gnt;   

    // 1. Winner for Fixed Priority
    always @(*) begin
        fixed_gnt = 4'b0000;
        if (ch_req[0])
            fixed_gnt = 4'b0001;
        else if (ch_req[1])
            fixed_gnt = 4'b0010;
        else if (ch_req[2])
            fixed_gnt = 4'b0100;
        else if (ch_req[3])
            fixed_gnt = 4'b1000;
    end

    // 2. Winner for Round-Robin
    always @(*) begin
        rr_gnt = 4'b0000;
        if (last_gnt == 2'd0) begin
            if (ch_req[1])
                rr_gnt = 4'b0010;
            else if (ch_req[2])
                rr_gnt = 4'b0100;
            else if (ch_req[3])
                rr_gnt = 4'b1000;
            else if (ch_req[0])
                rr_gnt = 4'b0001;
        end else if (last_gnt == 2'd1) begin
            if (ch_req[2])
                rr_gnt = 4'b0100;
            else if (ch_req[3])
                rr_gnt = 4'b1000;
            else if (ch_req[0])
                rr_gnt = 4'b0001;
            else if (ch_req[1])
                rr_gnt = 4'b0010;
        end else if (last_gnt == 2'd2) begin
            if (ch_req[3])
                rr_gnt = 4'b1000;
            else if (ch_req[0])
                rr_gnt = 4'b0001;
            else if (ch_req[1])
                rr_gnt = 4'b0010;
            else if (ch_req[2])
                rr_gnt = 4'b0100;
        end else if (last_gnt == 2'd3) begin
            if (ch_req[0])
                rr_gnt = 4'b0001;
            else if (ch_req[1])
                rr_gnt = 4'b0010;
            else if (ch_req[2])
                rr_gnt = 4'b0100;
            else if (ch_req[3])
                rr_gnt = 4'b1000;
        end
    end

    // 3. Final winner based on global policy
    always @(*) begin
        if (sched_policy == 32'd0)
            selected_gnt = fixed_gnt;
        else
            selected_gnt = rr_gnt;
    end

    // 4. Update last_gnt when a request is accepted
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n) begin
            last_gnt <= 2'd3;
        end else if (master_req_valid && master_req_ready) begin
            if (selected_gnt[0])
                last_gnt <= 2'd0;
            else if (selected_gnt[1])
                last_gnt <= 2'd1;
            else if (selected_gnt[2])
                last_gnt <= 2'd2;
            else if (selected_gnt[3])
                last_gnt <= 2'd3;
        end
    end

    // 5. Assert the grant signal to the winning channel
    always @(posedge clk or negedge rst_n) begin
        if (~rst_n)
            ch_gnt <= 4'b0000;
        else if (master_req_valid && master_req_ready)
            ch_gnt <= selected_gnt;
        else
            ch_gnt <= 4'b0000;
    end

    // 6. Send data to the Master based on the winner
    always @(*) begin
        if (selected_gnt != 4'b0000)
            master_req_valid = 1'b1;
        else
            master_req_valid = 1'b0;
    end

    always @(*) begin
        master_req_addr     = 32'h00000000;
        master_req_len      = 8'h00;
        master_req_is_write = 1'b0;
        master_req_ch_id    = 2'd0;

        if (selected_gnt[0]) begin
            master_req_addr     = ch_req_addr[0];
            master_req_len      = ch_req_len[0];
            master_req_is_write = ch_req_is_write[0];
            master_req_ch_id    = 2'd0;
        end
        else if (selected_gnt[1]) begin
            master_req_addr     = ch_req_addr[1];
            master_req_len      = ch_req_len[1];
            master_req_is_write = ch_req_is_write[1];
            master_req_ch_id    = 2'd1;
        end
        else if (selected_gnt[2]) begin
            master_req_addr     = ch_req_addr[2];
            master_req_len      = ch_req_len[2];
            master_req_is_write = ch_req_is_write[2];
            master_req_ch_id    = 2'd2;
        end
        else if (selected_gnt[3]) begin
            master_req_addr     = ch_req_addr[3];
            master_req_len      = ch_req_len[3];
            master_req_is_write = ch_req_is_write[3];
            master_req_ch_id    = 2'd3;
        end
    end
endmodule