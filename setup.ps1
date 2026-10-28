#Requires -Version 5.1
<#
.SYNOPSIS
    一键安装 wechat-moments（朋友圈）插件 + 技能。

.DESCRIPTION
    这个脚本不问你任何问题，全部自动探测：
      1. 找 WeChatAgent 的 workspace（含 state\wechat-io-config.json）
      2. 从里面读 reader 地址和 token
      3. 问 reader 要本账号 wxid
      4. 给 reader-api.py 打朋友圈只读路由补丁
      5. 装 DSH 插件到 desktop profile
      6. 装技能脚本到 ~\.dsh\skills\wechat-moments-post
      7. 写共享配置 ~\.dsh\wechat-moments.config.json
    跑完重启 DSH，5 个工具就出现了。

.PARAMETER Workspace
    手动指定 workspace 路径（自动探测失败时用）。

.PARAMETER ReaderToken
    手动指定 reader token（自动探测失败时用）。

.PARAMETER NoPatch
    跳过给 reader-api.py 打补丁（已经打过了）。

.PARAMETER NoProfile
    跳过插件安装（只装技能 + 配置）。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File setup.ps1
#>
[CmdletBinding()]
param(
    [string]$Workspace,
    [string]$ReaderToken,
    [string]$ReaderUrl,
    [switch]$NoPatch,
    [switch]$NoProfile,
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

$PkgRoot = $PSScriptRoot
if (-not $PkgRoot) { $PkgRoot = (Get-Location).Path }

$script:Problems = New-Object System.Collections.Generic.List[string]

function Step([string]$Text) { Write-Host ""; Write-Host "==> $Text" -ForegroundColor Cyan }
function Ok([string]$Text)   { Write-Host "    [OK] $Text" -ForegroundColor Green }
function Warn([string]$Text) { Write-Host "    [!]  $Text" -ForegroundColor Yellow }
function Bad([string]$Text)  {
    Write-Host "    [X]  $Text" -ForegroundColor Red
    $script:Problems.Add($Text) | Out-Null
}

# ---------------------------------------------------------------- 1. workspace

function Find-Workspace {
    # 候选优先级：显式参数 → 相对包的常见位置 → 各盘符浅层搜索
    if ($Workspace) {
        if (Test-Path -LiteralPath (Join-Path $Workspace 'state\wechat-io-config.json')) {
            return (Resolve-Path -LiteralPath $Workspace).Path
        }
        Warn "参数 -Workspace 指向的目录里没有 state\wechat-io-config.json：$Workspace"
    }

    $relatives = @(
        (Join-Path $PkgRoot '..\..'),
        (Join-Path $PkgRoot '..\..\..'),
        (Join-Path $env:USERPROFILE 'WeChatAgent\data\workspace'),
        (Join-Path $env:LOCALAPPDATA 'WeChatAgent\data\workspace')
    )
    foreach ($r in $relatives) {
        if (-not (Test-Path -LiteralPath $r)) { continue }
        $p = (Resolve-Path -LiteralPath $r).Path
        if (Test-Path -LiteralPath (Join-Path $p 'state\wechat-io-config.json')) { return $p }
    }

    # 浅层扫盘：<盘>:\*\data\workspace 与 <盘>:\data\workspace
    $drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -match '^[A-Za-z]:\\$' }
    foreach ($d in $drives) {
        $direct = Join-Path $d.Root 'data\workspace'
        if (Test-Path -LiteralPath (Join-Path $direct 'state\wechat-io-config.json')) {
            return (Resolve-Path -LiteralPath $direct).Path
        }
        try {
            $tops = Get-ChildItem -LiteralPath $d.Root -Directory -ErrorAction SilentlyContinue |
                    Select-Object -First 40
        } catch { continue }
        foreach ($t in $tops) {
            $cand = Join-Path $t.FullName 'data\workspace'
            if (Test-Path -LiteralPath (Join-Path $cand 'state\wechat-io-config.json')) {
                return (Resolve-Path -LiteralPath $cand).Path
            }
        }
    }
    return $null
}

Step '1/6 找 WeChatAgent workspace'
$wsPath = Find-Workspace
if (-not $wsPath) {
    Bad '找不到 workspace（含 state\wechat-io-config.json 的目录）。请用 -Workspace 指定。'
    $wsPath = $null
} else {
    Ok "workspace = $wsPath"
}

# ---------------------------------------------------------------- 2. token

Step '2/6 读 reader 地址与 token'
$ioConfig = $null
if ($wsPath) {
    $ioFile = Join-Path $wsPath 'state\wechat-io-config.json'
    try {
        $ioConfig = Get-Content -LiteralPath $ioFile -Raw -Encoding UTF8 | ConvertFrom-Json
        Ok "找到 $ioFile"
    } catch {
        Bad "读不了 $ioFile ：$($_.Exception.Message)"
    }
}

