#!/usr/bin/env bash
set -euo pipefail
trap 'echo "$0: line $LINENO: $BASH_COMMAND: exitcode $?"' ERR
# ABOUTME: Wrapper script to run Claude Code in Docker container
# ABOUTME: Handles project mounting, persistent Claude config, and environment variables

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/lib-common.sh"

# Parse command line arguments
DOCKER="${DOCKER:-docker}"
NO_CACHE=""
FORCE_REBUILD=false
CONTINUE_FLAG=""
MEMORY_LIMIT=""
GPU_ACCESS=""
CC_VERSION=""
ARGS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        --podman)
            DOCKER=podman
            shift
            ;;
        --no-cache)
            NO_CACHE="--no-cache"
            shift
            ;;
        --rebuild)
            FORCE_REBUILD=true
            shift
            ;;
        --continue)
            CONTINUE_FLAG="--continue"
            shift
            ;;
        --memory)
            MEMORY_LIMIT="$2"
            shift 2
            ;;
        --gpus)
            GPU_ACCESS="$2"
            shift 2
            ;;
        --cc-version)
            CC_VERSION="$2"
            shift 2
            ;;
        *)
            ARGS+=("$1")
            shift
            ;;
    esac
done

# Validate runtime and resolve persistent host directory before any build/run operations.
check_container_runtime "$DOCKER" "1.44"
resolve_claude_docker_dir

# Get the absolute path of the current directory
CURRENT_DIR=$(pwd)
HOST_HOME="${HOME:-}"
if [ -z "$HOST_HOME" ]; then
    HOST_HOME="$(get_home_for_uid "$(id -u)" || true)"
fi

CLAUDE_HOME_DIR="$CLAUDE_DOCKER_DIR/claude-home"
SSH_DIR="$CLAUDE_DOCKER_DIR/ssh"

# Preserve any --cc-version flag value before sourcing .env (.env may also set CC_VERSION)
CC_VERSION_FLAG="$CC_VERSION"

# Check if .env exists in claude-docker directory for building
ENV_FILE="$PROJECT_ROOT/.env"
if [ -f "$ENV_FILE" ]; then
    log_ok "已找到环境配置文件:$ENV_FILE"
    # Source .env to get configuration variables
    set -a
    source "$ENV_FILE" 2>/dev/null || true
    set +a
else
    log_warn "未找到环境配置文件:$ENV_FILE"
    log_warn "   Twilio MCP 功能将不可用。"
    log_warn "   如需启用:在 claude-docker 仓库中将 .env.example 复制为 .env 并填入你的凭证。"
fi

# Use environment variables as defaults if command line args not provided
if [ -z "${MEMORY_LIMIT:-}" ] && [ -n "${DOCKER_MEMORY_LIMIT:-}" ]; then
    MEMORY_LIMIT="$DOCKER_MEMORY_LIMIT"
    log_ok "使用环境变量中的内存上限:$MEMORY_LIMIT"
fi

if [ -z "${GPU_ACCESS:-}" ] && [ -n "${DOCKER_GPU_ACCESS:-}" ]; then
    GPU_ACCESS="$DOCKER_GPU_ACCESS"
    log_ok "使用环境变量中的 GPU 配置:$GPU_ACCESS"
fi

# --cc-version flag takes precedence over any CC_VERSION provided via .env
if [ -n "$CC_VERSION_FLAG" ]; then
    CC_VERSION="$CC_VERSION_FLAG"
elif [ -n "${CC_VERSION:-}" ]; then
    log_ok "使用 .env 中的 Claude Code 版本:$CC_VERSION"
fi

# Check if we need to rebuild the image
NEED_REBUILD=false

if ! "$DOCKER" images | grep -q "claude-docker"; then
    log_info "首次构建 Claude Docker 镜像..."
    NEED_REBUILD=true
fi

if [ "$FORCE_REBUILD" = true ]; then
    log_info "强制重新构建 Claude Docker 镜像..."
    NEED_REBUILD=true
