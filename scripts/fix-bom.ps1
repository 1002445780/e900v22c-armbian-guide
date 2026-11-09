# Fix PowerShell Chinese-script encoding: Windows PowerShell 5.1 reads BOM-less
# UTF-8 .ps1 files as ANSI/GBK, corrupting Chinese text and swallowing quotes
# that follow multibyte characters. This script prepends a UTF-8 BOM so PS 5.1
# parses the file correctly.
# Usage: .\fix-bom.ps1 -Path .\your-chinese-script.ps1
param([string]$Path)
$b = [System.IO.File]::ReadAllBytes($Path)
if (!($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)) {
    $out = New-Object byte[] ($b.Length + 3)
    $out[0] = 0xEF; $out[1] = 0xBB; $out[2] = 0xBF
    [Array]::Copy($b, 0, $out, 3, $b.Length)
    [System.IO.File]::WriteAllBytes($Path, $out)
    Write-Output "BOM added"
} else {
    Write-Output "BOM already present"
}