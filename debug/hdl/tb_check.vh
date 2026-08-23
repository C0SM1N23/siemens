// Shared self-check task for the testbenches: === compare (so an X never
// passes), PASS/FAIL line per check, mismatches counted in the bench's
// `errors`. Included inside each module body after `integer errors;`.
// Deliberately no include guard: the task is module-scoped, so each bench
// needs its own textual copy even when both compile in one vlog call.
task check;
    input [31:0] expected;
    input [31:0] got;
    input [511:0] test_name;   // 64 chars: the longest check labels need > 32
    begin
        if (expected === got)
            $display("PASS: %0s = 0x%08h", test_name, got);
        else begin
            $display("FAIL: %0s -> expected 0x%08h, got 0x%08h",
                     test_name, expected, got);
            errors = errors + 1;
        end
    end
endtask
