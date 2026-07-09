param(
    [Parameter(Mandatory)][ValidateSet('full', 'region', 'active')][string]$Mode,
    [Parameter(Mandatory)][string]$OutPath,
    [int]$X = 0,
    [int]$Y = 0,
    [int]$W = 0,
    [int]$H = 0
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing

switch ($Mode) {
    'full' {
        $r = [Drawing.Rectangle]::Empty
        foreach ($s in [Windows.Forms.Screen]::AllScreens) {
            if ($r.IsEmpty) { $r = $s.Bounds } else { $r = [Drawing.Rectangle]::Union($r, $s.Bounds) }
        }
        $b = New-Object Drawing.Bitmap $r.Width, $r.Height
        $g = [Drawing.Graphics]::FromImage($b)
        $g.CopyFromScreen($r.Location, [Drawing.Point]::Empty, $r.Size)
        $b.Save($OutPath, [Drawing.Imaging.ImageFormat]::Png)
        $g.Dispose(); $b.Dispose()
    }
    'region' {
        if ($W -lt 1 -or $H -lt 1) { throw "region size invalid W=$W H=$H" }
        $b = New-Object Drawing.Bitmap $W, $H
        $g = [Drawing.Graphics]::FromImage($b)
        # int,int,int,int,Size — avoid Point/Size overload that PS misbinds to CopyPixelOperation
        $g.CopyFromScreen([int]$X, [int]$Y, 0, 0, (New-Object Drawing.Size $W, $H))
        $b.Save($OutPath, [Drawing.Imaging.ImageFormat]::Png)
        $g.Dispose(); $b.Dispose()
    }
    'active' {
        $code = @'
using System;
using System.Runtime.InteropServices;
public class Win32 {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    public struct RECT { public int L, T, R, B; }
}
'@
        if (-not ('Win32' -as [type])) { Add-Type -TypeDefinition $code }
        $hwnd = [Win32]::GetForegroundWindow()
        $rect = New-Object Win32+RECT
        [void][Win32]::GetWindowRect($hwnd, [ref]$rect)
        $w = [Math]::Max(1, $rect.R - $rect.L)
        $ht = [Math]::Max(1, $rect.B - $rect.T)
        $b = New-Object Drawing.Bitmap $w, $ht
        $g = [Drawing.Graphics]::FromImage($b)
        $g.CopyFromScreen([int]$rect.L, [int]$rect.T, 0, 0, (New-Object Drawing.Size $w, $ht))
        $b.Save($OutPath, [Drawing.Imaging.ImageFormat]::Png)
        $g.Dispose(); $b.Dispose()
    }
}