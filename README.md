# webpcap

**Device:** local **Windows desktop** tool (AHK + FFmpeg). Not a mobile web app. Browser helpers (`canvas-test.html`, canvas REC hook) still use a normal viewport when opened in a browser on any device for preview — capture itself requires this Windows host.

## How to run

### Start

```powershell
cd path\to\webpcap
.\build.ps1
```

Do **not** paste angle-bracket placeholders into PowerShell — `<` is reserved. Use a real folder path.

Starts **video-host** (`http://127.0.0.1:19787`) + the AHK daemon + a small **watchdog** (keeps running in the background).
Regular PowerShell is enough (Admin only for first-time FFmpeg/AHK install).
Uses `AutoHotkey64_UIA.exe` (UI Access) when installed, so hotkeys also work while an elevated app has focus; `[daemon] ahk_uia=0` opts out.

**Tray:** a system-tray icon means the daemon is up (idle = dim / `rec-off`; REC = red blink). Right-click → reload daemon, restart video-host, open CAPS/REC folders, or exit.
**Sleep / wake:** after resume, AHK rehooks PrtSc (Reload when not recording; soft rehook if REC is active).
**Self-heal:** AHK pings video-host and restarts it if down (**not while a REC is active** — stop must finish cleanly); external `watchdog.ps1` restarts AHK and/or host if either dies, and clears stuck REC `ffmpeg` leftovers.

### Autostart (sign-in after power-on / reboot)

Run **once** so you never need to open a terminal after reboot:

```powershell
cd path\to\webpcap
.\install-autostart.ps1
```

Registers a **user** Scheduled Task (`webpcap`) that runs `build.ps1` ~20s after you sign in.
Remove: `.\uninstall-autostart.ps1`

### Hotkeys (while daemon is running)

Right-hand **PrtSc** + left-hand mods. **End** stops any REC.
Avoids OS traps: **not** `Alt`+`Shift`+`PrtSc` (High Contrast), **not** `Win`+`Alt`+`PrtSc` (Xbox Game Bar screenshot). **`Win`+`G`** stays free for Game Bar.

| Key | Mode | Action | Output |
|-----|------|--------|--------|
| `PrtSc` | CAPS | Full desktop still | `webpcap CAPS` `.webp` |
| `Alt`+`PrtSc` | CAPS | Active window still | CAPS `.webp` |
| `Ctrl`+`PrtSc` | CAPS | **Region** still — drag → **rubber-band** → fine-tune edges → **`Enter`** (`Esc` cancel) | CAPS `.webp` |
| `Shift`+`PrtSc`, `F22` or `Ctrl`+`Alt`+`Shift`+`F10` | CAPS | **Safe-to-post** full desktop still: every taskbar (clock, tray, weather, pinned apps) pixelated; blurred image also on clipboard. Plain `PrtSc` is never blurred | CAPS `*_safe.webp` |
| `Ctrl`+`Shift`+`PrtSc` | REC | Full display + **system audio** (toggle) | `Display_*.mp4` |
| `Ctrl`+`Win`+`PrtSc` | REC | Active window + **system audio** (toggle) | `Window_*.mp4` |
| `Ctrl`+`Alt`+`PrtSc` | REC | **Region** + **system audio** — drag → rubber-band → fine-tune → **`Enter`** | `Region_*.mp4` |
| `End` | REC | **Stop any** full / window / region recording | final MP4 |

Same REC hotkey again also stops. Canvas helper is **parked** (not on the main map).

**While any REC is active:** a **blinking red disc** sits on the primary **taskbar**, **just left of the overflow chevron (`^`)** so **you** see recording status. The disc uses Windows **`WDA_EXCLUDEFROMCAPTURE`** — visible on screen, **not** burned into MP4 output. Short toast on start (~2s); **`End`** stops and clears the indicator.

**Region UX:** cyan frame while dragging; after release, drag edges/corners/move the box; **`Enter`** **starts** region REC (or confirms region CAPS still); **`Esc`** cancels.

### Which REC mode?

| Mode | Hotkey | Frame | Typical use |
|------|--------|--------|-------------|
| **Full display** | `Ctrl`+`Shift`+`PrtSc` | Whole desktop | "What I see on the PC" |
| **Active window** | `Ctrl`+`Win`+`PrtSc` | Focused app only | Browser / app only (no desktop clutter) |
| **Region** | `Ctrl`+`Alt`+`PrtSc` | You draw the box | Custom crop |

All three write **video + system audio** in **one** `.mp4`.

```powershell
# Optional: open save folders (uses *your* profile — no hardcoded username)
explorer "$env:USERPROFILE\Pictures\Screenshots\webpcap CAPS"
explorer "$env:USERPROFILE\Videos\webpcap REC"
```

### Destinations (anonymous / portable)

