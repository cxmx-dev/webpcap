#Requires AutoHotkey v2.0
#SingleInstance Force
; webpcap v0.1 — zero-UI screenshot → WebP hotkey daemon

global FFMPEG := "", OUT := "", Q := 90, LOSSLESS := 0, REMAP := 1, DBG := false
for a in A_Args
    if (a = "--debug")
        DBG := true

LoadIni()
DirCreate(OUT)
if (REMAP) {
    Hotkey "PrintScreen", (*) => Go("full"), "On"
    Hotkey "#PrintScreen", (*) => Go("full"), "On"
    Hotkey "#+s", (*) => Go("region"), "On"
    Hotkey "#+r", (*) => Go("active"), "On"
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
}

ExpandEnvPath(p) {
    Loop {
        if !RegExMatch(p, "%(\w+)%", &m)
            return p
        p := StrReplace(p, m[0], EnvGet(m[1]), , 1)
    }
}

Go(mode) {
    global OUT, DBG
    ts := FormatTime(, "yyyyMMdd_HHmmss")
    png := A_Temp "\webpcap_" ts ".png"
    webp := OUT "\Screenshot_" ts ".webp"
    ok := mode = "full" ? CapFull(png) : mode = "region" ? CapRegion(png) : CapActive(png)
    if (!ok)
        return Tip("capture cancelled")
    if (!ToWebP(png, webp))
        return Tip("ffmpeg failed")
    FileDelete(png)
    ClipImg(webp)
    if (DBG)
        Tip("saved " webp)
}

RunPs1(script) {
    ps1 := A_Temp "\webpcap_run_" A_TickCount ".ps1"
    try {
        FileDelete ps1
        FileAppend script, ps1, "UTF-8"
        return RunWait('powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' ps1 '"', , "Hide") = 0
    } finally {
        if FileExist(ps1)
            FileDelete ps1
    }
}

CapFull(png) {
    script := "
    (
    Add-Type -AssemblyName System.Windows.Forms,System.Drawing
    `$r = [Drawing.Rectangle]::Empty
    foreach (`$s in [Windows.Forms.Screen]::AllScreens) {
        if (`$r.IsEmpty) { `$r = `$s.Bounds } else { `$r = [Drawing.Rectangle]::Union(`$r, `$s.Bounds) }
    }
    `$b = New-Object Drawing.Bitmap `$r.Width, `$r.Height
    `$g = [Drawing.Graphics]::FromImage(`$b)
    `$g.CopyFromScreen(`$r.Location, [Drawing.Point]::Empty, `$r.Size)
    `$b.Save('" png "', [Drawing.Imaging.ImageFormat]::Png)
    `$g.Dispose(); `$b.Dispose()
    )"
    return RunPs1(script)
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
    script := "
    (
    Add-Type -AssemblyName System.Windows.Forms,System.Drawing
    `$b = New-Object Drawing.Bitmap " w ", " h "
    `$g = [Drawing.Graphics]::FromImage(`$b)
    `$g.CopyFromScreen(" x ", " y ", [Drawing.Point]::Empty, [Drawing.Size]::new(" w ", " h "))
    `$b.Save('" png "', [Drawing.Imaging.ImageFormat]::Png)
    `$g.Dispose(); `$b.Dispose()
    )"
    return RunPs1(script)
}

CapActive(png) {
    script := "
    (
    Add-Type -AssemblyName System.Windows.Forms,System.Drawing
    `$code = @'
    using System;
    using System.Runtime.InteropServices;
    public class Win32 {
        [DllImport(""user32.dll"")] public static extern IntPtr GetForegroundWindow();
        [DllImport(""user32.dll"")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
        public struct RECT { public int L, T, R, B; }
    }
    '@
    Add-Type -TypeDefinition `$code
    `$h = [Win32]::GetForegroundWindow()
    `$r = New-Object Win32+RECT
    [void][Win32]::GetWindowRect(`$h, [ref]`$r)
    `$w = `$r.R - `$r.L; `$h = `$r.B - `$r.T
    `$b = New-Object Drawing.Bitmap `$w, `$h
    `$g = [Drawing.Graphics]::FromImage(`$b)
    `$g.CopyFromScreen(`$r.L, `$r.T, [Drawing.Point]::Empty, [Drawing.Size]::new(`$w, `$h))
    `$b.Save('" png "', [Drawing.Imaging.ImageFormat]::Png)
    `$g.Dispose(); `$b.Dispose()
    )"
    return RunPs1(script)
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
    if (LOSSLESS)
        args := '-y -i "' png '" -c:v libwebp -lossless 1 "' webp '"'
    else
        args := '-y -i "' png '" -c:v libwebp -q:v ' Q ' "' webp '"'
    return RunWait('"' FFMPEG '" ' args, , "Hide") = 0
}

ClipImg(webp) {
    script := "
    (
    Add-Type -AssemblyName System.Windows.Forms,System.Drawing
    `$i = [Drawing.Image]::FromFile('" webp "')
    [Windows.Forms.Clipboard]::SetImage(`$i)
    `$i.Dispose()
    )"
    RunPs1(script)
}

Tip(msg) {
    global DBG
    if (DBG)
        ToolTip msg, , , 1
}