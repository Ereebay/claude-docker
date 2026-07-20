#Requires -Version 5.1
<#
ABOUTME: Windows installer for claude-docker — seeds persistent config and registers a
ABOUTME: `claude-docker` PowerShell function. Native port of src/install.sh.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ProjectRoot = Split-Path -Parent $ScriptDir
. (Join-Path $ScriptDir 'lib-common.ps1')

$TargetHome = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
if (-not $TargetHome) {
    Write-LogErr "无法确定家目录。请将 CLAUDE_DOCKER_HOME 设为一个可写路径后重新运行 install.ps1。"
    exit 1
}

$ClaudeDockerDir = Resolve-ClaudeDockerDir $TargetHome
$ClaudeHomeDir   = Join-Path $ClaudeDockerDir 'claude-home'

# Create claude persistence directory and seed it with the project's .claude template.
New-Item -ItemType Directory -Path $ClaudeHomeDir -Force | Out-Null
Write-LogOk "已复制模板 Claude 配置到持久化目录"
Copy-Item -Path (Join-Path $ProjectRoot '.claude\*') -Destination $ClaudeHomeDir -Recurse -Force

# Copy example env file if it doesn't exist.
$EnvFile = Join-Path $ProjectRoot '.env'
if (-not (Test-Path -LiteralPath $EnvFile)) {
    Copy-Item -LiteralPath (Join-Path $ProjectRoot '.env.example') -Destination $EnvFile -Force
    Write-LogWarn "已在 $EnvFile 创建 .env 文件"
    Write-LogWarn "   请填入你的 API 密钥!"
}

# ---- Register a `claude-docker` function in the user's PowerShell profile ----
$LauncherPath = Join-Path $ScriptDir 'claude-docker.ps1'
$ProfilePath  = $PROFILE.CurrentUserAllHosts
$ProfileDir   = Split-Path -Parent $ProfilePath
if (-not (Test-Path -LiteralPath $ProfileDir)) {
    New-Item -ItemType Directory -Path $ProfileDir -Force | Out-Null
}
if (-not (Test-Path -LiteralPath $ProfilePath)) {
    New-Item -ItemType File -Path $ProfilePath -Force | Out-Null
    Write-LogOk "已创建 PowerShell 配置文件:$ProfilePath"
}

$profileContent = if (Test-Path -LiteralPath $ProfilePath) { Get-Content -LiteralPath $ProfilePath -Raw } else { '' }
if ($profileContent -notmatch 'function\s+claude-docker') {
    $block = @"

# Claude Docker launcher
function claude-docker { & "$LauncherPath" @args }
"@
    Add-Content -LiteralPath $ProfilePath -Value $block
    Write-LogOk "已将 'claude-docker' 函数添加到 PowerShell 配置文件"
} else {
    Write-LogOk "PowerShell 配置文件中已存在 claude-docker 函数"
}

# ---- GPU support (informational on Windows) ----
Write-Host ''
Write-LogInfo "正在检查 GPU 支持..."
if (Get-Command docker -ErrorAction SilentlyContinue) {
    $info = & docker info 2>$null
    if ($info | Select-String -SimpleMatch 'nvidia' -Quiet) {
        Write-LogOk "Docker 已检测到 NVIDIA 运行时(GPU 可用)"
    } else {
        Write-LogInfo "未检测到 Docker GPU 支持。Windows 上的 GPU 需:NVIDIA 驱动 + Docker Desktop + WSL2 后端。"
    }
} else {
    Write-LogWarn "未找到 docker 命令,请先安装 Docker Desktop(WSL2 后端)。"
}

Write-Host ''
Write-LogOk "安装完成! 🎉"
Write-Host ''
Write-LogInfo "后续步骤:"
Write-LogInfo "1. 若脚本被拦截,先允许本地脚本:Set-ExecutionPolicy -Scope CurrentUser RemoteSigned"
Write-LogInfo "2.(可选)编辑 $EnvFile 填入你的 API 密钥"
Write-LogInfo "3. 重新加载配置:. `$PROFILE  (或新开一个 PowerShell 窗口)"
Write-LogInfo "4. 进入任意项目目录并运行 'claude-docker' 启动"
Write-LogInfo "5. 若没有 API 密钥,Claude 会提示进行交互式登录认证"
