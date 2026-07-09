# Install webpcap to start at Windows sign-in (after reboot / power-on + login).
# No admin required — user-level Scheduled Task.
# Run once:  .\install-autostart.ps1
$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$build = Join-Path $Root 'build.ps1'
if (-not (Test-Path $build)) { throw "Missing build.ps1" }

$taskName = 'webpcap'
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
# Hidden start of build.ps1 at logon (delay so desktop/ffmpeg/AHK are ready)
$arg = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$build`""

$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "Removed previous task '$taskName'." -ForegroundColor DarkGray
}

$action = New-ScheduledTaskAction -Execute $ps -Argument $arg -WorkingDirectory $Root
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
# Slight delay so shell/desktop is up after reboot
$trigger.Delay = 'PT20S'
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description 'webpcap stills+video daemon (video-host + AutoHotkey) at sign-in' | Out-Null

Write-Host ''
Write-Host "Installed: Scheduled Task '$taskName' (at your sign-in, +20s delay)." -ForegroundColor Green
Write-Host "  runs: $build"
Write-Host "  user: $env:USERNAME"
Write-Host ''
Write-Host 'After reboot / power-on + login, hotkeys work without opening a terminal.'
Write-Host 'Remove later:  .\uninstall-autostart.ps1'
Write-Host 'Test now:      .\build.ps1'
Write-Host ''
Write-Host 'Hotkeys (when daemon is running):'
Write-Host '  CAPS  PrtSc | Alt+PrtSc | Ctrl+PrtSc (region drag)'
Write-Host '  REC   Ctrl+Shift+PrtSc full | Ctrl+Win+PrtSc window | Ctrl+Alt+PrtSc region'
Write-Host '  REC   End = stop any recording'
