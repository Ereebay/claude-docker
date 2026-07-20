#!/usr/bin/env bash
set -euo pipefail
trap 'echo "$0: line $LINENO: $BASH_COMMAND: exitcode $?"' ERR
# ABOUTME: Installation script for claude-docker
# ABOUTME: Creates persistent claude-docker config and adds shell alias for the calling user.

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib-common.sh"

get_user_shell_from_passwd() {
    local user_name="${1:-}"
    local user_shell=""

    if [ -n "$user_name" ] && command -v getent >/dev/null 2>&1; then
        user_shell="$(getent passwd "$user_name" | cut -d: -f7 || true)"
    fi

    if [ -z "$user_shell" ] && [ -n "$user_name" ] && [ -r /etc/passwd ]; then
        user_shell="$(awk -F: -v uname="$user_name" '$1 == uname { print $7; exit }' /etc/passwd || true)"
    fi

    if [ -z "$user_shell" ]; then
        user_shell="${SHELL:-/bin/bash}"
    fi

    printf '%s\n' "$user_shell"
}

get_shell_rc_filename() {
    local shell_path="${1:-}"
    local shell_name
    shell_name="$(basename "$shell_path")"

    case "$shell_name" in
        zsh)
            printf '%s\n' ".zshrc"
            ;;
        bash)
            if [ -f "$TARGET_HOME/.bash_profile" ] && [ ! -f "$TARGET_HOME/.bashrc" ]; then
                printf '%s\n' ".bash_profile"
            else
                printf '%s\n' ".bashrc"
            fi
            ;;
        sh|dash|ksh|ash)
            printf '%s\n' ".profile"
            ;;
        *)
            printf '%s\n' ".profile"
            ;;
    esac
}

TARGET_USER="$(id -un)"
TARGET_UID="$(id -u)"
TARGET_GID="$(id -g)"

if [ "$EUID" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    TARGET_USER="$SUDO_USER"
    TARGET_UID="$(id -u "$TARGET_USER")"
    TARGET_GID="$(id -g "$TARGET_USER")"
fi

TARGET_HOME="$(get_home_for_uid "$TARGET_UID" || true)"
if [ -z "$TARGET_HOME" ] && [ "$EUID" -ne 0 ]; then
    TARGET_HOME="${HOME:-}"
fi

if [ -z "$TARGET_HOME" ]; then
    log_err "无法为用户 '$TARGET_USER' 确定家目录。"
    log_err "请将 CLAUDE_DOCKER_HOME 设为一个可写路径后重新运行 install.sh。"
    exit 1
fi

TARGET_SHELL="$(get_user_shell_from_passwd "$TARGET_USER")"
TARGET_RC_NAME="$(get_shell_rc_filename "$TARGET_SHELL")"
TARGET_RC_FILE="$TARGET_HOME/$TARGET_RC_NAME"

resolve_claude_docker_dir "$TARGET_HOME"
CLAUDE_HOME_DIR="$CLAUDE_DOCKER_DIR/claude-home"

# Create claude persistence directory
mkdir -p "$CLAUDE_HOME_DIR"

# Copy template .claude contents to persistent directory
log_ok "已复制模板 Claude 配置到持久化目录"
cp -r "$PROJECT_ROOT/.claude/." "$CLAUDE_HOME_DIR/"

# Copy example env file if doesn't exist
if [ ! -f "$PROJECT_ROOT/.env" ]; then
    cp "$PROJECT_ROOT/.env.example" "$PROJECT_ROOT/.env"
    log_warn "已在 $PROJECT_ROOT/.env 创建 .env 文件"
    log_warn "   请填入你的 API 密钥!"
fi

# Add alias to the detected shell RC file
ALIAS_LINE="alias claude-docker='$PROJECT_ROOT/src/claude-docker.sh'"
if [ ! -f "$TARGET_RC_FILE" ]; then
    touch "$TARGET_RC_FILE"
    log_ok "已在 $TARGET_RC_FILE 创建 shell 配置文件"
fi

if ! grep -Fq "alias claude-docker=" "$TARGET_RC_FILE"; then
    echo "" >> "$TARGET_RC_FILE"
    echo "# Claude Docker alias" >> "$TARGET_RC_FILE"
    echo "$ALIAS_LINE" >> "$TARGET_RC_FILE"
    log_ok "已将 'claude-docker' 别名添加到 $TARGET_RC_NAME"
else
    log_ok "$TARGET_RC_NAME 中已存在 claude-docker 别名"
fi

# Fix ownership when run with sudo so the invoking user can modify generated files.
if [ "$EUID" -eq 0 ] && [ "$TARGET_USER" != "root" ]; then
    chown -R "$TARGET_UID:$TARGET_GID" "$CLAUDE_DOCKER_DIR"
    chown "$TARGET_UID:$TARGET_GID" "$TARGET_RC_FILE"
    if [ -f "$PROJECT_ROOT/.env" ]; then
        chown "$TARGET_UID:$TARGET_GID" "$PROJECT_ROOT/.env"
    fi
fi

# Make scripts executable
chmod +x "$PROJECT_ROOT/src/claude-docker.sh"
chmod +x "$PROJECT_ROOT/src/startup.sh"

# Check for GPU support
echo ""
log_info "正在检查 GPU 支持..."

# Check if running with admin privileges
if [ "$EUID" -eq 0 ]; then
    log_ok "以管理员权限运行"

    # Check if NVIDIA drivers are installed
    if command -v nvidia-smi &> /dev/null; then
        log_ok "检测到 NVIDIA 驱动"

        # Check if Docker has GPU support
        if docker info 2>/dev/null | grep -q nvidia; then
            log_ok "Docker GPU 支持已安装"
        else
            log_warn "未找到 Docker GPU 支持"
            log_info "正在安装 NVIDIA Container Toolkit..."

            # Install without sudo (we're already root)
            distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
            curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
                gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
            curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | \
                sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
                tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null
            apt-get update -qq
            apt-get install -y -qq nvidia-container-toolkit
            nvidia-ctk runtime configure --runtime=docker > /dev/null
            systemctl restart docker
            log_ok "NVIDIA Container Toolkit 安装完成"
        fi
    else
        log_info "未检测到 NVIDIA GPU —— 跳过 GPU 支持"
    fi
else
    log_info "非 root 运行 —— 跳过 GPU 安装"
    log_info "   如需安装 GPU 支持,请运行:sudo $SCRIPT_DIR/install.sh"

    # Still check status for informational purposes
    if command -v nvidia-smi &> /dev/null; then
        if docker info 2>/dev/null | grep -q nvidia; then
            log_ok "   GPU 支持似乎已安装"
        else
            log_warn "   检测到 GPU,但未安装 Docker GPU 支持"
        fi
    fi
fi

echo ""
log_ok "安装完成! 🎉"
echo ""
log_info "后续步骤:"
log_info "1.(可选)编辑 $PROJECT_ROOT/.env 填入你的 API 密钥"
log_info "2. 运行 'source $TARGET_RC_FILE' 或新开一个终端"
log_info "3. 进入任意项目目录并运行 'claude-docker' 启动"
log_info "4. 若没有 API 密钥,Claude 会提示进行交互式登录认证"
