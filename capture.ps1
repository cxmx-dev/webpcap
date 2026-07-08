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
        $b = New-Object Drawing.Bitmap $W, $H
        $g = [Drawing.Graphics]::FromImage($b)
        $g.CopyFromScreen($X, $Y, [Drawing.Point]::Empty, [Drawing.Size]::new($W, $H))
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
        Add-Type -TypeDefinition $code
        $hwnd = [Win32]::GetForegroundWindow()
        $rect = New-Object Win32+RECT
        [void][Win32]::GetWindowRect($hwnd, [ref]$rect)
        $w = $rect.R - $rect.L; $ht = $rect.B - $rect.T
        $b = New-Object Drawing.Bitmap $w, $ht
        $g = [Drawing.Graphics]::FromImage($b)
        $g.CopyFromScreen($rect.L, $rect.T, [Drawing.Point]::Empty, [Drawing.Size]::new($w, $ht))
        $b.Save($OutPath, [Drawing.Imaging.ImageFormat]::Png)
        $g.Dispose(); $b.Dispose()
    }
}