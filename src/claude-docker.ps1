#Requires -Version 5.1
<#
ABOUTME: PowerShell launcher to run Claude Code in Docker on Windows (Docker Desktop).
ABOUTME: Native port of src/claude-docker.sh — mounting, persistent config, env passthrough.
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $Rest
)

$ErrorActionPreference = 'Stop'
$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ProjectRoot = Split-Path -Parent $ScriptDir
. (Join-Path $ScriptDir 'lib-common.ps1')

# ---- Parse command line arguments ----
$Docker        = if ($env:DOCKER) { $env:DOCKER } else { 'docker' }
$NoCache       = $false
$ForceRebuild  = $false
$ContinueFlag  = ''
$MemoryLimit   = ''
$GpuAccess     = ''
$CcVersion     = ''
$PassArgs      = @()

$argList = @($Rest | Where-Object { $null -ne $_ })
for ($i = 0; $i -lt $argList.Count; $i++) {
    switch ($argList[$i]) {
        '--podman'     { $Docker = 'podman' }
        '--no-cache'   { $NoCache = $true }
        '--rebuild'    { $ForceRebuild = $true }
        '--continue'   { $ContinueFlag = '--continue' }
        '--memory'     { $i++; $MemoryLimit = $argList[$i] }
        '--gpus'       { $i++; $GpuAccess   = $argList[$i] }
        '--cc-version' { $i++; $CcVersion   = $argList[$i] }
        default        { $PassArgs += $argList[$i] }
    }
}

# Validate runtime and resolve persistent host directory before any build/run operations.
Test-ContainerRuntime $Docker
$ClaudeDockerDir = Resolve-ClaudeDockerDir

$CurrentDir = (Get-Location).Path
$HostHome   = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }

$ClaudeHomeDir = Join-Path $ClaudeDockerDir 'claude-home'
$SshDir        = Join-Path $ClaudeDockerDir 'ssh'

# On Windows/Docker Desktop the host UID/GID is irrelevant (virtualized bind mounts),
# so we use the Dockerfile's conventional defaults.
$UserUid = 1000
$UserGid = 1000

# Preserve any --cc-version flag before loading .env (.env may also set CC_VERSION).
$CcVersionFlag = $CcVersion

# ---- Load .env for build/runtime configuration ----
$EnvFile = Join-Path $ProjectRoot '.env'
if (Test-Path -LiteralPath $EnvFile) {
    Write-LogOk "已找到环境配置文件:$EnvFile"
    Import-DotEnv $EnvFile
} else {
    Write-LogWarn "未找到环境配置文件:$EnvFile"
    Write-LogWarn "   Twilio MCP 功能将不可用。"
    Write-LogWarn "   如需启用:在 claude-docker 仓库中将 .env.example 复制为 .env 并填入你的凭证。"
}

# --cc-version flag takes precedence over CC_VERSION from .env
if ($CcVersionFlag) {
    $CcVersion = $CcVersionFlag
} elseif ($env:CC_VERSION) {
    $CcVersion = $env:CC_VERSION
    Write-LogOk "使用 .env 中的 Claude Code 版本:$CcVersion"
}

# Command line args override .env defaults for memory/gpu.
if (-not $MemoryLimit -and $env:DOCKER_MEMORY_LIMIT) {
    $MemoryLimit = $env:DOCKER_MEMORY_LIMIT
    Write-LogOk "使用环境变量中的内存上限:$MemoryLimit"
}
if (-not $GpuAccess -and $env:DOCKER_GPU_ACCESS) {
    $GpuAccess = $env:DOCKER_GPU_ACCESS
    Write-LogOk "使用环境变量中的 GPU 配置:$GpuAccess"
}

# ---- Decide whether to (re)build the image ----
$NeedRebuild = $false
$imageList = & $Docker images --format '{{.Repository}}' 2>$null
if (-not ($imageList | Select-String -SimpleMatch 'claude-docker' -Quiet)) {
    Write-LogInfo "首次构建 Claude Docker 镜像..."
    $NeedRebuild = $true
}
if ($ForceRebuild) {
    Write-LogInfo "强制重新构建 Claude Docker 镜像..."
    $NeedRebuild = $true
}
if ($NoCache -and -not $NeedRebuild) {
    Write-LogWarn "已设置 --no-cache 但镜像已存在。请使用 --rebuild --no-cache 强制无缓存重建。"
}

