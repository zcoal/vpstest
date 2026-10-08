#!/usr/bin/env bash
#
# Cloudflare DDNS 交互式管理脚本
# 支持 Debian / Ubuntu / Alpine Linux
# 从 GitHub 直接调用：
#   bash <(curl -fsSL https://raw.githubusercontent.com/你的用户名/你的仓库/main/cf-ddns.sh)
#
set -euo pipefail

# ==================== 常量 ====================
CF_API_BASE="https://api.cloudflare.com/client/v4"
CONFIG_DIR="/etc/cf-ddns"
CONFIG_FILE="${CONFIG_DIR}/config"
LOG_FILE="/var/log/cf-ddns.log"
LOG_MAX_BYTES=1048576      # 日志超过 1MB 触发轮转
LOG_KEEP_LINES=500         # 轮转后保留最后 500 行
SCRIPT_DEST="/usr/local/bin/cf-ddns"
SERVICE_NAME="cf-ddns"
DEFAULT_INTERVAL=300

# ==================== 颜色 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ==================== 工具函数 ====================
info()  { printf "${GREEN}[INFO]${NC}  %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
error() { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }
die()   { error "$@"; exit 1; }

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true

    # 日志轮转（静默处理，不影响主流程）
    if [[ -f "$LOG_FILE" ]]; then
        local size
        size=$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)
        if [[ "${size:-0}" -gt "$LOG_MAX_BYTES" ]]; then
            tail -n "$LOG_KEEP_LINES" "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null \
                && mv "${LOG_FILE}.tmp" "$LOG_FILE" 2>/dev/null || true
        fi
    fi
}

pause() {
    printf "\n${CYAN}按 Enter 键返回菜单...${NC}"
    read -r _ 2>/dev/null || true
}

need_root() {
    [[ $EUID -eq 0 ]] || die "此操作需要 root 权限，请使用 sudo 运行。"
}

# ==================== 依赖检查与安装 ====================
detect_pkg_mgr() {
    if command -v apt-get >/dev/null 2>&1; then echo "apt"
    elif command -v apk >/dev/null 2>&1; then echo "apk"
    elif command -v dnf >/dev/null 2>&1; then echo "dnf"
    elif command -v yum >/dev/null 2>&1; then echo "yum"
    else echo "unknown"; fi
}

install_deps() {
    local missing=()
    command -v curl >/dev/null 2>&1 || missing+=("curl")
    command -v jq   >/dev/null 2>&1 || missing+=("jq")

    [[ ${#missing[@]} -eq 0 ]] && return 0

    local pm
    pm=$(detect_pkg_mgr)
    info "正在安装依赖: ${missing[*]}"
    case "$pm" in
        apt) apt-get update -qq && apt-get install -y -qq "${missing[@]}" ;;
        apk) apk add --no-cache "${missing[@]}" ;;
        dnf) dnf install -y "${missing[@]}" ;;
        yum) yum install -y "${missing[@]}" ;;
        *)   die "无法检测包管理器，请手动安装: ${missing[*]}" ;;
    esac
}

# ==================== 配置读写 ====================
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    fi
    CF_API_TOKEN="${CF_API_TOKEN:-}"
    CF_HOSTNAME="${CF_HOSTNAME:-}"
    CF_RECORD_TYPE="${CF_RECORD_TYPE:-A}"
    UPDATE_INTERVAL="${UPDATE_INTERVAL:-$DEFAULT_INTERVAL}"
    CF_PROXIED="${CF_PROXIED:-false}"
    CF_TTL="${CF_TTL:-1}"
    USE_IPV6="${USE_IPV6:-false}"
}

save_config() {
    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<EOF
CF_API_TOKEN="${CF_API_TOKEN}"
CF_HOSTNAME="${CF_HOSTNAME}"
CF_RECORD_TYPE="${CF_RECORD_TYPE}"
UPDATE_INTERVAL="${UPDATE_INTERVAL}"
CF_PROXIED="${CF_PROXIED}"
CF_TTL="${CF_TTL}"
USE_IPV6="${USE_IPV6}"
EOF
    chmod 600 "$CONFIG_FILE"
    info "配置已保存到 ${CONFIG_FILE}"
}

