# Turn OFF Windows "Print Screen opens Snipping Tool" so webpcap can hook PrtSc
$ErrorActionPreference = 'Stop'
$path = 'HKCU:\Control Panel\Keyboard'
if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
$cur = Get-ItemProperty -Path $path -Name 'PrintScreenKeyForSnippingEnabled' -ErrorAction SilentlyContinue
if ($cur.PrintScreenKeyForSnippingEnabled -eq 0) {
    Write-Host 'Print Screen snipping hijack already OFF.'
} else {
    Set-ItemProperty -Path $path -Name 'PrintScreenKeyForSnippingEnabled' -Value 0 -Type DWord
    Write-Host 'Disabled Print Screen -> Snipping Tool (registry).'
}
Write-Host ''
Write-Host 'Manual check: Settings > Bluetooth & devices > Keyboard'
Write-Host '  Turn OFF "Use the Print screen key to open screen capture"'
Write-Host ''
Write-Host 'Win+Shift+S is still owned by Snipping Tool — use Win+Shift+R or PrtSc for webpcap.'
Write-Host 'Restart webpcap after: Get-Process AutoHotkey* | Stop-Process -Force; .\build.ps1'