# 探测：截微信主窗口 -> OCR -> 打印所有文本行及其窗口内坐标
# 用途：在看不到屏幕的时候，用纯文本判断 UI 上有什么、按钮在哪
param(
    [string]$Match = '',
    [int]$MinY = 0
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Runtime.WindowsRuntime

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class W32Probe {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
"@

try { [W32Probe]::SetProcessDPIAware() | Out-Null } catch { }

$script:asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
})[0]

function Await($op, [Type]$resultType) {
    $asTask = $script:asTaskGeneric.MakeGenericMethod($resultType)
    $task = $asTask.Invoke($null, @($op))
    $task.Wait(-1) | Out-Null
    return $task.Result
}

$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Globalization.Language, Windows.Foundation, ContentType = WindowsRuntime]

function Get-WeChatHwnd {
    $p = Get-Process -Name Weixin -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if ($p) { return [IntPtr]$p.MainWindowHandle }
    return [IntPtr]::Zero
}

function Capture-Window([IntPtr]$hwnd) {
    $r = New-Object W32Probe+RECT
    [void][W32Probe]::GetWindowRect($hwnd, [ref]$r)
    $w = $r.Right - $r.Left
    $h = $r.Bottom - $r.Top
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size $w, $h))
    $g.Dispose()
    $path = Join-Path $env:TEMP 'probe_shot.png'
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    return [pscustomobject]@{ Path = $path; Left = $r.Left; Top = $r.Top; Width = $w; Height = $h }
}

function Invoke-Ocr([string]$path) {
    $file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($path)) ([Windows.Storage.StorageFile])
    $stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    $decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $sb = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
    $lang = New-Object Windows.Globalization.Language 'zh-Hans-CN'
    $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($lang)
    if (-not $engine) { throw 'OCR 引擎创建失败' }
    $res = Await ($engine.RecognizeAsync($sb)) ([Windows.Media.Ocr.OcrResult])
    $stream.Dispose()

    $lines = @()
    foreach ($ln in $res.Lines) {
        $minX = [double]::MaxValue; $minY = [double]::MaxValue
        $maxX = 0.0; $maxY = 0.0
        foreach ($wd in $ln.Words) {
            $rc = $wd.BoundingRect
            if ($rc.X -lt $minX) { $minX = $rc.X }
            if ($rc.Y -lt $minY) { $minY = $rc.Y }
            if (($rc.X + $rc.Width) -gt $maxX) { $maxX = $rc.X + $rc.Width }
            if (($rc.Y + $rc.Height) -gt $maxY) { $maxY = $rc.Y + $rc.Height }
        }
        if ($maxX -le 0) { continue }
        $lines += [pscustomobject]@{ Text = $ln.Text; X = $minX; Y = $minY; W = ($maxX - $minX); H = ($maxY - $minY) }
    }
    return $lines
}

$hwnd = Get-WeChatHwnd
if ($hwnd -eq [IntPtr]::Zero) { Write-Host 'NO-WECHAT-WINDOW'; exit 1 }
[void][W32Probe]::SetForegroundWindow($hwnd)
Start-Sleep -Milliseconds 400

$shot = Capture-Window $hwnd
Write-Host ("window {0},{1}  {2}x{3}" -f $shot.Left, $shot.Top, $shot.Width, $shot.Height)

$scale = 2.0
$src = [System.Drawing.Bitmap]::FromFile($shot.Path)
$big = New-Object System.Drawing.Bitmap ([int]($src.Width * $scale)), ([int]($src.Height * $scale))
$g = [System.Drawing.Graphics]::FromImage($big)
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$g.DrawImage($src, 0, 0, $big.Width, $big.Height)
$g.Dispose(); $src.Dispose()
$up = Join-Path $env:TEMP 'probe_shot_up.png'
$big.Save($up, [System.Drawing.Imaging.ImageFormat]::Png)
$big.Dispose()

$lines = Invoke-Ocr $up
Write-Host ("OCR lines: " + $lines.Count)
Write-Host '--- window-relative coords (x,y,w,h) ---'
foreach ($ln in $lines) {
    $y = [int]($ln.Y / $scale)
    if ($y -lt $MinY) { continue }
    if ($Match -and ($ln.Text -notlike "*$Match*")) { continue }
    Write-Host ("  [{0,4},{1,4}] {2,3}x{3,-3} {4}" -f [int]($ln.X / $scale), $y, [int]($ln.W / $scale), [int]($ln.H / $scale), $ln.Text)
}
