# webpcap

**Device:** local **Windows desktop** tool (AHK + FFmpeg). Not a mobile web app. Browser helpers (`canvas-test.html`, canvas REC hook) still use a normal viewport when opened in a browser on any device for preview — capture itself requires this Windows host.

**Hub batch push:** from the portfolio hub root, `.\scripts\start-all.ps1` syncs this repo without launching the daemon. Single `start.ps1 -Repo webpcap` = **daemon only** (no push).

## How to run

### Start

```powershell
cd path\to\webpcap
.\build.ps1
```

Do **not** paste angle-bracket placeholders into PowerShell — `<` is reserved. Use a real folder path.

Starts **video-host** (`http://127.0.0.1:19787`) + the AHK daemon (keeps running in the background).  
No hub required. Regular PowerShell is enough (Admin only for first-time FFmpeg/AHK install).

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

**While any REC is active:** a **blinking red disc** sits on the primary **taskbar**, **just left of the overflow chevron (`^`)** (left of the system-tray / clock cluster) so **you** see recording status. The disc uses Windows **`WDA_EXCLUDEFROMCAPTURE`** — visible on screen, **not** burned into full / window / region MP4 output (gdigrab). Short toast on start (~2s); **`End`** (or same REC hotkey) stops and clears the indicator. Tweak horizontal pad via `recDotFromRight` in `webpcap.ahk` (`ShowRecDot`) if DPI/tray density shifts the chevron.

**Shortcut tags (you-only):** CAPS/REC feedback banners (saved / REC on / region hints) are a private on-screen tag — **not** a system `ToolTip` — with the same capture-exclude affinity. Region rubber-band, size label, and pick shield also exclude. **You** see chrome; stills and MP4s do not.

**Region UX:** cyan frame while dragging; after release, drag edges/corners/move the box; **`Enter`** **starts** region REC (or confirms region CAPS still); **`Esc`** cancels. Drag alone does not record video until **Enter**. A light full-desktop **pick shield** sits under the frame so mouse drag does **not** select text / highlight words in the app underneath (CAPS + REC region). Shield is hidden before capture starts (not in the still or MP4).

### Which REC mode?

| Mode | Hotkey | Frame | Typical use |
|------|--------|--------|-------------|
| **Full display** | `Ctrl`+`Shift`+`PrtSc` | Whole desktop | “What I see on the PC” |
| **Active window** | `Ctrl`+`Win`+`PrtSc` | Focused app only | Browser / Twitch tab only (no desktop clutter); focus that window first |
| **Region** | `Ctrl`+`Alt`+`PrtSc` | You draw the box | Custom crop (Clipchamp-like) |

All three write **video + system audio** in **one** `.mp4`. Maximized window ≈ full screen (crop benefit smaller). Prefer **borderless/windowed** games for window REC.

```powershell
# Optional: open save folders (uses *your* profile — no hardcoded username)
explorer "$env:USERPROFILE\Pictures\Screenshots\webpcap CAPS"
explorer "$env:USERPROFILE\Videos\webpcap REC"
```

### Controls

| Key | What it does | Output type |
|-----|----------------|-------------|
| `PrtSc` | Full desktop (virtual desktop) | still `.webp` + clipboard PNG |
| `Alt`+`PrtSc` | Active window (visible DWM frame) | still `.webp` + clipboard PNG |
| `Ctrl`+`PrtSc` | Region — drag, fine-tune, `Enter` | still `.webp` + clipboard PNG |
| `Ctrl`+`Shift`+`PrtSc` | Full display video + system audio; again or `End` | video+audio `.mp4` |
| `Ctrl`+`Win`+`PrtSc` | Active window video + system audio; again or `End` | video+audio `.mp4` |
| `Ctrl`+`Alt`+`PrtSc` | Region video + system audio (drag → fine-tune → `Enter`); again or `End` | video+audio `.mp4` |
| `End` | Stop whatever REC is running | — |

Either **Left/Right** Ctrl / Alt / Shift / Win work for combos.

### Destinations (anonymous / portable)

Defaults are **per Windows user** via `%USERPROFILE%` (or `$env:USERPROFILE` in PowerShell).  
Docs never use a machine username or drive letter — clone works the same on any PC.

