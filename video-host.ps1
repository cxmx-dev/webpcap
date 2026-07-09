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

New-Item -ItemType Directory -Force -Path $VidDir | Out-Null

$pidFile = Join-Path $env:TEMP 'webpcap-video-host.pid'
$logFile = Join-Path $env:TEMP 'webpcap-video.log'
$script:DisplayProc = $null
$script:DisplayOut = $null          # temp silent video path while recording
$script:DisplayFinal = $null        # final *_.mp4 in viddir
$script:DisplayAudio = $null        # WasapiLoopbackRecorder
$script:DisplayAudioWav = $null
$script:DisplayHasAudio = $false
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

function Merge-DisplayAv([string]$videoPath, [string]$wavPath, [string]$finalPath) {
    if (-not (Test-Path $videoPath)) { return $false }
    $hasWav = $wavPath -and (Test-Path $wavPath) -and ((Get-Item $wavPath).Length -gt 128)
    if (-not $hasWav) {
        Move-Item -Force $videoPath $finalPath
        $sz = (Get-Item $finalPath).Length
        Write-Log ('display saved (video only): {0} ({1} bytes)' -f $finalPath, $sz)
        return $true
    }
    # one MP4: video + system audio (AAC) via User's ffmpeg
    $argLine = "-hide_banner -loglevel error -y -i `"$videoPath`" -i `"$wavPath`" -c:v copy -c:a aac -b:a 192k -shortest -movflags +faststart `"$finalPath`""
    $p = Start-Process -FilePath $Ffmpeg -ArgumentList $argLine -Wait -PassThru -WindowStyle Hidden
    $code = if ($null -eq $p) { 'null' } else { $p.ExitCode }
    if ($null -eq $p -or $p.ExitCode -ne 0 -or -not (Test-Path $finalPath)) {
        Write-Log ('display mux failed exit={0} - falling back to video only' -f $code)
        try { Move-Item -Force $videoPath $finalPath } catch { return $false }
        Write-Log ('display saved (video only fallback): {0}' -f $finalPath)
        return $true
    }
    $sz = (Get-Item $finalPath).Length
    Write-Log ('display saved (video+audio): {0} ({1} bytes)' -f $finalPath, $sz)
    return $true
}

function Test-DesktopRecording {
    return ($null -ne $script:DisplayProc -and -not $script:DisplayProc.HasExited)
}

