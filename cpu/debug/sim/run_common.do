# Shared batch verdict: require explicit completion and zero mismatches.
onerror {quit -code 1 -f}
set run_count 0

proc run_case {top description args} {
    global run_count
    incr run_count
    if {[info exists ::env(VERBOSE)] && $::env(VERBOSE) ne "0"} {lappend args +verbose}
    echo "RUN $run_count: $description"
    eval vsim -onfinish stop -voptargs=+acc work.$top $args
    foreach arg $args {
        if {[regexp {^-G([^=]+)=(.+)$} $arg unused path expected]} {
            set actual [examine -radix decimal $path]
            if {$actual != $expected} {echo "FAIL: parameter $path: expected $expected, got $actual"; quit -code 1 -f}
            echo "CONFIG $path=$actual"
        }
    }
    run -all
    if {[examine -radix binary /$top/test_done] ne "1"} {echo "FAIL: $top did not complete"; quit -code 1 -f}
    if {[examine -radix decimal /$top/errors] != 0} {echo "FAIL: $top reported mismatches"; quit -code 1 -f}
    quit -sim
    echo "PASS: $top"
}
