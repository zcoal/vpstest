#!/bin/bash

# ============================================================================
# FRP 服务端管理脚本
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
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${WHITE}FRP 服务端管理脚本 v1.0${NC}   ${CYAN}系统: $OS_TYPE ($INIT_SYSTEM)${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════════════${NC}"
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
    
    echo -e "${CYAN}┌─────────────────────── 配置摘要 ───────────────────────┐${NC}"
    printf "${CYAN}│${NC} %-25s ${CYAN}:${NC} %-25s ${CYAN}│${NC}\n" "客户端连接端口" "$CURRENT_BIND_PORT"
    printf "${CYAN}│${NC} %-25s ${CYAN}:${NC} %-25s ${CYAN}│${NC}\n" "管理面板端口" "$CURRENT_DASHBOARD_PORT"
    printf "${CYAN}│${NC} %-25s ${CYAN}:${NC} %-25s ${CYAN}│${NC}\n" "管理用户名" "$CURRENT_DASHBOARD_USER"
    printf "${CYAN}│${NC} %-25s ${CYAN}:${NC} %-25s ${CYAN}│${NC}\n" "认证Token" "${CURRENT_TOKEN:0:10}..."
    echo -e "${CYAN}└─────────────────────────────────────────────────────────┘${NC}"
}

# 显示网络状态
show_network_status() {
    local status=$(get_service_status)
    
    if [ "$status" = "running" ]; then
        echo -e "${CYAN}┌─────────────────────── 网络状态 ───────────────────────┐${NC}"
        
        # 获取监听端口 - 使用更兼容的方法
        local bind_port=${CURRENT_BIND_PORT:-7000}
        local dash_port=${CURRENT_DASHBOARD_PORT:-7500}
        
        # 尝试多种方法获取IP
        local local_ip=""
        if command -v ip >/dev/null 2>&1; then
            local_ip=$(ip route get 1 | awk '{print $NF;exit}')
        elif command -v hostname >/dev/null 2>&1; then
            # 只使用hostname获取主机名
            local_ip=$(hostname)
        else
            local_ip="未知"
        fi
        
        # 如果是主机名，显示主机名
        if [[ "$local_ip" =~ ^[a-zA-Z] ]]; then
            printf "${CYAN}│${NC} %-25s ${CYAN}:${NC} ${GREEN}%-25s${NC} ${CYAN}│${NC}\n" "服务器主机" "$local_ip"
        else
            printf "${CYAN}│${NC} %-25s ${CYAN}:${NC} ${GREEN}%-25s${NC} ${CYAN}│${NC}\n" "服务端地址" "$local_ip:$bind_port"
        fi
        
        printf "${CYAN}│${NC} %-25s ${CYAN}:${NC} ${GREEN}%-25s${NC} ${CYAN}│${NC}\n" "管理面板端口" "$dash_port"
        
        # 检查端口监听状态
        if ss -tuln 2>/dev/null | grep -q ":$bind_port "; then
            printf "${CYAN}│${NC} %-25s ${CYAN}:${NC} ${GREEN}%-25s${NC} ${CYAN}│${NC}\n" "连接端口状态" "正常监听"
        elif netstat -tuln 2>/dev/null | grep -q ":$bind_port "; then
            printf "${CYAN}│${NC} %-25s ${CYAN}:${NC} ${GREEN}%-25s${NC} ${CYAN}│${NC}\n" "连接端口状态" "正常监听"
        else
            printf "${CYAN}│${NC} %-25s ${CYAN}:${NC} ${RED}%-25s${NC} ${CYAN}│${NC}\n" "连接端口状态" "未监听"
        fi
        
        echo -e "${CYAN}└─────────────────────────────────────────────────────────┘${NC}"
    fi
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
    
    echo -e "${PURPLE}══════════════════════ 主菜单 ═══════════════════════${NC}"
    echo ""
    echo -e "${GREEN}[1]${NC} 安装 FRP 服务端"
    echo -e "${GREEN}[2]${NC} 卸载 FRP 服务端"
    echo ""
    echo -e "${BLUE}[3]${NC} 启动 FRP 服务"
    echo -e "${BLUE}[4]${NC} 停止 FRP 服务"
    echo -e "${BLUE}[5]${NC} 重启 FRP 服务"
    echo -e "${BLUE}[6]${NC} 查看服务状态"
    echo ""
    echo -e "${YELLOW}[7]${NC} 修改配置"
    echo -e "${YELLOW}[8]${NC} 查看配置文件"
    echo -e "${YELLOW}[9]${NC} 查看实时日志"
    echo ""
    echo -e "${CYAN}[10]${NC} 查看安全信息"
    echo -e "${CYAN}[11]${NC} 检查更新"
    echo -e "${CYAN}[12]${NC} 备份配置"
    echo ""
    echo -e "${RED}[0]${NC} 退出脚本"
    echo ""
    echo -e "${PURPLE}══════════════════════════════════════════════════════${NC}"
    echo ""
    
    read -p "请选择操作 [0-12]: " choice
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
    echo -e "${YELLOW}[1/6] 安装系统依赖...${NC}"
    
    case $PKG_MANAGER in
        "apk")
            apk update >/dev/null 2>&1
            apk add --no-cache wget tar ca-certificates >/dev/null 2>&1
            if ! command -v nano >/dev/null 2>&1; then
                apk add --no-cache nano >/dev/null 2>&1 && HAS_NANO=true
            fi
            ;;
        "apt")
            apt update >/dev/null 2>&1
            apt install -y wget tar ca-certificates >/dev/null 2>&1
            if ! command -v nano >/dev/null 2>&1; then
                apt install -y nano >/dev/null 2>&1 && HAS_NANO=true
            fi
            ;;
    esac
    
    echo -e "${GREEN}✓ 依赖安装完成${NC}"
}

