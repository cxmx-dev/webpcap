# webpcap video host - display (gdigrab) + canvas (MediaRecorder upload) on 127.0.0.1
# Started by build.ps1; AHK toggles via HTTP. Keeps ffmpeg stdin open for clean MP4 stop.
param(
    [string]$Root = $PSScriptRoot,
    [string]$IniPath = ''
)
$ErrorActionPreference = 'Stop'
if (-not $IniPath) { $IniPath = Join-Path $Root 'webpcap.ini' }

function Get-IniValue([string]$file, [string]$section, [string]$key, [string]$default = '') {
    if (-not (Test-Path $file)) { return $default }
    $cur = ''
    foreach ($line in Get-Content $file -ErrorAction SilentlyContinue) {
        if ($line -match '^\s*\[(.+)\]\s*$') { $cur = $Matches[1]; continue }
        if ($cur -eq $section -and $line -match ('^\s*' + [regex]::Escape($key) + '\s*=\s*(.*)$')) {
            return $Matches[1].Trim()
        }
    }
    return $default
}

function Expand-EnvPath([string]$p) {
    return [Environment]::ExpandEnvironmentVariables($p)
}

$ex = Join-Path $Root 'webpcap.ini.example'
if (-not (Test-Path $IniPath) -and (Test-Path $ex)) { Copy-Item $ex $IniPath }

$Ffmpeg = Get-IniValue $IniPath 'paths' 'ffmpeg' 'ffmpeg.exe'
$VidDir = Expand-EnvPath (Get-IniValue $IniPath 'paths' 'viddir' '%USERPROFILE%\Videos\webpcap REC')
$Fps = [int](Get-IniValue $IniPath 'video' 'fps' '30')
$Crf = [int](Get-IniValue $IniPath 'video' 'crf' '23')
$Port = [int](Get-IniValue $IniPath 'video' 'port' '19787')
# display REC audio: system = WASAPI loopback (what speakers play); off = silent
$AudioMode = (Get-IniValue $IniPath 'video' 'audio' 'system').Trim().ToLowerInvariant()
if ($AudioMode -notin @('system', 'off')) { $AudioMode = 'system' }
# Fine-tune A/V after auto offset: positive ms delays audio (sound later); negative advances audio
$AudioDelayMs = 0
try { $AudioDelayMs = [int](Get-IniValue $IniPath 'video' 'audio_delay_ms' '0') } catch { $AudioDelayMs = 0 }

New-Item -ItemType Directory -Force -Path $VidDir | Out-Null

$pidFile = Join-Path $env:TEMP 'webpcap-video-host.pid'
$logFile = Join-Path $env:TEMP 'webpcap-video.log'
$script:DisplayProc = $null
$script:DisplayOut = $null          # temp silent video path while recording
$script:DisplayFinal = $null        # final *_.mp4 in viddir
$script:DisplayAudio = $null        # WasapiLoopbackRecorder
$script:DisplayAudioWav = $null
$script:DisplayHasAudio = $false
$script:DisplayAudioStartUtc = [datetime]::MinValue
$script:DisplayVideoStartUtc = [datetime]::MinValue
$script:DisplayErrFile = $null      # ffmpeg stderr path for failed REC diagnosis
$script:RecKind = $null             # display | window | region
$script:CanvasRecord = $false
$script:CanvasSeq = 0
$script:LastClientUtc = [datetime]::MinValue
$script:LastUploadUtc = [datetime]::MinValue
$script:Lock = New-Object object

function Write-Log([string]$msg) {
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    try { Add-Content -Path $logFile -Value $line -Encoding UTF8 } catch {}
}

# Compile WASAPI loopback helper once (system audio - this ffmpeg build has no wasapi demuxer)
$loopbackCs = Join-Path $Root 'WasapiLoopback.cs'
if (-not ('WasapiLoopbackRecorder' -as [type])) {
    if (Test-Path $loopbackCs) {
        try {
            Add-Type -TypeDefinition (Get-Content -LiteralPath $loopbackCs -Raw -Encoding UTF8)
            Write-Log 'WasapiLoopback type loaded'
        } catch {
            Write-Log "WasapiLoopback Add-Type failed: $_"
        }
    } else {
        Write-Log 'WasapiLoopback.cs missing - display REC will be video-only'
    }
}

function Test-CanvasHelperAlive {
    if ($script:LastClientUtc -eq [datetime]::MinValue) { return $false }
    return (([datetime]::UtcNow - $script:LastClientUtc).TotalSeconds -lt 2.5)
}

function Note-CanvasClient {
    $script:LastClientUtc = [datetime]::UtcNow
}

function New-Stamp {
    return ('{0}_{1}' -f (Get-Date -Format 'yyyyMMdd_HHmmss'), [Environment]::TickCount)
}

function Stop-DisplayAudio {
    $rec = $script:DisplayAudio
    $script:DisplayAudio = $null
    if ($null -eq $rec) { return }
    try { $rec.Stop() } catch { Write-Log "loopback stop: $_" }
    if ($rec.LastError) { Write-Log "loopback error: $($rec.LastError)" }
    try { $rec.Dispose() } catch {}
}

