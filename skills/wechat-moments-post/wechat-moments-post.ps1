# wechat-moments-post.ps1 — 发一条微信朋友圈（纯 Win32，无第三方依赖）
#
# 用法：
#   powershell -File wechat-moments-post.ps1 -Image "C:\path\pic.jpg" -Text "文案"
#   powershell -File wechat-moments-post.ps1 -Image ... -Text ... -DryRun
#
# 流程与手工操作一致：微信 → 发现 → 朋友圈 → 相机 → 选图 → 填文案 → 发表

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Image,
    [string]$Text = '',
    # 文案也可以从文件读。-- 为什么要这个：
    # runner.ps1 用 Start-Process -ArgumentList 传参，而它会把含空格的字符串
    # 拆成多个参数。文案里有 "Windows"、"AI" 这类词时，整段会被拆散，
    # 后面的词甚至会被当成下一个参数名（曾把 "Windows" 喂给 -WinWidth）。
    # 走文件就完全没有这个问题。
    [string]$TextFile = '',
    [switch]$DryRun,
    [switch]$NormalizeOnly,
    [switch]$NoPublish,
    [switch]$Quiet,
    # 归一化目标尺寸。默认 980x900 是实测最稳的一档；换机器/换分辨率时如果这一档
    # 在该屏幕工作区里显得别扭，可以用这两个参数改。超过工作区会自动缩到工作区大小。
    [int]$WinWidth = 980,
    [int]$WinHeight = 900
)

$ErrorActionPreference = 'Stop'

# -TextFile 优先：从文件读 UTF-8 文案，避免命令行分词问题。
if ($TextFile) {
    if (-not (Test-Path -LiteralPath $TextFile)) { throw "TextFile not found: $TextFile" }
    $Text = [System.IO.File]::ReadAllText($TextFile, [System.Text.Encoding]::UTF8)
    $Text = $Text.TrimEnd("`r", "`n")
}

# Write stdout as UTF-8. Without this Windows PowerShell encodes it with the OEM
# code page (936), so Chinese log lines turn into mojibake for the caller.
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class W32 {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int hh, bool repaint);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);
    [DllImport("user32.dll")] public static extern IntPtr OpenClipboard(IntPtr h);
    [DllImport("user32.dll")] public static extern bool CloseClipboard();
    [DllImport("user32.dll")] public static extern bool EmptyClipboard();
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SetClipboardData(uint fmt, IntPtr mem);
    [DllImport("kernel32.dll")] public static extern IntPtr GlobalAlloc(uint f, UIntPtr n);
    [DllImport("kernel32.dll")] public static extern IntPtr GlobalLock(IntPtr h);
    [DllImport("kernel32.dll")] public static extern bool GlobalUnlock(IntPtr h);
    [DllImport("kernel32.dll")] public static extern IntPtr GlobalFree(IntPtr h);
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
}
"@

# ---------- 基础工具 ----------

function Sleep-Ms([int]$ms) { Start-Sleep -Milliseconds $ms }

function Get-Windows {
    $list = New-Object System.Collections.ArrayList
    $cb = [W32+EnumProc] {
        param($h, $p)
        if (-not [W32]::IsWindowVisible($h)) { return $true }
        $sb = New-Object System.Text.StringBuilder 512
        [void][W32]::GetWindowTextW($h, $sb, 512)
        $title = $sb.ToString()
        if ([string]::IsNullOrWhiteSpace($title)) { return $true }

        $cb2 = New-Object System.Text.StringBuilder 256
        [void][W32]::GetClassNameW($h, $cb2, 256)

        $r = New-Object W32+RECT
        if (-not [W32]::GetWindowRect($h, [ref]$r)) { return $true }
        $w = $r.R - $r.L; $hh = $r.B - $r.T
        if ($w -le 1 -or $hh -le 1) { return $true }

        [void]$list.Add([pscustomobject]@{
            Handle = $h; Title = $title; Class = $cb2.ToString()
            Left = $r.L; Top = $r.T; Width = $w; Height = $hh
            Right = $r.R; Bottom = $r.B
        })
        return $true
    }
    [void][W32]::EnumWindows($cb, [IntPtr]::Zero)
    return $list
}