# 创建用户
create_user() {
    echo -e "${YELLOW}[2/6] 创建FRP运行用户...${NC}"
    
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

# 获取用户配置 - 简化版
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
    
    # 4. 管理密码 - 直接显示输入
    echo -e "${CYAN}请输入管理面板密码${NC}"
    echo -e "${YELLOW}注意: 密码将明文显示在屏幕上${NC}"
    read -p "请输入密码: " dashboard_pwd
    if [ -z "$dashboard_pwd" ]; then
        echo -e "${RED}错误: 密码不能为空${NC}"
        exit 1
    fi
    
    # 5. 认证Token - 直接显示输入
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
    echo -e "${YELLOW}[3/6] 下载FRP v${FRP_VERSION}...${NC}"
    
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
    echo -e "${YELLOW}[4/6] 创建配置文件...${NC}"
    
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

# 创建服务文件
create_service_file() {
    echo -e "${YELLOW}[5/6] 创建系统服务...${NC}"
    
    case $INIT_SYSTEM in
        "systemd")
            cat > /etc/systemd/system/frps.service << EOF
[Unit]
Description=FRP Server Daemon
After=network.target

[Service]
Type=simple
User=${FRP_USER}
Group=${FRP_USER}
Restart=on-failure
RestartSec=5s
ExecStart=${FRP_BIN} -c ${FRP_CONFIG}
ExecReload=/bin/kill -HUP \$MAINPID
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl enable frps >/dev/null 2>&1
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
EOF
            chmod +x /etc/init.d/frps
            rc-update add frps default >/dev/null 2>&1
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
            ;;
    esac
    
    echo -e "${GREEN}✓ 系统服务创建完成${NC}"
}