if ($ReaderUrl) { $resolvedReader = $ReaderUrl }
elseif ($ioConfig -and $ioConfig.reader_base_url) { $resolvedReader = [string]$ioConfig.reader_base_url }
else { $resolvedReader = 'http://127.0.0.1:5031' }

if ($ReaderToken) { $resolvedToken = $ReaderToken }
elseif ($ioConfig -and $ioConfig.reader_token) { $resolvedToken = [string]$ioConfig.reader_token }
else { $resolvedToken = '' }

if ($resolvedToken) { Ok ("reader = {0}，token 长度 {1}" -f $resolvedReader, $resolvedToken.Length) }
else { Bad '拿不到 reader token。请用 -ReaderToken 指定。' }

# ---------------------------------------------------------------- 3. wxid

Step '3/6 问 reader 要本账号 wxid'
$resolvedWxid = ''
$resolvedNick = ''
if ($resolvedToken) {
    try {
        $hdr = @{ Authorization = "Bearer $resolvedToken" }
        $mine = Invoke-RestMethod "$resolvedReader/api/v1/sns/mine?limit=5" -Headers $hdr -TimeoutSec 20
        $first = @($mine.posts) | Select-Object -First 1
        if ($first -and $first.username) {
            $resolvedWxid = [string]$first.username
            Ok "wxid = $resolvedWxid"
        } else {
            Warn 'reader 返回里没有 posts[0].username（朋友圈没发过东西？）'
        }
        if ($ioConfig -and $ioConfig.self_wxid) { $resolvedWxid = [string]$ioConfig.self_wxid }
    } catch {
        Bad "调 /api/v1/sns/mine 失败：$($_.Exception.Message)"
        Warn '  如果报 404，说明 reader 还没打过补丁；本脚本第 4 步会打，之后可以重跑。'
    }
} else {
    Warn '没有 token，跳过 wxid 探测'
}

# ---------------------------------------------------------------- 4. patch

Step '4/6 给 reader-api.py 打朋友圈路由补丁'
$patchScript = Join-Path $PkgRoot 'reader\patch-reader.py'
$snsModule   = Join-Path $PkgRoot 'reader\sns_routes.py'
$readerPy    = $null
$pyExe       = $null

if ($NoPatch) {
    Warn '按 -NoPatch 跳过'
} elseif (-not $wsPath) {
    Bad '没有 workspace，无法定位 reader-api.py'
} elseif (-not (Test-Path -LiteralPath $patchScript)) {
    Bad "包里缺 reader\patch-reader.py"
} else {
    $cand = Join-Path $wsPath 'scripts\reader-api.py'
    if (Test-Path -LiteralPath $cand) { $readerPy = $cand }
    else { Warn "没找到 $cand（reader 可能装在别处）" }

    # 找 python：workspace 同级 runtimes\*\python\python.exe
    $runRoot = Join-Path (Split-Path $wsPath -Parent) 'runtimes'
    if (Test-Path -LiteralPath $runRoot) {
        $pyExe = Get-ChildItem -LiteralPath $runRoot -Directory -ErrorAction SilentlyContinue |
                 Sort-Object Name -Descending |
                 ForEach-Object { Join-Path $_.FullName 'python\python.exe' } |
                 Where-Object { Test-Path -LiteralPath $_ } |
                 Select-Object -First 1
    }
    if (-not $pyExe) {
        $cmd = Get-Command python.exe -ErrorAction SilentlyContinue
        if ($cmd) { $pyExe = $cmd.Source }
    }

    if (-not $pyExe) {
        Bad '找不到 python.exe，无法打补丁'
    } elseif (-not $readerPy) {
        Bad '找不到 reader-api.py'
    } else {
        Ok "python  = $pyExe"
        Ok "reader  = $readerPy"
        # sns_routes.py 必须和 reader-api.py 同目录
        $snsDst = Join-Path (Split-Path $readerPy -Parent) 'sns_routes.py'
        if (Test-Path -LiteralPath $snsModule) {
            Copy-Item -LiteralPath $snsModule -Destination $snsDst -Force
            Ok "已放置 sns_routes.py"
        } else {
            Bad '包里缺 reader\sns_routes.py'
        }
        # python 重定向到文件时默认按 locale(cp936/GBK) 编码，中文会变成乱码。
        # 强制 PYTHONIOENCODING=utf-8，再按 UTF-8 读回文件。
        $tmpOut = Join-Path $env:TEMP ('patch-reader-' + [guid]::NewGuid().ToString('N') + '.log')
        $prevPyIo = $env:PYTHONIOENCODING
        $env:PYTHONIOENCODING = 'utf-8'
        try {
            & $pyExe $patchScript $readerPy *> $tmpOut
            $patchExit = $LASTEXITCODE
        } finally {
            if ($null -eq $prevPyIo) { Remove-Item Env:\PYTHONIOENCODING -ErrorAction SilentlyContinue }
            else { $env:PYTHONIOENCODING = $prevPyIo }
        }
        if (Test-Path -LiteralPath $tmpOut) {
            try {
                [System.IO.File]::ReadAllText($tmpOut, [System.Text.Encoding]::UTF8) -split "`r?`n" |
                    Where-Object { $_.Trim() } |
                    ForEach-Object { Write-Host "      $_" }
            } catch { Warn "补丁输出读不出来：$($_.Exception.Message)" }
            Remove-Item -LiteralPath $tmpOut -Force -ErrorAction SilentlyContinue
        }
        if ($patchExit -eq 0) { Ok '补丁已应用' }
        else { Bad "补丁失败（exit $patchExit），见上面的 ✗ 行" }
    }
}