fi

# Warn if --no-cache is used without rebuild
if [ -n "${NO_CACHE:-}" ] && [ "$NEED_REBUILD" = false ]; then
    log_warn "已设置 --no-cache 但镜像已存在。请使用 --rebuild --no-cache 强制无缓存重建。"
fi

if [ "$NEED_REBUILD" = true ]; then
    # Copy authentication files to build context
    if [ -n "$HOST_HOME" ] && [ -f "$HOST_HOME/.claude.json" ]; then
        cp "$HOST_HOME/.claude.json" "$PROJECT_ROOT/.claude.json"
    fi

    # Get git config from host
    GIT_USER_NAME=$(git config --global --get user.name 2>/dev/null || echo "")
    GIT_USER_EMAIL=$(git config --global --get user.email 2>/dev/null || echo "")

    # Build docker command with conditional system packages and git config
    BUILD_ARGS="--build-arg USER_UID=$(id -u) --build-arg USER_GID=$(id -g)"
    if [ -n "${GIT_USER_NAME:-}" ] && [ -n "${GIT_USER_EMAIL:-}" ]; then
        BUILD_ARGS="$BUILD_ARGS --build-arg GIT_USER_NAME=\"$GIT_USER_NAME\" --build-arg GIT_USER_EMAIL=\"$GIT_USER_EMAIL\""
    fi
    if [ -n "${SYSTEM_PACKAGES:-}" ]; then
        log_ok "构建时附加系统软件包:$SYSTEM_PACKAGES"
        BUILD_ARGS="$BUILD_ARGS --build-arg SYSTEM_PACKAGES=\"$SYSTEM_PACKAGES\""
    fi
    if [ -n "${CC_VERSION:-}" ]; then
        log_ok "构建 Claude Code 版本:$CC_VERSION"
        BUILD_ARGS="$BUILD_ARGS --build-arg CC_VERSION=\"$CC_VERSION\""
    fi

    eval "'$DOCKER' build $NO_CACHE $BUILD_ARGS -t claude-docker:latest \"$PROJECT_ROOT\""

    # Clean up copied auth files
    rm -f "$PROJECT_ROOT/.claude.json"
fi

# Ensure the claude-home and ssh directories exist
mkdir -p "$CLAUDE_HOME_DIR"
mkdir -p "$SSH_DIR"

# Copy authentication files to persistent claude-home if they don't exist
if [ -n "$HOST_HOME" ] && [ -f "$HOST_HOME/.claude/.credentials.json" ] && [ ! -f "$CLAUDE_HOME_DIR/.credentials.json" ]; then
    log_ok "已复制 Claude 登录凭证到持久化目录"
    cp "$HOST_HOME/.claude/.credentials.json" "$CLAUDE_HOME_DIR/.credentials.json"
fi

# Log information about persistent Claude home directory
echo ""
log_info "Claude 持久化配置目录:$CLAUDE_HOME_DIR/"
log_info "该目录保存 Claude 设置、CLAUDE.md 指令、会话和登录凭证。"
log_info "修改这里的文件会影响所有通过 claude-docker 启动的项目。"
echo ""

# Check SSH key setup
SSH_KEY_PATH="$SSH_DIR/id_rsa"
SSH_PUB_KEY_PATH="$SSH_DIR/id_rsa.pub"

if [ ! -f "$SSH_KEY_PATH" ] || [ ! -f "$SSH_PUB_KEY_PATH" ]; then
    echo ""
    log_warn "未找到用于 Git 操作的 SSH 密钥"
    log_warn "   如需在 Claude Docker 中启用 git push/pull:"
    echo ""
    log_warn "   1. 生成 SSH 密钥:"
    log_warn "      ssh-keygen -t rsa -b 4096 -f $SSH_DIR/id_rsa -N ''"
    echo ""
    log_warn "   2. 将公钥添加到 GitHub:"
    log_warn "      cat $SSH_DIR/id_rsa.pub"
    log_warn "      # 复制输出并添加到:GitHub → Settings → SSH Keys"
    echo ""
    log_warn "   3. 测试连接:"
    log_warn "      ssh -T git@github.com -i $SSH_DIR/id_rsa"
    echo ""
    log_warn "   Claude 将在无 SSH 密钥的情况下继续(仅支持只读 git 操作)"
    echo ""
