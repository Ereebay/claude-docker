#!/usr/bin/env bash
set -euo pipefail
trap 'echo "$0: line $LINENO: $BASH_COMMAND: exitcode $?"' ERR

# ABOUTME: Startup script for claude-docker container with MCP server
# ABOUTME: Loads twilio env vars, checks for .credentials.json, copies CLAUDE.md template if no claude.md in claude-docker/claude-home.
# ABOUTME: Starts claude code with permissions bypass and continues from last session.
# NOTE: Need to call claude-docker --rebuild to integrate changes.

# Load shared logging helpers (baked into the image at build time). Fall back to
# minimal inline versions for older images built before lib-common.sh was copied.
if [ -f /app/lib-common.sh ]; then
    source /app/lib-common.sh
fi
if ! command -v log_info >/dev/null 2>&1; then
    log_ok()   { printf '[成功] %s\n' "$*"; }
    log_info() { printf '[信息] %s\n' "$*"; }
    log_warn() { printf '[警告] %s\n' "$*"; }
    log_err()  { printf '[错误] %s\n' "$*" >&2; }
fi

# Load environment variables from .env if it exists
# Use the .env file baked into the image at build time
if [ -f /app/.env ]; then
    log_info "加载镜像内置环境配置:/app/.env"
    set -a
    source /app/.env 2>/dev/null || true
    set +a

    # Export Twilio variables for runtime use
    export TWILIO_ACCOUNT_SID
    export TWILIO_AUTH_TOKEN
    export TWILIO_FROM_NUMBER
    export TWILIO_TO_NUMBER
else
    log_warn "镜像中未找到 .env 文件。"
fi

# Optional: host-exec SSH wrapper (container -> host). Only active when HOST_EXEC is enabled
# on the host launcher. SECURITY: this breaks container isolation — see .env.example warning.
if [ -n "${HOST_EXEC:-}" ] && [ "${HOST_EXEC}" != "0" ] && [ "${HOST_EXEC}" != "false" ]; then
    HOST_EXEC_HOST="${HOST_EXEC_HOST:-host.docker.internal}"
    HOST_EXEC_USER="${HOST_EXEC_USER:-}"

    # Ensure the mac-host SSH alias exists in the (mounted) ssh config
    SSH_CFG="$HOME/.ssh/config"
    mkdir -p "$HOME/.ssh"
    if [ -n "$HOST_EXEC_USER" ] && ! grep -q "^Host mac-host$" "$SSH_CFG" 2>/dev/null; then
        cat >> "$SSH_CFG" << EOF

Host mac-host
    HostName $HOST_EXEC_HOST
    User $HOST_EXEC_USER
    IdentityFile ~/.ssh/id_rsa
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
EOF
        chmod 600 "$SSH_CFG" 2>/dev/null || true
    fi

    # Create the host-exec wrapper on PATH (~/.local/bin is already in PATH)
    mkdir -p "$HOME/.local/bin"
    cat > "$HOME/.local/bin/host-exec" << 'WRAP'
#!/usr/bin/env bash
# Run a command on the host via SSH. Enabled by HOST_EXEC=1 at launch.
exec ssh mac-host "$@"
WRAP
    chmod +x "$HOME/.local/bin/host-exec"
    log_ok "已启用宿主机 SSH wrapper: host-exec -> mac-host"
fi

# Check for existing authentication
if [ -f "$HOME/.claude/.credentials.json" ]; then
    log_ok "已找到 Claude 登录凭证"
else
    log_info "未找到登录凭证 —— 你需要登录,登录后将保存供后续会话使用。"
fi

# Handle CLAUDE.md template
if [ ! -f "$HOME/.claude/CLAUDE.md" ]; then
    log_ok "未找到 $HOME/.claude/CLAUDE.md —— 复制模板"
    # Copy from the template that was baked into the image
    if [ -f "/app/.claude/CLAUDE.md" ]; then
        cp "/app/.claude/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
    elif [ -f "/home/claude-user/.claude.template/CLAUDE.md" ]; then
        # Fallback for existing images
        cp "/home/claude-user/.claude.template/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
    fi
    log_info "模板已复制到:$HOME/.claude/CLAUDE.md"
else
    log_ok "使用已有 CLAUDE.md:$HOME/.claude/CLAUDE.md"
    log_info "宿主机默认对应路径:~/.claude-docker/claude-home/CLAUDE.md"
    log_info "如需恢复默认模板,删除该文件后重新启动。"
fi

# Verify Twilio MCP configuration
if [ -n "$TWILIO_ACCOUNT_SID" ] && [ -n "$TWILIO_AUTH_TOKEN" ]; then
    log_ok "Twilio MCP 已配置 —— 短信通知已启用"
else
    log_info "未找到 Twilio 凭证 —— 短信通知已禁用"
fi

# # Export environment variables from settings.json
# # This is a workaround for Docker container not properly exposing these to Claude
# if [ -f "$HOME/.claude/settings.json" ] && command -v jq >/dev/null 2>&1; then
#     echo "Loading environment variables from settings.json..."
#     # First remove comments from JSON, then extract env vars
#     # Using sed to remove // comments before parsing with jq
#     while IFS='=' read -r key value; do
#         if [ -n "$key" ] && [ -n "$value" ]; then
#             export "$key=$value"
#             echo "  Exported: $key=$value"
#         fi
#     done < <(sed 's://.*$::g' "$HOME/.claude/settings.json" | jq -r '.env // {} | to_entries | .[] | "\(.key)=\(.value)"' 2>/dev/null)
# fi

# Start Claude Code with permissions bypass
log_info "启动 Claude Code..."
exec claude $CLAUDE_CONTINUE_FLAG --dangerously-skip-permissions "$@"
