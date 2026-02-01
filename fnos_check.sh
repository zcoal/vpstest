#!/bin/bash
# FNOS 病毒专杀工具 v3.1 (精简稳定版)

# 1. 设置日志文件
OUT="/tmp/fnos_clean_$(date +%F_%H%M%S).txt"

# 2. 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# 3. 定义日志函数 (直接输出并写入文件)
log() { echo -e "$1" | tee -a "$OUT"; }
warn() { echo -e "${RED}[发现威胁] $1${NC}" | tee -a "$OUT"; }
info() { echo -e "${GREEN}[安全] $1${NC}" | tee -a "$OUT"; }
action() { echo -e "${CYAN}[执行修复] $1${NC}" | tee -a "$OUT"; }

echo "========================================================" | tee -a "$OUT"
echo " FNOS 病毒检测与修复工具 " | tee -a "$OUT"
echo "========================================================" | tee -a "$OUT"

# --- 检查 cat 命令 ---
if [ ! -f /usr/bin/cat ] && [ -f /usr/bin/cat2 ]; then
warn "检测到 'cat' 命令丢失，系统已被篡改！"
read -p "是否立即修复 cat 命令？(y/n): " confirm
if [[ $confirm == "y" ]]; then
mv /usr/bin/cat2 /usr/bin/cat
chmod +x /usr/bin/cat
action "已将 cat2 恢复为 cat 。"
fi
fi

# --- 定义恶意文件 ---
MALICIOUS_FILES=(
"/usr/bin/nginx"
"/usr/sbin/gots"
"/usr/trim/bin/trim_https_cgi"
"/etc/systemd/system/nginx.service"
"/etc/systemd/system/trim_https_cgi.service"
)

# --- 扫描病毒 ---
FOUND_VIRUS=0

# 1. 文件扫描
for f in "${MALICIOUS_FILES[@]}"; do
if [ -e "$f" ]; then
warn "发现病毒文件: $f"
FOUND_VIRUS=1
fi
done

# 2. 内核模块扫描
MODULE_LOADED=0
if lsmod | grep -q "snd_pcap"; then
warn "发现恶意内核模块: snd_pcap (正在运行)"
MODULE_LOADED=1
FOUND_VIRUS=1
fi

# 3. 启动脚本扫描
STARTUP_FILE="/usr/trim/bin/system_startup.sh"
INJECTED=0
if [ -f "$STARTUP_FILE" ]; then
if grep -q "151.240.13.91" "$STARTUP_FILE" || grep -q "turmp" "$STARTUP_FILE"; then
warn "启动脚本 ($STARTUP_FILE) 被注入恶意下载代码！"
INJECTED=1
FOUND_VIRUS=1
fi
fi

# 4. 端口扫描
if ss -lntp | grep -q ":57132"; then
warn "发现恶意进程正在监听端口 57132"
FOUND_VIRUS=1
fi

# --- 结果判断 ---
echo "--------------------------------------------------------"
if [ $FOUND_VIRUS -eq 0 ]; then
info "恭喜！未扫描到已知病毒特征。"
exit 0
else
echo -e "${YELLOW}警告：系统已感染！${NC}"
# 再次确认用户是否修复
read -p "是否尝试自动修复并清理所有病毒？(输入 y 确认): " choice
if [[ "$choice" != "y" ]]; then
echo "已取消修复。"
exit 0
fi
fi

echo "==================== 开始修复流程 ======================"

# --- 修复 1: 停止服务 ---
action "停止恶意服务..."
systemctl stop nginx.service trim_https_cgi.service 2>/dev/null
systemctl disable nginx.service trim_https_cgi.service 2>/dev/null

# --- 修复 2: 杀进程 ---
action "强制终止恶意进程..."
pkill -9 -f "trim_https_cgi" 2>/dev/null
pkill -9 -f "gots" 2>/dev/null
# 杀端口占用
PID_57132=$(ss -lntp | grep ":57132" | awk -F'pid=' '{print $2}' | awk -F',' '{print $1}')
if [ -n "$PID_57132" ]; then
kill -9 "$PID_57132" 2>/dev/null
action "已终止监听 57132 的进程"
fi

# --- 修复 3: 卸载模块 ---
if [ $MODULE_LOADED -eq 1 ]; then
action "尝试卸载恶意内核模块 snd_pcap..."
chattr -i /lib/modules/*/snd_pcap.ko 2>/dev/null
rmmod snd_pcap 2>/dev/null
if lsmod | grep -q "snd_pcap"; then
echo -e "${RED}[失败] 无法卸载 snd_pcap ，请修复后尝试重启。${NC}"
else
action "内核模块已卸载。"
fi
# 删除模块文件
find /lib/modules -name "snd_pcap.ko" -exec rm -f {} \;
depmod -a
fi

# --- 修复 4: 删除文件 ---
action "解锁并删除病毒文件..."
for f in "${MALICIOUS_FILES[@]}"; do
if [ -e "$f" ]; then
chattr -i "$f" 2>/dev/null
rm -f "$f"
if [ ! -e "$f" ]; then
action "已删除: $f"
fi
fi
done

# --- 修复 5: 清理启动脚本 ---
if [ $INJECTED -eq 1 ]; then
action "清理启动脚本中的恶意代码..."
cp "$STARTUP_FILE" "${STARTUP_FILE}.bak"
sed -i '/151.240.13.91/d' "$STARTUP_FILE"
sed -i '/turmp/d' "$STARTUP_FILE"
action "启动脚本已清理。"
fi

# --- 修复 6: 防火墙 ---
action "添加防火墙规则 (屏蔽恶意 IP)..."
if command -v nft >/dev/null 2>&1; then
nft add rule inet filter input ip saddr 45.95.212.102 drop 2>/dev/null
nft add rule inet filter input ip saddr 151.240.13.91 drop 2>/dev/null
nft add rule inet filter output ip daddr 45.95.212.102 drop 2>/dev/null
nft add rule inet filter output ip daddr 151.240.13.91 drop 2>/dev/null
else
iptables -I INPUT -s 45.95.212.102 -j DROP 2>/dev/null
iptables -I OUTPUT -d 45.95.212.102 -j DROP 2>/dev/null
iptables -I INPUT -s 151.240.13.91 -j DROP 2>/dev/null
iptables -I OUTPUT -d 151.240.13.91 -j DROP 2>/dev/null
fi
action "防火墙规则已应用。"

echo "========================================================" | tee -a "$OUT"
echo "修复完成。建议输入 'reboot' 重启系统。" | tee -a "$OUT"