function Format-FfmpegSeconds([double]$sec) {
    # Invariant culture so FFmpeg always sees "0.250" not "0,250"
    return $sec.ToString('0.000', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Invoke-FfmpegArgs([string]$argLine, [int]$timeoutMs = 120000) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Ffmpeg
    $psi.Arguments = $argLine
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    if (-not $p.Start()) { return $null }
    if (-not $p.WaitForExit($timeoutMs)) {
        try { $p.Kill() } catch {}
        try { $p.WaitForExit(3000) | Out-Null } catch {}
        Write-Log "ffmpeg tool timeout ${timeoutMs}ms"
        try { $p.Dispose() } catch {}
        return -1
    }
    $code = $p.ExitCode
    try { $p.Dispose() } catch {}
    return $code
}

function Convert-TempVideoToMp4([string]$videoPath, [string]$finalPath) {
    # Prefer remux with +faststart for players; fall back to move/copy.
    $argLine = "-hide_banner -loglevel error -y -i `"$videoPath`" -c:v copy -an -movflags +faststart `"$finalPath`""
    $code = Invoke-FfmpegArgs $argLine 90000
    if ($code -eq 0 -and (Get-FileSizeSafe $finalPath) -gt 1024) {
        return $true
    }
    try {
        Move-Item -Force -LiteralPath $videoPath -Destination $finalPath
        if ((Get-FileSizeSafe $finalPath) -gt 1024) { return $true }
    } catch {}
    try {
        Copy-Item -Force -LiteralPath $videoPath -Destination $finalPath
        return ((Get-FileSizeSafe $finalPath) -gt 1024)
    } catch {
        return $false
    }
}

function Merge-DisplayAv {
    param(
        [string]$videoPath,
        [string]$wavPath,
        [string]$finalPath,
        [double]$AudioLeadSec = 0
    )
    if (-not (Test-Path -LiteralPath $videoPath)) { return $false }
    $hasWav = $wavPath -and (Test-Path -LiteralPath $wavPath) -and ((Get-Item -LiteralPath $wavPath).Length -gt 128)
    if (-not $hasWav) {
        if (-not (Convert-TempVideoToMp4 $videoPath $finalPath)) {
            Write-Log ('display save video-only failed: {0}' -f $videoPath)
            return $false
        }
        $sz = (Get-Item -LiteralPath $finalPath).Length
        Write-Log ('display saved (video only): {0} ({1} bytes)' -f $finalPath, $sz)
        return $true
    }
    # Align streams (file t=0 for both without offset is wrong when start clocks differ):
    #   AudioLeadSec = videoStart - audioStart (positive = audio began first).
    #   AudioLeadSec > 0 → skip that much from WAV head (-ss).
    #   AudioLeadSec < 0 → video began first (normal now) → delay audio (+itsoffset).
    # audio_delay_ms (ini): extra fine-tune after auto offset (positive = sound later / more skip).
    $adj = $AudioLeadSec + ($AudioDelayMs / 1000.0)
    if ($adj -gt 0.005) {
        $ss = Format-FfmpegSeconds $adj
        $argLine = "-hide_banner -loglevel error -y -i `"$videoPath`" -ss $ss -i `"$wavPath`" -c:v copy -c:a aac -b:a 192k -shortest -movflags +faststart `"$finalPath`""
        Write-Log ("mux A/V sync: skip audio head {0}s (lead={1:0.000} delay_ms={2})" -f $ss, $AudioLeadSec, $AudioDelayMs)
    } elseif ($adj -lt -0.005) {
        # Video first: delay audio so WAV t=0 lines up with when loopback actually started.
        $off = Format-FfmpegSeconds (-$adj)
        $argLine = "-hide_banner -loglevel error -y -i `"$videoPath`" -itsoffset $off -i `"$wavPath`" -c:v copy -c:a aac -b:a 192k -shortest -movflags +faststart `"$finalPath`""
        Write-Log ("mux A/V sync: delay audio {0}s (lead={1:0.000} delay_ms={2})" -f $off, $AudioLeadSec, $AudioDelayMs)
    } else {
        $argLine = "-hide_banner -loglevel error -y -i `"$videoPath`" -i `"$wavPath`" -c:v copy -c:a aac -b:a 192k -shortest -movflags +faststart `"$finalPath`""
        Write-Log ("mux A/V sync: no offset (lead={0:0.000} delay_ms={1})" -f $AudioLeadSec, $AudioDelayMs)
    }
    $code = Invoke-FfmpegArgs $argLine 120000
    if ($null -eq $code -or $code -ne 0 -or -not (Test-Path -LiteralPath $finalPath)) {
        Write-Log ('display mux failed exit={0} - falling back to video only' -f $code)
        if (Convert-TempVideoToMp4 $videoPath $finalPath) {
            Write-Log ('display saved (video only fallback): {0}' -f $finalPath)
            return $true
        }
        return $false
    }
    $sz = (Get-Item -LiteralPath $finalPath).Length
    Write-Log ('display saved (video+audio): {0} ({1} bytes)' -f $finalPath, $sz)
    return $true
}

function Test-DesktopRecording {
    return ($null -ne $script:DisplayProc -and -not $script:DisplayProc.HasExited)
}

function Get-FileSizeSafe([string]$path) {
    try {
        if ($path -and (Test-Path -LiteralPath $path)) { return (Get-Item -LiteralPath $path).Length }
    } catch {}
    return 0
}

function Reset-RecState {
    $script:DisplayProc = $null
    $script:DisplayOut = $null
    $script:DisplayFinal = $null
    $script:DisplayAudioWav = $null
    $script:DisplayHasAudio = $false
    $script:DisplayAudioStartUtc = [datetime]::MinValue
    $script:DisplayVideoStartUtc = [datetime]::MinValue
    $script:DisplayErrFile = $null
    $script:RecKind = $null
}

# Kill leftover ffmpeg processes from prior crashed/stuck REC sessions (command line has webpcap_rec_)
function Stop-OrphanRecFfmpeg {
    param([int]$ExceptPid = 0)
    $killed = 0
    try {
        $procs = Get-CimInstance Win32_Process -Filter "Name = 'ffmpeg.exe'" -ErrorAction SilentlyContinue
        foreach ($proc in @($procs)) {
            if (-not $proc) { continue }
            if ($ExceptPid -and [int]$proc.ProcessId -eq $ExceptPid) { continue }
            $cl = [string]$proc.CommandLine
            if ($cl -and $cl -match 'webpcap_rec_') {
                try {
                    Stop-Process -Id ([int]$proc.ProcessId) -Force -ErrorAction Stop
                    $killed++
                    Write-Log ("orphan ffmpeg killed pid={0}" -f $proc.ProcessId)
                } catch {
                    Write-Log ("orphan ffmpeg kill failed pid={0}: {1}" -f $proc.ProcessId, $_)
                }
            }
        }
    } catch {
        Write-Log "orphan ffmpeg scan: $_"
    }
    return $killed
}

function Clear-StaleRecTemps {
    # Drop abandoned temps older than 2 hours (or zero-byte leftovers)
    try {
        $cutoff = (Get-Date).AddHours(-2)
        Get-ChildItem -Path $env:TEMP -Filter 'webpcap_rec_*' -File -ErrorAction SilentlyContinue | ForEach-Object {
            $drop = ($_.Length -lt 64) -or ($_.LastWriteTime -lt $cutoff)
            if ($drop) {
                try { Remove-Item -Force -LiteralPath $_.FullName -ErrorAction SilentlyContinue } catch {}
            }
        }
    } catch {}
}

function Stop-FfmpegGraceful {
    param(
        [System.Diagnostics.Process]$Process,
        [int]$GraceMs = 8000
    )
    if ($null -eq $Process) { return @{ exited = $true; killed = $false; exitCode = $null } }
    if ($Process.HasExited) {
        return @{ exited = $true; killed = $false; exitCode = $Process.ExitCode }
    }
    # Prefer stdin 'q' + newline. MKV temps do not need long moov finalize; keep total under AHK timeout.
    try {
        if ($Process.StartInfo.RedirectStandardInput) {
            $Process.StandardInput.WriteLine('q')
            $Process.StandardInput.Flush()
        }
    } catch {
        Write-Log "ffmpeg stdin q: $_"
    }
    $qWait = [Math]::Min(3500, $GraceMs)
    if ($Process.WaitForExit($qWait)) {
        return @{ exited = $true; killed = $false; exitCode = $Process.ExitCode }
    }
    try {
        if ($Process.StartInfo.RedirectStandardInput) {
            $Process.StandardInput.Close()
        }
    } catch {}
    $left = [Math]::Max(1500, $GraceMs - $qWait)
    if ($Process.WaitForExit($left)) {
        return @{ exited = $true; killed = $false; exitCode = $Process.ExitCode }
    }
    Write-Log ("ffmpeg stop timeout after {0}ms - force kill pid={1}" -f $GraceMs, $Process.Id)
    try { $Process.Kill() } catch { Write-Log "ffmpeg Kill: $_" }
    try { $Process.WaitForExit(3000) | Out-Null } catch {}
    $code = $null
    try { if ($Process.HasExited) { $code = $Process.ExitCode } } catch {}
    return @{ exited = [bool]$Process.HasExited; killed = $true; exitCode = $code }
}

function Stop-DisplayRecord {
    if ($null -eq $script:DisplayProc -and -not $script:DisplayOut) { return $false }
    $p = $script:DisplayProc
    $tmpVid = $script:DisplayOut
    $final = $script:DisplayFinal
    $wav = $script:DisplayAudioWav
    $kind = $script:RecKind
    if (-not $kind) { $kind = 'display' }

    # Measured A/V start skew (positive = audio began before video)
    $audioLeadSec = 0.0
    if ($script:DisplayAudioStartUtc -ne [datetime]::MinValue -and $script:DisplayVideoStartUtc -ne [datetime]::MinValue) {
        $audioLeadSec = ($script:DisplayVideoStartUtc - $script:DisplayAudioStartUtc).TotalSeconds
        Write-Log ("rec stop A/V lead: audio_ahead={0:0.000}s (audio={1:o} video={2:o})" -f `
            $audioLeadSec, $script:DisplayAudioStartUtc, $script:DisplayVideoStartUtc)
    }

    # Stop audio FIRST so it does not keep recording while ffmpeg finalizes
    Stop-DisplayAudio

    $stopInfo = @{ exited = $true; killed = $false; exitCode = $null }
    try {
        $preSize = Get-FileSizeSafe $tmpVid
        Write-Log ("rec stop begin kind={0} tmpSize={1} pid={2}" -f $kind, $preSize, $(if ($p) { $p.Id } else { 0 }))
        # Keep under AHK 60s stop budget (q + mux). Prefer clean q for moov atom.
        $stopInfo = Stop-FfmpegGraceful -Process $p -GraceMs 10000
        Write-Log ("rec stop ffmpeg exited={0} killed={1} code={2} tmpSize={3}" -f `
            $stopInfo.exited, $stopInfo.killed, $stopInfo.exitCode, (Get-FileSizeSafe $tmpVid))
    } catch {
        Write-Log "rec stop error: $_"
    } finally {
        if ($null -ne $p) { try { $p.Dispose() } catch {} }
        Reset-RecState
    }

    $tmpSize = Get-FileSizeSafe $tmpVid
    # Reject empty stubs; short clips after clean q are multi-KB+
    if (-not $tmpVid -or $tmpSize -lt 1024) {
        Write-Log ('rec stop: no usable video (kind={0} tmp={1} size={2} killed={3})' -f $kind, $tmpVid, $tmpSize, $stopInfo.killed)
        if ($wav) { try { Remove-Item -Force -LiteralPath $wav -ErrorAction SilentlyContinue } catch {} }
        try { if ($tmpVid -and (Test-Path -LiteralPath $tmpVid)) { Remove-Item -Force -LiteralPath $tmpVid -ErrorAction SilentlyContinue } } catch {}
        return $false
    }
    if (-not $final) {
        $prefix = switch ($kind) {
            'window' { 'Window' }
            'region' { 'Region' }
            default { 'Display' }
        }
        $final = Join-Path $VidDir ("{0}_{1}.mp4" -f $prefix, (New-Stamp))
    }

    $ok = Merge-DisplayAv -videoPath $tmpVid -wavPath $wav -finalPath $final -AudioLeadSec $audioLeadSec
    try { if (Test-Path -LiteralPath $tmpVid) { Remove-Item -Force -LiteralPath $tmpVid -ErrorAction SilentlyContinue } } catch {}
    try { if ($wav -and (Test-Path -LiteralPath $wav)) { Remove-Item -Force -LiteralPath $wav -ErrorAction SilentlyContinue } } catch {}
    return $ok
}

function Get-Even([int]$n) {
    if ($n -lt 2) { return 2 }
    if ($n % 2 -ne 0) { return $n - 1 }
    return $n
}

function Get-VirtualScreen {
    # gdigrab desktop coords are virtual-desktop origin (can be negative on multi-monitor)
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue | Out-Null
        $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
        return @{ X = [int]$vs.X; Y = [int]$vs.Y; W = [int]$vs.Width; H = [int]$vs.Height }
    } catch {
        return @{ X = 0; Y = 0; W = 0; H = 0 }
    }
}