function Find-Win {
    param(
        [string]$Title,
        [string]$Class,
        [int]$TimeoutSec = 8,
        # 标题和 class 都相同的窗口可能同时存在好几个 —— 最坑的是「发布草稿框」标题也叫
        # 「朋友圈」、class 同样是 Qt51514QWindowIcon，但只有 410x528 左右。
        # 找朋友圈画布时必须按宽度把它排除，否则上次失败留下的草稿会被当成画布，
        # 之后每一步坐标全错（这是实测踩出来的）。
        [int]$MinWidth = 0,
        [int]$MaxWidth = 0
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        $hit = Get-Windows | Where-Object {
            $_.Title -eq $Title -and
            (-not $Class -or $_.Class -like "*$Class*") -and
            ($MinWidth -le 0 -or $_.Width -ge $MinWidth) -and
            ($MaxWidth -le 0 -or $_.Width -le $MaxWidth)
        } | Select-Object -First 1
        if ($hit) { return $hit }
        Sleep-Ms 250
    } while ((Get-Date) -lt $deadline)
    return $null
}

# 置前台并**验证**。
# 只用 SetForegroundWindow 是不够的：Windows 有前台锁（foreground lock），
# 当调用方不是当前前台进程时它会被静默忽略，函数照样返回，但窗口根本没上来 ——
# 于是后续 Click-At 的坐标全落到压在微信上面的那个窗口里（实测点进了 DSH 的设置面板）。
# 这里用 AttachThreadInput 绕过前台锁，并回读 GetForegroundWindow 确认，失败就重试。
function Activate-Win($w) {
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        if ([W32]::GetForegroundWindow() -eq $w.Handle) { Sleep-Ms 200; return $true }
        [void][W32]::ShowWindow($w.Handle, 9)   # SW_RESTORE
        [void][W32]::BringWindowToTop($w.Handle)
        # 把当前前台的输入队列挂到自己线程上，才能突破前台锁
        $fg = [W32]::GetForegroundWindow()
        $tidFg = 0
        $tidSelf = [W32]::GetCurrentThreadId()
        if ($fg -ne [IntPtr]::Zero) {
            $fgPid = 0
            $tidFg = [W32]::GetWindowThreadProcessId($fg, [ref]$fgPid)
        }
        $attached = $false
        if ($tidFg -ne 0 -and $tidFg -ne $tidSelf) {
            $attached = [W32]::AttachThreadInput($tidFg, $tidSelf, $true)
        }
        [void][W32]::SetForegroundWindow($w.Handle)
        [void][W32]::BringWindowToTop($w.Handle)
        if ($attached) { [void][W32]::AttachThreadInput($tidFg, $tidSelf, $false) }
        Sleep-Ms 350
        if ([W32]::GetForegroundWindow() -eq $w.Handle) { Sleep-Ms 200; return $true }
    }
    return ([W32]::GetForegroundWindow() -eq $w.Handle)
}

function Click-At([int]$x, [int]$y, [int]$WaitMs = 800) {
    [void][W32]::SetCursorPos($x, $y)
    Sleep-Ms 60
    [W32]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)  # LEFTDOWN
    Sleep-Ms 40
    [W32]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)  # LEFTUP
    Sleep-Ms $WaitMs
}

function Set-ClipboardText([string]$s) {
    $h = [W32]::OpenClipboard([IntPtr]::Zero)
    if ($h -eq [IntPtr]::Zero) { throw "打开剪贴板失败" }
    try {
        [void][W32]::EmptyClipboard()
        $bytes = [System.Text.Encoding]::Unicode.GetBytes($s + [char]0)
        $mem = [W32]::GlobalAlloc(0x0042, [UIntPtr]([uint64]$bytes.Length))  # GMEM_MOVEABLE|ZEROINIT
        $ptr = [W32]::GlobalLock($mem)
        [System.Runtime.InteropServices.Marshal]::Copy($bytes, 0, $ptr, $bytes.Length)
        [void][W32]::GlobalUnlock($mem)
        [void][W32]::SetClipboardData(13, $mem)  # CF_UNICODETEXT
    } finally {
        [void][W32]::CloseClipboard()
    }
}

