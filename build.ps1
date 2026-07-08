# webpcap v0.1 — start daemon (PowerShell)
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$Ahk = 'C:\Program Files\AutoHotkey\v2\AutoHotkey.exe'
if (-not (Test-Path $Ahk)) {
    Write-Error "AutoHotkey v2 not found at $Ahk"
    exit 1
}
Write-Host 'webpcap v0.1 - launching daemon (End Task AutoHotkey or close script to stop)'
Start-Process -FilePath $Ahk -ArgumentList "`"$Root\webpcap.ahk`""
Write-Host 'Started. Edit webpcap.ini then restart to apply config.'