# 保存安全信息
save_security_info() {
    echo -e "${YELLOW}[6/6] 保存安全信息...${NC}"
    
    # 尝试获取IP
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
    
    # 检查是否已安装
    if [ -f "$FRP_BIN" ]; then
        echo -e "${YELLOW}检测到已安装 FRP，是否重新安装？${NC}"
        read -p "重新安装将保留现有配置？(Y/n): " reinstall
        if [[ "$reinstall" =~ ^[Yy]?$ ]]; then
            # 备份现有配置
            if [ -f "$FRP_CONFIG" ]; then
                cp "$FRP_CONFIG" "$FRP_CONFIG.backup.$(date +%Y%m%d_%H%M%S)"
            fi
            # 停止服务
            stop_service_quiet
        else
            return
        fi
    fi
    
    # 获取用户配置
    get_user_config
    
    # 执行安装步骤
    install_dependencies
    create_user
    download_frp
    create_config_file
    create_service_file
    save_security_info
    
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════════${NC}"
    echo -e "${WHITE}                    FRP 安装完成！                              ${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}安装信息:${NC}"
    echo -e "  客户端连接端口: ${USER_CONFIG_BIND_PORT}"
    echo -e "  管理面板端口:   ${USER_CONFIG_DASHBOARD_PORT}"
    echo -e "  管理用户名:     ${USER_CONFIG_DASHBOARD_USER}"
    echo -e "  管理密码:       ${USER_CONFIG_DASHBOARD_PWD}"
    echo -e "  认证Token:      ${USER_CONFIG_TOKEN}"
    echo ""
    echo -e "${CYAN}配置文件位置:${NC}"
    echo -e "  ${FRP_CONFIG}"
    echo ""
    echo -e "${CYAN}服务管理命令:${NC}"
    echo -e "  启动服务: $([ "$INIT_SYSTEM" = "systemd" ] && echo "systemctl start frps" || echo "service frps start")"
    echo -e "  停止服务: $([ "$INIT_SYSTEM" = "systemd" ] && echo "systemctl stop frps" || echo "service frps stop")"
    echo -e "  重启服务: $([ "$INIT_SYSTEM" = "systemd" ] && echo "systemctl restart frps" || echo "service frps restart")"
    echo ""
    echo -e "${RED}重要提示:${NC}"
    echo -e "  安全信息已保存到: ${FRP_DIR}/frp_security_info.txt"
    echo -e "  请务必备份此文件！"
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════════${NC}"
    
    # 询问是否启动服务
    echo ""
    read -p "是否立即启动 FRP 服务？(Y/n): " start_now
    if [[ "$start_now" =~ ^[Yy]?$ ]]; then
        start_service
    fi
}

# ============================================================================
# 服务管理函数
# ============================================================================

stop_service_quiet() {
    case $INIT_SYSTEM in
        "systemd")
            systemctl stop frps 2>/dev/null || true
            ;;
        "openrc")
            rc-service frps stop 2>/dev/null || true
            ;;
        "sysvinit")
            service frps stop 2>/dev/null || true
            ;;
    esac
    sleep 1
}

start_service() {
    echo -e "${BLUE}启动 FRP 服务...${NC}"
    
    case $INIT_SYSTEM in
        "systemd")
            if systemctl start frps; then
                echo -e "${GREEN}✓ FRP 服务启动成功${NC}"
            else
                echo -e "${RED}✗ FRP 服务启动失败${NC}"
                systemctl status frps --no-pager -l
            fi
            ;;
        "openrc")
            if rc-service frps start; then
                echo -e "${GREEN}✓ FRP 服务启动成功${NC}"
            else
                echo -e "${RED}✗ FRP 服务启动失败${NC}"
                rc-service frps status
            fi
            ;;
        "sysvinit")
            if service frps start; then
                echo -e "${GREEN}✓ FRP 服务启动成功${NC}"
            else
                echo -e "${RED}✗ FRP 服务启动失败${NC}"
                service frps status
            fi
            ;;
    esac
}

stop_service() {
    echo -e "${YELLOW}停止 FRP 服务...${NC}"
    
    case $INIT_SYSTEM in
        "systemd")
            systemctl stop frps
            echo -e "${GREEN}✓ FRP 服务已停止${NC}"
            ;;
        "openrc")
            rc-service frps stop
            echo -e "${GREEN}✓ FRP 服务已停止${NC}"
            ;;
        "sysvinit")
            service frps stop
            echo -e "${GREEN}✓ FRP 服务已停止${NC}"
            ;;
    esac
}

restart_service() {
    echo -e "${BLUE}重启 FRP 服务...${NC}"
    
    case $INIT_SYSTEM in
        "systemd")
            systemctl restart frps
            echo -e "${GREEN}✓ FRP 服务重启成功${NC}"
            ;;
        "openrc")
            rc-service frps restart
            echo -e "${GREEN}✓ FRP 服务重启成功${NC}"
            ;;
        "sysvinit")
            service frps restart
            echo -e "${GREEN}✓ FRP 服务重启成功${NC}"
            ;;
    esac
}

# ============================================================================
# 其他功能函数
# ============================================================================