function Paste-Text([string]$s, [int]$WaitMs = 800) {
    Set-ClipboardText $s
    Sleep-Ms 150
    # Ctrl+V
    [W32]::keybd_event(0x11, 0, 0, [IntPtr]::Zero)      # Ctrl down
    [W32]::keybd_event(0x56, 0, 0, [IntPtr]::Zero)      # V down
    [W32]::keybd_event(0x56, 0, 2, [IntPtr]::Zero)      # V up
    [W32]::keybd_event(0x11, 0, 2, [IntPtr]::Zero)      # Ctrl up
    Sleep-Ms $WaitMs
}

function Send-Key([int]$vk, [int]$WaitMs = 600) {
    [W32]::keybd_event([byte]$vk, 0, 0, [IntPtr]::Zero)
    [W32]::keybd_event([byte]$vk, 0, 2, [IntPtr]::Zero)
    Sleep-Ms $WaitMs
}

# 标题栏右侧三个白色图标（刷新 / 铃铛 / 相机）在不同窗口宽度下偏移量并不固定：
# 实测 591 宽时相机在 Right-47，980 宽时在 Right-18 —— 证明「距右边缘固定 px」是错的。
# 这里改为按像素扫描标题栏，找出「深色底上的白色图标簇」，从右往左数第三个就是相机。
#
# 注意：不能只按「白色像素」找。内嵌模式下窗口标题栏本身是浅色的，整行都会命中白色
# （实测 433 列全命中，一次扫描直接失败）。必须先挑出**深色行**（暗像素占比高），
# 再在这些行里统计白色列。
function Find-TitleBarIcons($win) {
    $x0 = [int]($win.Left + $win.Width * 0.55)
    $x1 = [int]($win.Right - 4)
    $y0 = [int]($win.Top + 18)
    $y1 = [int]($win.Top + 100)
    if ($x1 -le $x0 -or $y1 -le $y0) { return $null }
    $w = $x1 - $x0 + 1
    $h = $y1 - $y0 + 1
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try { $g.CopyFromScreen($x0, $y0, 0, 0, (New-Object System.Drawing.Size $w, $h)) }
    catch { $g.Dispose(); $bmp.Dispose(); return $null }
    $g.Dispose()

    # 1) 找深色行（真正属于朋友圈深色标题栏的那些行）
    $darkRow = New-Object 'bool[]' $h
    for ($y = 0; $y -lt $h; $y++) {
        $dark = 0; $tot = 0
        for ($x = 0; $x -lt $w; $x += 6) {
            $c = $bmp.GetPixel($x, $y)
            $tot++
            if ($c.R -lt 115 -and $c.G -lt 115 -and $c.B -lt 135) { $dark++ }
        }
        $darkRow[$y] = ($tot -gt 0 -and ($dark / [double]$tot) -ge 0.5)
    }

    # 2) 只在深色行里统计「白色」列
    $colHit = New-Object 'int[]' $w
    for ($x = 0; $x -lt $w; $x++) {
        $n = 0
        for ($y = 0; $y -lt $h; $y++) {
            if (-not $darkRow[$y]) { continue }
            $c = $bmp.GetPixel($x, $y)
            if ($c.R -ge 195 -and $c.G -ge 195 -and $c.B -ge 195) { $n++ }
        }
        $colHit[$x] = $n
    }
    $bmp.Dispose()

    # 3) 连续命中列聚成一簇（允许中间 2px 空隙）
    $clusters = @()
    $s = -1; $gap = 0
    for ($x = 0; $x -lt $w; $x++) {
        if ($colHit[$x] -ge 2) {
            if ($s -lt 0) { $s = $x }
            $gap = 0
        } elseif ($s -ge 0) {
            $gap++
            if ($gap -gt 2) {
                $e = $x - $gap
                if (($e - $s) -ge 4) { $clusters += [int]($x0 + ($s + $e) / 2) }
                $s = -1; $gap = 0
            }
        }
    }
    if ($s -ge 0) {
        $e = $w - 1
        if (($e - $s) -ge 4) { $clusters += [int]($x0 + ($s + $e) / 2) }
    }
    if ($clusters.Count -lt 2) { return $null }
    # 从右往左排。实测 980 宽窗口扫到 4 簇 {1762,1726,1690,1654}：
    # 1762 离右边缘只有 8px，是窗口的最小化/关闭按钮（也是白的，必须排除）；
    # 1726 才是相机，1690 是铃铛，1654 是刷新。
    # 所以先剔除贴右边缘的窗口控制按钮，再取剩下的最右簇。
    $clusters = @($clusters | Sort-Object -Descending)
    $camX = $null
    foreach ($cx in $clusters) {
        if (($win.Right - $cx) -ge 24) { $camX = $cx; break }
    }
    if ($null -eq $camX) { $camX = $clusters[0] }
    $darkYs = @()
    for ($y = 0; $y -lt $h; $y++) { if ($darkRow[$y]) { $darkYs += $y } }
    $camY = if ($darkYs.Count -gt 0) { [int]($y0 + ($darkYs[0] + $darkYs[-1]) / 2) } else { [int]($win.Top + 55) }
    return [pscustomobject]@{ CamX = [int]$camX; CamY = [int]$camY; Clusters = $clusters }
}

