<#
  dsh-wechat-moments job runner.

  Kept ASCII-only on purpose: Windows PowerShell 5.1 reads .ps1 as GBK, so a
  UTF-8 file without a BOM containing non-ASCII source would be misparsed. All
  Chinese text this script produces comes from the skill scripts it invokes and
  is written out as UTF-8 files, never compiled as source here.

  Actions:
    list   - fast, HTTP only: which comments still need a reply.
    post   - slow, drives the desktop: publish a photo moment.
    reply  - slow, drives the desktop: reply to one comment.

  Every action writes <JobDir>\status.json and <JobDir>\output.log so the Node
  side can poll without holding a process handle.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$JobDir,
    [Parameter(Mandatory = $true)][string]$Action,
    # Kept only for manual invocations. The Node side writes args.json instead:
    # PowerShell strips the quotes out of an argv JSON string, so -ArgsJson
    # receives `{text:...}` and ConvertFrom-Json rejects it.
    [string]$ArgsJson = ''
)

$ErrorActionPreference = 'Stop'

# The skill scripts print UTF-8. Without this, Windows PowerShell decodes their
# stdout with the OEM code page (936 here) and every Chinese log line turns into
# mojibake before it reaches output.log.
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

$statusPath = Join-Path $JobDir 'status.json'
$logPath    = Join-Path $JobDir 'output.log'

function Write-Status {
    param([string]$State, [int]$Code = 0, [string]$Message = '')
    $payload = [ordered]@{
        state      = $State
        exitCode   = $Code
        message    = $Message
        updatedAt  = (Get-Date).ToString('o')
    }
    $json = $payload | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($statusPath, $json, [System.Text.UTF8Encoding]::new($false))
}

function Invoke-SkillScript {
    param([string]$ScriptPath, [string[]]$Arguments)

    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "skill script not found: $ScriptPath"
    }

    # Do NOT pipe the child's stdout through PowerShell: it decodes a native
    # process's output with the OEM code page (936 here), so the skill scripts'
    # UTF-8 Chinese arrives as mojibake. -RedirectStandardOutput/Error writes the
    # raw bytes to disk; read those back as UTF-8 instead.
    $outFile = Join-Path $JobDir '.stdout.tmp'
    $errFile = Join-Path $JobDir '.stderr.tmp'
    foreach ($f in @($outFile, $errFile)) {
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    }

    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + $Arguments
    $proc = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru -Wait `
        -ArgumentList $argv -RedirectStandardOutput $outFile -RedirectStandardError $errFile

    $code = 0
    if ($proc -and $null -ne $proc.ExitCode) { $code = [int]$proc.ExitCode }

    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $sb = New-Object System.Text.StringBuilder
    foreach ($f in @($outFile, $errFile)) {
        if (Test-Path -LiteralPath $f) {
            $chunk = [System.IO.File]::ReadAllText($f, $utf8)
            if ($chunk -and $chunk.Trim()) { [void]$sb.AppendLine($chunk.TrimEnd()) }
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        }
    }
    [System.IO.File]::WriteAllText($logPath, $sb.ToString(), $utf8)
    return [int]$code
}

try {
    Write-Status -State 'running'

    $args_ = @{}
    $argsFile = Join-Path $JobDir 'args.json'
    if (Test-Path -LiteralPath $argsFile) {
        $obj = [System.IO.File]::ReadAllText($argsFile, [System.Text.UTF8Encoding]::new($false)) | ConvertFrom-Json
        foreach ($p in $obj.PSObject.Properties) { $args_[$p.Name] = $p.Value }
    }
    elseif ($ArgsJson -and $ArgsJson.Trim()) {
        $obj = $ArgsJson | ConvertFrom-Json
        foreach ($p in $obj.PSObject.Properties) { $args_[$p.Name] = $p.Value }
    }

    $skillDir = [string]$args_['skillDir']
    if (-not $skillDir) { throw 'skillDir is required' }
    $skillDir = [System.Environment]::ExpandEnvironmentVariables($skillDir)

    switch ($Action) {
        'list' {
            $script = Join-Path $skillDir 'wechat-moments-reply.ps1'
            $code = Invoke-SkillScript -ScriptPath $script -Arguments @('-List')
        }
        'post' {
            $script = Join-Path $skillDir 'wechat-moments-post.ps1'
            $a = @('-Image', [string]$args_['image'])
            if ($args_['text']) { $a += @('-Text', [string]$args_['text']) }
            if ([bool]$args_['dryRun']) { $a += '-DryRun' }
            $code = Invoke-SkillScript -ScriptPath $script -Arguments $a
        }
        'reply' {
            $script = Join-Path $skillDir 'wechat-moments-reply.ps1'
            $a = @(
                '-ObjectId', [string]$args_['objectId'],
                '-CommentId', [string]$args_['commentId'],
                '-Text', [string]$args_['text']
            )
            if (-not [bool]$args_['dryRun']) { $a += '-Execute' }
            $code = Invoke-SkillScript -ScriptPath $script -Arguments $a
        }
        default { throw "unknown action: $Action" }
    }

    if ($code -eq 0) {
        Write-Status -State 'done' -Code 0
    } else {
        Write-Status -State 'failed' -Code $code -Message "script exited with $code"
    }
    exit $code
}
catch {
    $msg = $_.Exception.Message
    [System.IO.File]::WriteAllText($logPath, [string]$msg, [System.Text.UTF8Encoding]::new($false))
    Write-Status -State 'failed' -Code 1 -Message $msg
    exit 1
}
