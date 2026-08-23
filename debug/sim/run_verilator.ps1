# SVA + functional coverage run, from Windows, through WSL + Verilator.
#
# ModelSim ASE compiles neither SystemVerilog assertions nor coverage, so the
# debug/sva/ layer runs on Verilator (free) inside WSL. One-time setup:
#
#   wsl -d Ubuntu -u root -- apt-get update
#   wsl -d Ubuntu -u root -- apt-get install -y verilator make g++
#
# Usage:  .\run_verilator.ps1        (from debug/sim, or by full path)

$dir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$drive = $dir.Substring(0, 1).ToLower()
$rest  = $dir.Substring(2) -replace '\\', '/'
$wsl   = "/mnt/$drive$rest"

# strip CRLF the Windows checkout may have added, then run
$cmd = 'cd "' + $wsl + '" && sed -i ''s/\r$//'' run_verilator.sh && bash run_verilator.sh'
wsl -d Ubuntu -- bash -c $cmd
exit $LASTEXITCODE