function Clamp-CropToVirtual {
    param([int]$X, [int]$Y, [int]$W, [int]$H)
    $vs = Get-VirtualScreen
    if ($vs.W -lt 16 -or $vs.H -lt 16) {
        return @{ X = $X; Y = $Y; W = $W; H = $H; clamped = $false }
    }
    $vx = $vs.X; $vy = $vs.Y; $vw = $vs.W; $vh = $vs.H
    $x2 = $X + $W
    $y2 = $Y + $H
    if ($X -lt $vx) { $X = $vx }
    if ($Y -lt $vy) { $Y = $vy }
    if ($x2 -gt ($vx + $vw)) { $x2 = $vx + $vw }
    if ($y2 -gt ($vy + $vh)) { $y2 = $vy + $vh }
    $W = $x2 - $X
    $H = $y2 - $Y
    if ($W -lt 1) { $W = 1 }
    if ($H -lt 1) { $H = 1 }
    $W = Get-Even $W
    $H = Get-Even $H
    return @{ X = $X; Y = $Y; W = $W; H = $H; clamped = $true }
}

function Fail-DesktopStart {
    param(
        [System.Diagnostics.Process]$Proc,
        [string]$TmpVid,
        [string]$TmpWav,
        [string]$Error,
        [string]$Kind
    )
    try {
        if ($null -ne $Proc -and -not $Proc.HasExited) {
            try { $Proc.Kill() } catch {}
            try { $Proc.WaitForExit(1500) | Out-Null } catch {}
        }
    } catch {}
    if ($null -ne $Proc) { try { $Proc.Dispose() } catch {} }
    Stop-DisplayAudio
    try { if ($TmpWav -and (Test-Path -LiteralPath $TmpWav)) { Remove-Item -Force -LiteralPath $TmpWav -ErrorAction SilentlyContinue } } catch {}
    try { if ($TmpVid -and (Test-Path -LiteralPath $TmpVid)) { Remove-Item -Force -LiteralPath $TmpVid -ErrorAction SilentlyContinue } } catch {}
    Reset-RecState
    [void](Stop-OrphanRecFfmpeg)
    return @{ ok = $false; error = $Error; recording = $false; mode = $Kind }
}