$ClaudeJsonContext = Join-Path $ProjectRoot '.claude.json'
if ($NeedRebuild) {
    # Dockerfile COPYs .claude.json and .env from the build context — make sure both exist.
    $HostClaudeJson = Join-Path $HostHome '.claude.json'
    if (Test-Path -LiteralPath $HostClaudeJson) {
        Copy-Item -LiteralPath $HostClaudeJson -Destination $ClaudeJsonContext -Force
    } else {
        Write-LogWarn "宿主机未找到 $HostClaudeJson,使用空占位符(首次运行时会提示交互式登录)。"
        Set-Content -LiteralPath $ClaudeJsonContext -Value '{}' -Encoding UTF8 -NoNewline
    }
    if (-not (Test-Path -LiteralPath $EnvFile)) {
        Write-LogWarn "构建需要 .env,已从 .env.example 生成占位文件:$EnvFile"
        Copy-Item -LiteralPath (Join-Path $ProjectRoot '.env.example') -Destination $EnvFile -Force
    }

    # Pull git identity from the host so commits inside the container are attributed correctly.
    $GitUserName = ''
    $GitUserEmail = ''
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $GitUserName  = (& git config --global --get user.name)  2>$null
        $GitUserEmail = (& git config --global --get user.email) 2>$null
    }

    $buildArgs = @('build')
    if ($NoCache) { $buildArgs += '--no-cache' }
    $buildArgs += @('--build-arg', "USER_UID=$UserUid", '--build-arg', "USER_GID=$UserGid")
    if ($GitUserName -and $GitUserEmail) {
        $buildArgs += @('--build-arg', "GIT_USER_NAME=$GitUserName", '--build-arg', "GIT_USER_EMAIL=$GitUserEmail")
    }
    if ($env:SYSTEM_PACKAGES) {
        Write-LogOk "构建时附加系统软件包:$($env:SYSTEM_PACKAGES)"
        $buildArgs += @('--build-arg', "SYSTEM_PACKAGES=$($env:SYSTEM_PACKAGES)")
    }
    if ($CcVersion) {
        Write-LogOk "构建 Claude Code 版本:$CcVersion"
        $buildArgs += @('--build-arg', "CC_VERSION=$CcVersion")
    }
    $buildArgs += @('-t', 'claude-docker:latest', $ProjectRoot)

    & $Docker @buildArgs
    $buildExit = $LASTEXITCODE

    # Clean up the copied auth file regardless of build outcome.
    if (Test-Path -LiteralPath $ClaudeJsonContext) { Remove-Item -LiteralPath $ClaudeJsonContext -Force }
    if ($buildExit -ne 0) { throw "镜像构建失败(退出码 $buildExit)" }
}

# ---- Prepare persistent directories ----
New-Item -ItemType Directory -Path $ClaudeHomeDir -Force | Out-Null
New-Item -ItemType Directory -Path $SshDir -Force | Out-Null

# Seed login credentials into the persistent home if not present yet.
$HostCreds = Join-Path (Join-Path $HostHome '.claude') '.credentials.json'
$DestCreds = Join-Path $ClaudeHomeDir '.credentials.json'
if ((Test-Path -LiteralPath $HostCreds) -and -not (Test-Path -LiteralPath $DestCreds)) {
    Write-LogOk "已复制 Claude 登录凭证到持久化目录"
    Copy-Item -LiteralPath $HostCreds -Destination $DestCreds -Force
}

Write-Host ''
Write-LogInfo "Claude 持久化配置目录:$ClaudeHomeDir\"
Write-LogInfo "该目录保存 Claude 设置、CLAUDE.md 指令、会话和登录凭证。"
Write-LogInfo "修改这里的文件会影响所有通过 claude-docker 启动的项目。"
Write-Host ''

# ---- SSH key setup (informational) ----
$SshKey    = Join-Path $SshDir 'id_rsa'
$SshPubKey = Join-Path $SshDir 'id_rsa.pub'
if (-not (Test-Path -LiteralPath $SshKey) -or -not (Test-Path -LiteralPath $SshPubKey)) {
    Write-Host ''
    Write-LogWarn "未找到用于 Git 操作的 SSH 密钥"
    Write-LogWarn "   如需在 Claude Docker 中启用 git push/pull:"
    Write-LogWarn "   1. 生成 SSH 密钥:ssh-keygen -t rsa -b 4096 -f `"$SshKey`" -N `"`""
    Write-LogWarn "   2. 将 `"$SshPubKey`" 的内容添加到 GitHub → Settings → SSH Keys"
    Write-LogWarn "   Claude 将在无 SSH 密钥的情况下继续(仅支持只读 git 操作)"
    Write-Host ''
} else {
    Write-LogOk "已找到用于 Git 操作的 SSH 密钥"
    $SshConfig = Join-Path $SshDir 'config'
    if (-not (Test-Path -LiteralPath $SshConfig)) {
        $cfg = @"
Host github.com
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_rsa
    IdentitiesOnly yes
"@
        # Write LF-only so the config parses correctly inside the Linux container.
        [System.IO.File]::WriteAllText($SshConfig, ($cfg -replace "`r`n", "`n"))
        Write-LogOk "已为 GitHub 创建 SSH config"
    }
}

# ---- Assemble docker run arguments ----
$dockerOpts = @('--add-host=host.docker.internal:host-gateway')

