# webpcap

## Controls

| Key | Action |
|-----|--------|
| `PrtSc` / `Win+PrtSc` | Full desktop (all monitors) → `.webp` + clipboard |
| `Win+Shift+S` | Region — click top-left, then bottom-right (`Esc` cancels) |
| `Win+Shift+R` | Active window → `.webp` + clipboard |

**Output:** `%USERPROFILE%\Pictures\Screenshots\WebP\Screenshot_YYYYMMDD_HHMMSS.webp`

**Debug mode** (tooltips + tray icon): run with `--debug` (see [Start](#start) below).

**Stop:** Task Manager → end `AutoHotkey64.exe`, or close the script from the tray in debug mode.

---

## Run (standalone — download this repo only)

No hub required. **Regular PowerShell is enough** — you do not need Admin unless you are installing FFmpeg or AutoHotkey for the first time.

### Requirements

1. [AutoHotkey v2](https://www.autohotkey.com/) (default install path is fine)
2. [FFmpeg](https://ffmpeg.org/download.html) with `libwebp` — on `PATH`, or set full path in `webpcap.ini`
3. Windows 10/11 with PowerShell 5.1+

### First-time setup

```powershell
cd <path-to>\webpcap
Copy-Item .\webpcap.ini.example .\webpcap.ini
notepad .\webpcap.ini   # set ffmpeg= if not on PATH
ffmpeg -version         # optional: confirm ffmpeg runs
```

### Start

```powershell
cd <path-to>\webpcap
.\build.ps1
```

Press `PrtSc` once, then check output:

```powershell
explorer "$env:USERPROFILE\Pictures\Screenshots\WebP"
```

### Debug / test checklist

```powershell
cd <path-to>\webpcap
.\test_hotkeys.ps1
```

Or manual debug:

```powershell
& "C:\Program Files\AutoHotkey\v2\AutoHotkey.exe" ".\webpcap.ahk" --debug
```

### CMD (alternative)

```bat
cd /d <path-to>\webpcap
copy webpcap.ini.example webpcap.ini
build.bat
```

### Configure (`webpcap.ini`)

| Setting | Purpose |
|---------|---------|
| `ffmpeg` | `ffmpeg.exe` on PATH, or full path to your `ffmpeg.exe` |
| `outdir` | Save folder (default: `%USERPROFILE%\Pictures\Screenshots\WebP`) |
| `quality` | WebP quality `85`–`92` (default `90`) |
| `lossless` | `1` = lossless WebP, `0` = lossy |
| `remap` | `1` = hook hotkeys, `0` = disable hooks |

Edit `webpcap.ini`, then restart the daemon (`.\build.ps1` again after stopping the old instance).

### If nothing saves

1. Close other screenshot tools (ShareX, Snipping Tool, etc.) — they may grab `PrtSc` first.
2. Confirm FFmpeg: `ffmpeg -encoders 2>&1 | Select-String libwebp`
3. Run debug mode and watch for tooltips on save.
4. Restart: end `AutoHotkey64.exe` in Task Manager, then `.\build.ps1`.

---

## What this is

**Custom Media Pipeline Utility — zero-dependency WebP screenshot daemon**

Hotkey-native Windows screenshots that land as `.webp` files and on the clipboard — no Snipping Tool UI, no tray clutter, no OCR. One AHK v2 script pipes captures through FFmpeg (`libwebp`).

## Stack

- **AutoHotkey v2** — hotkey hooks, zero UI
- **FFmpeg** — PNG → WebP via `libwebp` (path in `webpcap.ini`)
- **PowerShell** — GDI capture + clipboard (built into Windows)

## Portfolio blurb

*webpcap* is a media pipeline micro-tool: it intercepts native screenshot hotkeys, captures via WinAPI/GDI with no overlay chrome, and immediately transcodes to WebP through FFmpeg — saving named files and refreshing the clipboard in one motion. Minimal surface area, deterministic output, real encoder integration.

## Version History

v0.1 — Controls-first README; standalone run guide; `webpcap.ini.example`; temp-`.ps1` capture; privacy-safe public docs (no machine paths in tracked files).