*(Maintainers: machine-absolute paths belong in a private `USER-NOTES.md` at repo root — never in this README.)*

| Kind | Folder name | Path (anonymous) | Filename |
|------|-------------|------------------|----------|
| **Stills (CAPS)** | `webpcap CAPS` | `%USERPROFILE%\Pictures\Screenshots\webpcap CAPS\` | `Screenshot_YYYYMMDD_HHMMSS_*.webp` |
| **Full display REC** | `webpcap REC` | `%USERPROFILE%\Videos\webpcap REC\` | `Display_YYYYMMDD_HHMMSS_*.mp4` (H.264 + AAC) |
| **Window REC** | `webpcap REC` | same | `Window_YYYYMMDD_HHMMSS_*.mp4` (H.264 + AAC) |
| **Region REC** | `webpcap REC` | same | `Region_YYYYMMDD_HHMMSS_*.mp4` (H.264 + AAC) |

| Only two output folders | |
|-------------------------|--|
| 1. CAPS | `%USERPROFILE%\Pictures\Screenshots\webpcap CAPS\` |
| 2. REC | `%USERPROFILE%\Videos\webpcap REC\` |

- **Stills:** real WebP on disk; **Ctrl+V** pastes PNG (clipboard). Region CAP = rubber-band + fine-tune + `Enter`.
- **All REC MP4s:** **video + system audio** in **one file** (WASAPI loopback). Quiet audio if nothing is playing is OK.
- **A/V sync:** video-host measures loopback vs gdigrab start skew, stops audio before FFmpeg finalizes, then muxes with offset. Optional fine-tune: `audio_delay_ms` in `webpcap.ini` (positive = sound later). Log: `%TEMP%\webpcap-video.log` lines like `mux A/V sync: skip audio head …`.
- **REC status:** blinking red taskbar overlay for **all** modes (full / window / region), placed **just left of `^`**; icons under `assets/rec-on.ico` / `rec-off.ico`. Disc is **user-visible only** (`SetWindowDisplayAffinity` / `WDA_EXCLUDEFROMCAPTURE` in `webpcap.ahk`) — not in the video file. Start toast auto-hides (~2s).
- **Shortcut tags:** CAPS/REC feedback banners (and region pick chrome) use the same **exclude-from-capture** affinity — **you** see them; stills/MP4 do not.
- **Full / window / region** use gdigrab (crop for window/region). Window bounds use **DWM visible frame** (avoids Win11 shadow offsets that broke gdigrab). Coords = virtual desktop.
- **Region pick:** full-desktop click sink under the rubber-band so drag does not highlight text in the page below.
- **Games / Game Bar:** prefer borderless windowed for window REC; full or region REC for exclusive fullscreen. Do not steal `Win`+`G`.
- **Canvas helper** remains in the repo for demos but is **parked** off the main hotkey map.
- Override in `webpcap.ini` (gitignored): `outdir`, `viddir`, `audio` = `system` \| `off`, `audio_delay_ms` (optional A/V fine-tune).

**Stop daemon:** Task Manager → end `AutoHotkey64.exe` (and the hidden PowerShell `video-host` if needed).  
**Debug:** `.\test_hotkeys.ps1` or `webpcap.ahk --debug` (tooltips + visible tray icon). Logs: `%TEMP%\webpcap.log`, `%TEMP%\webpcap-video.log`.

---

## Canvas video (exact HTML `<canvas>`) — parked

Optional path for **your** demos only (not bound to a main hotkey right now). Records **only** the largest `<canvas>` via an in-page helper — no browser chrome.

**Requires both:**

1. `.\build.ps1` (video-host + daemon)  
2. **Helper loaded on the page** — F12 console must show `[webpcap] canvas helper ready`

If the tooltip says **NO helper**, the hotkey only flipped a flag on the host — **no `Canvas_*.mp4` will be created**.

### Easiest test (demo page + main REC)

```powershell
cd path\to\webpcap
.\build.ps1
.\open-canvas-test.ps1
```

Opens a spinning-canvas demo. **Record with the main map** (not a canvas-only hotkey):

| Key | Mode | Output |
|-----|------|--------|
| `Ctrl`+`Shift`+`PrtSc` | Full display | `Display_*.mp4` |
| `Ctrl`+`Win`+`PrtSc` | Active window | `Window_*.mp4` |
| `Ctrl`+`Alt`+`PrtSc` | Region | `Region_*.mp4` |
| `End` | Stop | — |

**Do not use** `Alt`+`Shift`+`PrtSc` (Windows High Contrast; old canvas toggle removed). Pure `Canvas_*.mp4` helper REC stays **parked**. On-screen red REC disc is excluded from capture.

### Inject on any demo page

```html
<script src="http://127.0.0.1:19787/webpcap-canvas.js"></script>
```

**HTTPS demos** (e.g. GitHub Pages): mixed content may block loading the script from `http://127.0.0.1`. Copy `webpcap-canvas.js` into that site (same origin). The helper only talks to `127.0.0.1` for start/stop + upload.