function Get-Pixel([int]$x, [int]$y) {
    $bmp = New-Object System.Drawing.Bitmap 1, 1
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size 1, 1))
    $c = $bmp.GetPixel(0, 0)
    $g.Dispose(); $bmp.Dispose()
    return $c
}

function Test-WeChatGreen($c) {
    return ($c.G -gt 150 -and $c.R -lt 120 -and $c.B -lt 150 -and ($c.G - $c.R) -gt 55)
}

# 把窗口统一成固定尺寸并居中，且保证不超出当前屏幕工作区。
# 目的：不同用户的屏幕分辨率和窗口大小都不一样，后续所有坐标计算都基于这个已知几何。
# 若目标尺寸放不下（小屏），自动按工作区缩到能放下为止。
function Normalize-Win($w, [int]$TargetW = 980, [int]$TargetH = 900) {
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $maxW = $wa.Width - 60
    $maxH = $wa.Height - 60
    $tw = [Math]::Min($TargetW, $maxW)
    $th = [Math]::Min($TargetH, $maxH)
    if ($tw -lt 420) { $tw = $maxW }
    if ($th -lt 480) { $th = $maxH }
    $tx = $wa.X + [int](($wa.Width - $tw) / 2)
    $ty = $wa.Y + [int](($wa.Height - $th) / 2)
    try { [void][W32]::ShowWindow($w.Handle, 9) } catch { }
    [void][W32]::MoveWindow($w.Handle, $tx, $ty, $tw, $th, $true)
    Sleep-Ms 800
    $r = New-Object W32+RECT
    [void][W32]::GetWindowRect($w.Handle, [ref]$r)
    return [pscustomobject]@{
        Handle = $w.Handle; Title = $w.Title; Class = $w.Class
        Left = $r.L; Top = $r.T; Width = $r.R - $r.L; Height = $r.B - $r.T
        Right = $r.R; Bottom = $r.B
    }
}

