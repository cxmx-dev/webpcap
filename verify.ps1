# One-shot pipeline test (no hotkeys) — run from Repos\webpcap
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$ini = Join-Path $Root 'webpcap.ini'
if (-not (Test-Path $ini)) { Copy-Item (Join-Path $Root 'webpcap.ini.example') $ini }

function Get-IniValue($file, $section, $key) {
    $cur = ''
    foreach ($line in Get-Content $file) {
        if ($line -match '^\s*\[(.+)\]\s*$') { $cur = $Matches[1]; continue }
        if ($cur -eq $section -and $line -match ('^\s*' + [regex]::Escape($key) + '\s*=\s*(.+)\s*$')) {
            return $Matches[1]
        }
    }
    return $null
}

$ffmpeg = Get-IniValue $ini 'paths' 'ffmpeg'
$outdir = [Environment]::ExpandEnvironmentVariables((Get-IniValue $ini 'paths' 'outdir'))
if (-not $outdir) { $outdir = Join-Path $env:USERPROFILE 'Pictures\Screenshots\webpcap CAPS' }
New-Item -ItemType Directory -Force -Path $outdir | Out-Null

Write-Host "ffmpeg: $ffmpeg"
Write-Host "outdir: $outdir"
if (-not (Test-Path $ffmpeg)) { throw "ffmpeg not found: $ffmpeg" }

$ts = Get-Date -Format 'yyyyMMdd_HHmmss'
$png = Join-Path $env:TEMP "webpcap_verify_$ts.png"
$webp = Join-Path $outdir "Screenshot_$ts.webp"

Add-Type -AssemblyName System.Windows.Forms,System.Drawing
$r = [Drawing.Rectangle]::Empty
foreach ($s in [Windows.Forms.Screen]::AllScreens) {
    if ($r.IsEmpty) { $r = $s.Bounds } else { $r = [Drawing.Rectangle]::Union($r, $s.Bounds) }
}
$b = New-Object Drawing.Bitmap $r.Width, $r.Height
$g = [Drawing.Graphics]::FromImage($b)
$g.CopyFromScreen($r.Location, [Drawing.Point]::Empty, $r.Size)
$b.Save($png, [Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $b.Dispose()
Write-Host "capture OK: $png ($((Get-Item $png).Length) bytes)"

& $ffmpeg -hide_banner -loglevel error -y -i $png -c:v libwebp -q:v 90 $webp
Remove-Item $png -Force
Write-Host "webp OK: $webp ($((Get-Item $webp).Length) bytes)"
Write-Host 'If this works but PrtSc does not, turn OFF Windows Settings > Accessibility > Keyboard > Use Print screen key to open screen snipping'