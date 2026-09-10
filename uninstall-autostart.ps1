# Remove webpcap sign-in autostart task
$ErrorActionPreference = 'Stop'
$taskName = 'webpcap'
$t = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if (-not $t) {
    Write-Host "No scheduled task named '$taskName' — nothing to remove." -ForegroundColor Yellow
    exit 0
}
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
Write-Host "Removed scheduled task '$taskName'." -ForegroundColor Green
Write-Host 'webpcap will no longer start at sign-in. (Running instances still need End Task if open.)'
