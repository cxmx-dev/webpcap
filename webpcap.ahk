#Requires AutoHotkey v2.0
#SingleInstance Force
#UseHook
; webpcap — WebP stills + MP4 REC (full / window / region) + system audio
; Rubber-band region + fine-tune; End stops any REC

global FFMPEG := "", OUT := "", Q := 90, LOSSLESS := 0, REMAP := 1, DBG := false
global VIDPORT := 19787, VIDDIR := ""
global PSHELL := A_WinDir "\System32\WindowsPowerShell\v1.0\powershell.exe"
global SelectingRegion := false
global RbTop := 0, RbBot := 0, RbLeft := 0, RbRight := 0
global RbLabel := 0

CoordMode "Mouse", "Screen"
CoordMode "ToolTip", "Screen"

testMode := ""
for i, a in A_Args {
    if (a = "--debug")
        DBG := true
    else if (a = "--test" && A_Args.Has(i + 1))
        testMode := A_Args[i + 1]
}

LoadIni()
DirCreate(OUT)
if (VIDDIR)
    DirCreate(VIDDIR)

if (testMode) {
    Go(testMode)
    ExitApp(0)
}

#InputLevel 1
if (REMAP) {
    ; --- CAPS (stills) ---
    Hotkey "$PrintScreen", (*) => Go("full"), "On"
    Hotkey "$SC137", (*) => Go("full"), "On"
    Hotkey "$!PrintScreen", (*) => CapHotkeyActive(), "On"
    Hotkey "$!SC137", (*) => CapHotkeyActive(), "On"
    Hotkey "$^PrintScreen", (*) => CapHotkeyRegion(), "On"
    Hotkey "$^SC137", (*) => CapHotkeyRegion(), "On"

    ; --- REC ---
    ; Ctrl+Shift+PrtSc = full display
    Hotkey "$^+PrintScreen", (*) => VidToggle("display"), "On"
    Hotkey "$^+SC137", (*) => VidToggle("display"), "On"
    ; Ctrl+Win+PrtSc = active window (NOT Win+Alt+PrtSc = Game Bar screenshot)
    Hotkey "$^#PrintScreen", (*) => VidToggle("window"), "On"
    Hotkey "$^#SC137", (*) => VidToggle("window"), "On"
    ; Ctrl+Alt+PrtSc = region REC
    Hotkey "$^!PrintScreen", (*) => VidToggle("region"), "On"
    Hotkey "$^!SC137", (*) => VidToggle("region"), "On"

    Hotkey "End", (*) => VidStop(), "On"
}
if (DBG)
    TraySetIcon("imageres.dll", 67)
Persistent

LoadIni() {
    global FFMPEG, OUT, Q, LOSSLESS, REMAP, VIDPORT, VIDDIR
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
    if (!FileExist(FFMPEG))
        Tip("ffmpeg not found - edit webpcap.ini", 4000)
}

ExpandEnvPath(p) {
    Loop {
        if !RegExMatch(p, "%(\w+)%", &m)
            return p
        p := StrReplace(p, m[0], EnvGet(m[1]))
    }
}

CapHotkeyActive() {
    if (GetKeyState("Shift", "P") || GetKeyState("Control", "P") || GetKeyState("LWin", "P") || GetKeyState("RWin", "P"))
        return
    Go("active")
}

CapHotkeyRegion() {
    ; leave Ctrl+Shift / Ctrl+Alt / Ctrl+Win to REC
    if (GetKeyState("Shift", "P") || GetKeyState("Alt", "P") || GetKeyState("LWin", "P") || GetKeyState("RWin", "P"))
        return
    Go("region")
}

