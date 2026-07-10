# webpcap v0.2 — start video-host + AHK daemon
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$AhkCandidates = @(
    (Join-Path ${env:ProgramFiles} 'AutoHotkey\v2\AutoHotkey64.exe'),
    (Join-Path ${env:ProgramFiles} 'AutoHotkey\v2\AutoHotkey.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'AutoHotkey\v2\AutoHotkey64.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'AutoHotkey\v2\AutoHotkey.exe')
)
$Ahk = $AhkCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $Ahk) {
    Write-Error "AutoHotkey v2 not found under Program Files. Install AHK v2 or edit build.ps1."
    exit 1
}
$ini = Join-Path $Root 'webpcap.ini'
$ex = Join-Path $Root 'webpcap.ini.example'
if (-not (Test-Path $ini) -and (Test-Path $ex)) {
    Copy-Item $ex $ini
    Write-Host 'Created webpcap.ini from webpcap.ini.example - edit ffmpeg path if needed.' -ForegroundColor Yellow
}

# Stop previous video-host (if any)
$pidFile = Join-Path $env:TEMP 'webpcap-video-host.pid'
if (Test-Path $pidFile) {
    try {
        $old = [int]((Get-Content $pidFile -Raw).Trim())
        if ($old -gt 0) {
            Stop-Process -Id $old -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 400
        }
    } catch {}
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
}

# Stop prior webpcap AutoHotkey instances (avoid duplicates on re-run / logon)
try {
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            ($_.Name -match 'AutoHotkey') -and
            ($_.CommandLine -and ($_.CommandLine -match 'webpcap\.ahk'))
        } |
        ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
    Start-Sleep -Milliseconds 300
} catch {}

$hostPs1 = Join-Path $Root 'video-host.ps1'
Write-Host 'webpcap v0.2 - starting video-host (display + canvas)...'
$psArgs = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$hostPs1`" -Root `"$Root`""
Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs -WindowStyle Hidden

# Brief wait so health is up before AHK
$port = 19787
try {
    $line = (Get-Content $ini -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\s*port\s*=' } | Select-Object -First 1)
    if ($line -match '=\s*(\d+)') { $port = [int]$Matches[1] }
} catch {}
$ok = $false
for ($i = 0; $i -lt 25; $i++) {
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$port/health" -UseBasicParsing -TimeoutSec 1
        if ($r.StatusCode -eq 200) { $ok = $true; break }
    } catch {
        Start-Sleep -Milliseconds 200
    }
}
if ($ok) {
    Write-Host "  video-host OK  http://127.0.0.1:$port/health" -ForegroundColor Green
} else {
    Write-Host '  video-host not responding yet - check %TEMP%\webpcap-video.log' -ForegroundColor Yellow
}

$ahkScript = Join-Path $Root 'webpcap.ahk'
Write-Host '  launching AHK daemon (End Task AutoHotkey to stop)'
Start-Process -FilePath $Ahk -ArgumentList "`"$ahkScript`""
Write-Host 'Started. Edit webpcap.ini then restart to apply config.'
Write-Host ''
Write-Host 'Daemon running in background - CAPS / REC hotkeys:' -ForegroundColor Green
Write-Host '  CAPS  PrtSc              full still'
Write-Host '  CAPS  Alt+PrtSc          active window still'
Write-Host '  CAPS  Ctrl+PrtSc         region still (click-drag)'
Write-Host '  REC   Ctrl+Shift+PrtSc   full display + system audio (toggle)'
Write-Host '  REC   Ctrl+Win+PrtSc     active window + system audio (toggle)'
Write-Host '  REC   Ctrl+Alt+PrtSc     region + system audio (drag; fine-tune; Enter)'
Write-Host '  REC   End                stop any recording'
Write-Host 'Autostart at sign-in:  .\install-autostart.ps1' -ForegroundColor DarkGray
