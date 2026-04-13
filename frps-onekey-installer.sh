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
NC='\033[0m'

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

detect_system() {
    if [ -f /etc/alpine-release ]; then
        OS_TYPE="alpine"
        INIT_SYSTEM="openrc"
        PKG_MANAGER="apk"
        echo -e "${CYAN}检测到系统: Alpine Linux${NC}"
    elif [ -f /etc/debian_version ] || [ -f /etc/lsb-release ]; then
        OS_TYPE="debian"
        if command -v systemctl >/dev/null 2>&1; then
            INIT_SYSTEM="systemd"
        else
            INIT_SYSTEM="sysvinit"
        fi
        PKG_MANAGER="apt"
        echo -e "${CYAN}检测到系统: Debian/Ubuntu${NC}"
    else
        echo -e "${RED}错误: 不支持的操作系统${NC}"
        exit 1
    fi
    
    if command -v nano >/dev/null 2>&1; then
        HAS_NANO=true
    fi
}

check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo -e "${RED}错误: 此脚本必须以root用户运行${NC}"
        exit 1
    fi
}

status_bar() {
    echo -e "${BLUE}════════════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${WHITE}FRP 服务端管理脚本 v2.0${NC}   ${CYAN}系统: $OS_TYPE ($INIT_SYSTEM)${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════════════════════════════${NC}"
}

get_service_status() {
    if [ ! -f "$FRP_BIN" ]; then
        echo "not_installed"
        return
    fi
    
    case $INIT_SYSTEM in
        "systemd")
            if systemctl is-active --quiet frps 2>/dev/null; then
                echo "running"
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
            if pgrep -f "frps.*$FRP_CONFIG" >/dev/null; then
                echo "running"
            else
                echo "stopped"
            fi
            ;;
    esac
}

show_service_status() {
    local status=$(get_service_status)
    case $status in
        "running") echo -e "${GREEN}● 运行中${NC}" ;;
        "stopped") echo -e "${RED}● 已停止${NC}" ;;
        "not_installed") echo -e "${YELLOW}○ 未安装${NC}" ;;
    esac
}

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

show_config_summary() {
    get_current_config
    echo -e "${CYAN}┌─────────────────────────────────────────────────────────┐${NC}"
    printf "${CYAN}│${NC} 客户端连接端口 : %-26s${CYAN}│${NC}\n" "$CURRENT_BIND_PORT"
    printf "${CYAN}│${NC} 管理面板端口   : %-26s${CYAN}│${NC}\n" "$CURRENT_DASHBOARD_PORT"
    printf "${CYAN}│${NC} 管理用户名     : %-26s${CYAN}│${NC}\n" "$CURRENT_DASHBOARD_USER"
    printf "${CYAN}│${NC} 认证Token      : %-26s${CYAN}│${NC}\n" "${CURRENT_TOKEN:0:10}..."
    echo -e "${CYAN}└─────────────────────────────────────────────────────────┘${NC}"
}

# ============================================================================
# 安装函数
# ============================================================================

install_dependencies() {
    echo -e "${YELLOW}[1/6] 安装系统依赖...${NC}"
    case $PKG_MANAGER in
        "apk")
            apk update >/dev/null 2>&1
            apk add --no-cache wget tar ca-certificates curl >/dev/null 2>&1
            ;;
        "apt")
            apt update >/dev/null 2>&1
            apt install -y wget tar ca-certificates curl >/dev/null 2>&1
            ;;
    esac
    echo -e "${GREEN}✓ 依赖安装完成${NC}"
}

create_user() {
    echo -e "${YELLOW}[2/6] 创建FRP运行用户...${NC}"
    if id -u "$FRP_USER" >/dev/null 2>&1; then
        echo -e "${YELLOW}用户 $FRP_USER 已存在${NC}"
        return
    fi
    case $OS_TYPE in
        "alpine") adduser -D -H -s /bin/false "$FRP_USER" >/dev/null 2>&1 ;;
        "debian") useradd -r -s /bin/false -M "$FRP_USER" >/dev/null 2>&1 ;;
    esac
    echo -e "${GREEN}✓ 用户创建完成${NC}"
}

download_frp() {
    echo -e "${YELLOW}[3/6] 下载FRP v${FRP_VERSION}...${NC}"
    mkdir -p "$FRP_DIR"
    wget -q --show-progress -O "/tmp/${FRP_PACKAGE}.tar.gz" "$FRP_URL"
    if [ $? -ne 0 ]; then
        echo -e "${RED}下载失败，请检查网络${NC}"
        exit 1
    fi
    tar -xzf "/tmp/${FRP_PACKAGE}.tar.gz" -C "/tmp/"
    cp "/tmp/${FRP_PACKAGE}/frps" "$FRP_DIR/"
    chown -R "$FRP_USER":"$FRP_USER" "$FRP_DIR"
    chmod 750 "$FRP_DIR"
    chmod 755 "$FRP_BIN"
    echo -e "${GREEN}✓ FRP安装完成${NC}"
}

