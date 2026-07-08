# webpcap v0.1 — debug launch + test checklist
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$Ahk = 'C:\Program Files\AutoHotkey\v2\AutoHotkey.exe'
$Out = Join-Path $env:USERPROFILE 'Pictures\Screenshots\WebP'

if (-not (Test-Path $Ahk)) {
    Write-Error "AutoHotkey v2 not found at $Ahk"
    exit 1
}

Write-Host '=== webpcap v0.1 test plan ==='
Write-Host ''
Write-Host '[1] Starting daemon in --debug mode (tooltips on save)...'
Start-Process -FilePath $Ahk -ArgumentList "`"$Root\webpcap.ahk`" --debug"
Start-Sleep -Seconds 2
Write-Host ''
Write-Host '[2] Press PrintScreen       -> full desktop .webp'
Write-Host '[3] Press Win+Shift+S       -> two-click region .webp'
Write-Host '[4] Press Win+Shift+R       -> active window .webp'
Write-Host ''
Write-Host "Output folder: $Out"
Write-Host ''
Write-Host '[5] Verify each file: exists, opens, pastes (Ctrl+V), smaller than PNG'
Write-Host '[6] Speed: capture-to-save should feel instant (<1s typical)'
Write-Host ''
Read-Host 'Press Enter to close this window'