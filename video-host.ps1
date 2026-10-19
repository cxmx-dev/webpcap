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

$Ffmpeg = Expand-EnvPath (Get-IniValue $IniPath 'paths' 'ffmpeg' 'ffmpeg.exe')
# 2026-10-02: REC uses the system-drive ffmpeg (same as CAPS). An ffmpeg on a drive that spins down
# took seconds to wake (slow REC start, host startup loop). Optional [paths] rec_ffmpeg wins.
$recFf = Expand-EnvPath (Get-IniValue $IniPath 'paths' 'rec_ffmpeg' '')
if ($recFf -and (Test-Path -LiteralPath $recFf)) { $Ffmpeg = $recFf }
if (-not (Test-Path -LiteralPath $Ffmpeg)) {
    foreach ($cand in @((Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\ffmpeg.exe'), (Join-Path $env:ProgramFiles 'ffmpeg\bin\ffmpeg.exe'))) {
        if (Test-Path -LiteralPath $cand) { $Ffmpeg = $cand; break }
    }
}
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
$EncoderPref = (Get-IniValue $IniPath 'video' 'encoder' 'auto').Trim().ToLowerInvariant()
if ($EncoderPref -notin @('auto', 'nvenc', 'x264')) { $EncoderPref = 'auto' }
$CapturePref = (Get-IniValue $IniPath 'video' 'capture' 'auto').Trim().ToLowerInvariant()
if ($CapturePref -notin @('auto', 'ddagrab', 'gdigrab')) { $CapturePref = 'auto' }
$script:HaveNvenc = $false
$script:HaveDdagrab = $false
$script:ActiveEncoder = 'x264'
$script:ActiveCapture = 'gdigrab'
# 2026-10-02: mid-REC capture loss (ddagrab ends on display mode change) -> restart as a new segment
$MaxSegRestarts = 5
try { $MaxSegRestarts = [Math]::Max(0, [int](Get-IniValue $IniPath 'video' 'rec_restarts' '5')) } catch { $MaxSegRestarts = 5 }
# 2026-10-17: [capture] rec_screen = mouse | primary | all - which monitor full-display REC records.
# mouse = monitor under the cursor when REC starts (the AHK sends its rect), primary = primary,
# all = legacy (ddagrab output 0 / gdigrab whole desktop). Stills use [capture] screen in the AHK.
$RecScreen = (Get-IniValue $IniPath 'capture' 'rec_screen' 'mouse').Trim().ToLowerInvariant()
if ($RecScreen -notin @('mouse', 'primary', 'all')) { $RecScreen = 'mouse' }
$RecOutputPref = (Get-IniValue $IniPath 'capture' 'rec_output' 'auto').Trim().ToLowerInvariant()
$script:DdaOutput = 0
# Current REC target: DXGI device name (\\.\DISPLAYn) + last known rect; re-resolved on every
# (re)start so ddagrab output_idx / gdigrab bounds follow that monitor even after a mode change.
$script:RecDevice = ''
$script:RecRect = $null

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
$script:DisplayErrFile = $null      # ffmpeg stderr report (FFREPORT) for the current segment
$script:DisplayAudioStartUtcSaved = [datetime]::MinValue
$script:RecKind = $null             # display | window | region
# Segmented REC (2026-10-02): finished segments + params to restart capture after it dies
$script:RecSegments = New-Object System.Collections.ArrayList
$script:RecSegIndex = 0
$script:RecStamp = $null
$script:RecParams = $null
$script:RecRestarts = 0
$script:SegStartUtc = [datetime]::MinValue
# Last REC that ended WITHOUT a user stop (AHK health poll shows a tip and drops the red light)
$script:RecEndSeq = 0
$script:RecEndReason = ''
$script:RecEndPath = ''
$script:RecEndOk = $false
$script:RecEndUtc = [datetime]::MinValue
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
    try {
        $wavLen = 0; if ($script:DisplayAudioWav -and (Test-Path -LiteralPath $script:DisplayAudioWav)) { $wavLen = (Get-Item -LiteralPath $script:DisplayAudioWav).Length }
        Write-Log ("loopback stop: device='{0}' wav={1} bytes silence_padded_frames={2} events: {3}" -f $rec.DeviceName, $wavLen, $rec.PaddedFrames, $(if ($rec.Events) { $rec.Events } else { 'none' }))
    } catch {}
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
        [double]$AudioLeadSec = 0,
        [switch]$Aligned
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
    if ($Aligned) { $adj = 0 }
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

# REC session active = a temp segment is assigned (ffmpeg may be between segments)
function Test-RecSession {
    return [bool]$script:DisplayOut
}

# ffmpeg stderr -> file via FFREPORT (no pipe to drain; works with stdin 'q' stop)
function ConvertTo-FfReportPath([string]$path) {
    return (($path -replace '\\', '/') -replace ':', '\:')
}

function Get-ErrTail([string]$errFile, [int]$n = 6) {
    try {
        if ($errFile -and (Test-Path -LiteralPath $errFile)) {
            $lines = @(Get-Content -LiteralPath $errFile -Tail 40 -ErrorAction SilentlyContinue | Where-Object { $_ -and $_ -notmatch '^(ffmpeg started on|Report written to|Command line:|"|\s*$)' })
            if ($lines.Count -gt $n) { $lines = $lines[($lines.Count - $n)..($lines.Count - 1)] }
            if ($lines.Count) { return (($lines | ForEach-Object { $_.Trim() }) -join ' | ') }
        }
    } catch {}
    return '(no stderr)'
}

function New-RecFfmpegProcess {
    param([string]$Cap, [string]$Enc, [bool]$UseCrop, [int]$X, [int]$Y, [int]$W, [int]$H, [string]$TmpVid, [string]$ErrFile)
    $grab = Get-VideoGrabArgs -Capture $Cap -UseCrop $UseCrop -X $X -Y $Y -W $W -H $H
    $encArgs = Get-VideoEncodeArgs -Encoder $Enc -Capture $Cap
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Ffmpeg
    # Fragmented temp MP4 (0.5 s fragments): a segment whose ffmpeg is killed/crashes stays
    # readable up to its last fragment (plain MP4 needs the moov written at a clean exit).
    $psi.Arguments = "-hide_banner -loglevel error -y $grab $encArgs -an -flush_packets 1 -movflags +empty_moov+default_base_moof -frag_duration 500000 `"$TmpVid`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    if ($ErrFile) {
        try { Remove-Item -Force -LiteralPath $ErrFile -ErrorAction SilentlyContinue } catch {}
        $psi.EnvironmentVariables['FFREPORT'] = 'file=' + (ConvertTo-FfReportPath $ErrFile) + ':level=24'
    }
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    if (-not $p.Start()) { return $null }
    try { $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::High } catch {}
    return $p
}

# Width/height/duration of a finished temp video (parses `ffmpeg -i` stderr)
function Get-VideoInfo([string]$path) {
    $info = @{ w = 0; h = 0; dur = 0.0 }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $Ffmpeg
        $psi.Arguments = "-hide_banner -i `"$path`""
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardError = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $txt = $p.StandardError.ReadToEnd()
        [void]$p.WaitForExit(15000)
        try { $p.Dispose() } catch {}
        if ($txt -match 'Video:.*?\b(\d{2,5})x(\d{2,5})\b') { $info.w = [int]$Matches[1]; $info.h = [int]$Matches[2] }
        if ($txt -match 'Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)') {
            $info.dur = [int]$Matches[1] * 3600 + [int]$Matches[2] * 60 + [double]::Parse($Matches[3], [System.Globalization.CultureInfo]::InvariantCulture)
        }
    } catch { Write-Log "video info failed ${path}: $_" }
    return $info
}

function Wait-RecWarmup([System.Diagnostics.Process]$p, [string]$tmpVid, [int]$tries = 20) {
    for ($i = 0; $i -lt $tries; $i++) {
        Start-Sleep -Milliseconds 250
        if ($p.HasExited) { return $false }
        if ((Get-FileSizeSafe $tmpVid) -ge 2048) { return $true }
    }
    return $false
}

# Called from the main loop (every 500 ms) and /health: notices ffmpeg ending mid-REC,
# restarts capture as a new segment (same capture, then gdigrab), else auto-finalizes.
function Invoke-RecSupervisor {
    if (-not $script:DisplayOut) { return }
    $p = $script:DisplayProc
    if ($null -eq $p -or -not $p.HasExited) { return }
    $code = $null
    try { $code = $p.ExitCode } catch {}
    $seg = $script:DisplayOut
    $size = Get-FileSizeSafe $seg
    $cap = if ($script:RecParams) { $script:RecParams.Cap } else { '?' }
    Write-Log ("rec ffmpeg exited mid-REC code={0} seg={1} size={2} cap={3} stderr: {4}" -f $code, $script:RecSegIndex, $size, $cap, (Get-ErrTail $script:DisplayErrFile))
    try { $p.Dispose() } catch {}
    $script:DisplayProc = $null
    if ($size -ge 1024) {
        [void]$script:RecSegments.Add(@{ path = $seg; err = $script:DisplayErrFile; startUtc = $script:SegStartUtc })
    } else {
        try { Remove-Item -Force -LiteralPath $seg -ErrorAction SilentlyContinue } catch {}
    }
    if ($script:RecParams -and $script:RecRestarts -lt $MaxSegRestarts) {
        $script:RecRestarts++
        if (Start-RecSegment) { return }
    }
    Write-Log ("rec capture lost - auto-finalizing ({0} segment(s), restarts={1})" -f $script:RecSegments.Count, $script:RecRestarts)
    $path = $script:DisplayFinal
    $ok = $false
    try { $ok = Stop-DisplayRecord } catch { Write-Log "auto-finalize error: $_" }
    $script:RecEndSeq++
    $script:RecEndReason = 'capture_lost'
    $script:RecEndPath = $(if ($ok) { $path } else { '' })
    $script:RecEndOk = [bool]$ok
    $script:RecEndUtc = [datetime]::UtcNow
    Write-Log ("rec ended without user stop: reason=capture_lost ok={0} path={1}" -f $ok, $script:RecEndPath)
}

function Start-RecSegment {
    $rp = $script:RecParams
    $script:RecSegIndex++
    $tmp = Join-Path $env:TEMP ("webpcap_rec_{0}_s{1}.mp4" -f $script:RecStamp, $script:RecSegIndex)
    $caps = @($rp.Cap)
    if ($rp.Cap -eq 'ddagrab' -and -not $rp.UseCrop -and (Get-RecTargetNow).Idx -lt 0) { $caps = @() }
    if ($rp.Cap -ne 'gdigrab') { $caps += 'gdigrab' }
    Start-Sleep -Milliseconds 500   # let a display mode switch settle
    foreach ($cap in $caps) {
        $enc = $rp.Enc
        $err = [IO.Path]::ChangeExtension($tmp, ".$cap.err")
        try { Remove-Item -Force -LiteralPath $tmp -ErrorAction SilentlyContinue } catch {}
        $useCrop = $rp.UseCrop
        $p = New-RecFfmpegProcess -Cap $cap -Enc $enc -UseCrop $useCrop -X $rp.X -Y $rp.Y -W $rp.W -H $rp.H -TmpVid $tmp -ErrFile $err
        if ($null -eq $p) { Write-Log "rec segment $($script:RecSegIndex) launch failed cap=$cap"; continue }
        $startUtc = [datetime]::UtcNow
        if (Wait-RecWarmup $p $tmp) {
            $script:DisplayProc = $p
            $script:DisplayOut = $tmp
            $script:DisplayErrFile = $err
            $script:SegStartUtc = $startUtc
            Write-Log ("rec segment {0} restarted cap={1} enc={2} pid={3} tmp={4}" -f $script:RecSegIndex, $cap, $enc, $p.Id, $tmp)
            return $true
        }
        Write-Log ("rec segment {0} restart failed cap={1} exited={2} stderr: {3}" -f $script:RecSegIndex, $cap, $p.HasExited, (Get-ErrTail $err))
        try { if (-not $p.HasExited) { $p.Kill(); [void]$p.WaitForExit(2000) } } catch {}
        try { $p.Dispose() } catch {}
        try { Remove-Item -Force -LiteralPath $tmp -ErrorAction SilentlyContinue } catch {}
    }
    return $false
}

# Join >1 segment into one temp video. Same size: stream copy. Different size (mode change):
# re-encode, scaled/padded to the largest segment. Returns joined path or the largest segment.
function Join-RecSegments([object[]]$segs, [string]$outPath) {
    $infos = @()
    foreach ($sg in $segs) {
        $i = Get-VideoInfo $sg.path; $i.path = $sg.path
        if ($i.w -gt 0 -and $i.dur -gt 0.05) { $infos += $i } else { Write-Log ("rec join: skipping unreadable segment {0}" -f $sg.path) }
    }
    if ($infos.Count -eq 0) { return @{ path = $segs[0].path; infos = @() } }
    if ($infos.Count -eq 1) { return @{ path = $infos[0].path; infos = $infos } }
    $same = $true
    foreach ($i in $infos) { if ($i.w -ne $infos[0].w -or $i.h -ne $infos[0].h -or $i.w -eq 0) { $same = $false } }
    Write-Log ("rec join {0} segments same_size={1} sizes={2}" -f $infos.Count, $same, (($infos | ForEach-Object { '{0}x{1}/{2:0.0}s' -f $_.w, $_.h, $_.dur }) -join ','))
    if ($same) {
        $list = [IO.Path]::ChangeExtension($outPath, '.txt')
        $lines = $infos | ForEach-Object { "file '" + ($_.path -replace '\\', '/') + "'" }
        [IO.File]::WriteAllLines($list, [string[]]$lines)
        $code = Invoke-FfmpegArgs "-hide_banner -loglevel error -y -f concat -safe 0 -i `"$list`" -c copy `"$outPath`"" 120000
        try { Remove-Item -Force -LiteralPath $list -ErrorAction SilentlyContinue } catch {}
    } else {
        $big = $infos | Sort-Object { $_.w * $_.h } -Descending | Select-Object -First 1
        $tw = Get-Even $big.w; $th = Get-Even $big.h
        $in = ''; $fc = ''; $labels = ''
        for ($k = 0; $k -lt $infos.Count; $k++) {
            $in += " -i `"$($infos[$k].path)`""
            $fc += "[${k}:v]scale=${tw}:${th}:force_original_aspect_ratio=decrease,pad=${tw}:${th}:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=${Fps},format=yuv420p[v$k];"
            $labels += "[v$k]"
        }
        $fc += "${labels}concat=n=$($infos.Count):v=1:a=0[vout]"
        $venc = if ($script:HaveNvenc) { "-c:v h264_nvenc -preset p4 -rc constqp -qp $Crf -bf 0" } else { "-c:v libx264 -preset veryfast -crf $Crf -pix_fmt yuv420p" }
        $code = Invoke-FfmpegArgs "-hide_banner -loglevel error -y$in -filter_complex `"$fc`" -map `"[vout]`" $venc `"$outPath`"" 600000
    }
    if ($code -eq 0 -and (Get-FileSizeSafe $outPath) -gt 1024) { return @{ path = $outPath; infos = $infos } }
    Write-Log "rec join failed exit=$code - keeping largest segment only"
    $best = $infos | Sort-Object { (Get-FileSizeSafe $_.path) } -Descending | Select-Object -First 1
    return @{ path = $best.path; infos = @($best) }
}

# One WAV covering only the time windows that have video (drops audio from restart gaps),
# so A/V stay in sync after the segments are joined.
function New-AlignedWav([string]$wav, [object[]]$segs, [object[]]$infos, [string]$outWav) {
    if ($script:DisplayAudioStartUtcSaved -eq [datetime]::MinValue) { return $null }
    $fc = ''; $labels = ''; $n = 0
    for ($k = 0; $k -lt $segs.Count; $k++) {
        $dur = 0.0
        foreach ($i in $infos) { if ($i.path -eq $segs[$k].path) { $dur = $i.dur } }
        if ($dur -le 0.05) { continue }
        $st = ($segs[$k].startUtc - $script:DisplayAudioStartUtcSaved).TotalSeconds + ($AudioDelayMs / 1000.0)
        if ($st -ge 0) {
            $fc += "[0:a]atrim=start=$(Format-FfmpegSeconds $st):duration=$(Format-FfmpegSeconds $dur),asetpts=PTS-STARTPTS[a$n];"
        } else {
            $pad = [int][Math]::Round(-$st * 1000)
            $fc += "[0:a]atrim=start=0:duration=$(Format-FfmpegSeconds ($dur + $st)),asetpts=PTS-STARTPTS,adelay=delays=${pad}:all=1[a$n];"
        }
        $labels += "[a$n]"; $n++
    }
    if ($n -lt 1) { return $null }
    $fc += "${labels}concat=n=${n}:v=0:a=1[aout]"
    $code = Invoke-FfmpegArgs "-hide_banner -loglevel error -y -i `"$wav`" -filter_complex `"$fc`" -map `"[aout]`" -c:a pcm_s16le `"$outWav`"" 120000
    if ($code -eq 0 -and (Get-FileSizeSafe $outWav) -gt 128) { return $outWav }
    Write-Log "rec aligned audio failed exit=$code - using raw WAV"
    return $null
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
    $script:RecSegments = New-Object System.Collections.ArrayList
    $script:RecSegIndex = 0
    $script:RecStamp = $null
    $script:RecParams = $null
    $script:RecRestarts = 0
    $script:SegStartUtc = [datetime]::MinValue
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
    $errFile = $script:DisplayErrFile
    $segs = @($script:RecSegments)
    $curStartUtc = $script:SegStartUtc
    $script:DisplayAudioStartUtcSaved = $script:DisplayAudioStartUtc

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
        if ($null -ne $stopInfo.exitCode -and $stopInfo.exitCode -ne 0) {
            Write-Log ("rec stop ffmpeg stderr: {0}" -f (Get-ErrTail $errFile))
        }
    } catch {
        Write-Log "rec stop error: $_"
    } finally {
        if ($null -ne $p) { try { $p.Dispose() } catch {} }
        Reset-RecState
    }

    $tmpSize = Get-FileSizeSafe $tmpVid
    # Segments: earlier ones (capture restarted mid-REC) + the current one if usable
    $known = @($segs | ForEach-Object { $_.path })
    if ($tmpVid -and ($known -notcontains $tmpVid)) {
        if ($tmpSize -ge 1024) { $segs += @{ path = $tmpVid; err = $errFile; startUtc = $curStartUtc } }
        else { try { Remove-Item -Force -LiteralPath $tmpVid -ErrorAction SilentlyContinue } catch {} }
    }
    $allErr = @($segs | ForEach-Object { $_.err }) + @($errFile)
    # Reject empty stubs; short clips after clean q are multi-KB+
    if ($segs.Count -lt 1) {
        Write-Log ('rec stop: no usable video (kind={0} tmp={1} size={2} killed={3})' -f $kind, $tmpVid, $tmpSize, $stopInfo.killed)
        if ($wav) { try { Remove-Item -Force -LiteralPath $wav -ErrorAction SilentlyContinue } catch {} }
        return $false
    }
    $joined = $null; $alignedWav = $null
    if ($segs.Count -gt 1) {
        $j = Join-RecSegments $segs ([IO.Path]::ChangeExtension($segs[0].path, '.joined.mp4'))
        $tmpVid = $j.path
        if ($j.path -like '*.joined.mp4') { $joined = $j.path }
        if ($wav -and (Get-FileSizeSafe $wav) -gt 128) {
            $useSegs = @($segs | Where-Object { $j.infos.path -contains $_.path })
            $alignedWav = New-AlignedWav $wav $useSegs $j.infos ([IO.Path]::ChangeExtension($wav, '.aligned.wav'))
        }
    } else {
        $tmpVid = $segs[0].path
    }
    if (-not $final) {
        $prefix = switch ($kind) {
            'window' { 'Window' }
            'region' { 'Region' }
            default { 'Display' }
        }
        $final = Join-Path $VidDir ("{0}_{1}.mp4" -f $prefix, (New-Stamp))
    }

    if ($alignedWav) {
        $ok = Merge-DisplayAv -videoPath $tmpVid -wavPath $alignedWav -finalPath $final -Aligned
    } else {
        $ok = Merge-DisplayAv -videoPath $tmpVid -wavPath $wav -finalPath $final -AudioLeadSec $audioLeadSec
    }
    foreach ($f in (@($segs | ForEach-Object { $_.path }) + @($joined, $wav, $alignedWav))) {
        try { if ($f -and (Test-Path -LiteralPath $f)) { Remove-Item -Force -LiteralPath $f -ErrorAction SilentlyContinue } } catch {}
    }
    # stderr reports: drop on success, keep (aged out after 2 h) when the save failed
    if ($ok) { foreach ($f in $allErr) { try { if ($f -and (Test-Path -LiteralPath $f)) { Remove-Item -Force -LiteralPath $f -ErrorAction SilentlyContinue } } catch {} } }
    return $ok
}

function Get-Even([int]$n) {
    if ($n -lt 2) { return 2 }
    if ($n % 2 -ne 0) { return $n - 1 }
    return $n
}

# Primary monitor in physical pixels. Its top-left is always 0,0 in desktop coords.
function Get-PrimaryScreen {
    try {
        if (-not ('WpcScreen' -as [type])) {
            Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public static class WpcScreen {
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int i);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
    public static int[] Primary() {
        IntPtr old = IntPtr.Zero;
        try { old = SetThreadDpiAwarenessContext(new IntPtr(-4)); } catch {}
        int w = GetSystemMetrics(0), h = GetSystemMetrics(1);
        if (old != IntPtr.Zero) { try { SetThreadDpiAwarenessContext(old); } catch {} }
        return new int[] { w, h };
    }
}
"@
        }
        $wh = [WpcScreen]::Primary()
        return @{ X = 0; Y = 0; W = [int]$wh[0]; H = [int]$wh[1] }
    } catch {
        return @{ X = 0; Y = 0; W = 0; H = 0 }
    }
}

# DXGI outputs of the default adapter = what ffmpeg ddagrab opens (EnumOutputs order = output_idx).
# Verified 2026-10-17 against ffmpeg "Opened dxgi output N with dimensions WxH".
function Get-DxgiOutputs {
    try {
        if (-not ('WpcDxgi' -as [type])) {
            Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices; using System.Collections.Generic;
public static class WpcDxgi {
    [DllImport("dxgi.dll")] static extern int CreateDXGIFactory1(ref Guid riid, out IntPtr f);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int EnumFn(IntPtr self, uint i, out IntPtr o);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate int DescFn(IntPtr self, IntPtr d);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate uint RelFn(IntPtr self);
    static T V<T>(IntPtr o, int slot) { IntPtr vt = Marshal.ReadIntPtr(o); return (T)(object)Marshal.GetDelegateForFunctionPointer(Marshal.ReadIntPtr(vt, slot * IntPtr.Size), typeof(T)); }
    static void Rel(IntPtr o) { if (o != IntPtr.Zero) V<RelFn>(o, 2)(o); }
    // "idx|L|T|R|B|attached|device" for adapter 0
    public static string[] Outputs() {
        var r = new List<string>(); Guid g = new Guid("770aae78-f26f-4dba-a829-253c83d1b387"); IntPtr f;
        if (CreateDXGIFactory1(ref g, out f) != 0) return r.ToArray();
        IntPtr a;
        if (V<EnumFn>(f, 7)(f, 0, out a) == 0) {
            for (uint i = 0; i < 16; i++) {
                IntPtr o; if (V<EnumFn>(a, 7)(a, i, out o) != 0) break;
                IntPtr d = Marshal.AllocHGlobal(96);
                if (V<DescFn>(o, 7)(o, d) == 0) {
                    string name = Marshal.PtrToStringUni(d, 32).TrimEnd('\0');
                    r.Add(String.Format("{0}|{1}|{2}|{3}|{4}|{5}|{6}", i, Marshal.ReadInt32(d, 64), Marshal.ReadInt32(d, 68), Marshal.ReadInt32(d, 72), Marshal.ReadInt32(d, 76), Marshal.ReadInt32(d, 80), name));
                }
                Marshal.FreeHGlobal(d); Rel(o);
            }
            Rel(a);
        }
        Rel(f); return r.ToArray();
    }
}
"@
        }
        return @([WpcDxgi]::Outputs() | ForEach-Object {
            $p = $_ -split '\|'
            @{ Idx = [int]$p[0]; X = [int]$p[1]; Y = [int]$p[2]; W = [int]$p[3] - [int]$p[1]; H = [int]$p[4] - [int]$p[2]; Device = $p[6] }
        })
    } catch {
        Write-Log "dxgi outputs: $_"
        return @()
    }
}

# Startup: log the output table and the primary's output index.
function Select-DdaOutput {
    $script:DdaOutput = 0
    if (-not $script:HaveDdagrab) { return }
    $outs = @(Get-DxgiOutputs)
    $tbl = ($outs | ForEach-Object { '{0}={1} {2},{3} {4}x{5}' -f $_.Idx, $_.Device, $_.X, $_.Y, $_.W, $_.H }) -join '; '
    $prim = Get-PrimaryScreen
    $hit = $outs | Where-Object { $_.X -eq 0 -and $_.Y -eq 0 -and $_.W -eq $prim.W -and $_.H -eq $prim.H } | Select-Object -First 1
    if ($hit) { $script:DdaOutput = $hit.Idx }
    Write-Log ("ddagrab outputs: {0} | primary -> output {1}" -f $tbl, $script:DdaOutput)
}

# Per REC start (display kind): pick the target monitor. MonArg = "L,T,W,H" from the AHK (cursor's
# monitor) or ''. Sets $script:RecDevice / $script:RecRect. Returns a short description for logs.
function Set-RecTarget([string]$MonArg) {
    $script:RecDevice = ''
    $script:RecRect = $null
    if ($RecScreen -eq 'all') { return 'all (legacy)' }
    $want = $null; $src = 'primary'
    if ($RecScreen -eq 'mouse' -and $MonArg -match '^(-?\d+),(-?\d+),(\d+),(\d+)$') {
        $want = @{ X = [int]$Matches[1]; Y = [int]$Matches[2]; W = [int]$Matches[3]; H = [int]$Matches[4] }
        $src = 'mouse'
    }
    if (-not $want) {
        $pr = Get-PrimaryScreen
        $want = @{ X = 0; Y = 0; W = $pr.W; H = $pr.H }
    }
    $script:RecRect = $want
    $hit = @(Get-DxgiOutputs) | Where-Object { $_.X -eq $want.X -and $_.Y -eq $want.Y -and $_.W -eq $want.W -and $_.H -eq $want.H } | Select-Object -First 1
    if ($hit) { $script:RecDevice = $hit.Device }
    return ('{0} {1},{2} {3}x{4} device={5}' -f $src, $want.X, $want.Y, $want.W, $want.H, $(if ($hit) { "$($hit.Device) output $($hit.Idx)" } else { 'none (gdigrab only)' }))
}

# Current output index + rect of the REC target (follows its device). Idx = -1: ddagrab can't
# record it (e.g. monitor on another adapter) -> gdigrab.
function Get-RecTargetNow {
    if ($RecOutputPref -match '^\d+$') { return @{ Idx = [int]$RecOutputPref; Rect = $script:RecRect } }
    if (-not $script:RecRect) { return @{ Idx = $script:DdaOutput; Rect = $null } }
    if ($script:RecDevice) {
        $o = @(Get-DxgiOutputs) | Where-Object { $_.Device -eq $script:RecDevice } | Select-Object -First 1
        if ($o) { return @{ Idx = $o.Idx; Rect = @{ X = $o.X; Y = $o.Y; W = $o.W; H = $o.H } } }
    }
    return @{ Idx = -1; Rect = $script:RecRect }
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
        $dn = ''; $di = ''
        try { $dn = $rec.DeviceName; $di = $rec.DeviceId } catch {}
        Write-Log ("loopback start: {0} device='{1}' id={2}" -f $tmpWav, $dn, $di)
    } catch {
        Write-Log "loopback start failed: $_ - rec will be video-only"
        $script:DisplayAudio = $null
        $script:DisplayAudioWav = $null
        $script:DisplayHasAudio = $false
        $script:DisplayAudioStartUtc = [datetime]::MinValue
    }
}