**Bookmarklet** (http / local pages; host must be up):

```text
javascript:(function(){var s=document.createElement('script');s.src='http://127.0.0.1:19787/webpcap-canvas.js';document.documentElement.appendChild(s);})();
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
notepad .\webpcap.ini   # set ffmpeg= if not on PATH
ffmpeg -version
```

### Configure (`webpcap.ini`)

| Setting | Purpose |
|---------|---------|
| `ffmpeg` | `ffmpeg.exe` on PATH, or full path |
| `outdir` | Still CAPS folder (default `%USERPROFILE%\Pictures\Screenshots\webpcap CAPS`) |
| `viddir` | MP4 REC folder (default `%USERPROFILE%\Videos\webpcap REC`) |
| `quality` | WebP quality `85`–`92` (default `90`) |
| `lossless` | `1` = lossless WebP, `0` = lossy |
| `fps` / `crf` | Display + canvas encode |
| `port` | video-host port (default `19787`) |
| `audio` | Full / window / region REC: `system` = speakers loopback into same MP4 (default); `off` = silent |
| `audio_delay_ms` | Optional A/V fine-tune after auto start-offset (ms). Positive = delay audio (sound later); negative = advance audio |
| `remap` | `1` = hook hotkeys, `0` = disable hooks |

Restart after edits: `.\build.ps1` (stop old AutoHotkey / video-host first if needed).

### Verify pipeline (no hotkeys)

```powershell
cd path\to\webpcap
.\verify.ps1
.\smoke-test.ps1
```

If `verify.ps1` creates a `.webp` but `PrtSc` does not, Windows is stealing the hotkey — run `.\disable-snipping.ps1`.

### If nothing saves

1. **Windows 11:** `.\disable-snipping.ps1` — or turn **OFF** *Use the Print screen key to open screen capture*.
2. Close other screenshot tools (ShareX, Snipping Tool, etc.).
3. Confirm FFmpeg path in `webpcap.ini`.
4. **Video:** `%TEMP%\webpcap-video.log` and `http://127.0.0.1:19787/health`.
5. **Canvas:** browser console should show `[webpcap] canvas helper ready`.
6. **Stills log:** `%TEMP%\webpcap.log`.
7. Restart: end AutoHotkey + video-host, then `.\build.ps1`.

**Wrong folder?** Run scripts from inside `webpcap`.

### Source on GitHub

**Repo:** https://github.com/cxmx-dev/webpcap (local-tool — no Pages)

Updates: `git add -A`, `git commit -m "…"`, `git push`.

**Privacy (what ships):** public set is this **`README.md`** + scripts/source — destinations stay **`%USERPROFILE%` anonymous**. **Never published** (gitignored): `webpcap.ini`, all **`USER-*.md`**, `NOTES.md`, `PLAN.md`, `README.dev.md`, session/convo logs, `iteration-log.md`.

---

## What this is

**Custom Media Pipeline Utility — WebP screenshots + X-ready MP4 capture**

Hotkey-native Windows stills and video: GDI to WebP; full / window / region desktop REC with **system audio** in one MP4 each; optional parked canvas helper for demos.

## Stack