# 详细状态查看
detailed_status() {
    clear
    status_bar
    
    echo -e "${WHITE}FRP 服务详细状态${NC}"
    echo ""
    
    # 服务状态
    local status=$(get_service_status)
    case $status in
        "running")
            echo -e "${GREEN}● 服务状态: 运行中${NC}"
            ;;
        "stopped")
            echo -e "${RED}● 服务状态: 已停止${NC}"
            ;;
        "failed")
            echo -e "${RED}● 服务状态: 启动失败${NC}"
            ;;
        "not_installed")
            echo -e "${YELLOW}● 服务状态: 未安装${NC}"
            return
            ;;
    esac
    echo ""
    
    # 进程信息
    if [ "$status" = "running" ]; then
        echo -e "${CYAN}进程信息:${NC}"
        ps aux | grep -E "frps.*$FRP_CONFIG" | grep -v grep || echo "  未找到进程"
        echo ""
        
        # 端口监听
        echo -e "${CYAN}端口监听状态:${NC}"
        if command -v ss >/dev/null 2>&1; then
            ss -tulpn | grep frps 2>/dev/null || echo "  未找到监听端口"
        elif command -v netstat >/dev/null 2>&1; then
            netstat -tulpn 2>/dev/null | grep frps || echo "  未找到监听端口"
        else
            echo "  无法检查端口状态"
        fi
    fi
    
    # 配置信息
    show_config_summary
    echo ""
    
    # 日志尾部
    if [ -f "$FRP_LOG" ]; then
        echo -e "${CYAN}最近日志 (最后10行):${NC}"
        tail -10 "$FRP_LOG"
    else
        echo -e "${YELLOW}日志文件不存在${NC}"
    fi
    echo ""
    
    read -p "按回车键返回主菜单..."
}

# 编辑配置文件
edit_config_with_nano() {
    if ! $HAS_NANO; then
        echo -e "${YELLOW}nano未安装，尝试安装...${NC}"
        
        case $PKG_MANAGER in
            "apk")
                apk add --no-cache nano >/dev/null 2>&1
                ;;
            "apt")
                apt update >/dev/null 2>&1 && apt install -y nano >/dev/null 2>&1
                ;;
        esac
        
        if command -v nano >/dev/null 2>&1; then
            HAS_NANO=true
            echo -e "${GREEN}nano安装成功${NC}"
        else
            echo -e "${RED}无法安装nano，使用vi代替${NC}"
            vi "$FRP_CONFIG"
            return
        fi
    fi
    
    echo -e "${GREEN}使用nano编辑配置文件...${NC}"
    echo -e "${YELLOW}编辑完成后按Ctrl+X，然后按Y保存，最后按Enter确认${NC}"
    sleep 2
    nano "$FRP_CONFIG"
}

# 修改配置 - 简化版：直接进入nano编辑
modify_config() {
    if [ ! -f "$FRP_CONFIG" ]; then
        echo -e "${RED}FRP 未安装${NC}"
        read -p "按回车键返回..."
        return
    fi
    
    # 备份原配置
    local backup_file="$FRP_CONFIG.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$FRP_CONFIG" "$backup_file"
    echo -e "${GREEN}原配置已备份: $backup_file${NC}"
    
    # 直接使用nano编辑
    edit_config_with_nano
    
    # 询问是否重启服务
    echo ""
    read -p "配置已修改，是否重启服务使配置生效？(Y/n): " restart_confirm
    if [[ "$restart_confirm" =~ ^[Yy]?$ ]]; then
        restart_service
    fi
}

# 查看配置
view_config() {
    if [ ! -f "$FRP_CONFIG" ]; then
        echo -e "${RED}配置文件不存在${NC}"
        return
    fi
    
    clear
    echo -e "${BLUE}══════════════════════ FRP 配置文件 ═══════════════════════${NC}"
    echo ""
    cat "$FRP_CONFIG"
    echo ""
    echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    read -p "按回车键返回..."
}

# 查看日志
view_logs() {
    if [ ! -f "$FRP_LOG" ]; then
        echo -e "${YELLOW}日志文件不存在${NC}"
        read -p "按回车键返回..."
        return
    fi
    
    clear
    echo -e "${BLUE}══════════════════════ FRP 实时日志 ═══════════════════════${NC}"
    echo -e "${YELLOW}按 Ctrl+C 退出日志查看${NC}"
    echo ""
    
    tail -f -n 20 "$FRP_LOG"
}