function Start-LoopbackAudio([string]$tmpWav) {
    if ($AudioMode -ne 'system') { return }
    if (-not ('WasapiLoopbackRecorder' -as [type])) {
        Write-Log 'loopback type unavailable - rec will be video-only'
        return
    }
    try {
        $rec = New-Object WasapiLoopbackRecorder
        $rec.Start($tmpWav)
        $script:DisplayAudio = $rec
        $script:DisplayAudioWav = $tmpWav
        $script:DisplayHasAudio = $true
        try {
            $su = $rec.StartedUtc
            if ($su -and $su -ne [datetime]::MinValue) {
                $script:DisplayAudioStartUtc = $su
            } else {
                $script:DisplayAudioStartUtc = [datetime]::UtcNow
            }
        } catch {
            $script:DisplayAudioStartUtc = [datetime]::UtcNow
        }
        Write-Log "loopback start: $tmpWav"
    } catch {
        Write-Log "loopback start failed: $_ - rec will be video-only"
        $script:DisplayAudio = $null
        $script:DisplayAudioWav = $null
        $script:DisplayHasAudio = $false
        $script:DisplayAudioStartUtc = [datetime]::MinValue
    }
}

# kind: display | window | region
# crop optional for window/region (virtual-desktop coords, even WxH for x264)
function Start-DesktopRecord {
    param(
        [ValidateSet('display', 'window', 'region')][string]$Kind = 'display',
        [int]$X = 0,
        [int]$Y = 0,
        [int]$W = 0,
        [int]$H = 0
    )
    if (Test-DesktopRecording) {
        return @{ ok = $false; error = 'already recording'; recording = $true; mode = $script:RecKind }
    }
    if ($script:CanvasRecord) {
        $script:CanvasRecord = $false
        $script:CanvasSeq++
    }
    if (-not (Test-Path $Ffmpeg)) {
        return @{ ok = $false; error = 'ffmpeg not found' }
    }

    # Previous stuck REC left zombie ffmpeg + empty temps; clear before new grab
    [void](Stop-OrphanRecFfmpeg)
    Clear-StaleRecTemps

    $useCrop = ($Kind -eq 'window' -or $Kind -eq 'region')
    if ($useCrop) {
        # gdigrab rejects negative offsets on some builds; Win11 DWM shadow often reports -8,-8
        if ($X -lt 0) { $W += $X; $X = 0 }
        if ($Y -lt 0) { $H += $Y; $Y = 0 }
        if ($W -lt 1) { $W = 1 }
        if ($H -lt 1) { $H = 1 }
        $W = Get-Even $W
        $H = Get-Even $H
        $clamped = Clamp-CropToVirtual -X $X -Y $Y -W $W -H $H
        $X = $clamped.X; $Y = $clamped.Y; $W = $clamped.W; $H = $clamped.H
        if ($W -lt 16 -or $H -lt 16) {
            return @{ ok = $false; error = 'region too small (min 16x16 even)'; recording = $false; mode = $Kind }
        }
    }

    $stamp = New-Stamp
    $prefix = switch ($Kind) {
        'window' { 'Window' }
        'region' { 'Region' }
        default { 'Display' }
    }
    $final = Join-Path $VidDir ("{0}_{1}.mp4" -f $prefix, $stamp)
    # Live temp: plain MP4 WITHOUT +faststart. faststart holds ~0 bytes until clean finalize
    # (kill/crash → empty file → "no video"). Final mux still applies +faststart for players.
    $tmpVid = Join-Path $env:TEMP ("webpcap_rec_{0}.mp4" -f $stamp)
    $tmpWav = Join-Path $env:TEMP ("webpcap_rec_{0}.wav" -f $stamp)

    $script:RecKind = $Kind
    $script:DisplayFinal = $final
    $script:DisplayOut = $tmpVid
    $script:DisplayAudioWav = $null
    $script:DisplayHasAudio = $false
    $script:DisplayAudio = $null
    $script:DisplayAudioStartUtc = [datetime]::MinValue
    $script:DisplayVideoStartUtc = [datetime]::MinValue
    $script:DisplayErrFile = $null

    # gdigrab: full desktop or crop (virtual desktop coords; even size for libx264)
    if ($useCrop) {
        $grab = "-f gdigrab -framerate $Fps -offset_x $X -offset_y $Y -video_size ${W}x${H} -i desktop"
    } else {
        $grab = "-f gdigrab -framerate $Fps -i desktop"
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Ffmpeg
    # -flush_packets 1: surface bytes during record so warmup can detect a live grab
    $psi.Arguments = "-hide_banner -loglevel error -y $grab -c:v libx264 -preset veryfast -pix_fmt yuv420p -crf $Crf -an -flush_packets 1 `"$tmpVid`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi

    # Video first → warmup → then audio (avoids long audio lead during warmup; cleaner fail path)
    if (-not $p.Start()) {
        return (Fail-DesktopStart -Proc $null -TmpVid $tmpVid -TmpWav $tmpWav -Error 'ffmpeg failed to start' -Kind $Kind)
    }
    $script:DisplayVideoStartUtc = [datetime]::UtcNow
    $script:DisplayProc = $p

    Write-Log ("rec start kind={0} crop={1},{2} {3}x{4} tmp={5} final={6} pid={7}" -f `
        $Kind, $X, $Y, $W, $H, $tmpVid, $final, $p.Id)

    Start-Sleep -Milliseconds 350
    if ($p.HasExited) {
        Write-Log ("rec ffmpeg exited early code={0} kind={1}" -f $p.ExitCode, $Kind)
        return (Fail-DesktopStart -Proc $p -TmpVid $tmpVid -TmpWav $tmpWav -Error 'ffmpeg exited immediately (bad crop or grab failed)' -Kind $Kind)
    }

    # Plain MP4 opens ~48 bytes quickly; require any non-empty stub (not 0-byte hang)
    $grew = $false
    for ($i = 0; $i -lt 12; $i++) {
        Start-Sleep -Milliseconds 200
        if ($p.HasExited) { break }
        if ((Get-FileSizeSafe $tmpVid) -ge 32) { $grew = $true; break }
    }
    if ($p.HasExited) {
        Write-Log ("rec ffmpeg exited during warmup code={0} kind={1} size={2}" -f $p.ExitCode, $Kind, (Get-FileSizeSafe $tmpVid))
        return (Fail-DesktopStart -Proc $p -TmpVid $tmpVid -TmpWav $tmpWav -Error 'ffmpeg exited during start (grab failed)' -Kind $Kind)
    }
    if (-not $grew) {
        Write-Log ("rec ffmpeg hung (no output after warmup) kind={0} pid={1}" -f $Kind, $p.Id)
        return (Fail-DesktopStart -Proc $p -TmpVid $tmpVid -TmpWav $tmpWav -Error 'ffmpeg hung (no video frames) - retry REC' -Kind $Kind)
    }

    # Audio after video is confirmed writing (reduces empty WAV + A/V skew from warmup)
    Start-LoopbackAudio $tmpWav
    if ($script:DisplayHasAudio -and $script:DisplayAudioStartUtc -ne [datetime]::MinValue) {
        # Negative lead = video started first (expected now)
        $lead = ($script:DisplayVideoStartUtc - $script:DisplayAudioStartUtc).TotalSeconds
        Write-Log ("rec A/V start skew: audio_ahead={0:0.000}s (negative = video first)" -f $lead)
    }

    Write-Log ("rec warmup ok kind={0} tmpSize={1} audio={2}" -f $Kind, (Get-FileSizeSafe $tmpVid), $script:DisplayHasAudio)
    return @{
        ok        = $true
        path      = $final
        recording = $true
        audio     = $script:DisplayHasAudio
        mode      = $Kind
        x         = $X
        y         = $Y
        w         = $W
        h         = $H
    }
}