# ==================== Cloudflare API ====================
cf_api() {
    local method="$1" endpoint="$2" data="${3:-}"
    local url="${CF_API_BASE}${endpoint}"
    local args=(-s -X "$method" "$url"
        -H "Authorization: Bearer ${CF_API_TOKEN}"
        -H "Content-Type: application/json")
    [[ -n "$data" ]] && args+=(--data "$data")
    curl "${args[@]}"
}

get_public_ip() {
    local ip=""
    if [[ "$USE_IPV6" == "true" ]]; then
        ip=$(curl -6 -s --max-time 10 https://ipv6.icanhazip.com 2>/dev/null || true)
        [[ -z "$ip" ]] && ip=$(curl -6 -s --max-time 10 https://ifconfig.co 2>/dev/null || true)
    else
        ip=$(curl -4 -s --max-time 10 https://ipv4.icanhazip.com 2>/dev/null || true)
        [[ -z "$ip" ]] && ip=$(curl -4 -s --max-time 10 https://checkip.amazonaws.com 2>/dev/null || true)
    fi
    echo "$ip" | tr -d ' \n\r'
}

find_zone_id() {
    local full="$1"
    local IFS='.'
    read -r -a labels <<< "$full"
    local n=${#labels[@]}

    local i j candidate resp zid
    for ((i=0; i<=n-2; i++)); do
        candidate=""
        for ((j=i; j<n; j++)); do
            [[ -z "$candidate" ]] && candidate="${labels[j]}" || candidate="${candidate}.${labels[j]}"
        done
        resp=$(cf_api GET "/zones?name=${candidate}&status=active")
        zid=$(echo "$resp" | jq -r '.result[0].id // empty' 2>/dev/null)
        if [[ -n "$zid" ]]; then
            echo "$zid"
            return 0
        fi
    done
    return 1
}

find_record_id() {
    local zone_id="$1" record_name="$2" record_type="$3"
    local resp
    resp=$(cf_api GET "/zones/${zone_id}/dns_records?type=${record_type}&name=${record_name}")
    echo "$resp" | jq -r '.result[0].id // empty' 2>/dev/null
}

# ==================== 核心更新逻辑 ====================
do_update() {
    load_config

    if [[ -z "$CF_API_TOKEN" || -z "$CF_HOSTNAME" ]]; then
        error "配置不完整，请先通过菜单配置 API Token 和域名。"
        log "ERROR: 配置不完整"
        return 1
    fi

    local cf_comment="CF-DDNS"   # 记录备注

    log "===== 开始更新 ====="

    local current_ip
    current_ip=$(get_public_ip)
    if [[ -z "$current_ip" ]]; then
        error "无法获取公网 IP"
        log "ERROR: 无法获取公网 IP"
        return 1
    fi
    log "当前公网 IP: ${current_ip}"

    local zone_id
    zone_id=$(find_zone_id "$CF_HOSTNAME")
    if [[ -z "$zone_id" ]]; then
        error "未找到域名 ${CF_HOSTNAME} 对应的 Zone"
        log "ERROR: 未找到 Zone"
        return 1
    fi
    log "Zone ID: ${zone_id}"

    local record_id
    record_id=$(find_record_id "$zone_id" "$CF_HOSTNAME" "$CF_RECORD_TYPE")

    local data
    data=$(jq -n \
        --arg type "$CF_RECORD_TYPE" \
        --arg name "$CF_HOSTNAME" \
        --arg content "$current_ip" \
        --argjson ttl "$CF_TTL" \
        --argjson proxied "$CF_PROXIED" \
        --arg comment "$cf_comment" \
        '{type:$type, name:$name, content:$content, ttl:$ttl, proxied:$proxied, comment:$comment}')

    if [[ -n "$record_id" ]]; then
        local resp old_ip
        resp=$(cf_api GET "/zones/${zone_id}/dns_records/${record_id}")
        old_ip=$(echo "$resp" | jq -r '.result.content // empty' 2>/dev/null)

        if [[ "$old_ip" == "$current_ip" ]]; then
            info "IP 未变化 (${current_ip})，无需更新。"
            log "IP 未变化: ${current_ip}"
            log "===== 更新结束 ====="
            return 0
        fi

        local result success err
        result=$(cf_api PUT "/zones/${zone_id}/dns_records/${record_id}" "$data")
        success=$(echo "$result" | jq -r '.success' 2>/dev/null)

        if [[ "$success" == "true" ]]; then
            info "DNS 记录已更新: ${old_ip} → ${current_ip}"
            log "更新成功: ${old_ip} → ${current_ip}"
        else
            err=$(echo "$result" | jq -r '.errors[0].message // "未知错误"' 2>/dev/null)
            error "更新失败: ${err}"
            log "更新失败: ${err}"
            return 1
        fi
    else
        local result success err
        result=$(cf_api POST "/zones/${zone_id}/dns_records" "$data")
        success=$(echo "$result" | jq -r '.success' 2>/dev/null)

        if [[ "$success" == "true" ]]; then
            info "DNS 记录已创建: ${CF_HOSTNAME} → ${current_ip}"
            log "创建记录: ${CF_HOSTNAME} → ${current_ip}"
        else
            err=$(echo "$result" | jq -r '.errors[0].message // "未知错误"' 2>/dev/null)
            error "创建失败: ${err}"
            log "创建失败: ${err}"
            return 1
        fi
    fi

    log "===== 更新结束 ====="
    return 0
}

# ==================== 服务安装 ====================
install_systemd() {
    info "正在安装 systemd 服务..."

    cp "$0" "$SCRIPT_DEST" 2>/dev/null || {
        curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_DEST" || die "下载脚本失败"
    }
    chmod 755 "$SCRIPT_DEST"

    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Cloudflare DDNS Updater
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${SCRIPT_DEST} -s update
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}
EOF

    cat > "/etc/systemd/system/${SERVICE_NAME}.timer" <<EOF
[Unit]
Description=Run Cloudflare DDNS every ${UPDATE_INTERVAL} seconds
Requires=${SERVICE_NAME}.service

[Timer]
OnBootSec=30s
OnUnitActiveSec=${UPDATE_INTERVAL}s
Unit=${SERVICE_NAME}.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now "${SERVICE_NAME}.timer"

    info "systemd 服务已安装并启动。"
    info "查看状态: systemctl status ${SERVICE_NAME}.timer"
}

install_openrc() {
    info "正在安装 OpenRC 服务..."

    cp "$0" "$SCRIPT_DEST" 2>/dev/null || {
        curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_DEST" || die "下载脚本失败"
    }
    chmod 755 "$SCRIPT_DEST"

    cat > "/etc/init.d/${SERVICE_NAME}" <<'EOF'
#!/sbin/openrc-run

name="cf-ddns"
description="Cloudflare DDNS Updater"
command="/usr/local/bin/cf-ddns"
command_args="-s update"
command_background="false"
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/cf-ddns.log"
error_log="/var/log/cf-ddns.log"

depend() {
    need net
    after firewall
}

start_pre() {
    mkdir -p /var/log
}
EOF

    chmod +x "/etc/init.d/${SERVICE_NAME}"

    if command -v crontab >/dev/null 2>&1; then
        local cron_expr
        if [[ "$UPDATE_INTERVAL" -le 60 ]]; then
            cron_expr="* * * * *"
        elif [[ "$UPDATE_INTERVAL" -le 300 ]]; then
            cron_expr="*/5 * * * *"
        elif [[ "$UPDATE_INTERVAL" -le 600 ]]; then
            cron_expr="*/10 * * * *"
        elif [[ "$UPDATE_INTERVAL" -le 1800 ]]; then
            cron_expr="*/30 * * * *"
        else
            cron_expr="0 * * * *"
        fi

        local tmpcron
        tmpcron=$(mktemp)
        crontab -l 2>/dev/null | grep -v "cf-ddns" > "$tmpcron" || true
        echo "${cron_expr} ${SCRIPT_DEST} -s update >> ${LOG_FILE} 2>&1" >> "$tmpcron"
        crontab "$tmpcron"
        rm -f "$tmpcron"

        if command -v rc-update >/dev/null 2>&1; then
            rc-update add crond default 2>/dev/null || true
            rc-service crond start 2>/dev/null || true
        fi
        info "crontab 定时任务已添加 (间隔: ${UPDATE_INTERVAL}s)"
    else
        warn "未找到 crontab，请手动添加定时任务。"
    fi

    info "OpenRC 服务已安装。"
}

install_crontab_fallback() {
    cp "$0" "$SCRIPT_DEST" 2>/dev/null || {
        curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_DEST" || die "下载脚本失败"
    }
    chmod 755 "$SCRIPT_DEST"

    local cron_expr
    if [[ "$UPDATE_INTERVAL" -le 60 ]]; then
        cron_expr="* * * * *"
    elif [[ "$UPDATE_INTERVAL" -le 300 ]]; then
        cron_expr="*/5 * * * *"
    else
        cron_expr="*/10 * * * *"
    fi

    local tmpcron
    tmpcron=$(mktemp)
    crontab -l 2>/dev/null | grep -v "cf-ddns" > "$tmpcron" || true
    echo "${cron_expr} ${SCRIPT_DEST} -s update >> ${LOG_FILE} 2>&1" >> "$tmpcron"
    crontab "$tmpcron"
    rm -f "$tmpcron"

    info "crontab 定时任务已添加。"
}

uninstall_service() {
    info "正在卸载服务..."

    if command -v systemctl >/dev/null 2>&1; then
        systemctl stop "${SERVICE_NAME}.timer" 2>/dev/null || true
        systemctl disable "${SERVICE_NAME}.timer" 2>/dev/null || true
        rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
        rm -f "/etc/systemd/system/${SERVICE_NAME}.timer"
        systemctl daemon-reload 2>/dev/null || true
        info "systemd 服务已卸载。"
    fi

    if command -v rc-service >/dev/null 2>&1; then
        rc-service "${SERVICE_NAME}" stop 2>/dev/null || true
        rm -f "/etc/init.d/${SERVICE_NAME}"
        crontab -l 2>/dev/null | grep -v "cf-ddns" | crontab - 2>/dev/null || true
        info "OpenRC 服务已卸载。"
    fi

    if ! command -v systemctl >/dev/null 2>&1 && ! command -v rc-service >/dev/null 2>&1; then
        crontab -l 2>/dev/null | grep -v "cf-ddns" | crontab - 2>/dev/null || true
    fi

    rm -f "$SCRIPT_DEST"
    info "脚本已移除。配置文件保留在 ${CONFIG_DIR}"
}

service_status() {
    echo ""
    echo -e "${BOLD}===== 服务状态 =====${NC}"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl status "${SERVICE_NAME}.timer" --no-pager 2>/dev/null || echo "systemd 服务未安装"
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service "${SERVICE_NAME}" status 2>/dev/null || echo "OpenRC 服务未安装"
        crontab -l 2>/dev/null | grep -i "cf-ddns" || echo "无 crontab 任务"
    fi
    echo ""
    if [[ -f "$LOG_FILE" ]]; then
        echo -e "${BOLD}===== 最近日志 (最后 20 行) =====${NC}"
        tail -20 "$LOG_FILE"
    fi
}

# ==================== 菜单界面 ====================
show_banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    cat <<'BANNER'
   _____ ______   _____  _____  _   _  _____
  / ____|  ____| |  __ \|  __ \| \ | |/ ____|
 | |    | |__    | |  | | |  | |  \| | (___
 | |    |  __|   | |  | | |  | | . ` |\___ \
 | |____| |      | |__| | |__| | |\  |____) |
  \_____|_|      |_____/|_____/|_| \_|_____/
BANNER
    echo -e "${NC}"
    echo -e "  ${BOLD}Cloudflare DDNS 管理工具${NC}"
    echo -e "  支持 Debian / Ubuntu / Alpine Linux"
    echo -e "  ─────────────────────────────────────"
    echo ""
}

show_current_config() {
    load_config
    echo -e "${BOLD}当前配置：${NC}"
    if [[ -n "$CF_API_TOKEN" ]]; then
        echo -e "  API Token : ${GREEN}已设置${NC} (${CF_API_TOKEN:0:8}...)"
    else
        echo -e "  API Token : ${RED}未设置${NC}"
    fi
    echo -e "  域名      : ${CF_HOSTNAME:-${RED}未设置${NC}}"
    echo -e "  记录类型  : ${CF_RECORD_TYPE}"
    echo -e "  更新间隔  : ${UPDATE_INTERVAL} 秒"
    echo -e "  代理      : ${CF_PROXIED}"
    echo -e "  TTL       : ${CF_TTL}"
    echo ""
}

menu_configure() {
    clear
    echo -e "${BOLD}===== 配置 Cloudflare DDNS =====${NC}"
    echo -e "${YELLOW}提示：方括号中的值为当前值，直接回车即保留。${NC}\n"

    # ---- API Token ----
    if [[ -n "$CF_API_TOKEN" ]]; then
        printf "${CYAN}Cloudflare API Token${NC} [留空保留当前]: "
    else
        printf "${CYAN}Cloudflare API Token${NC} (需 Zone:DNS:Edit 权限): "
    fi
    read -r token
    if [[ -n "$token" ]]; then
        CF_API_TOKEN="$token"
    fi
    [[ -z "$CF_API_TOKEN" ]] && { error "API Token 不能为空"; pause; return 1; }

    # ---- 域名 ----
    if [[ -n "$CF_HOSTNAME" ]]; then
        printf "${CYAN}完整域名${NC} (如 home.example.com) [${CF_HOSTNAME}]: "
    else
        printf "${CYAN}完整域名${NC} (如 home.example.com): "
    fi
    read -r hostname
    if [[ -n "$hostname" ]]; then
        CF_HOSTNAME="$hostname"
    fi
    [[ -z "$CF_HOSTNAME" ]] && { error "域名不能为空"; pause; return 1; }

    # ---- 记录类型 ----
    echo ""
    echo -e "${CYAN}记录类型${NC} (当前: ${CF_RECORD_TYPE})"
    echo "  1) A    (IPv4)"
    echo "  2) AAAA (IPv6)"
    printf "选择 [1/2，直接回车保留当前]: "
    read -r rt
    case "${rt:-}" in
        1) CF_RECORD_TYPE="A";    USE_IPV6="false" ;;
        2) CF_RECORD_TYPE="AAAA"; USE_IPV6="true"  ;;
        "") ;;  # 保留
        *) warn "无效选项，保留当前值。" ;;
    esac

    # ---- 更新间隔 ----
    echo ""
    printf "${CYAN}更新间隔（秒）${NC} [${UPDATE_INTERVAL}]: "
    read -r interval
    if [[ -n "$interval" ]]; then
        if [[ "$interval" =~ ^[0-9]+$ ]] && [[ "$interval" -gt 0 ]]; then
            UPDATE_INTERVAL="$interval"
        else
            warn "无效数值，保留当前值 ${UPDATE_INTERVAL}。"
        fi
    fi

    # ---- Cloudflare 代理（重点优化：回车跳过 = 不启用）----
    echo ""
    printf "${CYAN}是否启用 Cloudflare 代理 (proxied)?${NC} [y/N，直接回车默认不启用]: "
    read -r proxied
    case "${proxied:-}" in
        [Yy]*) CF_PROXIED="true" ;;
        *)     CF_PROXIED="false" ;;
    esac

    # ---- TTL ----
    echo ""
    printf "${CYAN}TTL（秒，1=自动）${NC} [${CF_TTL}]: "
    read -r ttl
    if [[ -n "$ttl" ]]; then
        if [[ "$ttl" =~ ^[0-9]+$ ]]; then
            CF_TTL="$ttl"
        else
            warn "无效数值，保留当前值 ${CF_TTL}。"
        fi
    fi

    save_config

    # ---- 连接测试 ----
    echo ""
    info "正在测试 Cloudflare API 连接..."
    local zone_id
    zone_id=$(find_zone_id "$CF_HOSTNAME" 2>/dev/null) || true
    if [[ -n "$zone_id" ]]; then
        info "连接成功！Zone ID: ${zone_id}"
    else
        warn "未能找到域名对应的 Zone，请检查 API Token 权限和域名是否正确。"
    fi

    pause
}

menu_install_service() {
    need_root
    clear
    echo -e "${BOLD}===== 安装为系统服务 =====${NC}\n"

    load_config
    if [[ -z "$CF_API_TOKEN" || -z "$CF_HOSTNAME" ]]; then
        error "请先完成配置（菜单选项 1）。"
        pause
        return 1
    fi

    if command -v systemctl >/dev/null 2>&1; then
        info "检测到 systemd，将使用 systemd 服务。"
        install_systemd
    elif command -v rc-service >/dev/null 2>&1; then
        info "检测到 OpenRC，将使用 OpenRC + crontab。"
        install_openrc
    else
        warn "未检测到 systemd 或 OpenRC，将使用 crontab。"
        install_crontab_fallback
    fi

    pause
}

menu_update_now() {
    clear
    echo -e "${BOLD}===== 立即执行更新 =====${NC}\n"
    load_config
    do_update
    pause
}

menu_uninstall() {
    need_root
    clear
    echo -e "${BOLD}===== 卸载服务 =====${NC}\n"
    printf "${YELLOW}确定要卸载吗？配置将保留。 [y/N]: ${NC}"
    read -r confirm
    case "${confirm:-}" in
        [Yy]*) uninstall_service; pause ;;
        *)     info "已取消。"; pause ;;
    esac
}

# ==================== 主菜单 ====================
main_menu() {
    while true; do
        show_banner
        show_current_config

        echo -e "${BOLD}请选择操作：${NC}"
        echo -e "  ${GREEN}1)${NC} 配置 Cloudflare DDNS"
        echo -e "  ${GREEN}2)${NC} 立即执行更新"
        echo -e "  ${GREEN}3)${NC} 安装为系统服务（自动定时更新）"
        echo -e "  ${GREEN}4)${NC} 查看服务状态与日志"
        echo -e "  ${GREEN}5)${NC} 卸载服务"
        echo -e "  ${GREEN}0)${NC} 退出"
        echo ""
        printf "请输入选项 [0-5]: "
        read -r choice

        case "${choice:-}" in
            1) menu_configure ;;
            2) menu_update_now ;;
            3) menu_install_service ;;
            4) clear; service_status; pause ;;
            5) menu_uninstall ;;
            0) echo ""; info "再见！"; exit 0 ;;
            *) warn "无效选项，请重新选择。"; sleep 1 ;;
        esac
    done
}

# ==================== 入口 ====================
SCRIPT_URL="https://raw.githubusercontent.com/你的用户名/你的仓库/main/cf-ddns.sh"

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -s|--silent|--)
                # 静默标志 / 选项结束符，直接跳过
                shift
                ;;
            update)
                install_deps
                do_update
                exit $?
                ;;
            configure)
                install_deps
                menu_configure
                exit 0
                ;;
            install)
                need_root
                install_deps
                load_config
                if command -v systemctl >/dev/null 2>&1; then
                    install_systemd
                elif command -v rc-service >/dev/null 2>&1; then
                    install_openrc
                else
                    install_crontab_fallback
                fi
                exit 0
                ;;
            uninstall)
                need_root
                uninstall_service
                exit 0
                ;;
            status)
                service_status
                exit 0
                ;;
            -h|--help)
                cat <<HELP
Cloudflare DDNS 管理工具

用法:
  $(basename "$0")                    交互式菜单
  $(basename "$0") update             立即执行更新
  $(basename "$0") configure          配置向导
  $(basename "$0") install            安装系统服务
  $(basename "$0") uninstall          卸载服务
  $(basename "$0") status             查看状态

从 GitHub 直接运行:
  bash <(curl -fsSL ${SCRIPT_URL})

传递参数:
  bash <(curl -fsSL ${SCRIPT_URL}) -s -- update
HELP
                exit 0
                ;;
            *)
                error "未知参数: $1"
                exit 1
                ;;
        esac
    done

    install_deps
    main_menu
}

main "$@"