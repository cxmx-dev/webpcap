#Requires AutoHotkey v2.0
#SingleInstance Force
#UseHook
#InputLevel 1
; webpcap — WebP stills + MP4 REC (full / window / region) + system audio
; Rubber-band region + fine-tune; End stops any REC
; Hardening: sleep-resume rehook, host/AHK watchdog, visible idle tray
; CAPS: press-time in-process GDI grab, instant sound + tag, in-process clipboard,
;       async WebP encode with timeout, per-step timing in webpcap.log, busy queue

global FFMPEG := "", OUT := "", Q := 90, LOSSLESS := 0, REMAP := 1, DBG := false
global VIDPORT := 19787, VIDDIR := ""
global PSHELL := A_WinDir "\System32\WindowsPowerShell\v1.0\powershell.exe"
global SelectingRegion := false
global RbTop := 0, RbBot := 0, RbLeft := 0, RbRight := 0
global RbLabel := 0
global PickShield := 0   ; full-screen click sink during region pick (stops text selection under cursor)
global RecBlinking := false, RecBlinkShow := true
global RecDotGui := 0
global TipGui := 0, TipTxt := 0
global IcoRecOn := A_ScriptDir "\assets\rec-on.ico"
global IcoRecOff := A_ScriptDir "\assets\rec-off.ico"
; Daemon hardening (sleep rehook + host watchdog + visible tray)
global SHOW_TRAY := 1, WATCHDOG := 1, WATCHDOG_SEC := 30, REHOOK_ON_RESUME := 1
global HostHealthy := false, HostRestartUtc := 0, ResumePending := false
global MsgSink := 0, HotkeysRegistered := false
; CAPS pipeline state (async encode jobs keyed by ffmpeg PID)
global CapBusy := false, CapQueue := [], EncJobs := Map()
global CAP_SOUND := 1, CAP_ENCODE_TIMEOUT_MS := 30000, CAP_GRAB_TIMEOUT_MS := 15000
; 2026-09-30b: ffmpeg used for CAPS WebP encodes (system-drive copy preferred - see ResolveCapsFfmpeg)
global CAPS_FFMPEG := "", ArgOutDir := "", ArgEncodeMs := 0, ArgCapsFfmpeg := ""
; 2026-09-30c: safe-to-post shot (full grab with every taskbar pixelated) - pixel block size
global SAFE_BLOCK_PX := 32, SAFE_HOTKEY_F22 := 1
global TrayStatusItem := "webpcap — ready"
; 2026-10-02: REC state poll while the red light is on (host may end a REC by itself)
global RecStartTick := 0, RecPollMiss := 0
; 2026-10-02b: audible REC feedback (red light / tags are hidden behind exclusive-fullscreen games)
global REC_SOUNDS := 1
; 2026-10-03: REC records system audio (loopback), so tones must never overlap a capture.
; Start tone plays to the end + this gap BEFORE the host is asked to start; stop/fail tones
; only play after the host answered (audio + ffmpeg stopped, file finalized/joined).
global REC_TONE_GAP_MS := 250
; 2026-10-17: which screen a full-screen still (PrtSc / safe shot) grabs.
; mouse = monitor under the cursor (default), primary = primary monitor, all = whole virtual desktop.
global CAP_SCREEN := "mouse"
; 2026-10-17: brief "Screen N" flash on the captured monitor after a full-screen still
; (shown after the grab, excluded from capture, never while REC is live). [capture] flash=0 = off
global CAP_FLASH := 1, FlashGui := 0
; 2026-10-17: [windows] browsers_to_primary=1 - a NEW top-level browser window that appears on a
; non-primary monitor is moved to the primary once (shell hook). Existing windows, windows dragged
; later and tab drag-outs are never touched. [windows] browsers = process list.
global B2P := 0, B2P_EXES := "firefox.exe,chrome.exe,msedge.exe,brave.exe,opera.exe,vivaldi.exe"
global B2P_Seen := Map(), B2P_MsgId := 0

CoordMode "Mouse", "Screen"

testMode := ""
for i, a in A_Args {
    if (a = "--debug")
        DBG := true
    else if (a = "--test" && A_Args.Has(i + 1))
        testMode := A_Args[i + 1]
    ; test-only overrides (smoke tests; the daemon never passes these)
    else if (a = "--outdir" && A_Args.Has(i + 1))
        ArgOutDir := A_Args[i + 1]
    else if (a = "--encode-timeout-ms" && A_Args.Has(i + 1))
        ArgEncodeMs := Integer(A_Args[i + 1])
    else if (a = "--caps-ffmpeg" && A_Args.Has(i + 1))
        ArgCapsFfmpeg := A_Args[i + 1]
}

LoadIni()
DirCreate(OUT)
if (VIDDIR)
    DirCreate(VIDDIR)

if (testMode) {
    Go(testMode)
    ; Encode is async - wait for it (bounded) so --test still produces the file
    tWait := A_TickCount
    while (EncJobs.Count && A_TickCount - tWait < CAP_ENCODE_TIMEOUT_MS + 2000)
        Sleep 50
    ExitApp(0)
}

; Idle: visible tray (default) so User can see daemon is up. REC: red blink + on-screen disc.
A_IconTip := "webpcap"
SetupTrayMenu()
TrayRestoreIdle()
EnsureMsgSink()
RegisterHotkeys()
SetupPowerResume()
SetupBrowsersToPrimary()
SetupHostWatchdog()
st0 := HttpGet("http://127.0.0.1:" VIDPORT "/health")
HostHealthy := (st0 != "")
; REC still running after a daemon restart: re-arm indicator so End (REC-only) works
if (InStr(st0, '"displayRecording":true') || InStr(st0, '"displayRecording": true'))
    RecIndicatorStart("REC")
TrayRefreshStatus()
Log("daemon up  tray=" SHOW_TRAY " watchdog=" WATCHDOG " rehook=" REHOOK_ON_RESUME " host=" (HostHealthy ? "ok" : "down"))
Persistent

; --- Hotkeys (callable again after resume / soft rehook) ---
RegisterHotkeys() {
    global REMAP, HotkeysRegistered, SAFE_HOTKEY_F22
    if (!REMAP) {
        HotkeysRegistered := false
        return
    }
    ; HotIf + *PrtSc: PrtSc often drops multi-mod combos when using only $^! style hotkeys.
    ; That bug turned Ctrl+Alt+PrtSc into CAPS region (webp) → End said "nothing recording".

    ; REC: Ctrl+Shift+PrtSc = full display
    HotIf (*) => GetKeyState("Control", "P") && GetKeyState("Shift", "P") && !GetKeyState("Alt", "P")
    Hotkey "*PrintScreen", (*) => VidToggle("display"), "On"
    Hotkey "*SC137", (*) => VidToggle("display"), "On"

    ; REC: Ctrl+Win+PrtSc = window
    HotIf (*) => GetKeyState("Control", "P") && (GetKeyState("LWin", "P") || GetKeyState("RWin", "P")) && !GetKeyState("Shift", "P") && !GetKeyState("Alt", "P")
    Hotkey "*PrintScreen", (*) => VidToggle("window"), "On"
    Hotkey "*SC137", (*) => VidToggle("window"), "On"

    ; REC: Ctrl+Alt+PrtSc = region video
    HotIf (*) => GetKeyState("Control", "P") && GetKeyState("Alt", "P") && !GetKeyState("Shift", "P")
    Hotkey "*PrintScreen", (*) => VidToggle("region"), "On"
    Hotkey "*SC137", (*) => VidToggle("region"), "On"

    ; CAPS: Ctrl+PrtSc only = region still
    HotIf (*) => GetKeyState("Control", "P") && !GetKeyState("Alt", "P") && !GetKeyState("Shift", "P") && !GetKeyState("LWin", "P") && !GetKeyState("RWin", "P")
    Hotkey "*PrintScreen", (*) => Go("region"), "On T2"
    Hotkey "*SC137", (*) => Go("region"), "On T2"

    ; CAPS: Alt+PrtSc = active window (no Ctrl)
    HotIf (*) => GetKeyState("Alt", "P") && !GetKeyState("Control", "P") && !GetKeyState("Shift", "P") && !GetKeyState("LWin", "P") && !GetKeyState("RWin", "P")
    Hotkey "*PrintScreen", (*) => Go("active"), "On T2"
    Hotkey "*SC137", (*) => Go("active"), "On T2"

    ; CAPS SAFE: Shift+PrtSc = full desktop with every taskbar pixelated (safe to post).
    ; Plain PrtSc below is NOT affected - it never blurs anything.
    HotIf (*) => GetKeyState("Shift", "P") && !GetKeyState("Control", "P") && !GetKeyState("Alt", "P") && !GetKeyState("LWin", "P") && !GetKeyState("RWin", "P")
    Hotkey "*PrintScreen", (*) => Go("safe"), "On T2"
    Hotkey "*SC137", (*) => Go("safe"), "On T2"

    ; CAPS: PrtSc alone = full desktop
    HotIf (*) => !GetKeyState("Control", "P") && !GetKeyState("Alt", "P") && !GetKeyState("Shift", "P") && !GetKeyState("LWin", "P") && !GetKeyState("RWin", "P")
    Hotkey "*PrintScreen", (*) => Go("full"), "On T2"
    Hotkey "*SC137", (*) => Go("full"), "On T2"

    HotIf()

    ; CAPS SAFE: F22 (e.g. a programmable keypad key set to send F22). Unmodified only - Ctrl/Shift+F22
    ; may belong to other keypad keys.
    if (SAFE_HOTKEY_F22) {
        Hotkey "F22", (*) => Go("safe"), "On T2"
        ; Ctrl+Alt+Shift+F10 = F22 alias: if a keypad vendor app cannot emit F13-F24, the keypad
        ; key can be programmed as an onboard macro sending this combo.
        Hotkey "^!+F10", (*) => Go("safe"), "On T2"
    }

    ; End stops REC - only while a REC is running; otherwise End reaches the app as normal
    HotIf RecActiveHotIf
    Hotkey "End", (*) => VidStop(), "On"
    HotIf()
    HotkeysRegistered := true
}

RecActiveHotIf(*) {
    global RecBlinking
    return RecBlinking
}

; Hidden message sink so WM_POWERBROADCAST reaches this process after sleep/wake.
EnsureMsgSink() {
    global MsgSink
    if (MsgSink) {
        try {
            if (WinExist("ahk_id " MsgSink.Hwnd))
                return
        } catch {
        }
        try MsgSink.Destroy()
        MsgSink := 0
    }
    g := Gui("+ToolWindow -Caption +E0x08000000")
    g.Show("x0 y0 w1 h1 NoActivate Hide")
    MsgSink := g
}

