# Run one capture without hotkeys — proves AHK pipeline works
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$Ahk = 'C:\Program Files\AutoHotkey\v2\AutoHotkey.exe'
$script = Join-Path $Root 'webpcap.ahk'

if (-not (Test-Path $Ahk)) { throw "AutoHotkey v2 not found: $Ahk" }

$out = Join-Path $env:USERPROFILE 'Pictures\Screenshots\WebP'
New-Item -ItemType Directory -Force -Path $out | Out-Null
$before = (Get-ChildItem $out -Filter '*.webp' -ErrorAction SilentlyContinue).Count

Write-Host 'Running: webpcap.ahk --test full'
& $Ahk $script '--test' 'full'
Start-Sleep -Seconds 5
$code = $LASTEXITCODE
Write-Host "exit code: $code"

$after = (Get-ChildItem $out -Filter '*.webp' -ErrorAction SilentlyContinue).Count
if ($after -gt $before) {
    Write-Host "PASS: new .webp created ($before -> $after files)" -ForegroundColor Green
} else {
    Write-Host 'FAIL: no new .webp — check %TEMP%\webpcap.log' -ForegroundColor Red
}
Get-ChildItem $out -Filter '*.webp' | Sort-Object LastWriteTime -Descending | Select-Object -First 3 Name, Length, LastWriteTime

if (Test-Path "$env:TEMP\webpcap.log") {
    Write-Host '--- log tail ---'
    Get-Content "$env:TEMP\webpcap.log" -Tail 5
}