# Open local canvas-test.html with helper (video-host must be up — run .\build.ps1 first)
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$html = Join-Path $Root 'canvas-test.html'
if (-not (Test-Path $html)) { throw "Missing $html" }

$port = 19787
try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:$port/health" -UseBasicParsing -TimeoutSec 2
    $j = $r.Content | ConvertFrom-Json
    Write-Host "video-host OK  helper=$($j.helper)" -ForegroundColor Green
} catch {
    Write-Host 'video-host offline — starting build.ps1 first...' -ForegroundColor Yellow
    & (Join-Path $Root 'build.ps1')
    Start-Sleep -Seconds 2
}

# file:// URL so script can load helper from 127.0.0.1
$uri = ([Uri]$html).AbsoluteUri
Write-Host "Opening: $uri"
Write-Host 'In the page console (F12) you should see: [webpcap] canvas helper ready'
Write-Host 'Then: Alt+Shift+PrtSc start → wait 2s → Alt+Shift+PrtSc stop'
Write-Host "Output: $env:USERPROFILE\Videos\webpcap REC\Canvas_*.mp4"
Start-Process $uri
