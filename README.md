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

**Tray:** a system-tray icon means the daemon is up (idle = dim / `rec-off`; REC = red blink). Right-click → reload daemon, restart video-host, open CAPS/REC folders, or exit.
**Sleep / wake:** after resume, AHK rehooks PrtSc (Reload when not recording; soft rehook if REC is active).
**Self-heal:** AHK pings video-host and restarts it if down; external `watchdog.ps1` restarts AHK and/or host if either dies.

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
- Override in `webpcap.ini` (gitignored): `outdir`, `viddir`, `audio` = `system` \| `off`, `audio_delay_ms`.

**Stop daemon:** tray → Exit webpcap, or Task Manager → end `AutoHotkey64.exe`.
**Debug:** `.\test_hotkeys.ps1` or `webpcap.ahk --debug`. Logs: `%TEMP%\webpcap.log`, `%TEMP%\webpcap-video.log`.

---

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
2. [FFmpeg](https://ffmpeg.org/download.html) with `libwebp` + `libx264` — on `PATH`, or full path in `webpcap.ini`
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

If `verify.ps1` creates a `.webp` but `PrtSc` does not, Windows is stealing the hotkey — run `.\disable-snipping.ps1`.

### Source

**Repo:** https://github.com/cxmx-dev/webpcap

Public set: this **`README.md`** + scripts/source — destinations stay **`%USERPROFILE%` anonymous**. Private config and notes stay gitignored.

## What this is

**Custom Media Pipeline Utility — WebP screenshots + X-ready MP4 capture**

Hotkey-native Windows stills and video: GDI to WebP; full / window / region desktop REC with **system audio** in one MP4 each; optional parked canvas helper for demos.

## Stack

- **AutoHotkey v2** — hotkeys, rubber-band region + fine-tune, DWM window bounds, sleep rehook, tray
- **FFmpeg** — PNG → WebP (`libwebp`); gdigrab full/crop → H.264; AAC mux
- **WASAPI loopback** (`WasapiLoopback.cs`) — system audio for all REC modes
- **PowerShell** — GDI capture, clipboard, video-host (`127.0.0.1`), external `watchdog.ps1`
- **webpcap-canvas.js** — optional largest-`<canvas>` recorder (parked)

## Portfolio blurb

*webpcap* is a media pipeline micro-tool: PrtSc-family stills as WebP; full / window / region REC with system audio in one MP4 — Clipchamp-like drag framing without a heavy UI, without fighting Game Bar or High Contrast shortcuts.