Go(mode) {
    global OUT, DBG, FFMPEG, SelectingRegion
    if (SelectingRegion)
        return
    ts := FormatTime(, "yyyyMMdd_HHmmss") "_" A_TickCount
    png := A_Temp "\webpcap_" ts ".png"
    webp := OUT "\Screenshot_" ts ".webp"
    ok := mode = "full" ? CapFull(png) : mode = "region" ? CapRegion(png) : CapActive(png)
    if (!ok || !FileExist(png))
        return Tip("capture failed - see " A_Temp "\webpcap.log", 4000)
    if (!FileExist(FFMPEG))
        return Tip("ffmpeg not found - edit webpcap.ini", 4000)
    if (!ToWebP(png, webp))
        return Tip("ffmpeg encode failed - see webpcap.log", 4000)
    ClipImgPng(png)
    FileDelete(png)
    Tip(DBG ? "saved " webp : "webpcap saved", DBG ? 0 : 1500)
}

; --- REC API ---
VidToggle(mode) {
    global VIDPORT, SelectingRegion
    if (SelectingRegion && mode != "region")
        return

    st := HttpGet("http://127.0.0.1:" VIDPORT "/health")
    if (st != "" && (InStr(st, '"displayRecording":true') || InStr(st, '"displayRecording": true'))) {
        return VidStop()
    }

    if (mode = "display") {
        body := HttpPost("http://127.0.0.1:" VIDPORT "/display/toggle")
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
        body := HttpPost(url)
        return VidTipFromBody(body, "window")
    }
    if (mode = "region") {
        return VidRegionStart()
    }
}

VidRegionStart() {
    global VIDPORT, SelectingRegion
    if (SelectingRegion)
        return
    SelectingRegion := true
    Tip("region REC: drag box  |  Esc cancel", 0)
    ok := SelectRegionInteractive(&x, &y, &w, &h)
    SelectingRegion := false
    HideRubber()
    ToolTip
    if (!ok)
        return Tip("region REC cancelled", 1500)
    w := w - (w & 1), h := h - (h & 1)
    if (w < 16 || h < 16)
        return Tip("region too small", 2500)
    url := "http://127.0.0.1:" VIDPORT "/region/toggle?x=" x "&y=" y "&w=" w "&h=" h
    body := HttpPost(url)
    return VidTipFromBody(body, "region")
}

VidStop() {
    global VIDPORT, DBG, VIDDIR
    body := HttpPost("http://127.0.0.1:" VIDPORT "/rec/stop")
    if (body = "") {
        Log("video-host not reachable on port " VIDPORT)
        return Tip("video-host offline - run .\build.ps1", 4000)
    }
    if (InStr(body, '"stopped":false') || InStr(body, '"stopped": false')) {
        if (InStr(body, "nothing_recording"))
            return Tip("nothing recording", 1200)
        return Tip("stop: nothing active", 1200)
    }
    ok := InStr(body, '"ok":true') || InStr(body, '"ok": true')
    if (ok)
        Tip(DBG ? "REC saved -> " VIDDIR : "REC saved (video+audio .mp4)", DBG ? 0 : 2500)
    else
        Tip("REC stop failed - see webpcap-video.log", 4000)
}

