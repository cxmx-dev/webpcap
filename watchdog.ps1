# webpcap external watchdog — survives AHK death; restarts AHK and/or video-host.
# Started by build.ps1 (hidden). Stopped when build.ps1 re-runs.
param(
    [string]$Root = $PSScriptRoot,
    [int]$IntervalSec = 30
)
$ErrorActionPreference = 'Continue'
if ($IntervalSec -lt 10) { $IntervalSec = 10 }

$logFile = Join-Path $env:TEMP 'webpcap-watchdog.log'
$pidFile = Join-Path $env:TEMP 'webpcap-watchdog.pid'
$hostPidFile = Join-Path $env:TEMP 'webpcap-video-host.pid'
$ahkScript = Join-Path $Root 'webpcap.ahk'
$hostPs1 = Join-Path $Root 'video-host.ps1'
$ini = Join-Path $Root 'webpcap.ini'

function Write-WLog([string]$msg) {
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    try { Add-Content -Path $logFile -Value $line -Encoding UTF8 } catch {}
}

function Get-IniPort {
    $port = 19787
    if (-not (Test-Path $ini)) { return $port }
    try {
        $line = Get-Content $ini -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\s*port\s*=' } | Select-Object -First 1
        if ($line -match '=\s*(\d+)') { $port = [int]$Matches[1] }
    } catch {}
    return $port
}

function Find-AhkExe {
    # 2026-10-02b: UI Access build first (hotkeys over elevated windows), same as build.ps1
    $useUia = $true
    try { if (Get-Content $ini -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\s*ahk_uia\s*=\s*0' }) { $useUia = $false } } catch {}
    $cands = @(
        $(if ($useUia) { Join-Path ${env:ProgramFiles} 'AutoHotkey\v2\AutoHotkey64_UIA.exe' }),
        (Join-Path ${env:ProgramFiles} 'AutoHotkey\v2\AutoHotkey64.exe'),
        (Join-Path ${env:ProgramFiles} 'AutoHotkey\v2\AutoHotkey.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'AutoHotkey\v2\AutoHotkey64.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'AutoHotkey\v2\AutoHotkey.exe')
    )
    return $cands | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
}

function Test-WebpcapAhk {
    $hit = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            ($_.Name -match 'AutoHotkey') -and
            ($_.CommandLine -and ($_.CommandLine -match 'webpcap\.ahk'))
        } |
        Select-Object -First 1
    if ($hit) { return $true }
    # 2026-10-02b: AutoHotkey64_UIA.exe runs at High integrity, so its CommandLine reads as
    # empty from this (medium) process. Fall back to the script's hidden main window title.
    return (Test-WebpcapAhkWindow)
}

function Test-WebpcapAhkWindow {
    try {
        if (-not ('WpcAhkWin' -as [type])) {
            Add-Type -TypeDefinition @"
using System; using System.Text; using System.Runtime.InteropServices;
public static class WpcAhkWin {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr p, IntPtr a, string c, string w);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    public static bool Has(string needle) {
        IntPtr h = IntPtr.Zero;
        while ((h = FindWindowEx(IntPtr.Zero, h, "AutoHotkey", null)) != IntPtr.Zero) {
            var sb = new StringBuilder(1024); GetWindowText(h, sb, 1024);
            if (sb.ToString().IndexOf(needle, StringComparison.OrdinalIgnoreCase) >= 0) return true;
        }
        return false;
    }
}
"@
        }
        return [WpcAhkWin]::Has('\webpcap.ahk')
    } catch {
        Write-WLog "AHK window check failed: $($_.Exception.Message)"
        return $false
    }
}

function Test-VideoHost([int]$port) {
    try {
        $r = Invoke-WebRequest -Uri "http://127.0.0.1:$port/health" -UseBasicParsing -TimeoutSec 2
        return ($r.StatusCode -eq 200 -and $r.Content -match '"ok"\s*:\s*true')
    } catch {
        return $false
    }
}

function Start-WebpcapAhk {
    $ahk = Find-AhkExe
    if (-not $ahk) {
        Write-WLog 'AHK v2 not found — cannot restart daemon'
        return
    }
    if (-not (Test-Path $ahkScript)) {
        Write-WLog "missing $ahkScript"
        return
    }
    # ShellExecute launch (required for the UIA build)
    Start-Process -FilePath $ahk -ArgumentList "`"$ahkScript`""
    Write-WLog "started webpcap.ahk via $ahk"
}

function Stop-OrphanWebpcapFfmpeg {
    $n = 0
    try {
        Get-CimInstance Win32_Process -Filter "Name = 'ffmpeg.exe'" -ErrorAction SilentlyContinue |
            ForEach-Object {
                $cl = [string]$_.CommandLine
                if ($cl -and $cl -match 'webpcap_rec_') {
                    try {
                        Stop-Process -Id ([int]$_.ProcessId) -Force -ErrorAction Stop
                        $n++
                        Write-WLog "killed orphan ffmpeg pid=$($_.ProcessId)"
                    } catch {}
                }
            }
    } catch {}
    return $n
}

function Start-VideoHost {
    if (-not (Test-Path $hostPs1)) {
        Write-WLog 'missing video-host.ps1'
        return
    }
    # Kill prior host via pid file
    if (Test-Path $hostPidFile) {
        try {
            $old = [int]((Get-Content $hostPidFile -Raw).Trim())
            if ($old -gt 0) {
                Stop-Process -Id $old -Force -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 300
            }
        } catch {}
        Remove-Item $hostPidFile -Force -ErrorAction SilentlyContinue
    }
    # Orphans by command line
    try {
        Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -match 'powershell' -and
                $_.CommandLine -and
                ($_.CommandLine -match 'video-host\.ps1') -and
                ($_.CommandLine -match 'webpcap|Repos')
            } |
            ForEach-Object {
                Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            }
    } catch {}
    # Stuck gdigrab from mid-stop kill → next region REC hangs with 0-byte output
    [void](Stop-OrphanWebpcapFfmpeg)
    $psArgs = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$hostPs1`" -Root `"$Root`""
    Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs -WindowStyle Hidden
    Write-WLog 'started video-host.ps1'
}

# Record our pid so build.ps1 can stop us cleanly
try { Set-Content -Path $pidFile -Value $PID -Encoding ASCII -NoNewline } catch {}
Write-WLog "watchdog start root=$Root interval=${IntervalSec}s pid=$PID"

$port = Get-IniPort
$lastAhkRestart = [datetime]::MinValue
$lastHostRestart = [datetime]::MinValue
$minGap = [TimeSpan]::FromSeconds(45)

try {
    # First pass after a short delay so a dead sibling is fixed without waiting a full interval
    $first = $true
    while ($true) {
        if ($first) {
            Start-Sleep -Seconds 5
            $first = $false
        } else {
            Start-Sleep -Seconds $IntervalSec
        }
        $port = Get-IniPort

        $ahkOk = Test-WebpcapAhk
        $hostOk = Test-VideoHost $port

        if (-not $ahkOk) {
            $now = Get-Date
            if (($now - $lastAhkRestart) -ge $minGap) {
                Write-WLog 'AHK daemon missing - restarting'
                Start-WebpcapAhk
                $lastAhkRestart = $now
            }
        }

        if (-not $hostOk) {
            $now = Get-Date
            if (($now - $lastHostRestart) -ge $minGap) {
                Write-WLog 'video-host unhealthy - restarting'
                Start-VideoHost
                $lastHostRestart = $now
            }
        }
    }
} finally {
    try { Remove-Item $pidFile -Force -ErrorAction SilentlyContinue } catch {}
    Write-WLog 'watchdog exit'
}