; --- New browser windows -> primary monitor ([windows] browsers_to_primary) ---
SetupBrowsersToPrimary() {
    global B2P, B2P_EXES, B2P_MsgId
    if (!B2P)
        return
    B2P_MsgId := DllCall("RegisterWindowMessage", "str", "SHELLHOOK", "uint")
    if (!B2P_MsgId || !DllCall("RegisterShellHookWindow", "ptr", A_ScriptHwnd))
        return Log("browsers_to_primary: shell hook registration failed")
    OnMessage(B2P_MsgId, B2P_ShellMsg)
    Log("browsers_to_primary on: " B2P_EXES)
}

B2P_ShellMsg(wParam, lParam, *) {
    global B2P_Seen
    if ((wParam & 0x7FFF) != 1)         ; HSHELL_WINDOWCREATED only
        return
    hwnd := lParam
    if (B2P_Seen.Has(hwnd))             ; act at most once per window
        return
    if (B2P_Seen.Count > 300) {         ; forget windows that are gone
        for h in [B2P_Seen*]
            if !WinExist("ahk_id " h)
                B2P_Seen.Delete(h)
    }
    B2P_Seen[hwnd] := A_TickCount
    if GetKeyState("LButton", "P")      ; tab dragged out / window being placed by hand
        return
    SetTimer(B2P_Check.Bind(hwnd, 0), -200)   ; let the browser finish its own placement
}