Defaults are **per Windows user** via `%USERPROFILE%` (or `$env:USERPROFILE` in PowerShell).
Docs never use a machine username or drive letter — clone works the same on any PC.

| Kind | Folder name | Path (anonymous) | Filename |
|------|-------------|------------------|----------|
| **Stills (CAPS)** | `webpcap CAPS` | `%USERPROFILE%\Pictures\Screenshots\webpcap CAPS\` | `Screenshot_YYYYMMDD_HHMMSS_*.webp` |
| **Full display REC** | `webpcap REC` | `%USERPROFILE%\Videos\webpcap REC\` | `Display_YYYYMMDD_HHMMSS_*.mp4` (H.264 + AAC) |
| **Window REC** | `webpcap REC` | same | `Window_YYYYMMDD_HHMMSS_*.mp4` |
| **Region REC** | `webpcap REC` | same | `Region_YYYYMMDD_HHMMSS_*.mp4` |

- **Stills:** real WebP on disk; **Ctrl+V** pastes PNG (clipboard).
- **All REC MP4s:** **video + system audio** in **one file** (WASAPI loopback).
- Override in `webpcap.ini` (gitignored): `outdir`, `viddir`, `audio` = `system` \| `off`, `audio_delay_ms`, `encoder` = `auto` \| `nvenc` \| `x264`, `capture` = `auto` \| `ddagrab` \| `gdigrab`, `[capture] screen` / `rec_screen` = `mouse` \| `primary` \| `all` (which monitor stills / full-display REC grab), `flash=0` (hide the "Screen N" flash), `[windows] browsers_to_primary=1` (move new browser windows from a secondary monitor to the primary once; `browsers=` list, default off), `[daemon] rec_tone_gap_ms`, `ahk_uia=0`, `[capture] rec_output` = `auto` \| output number (force a Desktop Duplication output), `[paths] rec_ffmpeg` (optional ffmpeg used only for REC).

**Stop daemon:** tray → Exit webpcap, or Task Manager → end `AutoHotkey64.exe`.
**Debug:** `.\test_hotkeys.ps1` or `webpcap.ahk --debug`. Logs: `%TEMP%\webpcap.log`, `%TEMP%\webpcap-video.log` (look for `warmup`, `orphan`, `mux A/V sync`, `display saved`).

If **region REC** fails, check the video log; common past cause was a stuck capture process after a short stop timeout — current builds wait long enough for stop/mux and refuse “REC on” until frames actually write.

---

### Known issues

- If `paths.ffmpeg` lives on a drive that spins down, the video-host **startup check can hang** until the drive wakes. CAPS stills avoid this by preferring an ffmpeg on the system drive (`[paths] caps_ffmpeg`). Workaround: keep ffmpeg on the system drive, or wake the drive first.

## Canvas video (exact HTML `<canvas>`) — parked

Optional path for demos only. Records **only** the largest `<canvas>` via an in-page helper — no browser chrome.

**Requires both:**

1. `.\build.ps1` (video-host + daemon)
2. **Helper loaded on the page** — F12 console must show `[webpcap] canvas helper ready`

```powershell
cd path\to\webpcap
.\build.ps1
.\open-canvas-test.ps1
```

Inject on any demo page:

```html
<script src="http://127.0.0.1:19787/webpcap-canvas.js"></script>
```

---

## Setup (first time)

### Requirements

1. [AutoHotkey v2](https://www.autohotkey.com/)
2. [FFmpeg](https://ffmpeg.org/download.html) with `libwebp` + H.264 (`h264_nvenc` used when present, else `libx264`) — on `PATH`, or full path in `webpcap.ini`
3. Windows 10/11 with PowerShell 5.1+

### First-time config

```powershell
cd path\to\webpcap
Copy-Item .\webpcap.ini.example .\webpcap.ini
notepad .\webpcap.ini
ffmpeg -version
```

### Verify pipeline (no hotkeys)

```powershell
cd path\to\webpcap
.\verify.ps1
.\smoke-test.ps1
```

If `verify.ps1` creates a `.webp` but `PrtSc` does not, Windows Snipping Tool or Game Bar is stealing the hotkey — turn those off in Windows settings.

### Source

**Repo:** https://github.com/cxmx-dev/webpcap

## What this is

**Custom Media Pipeline Utility — WebP screenshots + X-ready MP4 capture**

Hotkey-native Windows stills and video: GDI to WebP; full / window / region desktop REC with **system audio** in one MP4 each; optional parked canvas helper for demos.

## Stack

- **AutoHotkey v2** — hotkeys, rubber-band region + fine-tune, DWM window bounds, sleep rehook, tray
- **FFmpeg** — PNG → WebP (`libwebp`); desktop grab (`ddagrab` when available, else `gdigrab`) → H.264 (`h264_nvenc` when available, else `libx264`); AAC mux
- **WASAPI loopback** (`WasapiLoopback.cs`) — system audio for all REC modes
- **PowerShell** — GDI capture, clipboard, video-host (`127.0.0.1`), external `watchdog.ps1`
- **webpcap-canvas.js** — optional largest-`<canvas>` recorder (parked)

## Portfolio blurb

*webpcap* is a media pipeline micro-tool: PrtSc-family stills as WebP; full / window / region REC with system audio in one MP4 — Clipchamp-like drag framing without a heavy UI, without fighting Game Bar or High Contrast shortcuts.

## Version History

2026-10-17 (b)
 Optional `[windows] browsers_to_primary=1`: a new browser window that opens on a secondary monitor is moved once to the primary (keeps its size if it fits, else maximized); tab drag-outs, dialogs, small and fullscreen windows are left alone. Default off.

2026-10-17
• Monitor select: `[capture] screen` / `rec_screen` = `mouse` | `primary` | `all` (default: monitor under the mouse); full-display REC maps the monitor to Desktop Duplication by display name, gdigrab fallback cropped. Brief `Screen N` flash after PrtSc (excluded from capture, `flash=0` off). System audio follows the current default output each REC, pads silence when idle (no more video-only clips), and survives a mid-REC device change.

2026-10-03
• REC start tone finishes before capture begins (`rec_tone_gap_ms=250`), so tones stay out of clips.

2026-10-02
• REC reliability: stop always finalizes; lost capture is detected and restarted as a new segment, segments joined on stop; ffmpeg errors kept per segment; fragmented temp MP4; REC prefers a system-drive ffmpeg. Runs under AutoHotkey UI Access so hotkeys work over elevated apps. REC start / saved / fail tones.

2026-09-30 (f)
 Verified with a keypad macro: one press of a key sending `Ctrl`+`Alt`+`Shift`+`F10` = exactly one `*_safe.webp` (no doubles). Docs only.

2026-09-30 (e)
• Safe-to-post shot also on `Ctrl`+`Alt`+`Shift`+`F10` (same `[safe] f22=1` switch) - for keypads whose software cannot send F22 and use a Ctrl+Alt+Shift macro instead.

2026-09-30 (d)
• Docs: known issue - video-host startup check can hang while a spun-down drive holding `paths.ffmpeg` wakes up. Public note on the safe shot made path-free.

2026-09-30 (c)
 Safe-to-post shot: `Shift`+`PrtSc` (test combo) and unmodified `F22` (e.g. a programmable keypad key set to send F22). Same instant in-process grab + sound/tag as `PrtSc`, then each visible taskbar (`Shell_TrayWnd` + every `Shell_SecondaryTrayWnd`, any edge; auto-hidden bars only blur their on-screen sliver) is pixelated in 32 px averaged blocks before the BMP / clipboard are written, so text and icons are unreadable. Saves `Screenshot_<ts>_safe.webp` (system-drive ffmpeg, temp-then-move, alpha dropped) or `_safe.png` fallback; no unblurred fallback path. Optional ini `[safe] block_px=32` / `f22=1`. Plain `PrtSc` unchanged. Test: taskbar band detail 5.32 -> 0.56 (mean gradient), rest of frame mean diff 0.08 vs plain shot; clipboard + PNG fallback blurred, alpha 255. Fixed during test: GDI stretch left alpha 0 -> transparent band in WebP.

2026-09-30 (b)
 CAPS 0-byte / missing stills fixed. Cause: `paths.ffmpeg` can live on a drive that spins down; a cold ffmpeg start took ~10-30 s, so the 30 s encode timeout killed ffmpeg (captures timed out; one left a 0-byte .webp). Now CAPS uses an ffmpeg on the system drive when one exists (optional `[paths] caps_ffmpeg`; REC still uses `paths.ffmpeg`), encodes to %TEMP% and moves into CAPS only on success, and on timeout/failure saves a PNG fallback (GDI+) instead of losing the shot. Tests: normal full capture 208 KB webp in ~300 ms; forced timeout -> valid PNG fallback, no 0-byte file.

2026-08-26
• REC start: `encoder=auto` / `capture=auto` (NVENC + Desktop Duplication when the local ffmpeg build has them); one automatic fallback if warmup hangs; loopback starts as soon as ffmpeg is alive; High process priority.

2026-08-05
• Region / full / window REC harden: live capture no longer uses faststart (empty file until finalize); warmup confirms frames before “REC on”; stop waits long enough for finalize + mux; watchdogs do not kill the host mid-REC; stuck REC ffmpeg cleaned on host restart.
• Docs: debug log hints + self-heal note (no host restart while recording).

2026-07-27
• Daemon hardening: sleep/wake rehook, dual watchdog, visible idle tray.

2026-07-18
• Region chrome capture-exclude.

2026-07-16
• A/V sync mux offset; region pick shield (no text select under drag).
