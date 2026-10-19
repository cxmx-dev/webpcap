# webpcap — debug launch + test checklist (new hotkey map)
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$Ahk = Join-Path ${env:ProgramFiles} 'AutoHotkey\v2\AutoHotkey.exe'
if (-not (Test-Path $Ahk)) {
    $Ahk86 = Join-Path ${env:ProgramFiles(x86)} 'AutoHotkey\v2\AutoHotkey.exe'
    if (Test-Path $Ahk86) { $Ahk = $Ahk86 }
}
$Out = Join-Path $env:USERPROFILE 'Pictures\Screenshots\webpcap CAPS'
$Vid = Join-Path $env:USERPROFILE 'Videos\webpcap REC'

if (-not (Test-Path $Ahk)) {
    Write-Error "AutoHotkey v2 not found under Program Files"
    exit 1
}

Write-Host '=== webpcap hotkey test plan ==='
Write-Host ''
Write-Host '[0] .\build.ps1  (video-host + daemon)'
Write-Host '[1] Starting AHK in --debug mode...'
Start-Process -FilePath $Ahk -ArgumentList "`"$Root\webpcap.ahk`" --debug"
Start-Sleep -Seconds 2
Write-Host ''
Write-Host '--- CAPS (.webp) ---'
Write-Host '[2] PrtSc                 full desktop still'
Write-Host '[3] Alt+PrtSc             active window still'
Write-Host '[4] Ctrl+PrtSc            region still (click-drag; Esc cancel)'
Write-Host ''
Write-Host '--- REC (.mp4 + system audio) ---'
Write-Host '[5] Ctrl+Shift+PrtSc      full display REC; again or End to stop'
Write-Host '[6] Ctrl+Win+PrtSc        active window REC; again or End to stop'
Write-Host '[7] Ctrl+Alt+PrtSc        region REC: drag, fine-tune edges, Enter; End stops'
Write-Host '[8] End                   stop any active REC'
Write-Host ''
Write-Host "Stills: $Out"
Write-Host "Video:  $Vid"
Write-Host ''
Read-Host 'Press Enter to close this window'
