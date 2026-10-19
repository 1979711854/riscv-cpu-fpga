param(
    [string]$Doc = "D:\riscv-cpu-fpga_merged\doc\contest\技术文档_v1.docx",
    [string]$Pdf = "D:\riscv-cpu-fpga_merged\doc\contest\技术文档_v1.pdf"
)
$ErrorActionPreference = "Stop"
$w = New-Object -ComObject Word.Application
$w.Visible = $false
$w.DisplayAlerts = 0
$d = $w.Documents.Open($Doc, $false, $false)
"pages=$($d.ComputeStatistics(2)) words=$($d.ComputeStatistics(0)) chars=$($d.ComputeStatistics(3))"
if (Test-Path $Pdf) { Remove-Item $Pdf -Force }
$d.SaveAs([ref]$Pdf, [ref]17)
$d.Close($false)
$w.Quit()
