#Requires AutoHotkey v2.0
#SingleInstance Force
#UseHook
; webpcap v0.1 — zero-UI screenshot → WebP hotkey daemon

global FFMPEG := "", OUT := "", Q := 90, LOSSLESS := 0, REMAP := 1, DBG := false
global PSHELL := A_WinDir "\System32\WindowsPowerShell\v1.0\powershell.exe"

testMode := ""
for i, a in A_Args {
    if (a = "--debug")
        DBG := true
    else if (a = "--test" && A_Args.Has(i + 1))
        testMode := A_Args[i + 1]
}

LoadIni()
DirCreate(OUT)

if (testMode) {
    Go(testMode)
    ExitApp(0)
}

#InputLevel 1
if (REMAP) {
    Hotkey "$PrintScreen", (*) => Go("full"), "On"
    Hotkey "$#PrintScreen", (*) => Go("full"), "On"
    Hotkey "$SC137", (*) => Go("full"), "On"
    Hotkey "$#+s", (*) => Go("region"), "On"
    Hotkey "$#+r", (*) => Go("active"), "On"
}
if (DBG)
    TraySetIcon("imageres.dll", 67)
Persistent

LoadIni() {
    global FFMPEG, OUT, Q, LOSSLESS, REMAP
    ini := A_ScriptDir "\webpcap.ini"
    ex := A_ScriptDir "\webpcap.ini.example"
    if (!FileExist(ini) && FileExist(ex))
        FileCopy ex, ini
    FFMPEG := IniRead(ini, "paths", "ffmpeg", "ffmpeg.exe")
    OUT := ExpandEnvPath(IniRead(ini, "paths", "outdir", EnvGet("USERPROFILE") "\Pictures\Screenshots\WebP"))
    Q := IniRead(ini, "encode", "quality", 90)
    LOSSLESS := IniRead(ini, "encode", "lossless", 0)
    REMAP := IniRead(ini, "hotkeys", "remap", 1)
    if (!FileExist(FFMPEG))
        Tip("ffmpeg not found — edit webpcap.ini", 4000)
}

ExpandEnvPath(p) {
    Loop {
        if !RegExMatch(p, "%(\w+)%", &m)
            return p
        p := StrReplace(p, m[0], EnvGet(m[1]))
    }
}

Go(mode) {
    global OUT, DBG, FFMPEG
    ts := FormatTime(, "yyyyMMdd_HHmmss") "_" A_TickCount
    png := A_Temp "\webpcap_" ts ".png"
    webp := OUT "\Screenshot_" ts ".webp"
    ok := mode = "full" ? CapFull(png) : mode = "region" ? CapRegion(png) : CapActive(png)
    if (!ok || !FileExist(png))
        return Tip("capture failed — see %TEMP%\webpcap.log", 4000)
    if (!FileExist(FFMPEG))
        return Tip("ffmpeg not found — edit webpcap.ini", 4000)
    if (!ToWebP(png, webp))
        return Tip("ffmpeg encode failed — see webpcap.log", 4000)
    ClipImgPng(png)
    FileDelete(png)
    Tip(DBG ? "saved " webp : "webpcap saved", DBG ? 0 : 1500)
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
    ToolTip "webpcap: click top-left (Esc cancel)"
    if (!WaitClick(&x1, &y1))
        return (ToolTip(), false)
    ToolTip "webpcap: click bottom-right (Esc cancel)"
    if (!WaitClick(&x2, &y2))
        return (ToolTip(), false)
    ToolTip
    x := Min(x1, x2), y := Min(y1, y2), w := Abs(x2 - x1), h := Abs(y2 - y1)
    if (w < 2 || h < 2)
        return false
    return RunCapture("region", png, x, y, w, h)
}

CapActive(png) {
    return RunCapture("active", png)
}

WaitClick(&x, &y) {
    Loop {
        if (GetKeyState("Escape", "P"))
            return false
        if (GetKeyState("LButton", "P")) {
            MouseGetPos &x, &y
            KeyWait "LButton"
            return true
        }
        Sleep 30
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
}