function Toggle-DesktopRec {
    param(
        [ValidateSet('display', 'window', 'region')][string]$Kind = 'display',
        [int]$X = 0,
        [int]$Y = 0,
        [int]$W = 0,
        [int]$H = 0
    )
    # Same hotkey again OR any stop: if already recording, stop (any kind)
    if (Test-DesktopRecording) {
        $path = $script:DisplayFinal
        $prev = $script:RecKind
        $ok = Stop-DisplayRecord
        return @{ ok = $ok; recording = $false; path = $path; mode = $prev; stopped = $true; audio = $true }
    }
    $r = Start-DesktopRecord -Kind $Kind -X $X -Y $Y -W $W -H $H
    if (-not $r.ContainsKey('recording')) { $r['recording'] = [bool]$r.ok }
    if (-not $r.ContainsKey('mode')) { $r['mode'] = $Kind }
    return $r
}

function Stop-AnyRec {
    if (Test-DesktopRecording -or $script:DisplayOut) {
        $path = $script:DisplayFinal
        $prev = $script:RecKind
        $ok = Stop-DisplayRecord
        return @{ ok = $ok; recording = $false; path = $path; mode = $prev; stopped = $true }
    }
    if ($script:CanvasRecord) {
        $script:CanvasRecord = $false
        $script:CanvasSeq++
        return @{ ok = $true; recording = $false; mode = 'canvas'; stopped = $true; hint = 'canvas_disarmed' }
    }
    return @{ ok = $true; recording = $false; stopped = $false; hint = 'nothing_recording' }
}