if ($MemoryLimit) {
    Write-LogOk "设置内存上限:$MemoryLimit"
    $dockerOpts += @('--memory', $MemoryLimit)
}
if ($GpuAccess) {
    $info = & $Docker info 2>$null
    if ($info | Select-String -SimpleMatch 'nvidia' -Quiet) {
        Write-LogOk "启用 GPU 访问:$GpuAccess"
        $dockerOpts += @('--gpus', $GpuAccess)
    } else {
        Write-LogWarn "已请求 GPU 访问,但未在 Docker 中检测到 NVIDIA 运行时,将不使用 GPU 继续..."
    }
}

$mountArgs = @(
    '-v', ("{0}:/workspace" -f (ConvertTo-DockerMountPath $CurrentDir)),
    '-v', ("{0}:/home/claude-user/.claude:rw" -f (ConvertTo-DockerMountPath $ClaudeHomeDir)),
    '-v', ("{0}:/home/claude-user/.ssh:rw"    -f (ConvertTo-DockerMountPath $SshDir))
)
$envArgs = @()

# Host conda passthrough is a Linux/macOS feature; Windows conda binaries can't run in a Linux
# container, so we warn and skip rather than create broken mounts.
if ($env:CONDA_PREFIX) {
    Write-LogWarn "检测到 CONDA_PREFIX,但 Windows 宿主的 conda 无法在 Linux 容器中运行,已跳过挂载。"
}
if ($env:CONDA_EXTRA_DIRS) {
    Write-LogWarn "检测到 CONDA_EXTRA_DIRS,Windows 下不支持 conda 目录透传,已跳过。"
}

# Mount an additional project directory at /<basename> when CLAUDE_REPO is set.
if ($env:CLAUDE_REPO) {
    if (Test-Path -LiteralPath $env:CLAUDE_REPO) {
        $repoName = Split-Path -Leaf $env:CLAUDE_REPO
        if ($repoName -eq 'workspace') {
            Write-LogWarn "CLAUDE_REPO 目录名为 workspace,会与主项目挂载冲突,已跳过"
        } else {
            $mountArgs += @('-v', ("{0}:/{1}:rw" -f (ConvertTo-DockerMountPath $env:CLAUDE_REPO), $repoName))
            Write-LogOk "挂载 Claude repo:$($env:CLAUDE_REPO) -> /$repoName"
        }
    } else {
        Write-LogWarn "CLAUDE_REPO 指定的目录不存在:$($env:CLAUDE_REPO)"
    }
}

# Pass through host environment variables prefixed with ENV_ (prefix stripped inside the container).
$envPassCount = 0
foreach ($e in (Get-ChildItem Env: | Where-Object { $_.Name -like 'ENV_*' })) {
    $target = $e.Name.Substring(4)
    if ($target) {
        $envArgs += @('-e', "$target=$($e.Value)")
        $envPassCount++
    }
}
if ($envPassCount -gt 0) {
    Write-LogOk "已将 $envPassCount 个 ENV_ 前缀变量传入容器环境"
}

# Optional: host-exec SSH wrapper (container -> host). DEFAULT OFF; enable with HOST_EXEC=1.
if ($env:HOST_EXEC -and $env:HOST_EXEC -ne '0' -and $env:HOST_EXEC -ne 'false') {
    $hostExecUser = if ($env:HOST_EXEC_USER) { $env:HOST_EXEC_USER } else { $env:USERNAME }
    $hostExecHost = if ($env:HOST_EXEC_HOST) { $env:HOST_EXEC_HOST } else { 'host.docker.internal' }
    $envArgs += @('-e', 'HOST_EXEC=1', '-e', "HOST_EXEC_USER=$hostExecUser", '-e', "HOST_EXEC_HOST=$hostExecHost")
    Write-LogWarn "已启用 HOST_EXEC:容器可经 SSH 在宿主($hostExecUser@$hostExecHost)执行命令 —— 请确认已授权并限制该密钥"
}

# ---- Run Claude Code in Docker ----
Write-LogInfo "正在 Docker 容器中启动 Claude Code..."
# Sanitize the project folder name for use in a Docker container name
# (Windows folders often contain spaces/other chars Docker's [a-zA-Z0-9_.-] rule rejects).
$projectLeaf = (Split-Path -Leaf $CurrentDir) -replace '[^a-zA-Z0-9_.-]', '-'
$containerName = "claude-docker-$projectLeaf-$PID"

$runArgs = @('run', '-it', '--rm')
$runArgs += $dockerOpts
$runArgs += $mountArgs
$runArgs += $envArgs
$runArgs += @('-e', "CLAUDE_CONTINUE_FLAG=$ContinueFlag")
$runArgs += @('--workdir', '/workspace')
$runArgs += @('--name', $containerName)
$runArgs += 'claude-docker:latest'
if ($PassArgs.Count -gt 0) { $runArgs += $PassArgs }

& $Docker @runArgs
exit $LASTEXITCODE