# 显示安全信息
show_security_info() {
    if [ ! -f "$FRP_DIR/frp_security_info.txt" ]; then
        echo -e "${YELLOW}安全信息文件不存在${NC}"
        return
    fi
    
    clear
    echo -e "${BLUE}══════════════════════ 安全信息 ═══════════════════════${NC}"
    echo ""
    cat "$FRP_DIR/frp_security_info.txt"
    echo ""
    echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    
    read -p "按回车键返回..."
}

# 检查更新
check_update() {
    echo -e "${BLUE}检查 FRP 更新...${NC}"
    
    # 获取最新版本
    latest_version=$(curl -s https://api.github.com/repos/fatedier/frp/releases/latest | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/' 2>/dev/null)
    
    if [ -z "$latest_version" ]; then
        echo -e "${RED}无法获取最新版本${NC}"
        return
    fi
    
    echo "当前版本: v$FRP_VERSION"
    echo "最新版本: v$latest_version"
    
    if [ "$FRP_VERSION" != "$latest_version" ]; then
        echo -e "${GREEN}发现新版本 v$latest_version${NC}"
        read -p "是否更新？(y/N): " update_confirm
        if [[ "$update_confirm" =~ ^[Yy]$ ]]; then
            FRP_VERSION="$latest_version"
            FRP_PACKAGE="frp_${FRP_VERSION}_linux_amd64"
            FRP_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${FRP_PACKAGE}.tar.gz"
            
            # 停止服务
            stop_service_quiet
            
            # 下载新版本
            download_frp
            
            # 重启服务
            restart_service
            
            echo -e "${GREEN}更新完成${NC}"
        fi
    else
        echo -e "${GREEN}已是最新版本${NC}"
    fi
}

# 备份配置
backup_config() {
    local backup_dir="/var/backups/frp"
    mkdir -p "$backup_dir"
    
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="$backup_dir/frp_backup_$timestamp.tar.gz"
    
    tar -czf "$backup_file" -C /opt/frp . 2>/dev/null
    
    echo -e "${GREEN}备份已创建: $backup_file${NC}"
    echo ""
}

# 卸载FRP
uninstall_frp() {
    echo -e "${RED}══════════════════════ 卸载 FRP ═══════════════════════${NC}"
    echo ""
    
    if [ ! -f "$FRP_BIN" ]; then
        echo -e "${YELLOW}FRP 未安装${NC}"
        read -p "按回车键返回..."
        return
    fi
    
    echo -e "${RED}警告: 此操作将删除所有 FRP 文件！${NC}"
    echo ""
    echo "将删除以下内容:"
    echo "  • FRP 程序文件: $FRP_DIR"
    echo "  • 配置文件: $FRP_CONFIG"
    echo "  • 日志文件: $FRP_LOG"
    echo "  • 系统服务文件"
    echo ""
    
    read -p "确定要卸载吗？(请输入 'yes' 确认): " confirm
    if [ "$confirm" != "yes" ]; then
        echo -e "${GREEN}卸载取消${NC}"
        return
    fi
    
    # 停止服务
    echo -e "${YELLOW}停止服务...${NC}"
    stop_service_quiet
    
    # 禁用服务
    case $INIT_SYSTEM in
        "systemd")
            systemctl disable frps 2>/dev/null || true
            rm -f /etc/systemd/system/frps.service
            systemctl daemon-reload
            ;;
        "openrc")
            rc-update del frps default 2>/dev/null || true
            rm -f /etc/init.d/frps
            ;;
        "sysvinit")
            update-rc.d -f frps remove 2>/dev/null || true
            rm -f /etc/init.d/frps
            ;;
    esac
    
    # 删除安装目录
    echo -e "${YELLOW}删除文件...${NC}"
    rm -rf "$FRP_DIR"
    
    echo -e "${GREEN}FRP 卸载完成${NC}"
}

# ============================================================================
# 主程序
# ============================================================================

# 初始化
main() {
    check_root
    detect_system
    
    # 创建必要的目录
    mkdir -p "$FRP_DIR"
    
    # 显示主菜单
    show_main_menu
}

# 捕获Ctrl+C
trap 'echo -e "\n${RED}操作取消${NC}"; exit 0' INT

# 运行主程序
main