function Toggle-Display {
    return Toggle-DesktopRec -Kind 'display'
}

function Toggle-Canvas {
    if ($null -ne $script:DisplayProc -and -not $script:DisplayProc.HasExited) {
        [void](Stop-DisplayRecord)
    }
    $script:CanvasRecord = -not $script:CanvasRecord
    $script:CanvasSeq++
    $helper = Test-CanvasHelperAlive
    Write-Log ("canvas toggle: record={0} seq={1} helper={2}" -f $script:CanvasRecord, $script:CanvasSeq, $helper)
    return @{
        ok        = $true
        mode      = 'canvas'
        recording = $script:CanvasRecord
        seq       = $script:CanvasSeq
        helper    = $helper
        hint      = if ($helper) { 'helper_online' } else { 'no_helper_open_page_with_script' }
    }
}

function Save-CanvasUpload([byte[]]$bytes, [string]$ext) {
    if (-not $ext) { $ext = 'webm' }
    $ext = $ext.TrimStart('.').ToLowerInvariant()
    if ($ext -notin @('webm', 'mp4', 'mkv')) { $ext = 'webm' }
    $stamp = New-Stamp
    $raw = Join-Path $env:TEMP ("webpcap_canvas_$stamp.$ext")
    $mp4 = Join-Path $VidDir ("Canvas_{0}.mp4" -f $stamp)
    [IO.File]::WriteAllBytes($raw, $bytes)
    Write-Log "canvas upload: $raw ($($bytes.Length) bytes)"

    if ($ext -eq 'mp4') {
        Move-Item -Force $raw $mp4
        return @{ ok = $true; path = $mp4 }
    }
    if (-not (Test-Path $Ffmpeg)) {
        Move-Item -Force $raw (Join-Path $VidDir ("Canvas_{0}.$ext" -f $stamp))
        return @{ ok = $false; error = 'ffmpeg not found'; path = $raw }
    }
    $argLine = "-hide_banner -loglevel error -y -i `"$raw`" -c:v libx264 -preset veryfast -pix_fmt yuv420p -crf $Crf -an -movflags +faststart `"$mp4`""
    $p = Start-Process -FilePath $Ffmpeg -ArgumentList $argLine -Wait -PassThru -WindowStyle Hidden
    try { Remove-Item -Force $raw -ErrorAction SilentlyContinue } catch {}
    if ($null -eq $p -or $p.ExitCode -ne 0 -or -not (Test-Path $mp4)) {
        $code = if ($null -eq $p) { 'null' } else { $p.ExitCode }
        Write-Log "canvas ffmpeg exit $code"
        return @{ ok = $false; error = 'ffmpeg encode failed' }
    }
    Write-Log "canvas saved: $mp4 ($((Get-Item $mp4).Length) bytes)"
    return @{ ok = $true; path = $mp4 }
}

