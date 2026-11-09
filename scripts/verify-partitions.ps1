# Verify partition backups: size must equal blockdev --getsize64, SHA256 must match box-side hash.
# Usage: .\verify-partitions.ps1 -Ip 192.168.1.100 -BackupDir .\backup
param(
    [string]$Ip = '192.168.1.100',
    [string]$BackupDir = '.\backup',
    [string]$Adb = 'adb'
)
$ErrorActionPreference = 'Stop'

$sizes = @{
    bootloader = 4194304; boot = 16777216; recovery = 25165824; dtbo = 8388608
    vbmeta = 2097152; logo = 8388608; env = 8388608; misc = 8388608
    ctc = 268435456; cri_data = 8388608; skparam = 16777216; skmac = 4194304
    skbackup = 805306368; param = 16777216; system = 1342177280; vendor = 335544320
}
$rawParts = @('bootloader','boot','recovery','dtbo','vbmeta','logo','env','misc','cri_data','skparam','skmac','param')
$gzParts  = @('system','vendor','ctc','skbackup')
$all = $rawParts + $gzParts

Write-Output '=== SHA256 on box (takes a few minutes) ==='
$cmd = ($all | ForEach-Object { "sha256sum /dev/block/$_" }) -join '; '
$boxOutput = & $Adb -s $Ip shell $cmd
$boxHash = @{}
foreach ($line in $boxOutput) {
    if ($line -match '^([0-9a-f]{64})\s+/dev/block/(\w+)') { $boxHash[$Matches[2]] = $Matches[1] }
}

Write-Output '=== SHA256 + size on PC ==='
$fail = 0
foreach ($p in $all) {
    $isGz = $gzParts -contains $p
    $file = Join-Path $BackupDir $(if ($isGz) { "$p.img.gz" } else { "$p.img" })
    if (-not (Test-Path $file)) { Write-Output "$p : MISSING FILE"; $fail++; continue }
    $fs = [System.IO.File]::OpenRead($file)
    $stream = $fs
    if ($isGz) {
        $gz = New-Object System.IO.Compression.GZipStream($fs, [System.IO.Compression.CompressionMode]::Decompress)
        $stream = $gz
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $buf = New-Object byte[] 1048576
    $total = [long]0
    while (($n = $stream.Read($buf, 0, $buf.Length)) -gt 0) {
        $sha.TransformBlock($buf, 0, $n, $null, 0) | Out-Null
        $total += $n
    }
    $sha.TransformFinalBlock($buf, 0, 0) | Out-Null
    $pcHash = ([BitConverter]::ToString($sha.Hash) -replace '-','').ToLower()
    $stream.Dispose(); $fs.Dispose()

    $sizeOk = ($total -eq $sizes[$p])
    $hashOk = ($boxHash.ContainsKey($p) -and $boxHash[$p] -eq $pcHash)
    if ($sizeOk -and $hashOk) {
        Write-Output "$p : OK (size=$total, sha256 match)"
    } else {
        Write-Output "$p : FAIL (sizeOk=$sizeOk expected=$($sizes[$p]) got=$total; hashOk=$hashOk)"
        Write-Output "  box: $($boxHash[$p])"
        Write-Output "  pc : $pcHash"
        $fail++
    }
}
if ($fail -eq 0) { Write-Output '=== ALL PARTITIONS VERIFIED OK ===' } else { Write-Output "=== $fail FAILURES ==="; exit 1 }

# NOTE: skparam is a LIVE partition (system service rewrites sk_syspara periodically).
# If only skparam fails: re-run the single-partition backup, then verify with hashes
# captured before AND after the read - all three must match.