else
    log_ok "已找到用于 Git 操作的 SSH 密钥"

    # Create SSH config if it doesn't exist
    SSH_CONFIG_PATH="$SSH_DIR/config"
    if [ ! -f "$SSH_CONFIG_PATH" ]; then
        cat > "$SSH_CONFIG_PATH" << 'EOF'
Host github.com
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_rsa
    IdentitiesOnly yes
EOF
        log_ok "已为 GitHub 创建 SSH config"
    fi
fi

# Prepare additional mount arguments
MOUNT_ARGS=""
ENV_ARGS=""
DOCKER_OPTS=""

# Add memory limit if specified
if [ -n "${MEMORY_LIMIT:-}" ]; then
    log_ok "设置内存上限:$MEMORY_LIMIT"
    DOCKER_OPTS="$DOCKER_OPTS --memory $MEMORY_LIMIT"
fi

# Add GPU access if specified
if [ -n "${GPU_ACCESS:-}" ]; then
    # Check if nvidia-docker2 or nvidia-container-runtime is available
    if "$DOCKER" info 2>/dev/null | grep -q nvidia || which nvidia-docker >/dev/null 2>&1; then
        log_ok "启用 GPU 访问:$GPU_ACCESS"
        DOCKER_OPTS="$DOCKER_OPTS --gpus $GPU_ACCESS"
    else
        log_warn "已请求 GPU 访问,但未找到 NVIDIA Docker 运行时"
        log_warn "   请安装 nvidia-docker2 或 nvidia-container-runtime 以启用 GPU 支持"
        log_warn "   将在不使用 GPU 的情况下继续..."
    fi
fi

# Enable host.docker.internal DNS so container can reach host services (e.g. vLLM on port 8000)
DOCKER_OPTS="$DOCKER_OPTS --add-host=host.docker.internal:host-gateway"

# Mount conda installation if specified
if [ -n "${CONDA_PREFIX:-}" ] && [ -d "$CONDA_PREFIX" ]; then
    log_ok "挂载 conda 安装目录:$CONDA_PREFIX"
    MOUNT_ARGS="$MOUNT_ARGS -v $CONDA_PREFIX:$CONDA_PREFIX:ro"
    ENV_ARGS="$ENV_ARGS -e CONDA_PREFIX=$CONDA_PREFIX -e CONDA_EXE=$CONDA_PREFIX/bin/conda"
else
    log_info "未配置 conda 安装目录"
fi