# ---------------------------------------------------------------- 5. skills

Step '5/6 装技能脚本'
$skillSrc = Join-Path $PkgRoot 'skills\wechat-moments-post'
$skillDst = Join-Path $env:USERPROFILE '.dsh\skills\wechat-moments-post'
if (-not (Test-Path -LiteralPath $skillSrc)) {
    Bad '包里缺 skills\wechat-moments-post'
} else {
    if (-not (Test-Path -LiteralPath $skillDst)) {
        New-Item -ItemType Directory -Path $skillDst -Force | Out-Null
    }
    $copied = 0
    Get-ChildItem -LiteralPath $skillSrc -File | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $skillDst $_.Name) -Force
        $copied++
    }
    Ok "已复制 $copied 个文件到 $skillDst"
}

# ---------------------------------------------------------------- 6. plugin

Step '6/6 装 DSH 插件'
if ($NoProfile) {
    Warn '按 -NoProfile 跳过'
} else {
    $profileDir = Join-Path $env:USERPROFILE '.dsh\profiles\desktop'
    if (-not (Test-Path -LiteralPath $profileDir)) {
        Bad "没找到 DSH profile：$profileDir（先启动一次 DSH 桌面端）"
    } else {
        Ok "profile = $profileDir"
        $pluginSrc = Join-Path $PkgRoot 'plugin'
        $vendorDst = Join-Path $profileDir 'vendor\dsh-wechat-moments'
        $modDst    = Join-Path $profileDir 'node_modules\dsh-wechat-moments'

        foreach ($dst in @($vendorDst, $modDst)) {
            if (-not (Test-Path -LiteralPath (Join-Path $dst 'lib'))) {
                New-Item -ItemType Directory -Path (Join-Path $dst 'lib') -Force | Out-Null
            }
            Copy-Item -LiteralPath (Join-Path $pluginSrc 'package.json')      -Destination (Join-Path $dst 'package.json')      -Force
            Copy-Item -LiteralPath (Join-Path $pluginSrc 'cordis.patch.yml')  -Destination (Join-Path $dst 'cordis.patch.yml')  -Force
            Copy-Item -LiteralPath (Join-Path $pluginSrc 'lib\index.js')      -Destination (Join-Path $dst 'lib\index.js')      -Force
            Copy-Item -LiteralPath (Join-Path $pluginSrc 'lib\runner.ps1')    -Destination (Join-Path $dst 'lib\runner.ps1')    -Force
        }
        Ok '插件文件已复制（vendor + node_modules）'

        # profile package.json：依赖 + bundles
        $profPkg = Join-Path $profileDir 'package.json'
        if (Test-Path -LiteralPath $profPkg) {
            try {
                $raw = Get-Content -LiteralPath $profPkg -Raw -Encoding UTF8
                $obj = $raw | ConvertFrom-Json
                $changed = $false

                if (-not $obj.dependencies) {
                    $obj | Add-Member -NotePropertyName dependencies -NotePropertyValue ([pscustomobject]@{}) -Force
                    $changed = $true
                }
                if (-not $obj.dependencies.'dsh-wechat-moments') {
                    $obj.dependencies | Add-Member -NotePropertyName 'dsh-wechat-moments' -NotePropertyValue 'file:vendor/dsh-wechat-moments' -Force
                    $changed = $true
                }
                if ($obj.dsh -and $obj.dsh.profile -and $obj.dsh.profile.bundles) {
                    $b = @($obj.dsh.profile.bundles)
                    if ($b -notcontains 'dsh-wechat-moments') {
                        $obj.dsh.profile.bundles = @($b) + 'dsh-wechat-moments'
                        $changed = $true
                    }
                } else {
                    Warn 'profile package.json 里没有 dsh.profile.bundles，需手工确认插件是否被加载'
                }

                if ($changed) {
                    Copy-Item -LiteralPath $profPkg -Destination "$profPkg.bak-setup" -Force
                    $obj | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $profPkg -Encoding UTF8
                    Ok '已更新 profile\package.json（备份在 package.json.bak-setup）'
                } else {
                    Ok 'profile\package.json 已经配置好，无需改动'
                }
            } catch {
                Bad "改 profile\package.json 失败：$($_.Exception.Message)"
            }
        } else {
            Bad "没找到 $profPkg"
        }

        # profile 根 cordis.patch.yml 不能重复 insert 同 id
        $profPatch = Join-Path $profileDir 'cordis.patch.yml'
        if (Test-Path -LiteralPath $profPatch) {
            $pt = Get-Content -LiteralPath $profPatch -Raw -Encoding UTF8
            if ($pt -match 'dsh-wechat-moments') {
                Warn "profile\cordis.patch.yml 里也有 dsh-wechat-moments —— 会被插两次。建议删掉那一行（bundle 自己会 insert）。"
            }
        }
    }
}