function Send-Json($ctx, $obj, [int]$code = 200) {
    $json = ($obj | ConvertTo-Json -Compress -Depth 6)
    $buf = [Text.Encoding]::UTF8.GetBytes($json)
    $ctx.Response.StatusCode = $code
    $ctx.Response.ContentType = 'application/json; charset=utf-8'
    Add-Cors $ctx
    $ctx.Response.ContentLength64 = $buf.Length
    $ctx.Response.OutputStream.Write($buf, 0, $buf.Length)
    $ctx.Response.OutputStream.Close()
}

function Send-Text($ctx, [string]$text, [string]$contentType, [int]$code = 200) {
    $buf = [Text.Encoding]::UTF8.GetBytes($text)
    $ctx.Response.StatusCode = $code
    $ctx.Response.ContentType = $contentType
    Add-Cors $ctx
    $ctx.Response.ContentLength64 = $buf.Length
    $ctx.Response.OutputStream.Write($buf, 0, $buf.Length)
    $ctx.Response.OutputStream.Close()
}

function Send-Bytes($ctx, [byte[]]$buf, [string]$contentType, [int]$code = 200) {
    $ctx.Response.StatusCode = $code
    $ctx.Response.ContentType = $contentType
    Add-Cors $ctx
    $ctx.Response.ContentLength64 = $buf.Length
    $ctx.Response.OutputStream.Write($buf, 0, $buf.Length)
    $ctx.Response.OutputStream.Close()
}

function Add-Cors($ctx) {
    $ctx.Response.Headers['Access-Control-Allow-Origin'] = '*'
    $ctx.Response.Headers['Access-Control-Allow-Methods'] = 'GET, POST, OPTIONS'
    $ctx.Response.Headers['Access-Control-Allow-Headers'] = 'Content-Type'
    $ctx.Response.Headers['Access-Control-Allow-Private-Network'] = 'true'
}

function Read-BodyBytes($ctx) {
    $ms = New-Object IO.MemoryStream
    $ctx.Request.InputStream.CopyTo($ms)
    return $ms.ToArray()
}

