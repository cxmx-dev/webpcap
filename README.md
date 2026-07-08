# webpcap

**Custom Media Pipeline Utility — zero-dependency WebP screenshot daemon**

Hotkey-native Windows screenshots that land as `.webp` files and on the clipboard — no Snipping Tool UI, no tray clutter, no OCR. One AHK v2 script pipes captures through your local FFmpeg engine (`libwebp`) and saves to `Pictures\Screenshots\WebP\`.

## Quick start

```bat
build.bat          rem start daemon (background)
test_hotkeys.bat   rem debug run + v0.1 checklist
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

**070826** — v0.1 scaffold: AHK daemon, ini config, build/test batches, FFmpeg WebP pipe.