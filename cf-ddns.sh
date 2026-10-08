#!/usr/bin/env bash
#
# Cloudflare DDNS 交互式管理脚本（多记录 / IPv4 + IPv6 混合）
# 支持 Debian / Ubuntu / Alpine Linux
#
set -euo pipefail

# ==================== 常量 ====================
CF_API_BASE="https://api.cloudflare.com/client/v4"
CONFIG_DIR="/etc/cf-ddns"
CONFIG_FILE="${CONFIG_DIR}/config"
RECORDS_FILE="${CONFIG_DIR}/records"
LOG_FILE="/var/log/cf-ddns.log"
LOG_MAX_BYTES=1048576
LOG_KEEP_LINES=500
SCRIPT_DEST="/usr/local/bin/cf-ddns"
SERVICE_NAME="cf-ddns"
DEFAULT_INTERVAL=300
DEFAULT_COMMENT="CF-DDNS"

# ==================== 颜色 ====================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ==================== 工具函数 ====================
info()  { printf "${GREEN}[INFO]${NC}  %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
error() { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }
die()   { error "$@"; exit 1; }

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
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

# ==================== 依赖 ====================
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

    local pm; pm=$(detect_pkg_mgr)
    info "正在安装依赖: ${missing[*]}"
    case "$pm" in
        apt) apt-get update -qq && apt-get install -y -qq "${missing[@]}" ;;
        apk) apk add --no-cache "${missing[@]}" ;;
        dnf) dnf install -y "${missing[@]}" ;;
        yum) yum install -y "${missing[@]}" ;;
        *)   die "无法检测包管理器，请手动安装: ${missing[*]}" ;;
    esac
}

# ==================== 配置 ====================
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    fi
    CF_API_TOKEN="${CF_API_TOKEN:-}"
    UPDATE_INTERVAL="${UPDATE_INTERVAL:-$DEFAULT_INTERVAL}"
}

save_config() {
    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<EOF
CF_API_TOKEN="${CF_API_TOKEN}"
UPDATE_INTERVAL="${UPDATE_INTERVAL}"
EOF
    chmod 600 "$CONFIG_FILE"
    info "配置已保存到 ${CONFIG_FILE}"
}