# Mount additional conda directories if specified
if [ -n "${CONDA_EXTRA_DIRS:-}" ]; then
    log_ok "挂载额外的 conda 目录..."
    CONDA_ENVS_PATHS=""
    CONDA_PKGS_PATHS=""
    for dir in $CONDA_EXTRA_DIRS; do
        if [ -d "$dir" ]; then
            log_info "  - 挂载 $dir"
            MOUNT_ARGS="$MOUNT_ARGS -v $dir:$dir:ro"
            # Build comma-separated list for CONDA_ENVS_DIRS
            if [[ "$dir" == *"env"* ]]; then
                if [ -z "${CONDA_ENVS_PATHS:-}" ]; then
                    CONDA_ENVS_PATHS="$dir"
                else
                    CONDA_ENVS_PATHS="$CONDA_ENVS_PATHS:$dir"
                fi
            fi
            # Build comma-separated list for CONDA_PKGS_DIRS
            if [[ "$dir" == *"pkg"* ]]; then
                if [ -z "${CONDA_PKGS_PATHS:-}" ]; then
                    CONDA_PKGS_PATHS="$dir"
                else
                    CONDA_PKGS_PATHS="$CONDA_PKGS_PATHS:$dir"
                fi
            fi
        else
            log_warn "  - 跳过 $dir(不存在)"
        fi
    done
    # Set CONDA_ENVS_DIRS environment variable if we found env paths
    if [ -n "${CONDA_ENVS_PATHS:-}" ]; then
        ENV_ARGS="$ENV_ARGS -e CONDA_ENVS_DIRS=$CONDA_ENVS_PATHS"
        log_info "  - 设置 CONDA_ENVS_DIRS=$CONDA_ENVS_PATHS"
    fi
    # Set CONDA_PKGS_DIRS environment variable if we found pkg paths
    if [ -n "${CONDA_PKGS_PATHS:-}" ]; then
        ENV_ARGS="$ENV_ARGS -e CONDA_PKGS_DIRS=$CONDA_PKGS_PATHS"
        log_info "  - 设置 CONDA_PKGS_DIRS=$CONDA_PKGS_PATHS"
    fi
else
    log_info "未配置额外的 conda 目录"
fi

# Mount an additional project directory into the container at /<basename>
# Set CLAUDE_REPO=/host/path in .env to make another project available alongside /workspace.
if [ -n "${CLAUDE_REPO:-}" ]; then
    if [ -d "$CLAUDE_REPO" ]; then
        CLAUDE_REPO_NAME="$(basename "$CLAUDE_REPO")"
        if [ "$CLAUDE_REPO_NAME" = "workspace" ]; then
            log_warn "CLAUDE_REPO 目录名为 workspace,会与主项目挂载冲突,已跳过"
        else
            MOUNT_ARGS="$MOUNT_ARGS -v $CLAUDE_REPO:/$CLAUDE_REPO_NAME:rw"
            log_ok "挂载 Claude repo:$CLAUDE_REPO -> /$CLAUDE_REPO_NAME"
        fi
    else
        log_warn "CLAUDE_REPO 指定的目录不存在:$CLAUDE_REPO"
    fi
fi

# Optional: host-exec SSH wrapper (container -> host). DEFAULT OFF; enable with HOST_EXEC=1.
# SECURITY: this lets the permission-skipping agent run commands on your host via SSH.
# It only forwards the switch + host identity; the container sets up the wrapper at startup.
if [ -n "${HOST_EXEC:-}" ] && [ "${HOST_EXEC}" != "0" ] && [ "${HOST_EXEC}" != "false" ]; then
    HOST_EXEC_USER="${HOST_EXEC_USER:-$(id -un)}"
    HOST_EXEC_HOST="${HOST_EXEC_HOST:-host.docker.internal}"
    ENV_ARGS="$ENV_ARGS -e HOST_EXEC=1 -e HOST_EXEC_USER=$HOST_EXEC_USER -e HOST_EXEC_HOST=$HOST_EXEC_HOST"
    log_warn "已启用 HOST_EXEC:容器可经 SSH 在宿主($HOST_EXEC_USER@$HOST_EXEC_HOST)执行命令 —— 请确认已授权并限制该密钥"
fi

# Run Claude Code in Docker
log_info "正在 Docker 容器中启动 Claude Code..."
"$DOCKER" run -it --rm \
    $DOCKER_OPTS \
    -v "$CURRENT_DIR:/workspace" \
    -v "$CLAUDE_HOME_DIR:/home/claude-user/.claude:rw" \
    -v "$SSH_DIR:/home/claude-user/.ssh:rw" \
    $MOUNT_ARGS \
    $ENV_ARGS \
    -e CLAUDE_CONTINUE_FLAG="$CONTINUE_FLAG" \
    --workdir /workspace \
    --name "claude-docker-$(basename "$CURRENT_DIR")-$$" \
    claude-docker:latest ${ARGS[@]+"${ARGS[@]}"}