B2P_Check(hwnd, tries) {
    global B2P_EXES, SelectingRegion, CapBusy
    try {
        if !WinExist("ahk_id " hwnd)
            return
        if (SelectingRegion || CapBusy) {       ; never move windows during a capture
            if (tries < 40)
                SetTimer(B2P_Check.Bind(hwnd, tries + 1), -500)
            return
        }
        if GetKeyState("LButton", "P")          ; user is dragging it
            return
        exe := StrLower(WinGetProcessName("ahk_id " hwnd))
        if !InStr("," B2P_EXES ",", "," exe ",")
            return
        style := WinGetStyle("ahk_id " hwnd), ex := WinGetExStyle("ahk_id " hwnd)
        if !(style & 0x10000000) {              ; WS_VISIBLE not yet
            if (tries < 25)                     ; slow first start: wait up to ~5 s
                SetTimer(B2P_Check.Bind(hwnd, tries + 1), -200)
            return
        }
        ; real browser window only: WS_CAPTION, not WS_CHILD, not WS_EX_TOOLWINDOW, not owned (dialogs/popups)
        if ((style & 0xC00000) != 0xC00000 || (style & 0x40000000) || (ex & 0x80)
            || DllCall("GetWindow", "ptr", hwnd, "uint", 4, "ptr"))
            return
        mm := WinGetMinMax("ahk_id " hwnd)
        if (mm = -1)
            return
        WinGetPos(&x, &y, &w, &h, "ahk_id " hwnd)
        if (w < 300 || h < 200)
            return
        mon := MonitorAt(x + w // 2, y + h // 2)
        if (!mon)                               ; centre off-screen (taller than its monitor): most overlap
            mon := MonitorMostOverlap(x, y, w, h)
        prim := MonitorGetPrimary()
        if (!mon || mon = prim)
            return
        MonitorGet(mon, &ml, &mt, &mr, &mb)
        if (mm != 1 && x <= ml && y <= mt && x + w >= mr && y + h >= mb)
            return                              ; covers the whole monitor (fullscreen video)
        MonitorGetWorkArea(prim, &pl, &pt, &pr, &pb)
        pw := pr - pl, ph := pb - pt
        if (mm = 1) {                           ; maximized: restore, move, maximize again
            WinRestore("ahk_id " hwnd)
            WinGetPos(&x, &y, &w, &h, "ahk_id " hwnd)
            w := Min(w, pw), h := Min(h, ph)
            WinMove(pl + (pw - w) // 2, pt + (ph - h) // 2, w, h, "ahk_id " hwnd)
            WinMaximize("ahk_id " hwnd)
            how := "maximized"
        } else if (w <= pw && h <= ph) {        ; fits: same size, centred
            WinMove(pl + (pw - w) // 2, pt + (ph - h) // 2, , , "ahk_id " hwnd)
            how := "moved " w "x" h
        } else {                                ; too big for the primary work area
            WinMove(pl, pt, , , "ahk_id " hwnd)
            WinMaximize("ahk_id " hwnd)
            how := "too big - maximized"
        }
        Log("browsers_to_primary: " exe " hwnd=" hwnd " from screen " mon " (" x "," y ") -> primary, " how)
    } catch as e {
        Log("browsers_to_primary: " e.Message)
    }
}

SetupPowerResume() {
    global REHOOK_ON_RESUME
    if (!REHOOK_ON_RESUME)
        return
    OnMessage(0x218, OnPowerBroadcast)  ; WM_POWERBROADCAST
}

OnPowerBroadcast(wParam, *) {
    ; PBT_APMSUSPEND=4  PBT_APMRESUMESUSPEND=7  PBT_APMRESUMECRITICAL=6  PBT_APMRESUMEAUTOMATIC=0x12
    if (wParam = 0x4) {
        Log("power: suspend")
        return 0
    }
    if (wParam = 0x7 || wParam = 0x12 || wParam = 0x6) {
        global ResumePending
        Log("power: resume wParam=" wParam)
        ; Debounce multi-fire resume messages
        ResumePending := true
        SetTimer(OnSystemResume, -2500)
        return 0
    }
}

; After sleep, low-level PrtSc hooks often die while the process still looks alive.
; Prefer Reload (full rehook). If REC is active, soft-rehook only so recording is not killed.
OnSystemResume(*) {
    global ResumePending, SelectingRegion, VIDPORT, RecBlinking
    if (!ResumePending)
        return
    ResumePending := false
    if (SelectingRegion) {
        Log("resume: region pick active — delay rehook 5s")
        SetTimer(OnSystemResume, -5000)
        ResumePending := true
        return
    }
    st := HttpGet("http://127.0.0.1:" VIDPORT "/health")
    recActive := (st != "" && (InStr(st, '"displayRecording":true') || InStr(st, '"displayRecording": true')))
    if (recActive || RecBlinking) {
        Log("resume: REC active — soft rehook only (no Reload)")
        try RegisterHotkeys()
        EnsureHostAlive(true)
        TrayRefreshStatus()
        Tip("webpcap rehooked after wake (REC still running)", 2500)
        return
    }
    EnsureHostAlive(true)
    Log("resume: Reload for full hotkey rehook")
    ; Brief tip may not show across Reload; log is the durable signal
    Reload
}

SetupHostWatchdog() {
    global WATCHDOG, WATCHDOG_SEC
    if (!WATCHDOG)
        return
    sec := WATCHDOG_SEC < 10 ? 10 : WATCHDOG_SEC
    ; Fat-arrow callback is more reliable than bare function name for SetTimer in some AHK builds
    SetTimer(() => HostWatchdogTick(), sec * 1000)
}

HostWatchdogTick() {
    try {
        global SelectingRegion, RecBlinking, HostHealthy
        ; Never restart host during region pick or active REC — stop holds the
        ; HTTP listener, so /health can fail and a restart would kill ffmpeg mid-write.
        if (SelectingRegion || RecBlinking)
            return
        was := HostHealthy
        ok := EnsureHostAlive(false)
        HostHealthy := ok
        if (!RecBlinking)
            TrayRefreshStatus()
        if (!ok && was)
            Tip("video-host down - restarting...", 2000)
        else if (ok && !was)
            Log("watchdog: video-host back")
        else if (!ok)
            Log("watchdog: host still down after ensure")
    } catch as e {
        Log("watchdog tick error: " e.Message)
    }
}

; Returns true if /health is OK. Optionally restarts host when down (throttled).
EnsureHostAlive(forceRestart := false) {
    global VIDPORT, HostRestartUtc
    st := HttpGet("http://127.0.0.1:" VIDPORT "/health")
    if (st != "")
        return true
    ; Throttle: at most one host restart every 45s unless force
    now := A_TickCount
    if (!forceRestart && HostRestartUtc && (now - HostRestartUtc < 45000))
        return false
    HostRestartUtc := now
    Log("watchdog: video-host offline - restarting")
    RestartVideoHost()
    ; Wait briefly for health
    Loop 15 {
        Sleep 200
        if (HttpGet("http://127.0.0.1:" VIDPORT "/health") != "")
            return true
    }
    return false
}

RestartVideoHost() {
    global PSHELL
    host := A_ScriptDir "\video-host.ps1"
    if (!FileExist(host)) {
        Log("watchdog: missing video-host.ps1")
        return
    }
    pidFile := A_Temp "\webpcap-video-host.pid"
    if (FileExist(pidFile)) {
        try {
            oldTxt := Trim(FileRead(pidFile, "UTF-8"))
            ; strip BOM / CR leftovers; pull first integer only
            if (RegExMatch(oldTxt, "(\d+)", &m)) {
                old := m[1] + 0  ; numeric coerce without Integer() type pitfalls
                if (old > 0) {
                    try ProcessClose(old)
                }
            }
        } catch as e {
            Log("watchdog: pid close " e.Message)
        }
        try FileDelete(pidFile)
        Sleep 400
    }
    ; Kill stuck gdigrab leftovers so next REC does not hang on a zombie grab
    try {
        for proc in ComObjGet("winmgmts:").ExecQuery("Select ProcessId,CommandLine from Win32_Process where Name='ffmpeg.exe'") {
            cl := proc.CommandLine
            if (cl != "" && InStr(cl, "webpcap_rec_")) {
                try ProcessClose(proc.ProcessId)
                Log("watchdog: killed orphan ffmpeg " proc.ProcessId)
            }
        }
    } catch as e {
        Log("watchdog: orphan ffmpeg scan " e.Message)
    }
    ; Same launch shape as build.ps1 (quoted -File / -Root)
    args := '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' host '" -Root "' A_ScriptDir '"'
    ; 2026-10-02b: under AutoHotkey64_UIA.exe this process is High integrity; a plain Run() would
    ; make the host High too, and build.ps1/watchdog.ps1 (medium) could then not stop it.
    ; ShellRun launches through Explorer, so the host stays a normal medium-integrity process.
    try {
        ShellRun(PSHELL, args, A_ScriptDir, "", 0)
        Log("watchdog: launched video-host (shell)")
    } catch as e {
        Log("watchdog: shell launch fail " e.Message " - falling back to Run")
        try {
            Run(PSHELL " " args,, "Hide")
            Log("watchdog: launched video-host")
        } catch as e2 {
            Log("watchdog: start host fail " e2.Message)
        }
    }
}

; Run via the desktop shell (Explorer) = caller's normal medium token, not our UIA/High one.
; From AutoHotkeyUX inc/ShellRun.ahk (Lexikos). Docs: Shell.ShellExecute.
ShellRun(filePath, arguments?, directory?, operation?, show?) {
    static VT_UI4 := 0x13, SWC_DESKTOP := ComValue(VT_UI4, 0x8)
    ComObject("Shell.Application").Windows.Item(SWC_DESKTOP).Document.Application
        .ShellExecute(filePath, arguments?, directory?, operation?, show?)
}

SetupTrayMenu() {
    global TrayStatusItem
    A_TrayMenu.Delete()
    TrayStatusItem := "webpcap — ready"
    A_TrayMenu.Add(TrayStatusItem, (*) => 0)
    A_TrayMenu.Disable(TrayStatusItem)
    A_TrayMenu.Add()
    A_TrayMenu.Add("Reload daemon (rehook)", (*) => TrayReload())
    A_TrayMenu.Add("Restart video-host", (*) => TrayRestartHost())
    A_TrayMenu.Add()
    A_TrayMenu.Add("Open CAPS folder", (*) => TrayOpenCaps())
    A_TrayMenu.Add("Open REC folder", (*) => TrayOpenRec())
    A_TrayMenu.Add()
    A_TrayMenu.Add("Exit webpcap", (*) => TrayExit())
}

TrayReload() {
    Log("tray: Reload")
    Reload
}

TrayRestartHost() {
    Log("tray: restart video-host")
    Tip("restarting video-host…", 1500)
    ok := EnsureHostAlive(true)
    global HostHealthy
    HostHealthy := ok
    TrayRefreshStatus()
    Tip(ok ? "video-host OK" : "video-host still down — see webpcap-video.log", ok ? 1500 : 3500)
}

TrayOpenCaps() {
    global OUT
    try Run('explorer "' OUT '"')
}

TrayOpenRec() {
    global VIDDIR
    if (VIDDIR)
        try Run('explorer "' VIDDIR '"')
}

TrayExit() {
    Log("tray: Exit")
    ExitApp()
}

TrayRefreshStatus() {
    global HostHealthy, SHOW_TRAY, DBG, RecBlinking, TrayStatusItem
    if (RecBlinking)
        return
    st := HostHealthy ? "ready" : "host offline"
    newName := "webpcap — " st
    A_IconTip := "webpcap · " st "`nPrtSc still · Shift+PrtSc/F22 safe · Ctrl+Shift+PrtSc REC`nRight-click for menu"
    if (TrayStatusItem != newName) {
        try {
            A_TrayMenu.Rename(TrayStatusItem, newName)
            TrayStatusItem := newName
        } catch {
            try {
                SetupTrayMenu()
                TrayStatusItem := "webpcap — ready"
                if (TrayStatusItem != newName) {
                    try A_TrayMenu.Rename(TrayStatusItem, newName)
                    TrayStatusItem := newName
                }
            } catch {
            }
        }
    }
    ; Keep idle icon visible unless tray_icon=0 (and not debug)
    if (SHOW_TRAY || DBG)
        A_IconHidden := false
    else
        A_IconHidden := true
}

LoadIni() {
    global FFMPEG, OUT, Q, LOSSLESS, REMAP, VIDPORT, VIDDIR
    global SHOW_TRAY, WATCHDOG, WATCHDOG_SEC, REHOOK_ON_RESUME
    global CAP_SOUND, CAP_ENCODE_TIMEOUT_MS, CAP_GRAB_TIMEOUT_MS
    global CAPS_FFMPEG, ArgOutDir, ArgEncodeMs, ArgCapsFfmpeg, SAFE_BLOCK_PX, SAFE_HOTKEY_F22
    ini := A_ScriptDir "\webpcap.ini"
    ex := A_ScriptDir "\webpcap.ini.example"
    if (!FileExist(ini) && FileExist(ex))
        FileCopy ex, ini
    FFMPEG := ExpandEnvPath(IniRead(ini, "paths", "ffmpeg", "ffmpeg.exe"))
    OUT := ExpandEnvPath(IniRead(ini, "paths", "outdir", EnvGet("USERPROFILE") "\Pictures\Screenshots\webpcap CAPS"))
    VIDDIR := ExpandEnvPath(IniRead(ini, "paths", "viddir", EnvGet("USERPROFILE") "\Videos\webpcap REC"))
    Q := IniRead(ini, "encode", "quality", 90)
    LOSSLESS := IniRead(ini, "encode", "lossless", 0)
    REMAP := IniRead(ini, "hotkeys", "remap", 1)
    VIDPORT := Integer(IniRead(ini, "video", "port", 19787))
    SHOW_TRAY := Integer(IniRead(ini, "daemon", "tray_icon", 1))
    WATCHDOG := Integer(IniRead(ini, "daemon", "watchdog", 1))
    WATCHDOG_SEC := Integer(IniRead(ini, "daemon", "watchdog_sec", 30))
    REHOOK_ON_RESUME := Integer(IniRead(ini, "daemon", "rehook_on_resume", 1))
    CAP_SOUND := Integer(IniRead(ini, "feedback", "sound", 1))
    global REC_SOUNDS
    REC_SOUNDS := Integer(IniRead(ini, "daemon", "rec_sounds", 1))
    global REC_TONE_GAP_MS
    REC_TONE_GAP_MS := Integer(IniRead(ini, "daemon", "rec_tone_gap_ms", 250))
    global CAP_SCREEN
    CAP_SCREEN := StrLower(Trim(IniRead(ini, "capture", "screen", "mouse")))
    if !(CAP_SCREEN = "mouse" || CAP_SCREEN = "primary" || CAP_SCREEN = "all")
        CAP_SCREEN := "mouse"
    global CAP_FLASH
    CAP_FLASH := Integer(IniRead(ini, "capture", "flash", 1))
    global B2P, B2P_EXES
    try B2P := Integer(IniRead(ini, "windows", "browsers_to_primary", 0))
    catch
        B2P := 0
    B2P_EXES := StrLower(StrReplace(IniRead(ini, "windows", "browsers", B2P_EXES), " "))
    CAP_ENCODE_TIMEOUT_MS := Integer(IniRead(ini, "timeouts", "encode_ms", 30000))
    CAP_GRAB_TIMEOUT_MS := Integer(IniRead(ini, "timeouts", "grab_fallback_ms", 15000))
    SAFE_BLOCK_PX := Max(16, Integer(IniRead(ini, "safe", "block_px", 32)))
    SAFE_HOTKEY_F22 := Integer(IniRead(ini, "safe", "f22", 1))
    if (ArgOutDir != "")
        OUT := ArgOutDir
    if (ArgEncodeMs > 0)
        CAP_ENCODE_TIMEOUT_MS := ArgEncodeMs
    CAPS_FFMPEG := ResolveCapsFfmpeg(ArgCapsFfmpeg != "" ? ArgCapsFfmpeg : ExpandEnvPath(IniRead(ini, "paths", "caps_ffmpeg", "")))
    Log("CAPS ffmpeg=" CAPS_FFMPEG (CAPS_FFMPEG != FFMPEG ? "  (paths.ffmpeg=" FFMPEG " kept for REC)" : ""))
    if (!FileExist(FFMPEG))
        Tip("ffmpeg not found - edit webpcap.ini", 4000)
}

; 2026-09-30b: an ffmpeg.exe on another drive (e.g. a drive that spins down)
; took ~30 s to start after the drive slept -> every CAPS encode hit the 30 s kill.
; Stills use an ffmpeg on the system drive when one exists:
;   1. [paths] caps_ffmpeg (explicit)   2. paths.ffmpeg if already on the system drive
;   3. WinGet link / common installs on the system drive   4. paths.ffmpeg as-is
ResolveCapsFfmpeg(explicit) {
    global FFMPEG
    if (explicit != "" && FileExist(explicit))
        return explicit
    sys := SubStr(A_WinDir, 1, 2)
    if (FileExist(FFMPEG) && SubStr(FFMPEG, 2, 1) = ":" && SubStr(FFMPEG, 1, 2) = sys)
        return FFMPEG
    for cand in [EnvGet("LOCALAPPDATA") "\Microsoft\WinGet\Links\ffmpeg.exe"
               , A_ProgramFiles "\ffmpeg\bin\ffmpeg.exe"
               , sys "\ffmpeg\bin\ffmpeg.exe"] {
        if (FileExist(cand) && SubStr(cand, 1, 2) = sys)
            return cand
    }
    return FFMPEG
}

ExpandEnvPath(p) {
    Loop {
        if !RegExMatch(p, "%(\w+)%", &m)
            return p
        p := StrReplace(p, m[0], EnvGet(m[1]))
    }
}

; --- CAPS (stills) ---
; Pixels are grabbed in-process (GDI BitBlt) at press time - no PowerShell spawn.
; Sound + tag right after the grab, clipboard set in-process, WebP encode runs async
; (ffmpeg, bounded by timeouts.encode_ms). Presses during a capture are queued
; (full/active) or answered with a "busy" tag (region) - never silently dropped.
Go(mode) {
    global SelectingRegion, CapBusy, CapQueue
    if (SelectingRegion) {
        Log("CAPS " mode " ignored: region pick active")
        return Tip("webpcap busy: region pick active - Enter confirm / Esc cancel", 1500)
    }
    if (CapBusy) {
        if (mode = "region" || CapQueue.Length >= 5) {
            Log("CAPS " mode " busy (not queued)")
            return Tip("webpcap busy - capture in progress, press again", 1500)
        }
        CapQueue.Push(mode)
        Log("CAPS " mode " queued depth=" CapQueue.Length)
        return Tip("webpcap busy - " mode " capture queued", 1000)
    }
    CapBusy := true
    try {
        CapsOnce(mode)
    } catch as e {
        Log("CAPS " mode " error: " e.Message)
        Tip("capture error - see " A_Temp "\webpcap.log", 4000)
    } finally {
        CapBusy := false
    }
    if (CapQueue.Length)
        SetTimer(CapsDrainQueue, -1)
}

CapsDrainQueue() {
    global CapQueue
    if (CapQueue.Length)
        Go(CapQueue.RemoveAt(1))
}

CapsOnce(mode) {
    global OUT, FFMPEG, CAPS_FFMPEG, SelectingRegion, CAP_SCREEN
    tPress := QpcMs()
    Log("CAPS " mode)
    HideScreenFlash(true)
    x := 0, y := 0, w := 0, h := 0
    scr := ""
    if (mode = "region") {
        SelectingRegion := true
        Tip("region CAP: drag box  |  Esc cancel", 0)
        ok := SelectRegionInteractive(&x, &y, &w, &h)
        SelectingRegion := false
        HideRubber()
        HideTip()
        if (!ok || w < 2 || h < 2) {
            Log("CAPS region cancelled")
            return
        }
        Sleep 30            ; let DWM drop the rubber-band / shield frame
        tPress := QpcMs()   ; region: measure from Enter
    } else if (mode = "active") {
        if (!GetActiveVisibleRect(&x, &y, &w, &h))
            return Tip("could not read active window bounds", 3000)
    } else {
        scr := CapScreenRect(&x, &y, &w, &h)
        Log("CAPS " mode " screen=" scr " rect=" x "," y " " w "x" h)
    }
    ts := FormatTime(, "yyyyMMdd_HHmmss") "_" A_TickCount
    if (mode = "safe")
        ts .= "_safe"
    webp := OUT "\Screenshot_" ts ".webp"
    src := A_Temp "\webpcap_" ts ".bmp"
    how := "gdi"
    if (mode = "safe")
        tbRects := TaskbarRects()       ; read before the grab - same instant as the pixels
    hbm := GdiCaptureRect(x, y, w, h)
    tGrab := QpcMs()
    CapsFeedbackSound()
    if (mode = "safe") {
        ; Safe shot must never leave unblurred pixels anywhere: no GDI fallback path.
        if (!hbm)
            return Tip("safe shot failed (screen grab) - nothing saved", 4000)
        n := BlurTaskbars(hbm, x, y, w, h, tbRects)
        how := "gdi+safe(" n " taskbar" (n = 1 ? "" : "s") ")"
    }
    ; Pixels are already in memory: only now may the flash appear on screen
    if (hbm && (mode = "full" || mode = "safe"))
        ShowScreenFlash(scr, x, y, w, h)
    if (hbm) {
        Tip((mode = "safe" ? "safe shot " : "captured ") w "x" h " - saving...", 0)
        saved := GdipSaveHBitmap(hbm, src, "bmp")
        tSave := QpcMs()
        clip := ClipSetHBitmap(hbm)     ; clipboard owns hbm on success
        if (!clip)
            DllCall("DeleteObject", "ptr", hbm)
        tClip := QpcMs()
        if (!saved) {
            Log("CAPS " mode " GDI+ save failed: " src)
            return Tip("capture save failed - see webpcap.log", 4000)
        }
    } else {
        ; Fallback: legacy PowerShell grabber, bounded by timeouts.grab_fallback_ms
        how := "ps-fallback"
        Log("CAPS " mode " GDI grab failed - PowerShell fallback")
        Tip("capturing (fallback)...", 0)
        src := A_Temp "\webpcap_" ts ".png"
        if (!RunCapture((mode = "full" && CAP_SCREEN = "all") ? "full" : "region", src, x, y, w, h))
            return Tip("capture failed - see " A_Temp "\webpcap.log", 4000)
        tGrab := QpcMs(), tSave := tGrab
        clip := ClipSetFromFile(src)
        tClip := QpcMs()
    }
    if (!FileExist(CAPS_FFMPEG)) {
        ; No encoder: still keep the shot (PNG straight into the CAPS folder).
        CapsSaveFallback({src: src, webp: webp, tmp: "", mode: mode})
        return Tip("ffmpeg not found - saved PNG instead (edit webpcap.ini)", 4000)
    }
    StartEncodeJob(src, webp, mode, how, w, h, tPress, tGrab, tSave, tClip, clip)
}

StartEncodeJob(src, webp, mode, how, w, h, tPress, tGrab, tSave, tClip, clip) {
    global CAPS_FFMPEG, Q, LOSSLESS, EncJobs
    ; 2026-09-30b: encode into %TEMP% and move into the CAPS folder only when the
    ; WebP is complete - a killed/failed encode can no longer leave a 0-byte file.
    tmp := RegExReplace(src, "\.\w+$", "") ".webp"
    try FileDelete(tmp)
    args := (LOSSLESS
        ? '-nostdin -hide_banner -loglevel error -y -i "' src '" -c:v libwebp -lossless 1 "' tmp '"'
        : '-nostdin -hide_banner -loglevel error -y -i "' src '" -c:v libwebp -q:v ' Q ' "' tmp '"')
    if (mode = "safe")   ; never let a stray alpha channel blank (or reveal) the blurred band
        args := StrReplace(args, '-c:v libwebp', '-vf format=rgb24 -c:v libwebp')
    pid := 0
    try {
        Run('"' CAPS_FFMPEG '" ' args, , "Hide", &pid)
    } catch as e {
        Log("CAPS " mode " ffmpeg launch failed: " e.Message)
        CapsSaveFallback({src: src, webp: webp, tmp: tmp, mode: mode})
        return Tip("ffmpeg launch failed - saved PNG instead (see webpcap.log)", 4000)
    }
    EncJobs[pid] := {src: src, webp: webp, tmp: tmp, mode: mode, how: how, w: w, h: h, tPress: tPress, tGrab: tGrab, tSave: tSave, tClip: tClip, tEnc: QpcMs(), clip: clip}
    SetTimer(EncodePoll, 50)
}

EncodePoll() {
    global EncJobs, CAP_ENCODE_TIMEOUT_MS, DBG
    for pid, j in EncJobs.Clone() {
        now := QpcMs()
        if (ProcessExist(pid)) {
            if (now - j.tEnc > CAP_ENCODE_TIMEOUT_MS) {
                try ProcessClose(pid)
                try ProcessWaitClose(pid, 3)      ; let it release the temp files
                EncJobs.Delete(pid)
                Log(Format("CAPS {} encode TIMEOUT after {:.0f} ms (killed ffmpeg {})", j.mode, now - j.tEnc, pid))
                saved := CapsSaveFallback(j)
                Tip(saved ? "webpcap: WebP encode timed out - saved PNG instead" : "webpcap: encode timed out - image kept in %TEMP% (see webpcap.log)", 4000)
            }
            continue
        }
        EncJobs.Delete(pid)
        ok := false
        try ok := (FileGetSize(j.tmp) > 0)
        if (ok) {
            try {
                FileMove(j.tmp, j.webp, 1)
            } catch as e {
                ok := false
                Log("CAPS " j.mode " move to CAPS failed: " e.Message)
            }
        }
        if (ok) {
            try FileDelete(j.src)
        } else {
            CapsSaveFallback(j)
        }
        Log(Format("CAPS {} done ok={} {} {}x{} clip={} | grab {:.0f} ms, save {:.0f} ms, clip {:.0f} ms, encode {:.0f} ms, press-to-file {:.0f} ms"
            , j.mode, ok ? 1 : 0, j.how, j.w, j.h, j.clip ? 1 : 0
            , j.tGrab - j.tPress, j.tSave - j.tGrab, j.tClip - j.tSave, now - j.tEnc, now - j.tPress))
        if (ok)
            Tip(DBG ? "saved " j.webp : "webpcap saved (" Round((now - j.tPress) / 1000, 1) " s)", DBG ? 0 : 1500)
        else
            Tip("ffmpeg encode failed - saved PNG instead (see webpcap.log)", 4000)
    }
    if (!EncJobs.Count)
        SetTimer(EncodePoll, 0)
}

; Encode failed / timed out / no ffmpeg: never lose the shot. Write it as PNG
; next to where the WebP would have gone (in-process GDI+, ~100 ms). If even
; that fails, the temp image stays in %TEMP% and its path is logged.
CapsSaveFallback(j) {
    if (j.HasOwnProp("tmp") && j.tmp != "")
        try FileDelete(j.tmp)
    png := RegExReplace(j.webp, "\.webp$", "") ".png"
    if (GdipConvertFile(j.src, png, "png")) {
        try FileDelete(j.src)
        Log("CAPS " j.mode " fallback PNG saved: " png)
        return true
    }
    Log("CAPS " j.mode " fallback PNG FAILED - temp image kept: " j.src)
    return false
}

; --- Safe-to-post shot (2026-09-30c) ---
; Visible taskbar rects (screen coords) for every monitor: main Shell_TrayWnd plus each
; Shell_SecondaryTrayWnd. Auto-hide: a hidden bar sits (almost) off-screen, so only the
; sliver that is on screen gets clipped in BlurTaskbars; a shown bar is blurred fully.
TaskbarRects() {
    rects := []
    for cls in ["Shell_TrayWnd", "Shell_SecondaryTrayWnd"] {
        try list := WinGetList("ahk_class " cls)
        catch
            continue
        for hwnd in list {
            if (!DllCall("IsWindowVisible", "ptr", hwnd))
                continue
            rc := Buffer(16, 0)
            if (!DllCall("GetWindowRect", "ptr", hwnd, "ptr", rc))
                continue
            l := NumGet(rc, 0, "int"), t := NumGet(rc, 4, "int"), r := NumGet(rc, 8, "int"), b := NumGet(rc, 12, "int")
            if (r - l >= 2 && b - t >= 2)
                rects.Push({l: l, t: t, r: r, b: b, cls: cls})
        }
    }
    return rects
}

; Pixelate each taskbar rect inside hbm (hbm covers screen x,y,w,h). Block size
; SAFE_BLOCK_PX (default 32 px, > a 48 px bar's text and icon size) so the clock, tray,
; weather and pinned icons collapse into a few averaged colour blocks. Returns count.
BlurTaskbars(hbm, x, y, w, h, rects) {
    global SAFE_BLOCK_PX
    n := 0, desc := ""
    hdcS := DllCall("GetDC", "ptr", 0, "ptr")
    hdcM := DllCall("CreateCompatibleDC", "ptr", hdcS, "ptr")
    old := DllCall("SelectObject", "ptr", hdcM, "ptr", hbm, "ptr")
    for rc in rects {
        ; taskbar not on the captured monitor at all: leave it (padding alone must not
        ; reach into the shot from a neighbouring monitor's taskbar)
        if (rc.r <= x || rc.l >= x + w || rc.b <= y || rc.t >= y + h)
            continue
        ; pad 2 px (rounded corners / shadow), then clip to the captured area
        l := Max(rc.l - 2, x), t := Max(rc.t - 2, y), r := Min(rc.r + 2, x + w), b := Min(rc.b + 2, y + h)
        rw := r - l, rh := b - t
        if (rw < 1 || rh < 1)
            continue
        if (PixelateDc(hdcS, hdcM, l - x, t - y, rw, rh, SAFE_BLOCK_PX))
            n++
        desc .= Format(" {}[{},{} {}x{}]", rc.cls = "Shell_TrayWnd" ? "main" : "2nd", l, t, rw, rh)
    }
    DllCall("SelectObject", "ptr", hdcM, "ptr", old)
    DllCall("DeleteDC", "ptr", hdcM)
    DllCall("ReleaseDC", "ptr", 0, "ptr", hdcS)
    Log("CAPS safe: pixelated " n "/" rects.Length " taskbar rect(s) block=" SAFE_BLOCK_PX desc)
    return n
}

; Average-down (HALFTONE) to 1 px per block, then stretch back: block mosaic.
; The small buffer is a 32-bpp DIB so its alpha can be forced to 255: GDI stretch
; writes alpha 0, which made the taskbar band TRANSPARENT in the WebP (seen in test).
PixelateDc(hdcS, hdcM, rx, ry, rw, rh, blk) {
    sw := Max(1, Ceil(rw / blk)), sh := Max(1, Ceil(rh / blk))
    hdcT := DllCall("CreateCompatibleDC", "ptr", hdcS, "ptr")
    bi := Buffer(40, 0)
    NumPut("uint", 40, "int", sw, "int", -sh, "ushort", 1, "ushort", 32, bi)
    pBits := 0
    hbT := DllCall("CreateDIBSection", "ptr", hdcS, "ptr", bi, "uint", 0, "ptr*", &pBits, "ptr", 0, "uint", 0, "ptr")
    if (!hdcT || !hbT) {
        if (hbT)
            DllCall("DeleteObject", "ptr", hbT)
        if (hdcT)
            DllCall("DeleteDC", "ptr", hdcT)
        return false
    }
    oT := DllCall("SelectObject", "ptr", hdcT, "ptr", hbT, "ptr")
    DllCall("SetStretchBltMode", "ptr", hdcT, "int", 4)         ; HALFTONE = area average
    DllCall("SetBrushOrgEx", "ptr", hdcT, "int", 0, "int", 0, "ptr", 0)
    ok1 := DllCall("StretchBlt", "ptr", hdcT, "int", 0, "int", 0, "int", sw, "int", sh
        , "ptr", hdcM, "int", rx, "int", ry, "int", rw, "int", rh, "uint", 0x00CC0020)
    DllCall("GdiFlush")
    Loop sw * sh
        NumPut("uchar", 255, pBits, (A_Index - 1) * 4 + 3)
    DllCall("SetStretchBltMode", "ptr", hdcM, "int", 3)         ; COLORONCOLOR = hard blocks
    ok2 := DllCall("StretchBlt", "ptr", hdcM, "int", rx, "int", ry, "int", rw, "int", rh
        , "ptr", hdcT, "int", 0, "int", 0, "int", sw, "int", sh, "uint", 0x00CC0020)
    DllCall("SelectObject", "ptr", hdcT, "ptr", oT)
    DllCall("DeleteObject", "ptr", hbT)
    DllCall("DeleteDC", "ptr", hdcT)
    return ok1 && ok2
}

CapsFeedbackSound() {
    global CAP_SOUND
    if (!CAP_SOUND)
        return
    wav := A_WinDir "\Media\Windows Navigation Start.wav"
    try SoundPlay(FileExist(wav) ? wav : "*-1")
}

; --- REC API ---
VidToggle(mode) {
    global VIDPORT, SelectingRegion
    static busy := false
    if (busy)
        return
    if (SelectingRegion && mode != "region")
        return

    busy := true
    try {
        Log("REC toggle " mode)
        st := HttpGet("http://127.0.0.1:" VIDPORT "/health")
        if (st = "") {
            ; Self-heal once before failing the REC hotkey
            if (EnsureHostAlive(true)) {
                st := HttpGet("http://127.0.0.1:" VIDPORT "/health")
            }
            if (st = "") {
                global HostHealthy
                HostHealthy := false
                TrayRefreshStatus()
                return Tip("video-host offline - run .\build.ps1", 4000)
            }
            global HostHealthy
            HostHealthy := true
            TrayRefreshStatus()
        }
        if (InStr(st, '"displayRecording":true') || InStr(st, '"displayRecording": true')) {
            return VidStop()
        }

        if (mode = "display") {
            HideScreenFlash()
            ; Cursor's monitor; the host uses it when [capture] rec_screen=mouse (default)
            mq := ""
            mon := MonitorUnderMouse()
            if (mon) {
                MonitorGet(mon, &mL, &mT, &mR, &mB)
                mq := "?mon=" mL "," mT "," (mR - mL) "," (mB - mT)
            }
            RecStartTone()
            body := HttpPost("http://127.0.0.1:" VIDPORT "/display/toggle" mq, 35000)
            return VidTipFromBody(body, "display")
        }
        if (mode = "window") {
            ; Visible frame (not WinGetPos shadow offsets — those were -8,-8 and broke gdigrab)
            if (!GetActiveVisibleRect(&wx, &wy, &ww, &wh))
                return Tip("could not read active window bounds", 3000)
            if (ww < 16 || wh < 16)
                return Tip("window too small to REC", 2500)
            ww := ww - (ww & 1), wh := wh - (wh & 1)
            url := "http://127.0.0.1:" VIDPORT "/window/toggle?x=" wx "&y=" wy "&w=" ww "&h=" wh
            RecStartTone()
            body := HttpPost(url, 35000)
            return VidTipFromBody(body, "window")
        }
        if (mode = "region") {
            return VidRegionStart()
        }
    } finally {
        busy := false
    }
}

VidRegionStart() {
    global VIDPORT, SelectingRegion
    if (SelectingRegion)
        return
    SelectingRegion := true
    Tip("region REC VIDEO: drag box  |  Esc cancel", 0)
    ok := SelectRegionInteractive(&x, &y, &w, &h, true)
    SelectingRegion := false
    HideRubber()
    HideTip()
    if (!ok) {
        Log("region REC cancelled by user")
        return Tip("region REC cancelled", 1500)
    }
    w := w - (w & 1), h := h - (h & 1)
    if (w < 16 || h < 16)
        return Tip("region too small", 2500)
    Tip("starting region REC...", 0)
    RecStartTone()
    url := "http://127.0.0.1:" VIDPORT "/region/toggle?x=" x "&y=" y "&w=" w "&h=" h
    Log("region REC post " x "," y " " w "x" h)
    ; Long timeout: host warms gdigrab before answering (orphan cleanup + frame check)
    body := HttpPost(url, 40000)
    Log("region REC response: " (body = "" ? "(empty)" : SubStr(body, 1, 180)))
    return VidTipFromBody(body, "region")
}

VidStop() {
    global VIDPORT, DBG, VIDDIR
    ; Stop can take several seconds (ffmpeg finalize + A/V mux). Old 8s timeout
    ; aborted mid-stop → host restart → zombie ffmpeg → next region REC failed.
    ; 2026-10-02: 180 s - a REC whose capture restarted mid-way may need its segments re-encoded
    body := HttpPost("http://127.0.0.1:" VIDPORT "/rec/stop", 180000)
    if (body = "") {
        Log("video-host not reachable on port " VIDPORT " during stop — retry once")
        Sleep 800
        body := HttpPost("http://127.0.0.1:" VIDPORT "/rec/stop", 180000)
    }
    if (body = "") {
        Log("video-host not reachable on port " VIDPORT)
        RecIndicatorStop()
        RecSound("fail")
        return Tip("video-host offline - run .\build.ps1", 4000)
    }
    if (InStr(body, '"stopped":false') || InStr(body, '"stopped": false')) {
        RecIndicatorStop()  ; clear stuck red dot if host already idle
        if (InStr(body, "nothing_recording"))
            return Tip("nothing recording (REC never started — need Enter after rubber-band)", 2800)
        return Tip("stop: nothing active", 1200)
    }
    ok := InStr(body, '"ok":true') || InStr(body, '"ok": true')
    RecIndicatorStop()
    RecSound(ok ? "stop" : "fail")
    if (ok)
        Tip(DBG ? "REC saved -> " VIDDIR : "REC saved (video+audio .mp4)", DBG ? 0 : 2500)
    else
        Tip("REC stop failed - see webpcap-video.log", 4000)
}

VidTipFromBody(body, mode) {
    global DBG, VIDDIR, VIDPORT
    if (body = "") {
        Log("video-host not reachable on port " VIDPORT)
        RecIndicatorStop()
        RecSound("fail")
        return Tip("video-host offline - run .\build.ps1", 4000)
    }
    rec := InStr(body, '"recording":true') || InStr(body, '"recording": true')
    ok := InStr(body, '"ok":true') || InStr(body, '"ok": true')
    if (rec) {
        ; All video REC modes share the same red indicator
        label := mode = "display" ? "full display" : mode = "window" ? "window" : "region"
        if (mode = "display" && RegExMatch(body, '"screen":\s*"?(\d+)', &ms))
            label .= " (screen " ms[1] ")"
        RecIndicatorStart(label)
        ; (start tone already played in full before the capture began - see RecStartTone)
        Tip(label " REC on (+audio)  |  End to stop", 2500)
        return
    }
    RecIndicatorStop()
    RecSound(ok ? "stop" : "fail")
    if (ok)
        Tip(DBG ? "REC saved -> " VIDDIR : "REC saved (video+audio .mp4)", DBG ? 0 : 2500)
    else if (InStr(body, "hung") || InStr(body, "no video frames"))
        Tip("REC failed: capture hung - try again (End if stuck)", 4500)
    else if (InStr(body, "ffmpeg exited") || InStr(body, "bad crop") || InStr(body, "grab failed"))
        Tip("REC failed: bad window crop - try region REC or borderless window", 4500)
    else {
        Log("REC fail body: " SubStr(body, 1, 240))
        Tip("REC failed - see webpcap-video.log", 4000)
    }
}

; --- REC indicator: on-screen red blink (above taskbar, tray corner) + tray icon ---
; Blink uses opacity (not Hide) so a stuck "hidden" phase can't make the dot vanish forever.
TrayRestoreIdle() {
    global DBG, RecBlinking, RecBlinkShow, SHOW_TRAY, IcoRecOff, HostHealthy
    try SetTimer(RecBlinkTick, 0)
    RecBlinking := false
    RecBlinkShow := true
    HideRecDot()
    ; Visible tray when idle (default) — proof daemon is up without Task Manager
    if (SHOW_TRAY || DBG)
        A_IconHidden := false
    else
        A_IconHidden := true
    if (FileExist(IcoRecOff)) {
        try TraySetIcon(IcoRecOff)
    } else if (DBG) {
        try TraySetIcon("imageres.dll", 67)
    } else {
        try TraySetIcon("imageres.dll", 67)  ; camera-ish shell icon fallback
    }
    TrayRefreshStatus()
}

RecIndicatorStart(modeLabel := "REC") {
    global RecBlinking, RecBlinkShow, IcoRecOn
    ; Always re-arm (do not early-return) — stuck RecBlinking used to skip show forever
    try SetTimer(RecBlinkTick, 0)
    RecBlinking := true
    RecBlinkShow := true
    A_IconHidden := false
    A_IconTip := "webpcap " modeLabel " REC — End to stop"
    if (FileExist(IcoRecOn)) {
        try TraySetIcon(IcoRecOn)
    } else {
        try TraySetIcon("imageres.dll", 100)
    }
    ShowRecDot(true)
    SetTimer(RecBlinkTick, 500)
    global RecStartTick, RecPollMiss
    RecStartTick := A_TickCount, RecPollMiss := 0
    SetTimer(RecStatePoll, 2000)
    Log("REC indicator on (" modeLabel ")")
}

RecIndicatorStop() {
    global RecBlinking
    try SetTimer(RecBlinkTick, 0)
    try SetTimer(RecStatePoll, 0)
    RecBlinking := false
    HideRecDot()
    TrayRestoreIdle()
    Log("REC indicator off")
}

; REC sounds (async SoundPlay - never blocks the hotkey thread). kind: start | stop | fail
; assets\rec-*.wav: start = rising two-tone, stop/saved = falling two-tone, fail = low buzz.
RecSound(kind) {
    global REC_SOUNDS, RecBlinking
    if (!REC_SOUNDS)
        return
    ; Never while the indicator says a REC is live (the tone would land in the clip).
    ; Every stop/fail caller turns the indicator off only after the host has stopped.
    if (RecBlinking)
        return Log("REC sound '" kind "' skipped: REC still live")
    wav := A_ScriptDir "\assets\rec-" kind ".wav"
    try SoundPlay(FileExist(wav) ? wav : (kind = "fail" ? "*16" : "*64"))
}

; Start tone: play it to the end (SoundPlay Wait) + REC_TONE_GAP_MS so the audio engine has
; drained before the host starts the loopback capture. Costs ~0.5 s of REC start latency.
RecStartTone() {
    global REC_SOUNDS, REC_TONE_GAP_MS
    if (!REC_SOUNDS)
        return
    wav := A_ScriptDir "\assets\rec-start.wav"
    try SoundPlay(FileExist(wav) ? wav : "*64", 1)
    if (REC_TONE_GAP_MS > 0)
        Sleep REC_TONE_GAP_MS
}

; While REC is on: ask the host every 2 s. If its capture died and could not be
; restarted, the host auto-saves the partial clip; drop the red light and say why.
; No answer (host busy restarting a segment / finishing a stop) is not a verdict.
RecStatePoll() {
    global RecBlinking, VIDPORT, RecStartTick, RecPollMiss
    if (!RecBlinking) {
        try SetTimer(RecStatePoll, 0)
        return
    }
    st := HttpGet("http://127.0.0.1:" VIDPORT "/health")
    if (st = "" || !RecBlinking)
        return
    if (InStr(st, '"displayRecording":true')) {
        RecPollMiss := 0
        return
    }
    ago := RegExMatch(st, '"recEndAgoMs":(\d+)', &m) ? Integer(m[1]) : -1
    if (InStr(st, '"recEndReason":"capture_lost"') && ago >= 0 && ago <= A_TickCount - RecStartTick) {
        path := RegExMatch(st, '"recEndPath":"([^"]*)"', &mp) ? StrReplace(mp[1], "\\", "\") : ""
        Log("REC ended by host: capture lost  saved=" (InStr(st, '"recEndOk":true') ? 1 : 0) " " path)
        RecIndicatorStop()
        RecSound("fail")
        return Tip("REC ended: screen capture lost (display mode change)", 6000)
    }
    RecPollMiss += 1
    if (RecPollMiss >= 2) {
        Log("REC poll: host reports not recording - clearing indicator")
        RecIndicatorStop()
        RecSound("fail")
        Tip("REC ended - see webpcap-video.log", 4000)
    }
}

RecTrayBlinkStart(modeLabel := "REC") {
    RecIndicatorStart(modeLabel)
}
RecTrayBlinkStop() {
    RecIndicatorStop()
}

RecBlinkTick() {
    global RecBlinking, RecBlinkShow, IcoRecOn, IcoRecOff
    if (!RecBlinking)
        return
    RecBlinkShow := !RecBlinkShow
    ; Opacity blink — window stays mapped (never Hide on "off" phase)
    ShowRecDot(true, RecBlinkShow ? 255 : 70)
    if (RecBlinkShow) {
        A_IconHidden := false
        if (FileExist(IcoRecOn)) {
            try TraySetIcon(IcoRecOn)
        }
    } else if (FileExist(IcoRecOff)) {
        A_IconHidden := false
        try TraySetIcon(IcoRecOff)
    } else {
        A_IconHidden := true
    }
}

; Keep webpcap UI on-screen for the user, but omit from gdigrab / BitBlt / Desktop Duplication.
; WDA_EXCLUDEFROMCAPTURE = 0x11 (Windows 10 2004+). Fails silently on older OS.
; Used for: REC disc, CAPS/REC feedback tags (Tip), region rubber-band + size label.
ExcludeFromCapture(hwnd) {
    if (!hwnd)
        return
    static WDA_EXCLUDEFROMCAPTURE := 0x11
    try DllCall("user32\SetWindowDisplayAffinity", "ptr", hwnd, "uint", WDA_EXCLUDEFROMCAPTURE)
}
; Back-compat alias
ExcludeRecDotFromCapture(hwnd) {
    ExcludeFromCapture(hwnd)
}

EnsureRecDot() {
    global RecDotGui
    if (RecDotGui) {
        try {
            if (WinExist("ahk_id " RecDotGui.Hwnd)) {
                ExcludeRecDotFromCapture(RecDotGui.Hwnd)
                return
            }
        } catch {
        }
        try RecDotGui.Destroy()
        RecDotGui := 0
    }
    ; Click-through red disc, topmost — no +Owner (can orphan under wrong parent)
    g := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x20 +E0x08000000")
    g.BackColor := "FF1A1A"
    g.MarginX := 0
    g.MarginY := 0
    g.Show("x0 y0 w22 h22 NoActivate Hide")
    hwnd := g.Hwnd
    hRgn := DllCall("CreateEllipticRgn", "int", 0, "int", 0, "int", 22, "int", 22, "ptr")
    if (hRgn)
        DllCall("SetWindowRgn", "ptr", hwnd, "ptr", hRgn, "int", 1)
    try WinSetTransparent(255, g)
    try WinSetAlwaysOnTop(true, g)
    ExcludeRecDotFromCapture(hwnd)
    RecDotGui := g
}

; visible=true shows; alpha 0-255. When visible=false, hide completely (stop only).
; Position: ON the primary taskbar, just left of the overflow chevron (^).
; Measured on 2560-wide primary: ^ ~180px from right; R-118 sat on wifi/clock (too far right).
ShowRecDot(visible := true, alpha := 255) {
    global RecDotGui
    EnsureRecDot()
    if (!visible) {
        try RecDotGui.Hide()
        return
    }
    mon := MonitorGetPrimary()
    MonitorGet(mon, &L, &T, &R, &B)
    MonitorGetWorkArea(mon, &wL, &wT, &wR, &wB)
    ; Taskbar band height (bottom bar). Fallback if auto-hide / odd layout.
    tbH := B - wB
    if (tbH < 28)
        tbH := 48
    if (tbH > 80)
        tbH := 48
    dot := 22
    ; Just left of ^ (hidden-icons chevron). 22px disc + small gap before chevron.
    ; Tweak RecDotFromRight if tray icon count / DPI moves the chevron.
    recDotFromRight := 228
    x := R - recDotFromRight
    y := B - tbH + ((tbH - dot) // 2)
    if (x < L)
        x := L + 4
    if (y < T)
        y := B - dot - 4
    try {
        RecDotGui.Show("x" x " y" y " w" dot " h" dot " NoActivate")
        try WinSetAlwaysOnTop(true, RecDotGui)
        ExcludeRecDotFromCapture(RecDotGui.Hwnd)
        a := alpha < 40 ? 40 : (alpha > 255 ? 255 : alpha)
        try WinSetTransparent(a, RecDotGui)
    } catch as e {
        Log("ShowRecDot fail: " e.Message)
        RecDotGui := 0
        EnsureRecDot()
        try {
            RecDotGui.Show("x" x " y" y " w" dot " h" dot " NoActivate")
            ExcludeRecDotFromCapture(RecDotGui.Hwnd)
            try WinSetTransparent(255, RecDotGui)
        } catch {
        }
    }
}

HideRecDot() {
    global RecDotGui
    if (RecDotGui) {
        try RecDotGui.Hide()
    }
}

HttpGet(url) {
    try {
        http := ComObject("WinHttp.WinHttpRequest.5.1")
        http.Open("GET", url, false)
        http.SetTimeouts(500, 500, 2000, 2000)
        http.Send()
        if (http.Status < 200 || http.Status >= 300)
            return ""
        return http.ResponseText
    } catch {
        return ""
    }
}

; receiveMs: default 8s for light posts; REC start/stop need 25–60s (warmup + mux).
HttpPost(url, receiveMs := 8000) {
    try {
        http := ComObject("WinHttp.WinHttpRequest.5.1")
        http.Open("POST", url, false)
        ; resolve, connect, send, receive (ms)
        recv := receiveMs > 1000 ? receiveMs : 8000
        http.SetTimeouts(2000, 2000, 15000, recv)
        http.Send()
        if (http.Status < 200 || http.Status >= 300) {
            Log("HTTP " http.Status " " url)
            return ""
        }
        return http.ResponseText
    } catch as e {
        Log("HttpPost " url " " e.Message)
        return ""
    }
}

; Full-screen still bounds per [capture] screen. Whole monitor rect (taskbar included, never
; the work area). Returns a short label for the log: "mouse:N", "primary:N" or "all".
CapScreenRect(&x, &y, &w, &h) {
    global CAP_SCREEN
    if (CAP_SCREEN != "all") {
        try {
            mon := MonitorGetPrimary()
            how := "primary"
            if (CAP_SCREEN = "mouse") {
                m := MonitorUnderMouse()
                if (m)
                    mon := m, how := "mouse"
            }
            MonitorGet(mon, &L, &T, &R, &B)
            if (R - L >= 2 && B - T >= 2) {
                x := L, y := T, w := R - L, h := B - T
                return how ":" mon
            }
        }
    }
    x := SysGet(76), y := SysGet(77), w := SysGet(78), h := SysGet(79)
    return "all"
}

; Monitor index under the cursor, 0 if the cursor is on no monitor.
MonitorUnderMouse() {
    pt := Buffer(8, 0)
    if !DllCall("GetCursorPos", "ptr", pt)
        return 0
    return MonitorAt(NumGet(pt, 0, "int"), NumGet(pt, 4, "int"))
}

; Monitor index the rect overlaps most, 0 if none.
MonitorMostOverlap(x, y, w, h) {
    best := 0, bestA := 0
    Loop MonitorGetCount() {
        MonitorGet(A_Index, &L, &T, &R, &B)
        ow := Min(x + w, R) - Max(x, L), oh := Min(y + h, B) - Max(y, T)
        if (ow > 0 && oh > 0 && ow * oh > bestA)
            best := A_Index, bestA := ow * oh
    }
    return best
}

; Monitor index containing the point, 0 if none.
MonitorAt(px, py) {
    Loop MonitorGetCount() {
        MonitorGet(A_Index, &L, &T, &R, &B)
        if (px >= L && px < R && py >= T && py < B)
            return A_Index
    }
    return 0
}

; Windows display number ("2" for \\.\DISPLAY2) of an AHK monitor index; falls back to the index.
MonitorDisplayNumber(mon) {
    try {
        if RegExMatch(MonitorGetName(mon), "DISPLAY(\d+)$", &m)
            return m[1]
    }
    return mon
}

; "Screen N" for ~0.7 s centred on the captured monitor. Called only AFTER the grab; excluded
; from screen capture (WDA_EXCLUDEFROMCAPTURE) and never shown while a REC is running.
ShowScreenFlash(scr, x, y, w, h) {
    global CAP_FLASH, FlashGui, RecBlinking
    if (!CAP_FLASH || RecBlinking || !RegExMatch(scr, ":(\d+)$", &m))
        return
    HideScreenFlash()
    label := "Screen " MonitorDisplayNumber(Integer(m[1]))
    try {
        ; NOACTIVATE + TRANSPARENT (click-through); ToolWindow keeps it off the taskbar / Alt+Tab
        g := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x08000020")
        g.BackColor := "1E1E1E"
        g.MarginX := 0, g.MarginY := 0
        g.SetFont("s40 bold cFFFFFF", "Segoe UI")
        g.AddText("x0 y28 w360 h80 Center", label)
        g.Show("x" x " y" y " w360 h136 NoActivate Hide")
        ExcludeFromCapture(g.Hwnd)          ; before it is ever visible
        fx := x + (w - 360) // 2, fy := y + (h - 136) // 2
        g.Show("x" fx " y" fy " w360 h136 NoActivate")
        WinSetTransparent(210, g)
        FlashGui := g
        SetTimer(HideScreenFlash, -700)
    }
}

HideScreenFlash(settle := false) {
    global FlashGui
    if (!FlashGui)
        return
    try SetTimer(HideScreenFlash, 0)
    try FlashGui.Destroy()
    FlashGui := 0
    if (settle)
        Sleep 30    ; let DWM drop it before a new grab (it is capture-excluded anyway)
}

RunCapture(mode, png, x := 0, y := 0, w := 0, h := 0) {
    global PSHELL, CAP_GRAB_TIMEOUT_MS
    cap := A_ScriptDir "\capture.ps1"
    if (!FileExist(cap)) {
        Log("missing capture.ps1")
        return false
    }
    args := '-STA -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' cap '" -Mode ' mode ' -OutPath "' png '"'
    if (mode = "region")
        args .= " -X " x " -Y " y " -W " w " -H " h
    target := PSHELL " " args
    exitCode := RunWaitTimeout(target, CAP_GRAB_TIMEOUT_MS)
    if (exitCode != 0)
        Log("capture.ps1 exit " exitCode)
    if (!FileExist(png)) {
        Log("capture file missing: " png " (exit " exitCode ")")
        return false
    }
    return true
}

CapFull(png) {
    return RunCapture("full", png)
}

CapRegion(png) {
    global SelectingRegion
    SelectingRegion := true
    Tip("region CAP: drag box  |  Esc cancel", 0)
    ok := SelectRegionInteractive(&x, &y, &w, &h)
    SelectingRegion := false
    HideRubber()
    HideTip()
    if (!ok)
        return false
    if (w < 2 || h < 2)
        return false
    return RunCapture("region", png, x, y, w, h)
}

CapActive(png) {
    return RunCapture("active", png)
}

; Visible client+chrome bounds (DWM extended frame). Avoids Win11 shadow (-8,-8) that breaks gdigrab.
GetActiveVisibleRect(&x, &y, &w, &h) {
    hwnd := WinExist("A")
    if (!hwnd)
        return false
    rect := Buffer(16, 0)
    ; DWMWA_EXTENDED_FRAME_BOUNDS = 9
    hr := DllCall("dwmapi\DwmGetWindowAttribute", "ptr", hwnd, "uint", 9, "ptr", rect, "uint", 16, "int")
    if (hr != 0) {
        WinGetPos &x, &y, &w, &h, "A"
    } else {
        x := NumGet(rect, 0, "int")
        y := NumGet(rect, 4, "int")
        r := NumGet(rect, 8, "int")
        b := NumGet(rect, 12, "int")
        w := r - x
        h := b - y
    }
    ; Clamp to virtual screen (gdigrab rejects negative offsets)
    vsX := SysGet(76), vsY := SysGet(77), vsW := SysGet(78), vsH := SysGet(79)
    vsR := vsX + vsW, vsB := vsY + vsH
    if (x < vsX) {
        w -= (vsX - x), x := vsX
    }
    if (y < vsY) {
        h -= (vsY - y), y := vsY
    }
    if (x + w > vsR)
        w := vsR - x
    if (y + h > vsB)
        h := vsB - y
    if (w < 2 || h < 2)
        return false
    return true
}

; --- Rubber-band + fine-tune region picker ---
; 1) LMB drag frame (live cyan border)
; 2) Mouse-up -> fine-tune: drag edges/corners/move, Enter=OK, Esc=cancel
; Full-screen PickShield blocks mouse from apps below (no text highlight / drag-select).
SelectRegionInteractive(&x, &y, &w, &h, forRec := false) {
    x1 := 0, y1 := 0, started := false
    ShowPickShield()
    EnsureRubber()
    conf := forRec ? "Enter=START REC" : "Enter=OK"

    ; Phase 1: drag
    Loop {
        if (GetKeyState("Escape", "P")) {
            HideRubber()
            return false
        }
        if (!started) {
            if (GetKeyState("LButton", "P")) {
                MouseGetPos &x1, &y1
                started := true
                Tip("drag... release to fine-tune", 0)
            }
            Sleep 15
            continue
        }
        MouseGetPos &x2, &y2
        rx := Min(x1, x2), ry := Min(y1, y2), rw := Abs(x2 - x1), rh := Abs(y2 - y1)
        ShowRubber(rx, ry, rw, rh)
        Tip("region " rw "x" rh "  release = fine-tune  Esc = cancel", 0)
        if (!GetKeyState("LButton", "P")) {
            if (rw < 4 || rh < 4) {
                HideRubber()
                return false
            }
            x := rx, y := ry, w := rw, h := rh
            break
        }
        Sleep 15
    }

    ; Phase 2: fine-tune — Enter starts capture / REC (drag alone does not record yet)
    Tip("fine-tune: drag edges  |  " conf "  Esc=cancel", 0)
    grip := ""
    gx0 := 0, gy0 := 0, bx := x, by := y, bw := w, bh := h
    Loop {
        if (GetKeyState("Escape", "P")) {
            HideRubber()
            return false
        }
        ; Main Enter or Numpad Enter
        if (GetKeyState("Enter", "P") || GetKeyState("NumpadEnter", "P")) {
            if (GetKeyState("Enter", "P"))
                KeyWait "Enter"
            if (GetKeyState("NumpadEnter", "P"))
                KeyWait "NumpadEnter"
            if (w >= 2 && h >= 2) {
                HideRubber()
                return true
            }
        }

        MouseGetPos &mx, &my
        ShowRubber(x, y, w, h)
        zone := HitZone(mx, my, x, y, w, h)

        if (grip = "") {
            if (GetKeyState("LButton", "P") && zone != "") {
                grip := zone
                gx0 := mx, gy0 := my
                bx := x, by := y, bw := w, bh := h
            }
        } else {
            if (!GetKeyState("LButton", "P")) {
                grip := ""
            } else {
                dx := mx - gx0, dy := my - gy0
                ApplyGrip(grip, bx, by, bw, bh, dx, dy, &x, &y, &w, &h)
                ShowRubber(x, y, w, h)
            }
        }

        hint := zone != "" ? zone : "·"
        Tip("fine-tune " w "x" h "  [" hint "]  " conf "  Esc=cancel", 0)
        Sleep 15
    }
}

HitZone(mx, my, x, y, w, h) {
    m := 10
    inX := (mx >= x - m && mx <= x + w + m)
    inY := (my >= y - m && my <= y + h + m)
    if (!inX || !inY)
        return ""
    nearL := (mx <= x + m)
    nearR := (mx >= x + w - m)
    nearT := (my <= y + m)
    nearB := (my >= y + h - m)
    if (nearT && nearL)
        return "nw"
    if (nearT && nearR)
        return "ne"
    if (nearB && nearL)
        return "sw"
    if (nearB && nearR)
        return "se"
    if (nearT)
        return "n"
    if (nearB)
        return "s"
    if (nearL)
        return "w"
    if (nearR)
        return "e"
    if (mx > x + m && mx < x + w - m && my > y + m && my < y + h - m)
        return "move"
    return ""
}

ApplyGrip(grip, bx, by, bw, bh, dx, dy, &x, &y, &w, &h) {
    x := bx, y := by, w := bw, h := bh
    switch grip {
        case "move":
            x := bx + dx, y := by + dy
        case "n":
            y := by + dy, h := bh - dy
        case "s":
            h := bh + dy
        case "w":
            x := bx + dx, w := bw - dx
        case "e":
            w := bw + dx
        case "nw":
            x := bx + dx, y := by + dy, w := bw - dx, h := bh - dy
        case "ne":
            y := by + dy, w := bw + dx, h := bh - dy
        case "sw":
            x := bx + dx, w := bw - dx, h := bh + dy
        case "se":
            w := bw + dx, h := bh + dy
    }
    ; normalize if inverted
    if (w < 0) {
        x += w, w := -w
    }
    if (h < 0) {
        y += h, h := -h
    }
    if (w < 2)
        w := 2
    if (h < 2)
        h := 2
}

; Full virtual-desktop overlay: receives mouse (no WS_EX_TRANSPARENT) so drag does not
; select text / highlight words in the app underneath. Hidden before CAPS/REC capture.
EnsurePickShield() {
    global PickShield
    if (PickShield)
        return
    ; +E0x08000000 = WS_EX_NOACTIVATE — eat clicks without stealing keyboard focus
    g := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x08000000")
    g.BackColor := "000000"
    g.Show("x0 y0 w1 h1 NoActivate Hide")
    PickShield := g
}

ShowPickShield() {
    global PickShield
    EnsurePickShield()
    vsL := SysGet(76)   ; SM_XVIRTUALSCREEN
    vsT := SysGet(77)   ; SM_YVIRTUALSCREEN
    vsW := SysGet(78)   ; SM_CXVIRTUALSCREEN
    vsH := SysGet(79)   ; SM_CYVIRTUALSCREEN
    if (vsW < 2)
        vsW := A_ScreenWidth
    if (vsH < 2)
        vsH := A_ScreenHeight
    try {
        PickShield.Show("x" vsL " y" vsT " w" vsW " h" vsH " NoActivate")
        WinSetAlwaysOnTop(true, PickShield)
        ; Light dim (still readable). Opacity 0 would skip hit-testing on some builds.
        WinSetTransparent(55, PickShield)
        ExcludeFromCapture(PickShield.Hwnd)  ; dimmer is for you only
    }
}

HidePickShield() {
    global PickShield
    if (PickShield) {
        try PickShield.Hide()
    }
}

EnsureRubber() {
    global RbTop, RbBot, RbLeft, RbRight, RbLabel
    if (RbTop)
        return
    mk(*) {
        ; E0x20 = click-through borders; PickShield underneath receives the drag
        g := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x20 +Owner")
        g.BackColor := "00D4FF"
        g.Show("x0 y0 w1 h1 NoActivate Hide")
        WinSetTransparent(200, g)
        ExcludeFromCapture(g.Hwnd)  ; pick chrome: you see it; captures do not
        return g
    }
    RbTop := mk(), RbBot := mk(), RbLeft := mk(), RbRight := mk()
    RbLabel := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x20 +Owner")
    RbLabel.BackColor := "101820"
    RbLabel.SetFont("s9 c00D4FF", "Segoe UI")
    global RbLabelTxt := RbLabel.Add("Text", "c00D4FF", "0x0")
    RbLabel.Show("x0 y0 w80 h18 NoActivate Hide")
    WinSetTransparent(220, RbLabel)
    ExcludeFromCapture(RbLabel.Hwnd)
}

ShowRubber(x, y, w, h) {
    global RbTop, RbBot, RbLeft, RbRight, RbLabel, RbLabelTxt
    EnsureRubber()
    if (w < 1)
        w := 1
    if (h < 1)
        h := 1
    t := 3
    try {
        RbTop.Show("x" x " y" y " w" w " h" t " NoActivate")
        RbBot.Show("x" x " y" (y + h - t) " w" w " h" t " NoActivate")
        RbLeft.Show("x" x " y" y " w" t " h" h " NoActivate")
        RbRight.Show("x" (x + w - t) " y" y " w" t " h" h " NoActivate")
        RbLabelTxt.Value := w "x" h
        ly := y - 22
        if (ly < 0)
            ly := y + h + 4
        RbLabel.Show("x" x " y" ly " w80 h18 NoActivate")
        ; re-apply affinity after show (some builds drop it)
        for g in [RbTop, RbBot, RbLeft, RbRight, RbLabel]
            if (g)
                ExcludeFromCapture(g.Hwnd)
    }
}

HideRubber() {
    global RbTop, RbBot, RbLeft, RbRight, RbLabel
    for g in [RbTop, RbBot, RbLeft, RbRight, RbLabel] {
        if (g) {
            try g.Hide()
        }
    }
    HidePickShield()
}

; Run hidden and wait at most timeoutMs. Returns 0 when the process exited,
; -1 launch failure, -2 timeout (process killed). Exit code is not tracked.
RunWaitTimeout(target, timeoutMs) {
    pid := 0
    try {
        Run(target, , "Hide", &pid)
    } catch as e {
        Log("run failed: " e.Message)
        return -1
    }
    t0 := A_TickCount
    while ProcessExist(pid) {
        if (A_TickCount - t0 > timeoutMs) {
            try ProcessClose(pid)
            Log("run timeout " timeoutMs " ms: " SubStr(target, 1, 120))
            return -2
        }
        Sleep 50
    }
    return 0
}

QpcMs() {
    static f := 0
    if (!f)
        DllCall("QueryPerformanceFrequency", "int64*", &f)
    c := 0
    DllCall("QueryPerformanceCounter", "int64*", &c)
    return c * 1000.0 / f
}

GdipEnsure() {
    static tok := 0
    if (tok)
        return true
    if (!DllCall("GetModuleHandle", "str", "gdiplus", "ptr"))
        DllCall("LoadLibrary", "str", "gdiplus", "ptr")
    si := Buffer(A_PtrSize = 8 ? 24 : 16, 0)
    NumPut("uint", 1, si)
    r := DllCall("gdiplus\GdiplusStartup", "ptr*", &tok, "ptr", si, "ptr", 0, "int")
    if (r != 0) {
        Log("GdiplusStartup failed " r)
        tok := 0
        return false
    }
    return true
}

; Screen rect -> HBITMAP (caller owns). Same source as CopyFromScreen (BitBlt SRCCOPY);
; capture-excluded webpcap UI (tags, rubber-band, REC disc) stays out of the image.
GdiCaptureRect(x, y, w, h) {
    if (w < 1 || h < 1)
        return 0
    hdcS := DllCall("GetDC", "ptr", 0, "ptr")
    if (!hdcS)
        return 0
    hdcM := DllCall("CreateCompatibleDC", "ptr", hdcS, "ptr")
    hbm := DllCall("CreateCompatibleBitmap", "ptr", hdcS, "int", w, "int", h, "ptr")
    ok := false
    if (hdcM && hbm) {
        old := DllCall("SelectObject", "ptr", hdcM, "ptr", hbm, "ptr")
        ok := DllCall("BitBlt", "ptr", hdcM, "int", 0, "int", 0, "int", w, "int", h
            , "ptr", hdcS, "int", x, "int", y, "uint", 0x00CC0020)
        DllCall("SelectObject", "ptr", hdcM, "ptr", old)
    }
    if (hdcM)
        DllCall("DeleteDC", "ptr", hdcM)
    DllCall("ReleaseDC", "ptr", 0, "ptr", hdcS)
    if (!ok) {
        if (hbm)
            DllCall("DeleteObject", "ptr", hbm)
        Log("GdiCaptureRect failed " x "," y " " w "x" h)
        return 0
    }
    return hbm
}

; fmt: "bmp" (fast temp for ffmpeg) or "png"
GdipSaveHBitmap(hbm, path, fmt := "bmp") {
    if (!GdipEnsure())
        return false
    pBmp := 0
    if (DllCall("gdiplus\GdipCreateBitmapFromHBITMAP", "ptr", hbm, "ptr", 0, "ptr*", &pBmp, "int") != 0)
        return false
    clsid := Buffer(16, 0)
    DllCall("ole32\CLSIDFromString", "wstr", fmt = "png"
        ? "{557CF406-1A04-11D3-9A73-0000F81EF32E}"
        : "{557CF400-1A04-11D3-9A73-0000F81EF32E}", "ptr", clsid)
    r := DllCall("gdiplus\GdipSaveImageToFile", "ptr", pBmp, "wstr", path, "ptr", clsid, "ptr", 0, "int")
    DllCall("gdiplus\GdipDisposeImage", "ptr", pBmp)
    return r = 0
}

; CF_BITMAP in-process (Windows synthesizes CF_DIB / CF_DIBV5). On success the
; clipboard owns hbm - do not delete it. Retries briefly if another app holds it.
ClipSetHBitmap(hbm) {
    opened := false
    Loop 10 {
        if (DllCall("OpenClipboard", "ptr", A_ScriptHwnd)) {
            opened := true
            break
        }
        Sleep 15
    }
    if (!opened) {
        Log("clipboard busy - image not copied")
        return false
    }
    DllCall("EmptyClipboard")
    r := DllCall("SetClipboardData", "uint", 2, "ptr", hbm, "ptr")
    DllCall("CloseClipboard")
    return r != 0
}

; Re-save an image file (BMP/PNG) in another format via GDI+.
GdipConvertFile(src, dst, fmt := "png") {
    if (!GdipEnsure() || !FileExist(src))
        return false
    pBmp := 0
    if (DllCall("gdiplus\GdipCreateBitmapFromFile", "wstr", src, "ptr*", &pBmp, "int") != 0)
        return false
    clsid := Buffer(16, 0)
    DllCall("ole32\CLSIDFromString", "wstr", fmt = "png"
        ? "{557CF406-1A04-11D3-9A73-0000F81EF32E}"
        : "{557CF400-1A04-11D3-9A73-0000F81EF32E}", "ptr", clsid)
    r := DllCall("gdiplus\GdipSaveImageToFile", "ptr", pBmp, "wstr", dst, "ptr", clsid, "ptr", 0, "int")
    DllCall("gdiplus\GdipDisposeImage", "ptr", pBmp)
    if (r != 0)
        try FileDelete(dst)
    return r = 0
}

ClipSetFromFile(path) {
    if (!GdipEnsure())
        return false
    pBmp := 0, hbm := 0
    if (DllCall("gdiplus\GdipCreateBitmapFromFile", "wstr", path, "ptr*", &pBmp, "int") != 0)
        return false
    DllCall("gdiplus\GdipCreateHBITMAPFromBitmap", "ptr", pBmp, "ptr*", &hbm, "uint", 0xFFFFFFFF, "int")
    DllCall("gdiplus\GdipDisposeImage", "ptr", pBmp)
    if (!hbm)
        return false
    ok := ClipSetHBitmap(hbm)
    if (!ok)
        DllCall("DeleteObject", "ptr", hbm)
    return ok
}

Log(msg) {
    global DBG
    line := FormatTime(, "yyyy-MM-dd HH:mm:ss") " " msg "`n"
    try FileAppend line, A_Temp "\webpcap.log", "UTF-8-RAW"
    if (DBG)
        Tip("[dbg] " msg, 0)
}

; --- Private feedback tags (CAPS / REC shortcuts) ---
; Visible only to the signed-in user; excluded from stills + REC MP4 via WDA_EXCLUDEFROMCAPTURE.
EnsureTipGui() {
    global TipGui, TipTxt
    if (TipGui) {
        try {
            if (WinExist("ahk_id " TipGui.Hwnd)) {
                ExcludeFromCapture(TipGui.Hwnd)
                return
            }
        } catch {
        }
        try TipGui.Destroy()
        TipGui := 0
        TipTxt := 0
    }
    g := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x20")
    g.BackColor := "0D1520"
    g.MarginX := 12
    g.MarginY := 10
    g.SetFont("s10 cE8F4FF", "Segoe UI")
    TipTxt := g.Add("Text", "w400 h36 cE8F4FF Wrap", "")
    g.Show("x0 y0 w424 h56 NoActivate Hide")
    try WinSetTransparent(235, g)
    try WinSetAlwaysOnTop(true, g)
    ExcludeFromCapture(g.Hwnd)
    TipGui := g
}

HideTip(*) {
    global TipGui
    try SetTimer(HideTip, 0)
    if (TipGui) {
        try TipGui.Hide()
    }
}

; timeout > 0: auto-hide ms; timeout = 0 + non-empty msg: sticky until next Tip/HideTip; msg "": hide
Tip(msg, timeout := 0) {
    global TipGui, TipTxt
    if (msg = "") {
        HideTip()
        return
    }
    EnsureTipGui()
    TipTxt.Value := msg
    mon := MonitorGetPrimary()
    MonitorGetWorkArea(mon, &L, &T, &R, &B)
    w := 424
    h := 56
    x := L + ((R - L - w) // 2)
    y := B - h - 52
    if (y < T)
        y := T + 8
    try {
        TipGui.Show("x" x " y" y " w" w " h" h " NoActivate")
        try WinSetAlwaysOnTop(true, TipGui)
        ExcludeFromCapture(TipGui.Hwnd)
    } catch as e {
        Log("Tip show fail: " e.Message)
    }
    try SetTimer(HideTip, 0)
    if (timeout > 0)
        SetTimer(HideTip, -timeout)
}
