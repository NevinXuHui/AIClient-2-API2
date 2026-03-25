#!/usr/bin/env bash

set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="aiclient2api"
SERVICE_UNIT=""
FORCE_PULL=0
FOREGROUND=0
DRY_RUN=0

print_header() {
    echo "========================================"
    echo "  AI Client 2 API 安装部署脚本"
    echo "========================================"
    echo
}

print_usage() {
    cat <<'EOF'
用法:
  ./install-and-run.sh [选项]

选项:
  --pull                 先执行 git pull --ff-only
  --foreground           不安装 systemd，直接前台启动
  --dry-run              仅打印将执行的命令，不真正执行
  --service-name <name>  指定 systemd 服务名，默认 aiclient2api
  -h, --help             显示帮助
EOF
}

die() {
    echo "[错误] $*" >&2
    exit 1
}

warn() {
    echo "[警告] $*"
}

info() {
    echo "[信息] $*"
}

success() {
    echo "[成功] $*"
}

run_cmd() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '[DRY-RUN]'
        printf ' %q' "$@"
        printf '\n'
        return 0
    fi

    "$@"
}

run_root_cmd() {
    if [ "$EUID" -eq 0 ]; then
        run_cmd "$@"
        return 0
    fi

    if ! command -v sudo > /dev/null 2>&1; then
        die "当前操作需要 root 或 sudo 权限"
    fi

    run_cmd sudo "$@"
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --pull)
                FORCE_PULL=1
                ;;
            --foreground)
                FOREGROUND=1
                ;;
            --dry-run)
                DRY_RUN=1
                ;;
            --service-name)
                shift
                [ "$#" -gt 0 ] || die "--service-name 缺少参数"
                SERVICE_NAME="$1"
                ;;
            -h|--help)
                print_usage
                exit 0
                ;;
            *)
                die "不支持的参数: $1"
                ;;
        esac
        shift
    done
}

ensure_project_root() {
    cd "$PROJECT_DIR"

    [ -f "$PROJECT_DIR/package.json" ] || die "未找到 package.json，请确认脚本位于项目根目录"
    [ -f "$PROJECT_DIR/src/core/master.js" ] || die "未找到 src/core/master.js"

    if [ -f "$PROJECT_DIR/pnpm-lock.yaml" ] && [ -f "$PROJECT_DIR/package-lock.json" ]; then
        warn "同时检测到 pnpm-lock.yaml 和 package-lock.json，脚本将优先使用已安装的包管理器，请确认锁文件策略一致"
    fi

    success "项目文件检查完成"
}

update_code_if_needed() {
    if [ "$FORCE_PULL" -ne 1 ]; then
        return 0
    fi

    info "正在从远程仓库拉取最新代码..."

    if ! command -v git > /dev/null 2>&1; then
        warn "未检测到 Git，跳过代码拉取"
        return 0
    fi

    if ! run_cmd git -C "$PROJECT_DIR" pull --ff-only; then
        warn "Git pull 失败，请检查网络、权限或手动处理分支状态"
        return 0
    fi

    success "代码已更新"
}

check_runtime() {
    info "正在检查 Node.js 和包管理器..."

    command -v node > /dev/null 2>&1 || die "未检测到 Node.js，请先安装 Node.js LTS"
    command -v npm > /dev/null 2>&1 || die "npm 不可用，请重新安装 Node.js"

    NODE_BIN="$(command -v node)"
    success "Node.js 已安装，版本: $(node --version)"

    if command -v pnpm > /dev/null 2>&1; then
        PKG_MANAGER="pnpm"
        PKG_MANAGER_BIN="$(command -v pnpm)"
        if [ -f "$PROJECT_DIR/pnpm-lock.yaml" ]; then
            INSTALL_CMD=("$PKG_MANAGER_BIN" install --frozen-lockfile)
        else
            INSTALL_CMD=("$PKG_MANAGER_BIN" install)
        fi
    else
        PKG_MANAGER="npm"
        PKG_MANAGER_BIN="$(command -v npm)"
        if [ -f "$PROJECT_DIR/package-lock.json" ]; then
            INSTALL_CMD=("$PKG_MANAGER_BIN" ci)
        else
            INSTALL_CMD=("$PKG_MANAGER_BIN" install)
        fi
    fi

    success "将使用 ${PKG_MANAGER} 安装依赖"
}