# 从旧版单记录配置迁移
migrate_old_config() {
    [[ -f "$RECORDS_FILE" ]] && return 0
    [[ -f "$CONFIG_FILE" ]] || return 0

    # 读取旧变量（不覆盖新变量）
    local _tok="" _host="" _type="" _prox="" _ttl=""
    # shellcheck source=/dev/null
    _tok=$(grep -E '^CF_API_TOKEN=' "$CONFIG_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true)
    _host=$(grep -E '^CF_HOSTNAME=' "$CONFIG_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true)
    _type=$(grep -E '^CF_RECORD_TYPE=' "$CONFIG_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true)
    _prox=$(grep -E '^CF_PROXIED=' "$CONFIG_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true)
    _ttl=$(grep -E '^CF_TTL=' "$CONFIG_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true)

    if [[ -n "$_host" ]]; then
        mkdir -p "$CONFIG_DIR"
        printf '%s|%s|%s|%s|%s\n' \
            "$_host" "${_type:-A}" "${_prox:-false}" "${_ttl:-1}" "$DEFAULT_COMMENT" \
            > "$RECORDS_FILE"
        info "已从旧配置迁移记录: ${_host}"

        # 重写 config，只留 Token 和间隔
        local _interval
        _interval=$(grep -E '^UPDATE_INTERVAL=' "$CONFIG_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true)
        cat > "$CONFIG_FILE" <<EOF
CF_API_TOKEN="${_tok}"
UPDATE_INTERVAL="${_interval:-$DEFAULT_INTERVAL}"
EOF
        chmod 600 "$CONFIG_FILE"
    fi
}

# ==================== 记录管理 ====================
declare -a RECORDS=()

load_records() {
    RECORDS=()
    [[ -f "$RECORDS_FILE" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        RECORDS+=("$line")
    done < "$RECORDS_FILE"
}

save_records() {
    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"
    : > "$RECORDS_FILE"
    local r
    for r in "${RECORDS[@]:-}"; do
        [[ -n "$r" ]] && echo "$r" >> "$RECORDS_FILE"
    done
    chmod 600 "$RECORDS_FILE"
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

get_public_ip_v4() {
    local ip=""
    ip=$(curl -4 -s --max-time 10 https://ipv4.icanhazip.com 2>/dev/null || true)
    [[ -z "$ip" ]] && ip=$(curl -4 -s --max-time 10 https://checkip.amazonaws.com 2>/dev/null || true)
    echo "$ip" | tr -d ' \n\r'
}

get_public_ip_v6() {
    local ip=""
    ip=$(curl -6 -s --max-time 10 https://ipv6.icanhazip.com 2>/dev/null || true)
    [[ -z "$ip" ]] && ip=$(curl -6 -s --max-time 10 https://ifconfig.co 2>/dev/null || true)
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

# ==================== 单条记录更新 ====================
# 参数: hostname rtype current_ip proxied ttl comment
update_single_record() {
    local hostname="$1" rtype="$2" current_ip="$3" proxied="$4" ttl="$5" comment="$6"

    local zone_id
    zone_id=$(find_zone_id "$hostname")
    if [[ -z "$zone_id" ]]; then
        error "  ${hostname} (${rtype}): 未找到对应 Zone"
        log "ERROR: ${hostname} 未找到 Zone"
        return 1
    fi

    local record_id
    record_id=$(find_record_id "$zone_id" "$hostname" "$rtype")

    local data
    data=$(jq -n \
        --arg type "$rtype" \
        --arg name "$hostname" \
        --arg content "$current_ip" \
        --argjson ttl "$ttl" \
        --argjson proxied "$proxied" \
        --arg comment "$comment" \
        '{type:$type, name:$name, content:$content, ttl:$ttl, proxied:$proxied, comment:$comment}')

    if [[ -n "$record_id" ]]; then
        local resp old_ip
        resp=$(cf_api GET "/zones/${zone_id}/dns_records/${record_id}")
        old_ip=$(echo "$resp" | jq -r '.result.content // empty' 2>/dev/null)

        if [[ "$old_ip" == "$current_ip" ]]; then
            info "  ${hostname} (${rtype}): IP 未变化 (${current_ip})"
            log "${hostname} (${rtype}): IP 未变化 ${current_ip}"
            return 0
        fi

        local result success err
        result=$(cf_api PUT "/zones/${zone_id}/dns_records/${record_id}" "$data")
        success=$(echo "$result" | jq -r '.success' 2>/dev/null)
        if [[ "$success" == "true" ]]; then
            info "  ${hostname} (${rtype}): ${old_ip} → ${current_ip}"
            log "${hostname} (${rtype}): 更新成功 ${old_ip} → ${current_ip}"
        else
            err=$(echo "$result" | jq -r '.errors[0].message // "未知错误"' 2>/dev/null)
            error "  ${hostname} (${rtype}): 更新失败 - ${err}"
            log "${hostname} (${rtype}): 更新失败 - ${err}"
            return 1
        fi
    else
        local result success err
        result=$(cf_api POST "/zones/${zone_id}/dns_records" "$data")
        success=$(echo "$result" | jq -r '.success' 2>/dev/null)
        if [[ "$success" == "true" ]]; then
            info "  ${hostname} (${rtype}): 已创建 → ${current_ip}"
            log "${hostname} (${rtype}): 创建成功 → ${current_ip}"
        else
            err=$(echo "$result" | jq -r '.errors[0].message // "未知错误"' 2>/dev/null)
            error "  ${hostname} (${rtype}): 创建失败 - ${err}"
            log "${hostname} (${rtype}): 创建失败 - ${err}"
            return 1
        fi
    fi
    return 0
}

# ==================== 批量更新 ====================
do_update() {
    load_config
    migrate_old_config
    load_records

    if [[ -z "$CF_API_TOKEN" ]]; then
        error "配置不完整：缺少 API Token。"
        log "ERROR: 缺少 API Token"
        return 1
    fi

    if [[ ${#RECORDS[@]} -eq 0 ]]; then
        error "未配置任何域名记录。"
        log "ERROR: 无记录"
        return 1
    fi

    log "===== 开始更新 (${#RECORDS[@]} 条记录) ====="

    # IP 缓存（同类型只查一次）
    local ipv4="" ipv6=""
    local failed=0
    local rec hostname rtype proxied ttl comment current_ip

    for rec in "${RECORDS[@]}"; do
        IFS='|' read -r hostname rtype proxied ttl comment <<< "$rec"
        [[ -z "$hostname" || -z "$rtype" ]] && continue

        # 默认值
        rtype="${rtype:-A}"
        proxied="${proxied:-false}"
        ttl="${ttl:-1}"
        comment="${comment:-$DEFAULT_COMMENT}"

        if [[ "$rtype" == "A" ]]; then
            [[ -z "$ipv4" ]] && ipv4=$(get_public_ip_v4)
            current_ip="$ipv4"
        elif [[ "$rtype" == "AAAA" ]]; then
            [[ -z "$ipv6" ]] && ipv6=$(get_public_ip_v6)
            current_ip="$ipv6"
        else
            error "  ${hostname}: 未知记录类型 ${rtype}"
            log "ERROR: 未知类型 ${rtype}"
            failed=$((failed+1))
            continue
        fi

        if [[ -z "$current_ip" ]]; then
            error "  ${hostname} (${rtype}): 无法获取公网 IP"
            log "ERROR: ${hostname} (${rtype}) 无法获取 IP"
            failed=$((failed+1))
            continue
        fi

        update_single_record "$hostname" "$rtype" "$current_ip" "$proxied" "$ttl" "$comment" || failed=$((failed+1))
    done

    if [[ $failed -gt 0 ]]; then
        log "===== 更新结束 (失败 ${failed} 条) ====="
        return 1
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
        if [[ "$UPDATE_INTERVAL" -le 60 ]]; then cron_expr="* * * * *"
        elif [[ "$UPDATE_INTERVAL" -le 300 ]]; then cron_expr="*/5 * * * *"
        elif [[ "$UPDATE_INTERVAL" -le 600 ]]; then cron_expr="*/10 * * * *"
        elif [[ "$UPDATE_INTERVAL" -le 1800 ]]; then cron_expr="*/30 * * * *"
        else cron_expr="0 * * * *"; fi

        local tmpcron; tmpcron=$(mktemp)
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
    if [[ "$UPDATE_INTERVAL" -le 60 ]]; then cron_expr="* * * * *"
    elif [[ "$UPDATE_INTERVAL" -le 300 ]]; then cron_expr="*/5 * * * *"
    else cron_expr="*/10 * * * *"; fi

    local tmpcron; tmpcron=$(mktemp)
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
        rm -f "/etc/systemd/system/${SERVICE_NAME}.service" \
              "/etc/systemd/system/${SERVICE_NAME}.timer"
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

# ==================== 界面 ====================
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
    echo -e "  支持多域名记录 / IPv4 + IPv6 混合"
    echo -e "  ─────────────────────────────────────"
    echo ""
}

show_current_config() {
    load_config
    load_records
    echo -e "${BOLD}当前配置：${NC}"
    if [[ -n "$CF_API_TOKEN" ]]; then
        echo -e "  API Token : ${GREEN}已设置${NC} (${CF_API_TOKEN:0:8}...)"
    else
        echo -e "  API Token : ${RED}未设置${NC}"
    fi
    echo -e "  更新间隔  : ${UPDATE_INTERVAL} 秒"
    echo -e "  域名记录  : ${#RECORDS[@]} 条"
    if [[ ${#RECORDS[@]} -gt 0 ]]; then
        local i=1 rec host rtype
        for rec in "${RECORDS[@]}"; do
            IFS='|' read -r host rtype _ _ _ <<< "$rec"
            echo -e "    ${GREEN}${i})${NC} ${host}  [${rtype}]"
            i=$((i+1))
        done
    fi
    echo ""
}

# -------- 配置 Token / Interval --------
menu_configure() {
    clear
    echo -e "${BOLD}===== 配置 API Token 与更新间隔 =====${NC}"
    echo -e "${YELLOW}方括号中的值为当前值，直接回车即保留。${NC}\n"

    if [[ -n "$CF_API_TOKEN" ]]; then
        printf "${CYAN}Cloudflare API Token${NC} [留空保留当前]: "
    else
        printf "${CYAN}Cloudflare API Token${NC} (需 Zone:DNS:Edit 权限): "
    fi
    read -r token
    if [[ -n "$token" ]]; then
        CF_API_TOKEN="$token"
    fi

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

    save_config

    if [[ -z "$CF_API_TOKEN" ]]; then
        warn "API Token 为空，请稍后配置。"
    fi

    pause
}

# -------- 记录管理 --------
menu_records() {
    while true; do
        clear
        echo -e "${BOLD}===== 管理域名记录 =====${NC}\n"
        load_records

        if [[ ${#RECORDS[@]} -eq 0 ]]; then
            echo -e "${YELLOW}（暂无记录）${NC}"
        else
            printf "${BOLD}%-3s %-30s %-6s %-9s %-6s %s${NC}\n" "#" "域名" "类型" "代理" "TTL" "备注"
            echo "──────────────────────────────────────────────────────────────"
            local i=1 rec host rtype prox ttl comment
            for rec in "${RECORDS[@]}"; do
                IFS='|' read -r host rtype prox ttl comment <<< "$rec"
                printf "%-3s %-30s %-6s %-9s %-6s %s\n" \
                    "$i" "$host" "$rtype" "${prox:-false}" "${ttl:-1}" "${comment:-}"
                i=$((i+1))
            done
        fi
        echo ""
        echo -e "  ${GREEN}1)${NC} 添加记录"
        echo -e "  ${GREEN}2)${NC} 删除记录"
        echo -e "  ${GREEN}3)${NC} 清空全部"
        echo -e "  ${GREEN}0)${NC} 返回上级菜单"
        printf "请选择 [0-3]: "
        read -r choice

        case "${choice:-}" in
            1) add_record ;;
            2) del_record ;;
            3)
                printf "${YELLOW}确定清空全部记录？ [y/N]: ${NC}"
                read -r c
                case "${c:-}" in
                    [Yy]*) RECORDS=(); save_records; info "已清空。" ;;
                    *)     info "已取消。" ;;
                esac
                sleep 1
                ;;
            0) return 0 ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

add_record() {
    echo ""
    echo -e "${BOLD}── 添加记录 ──${NC}"
    printf "${CYAN}完整域名${NC} (如 home.example.com 或 *.example.com): "
    read -r host
    [[ -z "$host" ]] && { warn "域名不能为空。"; sleep 1; return 0; }

    echo -e "${CYAN}记录类型：${NC}"
    echo "  1) A    (IPv4)"
    echo "  2) AAAA (IPv6)"
    printf "选择 [1/2，默认 1]: "
    read -r t
    local rtype
    case "${t:-1}" in
        2) rtype="AAAA" ;;
        *) rtype="A" ;;
    esac

    printf "${CYAN}启用 Cloudflare 代理 (proxied)?${NC} [y/N，回车默认不启用]: "
    read -r p
    local prox
    case "${p:-}" in
        [Yy]*) prox="true" ;;
        *)     prox="false" ;;
    esac

    printf "${CYAN}TTL（秒，1=自动）${NC} [1]: "
    read -r ttl
    ttl="${ttl:-1}"
    if ! [[ "$ttl" =~ ^[0-9]+$ ]]; then
        warn "无效 TTL，使用 1。"
        ttl=1
    fi

    printf "${CYAN}备注${NC} [${DEFAULT_COMMENT}]: "
    read -r comment
    comment="${comment:-$DEFAULT_COMMENT}"

    # 检查重复（同域名+同类型）
    local rec h rt
    for rec in "${RECORDS[@]:-}"; do
        IFS='|' read -r h rt _ _ _ <<< "$rec"
        if [[ "$h" == "$host" && "$rt" == "$rtype" ]]; then
            warn "已存在相同域名与类型的记录: ${host} [${rtype}]"
            sleep 2
            return 0
        fi
    done

    RECORDS+=("${host}|${rtype}|${prox}|${ttl}|${comment}")
    save_records
    info "已添加: ${host} [${rtype}]"
    sleep 1
}

del_record() {
    load_records
    if [[ ${#RECORDS[@]} -eq 0 ]]; then
        warn "暂无记录。"
        sleep 1
        return 0
    fi

    printf "${CYAN}输入要删除的编号（多个用空格分隔，回车取消）: ${NC}"
    read -r nums
    [[ -z "$nums" ]] && return 0

    # 收集要删的索引（1-based）
    local idx
    declare -a del_idx=()
    for idx in $nums; do
        if [[ "$idx" =~ ^[0-9]+$ ]] && [[ "$idx" -ge 1 && "$idx" -le ${#RECORDS[@]} ]]; then
            del_idx+=("$idx")
        else
            warn "跳过无效编号: $idx"
        fi
    done

    [[ ${#del_idx[@]} -eq 0 ]] && { warn "没有有效编号。"; sleep 1; return 0; }

    # 从大到小删除，避免索引错乱
    local sorted
    sorted=$(printf '%s\n' "${del_idx[@]}" | sort -rn)
    local n
    while IFS= read -r n; do
        [[ -z "$n" ]] && continue
        unset 'RECORDS[n-1]'
    done <<< "$sorted"

    # 重建数组（去掉空洞）
    local newarr=()
    local r
    for r in "${RECORDS[@]:-}"; do
        [[ -n "$r" ]] && newarr+=("$r")
    done
    RECORDS=("${newarr[@]:-}")
    save_records
    info "已删除 ${#del_idx[@]} 条记录。"
    sleep 1
}

# -------- 其它菜单 --------
menu_update_now() {
    clear
    echo -e "${BOLD}===== 立即执行更新 =====${NC}\n"
    do_update
    pause
}

menu_install_service() {
    need_root
    clear
    echo -e "${BOLD}===== 安装为系统服务 =====${NC}\n"

    load_config
    migrate_old_config
    load_records

    if [[ -z "$CF_API_TOKEN" ]]; then
        error "请先配置 API Token。"
        pause
        return 1
    fi
    if [[ ${#RECORDS[@]} -eq 0 ]]; then
        error "请先添加至少一条域名记录。"
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
        echo -e "  ${GREEN}1)${NC} 配置 API Token 与更新间隔"
        echo -e "  ${GREEN}2)${NC} 管理域名记录（增 / 删 / 列表）"
        echo -e "  ${GREEN}3)${NC} 立即执行更新"
        echo -e "  ${GREEN}4)${NC} 安装为系统服务（自动定时更新）"
        echo -e "  ${GREEN}5)${NC} 查看服务状态与日志"
        echo -e "  ${GREEN}6)${NC} 卸载服务"
        echo -e "  ${GREEN}0)${NC} 退出"
        echo ""
        printf "请输入选项 [0-6]: "
        read -r choice

        case "${choice:-}" in
            1) menu_configure ;;
            2) menu_records ;;
            3) menu_update_now ;;
            4) menu_install_service ;;
            5) clear; service_status; pause ;;
            6) menu_uninstall ;;
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
            -s|--silent|--) shift ;;
            update)
                install_deps
                do_update
                exit $?
                ;;
            install)
                need_root
                install_deps
                load_config
                migrate_old_config
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
Cloudflare DDNS 管理工具（多记录 / IPv4 + IPv6）

用法:
  $(basename "$0")                    交互式菜单
  $(basename "$0") update             立即执行更新
  $(basename "$0") install            安装系统服务
  $(basename "$0") uninstall          卸载服务
  $(basename "$0") status             查看状态

从 GitHub 直接运行:
  bash <(curl -fsSL ${SCRIPT_URL})
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
    migrate_old_config
    main_menu
}

main "$@"