# 把一条 B 站视频分享成朋友圈：拉封面 -> 发朋友圈 -> 补一条带 BV 号的评论
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File bili-share-to-moments.ps1 `
#       -Bvid "BV1Q7AjzdEQn" -Text "配文" [-DryRun]
#
# 说明：
#   - 朋友圈必须配图，这里用视频封面当图（比贴链接更不容易被折叠）。
#   - 发完后自动在自己那条动态下补一条评论，内容是「B站 BV号」。
#   - 全程不依赖模型看图：定位靠 Windows OCR + 像素扫描。

param(
    [Parameter(Mandatory = $true)][string]$Bvid,
    [string]$Text = '',
    [switch]$DryRun,
    [switch]$NoComment,
    [switch]$CommentOnly
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$postScript  = Join-Path $here 'wechat-moments-post.ps1'
$probeScript = Join-Path $here 'wx_ocr_probe.ps1'
$clickScript = Join-Path $here 'wx_click.ps1'
$greenScript = Join-Path $here 'wx_find_green2.ps1'

function Step($msg) { Write-Host ("  [share] " + $msg) }

# ---------- 1. 取封面 ----------
$cover = Join-Path $env:TEMP ("moments_cover_{0}.jpg" -f $Bvid)
$meta = Join-Path $env:TEMP ("moments_meta_{0}.json" -f $Bvid)

# 找 node：先问 PATH，再扫 DSH / WeChatAgent 自带的 runtime。
$node = $null
$nodeCands = New-Object System.Collections.Generic.List[string]
$cmd = Get-Command node.exe -ErrorAction SilentlyContinue
if ($cmd) { $nodeCands.Add($cmd.Source) | Out-Null }
foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA)) {
    if (-not $base) { continue }
    $nodeCands.Add((Join-Path $base 'nodejs\node.exe')) | Out-Null
}
$shallow = @()
foreach ($d in (Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -match '^[A-Za-z]:\\$' })) {
    $shallow += (Join-Path $d.Root 'data\runtimes')
}
foreach ($root in $shallow) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { $nodeCands.Add((Join-Path $_.FullName 'node.exe')) | Out-Null }
}
foreach ($cand in $nodeCands) { if ($cand -and (Test-Path -LiteralPath $cand)) { $node = $cand; break } }
if (-not $node) { throw '找不到 node.exe。请把 node 加到 PATH，或在本脚本第 34 行附近追加路径。' }

$fetchJs = Join-Path $env:TEMP 'moments_fetch_cover.cjs'
$js = @'
const fs = require('fs');
(async () => {
  const bvid = process.argv[2], out = process.argv[3], meta = process.argv[4];
  const headers = { 'User-Agent': 'Mozilla/5.0', 'Referer': 'https://www.bilibili.com/' };
  const r = await fetch(`https://api.bilibili.com/x/web-interface/view?bvid=${bvid}`, { headers });
  const j = await r.json();
  if (j.code !== 0) { console.log('VIEW-FAIL ' + j.code + ' ' + j.message); process.exit(2); }
  const d = j.data;
  const info = { bvid, title: d.title, owner: d.owner.name, duration: d.duration, pic: d.pic };
  fs.writeFileSync(meta, JSON.stringify(info, null, 2));
  const img = await fetch(d.pic, { headers });
  const buf = Buffer.from(await img.arrayBuffer());
  fs.writeFileSync(out, buf);
  console.log('TITLE  : ' + d.title);
  console.log('OWNER  : ' + d.owner.name);
  console.log('SAVED  : ' + out + ' (' + buf.length + ' bytes)');
})();
'@
[System.IO.File]::WriteAllText($fetchJs, $js, [System.Text.UTF8Encoding]::new($false))

if ($CommentOnly) {
    Step '只补评论（-CommentOnly）：跳过拉封面与发帖'
} else {
if (-not $node) { throw '找不到 node.exe，无法拉取封面' }
Step "拉取 $Bvid 的封面"
& $node $fetchJs $Bvid $cover $meta
if ($LASTEXITCODE -ne 0) { throw "拉封面失败（exit $LASTEXITCODE）" }
if (-not (Test-Path $cover)) { throw '封面没下载下来' }

$info = $null
if (Test-Path $meta) { $info = Get-Content -LiteralPath $meta -Raw -Encoding UTF8 | ConvertFrom-Json }
$title = if ($info) { $info.title } else { '' }
$owner = if ($info) { $info.owner } else { '' }

if (-not $Text) {
    $Text = if ($title) { "B站刷到：$title" } else { 'B站刷到个不错的' }
}
Step "配文：$Text"

if ($DryRun) {
    Step 'DryRun：不实际发布'
    Write-Host ("cover=$cover`ntitle=$title`nowner=$owner`ntext=$Text")
    return
}

# ---------- 2. 发朋友圈 ----------
Step '发布朋友圈'
& powershell -NoProfile -ExecutionPolicy Bypass -File $postScript -Image $cover -Text $Text
if ($LASTEXITCODE -ne 0) { throw "发朋友圈失败（exit $LASTEXITCODE）" }
Step '朋友圈已发布'
Start-Sleep -Milliseconds 1200
}