- **AutoHotkey v2** — hotkeys, rubber-band region + fine-tune, DWM window bounds
- **FFmpeg** — PNG → WebP (`libwebp`); gdigrab full/crop → H.264; AAC mux
- **WASAPI loopback** (`WasapiLoopback.cs`) — system audio for all REC modes
- **PowerShell** — GDI capture, clipboard, video-host (`127.0.0.1`)
- **webpcap-canvas.js** — optional largest-`<canvas>` recorder (parked hotkey)

## Portfolio blurb

*webpcap* is a media pipeline micro-tool: PrtSc-family stills as WebP; full / window / region REC with system audio in one MP4 — Clipchamp-like drag framing (rubber-band + fine-tune) without a heavy UI, without fighting Game Bar or High Contrast shortcuts.

## Version History

71826 9:37:50:12 PM CST
• **`update .mds`:** CAPS/REC **shortcut tags** (and region pick chrome) are **user-visible only** — `Tip()` is a private Gui with `WDA_EXCLUDEFROMCAPTURE` (`ExcludeFromCapture`); rubber-band, size label, pick shield included. Replaces system `ToolTip` that could burn into stills/REC. Restart daemon (`.\build.ps1`) to load.

71626 11:10:08:88 PM CST
• **`update .mds`:** local docs only — private session log standardized as **`webpcap_convo.md`** (gitignored; keep that name). No product/code change; public set unchanged.

71626 10:17:00:87 PM CST
• **`update .mds`:** **A/V sync** for all REC modes (WASAPI `StartedUtc` + mux `-ss` / `-itsoffset`; stop audio before FFmpeg finalize; ini `audio_delay_ms`). **Region pick shield** — full-desktop click sink so rubber-band drag does not highlight text under the cursor (CAPS + REC); User-verified clean `Region_*.mp4`. Private ops guide `INSTRUCTIONS.md` (gitignored). Hub **`start-all.ps1`** pushed public set (`main` **`b9f51ae`**). Daemon = `build.ps1` / `start.ps1 -Repo webpcap` only (no push).

71226 5:29:25:90 PM CST
• **`update .mds`:** hub `start-all.ps1` sync pushed this repo (`main` **`de36402`**) — capture-exclude + canvas demo main-map copy live on GitHub. Reminder: single `start.ps1 -Repo webpcap` = **daemon only** (no push); batch push = **`start-all.ps1`**.

71226 5:25:52:73 PM CST
• **`update .mds`:** canvas demo copy aligned with main REC map — `open-canvas-test.ps1`, `canvas-test.html`, `webpcap-canvas.js` no longer say Alt+Shift+PrtSc (High Contrast trap / parked canvas toggle). Demo page → use Ctrl+Shift / Win / Alt+PrtSc. **User-verified:** full display REC on canvas-test; red REC disc **absent from MP4** (capture-exclude works).

71226 5:20:36:51 PM CST
• **REC indicator not in video:** blinking red taskbar disc still shows while recording; excluded from capture via `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)` so full / window / region MP4s no longer include the light. Tray blink unchanged. Requires Windows 10 2004+.

71026 2:49:40:70 PM CST
• **`update .mds`:** device scope (Windows desktop); hub **`start-all.ps1`** / `-SyncOnly` batch push without launching daemon.

71026 3:32:25:89 AM CST
• **REC dot position:** taskbar indicator moved **just left of the overflow chevron (`^`)** (`recDotFromRight` 228; was `R-118` / sat on wifi–clock). Daemon reloaded. Nudge pad in `ShowRecDot` if tray layout shifts.

71026 3:28:13:94 AM CST
• **REC status + region reliability:** blinking red taskbar indicator for **all** REC modes (full / window / region); short start toast (~2s). Region REC requires **Enter** after rubber-band (same shared picker as CAPS). PrtSc multi-mod combos via `HotIf` (fixes Ctrl+Alt collapsing to CAPS still). Assets: `assets/rec-on.ico`, `assets/rec-off.ico`. `build.ps1` prefers AutoHotkey64. User-verified: all 3 REC modes + region rubber-band.

70826 7:41:19:05 PM CST
• **Live on GitHub:** `main` `6d456f3` — REC A/V, hotkeys, rubber-band region. Public set only; private docs stayed gitignored.

