# webpcap

**Custom Media Pipeline Utility — zero-dependency WebP screenshot daemon**

Hotkey-native Windows screenshots that land as `.webp` files and on the clipboard — no Snipping Tool UI, no tray clutter, no OCR. One AHK v2 script pipes captures through FFmpeg (`libwebp`) and saves to `Pictures\Screenshots\WebP\`.

## Quick start

1. Copy `webpcap.ini.example` → `webpcap.ini` and set your `ffmpeg` path (or leave `ffmpeg.exe` if on PATH).
2. Install [AutoHotkey v2](https://www.autohotkey.com/).

**PowerShell:**

```powershell
cd <path-to>\webpcap
.\build.ps1
.\test_hotkeys.ps1   # debug run + v0.1 checklist
```

**CMD:**

```bat
cd /d <path-to>\webpcap
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
- **FFmpeg** — PNG → WebP via `libwebp` (configure path in `webpcap.ini`)
- **PowerShell** — GDI capture + clipboard (built into Windows)

## Portfolio blurb

*webpcap* is a media pipeline micro-tool: it intercepts native screenshot hotkeys, captures via WinAPI/GDI with no overlay chrome, and immediately transcodes to WebP through FFmpeg — saving named files and refreshing the clipboard in one motion. Built for local-first workflow (config ini, one-click batch launch) as a hireable proof of Tools/Pipeline Engineer instincts: minimal surface area, deterministic output, and real encoder integration instead of yet another Electron tray app.

## Version History

v0.1 — AHK daemon, ini config, PowerShell/CMD launchers, FFmpeg WebP pipe, hub `local-tool` registration.