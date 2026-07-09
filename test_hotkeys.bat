@echo off
setlocal
cd /d "%~dp0"
set "AHK=C:\Program Files\AutoHotkey\v2\AutoHotkey.exe"
set "OUT=%USERPROFILE%\Pictures\Screenshots\webpcap CAPS"

echo === webpcap v0.1 test plan ===
echo.
echo [1] Starting daemon in --debug mode (tooltips on save)...
start "" "%AHK%" "%~dp0webpcap.ahk" --debug
timeout /t 2 /nobreak >nul
echo.
echo [2] Press PrintScreen       -^> full desktop .webp
echo [3] Press Win+Shift+S       -^> two-click region .webp
echo [4] Press Win+Shift+R       -^> active window .webp
echo [5] Shift+PrtSc             -^> display .mp4 toggle
echo [6] Alt+Shift+PrtSc         -^> canvas .mp4 toggle (helper on page)
echo.
echo Output folder: %OUT%
echo.
echo [5] Verify each file:
echo     - exists as Screenshot_YYYYMMDD_HHMMSS.webp
echo     - opens in image viewer
echo     - pastes from clipboard (Ctrl+V)
echo     - smaller than equivalent .png
echo.
echo [6] Speed check: capture-to-save should feel instant (^<1s typical)
echo.
pause
endlocal