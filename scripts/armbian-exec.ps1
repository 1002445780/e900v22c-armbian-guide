# SSH command executor for Armbian boxes, tolerant of the ophub first-login wizard.
# Usage: .\armbian-exec.ps1 -Ip 192.168.1.100 -Password 'yourpassword' -Commands "uname -a;;df -h"
# Requires the Posh-SSH module: Install-Module Posh-SSH -Scope CurrentUser -Force
param(
    [string]$Ip = '192.168.1.100',
    [string]$Password = 'YOUR_BOX_PASSWORD',
    [Parameter(Mandatory = $true)][string]$Commands,
    [int]$WaitSecs = 8
)
Import-Module Posh-SSH -ErrorAction Stop
$ErrorActionPreference = 'Stop'

$sec = ConvertTo-SecureString $Password -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential('root', $sec)
$session = New-SSHSession -ComputerName $Ip -Credential $cred -AcceptKey -Force -ConnectionTimeout 15
$stream = New-SSHShellStream -SSHSession $session -TerminalName 'xterm' -Columns 250 -Rows 50 -BufferSize 16384

function Drain([int]$secs) {
    $end = (Get-Date).AddSeconds($secs)
    $text = ''
    while ((Get-Date) -lt $end) {
        Start-Sleep -Milliseconds 250
        if ($stream.DataAvailable) { $text += $stream.Read() }
    }
    return $text
}

# Reach a shell prompt; dismiss the first-login wizard if it appears
$all = ''
$deadline = (Get-Date).AddSeconds(60)
$ready = $false
while ((Get-Date) -lt $deadline) {
    $chunk = Drain 2
    $all += $chunk
    $tail = $all.Substring([Math]::Max(0, $all.Length - 400))
    if ($tail -match 'root@[^\s]*:[^\n]*#\s*$') { $ready = $true; break }
    if ($tail -match 'username|Ctrl-C') {
        $stream.Write("$([char]3)")   # Ctrl-C aborts user creation
        Start-Sleep -Milliseconds 500
        $stream.WriteLine('')
        continue
    }
    if ($tail -match 'Create root password:\s*$') { $stream.WriteLine($Password); continue }
    if ($tail -match 'Repeat root password:\s*$') { $stream.WriteLine($Password); continue }
    if ($tail -match '1\) bash') { $stream.WriteLine('1'); continue }
}
if (-not $ready) {
    Write-Output '=== WARNING: no shell prompt detected, initial output: ==='
    Write-Output $all
}

$stream.WriteLine('rm -f /root/.not_logged_in_yet; stty cols 250 rows 50 2>/dev/null; export TERM=dumb; echo READY_MARKER')
[void](Drain 3)

$stream.WriteLine("echo CMDS_BEGIN; $Commands; echo CMDS_EXIT_CODE=`$?; echo CMDS_END")
$out = Drain $WaitSecs
Write-Output $out
Remove-SSHSession -SSHSession $session | Out-Null