# wechat-moments-reply.ps1 — 回复自己朋友圈动态下的评论
#
# 读：reader API /api/v1/sns/mine（wxid / 昵称 / 内容，确定性）
# 写：微信 UI —— 截窗口 → 2x 放大 → Windows.Media.Ocr 识别 → 模糊匹配评论行
#     → 点击进回复态 → OCR 校验「回复 <昵称>」→ 粘贴文本 → OCR 找「发送」并点击
# 安全：默认 dry-run；-Execute 才碰桌面；匹配分数接近时拒绝猜测；已回复的记台账。
#
# 用法：
#   powershell -File wechat-moments-reply.ps1 -List
#   powershell -File wechat-moments-reply.ps1 -ObjectId 1503... -CommentId 67 -Text "回复内容"
#   powershell -File wechat-moments-reply.ps1 -ObjectId 1503... -CommentId 67 -Text "回复内容" -Execute
#   powershell -File wechat-moments-reply.ps1 -ObjectId 1503... -CommentId 67 -Text "..." -Execute -DryRunUi

[CmdletBinding()]
param(
    [string]$ObjectId,
    [string]$CommentId,
    [string]$Text,
    [switch]$List,
    [switch]$Execute,
    [switch]$Quiet,
    [switch]$DryRunUi,
    [double]$OcrScale = 2.0
)

$ErrorActionPreference = 'Stop'

# ---------- 配置 ----------
# 一律从 wechat-moments.config.json 读，避免任何人的路径 / token / wxid 被写死进脚本。
# 查找顺序：脚本同目录 → %USERPROFILE%\.dsh\ → 都没有就报错，提示先跑 setup.ps1。
function Get-MomentsConfig {
    $cands = @(
        (Join-Path $PSScriptRoot 'wechat-moments.config.json'),
        (Join-Path $env:USERPROFILE '.dsh\wechat-moments.config.json'),
        (Join-Path $env:USERPROFILE '.dsh\skills\wechat-moments\wechat-moments.config.json')
    )
    foreach ($c in $cands) {
        if (-not $c) { continue }
        if (-not (Test-Path -LiteralPath $c)) { continue }
        try { return (Get-Content -LiteralPath $c -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { }
    }
    return $null
}

$Cfg = Get-MomentsConfig
if (-not $Cfg) {
    throw ('没找到 wechat-moments.config.json。先跑一次安装包里的 setup.ps1，' +
           '它会自动探测 reader 地址 / token / wxid 并生成这个文件。')
}

$ROOT   = [string]$Cfg.workspace
$READER = if ($Cfg.readerUrl) { [string]$Cfg.readerUrl } else { 'http://127.0.0.1:5031' }
$TOKEN  = [string]$Cfg.readerToken
$LEDGER = Join-Path $ROOT 'state\moments-replies.json'

# 本账号 wxid / 昵称：用来跳过自己发的评论。
$OwnWxid = [string]$Cfg.ownWxid
$OwnNick = if ($Cfg.ownNick) { [string]$Cfg.ownNick } else { '' }

# ---------- 台账 ----------

function Get-LedgerPath {
    $p = $LEDGER
    if (-not $p) { $p = $LEDGER }
    return $p
}

function Read-Ledger {
    $lp = Get-LedgerPath
    if (-not (Test-Path -LiteralPath $lp)) { return @{} }
    try {
        $raw = Get-Content -LiteralPath $lp -Raw -Encoding UTF8
        if (-not $raw.Trim()) { return @{} }
        $obj = $raw | ConvertFrom-Json
        $map = @{}
        foreach ($p in $obj.PSObject.Properties) { $map[$p.Name] = $p.Value }
        return $map
    } catch { return @{} }
}

function Save-Ledger($map) {
    # 只走 .NET，避免 PowerShell 参数集解析在无配置文件环境下的各种坑
    $lp = Get-LedgerPath
    $dir = [System.IO.Path]::GetDirectoryName($lp)
    if ($dir -and -not [System.IO.Directory]::Exists($dir)) { [System.IO.Directory]::CreateDirectory($dir) | Out-Null }
    $json = $map | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($lp, $json, (New-Object System.Text.UTF8Encoding $false))
}

function LedgerKey([string]$oid, [string]$cid) { return "$oid`:$cid" }

# ---------- reader ----------

function Resolve-OwnWxid {
    # 从 WeChatAgent / WeFlow 配置里拿本账号 wxid。
    # wechat-io-config.json 的 self_wxid 常常是空串，真正有用的是
    # weflow/WeFlow-config.json 里的 myWxid。
    # 路径基于配置里的 workspace 推导，不再写死某台机器的盘符。
    $candidates = @(
        (Join-Path $ROOT 'state\weflow\WeFlow-config.json'),
        (Join-Path $ROOT 'state\wechat-io-config.json')
    )
    foreach ($f in $candidates) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        try {
            $j = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($n in @('myWxid', 'self_wxid', 'wxid', 'own_wxid', 'account')) {
                if ($j.PSObject.Properties.Name -contains $n -and $j.$n) { return [string]$j.$n }
            }
        } catch { }
    }
    return ''
}

function Normalize-Wxid([string]$id) {
    # WeFlow 的 myWxid 是 wxid_xxx_2cc0（带数据库目录后缀），
    # 而动态/评论表里是 wxid_xxx，比较前要削掉后缀。
    if (-not $id) { return '' }
    return ($id -replace '_[0-9a-f]{4}$', '')
}

function Same-Account([string]$a, [string]$b) {
    $na = Normalize-Wxid $a
    $nb = Normalize-Wxid $b
    return ($na -and $nb -and $na -eq $nb)
}

if (-not $OwnWxid) { $OwnWxid = Resolve-OwnWxid }
$OwnWxid = Normalize-Wxid $OwnWxid

function Get-MyMoments([int]$limit = 30) {
    # token 走 header；reader 的 sns 路由不接受 query 里的 access_token
    $headers = @{ Authorization = "Bearer $TOKEN" }
    $r = Invoke-RestMethod "$READER/api/v1/sns/mine?limit=$limit" -Headers $headers -TimeoutSec 30
    if (-not $r.success) { throw "reader 返回失败：$($r.error)" }

    # reader 返回 posts[] + comments[]（扁平），这里按 tid 组装成
    # post.candidates（别人发的、可以回复的评论）。
    $byTid = @{}
    foreach ($p in $r.posts) {
        $tid = [string]$p.tid
        $byTid[$tid] = [pscustomobject]@{
            object_id = $tid
            content   = $p.content
            createAt  = $p.createTime
            candidates = New-Object System.Collections.ArrayList
        }
    }
    foreach ($c in $r.comments) {
        $tid = [string]$c.feedId
        if (-not $byTid.ContainsKey($tid)) { continue }
        if ($c.isLike) { continue }                      # 点赞不是评论
        if (Same-Account $c.fromUsername $OwnWxid) { continue }   # 自己发的不用回
        if ($OwnNick -and ([string]$c.fromNickname) -eq $OwnNick) { continue }  # 昵称兜底跳过自己
        [void]$byTid[$tid].candidates.Add([pscustomobject]@{
            comment_id = $c.commentId
            nickname   = $c.fromNickname
            username   = $c.fromUsername
            content    = $c.content
            createAt   = $c.createTime
        })
    }
    $posts = @($byTid.Values | Where-Object { $_.candidates.Count -gt 0 } | Sort-Object { -$_.createAt })
    return [pscustomobject]@{
        own_wxid = $OwnWxid
        count    = $posts.Count
        posts    = $posts
    }
}

function Resolve-Target($mine, [string]$oid, [string]$cid) {
    $post = $mine.posts | Where-Object { $_.object_id -eq $oid } | Select-Object -First 1
    if (-not $post) { throw "没找到 object_id=$oid 的动态（可能不在最近 $($mine.count) 条内）" }
    $comment = $post.candidates | Where-Object { [string]$_.comment_id -eq $cid } | Select-Object -First 1
    if (-not $comment) { throw "动态 $oid 下没有 comment_id=$cid 的评论" }
    return [pscustomobject]@{ Post = $post; Comment = $comment }
}

# ---------- 界面显示名（DB 昵称 → 界面上真正显示的名字） ----------
# DB 里存的是原始昵称，朋友圈界面上显示的是备注名：
#   真由理 → 南华 / 翮 → 高一健身李帅佐
# 按 DB 昵称去 OCR 里找永远找不到，之前只能退化成「正文模糊匹配」，
# 短评论（「真的假的」「大肥鱼」）就会匹配到隔壁那条，回复到别人头上。
# reader 的 /api/v1/contacts 能给出 displayName，这才是界面上印的字。

$script:DispCache = @{}
$script:DispWarned = $false
function Get-DisplayName([string]$dbNick, [string]$username) {
    if ($script:DispCache.ContainsKey($dbNick)) { return $script:DispCache[$dbNick] }
    $dn = $dbNick
    try {
        if ($username) {
            $q = [uri]::EscapeDataString($username)
            $hdr = @{ Authorization = "Bearer $TOKEN" }
            $ct = Invoke-RestMethod "$READER/api/v1/contacts?keyword=$q&limit=5" -Headers $hdr -TimeoutSec 15
            $hit = @($ct.contacts) | Where-Object { $_.username -eq $username } | Select-Object -First 1
            if ($hit -and $hit.displayName) { $dn = [string]$hit.displayName }
        }
    } catch {
        if (-not $script:DispWarned) {
            $script:DispWarned = $true
            Write-Host "[reader] 查显示名失败（用 DB 昵称兜底，后续不再提示）：$($_.Exception.Message)" -ForegroundColor DarkGray
        }
    }
    $script:DispCache[$dbNick] = $dn
    return $dn
}

# ---------- 列出待回复 ----------

if ($List) {
    $mine = Get-MyMoments 30
    $ledger = Read-Ledger
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

    Write-Host "本账号: $($mine.own_wxid)"
    Write-Host "扫描最近 $($mine.count) 条动态`n"

    $shown = 0
    foreach ($p in $mine.posts) {
        $todo = @()
        foreach ($c in $p.candidates) {
            if (-not $ledger.ContainsKey((LedgerKey $p.object_id $c.comment_id))) { $todo += $c }
        }
        if ($todo.Count -eq 0) { continue }
        $shown++
        Write-Host "【$($p.object_id)】$($p.content)"
        foreach ($c in $todo) {
            $one = ($c.content -replace "`r?`n", ' ')
            $dn = Get-DisplayName $c.nickname $c.username
            $who = if ($dn -and $dn -ne $c.nickname) { "$($c.nickname)（界面显示：$dn）" } else { $c.nickname }
            Write-Host ("   cid={0,-5} {1}: {2}" -f $c.comment_id, $who, $one)
        }
        Write-Host ''
    }
    if ($shown -eq 0) { Write-Host "没有待回复的评论。" }
    return
}

if (-not $ObjectId -or -not $CommentId) {
    Write-Host "用法：-List  或  -ObjectId <id> -CommentId <id> -Text <内容> [-Execute]" -ForegroundColor Yellow
    exit 2
}

$mine = Get-MyMoments 30
$target = Resolve-Target $mine $ObjectId $CommentId
$key = LedgerKey $ObjectId $CommentId
$ledger = Read-Ledger

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Write-Host "目标动态: $($target.Post.content)"
Write-Host "目标评论: $($target.Comment.nickname): $(($target.Comment.content -replace "`r?`n",' '))"
Write-Host "回复内容: $Text"

if ($ledger.ContainsKey($key)) {
    Write-Host "`n[跳过] 这条评论已经回复过（$($ledger[$key].at)）：$($ledger[$key].text)" -ForegroundColor Yellow
    exit 0
}

if (Same-Account $target.Comment.username $mine.own_wxid) {
    Write-Host "`n[跳过] 这是本账号自己发的评论，不需要回复。" -ForegroundColor Yellow
    exit 0
}

if ($OwnNick -and ([string]$target.Comment.nickname) -eq $OwnNick) {
    Write-Host "`n[跳过] 这是本账号（$OwnNick）自己的评论，不需要回复。" -ForegroundColor Yellow
    exit 0
}

if (-not $Execute) {
    Write-Host "`n[dry-run] 计划已确认，未触碰桌面。加 -Execute 才会真正回复。" -ForegroundColor Cyan
    exit 0
}

# =====================================================================
# UI 执行
# =====================================================================

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Runtime.WindowsRuntime

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class W32Moments {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint f, UIntPtr e);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int t, bool repaint);
}
"@

