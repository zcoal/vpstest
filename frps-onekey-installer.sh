以下是修复对齐问题后的完整脚本：

```bash
#!/bin/bash

# ============================================================================
# FRP 服务端管理脚本（支持自动重启）
# 兼容: Alpine Linux, Debian, Ubuntu
# ============================================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# 配置变量
FRP_VERSION="0.56.0"
FRP_PACKAGE="frp_${FRP_VERSION}_linux_amd64"
FRP_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${FRP_PACKAGE}.tar.gz"

FRP_DIR="/opt/frp"
FRP_CONFIG="$FRP_DIR/frps.ini"
FRP_LOG="$FRP_DIR/frps.log"
FRP_BIN="$FRP_DIR/frps"
FRP_USER="frpuser"

# 系统检测变量
OS_TYPE=""
INIT_SYSTEM=""
PKG_MANAGER=""
HAS_NANO=false

# 当前配置变量
CURRENT_BIND_PORT=""
CURRENT_DASHBOARD_PORT=""
CURRENT_DASHBOARD_USER=""
CURRENT_TOKEN=""

# ============================================================================
# 通用函数
# ============================================================================

# 检测操作系统和包管理器
detect_system() {
    if [ -f /etc/alpine-release ]; then
        OS_TYPE="alpine"
        INIT_SYSTEM="openrc"
        PKG_MANAGER="apk"
        echo -e "${CYAN}检测到系统: Alpine Linux${NC}"
    elif [ -f /etc/debian_version ] || [ -f /etc/lsb-release ]; then
        OS_TYPE="debian"
        
        # 检测初始化系统
        if command -v systemctl >/dev/null 2>&1; then
            INIT_SYSTEM="systemd"
        else
            INIT_SYSTEM="sysvinit"
        fi
        
        PKG_MANAGER="apt"
        
        if [ -f /etc/lsb-release ]; then
            . /etc/lsb-release
            echo -e "${CYAN}检测到系统: $DISTRIB_DESCRIPTION${NC}"
        else
            echo -e "${CYAN}检测到系统: Debian $(cat /etc/debian_version)${NC}"
        fi
    else
        echo -e "${RED}错误: 不支持的操作系统${NC}"
        exit 1
    fi
    
    # 检查是否安装nano
    if command -v nano >/dev/null 2>&1; then
        HAS_NANO=true
    fi
}

# 检查root权限
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}错误: 此脚本必须以root用户运行${NC}"
        exit 1
    fi
}

# 显示状态栏
status_bar() {
    echo -e "${BLUE}════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${WHITE}FRP 服务端管理脚本 v2.0 (支持自动重启)${NC}   ${CYAN}系统: $OS_TYPE ($INIT_SYSTEM)${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════════════════════════${NC}"
}

# 获取服务状态
get_service_status() {
    if [ ! -f "$FRP_BIN" ]; then
        echo "not_installed"
        return
    fi
    
    case $INIT_SYSTEM in
        "systemd")
            if systemctl is-active --quiet frps 2>/dev/null; then
                echo "running"
            elif systemctl is-failed --quiet frps 2>/dev/null; then
                echo "failed"
            else
                echo "stopped"
            fi
            ;;
        "openrc")
            if rc-service frps status >/dev/null 2>&1; then
                echo "running"
            else
                echo "stopped"
            fi
            ;;
        "sysvinit")
            if service frps status >/dev/null 2>&1; then
                echo "running"
            else
                echo "stopped"
            fi
            ;;
        *)
            # 检查进程是否存在
            if pgrep -f "frps.*$FRP_CONFIG" >/dev/null; then
                echo "running"
            else
                echo "stopped"
            fi
            ;;
    esac
}

# 显示服务状态
show_service_status() {
    local status=$(get_service_status)
    
    case $status in
        "running")
            echo -e "${GREEN}● 运行中${NC}"
            ;;
        "stopped")
            echo -e "${RED}● 已停止${NC}"
            ;;
        "failed")
            echo -e "${RED}● 启动失败${NC}"
            ;;
        "not_installed")
            echo -e "${YELLOW}○ 未安装${NC}"
            ;;
    esac
}

# 获取当前配置
get_current_config() {
    if [ -f "$FRP_CONFIG" ]; then
        CURRENT_BIND_PORT=$(grep '^bind_port' "$FRP_CONFIG" | cut -d'=' -f2 | tr -d ' ')
        CURRENT_DASHBOARD_PORT=$(grep '^dashboard_port' "$FRP_CONFIG" | cut -d'=' -f2 | tr -d ' ')
        CURRENT_DASHBOARD_USER=$(grep '^dashboard_user' "$FRP_CONFIG" | cut -d'=' -f2 | tr -d ' ')
        CURRENT_TOKEN=$(grep '^token' "$FRP_CONFIG" | cut -d'=' -f2 | tr -d ' ')
    else
        CURRENT_BIND_PORT="未配置"
        CURRENT_DASHBOARD_PORT="未配置"
        CURRENT_DASHBOARD_USER="未配置"
        CURRENT_TOKEN="未配置"
    fi
}

# 显示配置摘要
show_config_summary() {
    get_current_config
    
    echo -e "${CYAN}┌─────────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│${NC} 客户端连接端口 : ${CURRENT_BIND_PORT}${NC}"
    echo -e "${CYAN}│${NC} 管理面板端口   : ${CURRENT_DASHBOARD_PORT}${NC}"
    echo -e "${CYAN}│${NC} 管理用户名     : ${CURRENT_DASHBOARD_USER}${NC}"
    echo -e "${CYAN}│${NC} 认证Token      : ${CURRENT_TOKEN:0:10}...${NC}"
    echo -e "${CYAN}└─────────────────────────────────────────────────────────┘${NC}"
}

# 显示网络状态
show_network_status() {
    local status=$(get_service_status)
    
    if [ "$status" = "running" ]; then
        echo -e "${CYAN}┌─────────────────────────────────────────────────────────┐${NC}"
        
        # 获取监听端口
        local bind_port=${CURRENT_BIND_PORT:-7000}
        local dash_port=${CURRENT_DASHBOARD_PORT:-7500}
        
        # 尝试多种方法获取IP
        local local_ip=""
        if command -v ip >/dev/null 2>&1; then
            local_ip=$(ip route get 1 | awk '{print $NF;exit}')
        elif command -v hostname >/dev/null 2>&1; then
            local_ip=$(hostname)
        else
            local_ip="未知"
        fi
        
        # 如果是主机名，显示主机名
        if [[ "$local_ip" =~ ^[a-zA-Z] ]]; then
            echo -e "${CYAN}│${NC} 服务器主机     : ${local_ip}${NC}"
        else
            echo -e "${CYAN}│${NC} 服务端地址     : ${local_ip}:${bind_port}${NC}"
        fi
        
        echo -e "${CYAN}│${NC} 管理面板端口   : ${dash_port}${NC}"
        
        # 检查端口监听状态
        if ss -tuln 2>/dev/null | grep -q ":$bind_port "; then
            echo -e "${CYAN}│${NC} 连接端口状态   : ${GREEN}正常监听${NC}${CYAN}${NC}"
        elif netstat -tuln 2>/dev/null | grep -q ":$bind_port "; then
            echo -e "${CYAN}│${NC} 连接端口状态   : ${GREEN}正常监听${NC}${CYAN}${NC}"
        else
            echo -e "${CYAN}│${NC} 连接端口状态   : ${RED}未监听${NC}${CYAN}${NC}"
        fi
        
        echo -e "${CYAN}└─────────────────────────────────────────────────────────┘${NC}"
    fi
}

# 显示自动重启状态
show_autorestart_status() {
    echo -e "${CYAN}┌─────────────────────────────────────────────────────────┐${NC}"
    
    # 检查systemd服务配置
    if [ "$INIT_SYSTEM" = "systemd" ] && [ -f /etc/systemd/system/frps.service ]; then
        if grep -q "Restart=always" /etc/systemd/system/frps.service; then
            echo -e "${CYAN}│${NC} Systemd自动重启 : ${GREEN}✓ 已启用${NC}${CYAN}${NC}"
            local restart_sec=$(grep "RestartSec=" /etc/systemd/system/frps.service | cut -d'=' -f2)
            echo -e "${CYAN}│${NC} 重启间隔       : ${restart_sec:-10s}${NC}"
        else
            echo -e "${CYAN}│${NC} Systemd自动重启 : ${RED}✗ 未启用${NC}${CYAN}${NC}"
        fi
    fi
    
    # 检查cron监控
    if crontab -l 2>/dev/null | grep -q "frp_monitor.sh"; then
        echo -e "${CYAN}│${NC} Cron监控        : ${GREEN}✓ 已启用 (每分钟)${NC}${CYAN}${NC}"
    else
        echo -e "${CYAN}│${NC} Cron监控        : ${YELLOW}○ 未启用${NC}${CYAN}${NC}"
    fi
    
    echo -e "${CYAN}└─────────────────────────────────────────────────────────┘${NC}"
}

# 显示主菜单
show_main_menu() {
    clear
    status_bar
    
    echo -e "${WHITE}服务状态: $(show_service_status)${NC}"
    echo ""
    
    show_config_summary
    echo ""
    
    show_network_status
    echo ""
    
    show_autorestart_status
    echo ""
    
    echo -e "${PURPLE}══════════════════════ 主菜单 ═══════════════════════${NC}"
    echo ""
    echo -e "${GREEN}[1]${NC}  安装 FRP 服务端"
    echo -e "${GREEN}[2]${NC}  卸载 FRP 服务端"
    echo ""
    echo -e "${BLUE}[3]${NC}  启动 FRP 服务"
    echo -e "${BLUE}[4]${NC}  停止 FRP 服务"
    echo -e "${BLUE}[5]${NC}  重启 FRP 服务"
    echo -e "${BLUE}[6]${NC}  查看服务状态"
    echo ""
    echo -e "${YELLOW}[7]${NC}  修改配置"
    echo -e "${YELLOW}[8]${NC}  查看配置文件"
    echo -e "${YELLOW}[9]${NC}  查看实时日志"
    echo ""
    echo -e "${CYAN}[10]${NC} 查看安全信息"
    echo -e "${CYAN}[11]${NC} 检查更新"
    echo -e "${CYAN}[12]${NC} 备份配置"
    echo ""
    echo -e "${PURPLE}[13]${NC} 配置自动重启"
    echo -e "${PURPLE}[14]${NC} 查看监控日志"
    echo ""
    echo -e "${RED}[0]${NC}  退出脚本"
    echo ""
    echo -e "${PURPLE}══════════════════════════════════════════════════════${NC}"
    echo ""
    
    read -p "请选择操作 [0-14]: " choice
    echo ""
    
    case $choice in
        1) install_frp ;;
        2) uninstall_frp ;;
        3) start_service ;;
        4) stop_service ;;
        5) restart_service ;;
        6) detailed_status ;;
        7) modify_config ;;
        8) view_config ;;
        9) view_logs ;;
        10) show_security_info ;;
        11) check_update ;;
        12) backup_config ;;
        13) configure_autorestart ;;
        14) view_monitor_logs ;;
        0) 
            echo -e "${GREEN}再见！${NC}"
            exit 0
            ;;
        *) 
            echo -e "${RED}无效选择，请重试${NC}"
            sleep 2
            ;;
    esac
    
    # 返回主菜单
    echo ""
    read -p "按回车键返回主菜单..."
    show_main_menu
}

# ============================================================================
# 安装相关函数
# ============================================================================

# 安装依赖
install_dependencies() {
    echo -e "${YELLOW}[1/8] 安装系统依赖...${NC}"
    
    case $PKG_MANAGER in
        "apk")
            apk update >/dev/null 2>&1
            apk add --no-cache wget tar ca-certificates curl >/dev/null 2>&1
            if ! command -v nano >/dev/null 2>&1; then
                apk add --no-cache nano >/dev/null 2>&1 && HAS_NANO=true
            fi
            ;;
        "apt")
            apt update >/dev/null 2>&1
            apt install -y wget tar ca-certificates curl >/dev/null 2>&1
            if ! command -v nano >/dev/null 2>&1; then
                apt install -y nano >/dev/null 2>&1 && HAS_NANO=true
            fi
            ;;
    esac
    
    echo -e "${GREEN}✓ 依赖安装完成${NC}"
}

# 创建用户
create_user() {
    echo -e "${YELLOW}[2/8] 创建FRP运行用户...${NC}"
    
    if id -u "$FRP_USER" >/dev/null 2>&1; then
        echo -e "${YELLOW}用户 $FRP_USER 已存在${NC}"
        return
    fi
    
    case $OS_TYPE in
        "alpine")
            adduser -D -H -s /bin/false "$FRP_USER" >/dev/null 2>&1
            ;;
        "debian")
            useradd -r -s /bin/false -M "$FRP_USER" >/dev/null 2>&1
            ;;
    esac
    
    echo -e "${GREEN}✓ 用户创建完成${NC}"
}

# 获取用户配置
get_user_config() {
    echo -e "${PURPLE}══════════════════════ 配置向导 ═══════════════════════${NC}"
    echo ""
    
    # 默认值
    local default_bind_port="7000"
    local default_dashboard_port="7500"
    local default_dashboard_user="admin"
    
    # 如果有旧配置，使用旧配置作为默认值
    if [ -f "$FRP_CONFIG" ]; then
        local old_bind_port=$(grep '^bind_port' "$FRP_CONFIG" | cut -d'=' -f2 | tr -d ' ')
        local old_dashboard_port=$(grep '^dashboard_port' "$FRP_CONFIG" | cut -d'=' -f2 | tr -d ' ')
        local old_dashboard_user=$(grep '^dashboard_user' "$FRP_CONFIG" | cut -d'=' -f2 | tr -d ' ')
        
        [ -n "$old_bind_port" ] && default_bind_port="$old_bind_port"
        [ -n "$old_dashboard_port" ] && default_dashboard_port="$old_dashboard_port"
        [ -n "$old_dashboard_user" ] && default_dashboard_user="$old_dashboard_user"
    fi
    
    # 1. 绑定端口
    echo -e "${CYAN}请输入客户端连接端口${NC}"
    read -p "默认: $default_bind_port: " bind_port
    bind_port=${bind_port:-$default_bind_port}
    
    # 验证端口
    if ! [[ "$bind_port" =~ ^[0-9]+$ ]] || [ "$bind_port" -lt 1 ] || [ "$bind_port" -gt 65535 ]; then
        echo -e "${RED}错误: 端口号必须为1-65535的数字${NC}"
        exit 1
    fi
    
    # 2. 面板端口
    echo -e "${CYAN}请输入管理面板端口${NC}"
    read -p "默认: $default_dashboard_port: " dashboard_port
    dashboard_port=${dashboard_port:-$default_dashboard_port}
    
    if ! [[ "$dashboard_port" =~ ^[0-9]+$ ]] || [ "$dashboard_port" -lt 1 ] || [ "$dashboard_port" -gt 65535 ]; then
        echo -e "${RED}错误: 端口号必须为1-65535的数字${NC}"
        exit 1
    fi
    
    if [ "$dashboard_port" = "$bind_port" ]; then
        echo -e "${RED}错误: 不能与连接端口相同${NC}"
        exit 1
    fi
    
    # 3. 管理用户
    echo -e "${CYAN}请输入管理面板用户名${NC}"
    read -p "默认: $default_dashboard_user: " dashboard_user
    dashboard_user=${dashboard_user:-$default_dashboard_user}
    
    # 4. 管理密码
    echo -e "${CYAN}请输入管理面板密码${NC}"
    echo -e "${YELLOW}注意: 密码将明文显示在屏幕上${NC}"
    read -p "请输入密码: " dashboard_pwd
    if [ -z "$dashboard_pwd" ]; then
        echo -e "${RED}错误: 密码不能为空${NC}"
        exit 1
    fi
    
    # 5. 认证Token
    echo -e "${CYAN}请输入认证Token${NC}"
    echo -e "${YELLOW}注意: Token将明文显示在屏幕上${NC}"
    read -p "请输入Token: " token
    if [ -z "$token" ]; then
        echo -e "${RED}错误: Token不能为空${NC}"
        exit 1
    fi
    
    # 显示配置摘要
    echo ""
    echo -e "${GREEN}══════════════════════ 配置确认 ═══════════════════════${NC}"
    echo "客户端连接端口: $bind_port"
    echo "管理面板端口:   $dashboard_port"
    echo "管理用户名:     $dashboard_user"
    echo "管理密码:       $dashboard_pwd"
    echo "认证Token:      ${token:0:16}..."
    echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
    echo ""
    
    read -p "确认配置是否正确？(Y/n): " confirm
    if [[ ! "$confirm" =~ ^[Yy]?$ ]]; then
        echo -e "${YELLOW}重新输入配置...${NC}"
        get_user_config
        return
    fi
    
    # 保存配置
    USER_CONFIG_BIND_PORT="$bind_port"
    USER_CONFIG_DASHBOARD_PORT="$dashboard_port"
    USER_CONFIG_DASHBOARD_USER="$dashboard_user"
    USER_CONFIG_DASHBOARD_PWD="$dashboard_pwd"
    USER_CONFIG_TOKEN="$token"
}

# 下载FRP
download_frp() {
    echo -e "${YELLOW}[3/8] 下载FRP v${FRP_VERSION}...${NC}"
    
    mkdir -p "$FRP_DIR"
    
    echo "正在下载 FRP..."
    wget -q --show-progress -O "/tmp/${FRP_PACKAGE}.tar.gz" "$FRP_URL"
    if [ $? -ne 0 ]; then
        echo -e "${RED}下载失败，请检查网络${NC}"
        exit 1
    fi
    
    echo -e "${YELLOW}解压安装文件...${NC}"
    tar -xzf "/tmp/${FRP_PACKAGE}.tar.gz" -C "/tmp/"
    cp "/tmp/${FRP_PACKAGE}/frps" "$FRP_DIR/"
    
    chown -R "$FRP_USER":"$FRP_USER" "$FRP_DIR"
    chmod 750 "$FRP_DIR"
    chmod 755 "$FRP_BIN"
    
    echo -e "${GREEN}✓ FRP安装完成${NC}"
}

# 创建配置文件
create_config_file() {
    echo -e "${YELLOW}[4/8] 创建配置文件...${NC}"
    
    cat > "$FRP_CONFIG" << EOF
# ============================================================================
# FRP 服务端配置文件
# 生成时间: $(date)
# ============================================================================

[common]
# 基本设置
bind_addr = 0.0.0.0
bind_port = ${USER_CONFIG_BIND_PORT}

# 管理面板设置
dashboard_addr = 0.0.0.0
dashboard_port = ${USER_CONFIG_DASHBOARD_PORT}
dashboard_user = ${USER_CONFIG_DASHBOARD_USER}
dashboard_pwd = ${USER_CONFIG_DASHBOARD_PWD}

# 认证设置
token = ${USER_CONFIG_TOKEN}

# ============================================================================
# HTTP/HTTPS 代理设置
# ============================================================================

# HTTP反向代理端口（用于web服务映射）
# vhost_http_port = 80

# HTTPS反向代理端口（用于SSL网站映射）
# vhost_https_port = 443

# ============================================================================
# 日志设置
# ============================================================================

log_file = ${FRP_LOG}
log_level = info
log_max_days = 3

# ============================================================================
# 高级设置
# ============================================================================

# KCP协议支持
# kcp_bind_port = ${USER_CONFIG_BIND_PORT}

# 连接限制
max_pool_count = 50
max_ports_per_client = 0
authentication_timeout = 900

# TLS设置
tls_only = false

# 子域名主机
# subdomain_host = frp.example.com

# 允许的端口范围
# allow_ports = 2000-3000,3001,3003,4000-50000
EOF
    
    chown "$FRP_USER":"$FRP_USER" "$FRP_CONFIG"
    echo -e "${GREEN}✓ 配置文件创建完成${NC}"
}

# 创建服务文件（支持自动重启）
create_service_file() {
    echo -e "${YELLOW}[5/8] 创建系统服务（支持自动重启）...${NC}"
    
    case $INIT_SYSTEM in
        "systemd")
            cat > /etc/systemd/system/frps.service << EOF
[Unit]
Description=FRP Server Daemon
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=${FRP_USER}
Group=${FRP_USER}
# 自动重启配置
Restart=always
RestartSec=10s
# 失败重试次数限制（0=无限制）
StartLimitBurst=0
# 进程健康检查
WatchdogSec=30s
# 优雅停止超时
TimeoutStopSec=30s
# 仅在退出码为0时视为正常退出，其他情况自动重启
SuccessExitStatus=0
ExecStart=${FRP_BIN} -c ${FRP_CONFIG}
ExecReload=/bin/kill -HUP \$MAINPID
# 资源限制
LimitNOFILE=1048576
# 进程优先级
Nice=0
# 进程守护
KillMode=process
KillSignal=SIGQUIT

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl enable frps >/dev/null 2>&1
            echo -e "${GREEN}✓ Systemd服务已创建（已启用自动重启）${NC}"
            ;;
            
        "openrc")
            cat > /etc/init.d/frps << EOF
#!/sbin/openrc-run

name="frps"
description="FRP Server Daemon"

command="${FRP_BIN}"
command_args="-c ${FRP_CONFIG}"
command_user="${FRP_USER}"
command_background=true

pidfile="/var/run/frps.pid"
start_stop_daemon_args="--pidfile \${pidfile} --make-pidfile"

depend() {
    need net
    after firewall
}

start_pre() {
    checkpath -q -d -m 0755 ${FRP_DIR} || return 1
}

# OpenRC 不支持自动重启，需要配合监控脚本
EOF
            chmod +x /etc/init.d/frps
            rc-update add frps default >/dev/null 2>&1
            echo -e "${GREEN}✓ OpenRC服务已创建${NC}"
            ;;
            
        "sysvinit")
            cat > /etc/init.d/frps << EOF
#!/bin/sh
### BEGIN INIT INFO
# Provides:          frps
# Required-Start:    \$network \$local_fs \$remote_fs
# Required-Stop:     \$network \$local_fs \$remote_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: FRP Server Daemon
# Description:       Fast Reverse Proxy Server
### END INIT INFO

PATH=/sbin:/usr/sbin:/bin:/usr/bin
NAME=frps
DAEMON=${FRP_BIN}
DAEMON_ARGS="-c ${FRP_CONFIG}"
PIDFILE=/var/run/frps.pid
USER=${FRP_USER}

[ -x "\$DAEMON" ] || exit 0

case "\$1" in
    start)
        echo -n "Starting \$NAME: "
        start-stop-daemon --start --quiet --background --make-pidfile \\
            --pidfile \$PIDFILE --chuid \$USER --exec \$DAEMON -- \$DAEMON_ARGS
        echo "\$NAME."
        ;;
    stop)
        echo -n "Stopping \$NAME: "
        start-stop-daemon --stop --quiet --pidfile \$PIDFILE
        echo "\$NAME."
        ;;
    restart)
        \$0 stop
        sleep 1
        \$0 start
        ;;
    status)
        if [ -f \$PIDFILE ]; then
            if kill -0 \$(cat \$PIDFILE) >/dev/null 2>&1; then
                echo "\$NAME is running"
                exit 0
            else
                echo "\$NAME is not running but PID file exists"
                exit 1
            fi
        else
            echo "\$NAME is not running"
            exit 3
        fi
        ;;
    *)
        echo "Usage: \$0 {start|stop|restart|status}"
        exit 1
        ;;
esac

exit 0
EOF
            chmod +x /etc/init.d/frps
            update-rc.d frps defaults >/dev/null 2>&1
            echo -e "${GREEN}✓ SysVinit服务已创建${NC}"
            ;;
    esac
}

# 创建监控脚本
create_monitor_script() {
    echo -e "${YELLOW}[6/8] 创建进程监控脚本...${NC}"
    
    cat > "$FRP_DIR/frp_monitor.sh" << 'EOF'
#!/bin/bash

# FRP 进程监控脚本
FRP_BIN="/opt/frp/frps"
FRP_CONFIG="/opt/frp/frps.ini"
FRP_PID_FILE="/var/run/frps.pid"
LOG_FILE="/var/log/frp_monitor.log"
MAX_RESTART=5
RESTART_COUNT_FILE="/tmp/frp_restart_count"
RESTART_WINDOW=300

# 日志函数
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# 清理旧的重启计数
clean_restart_count() {
    if [ -f "$RESTART_COUNT_FILE" ]; then
        local current_time=$(date +%s)
        local file_time=$(stat -c %Y "$RESTART_COUNT_FILE" 2>/dev/null || echo 0)
        if [ $((current_time - file_time)) -gt $RESTART_WINDOW ]; then
            rm -f "$RESTART_COUNT_FILE"
        fi
    fi
}

# 增加重启计数
increment_restart_count() {
    clean_restart_count
    local count=1
    if [ -f "$RESTART_COUNT_FILE" ]; then
        count=$(cat "$RESTART_COUNT_FILE")
        count=$((count + 1))
    fi
    echo "$count" > "$RESTART_COUNT_FILE"
    return $count
}

# 检查FRP进程
check_frp() {
    if [ -f "$FRP_PID_FILE" ]; then
        local pid=$(cat "$FRP_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    
    if pgrep -f "frps.*$FRP_CONFIG" >/dev/null; then
        return 0
    fi
    
    return 1
}

# 启动FRP
start_frp() {
    log_message "FRP服务未运行，尝试重启..."
    
    increment_restart_count
    local restart_count=$?
    
    if [ $restart_count -gt $MAX_RESTART ]; then
        log_message "错误: 5分钟内重启次数超过${MAX_RESTART}次，停止自动重启"
        echo "FRP服务频繁崩溃，已停止自动重启" | wall 2>/dev/null
        return 1
    fi
    
    if command -v systemctl >/dev/null 2>&1; then
        systemctl start frps 2>/dev/null
        if [ $? -eq 0 ]; then
            log_message "通过systemctl成功重启FRP服务 (重启次数: $restart_count)"
            return 0
        fi
    elif command -v service >/dev/null 2>&1; then
        service frps start 2>/dev/null
        if [ $? -eq 0 ]; then
            log_message "通过service成功重启FRP服务 (重启次数: $restart_count)"
            return 0
        fi
    elif [ -f "$FRP_BIN" ]; then
        nohup "$FRP_BIN" -c "$FRP_CONFIG" > /dev/null 2>&1 &
        log_message "直接启动FRP进程 (重启次数: $restart_count)"
        return 0
    fi
    
    log_message "FRP重启失败"
    return 1
}

# 主循环
main() {
    if [ -f "$LOG_FILE" ] && [ $(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) -gt 10485760 ]; then
        mv "$LOG_FILE" "${LOG_FILE}.old"
    fi
    
    if ! check_frp; then
        start_frp
    fi
}

main
EOF
    
    chmod +x "$FRP_DIR/frp_monitor.sh"
    chown "$FRP_USER":"$FRP_USER" "$FRP_DIR/frp_monitor.sh"
    
    echo -e "${GREEN}✓ 监控脚本创建完成${NC}"
}

# 设置Cron监控
setup_cron_monitor() {
    echo -e "${YELLOW}[7/8] 设置定时监控任务...${NC}"
    
    local cron_cmd="* * * * * $FRP_DIR/frp_monitor.sh >/dev/null 2>&1"
    
    if crontab -l 2>/dev/null | grep -q "$FRP_DIR/frp_monitor.sh"; then
        echo -e "${YELLOW}监控任务已存在${NC}"
        return
    fi
    
    (crontab -l 2>/dev/null; echo "$cron_cmd") | crontab -
    
    echo -e "${GREEN}✓ 定时监控任务已设置（每分钟检查一次）${NC}"
}

# 保存安全信息
save_security_info() {
    echo -e "${YELLOW}[8/8] 保存安全信息...${NC}"
    
    local local_ip=""
    if command -v ip >/dev/null 2>&1; then
        local_ip=$(ip route get 1 | awk '{print $NF;exit}')
    elif command -v hostname >/dev/null 2>&1; then
        local_ip=$(hostname)
    else
        local_ip="未知"
    fi
    
    cat > "$FRP_DIR/frp_security_info.txt" << EOF
================================================
FRP 安全信息 - 请妥善保管
================================================
安装时间: $(date)
服务器地址: ${local_ip}

连接配置:
  客户端连接端口: ${USER_CONFIG_BIND_PORT}
  认证Token: ${USER_CONFIG_TOKEN}

管理面板:
  访问端口: ${USER_CONFIG_DASHBOARD_PORT}
  用户名: ${USER_CONFIG_DASHBOARD_USER}
  密码: ${USER_CONFIG_DASHBOARD_PWD}

文件路径:
  配置文件: ${FRP_CONFIG}
  日志文件: ${FRP_LOG}
  安装目录: ${FRP_DIR}

服务管理:
  启动命令: $([ "$INIT_SYSTEM" = "systemd" ] && echo "systemctl start frps" || echo "service frps start")
  状态检查: $([ "$INIT_SYSTEM" = "systemd" ] && echo "systemctl status frps" || echo "service frps status")
  自动重启: 已启用

客户端配置示例:
[common]
server_addr = ${local_ip}
server_port = ${USER_CONFIG_BIND_PORT}
token = ${USER_CONFIG_TOKEN}

[ssh]
type = tcp
local_ip = 127.0.0.1
local_port = 22
remote_port = 6000
================================================
EOF
    
    chmod 600 "$FRP_DIR/frp_security_info.txt"
    echo -e "${GREEN}✓ 安全信息已保存${NC}"
}

# 安装主函数
install_frp() {
    echo -e "${BLUE}开始安装 FRP 服务端...${NC}"
    echo ""
    
    if [ -f "$FRP_BIN" ]; then
        echo -e "${YELLOW}检测到已安装 FRP，是否重新安装？${NC}"
        read -p "重新安装将保留现有配置？(Y/n): " reinstall
        if [[ "$reinstall" =~ ^[Yy]?$ ]]; then
            if [ -f "$FRP_CONFIG" ]; then
                cp "$FRP_CONFIG" "$FRP_CONFIG.backup.$(date +%Y%m%d_%H%M%S)"
            fi
            stop_service_quiet
        else
            return
        fi
    fi
    
    get_user_config
    install_dependencies
    create_user
    download_frp
    create_config_file
    create_service_file
    create_monitor_script
    setup_cron_monitor
    save_security_info
    
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${WHITE}                    FRP 安装完成！                              ${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}安装信息:${NC}"
    echo -e "  客户端连接端口: ${USER_CONFIG_BIND_PORT}"
    echo -e "  管理面板端口:   ${USER_CONFIG_DASHBOARD_PORT}"
