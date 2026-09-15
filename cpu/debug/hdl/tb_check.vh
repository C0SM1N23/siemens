// Module-local result and comparison tasks. +verbose prints successful checks.
reg test_done = 1'b0;

task check;
    input [31:0] expected;
    input [31:0] got;
    input [511:0] test_name;   // 64 chars: the longest check labels need > 32
    begin
        if (expected === got) begin
            if ($test$plusargs("verbose")) $display("PASS: %0s = 0x%08h", test_name, got);
        end else begin
            $display("FAIL: %0s -> expected 0x%08h, got 0x%08h",
                     test_name, expected, got);
            errors = errors + 1;
        end
    end
endtask

// A run completes only through this task; watchdogs use $fatal directly.
task finish_test;
    begin
        if (errors !== 0) $fatal(1, "test failed: errors=%0d", errors);
        test_done = 1'b1;
        $finish;
    end
endtask
