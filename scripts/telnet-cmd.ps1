# Minimal Windows Telnet client (handles IAC negotiation, refuses all options)
# Usage: .\telnet-cmd.ps1 -Ip 192.168.1.100 -Port 3000 -CommandText "cd /system/bin;;./adbd &"
# Commands are split by ;; and sent one by one; output of each command is echoed back.
param(
    [string]$Ip = '192.168.1.100',
    [int]$Port = 3000,
    [string]$CommandText = '',
    [int]$WaitMs = 1500
)

$ErrorActionPreference = 'Stop'
$client = New-Object System.Net.Sockets.TcpClient
$client.Connect($Ip, $Port)
$stream = $client.GetStream()
$stream.ReadTimeout = 300
$stream.WriteTimeout = 3000

function Read-Telnet {
    $out = New-Object System.Text.StringBuilder
    $buf = New-Object byte[] 8192
    while ($stream.DataAvailable) {
        $n = $stream.Read($buf, 0, $buf.Length)
        if ($n -le 0) { break }
        $i = 0
        while ($i -lt $n) {
            $b = $buf[$i]
            if ($b -eq 255 -and ($i + 1) -lt $n) {
                $cmd = $buf[$i + 1]
                if ($cmd -eq 255) { [void]$out.Append([char]255); $i += 2; continue }
                if ($cmd -ge 251 -and $cmd -le 254 -and ($i + 2) -lt $n) {
                    $opt = $buf[$i + 2]
                    $reply = if ($cmd -eq 251 -or $cmd -eq 252) { 254 } else { 252 }
                    $neg = [byte[]]@(255, $reply, $opt)
                    $stream.Write($neg, 0, 3)
                    $i += 3; continue
                }
                if ($cmd -eq 250) {
                    $i += 2
                    while ($i -lt ($n - 1)) {
                        if ($buf[$i] -eq 255 -and $buf[$i + 1] -eq 240) { $i += 2; break }
                        $i++
                    }
                    continue
                }
                $i += 2; continue
            }
            if ($b -ge 32 -or $b -eq 10 -or $b -eq 13 -or $b -eq 9) { [void]$out.Append([char]$b) }
            $i++
        }
    }
    return $out.ToString()
}

function Drain([int]$ms) {
    $deadline = (Get-Date).AddMilliseconds($ms)
    $all = ''
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 150
        $all += Read-Telnet
    }
    return $all
}

Write-Output "=== Connected to ${Ip}:${Port} ==="
Write-Output (Drain 2000)

foreach ($c in @($CommandText -split ';;' | Where-Object { $_ -ne '' })) {
    Write-Output "=== SEND: $c ==="
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($c + "`n")
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush()
    Write-Output (Drain $WaitMs)
}

$client.Close()
Write-Output "=== Connection closed ==="