VidTipFromBody(body, mode) {
    global DBG, VIDDIR, VIDPORT
    if (body = "") {
        Log("video-host not reachable on port " VIDPORT)
        return Tip("video-host offline - run .\build.ps1", 4000)
    }
    rec := InStr(body, '"recording":true') || InStr(body, '"recording": true')
    ok := InStr(body, '"ok":true') || InStr(body, '"ok": true')
    if (rec) {
        label := mode = "display" ? "full display" : mode = "window" ? "window" : "region"
        Tip(label " REC (+audio)... End or same hotkey to stop", 0)
        return
    }
    if (ok)
        Tip(DBG ? "REC saved -> " VIDDIR : "REC saved (video+audio .mp4)", DBG ? 0 : 2500)
    else if (InStr(body, "ffmpeg exited") || InStr(body, "bad crop"))
        Tip("REC failed: bad window crop - try region REC or borderless window", 4500)
    else
        Tip("REC failed - see webpcap-video.log", 4000)
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

HttpPost(url) {
    try {
        http := ComObject("WinHttp.WinHttpRequest.5.1")
        http.Open("POST", url, false)
        http.SetTimeouts(1000, 1000, 8000, 8000)
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

RunCapture(mode, png, x := 0, y := 0, w := 0, h := 0) {
    global PSHELL
    cap := A_ScriptDir "\capture.ps1"
    if (!FileExist(cap)) {
        Log("missing capture.ps1")
        return false
    }
    args := '-STA -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' cap '" -Mode ' mode ' -OutPath "' png '"'
    if (mode = "region")
        args .= " -X " x " -Y " y " -W " w " -H " h
    target := PSHELL " " args
    exitCode := RunWait(target,, "Hide")
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
    ToolTip
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
SelectRegionInteractive(&x, &y, &w, &h) {
    x1 := 0, y1 := 0, started := false
    EnsureRubber()

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

    ; Phase 2: fine-tune
    Tip("fine-tune: drag edges/corners  |  Enter=OK  Esc=cancel", 0)
    grip := ""
    gx0 := 0, gy0 := 0, bx := x, by := y, bw := w, bh := h
    Loop {
        if (GetKeyState("Escape", "P")) {
            HideRubber()
            return false
        }
        if (GetKeyState("Enter", "P")) {
            KeyWait "Enter"
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
        Tip("fine-tune " w "x" h "  [" hint "]  Enter=OK  Esc=cancel", 0)
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

EnsureRubber() {
    global RbTop, RbBot, RbLeft, RbRight, RbLabel
    if (RbTop)
        return
    mk(*) {
        g := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x20 +Owner")
        g.BackColor := "00D4FF"
        g.Show("x0 y0 w1 h1 NoActivate Hide")
        WinSetTransparent(200, g)
        return g
    }
    RbTop := mk(), RbBot := mk(), RbLeft := mk(), RbRight := mk()
    RbLabel := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x20 +Owner")
    RbLabel.BackColor := "101820"
    RbLabel.SetFont("s9 c00D4FF", "Segoe UI")
    global RbLabelTxt := RbLabel.Add("Text", "c00D4FF", "0x0")
    RbLabel.Show("x0 y0 w80 h18 NoActivate Hide")
    WinSetTransparent(220, RbLabel)
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
    }
}

HideRubber() {
    global RbTop, RbBot, RbLeft, RbRight, RbLabel
    for g in [RbTop, RbBot, RbLeft, RbRight, RbLabel] {
        if (g) {
            try g.Hide()
        }
    }
}

ToWebP(png, webp) {
    global FFMPEG, Q, LOSSLESS
    args := (LOSSLESS
        ? '-hide_banner -loglevel error -y -i "' png '" -c:v libwebp -lossless 1 "' webp '"'
        : '-hide_banner -loglevel error -y -i "' png '" -c:v libwebp -q:v ' Q ' "' webp '"')
    target := '"' FFMPEG '" ' args
    exitCode := RunWait(target,, "Hide")
    if (exitCode != 0)
        Log("ffmpeg exit " exitCode)
    return exitCode = 0
}

ClipImgPng(png) {
    global PSHELL
    clip := A_ScriptDir "\clip.ps1"
    if (!FileExist(clip))
        return
    args := '-STA -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' clip '" -Path "' png '"'
    RunWait(PSHELL " " args,, "Hide")
}

Log(msg) {
    global DBG
    line := FormatTime(, "yyyy-MM-dd HH:mm:ss") " " msg "`n"
    try FileAppend line, A_Temp "\webpcap.log", "UTF-8-RAW"
    if (DBG)
        ToolTip msg, , , 2
}

Tip(msg, timeout := 0) {
    ToolTip msg, , , 1
    if (timeout > 0)
        SetTimer () => ToolTip(), -timeout
    else if (timeout = 0 && msg = "")
        ToolTip
}
