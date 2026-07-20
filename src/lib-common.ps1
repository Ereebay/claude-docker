# ABOUTME: Shared helpers for the Windows (PowerShell) claude-docker launcher and installer.
# ABOUTME: Mirrors src/lib-common.sh so the Windows path behaves like the Unix scripts.

# ---- Leveled logging helpers (match the Chinese prefixes used by lib-common.sh) ----
function Write-LogOk   { param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Msg) Write-Host ("[成功] " + ($Msg -join ' ')) -ForegroundColor Green }
function Write-LogInfo { param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Msg) Write-Host ("[信息] " + ($Msg -join ' ')) -ForegroundColor Cyan }
function Write-LogWarn { param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Msg) Write-Host ("[警告] " + ($Msg -join ' ')) -ForegroundColor Yellow }
function Write-LogErr  { param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Msg) [Console]::Error.WriteLine("[错误] " + ($Msg -join ' ')) }

# Convert a Windows path to the form Docker Desktop accepts in -v mounts.
# C:\Users\foo -> C:/Users/foo  (drive letter + colon kept; backslashes -> forward slashes)
function ConvertTo-DockerMountPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    return ($full -replace '\\', '/')
}

# Resolve (and create) the persistent per-user claude-docker directory.
# Honors CLAUDE_DOCKER_HOME; otherwise uses %USERPROFILE%\.claude-docker.
function Resolve-ClaudeDockerDir {
    param([string]$PreferredHome)

    if ($env:CLAUDE_DOCKER_HOME) {
        $resolved = $env:CLAUDE_DOCKER_HOME
    } else {
        $homeDir = if ($PreferredHome) { $PreferredHome }
                   elseif ($env:USERPROFILE) { $env:USERPROFILE }
                   else { $HOME }
        if (-not $homeDir) {
            throw "无法确定家目录。请将 CLAUDE_DOCKER_HOME 设为一个可写路径,例如:`n  `$env:CLAUDE_DOCKER_HOME = 'D:\claude-docker'"
        }
        $resolved = Join-Path $homeDir '.claude-docker'
    }

    if (-not (Test-Path -LiteralPath $resolved)) {
        New-Item -ItemType Directory -Path $resolved -Force | Out-Null
    }
    return (Resolve-Path -LiteralPath $resolved).Path
}

# Verify the container runtime exists and its daemon is reachable.
function Test-ContainerRuntime {
    param([string]$Runtime = 'docker')

    if (-not (Get-Command $Runtime -ErrorAction SilentlyContinue)) {
        throw "未找到容器运行时 '$Runtime'。请安装 Docker Desktop 并确保其在 PATH 中。"
    }
    & $Runtime info *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "无法连接 '$Runtime' 守护进程。请确认 Docker Desktop 正在运行。"
    }
}

# Parse a KEY=VALUE .env file into process environment variables (no `export`, optional quotes).
function Import-DotEnv {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $idx = $t.IndexOf('=')
        if ($idx -lt 1) { continue }
        $name = $t.Substring(0, $idx).Trim()
        $val  = $t.Substring($idx + 1).Trim()
        if ($val.Length -ge 2) {
            $first = $val[0]; $last = $val[$val.Length - 1]
            if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
                $val = $val.Substring(1, $val.Length - 2)
            }
        }
        Set-Item -Path "Env:$name" -Value $val
    }
}