# ---------------------------------------------------------------- 写配置

Step '写共享配置 ~\.dsh\wechat-moments.config.json'
$cfgPath = Join-Path $env:USERPROFILE '.dsh\wechat-moments.config.json'
$cfg = [ordered]@{
    workspace   = if ($wsPath) { $wsPath } else { '' }
    readerUrl   = $resolvedReader
    readerToken = $resolvedToken
    ownWxid     = $resolvedWxid
    ownNick     = $resolvedNick
    skillDir    = $skillDst
}
$cfgDir = Split-Path $cfgPath -Parent
if (-not (Test-Path -LiteralPath $cfgDir)) { New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null }
($cfg | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $cfgPath -Encoding UTF8
Ok "已写入 $cfgPath"

# ---------------------------------------------------------------- 自检

Step '自检'
if ($resolvedToken) {
    try {
        $hdr = @{ Authorization = "Bearer $resolvedToken" }
        $st = Invoke-RestMethod "$resolvedReader/api/v1/sns/stats" -Headers $hdr -TimeoutSec 15
        if ($null -ne $st.totalPosts) {
            Ok ("reader SNS 路由可用：totalPosts={0} myPosts={1}" -f $st.totalPosts, $st.myPosts)
        } elseif ($st.data -and $null -ne $st.data.totalPosts) {
            Ok ("reader SNS 路由可用：totalPosts={0} myPosts={1}" -f $st.data.totalPosts, $st.data.myPosts)
        } else {
            Warn 'reader 返回了响应，但没有 totalPosts 字段，可能版本不同'
        }
    } catch {
        Bad "reader /api/v1/sns/stats 不可用：$($_.Exception.Message)"
        Warn '  通常是补丁没打上，或 reader 进程没重启。'
    }
} else {
    Bad '没有 token，跳过自检'
}

$missing = @()
foreach ($f in @('wechat-moments-post.ps1', 'wechat-moments-reply.ps1', 'wx_ocr_probe.ps1')) {
    if (-not (Test-Path -LiteralPath (Join-Path $skillDst $f))) { $missing += $f }
}
if ($missing.Count -eq 0) { Ok '技能脚本齐全' }
else { Bad ("缺技能脚本：" + ($missing -join ', ')) }

if (Test-Path -LiteralPath $cfgPath) { Ok '配置文件存在' } else { Bad '配置文件没写成功' }

# ---------------------------------------------------------------- 收尾

Write-Host ''
if ($script:Problems.Count -gt 0) {
    Write-Host ("有 {0} 项需要处理：" -f $script:Problems.Count) -ForegroundColor Red
    $script:Problems | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    Write-Host ''
    Write-Host '修好后可以重跑本脚本（幂等，不会重复破坏）。' -ForegroundColor Yellow
    exit 1
}

Write-Host '全部就绪。' -ForegroundColor Green
Write-Host ''
Write-Host '下一步（必须做）：' -ForegroundColor Cyan
Write-Host '  1. 重启 WeChatAgent 的 reader 进程，让补丁生效'
Write-Host '  2. 重启 DSH 桌面端，让插件 5 个工具出现'
Write-Host '  3. 在对话里让我调 wechat_moments_feed 验证'
Write-Host ''
Write-Host '自测命令：' -ForegroundColor Cyan
Write-Host ('  powershell -File "{0}\wechat-moments-reply.ps1" -List' -f $skillDst)
Write-Host ''
Write-Host '遇到问题 / 想提需求：https://github.com/zhuiming2333/dsh-wechat-moments' -ForegroundColor DarkGray
exit 0