70826 7:21:50:09 PM CST
• **Pre-push privacy:** public `.md` = `README.md` only (`%USERPROFILE%` paths). Gitignored private set confirmed (`USER-*.md`, ini, NOTES/PLAN/dev/convo/iteration-log). AHK launcher uses `$env:ProgramFiles` (no machine username).

70826 7:14:42:90 PM CST
• **Window REC User-verified** (A+V): `Ctrl+Win+PrtSc` → `Window_*.mp4` with system audio. Docs: **Which REC mode?** (full vs window vs region) — window = focused app only (e.g. browser/Twitch without desktop clutter).

70826 7:07:25:51 PM CST
• **Region rubber-band + fine-tune** (CAPS + REC): cyan frame, edge/corner/move, **`Enter`** confirm / **`Esc`** cancel. **Window REC** = `Ctrl+Win+PrtSc` (avoids Game Bar `Win+Alt+PrtSc` and High Contrast `Alt+Shift+PrtSc`). Window crop uses DWM visible bounds + host clamp (fixes empty `Window_*.mp4` from `-8,-8` shadow). `capture.ps1` CopyFromScreen fix for window/region stills. Fail-fast if gdigrab dies immediately. Game Bar / `Win+G` left free.

70826 6:33:11:20 PM CST
• **Hotkey redesign (right-hand PrtSc):** CAPS = `PrtSc` / `Alt+PrtSc` / `Ctrl+PrtSc` region. REC = full / window / region + system audio; **`End`** stops. Canvas parked.

70826 6:08:17:00 PM CST
• **Display REC + system audio:** one `Display_*.mp4` (H.264 + AAC). WASAPI loopback + FFmpeg mux. Ini `audio=system|off`.

70826 5:26:53:29 PM CST
• **v0.2 complete cycle:** canvas REC verified (cube + canvas-test; no F12 chrome); display REC OK; **sign-in autostart** (`install-autostart.ps1` / `uninstall-autostart.ps1`); helper inject on Rubix + cube demos; start/build footer = “Daemon running in background…” + full hotkey list; dual-doc `USER-*.md`.

70826 4:58:46:99 PM CST
• Full **`USER-*.md`** set for webpcap (NOTES, PLAN, README.dev, convo); maintainers use those for absolute paths.

70826 4:56:58:10 PM CST
• Dual-doc habit: public README stays anonymous; personal absolutes live in private **`USER-*.md`** (gitignored) at repo root.

70826 4:55:01:70 PM CST
• Destinations documented **anonymously** (`%USERPROFILE%` only): **`webpcap CAPS`** + **`webpcap REC`** — no machine usernames in public docs.

70826 4:50:08:33 PM CST
• Output folders renamed: **`webpcap CAPS`** (stills) and **`webpcap REC`** (video); defaults + docs updated.

70826 4:41:50:62 PM CST
• `update .mds` — **How to run** first: **Controls** + **Destinations** (stills WebP vs display/canvas MP4 paths) at the top; v0.2 video docs clarified.

70826 — v0.2 — **video**: `Shift+PrtSc` display MP4; `Alt+Shift+PrtSc` HTML canvas MP4; `video-host.ps1` + `webpcap-canvas.js` + `canvas-test.html`.

70826 5:22:43:53 CST — **live on GitHub** — https://github.com/cxmx-dev/webpcap (`main`, `45a65bf`).

70826 5:18:16:75 CST — v0.1.3 **verified**: PrtSc saves real WebP (`RIFF`/`WEBPVP8`); `capture.ps1`/`clip.ps1`; `smoke-test.ps1` PASS.

70826 5:18:16:75 CST — v0.1.3 — **RunWait fix** (AHK v2: single `Target` string, not two-arg form) + `disable-snipping.ps1` + `$` hotkey hooks.

v0.1.2 — RunWait comma attempt (still wrong in AHK v2).

v0.1.1 — `verify.ps1`; `#UseHook`; PNG clipboard; `%TEMP%\webpcap.log`; Win11 snipping note; accurate error messages.

v0.1 — Controls-first README; standalone run guide; `webpcap.ini.example`; temp-`.ps1` capture; privacy-safe public docs.