function Probe-FfmpegCaps {
    $script:HaveNvenc = $false
    $script:HaveDdagrab = $false
    if (-not (Test-Path $Ffmpeg)) { return }
    try {
        $encOut = & $Ffmpeg -hide_banner -encoders 2>&1 | Out-String
        if ($encOut -match 'h264_nvenc') { $script:HaveNvenc = $true }
    } catch { Write-Log "encoder probe: $_" }
    try {
        $fltOut = & $Ffmpeg -hide_banner -filters 2>&1 | Out-String
        if ($fltOut -match 'ddagrab') { $script:HaveDdagrab = $true }
    } catch { Write-Log "capture probe: $_" }
    if ($EncoderPref -eq 'x264') {
        $script:ActiveEncoder = 'x264'
    } elseif ($script:HaveNvenc -and ($EncoderPref -in @('auto', 'nvenc'))) {
        $script:ActiveEncoder = 'nvenc'
    } else {
        if ($EncoderPref -eq 'nvenc') { Write-Log 'encoder=nvenc requested but h264_nvenc missing - using x264' }
        $script:ActiveEncoder = 'x264'
    }
    if ($CapturePref -eq 'gdigrab') {
        $script:ActiveCapture = 'gdigrab'
    } elseif ($script:HaveDdagrab -and ($CapturePref -in @('auto', 'ddagrab'))) {
        $script:ActiveCapture = 'ddagrab'
    } else {
        if ($CapturePref -eq 'ddagrab') { Write-Log 'capture=ddagrab requested but filter missing - using gdigrab' }
        $script:ActiveCapture = 'gdigrab'
    }
    Write-Log ("ffmpeg caps nvenc={0} ddagrab={1} encoder={2} capture={3} (ini encoder={4} capture={5})" -f `
        $script:HaveNvenc, $script:HaveDdagrab, $script:ActiveEncoder, $script:ActiveCapture, $EncoderPref, $CapturePref)
    try { Select-DdaOutput } catch { $script:DdaOutput = 0; Write-Log "ddagrab output select: $_" }
    Write-Log ("REC rec_screen={0}" -f $RecScreen)
}

function Get-VideoEncodeArgs([string]$Encoder, [string]$Capture) {
    if ($Encoder -eq 'nvenc') {
        $nv = "-c:v h264_nvenc -preset p4 -tune hq -rc constqp -qp $Crf -bf 0 -rc-lookahead 0"
        if ($Capture -eq 'gdigrab') { $nv += ' -pix_fmt yuv420p' }
        return $nv
    }
    return "-c:v libx264 -preset veryfast -pix_fmt yuv420p -crf $Crf"
}

function Get-VideoGrabArgs {
    param(
        [string]$Capture,
        [bool]$UseCrop,
        [int]$X,
        [int]$Y,
        [int]$W,
        [int]$H
    )
    if ($Capture -eq 'ddagrab') {
        $oi = $script:DdaOutput
        if (-not $UseCrop) { $tn = Get-RecTargetNow; if ($tn.Idx -ge 0) { $oi = $tn.Idx } }
        $common = "output_idx=${oi}:framerate=${Fps}:draw_mouse=1"
        if ($UseCrop -and $W -ge 16 -and $H -ge 16) {
            $ox = [Math]::Max(0, $X)
            $oy = [Math]::Max(0, $Y)
            return "-f lavfi -thread_queue_size 2048 -i `"ddagrab=${common}:video_size=${W}x${H}:offset_x=${ox}:offset_y=${oy}`""
        }
        return "-f lavfi -thread_queue_size 2048 -i `"ddagrab=${common}`""
    }
    if ($UseCrop) {
        return "-f gdigrab -thread_queue_size 2048 -framerate $Fps -draw_mouse 1 -offset_x $X -offset_y $Y -video_size ${W}x${H} -i desktop"
    }
    $tr = (Get-RecTargetNow).Rect
    if ($tr -and $tr.W -ge 16 -and $tr.H -ge 16) {
        # Full display on gdigrab (fallback / capture=gdigrab): just the REC target monitor
        $pw = Get-Even $tr.W; $ph = Get-Even $tr.H
        return "-f gdigrab -thread_queue_size 2048 -framerate $Fps -draw_mouse 1 -offset_x $($tr.X) -offset_y $($tr.Y) -video_size ${pw}x${ph} -i desktop"
    }
    return "-f gdigrab -thread_queue_size 2048 -framerate $Fps -draw_mouse 1 -i desktop"
}

# kind: display | window | region
# crop optional for window/region (virtual-desktop coords, even WxH for x264)
function Start-DesktopRecord {
    param(
        [ValidateSet('display', 'window', 'region')][string]$Kind = 'display',
        [int]$X = 0,
        [int]$Y = 0,
        [int]$W = 0,
        [int]$H = 0,
        [string]$ForceEncoder = '',
        [string]$ForceCapture = '',
        [switch]$IsRetry
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

    [void](Stop-OrphanRecFfmpeg)
    Clear-StaleRecTemps

    $useCrop = ($Kind -eq 'window' -or $Kind -eq 'region')
    if ($useCrop) {
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

    $enc = $script:ActiveEncoder
    $cap = $script:ActiveCapture
    if ($ForceEncoder) { $enc = $ForceEncoder }
    if ($ForceCapture) { $cap = $ForceCapture }
    if (-not $ForceCapture -and $CapturePref -eq 'auto' -and $useCrop) { $cap = 'gdigrab' }
    if ($cap -eq 'ddagrab' -and -not $script:HaveDdagrab) { $cap = 'gdigrab' }
    if ($cap -eq 'ddagrab' -and -not $useCrop -and (Get-RecTargetNow).Idx -lt 0) { $cap = 'gdigrab' }
    if ($enc -eq 'nvenc' -and -not $script:HaveNvenc) { $enc = 'x264' }

    $stamp = New-Stamp
    $prefix = switch ($Kind) {
        'window' { 'Window' }
        'region' { 'Region' }
        default { 'Display' }
    }
    $final = Join-Path $VidDir ("{0}_{1}.mp4" -f $prefix, $stamp)
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

    $errFile = Join-Path $env:TEMP ("webpcap_rec_{0}.err" -f $stamp)
    $script:DisplayErrFile = $errFile
    $p = New-RecFfmpegProcess -Cap $cap -Enc $enc -UseCrop $useCrop -X $X -Y $Y -W $W -H $H -TmpVid $tmpVid -ErrFile $errFile
    if ($null -eq $p) {
        return (Fail-DesktopStart -Proc $null -TmpVid $tmpVid -TmpWav $tmpWav -Error 'ffmpeg failed to start' -Kind $Kind)
    }
    $script:DisplayVideoStartUtc = [datetime]::UtcNow
    $script:SegStartUtc = $script:DisplayVideoStartUtc
    $script:DisplayProc = $p

    Write-Log ("rec start kind={0} crop={1},{2} {3}x{4} enc={5} cap={6} tmp={7} pid={8} retry={9}" -f `
        $Kind, $X, $Y, $W, $H, $enc, $cap, $tmpVid, $p.Id, [bool]$IsRetry)

    Start-Sleep -Milliseconds 80
    if ($p.HasExited) {
        Write-Log ("rec ffmpeg exited early code={0} kind={1} enc={2} cap={3} stderr: {4}" -f $p.ExitCode, $Kind, $enc, $cap, (Get-ErrTail $errFile))
        if (-not $IsRetry) {
            [void](Fail-DesktopStart -Proc $p -TmpVid $tmpVid -TmpWav $tmpWav -Error 'ffmpeg exited immediately' -Kind $Kind)
            $fallEnc = if ($enc -eq 'nvenc' -and $cap -eq 'ddagrab' -and $script:HaveNvenc) { 'nvenc' } else { 'x264' }
            Write-Log ("rec retry after early exit fallback enc={0} cap=gdigrab" -f $fallEnc)
            return Start-DesktopRecord -Kind $Kind -X $X -Y $Y -W $W -H $H -ForceEncoder $fallEnc -ForceCapture 'gdigrab' -IsRetry
        }
        return (Fail-DesktopStart -Proc $p -TmpVid $tmpVid -TmpWav $tmpWav -Error 'ffmpeg exited immediately (bad crop or grab failed)' -Kind $Kind)
    }

    Start-LoopbackAudio $tmpWav

    $grew = $false
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 250
        if ($p.HasExited) { break }
        if ((Get-FileSizeSafe $tmpVid) -ge 2048) { $grew = $true; break }   # > empty_moov header = real frames
    }
    if ($p.HasExited) {
        Write-Log ("rec ffmpeg exited during warmup code={0} kind={1} size={2} enc={3} cap={4} stderr: {5}" -f $p.ExitCode, $Kind, (Get-FileSizeSafe $tmpVid), $enc, $cap, (Get-ErrTail $errFile))
        if (-not $IsRetry) {
            [void](Fail-DesktopStart -Proc $p -TmpVid $tmpVid -TmpWav $tmpWav -Error 'ffmpeg exited during start' -Kind $Kind)
            Write-Log 'rec retry after warmup exit fallback gdigrab+x264'
            return Start-DesktopRecord -Kind $Kind -X $X -Y $Y -W $W -H $H -ForceEncoder 'x264' -ForceCapture 'gdigrab' -IsRetry
        }
        return (Fail-DesktopStart -Proc $p -TmpVid $tmpVid -TmpWav $tmpWav -Error 'ffmpeg exited during start (grab failed)' -Kind $Kind)
    }
    if (-not $grew) {
        Write-Log ("rec ffmpeg hung (no output after warmup) kind={0} pid={1} enc={2} cap={3} size={4} stderr: {5}" -f $Kind, $p.Id, $enc, $cap, (Get-FileSizeSafe $tmpVid), (Get-ErrTail $errFile))
        if (-not $IsRetry) {
            [void](Fail-DesktopStart -Proc $p -TmpVid $tmpVid -TmpWav $tmpWav -Error 'ffmpeg hung (no video frames)' -Kind $Kind)
            $fallEnc = if ($enc -eq 'nvenc' -and $script:HaveNvenc) { 'nvenc' } else { 'x264' }
            Write-Log ("rec retry after hang fallback enc={0} cap=gdigrab" -f $fallEnc)
            return Start-DesktopRecord -Kind $Kind -X $X -Y $Y -W $W -H $H -ForceEncoder $fallEnc -ForceCapture 'gdigrab' -IsRetry
        }
        return (Fail-DesktopStart -Proc $p -TmpVid $tmpVid -TmpWav $tmpWav -Error 'ffmpeg hung (no video frames) - retry REC' -Kind $Kind)
    }

    if ($script:DisplayHasAudio -and $script:DisplayAudioStartUtc -ne [datetime]::MinValue) {
        $lead = ($script:DisplayVideoStartUtc - $script:DisplayAudioStartUtc).TotalSeconds
        Write-Log ("rec A/V start skew: audio_ahead={0:0.000}s (negative = video first)" -f $lead)
    }

    Write-Log ("rec warmup ok kind={0} tmpSize={1} audio={2} enc={3} cap={4}" -f $Kind, (Get-FileSizeSafe $tmpVid), $script:DisplayHasAudio, $enc, $cap)
    $script:RecStamp = $stamp
    $script:RecSegIndex = 0
    $script:RecRestarts = 0
    $script:RecSegments = New-Object System.Collections.ArrayList
    $script:RecParams = @{ Kind = $Kind; X = $X; Y = $Y; W = $W; H = $H; UseCrop = $useCrop; Enc = $enc; Cap = $cap }
    return @{
        ok        = $true
        path      = $final
        recording = $true
        audio     = $script:DisplayHasAudio
        mode      = $Kind
        encoder   = $enc
        capture   = $cap
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
    # Same hotkey again OR any stop: if already recording, stop (any kind).
    # Session-aware: also stops when ffmpeg already died (finalizes what was captured).
    if ((Test-DesktopRecording) -or (Test-RecSession)) {
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
    # 2026-10-02: was `Test-DesktopRecording -or $script:DisplayOut` - PowerShell passed
    # "-or $x" as ARGUMENTS to the function, so a REC whose ffmpeg had died answered
    # nothing_recording and was never finalized (temps + loopback WAV orphaned).
    if ((Test-DesktopRecording) -or $script:DisplayOut) {
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
                [System.Threading.Monitor]::Enter($script:Lock)
                try { Invoke-RecSupervisor } catch { Write-Log "supervisor: $_" } finally { [System.Threading.Monitor]::Exit($script:Lock) }
                $disp = (Test-DesktopRecording) -or (Test-RecSession)
                $endAgo = if ($script:RecEndUtc -eq [datetime]::MinValue) { -1 } else { [int64]([datetime]::UtcNow - $script:RecEndUtc).TotalMilliseconds }
                Send-Json $ctx @{
                    ok               = $true
                    port             = $Port
                    viddir           = $VidDir
                    audio            = $AudioMode
            encoder          = $script:ActiveEncoder
            capture          = $script:ActiveCapture
            haveNvenc        = [bool]$script:HaveNvenc
            haveDdagrab      = [bool]$script:HaveDdagrab
                    displayRecording = $disp
                    recKind          = $script:RecKind
                    displayAudio     = [bool]$script:DisplayHasAudio
                    canvasRecording  = $script:CanvasRecord
                    canvasSeq        = $script:CanvasSeq
                    helper           = (Test-CanvasHelperAlive)
                    recSegments      = $script:RecSegments.Count + $(if ($script:DisplayOut) { 1 } else { 0 })
                    recEndSeq        = $script:RecEndSeq
                    recEndReason     = $script:RecEndReason
                    recEndAgoMs      = $endAgo
                    recEndOk         = [bool]$script:RecEndOk
                    recEndPath       = $script:RecEndPath
                }
            }
            '^/display/toggle$' {
                if ($method -ne 'POST') { Send-Json $ctx @{ ok = $false; error = 'POST only' } 405; return }
                $r = $null
                [System.Threading.Monitor]::Enter($script:Lock)
                try {
                    if (-not ((Test-DesktopRecording) -or (Test-RecSession))) {
                        $tgt = Set-RecTarget ([string]$ctx.Request.QueryString['mon'])
                        Write-Log "rec target: $tgt"
                    }
                    $r = Toggle-DesktopRec -Kind 'display'
                    if ($r -and $r.recording -and $script:RecDevice -match 'DISPLAY(\d+)$') { $r['screen'] = $Matches[1] }
                } finally { [System.Threading.Monitor]::Exit($script:Lock) }
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
                    if ((Test-DesktopRecording) -or (Test-RecSession)) {
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
                    if ((Test-DesktopRecording) -or (Test-RecSession)) {
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

Probe-FfmpegCaps

$listener = New-Object System.Net.HttpListener
$prefix = "http://127.0.0.1:$Port/"
$listener.Prefixes.Add($prefix)
try {
    $listener.Start()
} catch {
    Write-Log "listener failed on $prefix : $_"
    throw
}
Write-Log "video-host listening $prefix viddir=$VidDir ffmpeg=$Ffmpeg audio=$AudioMode audio_delay_ms=$AudioDelayMs encoder=$($script:ActiveEncoder) capture=$($script:ActiveCapture)"

try {
    $pending = $null
    while ($listener.IsListening) {
        $ctx = $null
        try {
            if ($null -eq $pending) { $pending = $listener.GetContextAsync() }
            # 500 ms tick: supervise REC ffmpeg even when no request arrives
            if (-not $pending.Wait(500)) {
                try { Invoke-RecSupervisor } catch { Write-Log "supervisor: $_" }
                continue
            }
            $ctx = $pending.Result
            $pending = $null
            Handle-Request $ctx
        } catch {
            $pending = $null
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
