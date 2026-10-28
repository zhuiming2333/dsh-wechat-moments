# 看自己朋友圈有没有人评论，列出谁说了什么
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File moments-inbox.ps1 [-NoScroll]
#
# 说明：
#   依赖 Windows OCR 读微信窗口文字，不需要模型看图。
#   只读：不点击、不发送，纯看。
#   默认会先把自己朋友圈滚到顶部；加 -NoScroll 就不动滚动位置。

param(
    [switch]$NoScroll
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$probeScript = Join-Path $here 'wx_ocr_probe.ps1'

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class W32Inbox {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
"@
try { [W32Inbox]::SetProcessDPIAware() | Out-Null } catch { }

function Get-WeChatWin {
    $p = Get-Process -Name Weixin -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if (-not $p) { throw '没找到微信窗口，先打开微信' }
    $r = New-Object W32Inbox+RECT
    [void][W32Inbox]::GetWindowRect([IntPtr]$p.MainWindowHandle, [ref]$r)
    return [pscustomobject]@{ Hwnd = [IntPtr]$p.MainWindowHandle; Left = $r.Left; Top = $r.Top; W = ($r.Right - $r.Left); H = ($r.Bottom - $r.Top) }
}

function Wheel-Up([int]$times, [int]$x, [int]$y) {
    $win = Get-WeChatWin
    [void][W32Inbox]::SetForegroundWindow($win.Hwnd)
    [void][W32Inbox]::SetCursorPos(($win.Left + $x), ($win.Top + $y))
    Start-Sleep -Milliseconds 150
    for ($i = 0; $i -lt $times; $i++) {
        [W32Inbox]::mouse_event(0x0800, 0, 0, [UInt32]([int64]4294967296 - 120), [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 90
    }
    Start-Sleep -Milliseconds 1300
}

function Get-OcrLines([int]$minY = 0) {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $probeScript -MinY $minY 2>&1
    $lines = @()
    foreach ($raw in $out) {
        $s = [string]$raw
        if ($s -match '^\s*\[\s*(\d+),\s*(\d+)\]\s+(\d+)x(\d+)\s+(.*)$') {
            $lines += [pscustomobject]@{
                X = [int]$Matches[1]; Y = [int]$Matches[2]
                W = [int]$Matches[3]; H = [int]$Matches[4]
                Text = ($Matches[5] -replace '\s', '')
            }
        }
    }
    return $lines
}

# 本账号昵称从共享配置读；读不到就退化成「不按昵称过滤」
# （只按评论结构判断谁在回复谁，宁可多列也不漏）。
function Get-MeNick {
    foreach ($c in @(
        (Join-Path $here 'wechat-moments.config.json'),
        (Join-Path $env:USERPROFILE '.dsh\wechat-moments.config.json')
    )) {
        if (-not (Test-Path -LiteralPath $c)) { continue }
        try {
            $j = Get-Content -LiteralPath $c -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.ownNick) { return [string]$j.ownNick }
            if ($j.ownWxid) { return [string]$j.ownWxid }
        } catch { }
    }
    return ''
}

$me = Get-MeNick
if (-not $me) { Write-Host '[inbox] 没读到本账号昵称（配置里 ownNick 为空），按全部评论列出' }

if (-not $NoScroll) {
    Write-Host '[inbox] 滚到朋友圈顶部'
    try { Wheel-Up 14 350 300 } catch { Write-Host ('[inbox] 滚动失败：' + $_.Exception.Message) }
}

$lines = Get-OcrLines 0
Write-Host ("[inbox] OCR 读到 " + $lines.Count + " 行")

# 解析规则（按微信朋友圈实际排版）：
#   「X回复Y：内容」 -> 别人回我 / 我回别人
#   「昵称：内容」    -> 一级评论
# 我自己是 $me，凡是我发的都跳过。
$items = @()
foreach ($ln in $lines) {
    $t = $ln.Text
    if ($t -match '^(.+?)回复(.+?)：(.+)$') {
        $replier = $Matches[1]; $target = $Matches[2]; $body = $Matches[3]
        if ($replier -eq $me) { continue }
        $items += [pscustomobject]@{ Kind = 'reply'; Nick = $replier; To = $target; Body = $body; Y = $ln.Y; X = $ln.X; W = $ln.W }
        continue
    }
    if ($t -match '^([^：]{1,20})：(.+)$') {
        $nick = $Matches[1]; $body = $Matches[2]
        if ($nick -eq $me) { continue }
        if ($nick -match '^(?:\d+分钟前|\d+小时前|\d+天前|刚刚)$') { continue }
        $items += [pscustomobject]@{ Kind = 'comment'; Nick = $nick; To = $me; Body = $body; Y = $ln.Y; X = $ln.X; W = $ln.W }
        continue
    }
}

if ($items.Count -eq 0) {
    Write-Host '[inbox] 视野内没看到别人的评论'
    return
}

Write-Host ''
Write-Host ("[inbox] 看到 " + $items.Count + " 条别人的评论：")
Write-Host ''
Write-Host '| # | 谁 | 类型 | 说了什么 | 屏幕上 y |'
Write-Host '|---|----|------|---------|---------|'
$i = 0
foreach ($it in $items) {
    $i++
    $kind = if ($it.Kind -eq 'reply') { '回复' } else { '评论' }
    Write-Host ("| {0} | {1} | {2} | {3} | {4} |" -f $i, $it.Nick, $kind, $it.Body, $it.Y)
}

Write-Host ''
Write-Host '[inbox] 回哪条就把昵称和内容交给 wechat-moments-reply.ps1。'
