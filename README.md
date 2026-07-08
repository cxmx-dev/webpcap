# webpcap

**Custom Media Pipeline Utility — zero-dependency WebP screenshot daemon**

Hotkey-native Windows screenshots that land as `.webp` files and on the clipboard — no Snipping Tool UI, no tray clutter, no OCR. One AHK v2 script pipes captures through your local FFmpeg engine (`libwebp`) and saves to `Pictures\Screenshots\WebP\`.

## Quick start

**PowerShell** (your default shell):

```powershell
cd E:\Code-Y\GitHub-Repo-Helper\Repos\webpcap
.\build.ps1
.\test_hotkeys.ps1   # debug run + v0.1 checklist
```

**CMD** (if you prefer):

```bat
cd /d E:\Code-Y\GitHub-Repo-Helper\Repos\webpcap
build.bat
test_hotkeys.bat
```

Edit `webpcap.ini` for output folder, quality (85–92), lossless toggle, and hotkey remap on/off.

## Hotkeys (v0.1)

| Key | Capture |
|-----|---------|
| `PrtSc` / `Win+PrtSc` | Full desktop (all monitors) |
| `Win+Shift+S` | Region — two-click corners |
| `Win+Shift+R` | Active window |

Pass `--debug` for save tooltips and tray icon.

## Stack

- **AutoHotkey v2** — hotkey hooks, zero UI
- **FFmpeg** (`E:\Code-Y\engine - ffmpeg\ffmpeg.exe`) — PNG → WebP via `libwebp`
- **PowerShell** — GDI capture + clipboard (built into Windows)

## Portfolio blurb

*webpcap* is a 120-line media pipeline micro-tool: it intercepts native screenshot hotkeys, captures via WinAPI/GDI with no overlay chrome, and immediately transcodes to WebP through a pinned FFmpeg build — saving named files and refreshing the clipboard in one motion. Built for local-first workflow (config ini, one-click batch launch, convo log) as a hireable proof of Tools/Pipeline Engineer instincts: minimal surface area, deterministic output, and real encoder integration instead of yet another Electron tray app.

## Version History

70826 3:06:35:56 AM CST
• v0.1 scaffold shipped: `webpcap.ahk` (119 lines), `webpcap.ini`, `build.bat`, `test_hotkeys.bat`; FFmpeg `libwebp` pipe verified; git init + commit `0a09e9e`.
• Hub docs synced (`update .mds`); local-only — not deployed via `start.ps1`.