# 扫「微信绿」(#07C160 附近)，4px 网格聚类 + 连通域，取面积最大、形状像按钮的那一块。
# 不依赖任何窗口尺寸/坐标常量。
#
# 【性能】整窗扫描很贵：980x900 按 2px 步长要读 ~22 万像素，实测每次 1~2 秒，
# 而调用方一次运行要扫好几轮（发表前重试 + 发表后验证）。「发表」按钮永远在窗口
# 下半部，所以用 -TopFrac 把上半截直接跳过（默认 0.55 → 少扫一半以上）。
function Find-GreenButton($win, [double]$MinXfrac = 0.0, [double]$TopFrac = 0.0) {
    if (-not $win) { return $null }
    $srcTop = [int]($win.Height * $TopFrac)
    $srcH = $win.Height - $srcTop
    if ($srcH -lt 40) { $srcTop = 0; $srcH = $win.Height }
    $bmp = New-Object System.Drawing.Bitmap $win.Width, $srcH, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($win.Left, ($win.Top + $srcTop), 0, 0, (New-Object System.Drawing.Size $win.Width, $srcH))
    $g.Dispose()
    $rect = New-Object System.Drawing.Rectangle 0, 0, $win.Width, $srcH
    $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $stride = $data.Stride
    $bytes = New-Object byte[] ($stride * $srcH)
    [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
    $bmp.UnlockBits($data)
    $bmp.Dispose()

    # 用 4px 网格 + 连通域，而不是「按行找最长绿色横条」——
    # 按钮上有白字「发表」，会把每一行的绿色切成几段，按行找最长段就永远凑不够宽度，
    # 只剩上下两条无字的细边能被识别，块高只有 8~9px，于是总被判成「没找到」。
    $cell = 4
    $step = 2
    $gw = [int][Math]::Ceiling($win.Width / $cell)
    $gh = [int][Math]::Ceiling($srcH / $cell)
    $grid = New-Object 'int[,]' $gw, $gh
    for ($y = 0; $y -lt $srcH; $y += $step) {
        $base = $y * $stride
        $cy = [int][Math]::Floor($y / $cell)
        for ($x = 0; $x -lt $win.Width; $x += $step) {
            $i = $base + $x * 4
            $bb = $bytes[$i]; $gg = $bytes[$i + 1]; $rr = $bytes[$i + 2]
            if ($gg -gt 150 -and $rr -lt 120 -and $bb -lt 160 -and ($gg - $rr) -gt 55) {
                $grid[[int][Math]::Floor($x / $cell), $cy]++
            }
        }
    }
    $on = New-Object 'bool[,]' $gw, $gh
    for ($cx = 0; $cx -lt $gw; $cx++) {
        for ($cy2 = 0; $cy2 -lt $gh; $cy2++) { if ($grid[$cx, $cy2] -ge 2) { $on[$cx, $cy2] = $true } }
    }

    $seen = New-Object 'bool[,]' $gw, $gh
    $best = $null
    $queue = New-Object System.Collections.Queue
    for ($sx = 0; $sx -lt $gw; $sx++) {
        for ($sy = 0; $sy -lt $gh; $sy++) {
            if (-not $on[$sx, $sy] -or $seen[$sx, $sy]) { continue }
            $queue.Clear()
            $queue.Enqueue(@($sx, $sy))
            $seen[$sx, $sy] = $true
            $bx0 = $sx; $bx1 = $sx; $by0 = $sy; $by1 = $sy
            while ($queue.Count -gt 0) {
                $p = $queue.Dequeue()
                $px = $p[0]; $py = $p[1]
                if ($px -lt $bx0) { $bx0 = $px }; if ($px -gt $bx1) { $bx1 = $px }
                if ($py -lt $by0) { $by0 = $py }; if ($py -gt $by1) { $by1 = $py }
                foreach ($d in @(@(1, 0), @(-1, 0), @(0, 1), @(0, -1))) {
                    $nx = $px + $d[0]; $ny = $py + $d[1]
                    if ($nx -ge 0 -and $nx -lt $gw -and $ny -ge 0 -and $ny -lt $gh -and $on[$nx, $ny] -and -not $seen[$nx, $ny]) {
                        $seen[$nx, $ny] = $true
                        $queue.Enqueue(@($nx, $ny))
                    }
                }
            }
            $pw = ($bx1 - $bx0 + 1) * $cell
            $ph = ($by1 - $by0 + 1) * $cell
            if ($pw -lt 60 -or $pw -gt 340) { continue }
            if ($ph -lt 16 -or $ph -gt 90) { continue }
            $px0 = $bx0 * $cell
            if ($px0 -lt ($win.Width * $MinXfrac)) { continue }
            $area = $pw * $ph
            if (-not $best -or $area -gt $best.Area) {
                $best = [pscustomobject]@{
                    Area = $area
                    X0 = $px0; X1 = ($bx1 + 1) * $cell
                    Y0 = $by0 * $cell; Y1 = ($by1 + 1) * $cell
                }
            }
        }
    }
    if (-not $best) { return $null }
    return [pscustomobject]@{
        X = $win.Left + [int](($best.X0 + $best.X1) / 2)
        Y = $win.Top + $srcTop + [int](($best.Y0 + $best.Y1) / 2)
        W = $best.X1 - $best.X0; H = $best.Y1 - $best.Y0
    }
}

# ---------- 主流程 ----------

if (-not (Test-Path -LiteralPath $Image)) { throw "图片不存在：$Image" }
$Image = (Resolve-Path -LiteralPath $Image).Path

$main = Find-Win -Title '微信' -Class 'QWindowIcon'
if (-not $main) { $main = Find-Win -Title '微信' }
if (-not $main) { throw "微信主窗口没有打开" }
if (-not $Quiet) { Write-Host ("微信 @ {0},{1} {2}x{3}" -f $main.Left, $main.Top, $main.Width, $main.Height) }

if ($DryRun) {
    [pscustomobject]@{
        Stage = 'dry-run'; Image = $Image; Text = $Text
        WeChat = "$($main.Left),$($main.Top) $($main.Width)x$($main.Height)"
    } | Format-List | Out-String | Write-Host
    return
}

# 0.5) 先把主窗口统一成固定尺寸。
# 这一步是给「换个人用」准备的：不同机器分辨率、不同窗口大小，
# 后面所有坐标都从这里的几何算出来，才不会是某台机器的固定魔法数。
$main = Normalize-Win $main $WinWidth $WinHeight
if (-not $Quiet) { Write-Host ("窗口统一为 {0}x{1} @ {2},{3}" -f $main.Width, $main.Height, $main.Left, $main.Top) }

if ($NormalizeOnly) {
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    [pscustomobject]@{
        Stage = 'normalized'; WeChat = "$($main.Left),$($main.Top) $($main.Width)x$($main.Height)"
        WorkArea = "$($wa.X),$($wa.Y) $($wa.Width)x$($wa.Height)"
    } | Format-List | Out-String | Write-Host
    return
}

# 1) 进朋友圈
# 微信可能把朋友圈渲染成独立窗口，也可能内嵌在主窗口里。两种都要认。
$moments = Find-Win -Title '朋友圈' -Class 'QWindowIcon' -TimeoutSec 1 -MinWidth 600
if (-not $moments) {
    Activate-Win $main
    # 左侧导航用**比例**而不是固定 px：不同 DPI（125%/150%）下侧栏宽度会变
    Click-At ($main.Left + [int]($main.Width * 0.035)) ($main.Top + [int]($main.Height * 0.273)) 1200   # 左侧「发现」
    Click-At ($main.Left + [int]($main.Width * 0.112)) ($main.Top + [int]($main.Height * 0.111)) 2500   # 「朋友圈」列表项

    $moments = Find-Win -Title '朋友圈' -Class 'QWindowIcon' -TimeoutSec 5 -MinWidth 600
    if (-not $moments) {
        # 内嵌模式：朋友圈内容直接渲染在主窗口里，相机图标在主窗口右上角
        if (-not $Quiet) { Write-Host "  [info] 未见独立朋友圈窗口，按内嵌模式处理" }
        $moments = $main
    } else {
        if (-not $Quiet) { Write-Host "  已进入朋友圈（独立窗口）" }
    }
}
if (-not $moments) { throw "没能进入朋友圈" }
# 朋友圈若是独立窗口，也统一尺寸，保证后续比例计算落在已知几何上
if ($moments.Handle -ne $main.Handle) { $moments = Normalize-Win $moments }
Activate-Win $moments
if (-not $Quiet) { Write-Host ("朋友圈画布 @ {0},{1} {2}x{3}" -f $moments.Left, $moments.Top, $moments.Width, $moments.Height) }

# 1.5) 滚到顶：相机按钮只在信息流顶部才可点。
# 旧版这里反复滚了 30 轮 x 30 下，结果把页面滚过头 / 滚动消息被窗口丢弃，
# 反而更难复位。现在只滚一轮，然后靠相机重试兜底。
if (-not $Quiet) { Write-Host "  滚到信息流顶部" }
$wheelX = $moments.Left + 120
$wheelY = $moments.Top + 250
[void][W32]::SetCursorPos($wheelX, $wheelY)
Sleep-Ms 80
for ($k = 0; $k -lt 12; $k++) {
    [W32]::mouse_event(0x0800, 0, 0, [UInt32]([int64]4294967296 - 120), [IntPtr]::Zero)
    Sleep-Ms 40
}
Sleep-Ms 700

# 2) 相机（朋友圈画布右上角）
# 微信有时把这个入口渲染成内嵌视图，弹出文件框可能慢一拍；轮询并重试一次。
#
# 标题栏三个图标从左到右：刷新、铃铛（消息）、相机。间距约 22~30px。
# 相机在最右，距窗口右边缘约 44~46px（实测 592 宽窗口里相机中心在 x=924，
# 窗口左边缘 376 → 偏右 548，即 Right-44）。
# 用 Right-46 会点到铃铛上（弹「全部互动消息」面板），必须用 Right-44 并留容差。
$dlg = $null
foreach ($camTry in 1..4) {
    # 每次都用最新窗口位置重新算相机坐标（窗口可能被系统挪过/改过宽度）
    # ⚠ 内嵌模式下没有标题为「朋友圈」的独立窗口，Find-Win 一直返回空，
    #    如果只在这个分支里刷新，$moments 会一直是脚本开头读到的旧尺寸 ——
    #    实测窗口从 803 宽变成 658 宽后，按旧尺寸算出的 camX 直接落到窗口外，
    #    于是点 3 次相机全落空。所以这里必须回退到重新读主窗口。
    $fresh = Find-Win -Title '朋友圈' -Class 'QWindowIcon' -TimeoutSec 1 -MinWidth 600
    if ($fresh) {
        $moments = $fresh
    } else {
        $m2 = Find-Win -Title '微信' -Class 'QWindowIcon' -TimeoutSec 1
        if ($m2) { $moments = $m2 }
    }
    # 相机在标题栏最右三个白色图标里最右边那个。不同窗口宽度/DPI 下偏移量不固定
    # （实测 591 宽 Right-47、980 宽 Right-18），所以先扫像素找图标簇；扫不到再按比例兜底。
    $icons = Find-TitleBarIcons $moments
    if ($icons) {
        $camX = $icons.CamX
        $camY = $icons.CamY
    } else {
        $fallback = @(18, 44, 36, 52)
        $camX = $moments.Right - $fallback[$camTry - 1]
        $camY = $moments.Top + 55
    }
    Activate-Win $moments
    Sleep-Ms 400
    Click-At $camX $camY 900
    if (-not $Quiet) {
        $src = if ($icons) { "扫描图标簇 {$($icons.Clusters -join ',')}" } else { '比例兜底' }
        Write-Host ("  已点相机 ({0},{1}) 第 {2} 次（窗口 {3}x{4}，{5}）" -f $camX, $camY, $camTry, $moments.Width, $moments.Height, $src)
    }

    $deadline = (Get-Date).AddSeconds(12)
    while ((Get-Date) -lt $deadline) {
        $dlg = Find-Win -Title '选择文件' -Class '#32770' -TimeoutSec 1
        if ($dlg) { break }
        Sleep-Ms 400
    }
    if ($dlg) { break }
    if (-not $Quiet) { Write-Host "  [retry] 文件框未出现，再点一次相机" }
}
if (-not $dlg) { throw "文件选择框没有出现" }
if (-not $Quiet) { Write-Host ("文件框 @ {0},{1} {2}x{3}" -f $dlg.Left, $dlg.Top, $dlg.Width, $dlg.Height) }

# 3) 填图片路径
# 文件选择框弹出时，焦点通常已经落在下方「文件名」输入框里，**直接粘贴 + 回车**即可。
# 少一次坐标点击就少一个失效点：那个框的位置随对话框尺寸/语言/DPI 变（旧代码按
# "Left + 46%W, Bottom - 62" 猜，换台机器就可能点空）。
Activate-Win $dlg
Sleep-Ms 300
Paste-Text $Image 600
Send-Key 0x0D 2000   # Enter
if (Find-Win -Title '选择文件' -Class '#32770' -TimeoutSec 3) {
    # 直接粘贴没生效（焦点不在文件名框）→ 退回「先点框再粘」的老办法
    if (-not $Quiet) { Write-Host "  [retry] 文件框还在，改为先点文件名框再粘贴" }
    $boxX = $dlg.Left + [int]($dlg.Width * 0.46)
    $boxY = $dlg.Bottom - 62
    Click-At $boxX $boxY 400
    Paste-Text $Image 400
    Send-Key 0x0D 2500
}
if (-not $Quiet) { Write-Host "  已选图片" }

# 4) 填文案
# 发布框标题也叫「朋友圈」，但它是**小窗口**（约 410x528）；这里限定宽度上限，
# 免得万一有个大连锁画布窗口存在时抢走匹配。
$editor = Find-Win -Title '朋友圈' -Class 'QWindowIcon' -TimeoutSec 10 -MaxWidth 800
if (-not $editor) { throw "发布框没有出现" }
Activate-Win $editor
Sleep-Ms 500
$txtX = $editor.Left + [int]($editor.Width * 0.42)
$txtY = $editor.Top + 78
Click-At $txtX $txtY 500
if ($Text) { Paste-Text $Text 600 }
if (-not $Quiet) { Write-Host "  已填文案" }

# 5) 发表：整窗扫微信绿定位「发表」按钮，不依赖窗口尺寸
# 发布框有两种形态：独立窗口，或内嵌在主窗口里渲染（后者很常见）。
# 所以固定扫「主窗口」，并跳过左侧导航栏（那里也有绿色的选中项，会误命中）。
# 按钮是异步渲染的，要过几百毫秒才画出来 —— 必须重试。
$btn = $null
for ($scan = 1; $scan -le 10; $scan++) {
    $btn = Find-GreenButton $main 0.22 -TopFrac 0.55
    if ($btn) { break }
    Sleep-Ms 400
}
if ($btn) {
    $btnX = $btn.X; $btnY = $btn.Y
    if (-not $Quiet) { Write-Host ("  绿色按钮 ({0},{1}) {2}x{3}" -f $btnX, $btnY, $btn.W, $btn.H) }
} else {
    $btnX = 0; $btnY = 0
    if (-not $Quiet) { Write-Host "  [warn] 没扫到绿色按钮" }
}
if ($NoPublish) {
    if (-not $Quiet) { Write-Host "  [NoPublish] 只验证定位，不发布（发布框留在屏幕上，手动关掉即可）" }
    [pscustomobject]@{
        Stage = 'no-publish'; Image = $Image; Text = $Text
        WeChat = "$($main.Left),$($main.Top) $($main.Width)x$($main.Height)"
        Submit = "$btnX,$btnY"
    } | Format-List | Out-String | Write-Host
    return
}
Click-At $btnX $btnY 1500
if (-not $Quiet) { Write-Host "  已点发表 ($btnX,$btnY)" }

# 6) 确认发表生效。
# 旧版只「等 1.5 秒 + 看绿色按钮还在不在」，两个问题：
#   ① 固定等待，按钮其实几百毫秒就消失，白等；按钮没消失时要再等 4 秒才重试。
#   ② 只看按钮不够 —— 发布框有小窗口形态，框关掉了按钮自然也没了。
# 现在改成轮询，并且把「发布框窗口是否还在」和「绿按钮是否还在」一起看。
$stage = 'uncertain'
$deadline = (Get-Date).AddSeconds(12)
while ((Get-Date) -lt $deadline) {
    $stillEditor = Find-Win -Title '朋友圈' -Class 'QWindowIcon' -TimeoutSec 1 -MaxWidth 800
    $stillBtn = Find-GreenButton $main 0.22 -TopFrac 0.55
    if (-not $stillEditor -and -not $stillBtn) { $stage = 'published'; break }
    if ($stillBtn -and -not $stillEditor) {
        # 内嵌模式没有独立发布框窗口，只能靠按钮判断：还在就再点一次
        if (-not $Quiet) { Write-Host "  [verify] 发表按钮还在，重点一次" }
        Click-At $stillBtn.X $stillBtn.Y 2000
    }
    Sleep-Ms 500
}
if ($stage -ne 'published' -and -not $Quiet) {
    Write-Host "  [error] 点了发表但发布框/按钮没消失，可能没发出去"
}

[pscustomobject]@{
    Stage = $stage; Image = $Image; Text = $Text
    Submit = "$btnX,$btnY"
} | Format-List | Out-String | Write-Host
if ($stage -eq 'uncertain') { exit 2 }
