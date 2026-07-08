@echo off
setlocal
cd /d "%~dp0"
set "AHK=C:\Program Files\AutoHotkey\v2\AutoHotkey.exe"
if not exist "%AHK%" (
    echo AutoHotkey v2 not found at %AHK%
    exit /b 1
)
echo webpcap v0.1 — launching daemon (close tray script or End Task to stop)
start "" "%AHK%" "%~dp0webpcap.ahk"
echo Started. Edit webpcap.ini then restart to apply config.
endlocal