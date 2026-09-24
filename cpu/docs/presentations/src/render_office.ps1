param([string]$Filter = '*.pptx')
$ErrorActionPreference = 'Stop'
$ppt = New-Object -ComObject PowerPoint.Application
$issues = @()
$inspected = 0
try {
    foreach ($file in Get-ChildItem output -Filter $Filter) {
        $stem = [IO.Path]::GetFileNameWithoutExtension($file.Name)
        $deck = $ppt.Presentations.Open($file.FullName, -1, 0, 0)
        try {
            $dir = Join-Path (Get-Location) "scratch/office/$stem"
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
            $deck.Export($dir, 'PNG', 1920, 1080)
            $deck.SaveAs((Join-Path $file.DirectoryName "$stem.pdf"), 32)
            foreach ($slide in $deck.Slides) {
                $inspected++
                foreach ($shape in $slide.Shapes) {
                    if ($shape.Left -lt -1 -or $shape.Top -lt -1 -or ($shape.Left+$shape.Width) -gt ($deck.PageSetup.SlideWidth+1) -or ($shape.Top+$shape.Height) -gt ($deck.PageSetup.SlideHeight+1)) {
                        $issues += "$stem slide $($slide.SlideIndex) outside slide: $($shape.Name)"
                    }
                    if ($shape.HasTextFrame -and $shape.TextFrame.HasText) {
                        $range = $shape.TextFrame2.TextRange
                        if ($range.BoundHeight -gt $shape.Height+2 -or $range.BoundWidth -gt $shape.Width+2) {
                            $issues += "$stem slide $($slide.SlideIndex) text overflow: $($shape.Name): $($range.Text)"
                        }
                    }
                }
            }
            Write-Output "RENDERED $stem ($($deck.Slides.Count) slides)"
        } finally { $deck.Close() }
    }
} finally { $ppt.Quit() }
Set-Content -LiteralPath scratch/office/text-fit-issues.txt -Value ($issues -join [Environment]::NewLine) -Encoding utf8
@{ issues = $issues.Count; inspectedSlides = $inspected; checkedAt = (Get-Date).ToString('s') } | ConvertTo-Json | Set-Content scratch/office/geometry-report.json -Encoding utf8
Write-Output "Text/geometry issues: $($issues.Count)"
if ($issues.Count -ne 0) { throw 'PowerPoint geometry/text-fit check failed' }