create_config_file() {
    echo -e "${YELLOW}[4/6] 创建配置文件...${NC}"
    
    read -p "请输入客户端连接端口 [7000]: " bind_port
    bind_port=${bind_port:-7000}
    
    read -p "请输入管理面板端口 [7500]: " dashboard_port
    dashboard_port=${dashboard_port:-7500}
    
    read -p "请输入管理面板用户名 [admin]: " dashboard_user
    dashboard_user=${dashboard_user:-admin}
    
    read -p "请输入管理面板密码: " dashboard_pwd
    dashboard_pwd=${dashboard_pwd:-$(openssl rand -base64 12)}
    
    read -p "请输入认证Token: " token
    token=${token:-$(openssl rand -base64 16)}
    
    cat > "$FRP_CONFIG" << EOF
[common]
bind_addr = 0.0.0.0
bind_port = $bind_port
dashboard_addr = 0.0.0.0
dashboard_port = $dashboard_port
dashboard_user = $dashboard_user
dashboard_pwd = $dashboard_pwd
token = $token
log_file = $FRP_LOG
log_level = info
log_max_days = 3
max_pool_count = 50
authentication_timeout = 900
EOF
    
    chown "$FRP_USER":"$FRP_USER" "$FRP_CONFIG"
    echo -e "${GREEN}✓ 配置文件创建完成${NC}"
    
    # 保存配置到变量供后续使用
    USER_CONFIG_BIND_PORT="$bind_port"
    USER_CONFIG_DASHBOARD_PORT="$dashboard_port"
    USER_CONFIG_DASHBOARD_USER="$dashboard_user"
    USER_CONFIG_TOKEN="$token"
}

create_service_file() {
    echo -e "${YELLOW}[5/6] 创建系统服务...${NC}"
    
    case $INIT_SYSTEM in
        "systemd")
            cat > /etc/systemd/system/frps.service << EOF
[Unit]
Description=FRP Server Daemon
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=$FRP_USER
Group=$FRP_USER
Restart=always
RestartSec=10s
StartLimitBurst=0
ExecStart=$FRP_BIN -c $FRP_CONFIG
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
command="$FRP_BIN"
command_args="-c $FRP_CONFIG"
command_user="$FRP_USER"
command_background=true
pidfile="/var/run/frps.pid"
depend() { need net; }
EOF
            chmod +x /etc/init.d/frps
            rc-update add frps default >/dev/null 2>&1
            ;;
        "sysvinit")
            cat > /etc/init.d/frps << 'EOF'
#!/bin/sh
### BEGIN INIT INFO
# Provides:          frps
# Required-Start:    $network
# Required-Stop:     $network
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: FRP Server
### END INIT INFO
EOF
            cat >> /etc/init.d/frps << EOF
DAEMON=$FRP_BIN
DAEMON_ARGS="-c $FRP_CONFIG"
PIDFILE=/var/run/frps.pid
USER=$FRP_USER

case "\$1" in
    start)
        start-stop-daemon --start --quiet --background --make-pidfile \\
            --pidfile \$PIDFILE --chuid \$USER --exec \$DAEMON -- \$DAEMON_ARGS
        ;;
    stop)
        start-stop-daemon --stop --quiet --pidfile \$PIDFILE
        ;;
    restart)
        \$0 stop
        sleep 1
        \$0 start
        ;;
    status)
        if [ -f \$PIDFILE ] && kill -0 \$(cat \$PIDFILE) 2>/dev/null; then
            echo "Running"
        else
            echo "Stopped"
        fi
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

save_security_info() {
    echo -e "${YELLOW}[6/6] 保存安全信息...${NC}"
    
    local local_ip=$(ip route get 1 | awk '{print $NF;exit}' 2>/dev/null || hostname)
    
    cat > "$FRP_DIR/frp_security_info.txt" << EOF
================================================
FRP 安全信息
================================================
安装时间: $(date)
服务器地址: ${local_ip}

连接配置:
  客户端连接端口: ${USER_CONFIG_BIND_PORT}
  认证Token: ${USER_CONFIG_TOKEN}

管理面板:
  访问端口: ${USER_CONFIG_DASHBOARD_PORT}
  用户名: ${USER_CONFIG_DASHBOARD_USER}
  密码: ${dashboard_pwd}

服务管理:
  启动: systemctl start frps
  停止: systemctl stop frps
  状态: systemctl status frps

客户端配置示例:
[common]
server_addr = ${local_ip}
server_port = ${USER_CONFIG_BIND_PORT}
token = ${USER_CONFIG_TOKEN}
================================================
EOF
    
    chmod 600 "$FRP_DIR/frp_security_info.txt"
    echo -e "${GREEN}✓ 安全信息已保存到: $FRP_DIR/frp_security_info.txt${NC}"
}

install_frp() {
    echo -e "${BLUE}开始安装 FRP 服务端...${NC}\n"
    
    install_dependencies
    create_user
    download_frp
    create_config_file
    create_service_file
    save_security_info
    
    echo ""
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${WHITE}                    FRP 安装完成！${NC}"
    echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}安装信息:${NC}"
    echo -e "  客户端连接端口: ${USER_CONFIG_BIND_PORT}"
    echo -e "  管理面板端口:   ${USER_CONFIG_DASHBOARD_PORT}"
    echo -e "  管理用户名:     ${USER_CONFIG_DASHBOARD_USER}"
    echo -e "  认证Token:      ${USER_CONFIG_TOKEN}"
    echo ""
    
    read -p "是否立即启动 FRP 服务？(Y/n): " start_now
    if [[ "$start_now" =~ ^[Yy]?$ ]]; then
        case $INIT_SYSTEM in
            "systemd") systemctl start frps ;;
            "openrc") rc-service frps start ;;
            "sysvinit") service frps start ;;
        esac
        echo -e "${GREEN}✓ FRP 服务已启动${NC}"
    fi
}

# ============================================================================
# 主程序
# ============================================================================

main() {
    check_root
    detect_system
    install_frp
}

main "$@"
