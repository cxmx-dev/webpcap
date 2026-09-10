param([Parameter(Mandatory)][string]$Path)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
$i = [Drawing.Image]::FromFile($Path)
[Windows.Forms.Clipboard]::SetImage($i)
$i.Dispose()