if ($NoComment) { Step '跳过补评论（-NoComment）'; return }

# ---------- 3. 在自己动态下补一条 BV 评论 ----------
$commentText = "B站 $Bvid"
Step "补评论：$commentText"

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

function Click-Win([int]$x, [int]$y, [int]$wait = 900) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $clickScript -X $x -Y $y -WaitMs $wait | Out-Null
}

# 找到自己那条动态的「评论」动作按钮：文案首 6 个字所在行下方最近的一个「评论」
$probe = $Text
if ($probe.Length -gt 6) { $probe = $probe.Substring(0, 6) }
$anchor = $null
$lines = Get-OcrLines 0
foreach ($ln in $lines) {
    if ($ln.Text -and ($ln.Text -like "*$probe*" -or $probe -like "*$($ln.Text)*")) { $anchor = $ln; break }
}
if (-not $anchor) { throw "没在屏幕上找到刚发的动态正文（找的是「$probe」）" }
Step ("动态定位到 y=" + $anchor.Y)

$btn = $null
foreach ($ln in $lines) {
    if ($ln.Text -eq '评论' -and $ln.Y -gt $anchor.Y -and $ln.Y -lt ($anchor.Y + 220)) {
        if (-not $btn -or ($ln.Y - $anchor.Y) -lt ($btn.Y - $anchor.Y)) { $btn = $ln }
    }
}
if (-not $btn) { throw '没找到「评论」按钮' }
Step ("评论按钮 (" + ($btn.X + [int]($btn.W / 2)) + ',' + ($btn.Y + [int]($btn.H / 2)) + ")")

Click-Win ($btn.X + [int]($btn.W / 2)) ($btn.Y + [int]($btn.H / 2)) 1200

# 输入评论
Add-Type -AssemblyName System.Windows.Forms
Start-Sleep -Milliseconds 300
[System.Windows.Forms.SendKeys]::SendWait($commentText)
Start-Sleep -Milliseconds 800

# 找绿色发送按钮
$greenOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $greenScript -Y0 500 -Y1 990 2>&1
$rows = @()
foreach ($raw in $greenOut) {
    $s = [string]$raw
    if ($s -match 'y=\s*(\d+)\s+n=\s*(\d+)\s+x=(\d+)\.\.(\d+)') {
        $ny = [int]$Matches[1]; $n = [int]$Matches[2]
        $x0 = [int]$Matches[3]; $x1 = [int]$Matches[4]
        if ($x0 -gt 430 -and $n -gt 40) { $rows += [pscustomobject]@{ Y = $ny; X0 = $x0; X1 = $x1; N = $n } }
    }
}
if ($rows.Count -eq 0) { throw '没找到绿色发送按钮' }
$ys = $rows | Measure-Object -Property Y -Minimum -Maximum
$cx = [int]((($rows | Measure-Object -Property X0 -Minimum).Minimum + ($rows | Measure-Object -Property X1 -Maximum).Maximum) / 2)
$cy = [int](($ys.Minimum + $ys.Maximum) / 2)
Step ("发送按钮 ($cx,$cy)")

for ($i = 0; $i -lt 3; $i++) {
    Click-Win $cx $cy 1500
    $after = Get-OcrLines 400
    $still = $after | Where-Object { $_.Text -like "*$commentText*" -or $_.Text -like "*$($commentText.Substring(0, [Math]::Min(6, $commentText.Length)))*" }
    $inputStillOpen = $after | Where-Object { $_.Text -eq '评论' -and $_.Y -gt 600 }
    if (-not $inputStillOpen) { Step '评论已发出'; break }
    Step ("第 " + ($i + 1) + " 次点发送未确认，重试")
    Start-Sleep -Milliseconds 600
}

Write-Host ''
Write-Host '=== 完成 ==='
Write-Host ("BVID  : " + $Bvid)
Write-Host ("标题  : " + $title)
Write-Host ("UP    : " + $owner)
Write-Host ("配文  : " + $Text)
Write-Host ("封面  : " + $cover)
Write-Host ("评论  : " + $commentText)
