# Open local canvas-test.html (demo surface for display/region REC).
# Canvas-only helper REC is parked (no dedicated hotkey). video-host must be up — run .\build.ps1 first.
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$html = Join-Path $Root 'canvas-test.html'
if (-not (Test-Path $html)) { throw "Missing $html" }

$port = 19787
try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:$port/health" -UseBasicParsing -TimeoutSec 2
    $j = $r.Content | ConvertFrom-Json
    Write-Host "video-host OK  helper=$($j.helper)  (parked canvas path; main REC uses display/window/region hotkeys)" -ForegroundColor Green
} catch {
    Write-Host 'video-host offline — starting build.ps1 first...' -ForegroundColor Yellow
    & (Join-Path $Root 'build.ps1')
    Start-Sleep -Seconds 2
}

# file:// URL so the page can still load helper script from 127.0.0.1 if present
$uri = ([Uri]$html).AbsoluteUri
Write-Host "Opening: $uri"
Write-Host 'Optional console (F12): [webpcap] canvas helper ready — helper is parked; not required for main REC.'
Write-Host ''
Write-Host 'Main REC (use these):' -ForegroundColor Cyan
Write-Host '  Ctrl+Shift+PrtSc   full display + system audio  →  Display_*.mp4'
Write-Host '  Ctrl+Win+PrtSc     active window + system audio →  Window_*.mp4'
Write-Host '  Ctrl+Alt+PrtSc     region (drag → fine-tune → Enter) → Region_*.mp4'
Write-Host '  End                stop any recording'
Write-Host ''
Write-Host 'Do NOT use Alt+Shift+PrtSc (Windows High Contrast trap; old canvas toggle — removed from main map).'
Write-Host "Output folder: $env:USERPROFILE\Videos\webpcap REC\"
Write-Host 'REC red disc blinks on-screen only (excluded from capture).'
Start-Process $uri