function Handle-Request($ctx) {
    $method = $ctx.Request.HttpMethod.ToUpperInvariant()
    $path = $ctx.Request.Url.AbsolutePath.TrimEnd('/').ToLowerInvariant()
    if (-not $path) { $path = '/' }

    if ($method -eq 'OPTIONS') {
        $ctx.Response.StatusCode = 204
        Add-Cors $ctx
        $ctx.Response.OutputStream.Close()
        return
    }

    try {
        switch -Regex ($path) {
            '^/health$' {
                $disp = Test-DesktopRecording
                Send-Json $ctx @{
                    ok               = $true
                    port             = $Port
                    viddir           = $VidDir
                    audio            = $AudioMode
                    displayRecording = $disp
                    recKind          = $script:RecKind
                    displayAudio     = [bool]$script:DisplayHasAudio
                    canvasRecording  = $script:CanvasRecord
                    canvasSeq        = $script:CanvasSeq
                    helper           = (Test-CanvasHelperAlive)
                }
            }
            '^/display/toggle$' {
                if ($method -ne 'POST') { Send-Json $ctx @{ ok = $false; error = 'POST only' } 405; return }
                $r = $null
                [System.Threading.Monitor]::Enter($script:Lock)
                try { $r = Toggle-DesktopRec -Kind 'display' } finally { [System.Threading.Monitor]::Exit($script:Lock) }
                Send-Json $ctx $r
            }
            '^/window/toggle$' {
                if ($method -ne 'POST') { Send-Json $ctx @{ ok = $false; error = 'POST only' } 405; return }
                $qx = 0; $qy = 0; $qw = 0; $qh = 0
                try { $qx = [int]$ctx.Request.QueryString['x'] } catch {}
                try { $qy = [int]$ctx.Request.QueryString['y'] } catch {}
                try { $qw = [int]$ctx.Request.QueryString['w'] } catch {}
                try { $qh = [int]$ctx.Request.QueryString['h'] } catch {}
                $r = $null
                [System.Threading.Monitor]::Enter($script:Lock)
                try {
                    if (Test-DesktopRecording) {
                        $r = Toggle-DesktopRec -Kind 'window'
                    } else {
                        $r = Toggle-DesktopRec -Kind 'window' -X $qx -Y $qy -W $qw -H $qh
                    }
                } finally { [System.Threading.Monitor]::Exit($script:Lock) }
                Send-Json $ctx $r
            }
            '^/region/toggle$' {
                if ($method -ne 'POST') { Send-Json $ctx @{ ok = $false; error = 'POST only' } 405; return }
                $qx = 0; $qy = 0; $qw = 0; $qh = 0
                try { $qx = [int]$ctx.Request.QueryString['x'] } catch {}
                try { $qy = [int]$ctx.Request.QueryString['y'] } catch {}
                try { $qw = [int]$ctx.Request.QueryString['w'] } catch {}
                try { $qh = [int]$ctx.Request.QueryString['h'] } catch {}
                $r = $null
                [System.Threading.Monitor]::Enter($script:Lock)
                try {
                    if (Test-DesktopRecording) {
                        $r = Toggle-DesktopRec -Kind 'region'
                    } else {
                        $r = Toggle-DesktopRec -Kind 'region' -X $qx -Y $qy -W $qw -H $qh
                    }
                } finally { [System.Threading.Monitor]::Exit($script:Lock) }
                Send-Json $ctx $r
            }
            '^/rec/stop$' {
                if ($method -ne 'POST') { Send-Json $ctx @{ ok = $false; error = 'POST only' } 405; return }
                $r = $null
                [System.Threading.Monitor]::Enter($script:Lock)
                try { $r = Stop-AnyRec } finally { [System.Threading.Monitor]::Exit($script:Lock) }
                Send-Json $ctx $r
            }
            '^/canvas/toggle$' {
                if ($method -ne 'POST') { Send-Json $ctx @{ ok = $false; error = 'POST only' } 405; return }
                $r = $null
                [System.Threading.Monitor]::Enter($script:Lock)
                try { $r = Toggle-Canvas } finally { [System.Threading.Monitor]::Exit($script:Lock) }
                Send-Json $ctx $r
            }
            '^/canvas/state$' {
                Note-CanvasClient
                Send-Json $ctx @{
                    ok        = $true
                    record    = $script:CanvasRecord
                    seq       = $script:CanvasSeq
                    recording = $script:CanvasRecord
                    helper    = $true
                }
            }
            '^/canvas/upload$' {
                if ($method -ne 'POST') { Send-Json $ctx @{ ok = $false; error = 'POST only' } 405; return }
                $ext = $ctx.Request.QueryString['ext']
                if (-not $ext) { $ext = 'webm' }
                $bytes = Read-BodyBytes $ctx
                if ($bytes.Length -lt 32) {
                    Send-Json $ctx @{ ok = $false; error = 'empty body' } 400
                    return
                }
                $r = $null
                [System.Threading.Monitor]::Enter($script:Lock)
                try {
                    $script:CanvasRecord = $false
                    $script:CanvasSeq++
                    $script:LastUploadUtc = [datetime]::UtcNow
                    $r = Save-CanvasUpload $bytes $ext
                } finally {
                    [System.Threading.Monitor]::Exit($script:Lock)
                }
                Send-Json $ctx $r
            }
            '^/webpcap-canvas\.js$' {
                $jsPath = Join-Path $Root 'webpcap-canvas.js'
                if (-not (Test-Path $jsPath)) {
                    Send-Json $ctx @{ ok = $false; error = 'js missing' } 404
                    return
                }
                $bytes = [IO.File]::ReadAllBytes($jsPath)
                Send-Bytes $ctx $bytes 'application/javascript; charset=utf-8'
            }
            default {
                Send-Json $ctx @{ ok = $false; error = 'not found'; path = $path } 404
            }
        }
    } catch {
        Write-Log "request error: $_"
        try { Send-Json $ctx @{ ok = $false; error = "$_" } 500 } catch {}
    }
}

# --- main ---
$oldPid = $null
if (Test-Path $pidFile) {
    try { $oldPid = [int](Get-Content $pidFile -Raw).Trim() } catch {}
    if ($oldPid -and $oldPid -ne $PID) {
        Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 300
    }
}
$PID | Set-Content $pidFile -Encoding ASCII

# Clear zombies from prior host crash (stuck gdigrab left empty REC files)
$nOrphan = Stop-OrphanRecFfmpeg
Clear-StaleRecTemps
if ($nOrphan -gt 0) { Write-Log "startup cleaned $nOrphan orphan ffmpeg" }

$listener = New-Object System.Net.HttpListener
$prefix = "http://127.0.0.1:$Port/"
$listener.Prefixes.Add($prefix)
try {
    $listener.Start()
} catch {
    Write-Log "listener failed on $prefix : $_"
    throw
}
Write-Log "video-host listening $prefix viddir=$VidDir ffmpeg=$Ffmpeg audio=$AudioMode audio_delay_ms=$AudioDelayMs"

try {
    while ($listener.IsListening) {
        $ctx = $null
        try {
            $ctx = $listener.GetContext()
            Handle-Request $ctx
        } catch {
            if ($listener.IsListening) { Write-Log "loop: $_" }
        }
    }
} finally {
    try { [void](Stop-DisplayRecord) } catch {}
    try { $listener.Stop() } catch {}
    try { $listener.Close() } catch {}
    try { Remove-Item $pidFile -Force -ErrorAction SilentlyContinue } catch {}
    Write-Log 'video-host stopped'
}
