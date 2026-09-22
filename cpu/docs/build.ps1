param([string]$Python = 'python', [switch]$Recapture)
$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    if ($Recapture) {
        Push-Location ../debug/sim
        try {
            & vsim -c -do 'do waves.do; quit -f'
            if ($LASTEXITCODE -ne 0) { throw 'Waveform regression failed' }
        } finally { Pop-Location }
    }
    & $Python tools/refined_diagrams.py
    if ($LASTEXITCODE -ne 0) { throw 'Diagram generation failed' }
    & $Python tools/check_diagrams.py
    if ($LASTEXITCODE -ne 0) { throw 'Diagram geometry check failed' }
    if (Test-Path waves/raw/rv32i_tb_reset.vcd) {
        & $Python tools/waveforms.py
        if ($LASTEXITCODE -ne 0) { throw 'Waveform rendering failed' }
        & $Python tools/audit_timing.py
        if ($LASTEXITCODE -ne 0) { throw 'Waveform timing audit failed' }
    }
    & $Python tools/specs.py
    if ($LASTEXITCODE -ne 0) { throw 'Specification generation failed' }
    foreach ($name in @('Design_Specification_RV32I_CPU','Verification_Specification_RV32I_CPU','Design_Specification_PIC','Verification_Specification_PIC')) {
        1..2 | ForEach-Object {
            & lualatex -interaction=nonstopmode -halt-on-error "$name.tex" | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "LaTeX failed: $name" }
        }
        Write-Output "BUILT $name.pdf"
    }
} finally { Pop-Location }