try { [W32Moments]::SetProcessDPIAware() | Out-Null } catch { }

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

function Click-At([int]$x, [int]$y) {
    [W32Moments]::SetCursorPos($x, $y) | Out-Null
    Start-Sleep -Milliseconds 60
    [W32Moments]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 40
    [W32Moments]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 280
}

function Wheel-Up([int]$x, [int]$y, [int]$times) {
    [W32Moments]::SetCursorPos($x, $y) | Out-Null
    Start-Sleep -Milliseconds 120
    for ($i = 0; $i -lt $times; $i++) {
        [W32Moments]::mouse_event(0x0800, 0, 0, 120, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 45
    }
    Start-Sleep -Milliseconds 400
}

function Wheel-Down([int]$x, [int]$y, [int]$times) {
    [W32Moments]::SetCursorPos($x, $y) | Out-Null
    Start-Sleep -Milliseconds 120
    # mouse_event 的 dwData 是 UInt32，负数要按补码传：-120 = 4294967176
    $neg = [UInt32]([int64]4294967296 - 120)
    for ($i = 0; $i -lt $times; $i++) {
        [W32Moments]::mouse_event(0x0800, 0, 0, $neg, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 45
    }
    Start-Sleep -Milliseconds 400
}

function Send-Txt([string]$s) {
    Set-Clipboard -Value $s
    Start-Sleep -Milliseconds 150
    # 先 Ctrl+A 全选再粘贴：重试时是替换而不是追加，避免重复内容
    [W32Moments]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero)
    [W32Moments]::keybd_event(0x41, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [W32Moments]::keybd_event(0x41, 0, 2, [UIntPtr]::Zero)
    [W32Moments]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 120
    [W32Moments]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero)
    [W32Moments]::keybd_event(0x56, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [W32Moments]::keybd_event(0x56, 0, 2, [UIntPtr]::Zero)
    [W32Moments]::keybd_event(0x11, 0, 2, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 400
}

function Esc-Key {
    [W32Moments]::keybd_event(0x1B, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [W32Moments]::keybd_event(0x1B, 0, 2, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 320
}

# 只有当确实存在微信的浮层（资料卡 / 下拉面板）时才按 Esc。
# 直接无条件按 Esc 有把朋友圈或主窗口关掉的风险。
Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class WPopup {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
}
"@

function Get-WeixinPopupCount {
    $pids = (Get-Process -Name Weixin -ErrorAction SilentlyContinue).Id
    $script:popupCount = 0
    $cb = [WPopup+EnumProc]{
        param($h, $l)
        $px = 0
        [WPopup]::GetWindowThreadProcessId($h, [ref]$px) | Out-Null
        if ($pids -contains $px -and [WPopup]::IsWindowVisible($h)) {
            $sb = New-Object System.Text.StringBuilder 256
            [WPopup]::GetClassNameW($h, $sb, 256) | Out-Null
            if ($sb.ToString() -like '*ToolSaveBits*') { $script:popupCount++ }
        }
        return $true
    }
    [WPopup]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
    return $script:popupCount
}

function Dismiss-Popup {
    # 故意不按 Esc。实测在详情页/浮层上 Esc 收不掉东西，而且历史上按 Esc 把微信搞成
    # 白屏、只能重启。这里只等一会儿，让浮层自己超时消失；后续点击用实时坐标，不依赖它。
    Start-Sleep -Milliseconds 200
}

Add-Type @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public class WFind {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left,Top,Right,Bottom; }
    // 微信同一进程里有多个 Qt 顶层窗口（主窗口 / 资料卡 / 朋友圈浮层），
    // Process.MainWindowHandle 会指错。这里按「类名 + 标题 + 面积最大」自己挑。
    public static IntPtr Best(uint[] pids, string title) {
        IntPtr best = IntPtr.Zero; long bestArea = 0;
        EnumWindows((h,l) => {
            if (!IsWindowVisible(h)) return true;
            uint px; GetWindowThreadProcessId(h, out px);
            bool ok = false;
            foreach (var p in pids) { if (p == px) { ok = true; break; } }
            if (!ok) return true;
            var cn = new StringBuilder(256); GetClassNameW(h, cn, 256);
            if (cn.ToString().IndexOf("Qt51514QWindowIcon") < 0) return true;
            if (title != null) {
                var tt = new StringBuilder(256); GetWindowTextW(h, tt, 256);
                if (tt.ToString() != title) return true;
            }
            RECT r; if (!GetWindowRect(h, out r)) return true;
            long area = (long)(r.Right-r.Left) * (r.Bottom-r.Top);
            if (area > bestArea) { bestArea = area; best = h; }
            return true;
        }, IntPtr.Zero);
        return best;
    }
    // 个人资料卡是独立的 Qt 弹窗（class Qt51514QWindowToolSaveBits，实测 328x335）。
    // 注意：朋友圈窗口也是同一个 class 且 492x503，比资料卡更大 ——
    // 所以必须按「面积最小」挑，而不是最大；否则会截到朋友圈窗口，
    // OCR 出来的「朋友圈」坐标属于另一张图，点击必然落空。
    // 另外把宽度上限收到 460，朋友圈窗口(492 宽)直接被排除。
    public static IntPtr Card(uint[] pids) {
        IntPtr best = IntPtr.Zero; long bestArea = 0;
        EnumWindows((h,l) => {
            if (!IsWindowVisible(h)) return true;
            uint px; GetWindowThreadProcessId(h, out px);
            bool ok = false;
            foreach (var p in pids) { if (p == px) { ok = true; break; } }
            if (!ok) return true;
            var cn = new StringBuilder(256); GetClassNameW(h, cn, 256);
            if (cn.ToString().IndexOf("Qt51514") < 0) return true;
            RECT r; if (!GetWindowRect(h, out r)) return true;
            int w = r.Right - r.Left, hh = r.Bottom - r.Top;
            // 资料卡实测有两种尺寸：328x335（小卡）和 492x503（大卡）。
            // 早先上限写 w<=460，大卡认不出来 → 脚本以为没弹出，再点一次反而把它关掉。
            if (w < 240 || w > 560 || hh < 240 || hh > 660) return true;
            long area = (long)w * hh;
            if (bestArea == 0 || area < bestArea) { bestArea = area; best = h; }
            return true;
        }, IntPtr.Zero);
        return best;
    }
    // 点资料卡缩略图后，「我的朋友圈」在这个版本里会开成**独立窗口**。
    // 实测有两种形态，且都不属于 Weixin 主进程：
    //   a) Qt 窗口，标题「朋友圈」，class Qt51514QWindowIcon
    //   b) CEF 窗口，标题「微信」，class Chrome_WidgetWin_0（WeChatAppEx 进程，921x891）
    // 所以不能按 pid 过滤，也不能只认 Qt 类名；按「标题 + 类名 + 面积」综合认。
    // 主窗口面积最大且标题为「微信」，排除它（用 mainPid/mainHwnd 传入）。
    public static IntPtr Moments(uint[] pids, IntPtr mainHwnd) {
        IntPtr best = IntPtr.Zero; long bestArea = 0;
        EnumWindows((h,l) => {
            if (!IsWindowVisible(h)) return true;
            if (h == mainHwnd) return true;
            var cn = new StringBuilder(256); GetClassNameW(h, cn, 256);
            var cls = cn.ToString();
            bool qt   = cls.IndexOf("Qt51514QWindowIcon") >= 0;
            bool cef  = cls.IndexOf("Chrome_WidgetWin") >= 0;
            if (!qt && !cef) return true;
            var tt = new StringBuilder(256); GetWindowTextW(h, tt, 256);
            var title = tt.ToString();
            // 朋友圈窗口要么标题就叫「朋友圈」，要么是 CEF 里那个标题为「微信」的
            if (title != "朋友圈" && !(cef && title == "微信")) return true;
            RECT r; if (!GetWindowRect(h, out r)) return true;
            long area = (long)(r.Right-r.Left)*(r.Bottom-r.Top);
            if (area > bestArea) { bestArea = area; best = h; }
            return true;
        }, IntPtr.Zero);
        return best;
    }
}
"@

function Get-CardHwnd {
    $procs = Get-Process -Name Weixin -ErrorAction SilentlyContinue
    if (-not $procs) { return [IntPtr]::Zero }
    $pids = [uint32[]]@($procs | ForEach-Object { $_.Id })
    return [WFind]::Card($pids)
}

function Get-MomentsHwnd {
    $procs = Get-Process -Name Weixin -ErrorAction SilentlyContinue
    if (-not $procs) { return [IntPtr]::Zero }
    $pids = [uint32[]]@($procs | ForEach-Object { $_.Id })
    # 朋友圈窗口可能属于 WeChatAppEx（CEF）进程，不一定是 Weixin，故传入主窗口以便排除。
    return [WFind]::Moments($pids, (Get-WeChatHwnd))
}

function Get-WeChatHwnd {
    $procs = Get-Process -Name Weixin -ErrorAction SilentlyContinue
    if (-not $procs) { return [IntPtr]::Zero }
    $pids = [uint32[]]@($procs | ForEach-Object { $_.Id })
    $h = [WFind]::Best($pids, '微信')
    if ($h -ne [IntPtr]::Zero) { return $h }
    return [WFind]::Best($pids, $null)
}

$script:shotSeq = 0
function Capture-Window([IntPtr]$hwnd, [double]$xFracFrom = 0, [double]$xFracTo = 1, [IntPtr]$TopHwnd = [IntPtr]::Zero, [switch]$NoActivate) {
    # 相册和详情页都只占窗口右半边，裁掉左半边能少一半 OCR 文字、
    # 也避免把左侧信息流的别人的动态误当成自己的。
    # CopyFromScreen 抓的是屏幕像素而不是窗口内容，所以必须先确保目标窗口在最前面，
    # 否则浏览器/编辑器盖在上面时，截到的是它们的画面。
    # TopHwnd 用来指定「提到最前面的是哪个窗口」：截资料卡时要提资料卡，
    # 提主窗口反而会把资料卡压到后面去。
    # NoActivate：检测回复框时必须用。回复框是依附在主窗口上的浮层，
    # 每次截图都把主窗口提到最前会把它压下去，于是永远拍不到、判定成「没弹出」，
    # 然后重试点击 —— 越重试越拍不到。
    $raise = $hwnd
    if ($TopHwnd -ne [IntPtr]::Zero) { $raise = $TopHwnd }
    if (-not $NoActivate) {
        [W32Moments]::ShowWindow($raise, 9) | Out-Null
        [W32Moments]::SetForegroundWindow($raise) | Out-Null
        Start-Sleep -Milliseconds 260
    }
    $r = New-Object W32Moments+RECT
    if (-not [W32Moments]::GetWindowRect($hwnd, [ref]$r)) { throw "GetWindowRect 失败" }
    $w = $r.Right - $r.Left
    $h = $r.Bottom - $r.Top
    if ($w -le 0 -or $h -le 0) { throw "窗口尺寸异常 ${w}x${h}" }
    $offX = [int]($w * $xFracFrom)
    $cw = [int]($w * ($xFracTo - $xFracFrom))
    if ($cw -lt 50) { $cw = $w - $offX }
    $bmp = New-Object System.Drawing.Bitmap $cw, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen(($r.Left + $offX), $r.Top, 0, 0, (New-Object System.Drawing.Size $cw, $h))
    $g.Dispose()
    $script:shotSeq++
    $path = Join-Path $env:TEMP ("moments_ocr_{0}_{1}.png" -f $PID, $script:shotSeq)
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    # Left/Top 跟着偏移走，后面所有「截图坐标 → 屏幕坐标」的换算都不用改
    return [pscustomobject]@{ Path = $path; Left = ($r.Left + $offX); Top = $r.Top; Width = $cw; Height = $h }
}

function Find-GreenButton([string]$path, [double]$xFrac = 0.55, [double]$yFrac = 0.70) {
    # 微信「发送」是白字绿底，OCR 读不出字，但颜色很好认（≈ #07C160）
    $bmp = [System.Drawing.Bitmap]::FromFile($path)
    try {
        $w = $bmp.Width; $h = $bmp.Height
        $x0 = [int]($w * $xFrac); $y0 = [int]($h * $yFrac)
        $rect = New-Object System.Drawing.Rectangle 0, 0, $w, $h
        $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
        $bytes = New-Object byte[] ($data.Stride * $h)
        [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
        $bmp.UnlockBits($data)

        $minX = [int]::MaxValue; $maxX = -1; $minY = [int]::MaxValue; $maxY = -1; $cnt = 0
        for ($y = $y0; $y -lt $h; $y++) {
            $row = $y * $data.Stride
            # 输入框边框也是同一种绿，但它是横贯整行的细线；
            # 按钮是一段 40~130px 宽的实心绿块，用「本行最长连续绿段」把它和边框区分开
            $curStart = -1; $curLen = 0; $bestStart = -1; $bestLen = 0
            for ($x = $x0; $x -lt $w; $x++) {
                $i = $row + $x * 3
                $b = $bytes[$i]; $g = $bytes[$i + 1]; $r = $bytes[$i + 2]
                $isGreen = ($g -gt 150 -and $r -lt 90 -and $b -gt 40 -and $b -lt 160 -and ($g - $r) -gt 80 -and ($g - $b) -gt 40)
                if ($isGreen) {
                    if ($curStart -lt 0) { $curStart = $x; $curLen = 0 }
                    $curLen++
                    if ($curLen -gt $bestLen) { $bestLen = $curLen; $bestStart = $curStart }
                } else {
                    $curStart = -1; $curLen = 0
                }
            }
            if ($bestLen -ge 40 -and $bestLen -le 130) {
                if ($bestStart -lt $minX) { $minX = $bestStart }
                $runEnd = $bestStart + $bestLen - 1
                if ($runEnd -gt $maxX) { $maxX = $runEnd }
                if ($y -lt $minY) { $minY = $y }
                if ($y -gt $maxY) { $maxY = $y }
                $cnt += $bestLen
            }
        }
        if ($cnt -lt 400 -or $maxX -lt 0) { return $null }
        return [pscustomobject]@{
            X = [int](($minX + $maxX) / 2)
            Y = [int](($minY + $maxY) / 2)
            W = ($maxX - $minX + 1)
            H = ($maxY - $minY + 1)
            Cnt = $cnt
        }
    } finally {
        $bmp.Dispose()
    }
}

function Invoke-Ocr([string]$path) {
    $file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($path)) ([Windows.Storage.StorageFile])
    $stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    $decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $sb = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
    $lang = New-Object Windows.Globalization.Language 'zh-Hans-CN'
    $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($lang)
    if (-not $engine) { throw "OCR 引擎创建失败（zh-Hans-CN）" }
    $res = Await ($engine.RecognizeAsync($sb)) ([Windows.Media.Ocr.OcrResult])
    $stream.Dispose()

    $lines = @()
    foreach ($ln in $res.Lines) {
        $minX = [double]::MaxValue; $minY = [double]::MaxValue
        $maxX = 0.0; $maxY = 0.0
        $words = @()
        foreach ($wd in $ln.Words) {
            $rc = $wd.BoundingRect
            if ($rc.X -lt $minX) { $minX = $rc.X }
            if ($rc.Y -lt $minY) { $minY = $rc.Y }
            if (($rc.X + $rc.Width) -gt $maxX) { $maxX = $rc.X + $rc.Width }
            if (($rc.Y + $rc.Height) -gt $maxY) { $maxY = $rc.Y + $rc.Height }
            $words += [pscustomobject]@{ Text = $wd.Text; X = $rc.X; Y = $rc.Y; W = $rc.Width; H = $rc.Height }
        }
        if ($maxX -le 0) { continue }
        $lines += [pscustomobject]@{
            Text  = $ln.Text
            X     = $minX
            Y     = $minY
            W     = $maxX - $minX
            H     = $maxY - $minY
            Words = $words
        }
    }
    return $lines
}

# 放大后 OCR：小窗口里中文太小，2x 放大能显著提升识别率
function Ocr-Window($shot, [double]$scale) {
    $src = [System.Drawing.Bitmap]::FromFile($shot.Path)
    $nw = [int]($src.Width * $scale)
    $nh = [int]($src.Height * $scale)
    $big = New-Object System.Drawing.Bitmap $nw, $nh
    $g = [System.Drawing.Graphics]::FromImage($big)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.DrawImage($src, 0, 0, $nw, $nh)
    $g.Dispose(); $src.Dispose()
    $up = Join-Path $env:TEMP ("moments_ocr_up_{0}_s{1}.png" -f $PID, $script:shotSeq)
    $big.Save($up, [System.Drawing.Imaging.ImageFormat]::Png)
    $big.Dispose()

    $lines = Invoke-Ocr $up
    foreach ($ln in $lines) {
        $ln.X = $ln.X / $scale
        $ln.Y = $ln.Y / $scale
        $ln.W = $ln.W / $scale
        $ln.H = $ln.H / $scale
        # 每行都记住自己那张截图的原点，换算屏幕坐标时不用再猜窗口左上角。
        # 截图可能被裁过（相册/详情页只截右半屏），所以原点不一定是窗口原点。
        $ln | Add-Member -NotePropertyName OX -NotePropertyValue $shot.Left -Force
        $ln | Add-Member -NotePropertyName OY -NotePropertyValue $shot.Top -Force
        if ($ln.Words) {
            foreach ($wd in $ln.Words) {
                $wd.X = $wd.X / $scale
                $wd.Y = $wd.Y / $scale
                $wd.W = $wd.W / $scale
                $wd.H = $wd.H / $scale
            }
        }
    }
    return $lines
}

function Normalize([string]$s) {
    if (-not $s) { return '' }
    $s = $s -replace '[\s\u3000]', ''
    $s = $s -replace '[：:，,。.、！!？?；;（）()\[\]【】]', ''
    return $s.ToLowerInvariant()
}

function Levenshtein([string]$a, [string]$b) {
    if ($a -eq $b) { return 0 }
    $la = $a.Length; $lb = $b.Length
    if ($la -eq 0) { return $lb }
    if ($lb -eq 0) { return $la }
    $prev = New-Object int[] ($lb + 1)
    $cur  = New-Object int[] ($lb + 1)
    for ($j = 0; $j -le $lb; $j++) { $prev[$j] = $j }
    for ($i = 1; $i -le $la; $i++) {
        $cur[0] = $i
        $ca = $a[$i - 1]
        for ($j = 1; $j -le $lb; $j++) {
            $cost = 0
            if ($ca -ne $b[$j - 1]) { $cost = 1 }
            $del = $prev[$j] + 1
            $ins = $cur[$j - 1] + 1
            $sub = $prev[$j - 1] + $cost
            $m = $del
            if ($ins -lt $m) { $m = $ins }
            if ($sub -lt $m) { $m = $sub }
            $cur[$j] = $m
        }
        $tmp = $prev; $prev = $cur; $cur = $tmp
    }
    return $prev[$lb]
}

function Sim([string]$a, [string]$b) {
    if (-not $a -and -not $b) { return 1.0 }
    $max = [Math]::Max($a.Length, $b.Length)
    if ($max -eq 0) { return 1.0 }
    $d = Levenshtein $a $b
    return 1.0 - ([double]$d / [double]$max)
}

# ---------- 评论按钮（「两个点」）定位 ----------
# 朋友圈每条动态右下角有一个「••」按钮，点它才会展开「赞 / 评论」。
# 直接点正文是没有用的 —— 这就是以前"找不到评论按钮"的根因。
#
# 【实测几何】微信 4.1.x / 窗口宽 592 时，按钮是**两个并排的 4x4 实心方块**：
#      y=721 ............-##-....-##-....
#      y=722 ............####....####.....
#      y=723 ............####....####.....
#      y=724 ............-##-....-##-....
#   每块约 4px 宽，两块之间隔 4px，整体 12~14px 宽、4px 高，
#   中心在窗口宽度的 ~91%（x≈539 / 592）。
#
# 【旧判据为什么永远匹配不上】旧代码找「6x6 近似方形、宽高差<=2」的块。
#   这个按钮是 12x4 的长条，宽高差 8，直接被 w/h 判据筛掉 —— 每轮都报
#   「没找到 •• 按钮」。别再把这里改成找 × 形，y≈933 那个 × 是**关闭/删除**，
#   点了会把动态藏起来。
function Find-CommentDot([IntPtr]$hwnd, [int]$rowY, [int]$rowX0, [int]$rowX1, [int]$tol = 60) {
    $r = New-Object W32Moments+RECT
    if (-not [W32Moments]::GetWindowRect($hwnd, [ref]$r)) { return $null }
    $winW = $r.Right - $r.Left
    $winH = $r.Bottom - $r.Top

    $y0 = [Math]::Max(0, $rowY - $tol)
    $y1 = [Math]::Min($winH - 1, $rowY + $tol)

    $bmp = New-Object System.Drawing.Bitmap $winW, $winH
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try { $g.CopyFromScreen($r.Left, $r.Top, 0, 0, $bmp.Size) }
    catch { $g.Dispose(); $bmp.Dispose(); return $null }
    $g.Dispose()

    # 只扫右侧带（按钮贴着正文右边缘），并避开最右 16px 的滚动条。
    # 实测按钮中心在 x≈541/592 = 0.914，所以 0.86~0.97 是最稳的带。
    # 上界不能放到 0.99：标题栏那三个图标（刷新/铃铛/相机）也在这个 x 区间，
    # 宽度/高度判据会把它们误判成 ••（实测在 y<200 冒出 6 个假候选）。
    $wx0 = [int]($winW * 0.86)
    $wx1 = [int]($winW * 0.97)
    $best = $null
    $bestScore = [double]::MinValue

    # 先把这块区域读进内存，避免 GetPixel 的 COM 调用开销
    $pix = New-Object 'int[,]' ($wx1 - $wx0 + 2), ($y1 - $y0 + 2)
    for ($y = $y0; $y -le $y1; $y++) {
        for ($x = $wx0; $x -le $wx1 + 1; $x++) {
            $px = [Math]::Min($x, $winW - 1)
            $c = $bmp.GetPixel($px, $y)
            # 0..255 灰度
            $pix[($x - $wx0), ($y - $y0)] = [int](($c.R + $c.G + $c.B) / 3)
        }
    }
    $bmp.Dispose()

    for ($y = $y0; $y -le $y1; $y++) {
        for ($x = $wx0; $x -le $wx1; $x++) {
            $g0 = $pix[($x - $wx0), ($y - $y0)]
            if ($g0 -gt 170) { continue }   # 方块是深灰 (#4x4 实心)

            # 取 16x6 的窗，数深色像素并求连通块的 x 范围
            $dark = 0; $minX = 99; $maxX = -1; $minY = 99; $maxY = -1
            for ($dy = 0; $dy -lt 6; $dy++) {
                $yy = $y + $dy - $y0
                if ($yy -lt 0 -or $yy -gt ($y1 - $y0)) { continue }
                for ($dx = 0; $dx -lt 16; $dx++) {
                    $xx = $x + $dx - $wx0
                    if ($xx -lt 0 -or $xx -gt ($wx1 - $wx0 + 1)) { continue }
                    if ($pix[($xx), ($yy)] -lt 170) {
                        $dark++
                        if ($dx -lt $minX) { $minX = $dx }
                        if ($dx -gt $maxX) { $maxX = $dx }
                        if ($dy -lt $minY) { $minY = $dy }
                        if ($dy -gt $maxY) { $maxY = $dy }
                    }
                }
            }
            # 「••」：整体 10~16 宽、3~5 高，深色像素 20~40
            if ($dark -lt 18 -or $dark -gt 44) { continue }
            $w = $maxX - $minX + 1
            $h = $maxY - $minY + 1
            if ($w -lt 9 -or $w -gt 18) { continue }
            if ($h -lt 3 -or $h -gt 6) { continue }
            # 必须真的分成两坨：中间那一列要是白的
            $gapX = $x + $minX + [int]($w / 2) - $wx0
            $gapDark = 0
            for ($dy = 0; $dy -lt 6; $dy++) {
                $yy = $y + $dy - $y0
                if ($yy -lt 0 -or $yy -gt ($y1 - $y0)) { continue }
                if ($pix[($gapX), ($yy)] -lt 170) { $gapDark++ }
            }
            if ($gapDark -gt 1) { continue }

            $cx = $x + $minX + [int]($w / 2)
            $cy = $y + $minY + [int]($h / 2)
            $fracX = $cx / [double]$winW
            if ($fracX -lt 0.86 -or $fracX -gt 0.97) { continue }

            # 优先靠近评论行中线的
            $score = -[Math]::Abs($cy - $rowY) - [Math]::Abs($w - 13)
            if ($score -gt $bestScore) {
                $bestScore = $score
                $best = [pscustomobject]@{ X = $r.Left + $cx; Y = $r.Top + $cy; WinX = $cx; WinY = $cy; W = $w; H = $h }
            }
        }
    }
    return $best
}

function Split-CommentLine([string]$text) {
    $idx = $text.IndexOfAny([char[]]@(':', [char]0xFF1A))
    if ($idx -lt 0) { return $null }
    $head = $text.Substring(0, $idx).Trim()
    $body = $text.Substring($idx + 1).Trim()
    if ($head -match '^(.*?)\s*回复\s') { $head = $matches[1].Trim() }
    if (-not $head -or -not $body) { return $null }
    return [pscustomobject]@{ Head = $head; Body = $body }
}

function Find-BestCommentLine($lines, [string]$dbNick, [string]$content, [double]$minY) {
    $nCont = Normalize $content
    $nNick = Normalize $dbNick
    $short = $nCont.Length -lt 5
    $cands = @()

    foreach ($ln in $lines) {
        if ($minY -ge 0 -and $ln.Y -lt $minY) { continue }
        $sp = Split-CommentLine $ln.Text
        if (-not $sp) { continue }
        $nBody = Normalize $sp.Body
        $nHead = Normalize $sp.Head
        if (-not $nBody) { continue }

        $sBody = Sim $nCont $nBody
        $sNick = Sim $nNick $nHead

        if ($short) {
            # 短内容容易撞车，必须昵称也对得上，否则不猜
            if ($sBody -lt 0.70 -or $sNick -lt 0.40) { continue }
            $score = 0.65 * $sBody + 0.35 * $sNick
        } else {
            if ($sBody -lt 0.60) { continue }
            $score = $sBody
        }

        $cands += [pscustomobject]@{
            Line    = $ln
            Score   = $score
            BodySim = $sBody
            NickSim = $sNick
            Display = $sp.Head
            Body    = $sp.Body
        }
    }

    if ($cands.Count -eq 0) { return $null }
    $sorted = $cands | Sort-Object Score -Descending
    if ($sorted.Count -ge 2) {
        if (($sorted[0].Score - $sorted[1].Score) -lt 0.08) {
            Write-Host "[ui] 候选分数太接近，拒绝猜测：" -ForegroundColor Yellow
            foreach ($c in $sorted[0..([Math]::Min(2, $sorted.Count - 1))]) {
                Write-Host ("      {0:N2}  {1}" -f $c.Score, $c.Line.Text) -ForegroundColor Yellow
            }
            return $null
        }
    }
    return $sorted[0]
}

Write-Host "`n[ui] 开始 UI 回复…" -ForegroundColor Cyan

$hwnd = Get-WeChatHwnd
if ($hwnd -eq [IntPtr]::Zero) { throw "找不到微信主窗口（Weixin.exe / 标题「微信」）。请先打开微信。" }
[W32Moments]::ShowWindow($hwnd, 9) | Out-Null
Start-Sleep -Milliseconds 250
[W32Moments]::SetForegroundWindow($hwnd) | Out-Null
Start-Sleep -Milliseconds 500

# 固定窗口尺寸和位置：微信窗口会在 439 / 658 / 787 / 803 / 1180 / 1204 之间反复变，
# 位置也不固定（实测 13,13 → 20,20 → -13,11）。太窄时右侧相册/详情面板铺不开，
# 「置顶/今天/昨天」读不到，流程就挂在这一步。
# 而且窗口会在运行过程中被系统重新摆位 —— 所以每次都强制摆到同一处，
# 并在复位后重新读一次，让所有坐标都落在已知几何上。
$wrFix = New-Object W32Moments+RECT
[W32Moments]::GetWindowRect($hwnd, [ref]$wrFix) | Out-Null
# 可用工作区是 2560x1392（任务栏占掉 48px），所以高度一律收到 1300，绝不超出屏幕。
# 窗口一旦伸出屏幕，底部（回复框、发送按钮）就点不到，OCR 也读不到。
$targetW = 1180
$targetH = 1300
$newX = 20
$newY = 20
$needResize = (($wrFix.Right - $wrFix.Left) -ne $targetW) -or (($wrFix.Bottom - $wrFix.Top) -ne $targetH) -or ($wrFix.Left -ne $newX) -or ($wrFix.Top -ne $newY)
if ($needResize) {
    [W32Moments]::MoveWindow($hwnd, $newX, $newY, $targetW, $targetH, $true) | Out-Null
    Start-Sleep -Milliseconds 1200
    $wrChk = New-Object W32Moments+RECT
    [W32Moments]::GetWindowRect($hwnd, [ref]$wrChk) | Out-Null
    Write-Host ("[ui] 窗口复位 {0}x{1}@{2},{3} → {4}x{5}@{6},{7}" -f `
        ($wrFix.Right - $wrFix.Left), ($wrFix.Bottom - $wrFix.Top), $wrFix.Left, $wrFix.Top, `
        ($wrChk.Right - $wrChk.Left), ($wrChk.Bottom - $wrChk.Top), $wrChk.Left, $wrChk.Top) -ForegroundColor Yellow
}

$wr = New-Object W32Moments+RECT
[W32Moments]::GetWindowRect($hwnd, [ref]$wr) | Out-Null
$winW = $wr.Right - $wr.Left
$winH = $wr.Bottom - $wr.Top
Write-Host "[ui] 微信窗口 ($($wr.Left),$($wr.Top)) ${winW}x${winH}"

$nick = $target.Comment.nickname
$cont = $target.Comment.content

# 目标动态正文前 14 字，用来在相册里认出这条动态
$pc = Normalize (($target.Post.content -replace "`r?`n", ' '))
if ($pc.Length -gt 14) { $pc = $pc.Substring(0, 14) }

$probe = $Text
if ($probe.Length -gt 6) { $probe = $probe.Substring(0, 6) }
$nProbe = Normalize $probe
$nNick = Normalize $nick

# 界面上真正显示的名字（DB 昵称可能被备注名盖住）
$dispNick = Get-DisplayName $nick $target.Comment.username
$nDispNick = Normalize $dispNick
if ($nDispNick -ne $nNick) {
    Write-Host "[ui] 显示名：$nick → $dispNick（按显示名定位评论）" -ForegroundColor Cyan
}

# ---------- 小工具 ----------

function Find-BestLine($lines, [string]$probe, [double]$thr = 0.55) {
    $best = $null; $bestSim = 0.0
    foreach ($ln in $lines) {
        $s = Sim $probe (Normalize $ln.Text)
        if ($s -gt $bestSim) { $bestSim = $s; $best = $ln }
    }
    if ($bestSim -lt $thr) { return $null }
    return [pscustomobject]@{ Line = $best; Score = $bestSim }
}

function Line-Center($ln) {
    return @([int]($ln.OX + $ln.X + $ln.W / 2), [int]($ln.OY + $ln.Y + $ln.H / 2))
}

function Is-TimeLine([string]$t) {
    $x = $t -replace '\s', ''
    return ($x -match '^\d{1,2}[:：]\d{2}$' -or $x -match '^(昨天|前天|今天)?\d{1,2}[:：]\d{2}$')
}

# ---------- 1) 点头像 → 「我的朋友圈」相册 ----------
# 左侧栏最上方的头像是固定位置，比在信息流里往下翻可靠得多。
# ⚠ 但「头像位置固定」只在主聊天列表下成立。左侧导航切到「发现」面板
#   （显示 朋友圈 / 视频号 / 扫一扫 …）时整列元素都会移位，按固定偏移必点空；
#   点空之后旧代码会退回主窗口截图，「朋友圈」这行就误匹配到左侧导航项，
#   接着点到导航上，于是相册永远打不开 —— 实测就是这么一路错下去的。
#   所以：先确认处在聊天列表，再点头像；点完必须真的找到资料卡弹窗，否则直接报错。

function Test-DiscoverPanel($lines) {
    foreach ($ln in $lines) {
        if ($ln.X -gt 220) { continue }        # 只看最左边那一列
        $t = Normalize $ln.Text
        if ($t -like '*视频号*' -or $t -like '*扫一扫*' -or $t -like '*搜一搜*') { return $true }
    }
    return $false
}

# 窗口在运行过程中会被系统重新摆位（实测 1180x1300 → 787x867，高度还会超过屏幕）。
# 头像偏移是按固定几何算的，几何一漂就点空 —— 点头像前再确认一次尺寸和位置。
$wrNow = New-Object W32Moments+RECT
[W32Moments]::GetWindowRect($hwnd, [ref]$wrNow) | Out-Null
if ((($wrNow.Right - $wrNow.Left) -ne $targetW) -or (($wrNow.Bottom - $wrNow.Top) -ne $targetH) -or ($wrNow.Left -ne $newX) -or ($wrNow.Top -ne $newY)) {
    Write-Host ("[ui] 窗口漂成 {0}x{1}@{2},{3}，重新固定" -f ($wrNow.Right - $wrNow.Left), ($wrNow.Bottom - $wrNow.Top), $wrNow.Left, $wrNow.Top) -ForegroundColor Yellow
    [W32Moments]::MoveWindow($hwnd, $newX, $newY, $targetW, $targetH, $true) | Out-Null
    Start-Sleep -Milliseconds 1100
}
$wr = New-Object W32Moments+RECT
[W32Moments]::GetWindowRect($hwnd, [ref]$wr) | Out-Null
$winW = $wr.Right - $wr.Left
$winH = $wr.Bottom - $wr.Top
$sNav = Capture-Window $hwnd
$lNav = Ocr-Window $sNav $OcrScale
if (Test-DiscoverPanel $lNav) {
    Write-Host "[ui] 左侧导航在「发现」面板，先切回聊天列表" -ForegroundColor Yellow
    Click-At ([int]($wr.Left + 40)) ([int]($wr.Top + 130))
    Start-Sleep -Milliseconds 1000
}

# 资料卡要是已经开着，重复点击会把它关掉 —— 先探一次。
$cardHwnd = Get-CardHwnd
if ($cardHwnd -ne [IntPtr]::Zero) { Write-Host "[ui] 资料卡已经开着，跳过点击" -ForegroundColor DarkGray }
# 微信会在被 MoveWindow 之后一两秒内把窗口恢复成自己记住的几何（实测 1180x1300 → 787x867）。
# 所以头像偏移必须按**点击那一刻**的真实矩形算，不能用在流程开头算出来的旧值。
# 实测两种几何下头像圆心占窗口的比例几乎一致：1180x1300 → (0.044,0.073)；787x867 → (0.044,0.075)。
$wr = New-Object W32Moments+RECT
[W32Moments]::GetWindowRect($hwnd, [ref]$wr) | Out-Null
$winW = $wr.Right - $wr.Left
$winH = $wr.Bottom - $wr.Top
Write-Host "[ui] 点击时真实几何 ($($wr.Left),$($wr.Top)) ${winW}x${winH}"

# 实测（窗口 1180x1300@20,20）：头像圆心在窗口内 (52,95)，半径约 22px。
# 旧候选全部擦着圆边，圆角上会点空。
$avatarTries = @(
    @([int]($winW * 0.044), [int]($winH * 0.073)),
    @([int]($winW * 0.044), [int](($winH * 0.073) + 9)),
    @([int]($winW * 0.044), [int](($winH * 0.073) - 9)),
    @([int](($winW * 0.044) - 7), [int]($winH * 0.073)),
    @([int]($winW * 0.044), [int]($winH * 0.075)),
    @(35, 65), @(52, 95), @(46, 88), @(58, 102)
)
foreach ($av in $avatarTries) {
    if ($cardHwnd -ne [IntPtr]::Zero) { break }
    $avatarX = [int]($wr.Left + $av[0])
    $avatarY = [int]($wr.Top + $av[1])
    Write-Host "[ui] 点左侧栏头像 ($avatarX,$avatarY)"
    Click-At $avatarX $avatarY
    # 资料卡是独立弹窗，弹出有延迟；轮询几次再判定，别急着换偏移重点
    # （重点会把已经弹出来的卡又点掉）。
    foreach ($w in 1..5) {
        Start-Sleep -Milliseconds 600
        $cardHwnd = Get-CardHwnd
        if ($cardHwnd -ne [IntPtr]::Zero) { break }
    }
    if ($cardHwnd -ne [IntPtr]::Zero) { break }
    Write-Host "[ui] 资料卡没出来，换个偏移再点" -ForegroundColor Yellow
}

if ($cardHwnd -eq [IntPtr]::Zero) {
    # 以前这里会退回主窗口截图继续跑，结果把左侧导航里的「朋友圈」当成资料卡标签，
    # 点过去什么也不会发生，最后以「没能打开相册」告终，真正的病因被藏了起来。
    throw "点了头像但没弹出个人资料卡（试了 4 个偏移）。不做后续点击，避免误操作。请确认微信主窗口停在聊天列表、且没有别的窗口挡在前面。"
}

# 关键：卡片是 Qt 弹出层，**一失去激活或空闲一两秒就会自己关掉**。
# 之前这里先截图再 OCR（2~3 秒），等算完坐标卡片已经没了，点击落在主窗口聊天列表上，
# 于是一路打开别人的聊天，最后报「没能打开相册」。
# 缩略图位置本来就按卡片矩形算比例，不需要 OCR —— 拿到矩形立刻点。
$wrCard = New-Object W32Moments+RECT
[W32Moments]::GetWindowRect($cardHwnd, [ref]$wrCard) | Out-Null
$cardW = $wrCard.Right - $wrCard.Left
$cardH = $wrCard.Bottom - $wrCard.Top
Write-Host "[ui] 资料卡 $cardHwnd @$($wrCard.Left),$($wrCard.Top) ${cardW}x${cardH}"

if ($DryRunUi) {
    Write-Host "[ui] -DryRunUi 结束，未做进一步点击。"
    return
}

function Test-Album($lines) {
    foreach ($ln in $lines) {
        $t = Normalize $ln.Text
        if ($t -eq '置顶' -or $t -eq '今天' -or $t -eq '昨天') { return $true }
    }
    return $false
}

# 实测标定（卡片 328x335 @60,40，2026-10-27 视觉量取）：
#   缩略图一排的垂直中心 ≈ 屏幕 y=208 → 卡片内比例 (208-40)/335 ≈ 0.50
#   x 从 172 到 345，中心 ≈ 240 → (240-60)/328 ≈ 0.55
# 以前写 0.328（对应 y=150）整整高了 58px，每次点在「朋友圈」标签下方的空白，
# 卡片随即失焦自关，后面的点击全落到主窗口聊天列表，最后报「没能打开相册」。
$cands = @(
    @(0.55, 0.50), @(0.45, 0.50), @(0.65, 0.50),
    @(0.55, 0.55), @(0.55, 0.45), @(0.75, 0.50)
)

$lA = $null
$sA = $null
$mHwnd = [IntPtr]::Zero
for ($ci = 0; $ci -lt $cands.Count; $ci++) {
    if ($ci -gt 0) {
        # 卡片一点就失焦自关，换候选前把卡片重新叫出来。
        Click-At $avatarX $avatarY
        Start-Sleep -Milliseconds 700
        $cardHwnd = Get-CardHwnd
        if ($cardHwnd -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 600; $cardHwnd = Get-CardHwnd }
        if ($cardHwnd -eq [IntPtr]::Zero) { continue }
        $wrCard = New-Object W32Moments+RECT
        [W32Moments]::GetWindowRect($cardHwnd, [ref]$wrCard) | Out-Null
        $cardW = $wrCard.Right - $wrCard.Left
        $cardH = $wrCard.Bottom - $wrCard.Top
    }
    $c = $cands[$ci]
    $tx = [int]($wrCard.Left + $cardW * $c[0])
    $ty = [int]($wrCard.Top + $cardH * $c[1])
    Write-Host ("[ui] 点资料卡缩略图 ({0},{1})  比例 {2},{3}" -f $tx, $ty, $c[0], $c[1])
    Click-At $tx $ty
    Start-Sleep -Milliseconds 2200
    # 「我的朋友圈」在这个版本里嵌进主窗口右半边（主窗口会变宽），先看主窗口。
    $sA = Capture-Window $hwnd 0 1.0
    $lA = Ocr-Window $sA $OcrScale
    if (Test-Album $lA) { break }
    $mHwnd = Get-MomentsHwnd
    if ($mHwnd -ne [IntPtr]::Zero) {
        # 相册是独立窗口（Qt 或 CEF 都可能），必须把它提到最前再截图，
        # 否则 CopyFromScreen 抓到的是压在上面的窗口。
        $sA = Capture-Window $mHwnd 0 1.0 ([IntPtr]::Zero)
        $lA = Ocr-Window $sA $OcrScale
        if (Test-Album $lA) { break }
        # CEF 版相册（Chrome_WidgetWin_0）首帧可能是空的，再等一拍重试。
        Start-Sleep -Milliseconds 900
        $sA = Capture-Window $mHwnd 0 1.0 ([IntPtr]::Zero)
        $lA = Ocr-Window $sA $OcrScale
        if (Test-Album $lA) { break }
    }
}
if (-not (Test-Album $lA)) {
    # 失败时把整窗 OCR 全量写进日志，用几十行文字就能判断当时屏幕上到底是什么，
    # 比再截一张 2560x1440 的图省得多。
    Write-Host "[ui] 相册没识别到。整窗 OCR 全量：" -ForegroundColor Yellow
    foreach ($ln in ($lA | Sort-Object Y)) {
        Write-Host ("   y={0,6:N0} x={1,5:N0}  {2}" -f $ln.Y, $ln.X, $ln.Text)
    }
    throw "没能打开「我的朋友圈」相册。未做任何点击以外的事。"
}
# 相册开在独立「朋友圈」窗口时，后续滚动/找动态都改在这个窗口上做。
if ($mHwnd -ne [IntPtr]::Zero) {
    $hwnd = $mHwnd
    $wr = New-Object W32Moments+RECT
    [W32Moments]::GetWindowRect($hwnd, [ref]$wr) | Out-Null
    $winW = $wr.Right - $wr.Left
    $winH = $wr.Bottom - $wr.Top
    Write-Host "[ui] 相册在独立窗口 $hwnd ($($wr.Left),$($wr.Top)) ${winW}x${winH}" -ForegroundColor Green
}
Write-Host "[ui] 已进入我的朋友圈相册" -ForegroundColor Green

# ---------- 2) 在相册里找到这条动态 ----------
# 相册里只有自己的动态，比全局信息流短得多。
# 正文太短（如「微信小视频」）的匹配不可靠，先失败而不是盲滚 12 屏。

if ($pc.Length -lt 4) {
    throw "这条动态正文只有「$pc」几个字，在相册里没法可靠定位。请用 -List 挑一条文字更长的动态。"
}

$found = $null
for ($k = 0; $k -le 12 -and -not $found; $k++) {
    if ($k -gt 0) {
        Wheel-Down ([int]($wr.Left + $winW * 0.82)) ([int]($wr.Top + $winH * 0.60)) 3
        Start-Sleep -Milliseconds 1200
        $sA = Capture-Window $hwnd 0 1.0
        $lA = Ocr-Window $sA $OcrScale
    }
    foreach ($ln in $lA) {
        $s = Sim $pc (Normalize $ln.Text)
        if ($s -ge 0.55) {
            $found = [pscustomobject]@{ Line = $ln; Score = $s }
            break
        }
    }
    if ($found) { Write-Host "[ui] 相册下滚第 $k 次后找到目标动态（相似 $([Math]::Round($found.Score,2))）" -ForegroundColor Green }
}
if (-not $found) { throw "在「我的朋友圈」相册里没找到这条动态「$pc…」。未做任何点击以外的事。" }

$postLine = $found.Line
Write-Host ("[ui] 目标动态行 y={0} x={1}" -f [int]$postLine.Y, [int]$postLine.X)

# ---------- 3) 点动态正文 → 详情页 ----------

$px = [int]($postLine.OX + $postLine.X + [Math]::Min($postLine.W * 0.5, 120))
$py = [int]($postLine.OY + $postLine.Y + $postLine.H / 2)
Write-Host "[ui] 点动态正文开详情 ($px,$py)"
Click-At $px $py
Start-Sleep -Milliseconds 2200

function Test-DetailPage {
    $s = Capture-Window $hwnd 0 1.0
    $ls = Ocr-Window $s $OcrScale
    foreach ($ln in $ls) { if ((Normalize $ln.Text) -match '^详情') { return $ls } }
    return $null
}

$linesD = Test-DetailPage
if (-not $linesD) { throw "点了动态但没打开「详情」页。未做任何点击以外的事。" }
Write-Host "[ui] 已进入详情页" -ForegroundColor Green

# ---------- 4) 定位这条评论 ----------
# 详情页在窗口右半边。
# 关键：按【评论正文】定位，不按昵称 —— DB 里存的是原始昵称，
# 界面上很可能显示备注名（例如 DB 的「真由理」在界面上叫「南华」）。

$paneX = 0   # 截图已经裁成右半屏，X 从 0 开始，不再需要按窗口宽度过滤

$nCont = Normalize (($cont -replace "`r?`n", ' '))
if ($nCont.Length -gt 24) { $nCont = $nCont.Substring(0, 24) }

function Find-CommentRow($lines) {
    $paneLines = @($lines | Where-Object { $_.X -ge $paneX })

    # ---- A) 首选：按【界面显示名】定位作者行 ----
    # 显示名是界面上真印着的那几个字（南华 / 高一健身李帅佐），
    # 一条评论只有一行能对上，短评论也不会串到隔壁那条。
    if ($nDispNick -and $nDispNick.Length -ge 2) {
        $best = $null; $bestS = 0.0
        foreach ($ln in $paneLines) {
            $t = Normalize $ln.Text
            if ($t.Length -lt 2) { continue }
            $s = if ($t -eq $nDispNick) { 1.0 } else { Sim $nDispNick $t }
            if ($s -gt $bestS) { $bestS = $s; $best = $ln }
        }
        if ($best -and $bestS -ge 0.80) {
            $body = $null; $bd = 9999
            foreach ($ln in $paneLines) {
                if ($ln.Y -le ($best.Y + 6)) { continue }
                $d = $ln.Y - $best.Y
                if ($d -gt 60) { continue }
                if ($d -lt $bd) { $bd = $d; $body = $ln }
            }
            if ($body) {
                $timeLn = $null
                foreach ($ln in $paneLines) {
                    if ([Math]::Abs($ln.Y - $best.Y) -gt 8) { continue }
                    if (-not (Is-TimeLine $ln.Text)) { continue }
                    if ($null -eq $timeLn -or $ln.X -gt $timeLn.X) { $timeLn = $ln }
                }
                return [pscustomobject]@{
                    Body = $body; Name = $best; Time = $timeLn
                    RowY = [int]$best.Y; Score = $bestS; By = 'name'
                }
            }
        }
    }

    # ---- B) 兜底：按评论正文模糊匹配（显示名没查到/OCR 没读出作者行时）----
    $body = $null; $bestS = 0.0
    foreach ($ln in $lines) {
        if ($ln.X -lt $paneX) { continue }
        $t = Normalize $ln.Text
        if ($t.Length -lt 2) { continue }
        # 楼中楼的整行是「回复 <某人>：<正文>」，正文被包在里面。
        # 先整行包含判断，再把冒号后面的部分单独比一次 —— OCR 常把小字
        # 认错（「有意思」→「有琶思」），只比正文那一截会把误差摊薄。
        # 注意：Normalize 会把冒号去掉，所以这里要在原始文本上切。
        $cand = $t
        $raw = [string]$ln.Text
        $ci = $raw.LastIndexOf('：')
        if ($ci -lt 0) { $ci = $raw.LastIndexOf(':') }
        if ($ci -ge 0 -and $raw.Length -gt ($ci + 1)) { $cand = Normalize ($raw.Substring($ci + 1)) }

        if ($nCont.Length -ge 2 -and $cand.Contains($nCont)) {
            $body = $ln; $bestS = 1.0; break
        }
        $s = Sim $nCont $cand
        if ($s -gt $bestS) { $bestS = $s; $body = $ln }
    }
    if ($bestS -lt 0.55) { return $null }
    # 2) 正文正上方最近的那一行是「昵称 …… 时间」。
    #    昵称和时间是同一 Y 上的两个独立 OCR 块，必须分开取：
    #    否则会把「昨天12:21」当成昵称，算出来的空白位置整条都错。
    #    作者行只在正文上方约 24px；往上找得太远会抓到上一条评论，
    #    结果回复到别人头上。所以限制在 40px 内，找不到就用固定偏移。
    $rowY = $null
    foreach ($ln in $lines) {
        if ($ln.X -lt $paneX) { continue }
        if ($ln.Y -ge $body.Y) { continue }
        if (($body.Y - $ln.Y) -gt 40) { continue }
        if ($null -eq $rowY -or $ln.Y -gt $rowY) { $rowY = $ln.Y }
    }
    if ($null -eq $rowY -or ($body.Y - $rowY) -lt 12) { $rowY = $body.Y - 24 }

    $nameLn = $null; $timeLn = $null
    foreach ($ln in $lines) {
        if ($ln.X -lt $paneX) { continue }
        if ([Math]::Abs($ln.Y - $rowY) -gt 8) { continue }
        if (Is-TimeLine $ln.Text) {
            if ($null -eq $timeLn -or $ln.X -gt $timeLn.X) { $timeLn = $ln }
        } else {
            if ($null -eq $nameLn -or $ln.X -lt $nameLn.X) { $nameLn = $ln }
        }
    }
    return [pscustomobject]@{ Body = $body; Name = $nameLn; Time = $timeLn; RowY = $rowY; Score = $bestS; By = 'content' }
}

$row = Find-CommentRow $linesD
if (-not $row) {
    # 详情页会记住上次滚到的位置，目标评论可能在视野上方。
    # 先滚到顶再看一遍，然后才往下逐段找。
    Wheel-Up ([int]($wr.Left + $winW * 0.80)) ([int]($wr.Top + $winH * 0.55)) 10
    Start-Sleep -Milliseconds 1300
    $s = Capture-Window $hwnd 0 1.0
    $linesD = Ocr-Window $s $OcrScale
    $row = Find-CommentRow $linesD
    if ($row) { Write-Host "[ui] 滚到详情页顶部后找到评论" -ForegroundColor Green }
}
if (-not $row) {
    for ($k = 1; $k -le 8 -and -not $row; $k++) {
        Wheel-Down ([int]($wr.Left + $winW * 0.80)) ([int]($wr.Top + $winH * 0.55)) 2
        Start-Sleep -Milliseconds 1100
        $s = Capture-Window $hwnd 0 1.0
        $linesD = Ocr-Window $s $OcrScale
        $row = Find-CommentRow $linesD
        if ($row) { Write-Host "[ui] 详情页下滚第 $k 次后找到评论" -ForegroundColor Green }
    }
}
if (-not $row) { throw "详情页里没定位到评论「$cont」。未做任何点击以外的事。" }

$nickLine = $row.Name
$rowY = [int]$row.RowY
$how = if ($row.By -eq 'name') { '按显示名' } else { '按正文（兜底）' }
if ($nickLine) {
    Write-Host ("[ui] {0} 定位：评论正文 y={1} / 作者行 y={2}「{3}」相似={4:N2}" -f $how, [int]$row.Body.Y, $rowY, (Normalize $nickLine.Text), $row.Score)
    Write-Host ("[ui] 作者行 x={0} w={1}" -f [int]$nickLine.X, [int]$nickLine.W)
} else {
    Write-Host ("[ui] {0} 定位：评论正文 y={1} / OCR 没读出作者行，按日期左端避让" -f $how, [int]$row.Body.Y) -ForegroundColor Yellow
}

# ---------- 5) 点「名字右边那道空白」打开回复框 ----------
# 点昵称会弹资料卡；点日期没反应；点两者之间的空白才会弹底部回复框。

$dateLine = $row.Time
if (-not $dateLine) {
    foreach ($ln in $linesD) {
        if ($ln.X -lt $paneX) { continue }
        if (-not (Is-TimeLine $ln.Text)) { continue }
        if ([Math]::Abs($ln.Y - $rowY) -le 16) { $dateLine = $ln; break }
    }
}

$dateLeft = 0
if ($dateLine) { $dateLeft = [int]($dateLine.OX + $dateLine.X) }
$nameRight = 0
if ($nickLine) { $nameRight = [int]($nickLine.OX + $nickLine.X + $nickLine.W) }

if ($dateLeft -gt 0) {
    # 名字长短不一，按名字算容易点到名字上（会弹资料卡）。
    # 时间戳位置是固定的，统一固定在时间戳左边一点，最稳。
    $clickX = $dateLeft - 34
    Write-Host "[ui] 固定点时间戳左侧空白：日期左端=$dateLeft → ($clickX)"
} else {
    $clickX = [int]($wr.Left + $winW * 0.82)
    Write-Host "[ui] 没读到日期，按几何取名字右侧（$clickX）" -ForegroundColor Yellow
}
# 截图原点必须取自真正的 OCR 行（$row 只是包装对象，没有 OX/OY）。
# 取错了会少掉窗口偏移，整行点偏到上一条评论上。
$rowOX = 0; $rowOY = 0
if ($nickLine) { $rowOX = $nickLine.OX; $rowOY = $nickLine.OY }
elseif ($dateLine) { $rowOX = $dateLine.OX; $rowOY = $dateLine.OY }
elseif ($row.Body) { $rowOX = $row.Body.OX; $rowOY = $row.Body.OY }
$clickY = [int]($rowOY + $rowY + 2)
Write-Host "[ui] 点名字右边空白 ($clickX,$clickY)"
Click-At $clickX $clickY
# 回复框弹出有动画；单次 OCR 常读到旧画面，必须轮询到占位字/发送真正出现。
function Test-ReplyBox {
    $s = Capture-Window $hwnd 0 1.0 -NoActivate
    $ls = Ocr-Window $s $OcrScale
    $bottomMin = $s.Height * 0.60
    # 「朋友圈」详情页嵌在主窗口**右半边**；左边是聊天区，它的底部也有输入框和「发送」。
    # 不加这道坎，就会把聊天输入框当成朋友圈回复框——2026-10-27 因此把一句话错发进了
    # 「外卖券助手」会话。所有判定一律要求绝对 x 落在右半区。
    # 0.66 是按「详情页嵌在主窗口右半边」估的。但详情页实际上经常是**独立顶层窗口**
# （实测 Weixin 540x1164@667,140），内容从窗口 53% 处就开始，用 0.66 会把
# 输入框里刚打进去的文字过滤掉，于是误判「没看到文字」。0.53 两种形态都能包住。
$paneAbs = $wr.Left + $winW * 0.53
    foreach ($ln in $ls) {
        if ($ln.Y -lt $bottomMin) { continue }
        if (($ln.OX + $ln.X) -lt $paneAbs) { continue }
        if ((Normalize $ln.Text) -eq '发送') { return [pscustomobject]@{ Ok = $true; Kind = 'send'; Line = $ln; All = $ls } }
    }
    # 占位字「回复 <昵称>」在窗口最底部，而且不带冒号。
    # 这里【完全不看文字内容】—— 实测 OCR 会把它读成
    #   「回源」「回过源」「丨回原kagami」「回复 源」…… 千奇百怪，
    # 任何基于文字前缀的判据都会漏判（漏判的代价是重试点击，反而把框点没了）。
    # 所以只按「位置 + 形状」认：底部最靠下、不是「发送」、原文不带冒号、长度 ≤24 的那一行。
    # 评论区里带「回复 X：内容」的行都有冒号且位置更高，不会被选中。
    $best = $null
    foreach ($ln in $ls) {
        if ($ln.Y -lt ($s.Height * 0.60)) { continue }
        if (($ln.OX + $ln.X) -lt $paneAbs) { continue }
        $t = Normalize $ln.Text
        if (-not $t) { continue }
        if ($t -eq '发送') { continue }
        if ($ln.Text.Contains('：') -or $ln.Text.Contains(':')) { continue }
        if ($t.Length -gt 24) { continue }
        if ($null -eq $best -or $ln.Y -gt $best.Y) { $best = $ln }
    }
    if ($best) { return [pscustomobject]@{ Ok = $true; Kind = 'placeholder'; Line = $best; All = $ls } }
    return [pscustomobject]@{ Ok = $false; All = $ls }
}

$box = $null
for ($try = 0; $try -lt 6; $try++) {
    Start-Sleep -Milliseconds 450
    $box = Test-ReplyBox
    if ($box.Ok) { break }
}
if (-not $box.Ok) {
    Write-Host "[ui] 第一次点击没弹出回复框，换位置再试" -ForegroundColor Yellow
    # 评论行只有十几像素高，绝对坐标稍有漂移就会点进行间空隙。
    # 所以纵向 ±6 / ±12 都试一遍，再横向往右挪。
    $retry = @(
        @($clickX, ($clickY - 6)),
        @($clickX, ($clickY + 6)),
        @($clickX, ($clickY - 12)),
        @($clickX, ($clickY + 12)),
        @(([int]($nameRight + 40)), $clickY),
        @(([int]($nameRight + 40)), ($clickY - 6)),
        @(([int]($wr.Left + $winW * 0.88)), $clickY)
    )
    foreach ($pt in $retry) {
        Click-At $pt[0] $pt[1]
        Start-Sleep -Milliseconds 900
        $box = Test-ReplyBox
        if ($box.Ok) { Write-Host "[ui] 重试命中 ($($pt[0]),$($pt[1]))" -ForegroundColor Green; break }
    }
}
if (-not $box.Ok) { throw "点了名字右边空白但没弹出回复输入框。未发送任何内容。" }
Write-Host "[ui] 回复框已弹出（判据: $($box.Kind)）" -ForegroundColor Green
if ($box.Kind -eq 'placeholder') {
    # 占位字是「回复 <界面上显示的名字>」，正好用来核对有没有点错人。
    # 显示名已经查到了（$dispNick），这里就能做硬校验：对不上就不发。
    # ⚠ OCR 会把「回复 源」读成「回过源」「回源」之类（多字/丢字），
    #    所以前缀只剥「回复」/「回」，并且允许整行包含目标显示名。
    $phRaw = Normalize $box.Line.Text
    $phName = $phRaw
    if ($phName.StartsWith('回复')) { $phName = $phName.Substring(2) }
    elseif ($phName.StartsWith('回')) { $phName = $phName.Substring(1) }
    Write-Host "[ui] 回复对象：$phName" -ForegroundColor Cyan
    $phSim = if ($nDispNick) { Sim $nDispNick $phName } else { Sim $nNick $phName }
    # OCR 噪声导致相似度偏低时，只要整行里出现了目标显示名，就算点对了。
    $wantName = if ($nDispNick) { Normalize $nDispNick } else { Normalize $nNick }
    if ($wantName -and $phRaw.Contains($wantName)) { $phSim = 1.0 }
    # 占位字本身经常被 OCR 读烂（`丨回原kagami`、`回过源`…），但**绝不能因此放行**。
    # 2026-10-27 就是因为「显示名匹配上了就继续」，占位字明明读成「红包」也照发，
    # 结果把一句话错发进了聊天会话。教训：占位字对不上，一律不发。
    if ($phSim -lt 0.50) {
        # 占位字很小、OCR 常读成「0」「17℃7」这种垃圾，上面的阈值会误杀。
        # 放 3 倍重读一次底部区域，确实在里面看到目标名字才放行（仍然不放过读错人）。
        $cmpName = if ($nDispNick) { $nDispNick } else { $nNick }
        $s3 = Capture-Window $hwnd 0 1.0 -NoActivate
        $l3 = Ocr-Window $s3 3.0
        $hit3 = $false
        foreach ($ln3 in $l3) {
            if ($ln3.Y -lt ($s3.Height * 0.55)) { continue }
            $t3 = Normalize $ln3.Text
            if ($wantName -and $t3.Contains($wantName)) { $hit3 = $true; break }
            $n3 = $t3
            if ($n3.StartsWith('回复')) { $n3 = $n3.Substring(2) }
            elseif ($n3.StartsWith('回')) { $n3 = $n3.Substring(1) }
            if ($n3 -and (Sim $cmpName $n3) -ge 0.50) { $hit3 = $true; break }
        }
        if ($hit3) {
            Write-Host "[ui] 占位字读不清，但放大重读确认回复对象是「$cmpName」，继续" -ForegroundColor Green
            $phSim = 1.0
        }
    }
    if ($phSim -lt 0.50) {
        Write-Host ("[ui] 回复对象「{0}」与目标「{1}」不符（相似 {2:N2}），已放弃发送，一个字都没发。" -f $phName, $dispNick, $phSim) -ForegroundColor Red
        Write-Host "[ui] 可能是点到了别的评论，或回复框根本不在朋友圈右半区。请人工确认。" -ForegroundColor Yellow
        exit 2
    }
}

# ---------- 6) 先用「发送」按钮反推输入区，再输入文字 ----------
# 以前优先用占位字中心，但占位字 OCR 常读成乱码（实测读成「17℃7」）、位置也可能落到
# 别的控件上（给出过 (238,1302)——那是主窗口左侧聊天区的坐标），文字于是全打进了聊天框，
# 「发送」自然也找不到。改用「发送按钮在右下、输入区在它左上方」这个稳定几何反推。
$boxShot = Capture-Window $hwnd 0 1.0 -NoActivate
$boxLines = Ocr-Window $boxShot $OcrScale

$preSendX = $null; $preSendY = $null
$paneAbs2 = $wr.Left + $winW * 0.53
foreach ($ln in ($boxLines | Sort-Object Y -Descending)) {
    if ($ln.Y -lt ($boxShot.Height * 0.60)) { continue }
    if (($ln.OX + $ln.X) -lt $paneAbs2) { continue }
    if ((Normalize $ln.Text) -eq '发送') {
        $c = Line-Center $ln
        $preSendX = $c[0]; $preSendY = $c[1]
        Write-Host "[ui] 发送按钮来自 OCR ($preSendX,$preSendY)"
        break
    }
}
if ($null -eq $preSendX) {
    $gb = Find-GreenButton $boxShot.Path
    if ($gb -and ($boxShot.Left + $gb.X) -ge $paneAbs2) {
        $preSendX = [int]($boxShot.Left + $gb.X)
        $preSendY = [int]($boxShot.Top + $gb.Y)
        Write-Host ("[ui] 发送按钮来自绿色扫描 ({0},{1})" -f $preSendX, $preSendY) -ForegroundColor Green
    }
}

if ($null -ne $preSendX) {
    $inputX = $preSendX - 200
    $inputY = $preSendY - 15
    Write-Host "[ui] 输入区按发送按钮反推 ($inputX,$inputY)"
} elseif ($box.Kind -eq 'placeholder') {
    $inputX = [int]($wr.Left + $winW * 0.72)
    $inputY = [int]($wr.Bottom - 46)
    Write-Host "[ui] 输入区按底部几何 ($inputX,$inputY)（占位字坐标不可靠，已弃用）" -ForegroundColor Yellow
} else {
    $inputX = [int]($wr.Left + $winW * 0.72)
    $inputY = [int]($wr.Top + $winH * 0.88)
    Write-Host "[ui] 输入区按几何 ($inputX,$inputY)" -ForegroundColor Yellow
}
# 限幅：越界点击会落到别的窗口/控件上，比点偏更糟。
if ($inputX -lt $paneAbs2) { $inputX = [int]$paneAbs2 + 30 }
if ($inputX -gt ($wr.Right - 20)) { $inputX = $wr.Right - 20 }
if ($inputY -lt ($wr.Top + 20)) { $inputY = $wr.Top + 20 }
if ($inputY -gt ($wr.Bottom - 12)) { $inputY = $wr.Bottom - 12 }
$paneAbs3 = $wr.Left + $winW * 0.53
$textThr = if ($nProbe.Length -le 5) { 0.55 } else { 0.70 }
$textOk = $false
$shot2 = $null; $lines2 = @()
# 回复框贴在右半屏最底部，但占位字 OCR 极不可靠（实测把评论区「B站 BV1jF411B7sw」那行当成占位字，
# 于是把字打进了空白处）。改为「先按底部几何点，看不到字就上下挪一点重试」。
$inputYBase = if ($box.Kind -eq 'placeholder') { [int]($wr.Bottom - 46) } else { $inputY }
foreach ($dy in @(0, -26, 26, -52, 52, -78)) {
    $tryX = $inputX
    $tryY = [int]($inputYBase + $dy)
    if ($tryY -lt ($wr.Top + 20)) { continue }
    if ($tryY -gt ($wr.Bottom - 14)) { continue }
    Write-Host "[ui] 尝试输入区 ($tryX,$tryY)" -ForegroundColor DarkGray
    Click-At $tryX $tryY
    Start-Sleep -Milliseconds 800
    Send-Txt $Text
    Start-Sleep -Milliseconds 900
    $shot2 = Capture-Window $hwnd 0 1.0 -NoActivate
    $lines2 = Ocr-Window $shot2 $OcrScale
    foreach ($ln in $lines2) {
        if ($ln.Y -lt ($shot2.Height * 0.60)) { continue }
        if (($ln.OX + $ln.X) -lt $paneAbs3) { continue }
        $n = Normalize $ln.Text
        if ($nProbe -and ($n.Contains($nProbe) -or (Sim $nProbe $n) -ge $textThr)) { $textOk = $true; break }
    }
    if ($textOk) { break }
}
if ($textOk) {
    Write-Host "[ui] 输入框里已看到文字" -ForegroundColor Green
} else {
    # 以前这里是「警告…仍尝试发送」，结果文字其实打进了别处也照发不误。
    # 看不到文字就说明输入区没点对，必须停下。
    throw "输入框里没看到刚输入的文字，未发送。请人工检查。"
}

# ---------- 7) 点「发送」 ----------

$sendX = $null; $sendY = $null
foreach ($ln in ($lines2 | Sort-Object Y -Descending)) {
    if ($ln.Y -lt ($shot2.Height * 0.6)) { continue }
    if (($ln.OX + $ln.X) -lt $paneAbs3) { continue }
    if ((Normalize $ln.Text) -eq '发送') {
        $c = Line-Center $ln
        $sendX = $c[0]; $sendY = $c[1]
        Write-Host "[ui] 发送按钮来自 OCR"
        break
    }
}
if ($null -eq $sendX) {
    $gb = Find-GreenButton $shot2.Path
    if ($gb -and ($shot2.Left + $gb.X) -ge $paneAbs3) {
        $sendX = [int]($shot2.Left + $gb.X)
        $sendY = [int]($shot2.Top + $gb.Y)
        Write-Host ("[ui] 发送按钮来自绿色扫描 ({0},{1})" -f $sendX, $sendY) -ForegroundColor Green
    }
}
if ($null -eq $sendX -and $null -ne $preSendX) {
    # 打字前后按钮位置不变，前面已经量到过就直接沿用。
    $sendX = $preSendX; $sendY = $preSendY
    Write-Host "[ui] 沿用前面定位到的发送按钮坐标"
}
if ($null -eq $sendX) { throw "没找到「发送」按钮。未发送，请人工检查。" }

Write-Host "[ui] 点「发送」($sendX,$sendY)"
Click-At $sendX $sendY
Start-Sleep -Milliseconds 2000

$ledger[$key] = [pscustomobject]@{
    at       = (Get-Date).ToString('s')
    text     = $Text
    nickname = $nick
    display  = $nick
    comment  = ($cont -replace "`r?`n", ' ')
}
Save-Ledger $ledger

$sentOk = $false
try {
    $shot3 = Capture-Window $hwnd 0 1.0 -NoActivate
    if ($shot3 -and $shot3.Path) {
        $lines3 = Ocr-Window $shot3 $OcrScale
        # 成功的标志是评论区里冒出「回复 X：<刚发的话>」这一行。
        # 不能只看「底部还有没有这句话」—— 发送成功后那行新评论本身就在底部。
        foreach ($ln in $lines3) {
            $n3 = Normalize $ln.Text
            if (-not $n3.StartsWith('回复')) { continue }
            $raw3 = [string]$ln.Text
            $ci3 = $raw3.LastIndexOf('：')
            if ($ci3 -lt 0) { $ci3 = $raw3.LastIndexOf(':') }
            if ($ci3 -ge 0 -and $raw3.Length -gt ($ci3 + 1)) {
                $tail3 = Normalize ($raw3.Substring($ci3 + 1))
            } else { $tail3 = $n3 }
            if ($tail3.Contains($nProbe) -or (Sim $nProbe $tail3) -ge 0.60) { $sentOk = $true; break }
        }
    }
} catch {
    Write-Host "[ui] 发送后校验已跳过：$($_.Exception.Message)" -ForegroundColor Yellow
}

if ($sentOk) {
    Write-Host "[ui] 已在评论区看到这条回复，发送成功" -ForegroundColor Green
} else {
    Write-Host "[ui] 警告：没在评论区看到新回复，请人工确认" -ForegroundColor Yellow
}

# 发完不按 Esc。实测在详情页里按 Esc 收不掉回复框，而且历史上 Esc 曾把微信搞成白屏
# 被迫重启。回复框留着不影响下一条：脚本总是从相册重新进来，坐标每轮实时算。
try {
    $after = Test-ReplyBox
    if ($after.Ok) {
        Write-Host "[ui] 回复框仍开着。不按 Esc（有把微信搞崩的前科），下一条会从相册重新进来，不受影响。" -ForegroundColor DarkGray
    }
} catch { }

Write-Host "[ui] 完成：已回复 $nick" -ForegroundColor Green
