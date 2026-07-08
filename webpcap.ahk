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
    FFMPEG := IniRead(ini, "paths", "ffmpeg", "E:\Code-Y\engine - ffmpeg\ffmpeg.exe")
    OUT := IniRead(ini, "paths", "outdir", EnvGet("USERPROFILE") "\Pictures\Screenshots\WebP")
    if InStr(OUT, "%")
        OUT := RegExReplace(OUT, "%(\w+)%", (m) => EnvGet(m[1]))
    Q := IniRead(ini, "encode", "quality", 90)
    LOSSLESS := IniRead(ini, "encode", "lossless", 0)
    REMAP := IniRead(ini, "hotkeys", "remap", 1)
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

CapFull(png) {
    ps := 'Add-Type -A System.Windows.Forms,System.Drawing;'
    . '$r=[Drawing.Rectangle]::Empty;[Windows.Forms.Screen]::AllScreens|%{$r=if($r.IsEmpty){$_.Bounds}else{[Drawing.Rectangle]::Union($r,$_.Bounds)}};'
    . '$b=New-Object Drawing.Bitmap $r.Width,$r.Height;$g=[Drawing.Graphics]::FromImage($b);'
    . '$g.CopyFromScreen($r.Location,[Drawing.Point]::Empty,$r.Size);$b.Save(''' png ''',[Drawing.Imaging.ImageFormat]::Png);$g.Dispose();$b.Dispose()'
    return RunWait('powershell.exe -NoProfile -WindowStyle Hidden -Command "' ps '"', , "Hide") = 0
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
    ps := 'Add-Type -A System.Windows.Forms,System.Drawing;$b=New-Object Drawing.Bitmap ' w ',' h ';'
    . '$g=[Drawing.Graphics]::FromImage($b);$g.CopyFromScreen(' x ',' y ',[Drawing.Point]::Empty,[Drawing.Size]::new(' w ',' h '));'
    . '$b.Save(''' png ''',[Drawing.Imaging.ImageFormat]::Png);$g.Dispose();$b.Dispose()'
    return RunWait('powershell.exe -NoProfile -WindowStyle Hidden -Command "' ps '"', , "Hide") = 0
}

CapActive(png) {
    ps := 'Add-Type -A System.Windows.Forms,System.Drawing;'
    . '$h=(Add-Type -M user32.dll -P ''[DllImport("user32.dll")]public static extern IntPtr GetForegroundWindow();'
    . '[DllImport("user32.dll")]public static extern bool GetWindowRect(IntPtr h,out RECT r);'
    . 'public struct RECT{public int L,T,R,B;}'' -PassThru)::GetForegroundWindow();'
    . '$r=New-Object RECT;$null=[user32]::GetWindowRect($h,[ref]$r);'
    . '$w=$r.R-$r.L;$h=$r.B-$r.T;$b=New-Object Drawing.Bitmap $w,$h;'
    . '$g=[Drawing.Graphics]::FromImage($b);$g.CopyFromScreen($r.L,$r.T,[Drawing.Point]::Empty,[Drawing.Size]::new($w,$h));'
    . '$b.Save(''' png ''',[Drawing.Imaging.ImageFormat]::Png);$g.Dispose();$b.Dispose()'
    return RunWait('powershell.exe -NoProfile -WindowStyle Hidden -Command "' ps '"', , "Hide") = 0
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
    ps := 'Add-Type -A System.Windows.Forms,System.Drawing;'
    . '$i=[Drawing.Image]::FromFile(''' webp ''');[Windows.Forms.Clipboard]::SetImage($i);$i.Dispose()'
    RunWait('powershell.exe -NoProfile -WindowStyle Hidden -Command "' ps '"', , "Hide")
}

Tip(msg) {
    global DBG
    if (DBG)
        ToolTip msg, , , 1
}