function Stop-DisplayRecord {
    if ($null -eq $script:DisplayProc -and -not $script:DisplayOut) { return $false }
    $p = $script:DisplayProc
    $tmpVid = $script:DisplayOut
    $final = $script:DisplayFinal
    $wav = $script:DisplayAudioWav
    $kind = $script:RecKind
    if (-not $kind) { $kind = 'display' }
    try {
        if ($null -ne $p -and -not $p.HasExited) {
            try {
                $p.StandardInput.WriteLine('q')
                $p.StandardInput.Flush()
            } catch {}
            if (-not $p.WaitForExit(8000)) {
                try { $p.Kill() } catch {}
                $p.WaitForExit(2000) | Out-Null
            }
        }
    } catch {
        Write-Log "rec stop error: $_"
    } finally {
        if ($null -ne $p) { try { $p.Dispose() } catch {} }
        $script:DisplayProc = $null
        $script:DisplayOut = $null
        $script:DisplayFinal = $null
        $script:DisplayAudioWav = $null
        $script:DisplayHasAudio = $false
        $script:RecKind = $null
        Stop-DisplayAudio
    }

    if (-not $tmpVid -or -not (Test-Path $tmpVid) -or ((Get-Item $tmpVid).Length -lt 64)) {
        Write-Log ('rec stop: no video file (kind={0} tmp={1})' -f $kind, $tmpVid)
        if ($wav) { try { Remove-Item -Force $wav -ErrorAction SilentlyContinue } catch {} }
        try { if ($tmpVid -and (Test-Path $tmpVid)) { Remove-Item -Force $tmpVid -ErrorAction SilentlyContinue } } catch {}
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

    $ok = Merge-DisplayAv $tmpVid $wav $final
    try { if (Test-Path $tmpVid) { Remove-Item -Force $tmpVid -ErrorAction SilentlyContinue } } catch {}
    try { if ($wav -and (Test-Path $wav)) { Remove-Item -Force $wav -ErrorAction SilentlyContinue } } catch {}
    return $ok
}

function Get-Even([int]$n) {
    if ($n -lt 2) { return 2 }
    if ($n % 2 -ne 0) { return $n - 1 }
    return $n
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

    $useCrop = ($Kind -eq 'window' -or $Kind -eq 'region')
    if ($useCrop) {
        # gdigrab rejects negative offsets (Win11 DWM shadow often reports -8,-8)
        if ($X -lt 0) { $W += $X; $X = 0 }
        if ($Y -lt 0) { $H += $Y; $Y = 0 }
        if ($W -lt 1) { $W = 1 }
        if ($H -lt 1) { $H = 1 }
        $W = Get-Even $W
        $H = Get-Even $H
        if ($W -lt 16 -or $H -lt 16) {
            return @{ ok = $false; error = 'region too small (min 16x16 even)' }
        }
    }

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

    if ($AudioMode -eq 'system' -and ('WasapiLoopbackRecorder' -as [type])) {
        try {
            $rec = New-Object WasapiLoopbackRecorder
            $rec.Start($tmpWav)
            $script:DisplayAudio = $rec
            $script:DisplayAudioWav = $tmpWav
            $script:DisplayHasAudio = $true
            Write-Log "loopback start: $tmpWav"
        } catch {
            Write-Log "loopback start failed: $_ - rec will be video-only"
            $script:DisplayAudio = $null
            $script:DisplayAudioWav = $null
            $script:DisplayHasAudio = $false
        }
    } elseif ($AudioMode -eq 'system') {
        Write-Log 'loopback type unavailable - rec will be video-only'
    }

    # gdigrab: full desktop or crop (virtual desktop coords; even size for libx264)
    if ($useCrop) {
        $grab = "-f gdigrab -framerate $Fps -offset_x $X -offset_y $Y -video_size ${W}x${H} -i desktop"
    } else {
        $grab = "-f gdigrab -framerate $Fps -i desktop"
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Ffmpeg
    $psi.Arguments = "-hide_banner -loglevel error -y $grab -c:v libx264 -preset veryfast -pix_fmt yuv420p -crf $Crf -an -movflags +faststart `"$tmpVid`""
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    if (-not $p.Start()) {
        Stop-DisplayAudio
        try { if (Test-Path $tmpWav) { Remove-Item -Force $tmpWav -ErrorAction SilentlyContinue } } catch {}
        $script:DisplayOut = $null
        $script:DisplayFinal = $null
        $script:RecKind = $null
        return @{ ok = $false; error = 'ffmpeg failed to start' }
    }
    $script:DisplayProc = $p
    Write-Log ("rec start kind={0} crop={1},{2} {3}x{4} tmp={5} final={6} audio={7} pid={8}" -f `
        $Kind, $X, $Y, $W, $H, $tmpVid, $final, $script:DisplayHasAudio, $p.Id)
    # Fail fast if gdigrab dies immediately (bad crop / device)
    Start-Sleep -Milliseconds 250
    if ($p.HasExited) {
        Write-Log ("rec ffmpeg exited early code={0} kind={1}" -f $p.ExitCode, $Kind)
        Stop-DisplayAudio
        try { if (Test-Path $tmpWav) { Remove-Item -Force $tmpWav -ErrorAction SilentlyContinue } } catch {}
        try { if (Test-Path $tmpVid) { Remove-Item -Force $tmpVid -ErrorAction SilentlyContinue } } catch {}
        try { $p.Dispose() } catch {}
        $script:DisplayProc = $null
        $script:DisplayOut = $null
        $script:DisplayFinal = $null
        $script:RecKind = $null
        return @{ ok = $false; error = 'ffmpeg exited immediately (bad crop or grab failed)'; recording = $false; mode = $Kind }
    }
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

$listener = New-Object System.Net.HttpListener
$prefix = "http://127.0.0.1:$Port/"
$listener.Prefixes.Add($prefix)
try {
    $listener.Start()
} catch {
    Write-Log "listener failed on $prefix : $_"
    throw
}
Write-Log "video-host listening $prefix viddir=$VidDir ffmpeg=$Ffmpeg audio=$AudioMode"

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