install_dependencies() {
    info "正在安装/更新依赖..."
    run_cmd "${INSTALL_CMD[@]}"
    success "依赖安装完成"
}

start_foreground() {
    echo
    echo "========================================"
    echo "  前台启动 AIClient2API 服务器"
    echo "========================================"
    echo
    echo "服务地址: http://localhost:3000"
    echo "管理端口: http://localhost:3100"
    echo "按 Ctrl+C 停止服务"
    echo

    exec "$NODE_BIN" "$PROJECT_DIR/src/core/master.js"
}

check_systemd() {
    [ "$(uname -s)" = "Linux" ] || die "systemd 模式仅支持 Linux；如需直接运行可使用 --foreground"
    command -v systemctl > /dev/null 2>&1 || die "未检测到 systemctl；如需直接运行可使用 --foreground"
}

resolve_service_user() {
    if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
        SERVICE_USER="$SUDO_USER"
    else
        SERVICE_USER="$(id -un)"
    fi

    SERVICE_GROUP="$(id -gn "$SERVICE_USER")"

    if command -v getent > /dev/null 2>&1; then
        SERVICE_HOME="$(getent passwd "$SERVICE_USER" | cut -d: -f6)"
    else
        SERVICE_HOME="$HOME"
    fi

    [ -n "$SERVICE_HOME" ] || die "无法解析服务用户目录"
}

write_service_file() {
    local temp_service_file

    SERVICE_UNIT="${SERVICE_NAME}.service"
    SERVICE_FILE="/etc/systemd/system/${SERVICE_UNIT}"
    temp_service_file="$(mktemp)"

    cat > "$temp_service_file" <<EOF
[Unit]
Description=AIClient2API Service
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
WorkingDirectory=${PROJECT_DIR}
Environment=HOME=${SERVICE_HOME}
Environment=NODE_ENV=production
ExecStart=${NODE_BIN} ${PROJECT_DIR}/src/core/master.js
Restart=always
RestartSec=5
KillSignal=SIGTERM
TimeoutStopSec=20
NoNewPrivileges=true
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    info "正在写入 systemd 服务文件: ${SERVICE_FILE}"
    if ! run_root_cmd install -m 0644 "$temp_service_file" "$SERVICE_FILE"; then
        rm -f -- "$temp_service_file"
        die "写入 systemd 服务文件失败"
    fi

    rm -f -- "$temp_service_file"
}

enable_and_restart_service() {
    info "正在重新加载 systemd 配置..."
    run_root_cmd systemctl daemon-reload

    info "正在设置开机自启..."
    run_root_cmd systemctl enable "$SERVICE_UNIT"

    info "正在启动服务..."
    run_root_cmd systemctl restart "$SERVICE_UNIT"

    if [ "$DRY_RUN" -eq 1 ]; then
        success "Dry-run 完成，未实际启动服务"
        return 0
    fi

    if [ "$EUID" -eq 0 ]; then
        if ! systemctl is-active --quiet "$SERVICE_UNIT"; then
            warn "服务已注册，但当前未处于运行状态，请执行 'sudo journalctl -u ${SERVICE_UNIT} -n 100 --no-pager' 排查"
            return 1
        fi
    else
        if ! sudo systemctl is-active --quiet "$SERVICE_UNIT"; then
            warn "服务已注册，但当前未处于运行状态，请执行 'sudo journalctl -u ${SERVICE_UNIT} -n 100 --no-pager' 排查"
            return 1
        fi
    fi

    success "systemd 服务已启动并设置为开机自启"
    echo
    echo "服务名称: ${SERVICE_UNIT}"
    echo "查看状态: sudo systemctl status ${SERVICE_UNIT}"
    echo "查看日志: sudo journalctl -u ${SERVICE_UNIT} -f"
    echo "重启服务: sudo systemctl restart ${SERVICE_UNIT}"
    echo "停止服务: sudo systemctl stop ${SERVICE_UNIT}"
}

main() {
    print_header
    parse_args "$@"
    ensure_project_root
    update_code_if_needed
    check_runtime
    install_dependencies

    if [ "$FOREGROUND" -eq 1 ]; then
        start_foreground
        return 0
    fi

    check_systemd
    resolve_service_user
    write_service_file
    enable_and_restart_service
}

main "$@"
