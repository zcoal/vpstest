一个功能强大的 FRP 服务端管理脚本，支持**自动重启**、**进程监控**和**智能熔断**，让你再也不担心服务崩溃。

## ✨ 特性

- 🚀 **一键安装/卸载** FRP 服务端
- 🔄 **自动重启机制**（三层防护）
  - Systemd 自动重启（10秒恢复）
  - Cron 进程监控（每分钟检查）
  - 智能熔断保护（防止无限重启）
- 📊 **交互式管理菜单**（简单易用）
- 📝 **完整日志记录**（便于故障排查）
- 🔒 **安全配置管理**（自动生成安全信息）
- 🌍 **多系统支持**（Alpine、Debian、Ubuntu）
- 🛡️ **进程健康检查**（30秒超时重启）

## 📋 系统要求

- **操作系统**: Alpine Linux / Debian / Ubuntu
- **权限**: Root 用户
- **网络**: 能够访问 GitHub
- **依赖**: wget/curl、tar、systemd/openrc（自动安装）

## 🚀 快速开始

```bash
curl -o frp-manager.sh https://raw.githubusercontent.com/zcoal/vps-test/main/frp-onekey-installer.sh && chmod +x frp-onekey-installer.sh && sudo ./frp-onekey-installer.sh
