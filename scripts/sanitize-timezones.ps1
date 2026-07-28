<#
.SYNOPSIS
  OPSEC timezone sanitize — check (default) or rewrite (--Fix).

.DESCRIPTION
  Scans tracked public text files for timezone abbreviations / full names / UTC±N.
  Check-only by default (exit 1 on hits). -Fix rewrites in place.

.PARAMETER Fix
  Rewrite hits in place (strip zone tokens; keep clock times when present).

.PARAMETER Root
  Repo root to scan (default: current directory).
#>
[CmdletBinding()]
param(
  [switch]$Fix,
  [string]$Root = '.'
)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path -LiteralPath $Root).Path
Set-Location $Root

$excludeRel = @(
  'scripts/sanitize-timezones.sh',
  'scripts/sanitize-timezones.ps1',
  '.github/workflows/timezone-sanitize.yml'
)
$excludeDirPrefixes = @(
  'node_modules/', '.git/', 'target/', 'dist/', 'build/', 'vendor/',
  '.venv/', 'venv/', '__pycache__/'
)

$extSet = [System.Collections.Generic.HashSet[string]]::new(
  [string[]]@('.md','.txt','.html','.htm','.js','.ts','.tsx','.jsx','.json','.yml','.yaml','.toml','.rs','.ps1','.sh','.cs','.css','.ahk')
)
$nameHints = @('NOTES','CHANGELOG','HISTORY','VERSION','RELEASES')

# Abbreviations + full names + UTC±N / GMT±N (not bare UTC alone)
$tzPattern = '(?i)\b(CST|CDT|EST|EDT|MST|MDT|PST|PDT)\b|(?i)\b(Central|Eastern|Mountain|Pacific)\s+(Standard|Daylight)\s+Time\b|(?i)\b(UTC|GMT)\s*[+\-]\s*\d{1,2}(:\d{2})?\b'

function Test-Excluded([string]$rel) {
  $rel = $rel -replace '\\','/'
  foreach ($e in $excludeRel) {
    if ($rel -eq $e) { return $true }
  }
  foreach ($p in $excludeDirPrefixes) {
    if ($rel.StartsWith($p)) { return $true }
  }
  return $false
}

function Test-ShouldScan([string]$rel) {
  $rel = $rel -replace '\\','/'
  $name = [System.IO.Path]::GetFileName($rel)
  $ext = [System.IO.Path]::GetExtension($rel).ToLowerInvariant()
  if ($extSet.Contains($ext)) { return $true }
  foreach ($h in $nameHints) {
    if ($name -like "$h*" ) { return $true }
  }
  return $false
}

function Get-TrackedFiles {
  $git = Join-Path $Root '.git'
  if (Test-Path $git) {
    $out = & git -C $Root ls-files 2>$null
    if ($LASTEXITCODE -eq 0) { return @($out) }
  }
  # fallback: walk (still skip heavy dirs)
  $all = Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object {
      $r = $_.FullName.Substring($Root.Length).TrimStart('\','/') -replace '\\','/'
      -not (Test-Excluded $r)
    } |
    ForEach-Object { $_.FullName.Substring($Root.Length).TrimStart('\','/') -replace '\\','/' }
  return @($all)
}

$hits = New-Object System.Collections.Generic.List[object]
$files = Get-TrackedFiles

foreach ($rel in $files) {
  if ([string]::IsNullOrWhiteSpace($rel)) { continue }
  $relN = $rel -replace '\\','/'
  if (Test-Excluded $relN) { continue }
  if (-not (Test-ShouldScan $relN)) { continue }
  $path = Join-Path $Root $rel
  if (-not (Test-Path -LiteralPath $path)) { continue }

  $lines = [System.IO.File]::ReadAllLines($path)
  $fileDirty = $false
  $newLines = New-Object System.Collections.Generic.List[string]
  for ($i = 0; $i -lt $lines.Length; $i++) {
    $line = $lines[$i]
    if ($line -match $tzPattern) {
      $hits.Add([pscustomobject]@{ File = $relN; Line = ($i + 1); Text = $line.TrimEnd() })
      if ($Fix) {
        $fixed = [regex]::Replace($line, '(?i)\b(Central|Eastern|Mountain|Pacific)\s+(Standard|Daylight)\s+Time\b', '')
        $fixed = [regex]::Replace($fixed, '(?i)\b(UTC|GMT)\s*[+\-]\s*\d{1,2}(:\d{2})?\b', { param($m) $m.Groups[1].Value })
        $fixed = [regex]::Replace($fixed, '(?i)\b(CST|CDT|EST|EDT|MST|MDT|PST|PDT)\b', '')
        # collapse interior double spaces but preserve leading indent
        if ($fixed -match '^\s+') {
          $indent = [regex]::Match($fixed, '^\s+').Value
          $rest = $fixed.Substring($indent.Length)
          $rest = [regex]::Replace($rest, ' {2,}', ' ')
          $fixed = $indent + $rest
        } else {
          $fixed = [regex]::Replace($fixed, '(?<=\S) {2,}(?=\S)', ' ')
        }
        $fixed = $fixed -replace '[ \t]+$',''
        $newLines.Add($fixed)
        $fileDirty = $true
        continue
      }
    }
    $newLines.Add($line)
  }
  if ($Fix -and $fileDirty) {
    $text = ($newLines -join "`n") + "`n"
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding $false))
  }
}

foreach ($h in $hits) {
  Write-Output ("{0}:{1}: {2}" -f $h.File, $h.Line, $h.Text)
}

Write-Output ""
Write-Output ("timezone-sanitize: {0} hit(s) in {1} file(s) (root={2} fix={3})" -f `
  $hits.Count, @($hits | Select-Object -ExpandProperty File -Unique).Count, $Root, [bool]$Fix)

if ($Fix) {
  # residual scan
  $remain = 0
  foreach ($rel in (@($hits | Select-Object -ExpandProperty File -Unique))) {
    $path = Join-Path $Root $rel
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $c = [System.IO.File]::ReadAllText($path)
    if ($c -match $tzPattern) {
      $remain++
      Write-Output "REMAIN: $rel"
    }
  }
  if ($remain -gt 0) {
    Write-Output "timezone-sanitize: residual hits after -Fix"
    exit 1
  }
  Write-Output "timezone-sanitize: fixed clean"
  exit 0
}

if ($hits.Count -gt 0) {
  Write-Output "timezone-sanitize: FAIL (check-only). Re-run with -Fix to rewrite, then review the diff."
  exit 1
}

Write-Output "timezone-sanitize: OK"
exit 0
