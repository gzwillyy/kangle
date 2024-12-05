#!/bin/bash

set -euo pipefail  # 遇到错误立即退出，未定义变量报错，管道命令失败时退出

# =============================================================================
# 常量和变量
# =============================================================================

PREFIX=""
BASE_DIR=""
LOG_FILE="/var/log/uninstall_kangle.log"

SERVICES=("httpd" "nginx")
PORTS=(80 443 3311 3312 3313 21)

# =============================================================================
# 函数定义
# =============================================================================

# 日志函数：记录带时间戳的消息到日志文件并输出到终端
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') : $*" | tee -a "$LOG_FILE"
}

# 初始化日志文件
initialize_log() {
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"
}

# 检查是否以 root 用户运行
check_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        log "请以 root 用户运行此脚本。"
        exit 1
    fi
}

# 检查输入参数
check_arguments() {
    if [ $# -ne 1 ]; then
        echo "用法: $0 <安装目录>"
        exit 1
    fi
    PREFIX="$1"
    if [ ! -d "$PREFIX" ]; then
        log "安装目录 $PREFIX 不存在。请检查路径是否正确。"
        exit 1
    fi
    log "卸载将从安装目录 $PREFIX 开始。"
}

# 检测操作系统类型和版本
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS="$ID"
        VERSION_ID_FULL="$VERSION_ID"
        VERSION_ID="${VERSION_ID%%.*}"
    else
        log "无法检测操作系统类型。"
        exit 1
    fi

    if [[ "$OS" != "centos" ]]; then
        log "此脚本仅适用于 CentOS 6、7-8 / Stream 8。"
        exit 1
    fi
}

# 确定 CentOS 版本
determine_version() {
    if [[ "$VERSION_ID" == "6" ]]; then
        CENTOS_VERSION=6
    elif [[ "$VERSION_ID" == "7" || "$VERSION_ID" == "8" ]]; then
        CENTOS_VERSION="$VERSION_ID"
    elif [[ "$VERSION_ID" == "Stream" ]]; then
        # 对于 CentOS Stream 8，VERSION_ID 通常仍为 "8"
        CENTOS_VERSION="8"
    else
        log "不支持的 CentOS 版本: $VERSION_ID"
        exit 1
    fi

    log "检测到的 CentOS 版本: $CENTOS_VERSION"
}

# 确定包管理器
determine_pkg_manager() {
    if [[ "$CENTOS_VERSION" -ge 8 ]]; then
        if command -v dnf >/dev/null 2>&1; then
            PKG_MANAGER="dnf"
        else
            PKG_MANAGER="yum"
        fi
    else
        PKG_MANAGER="yum"
    fi

    log "使用的包管理器: $PKG_MANAGER"
}

# 设置 ARCH 变量
set_arch() {
    ARCH="-$CENTOS_VERSION"
    if [ "$(uname -m)" = "x86_64" ]; then
        ARCH="${ARCH}-x64"
    fi
    log "检测到的 ARCH: $ARCH"
}

# 备份防火墙规则
backup_firewall() {
    if [ -f /root/iptables.backup ]; then
        log "iptables 备份文件已存在于 /root/iptables.backup。"
    else
        log "备份当前 iptables 规则..."
        iptables-save > /root/iptables.backup || { log "备份 iptables 规则失败。"; exit 1; }
        log "已备份 iptables 规则到 /root/iptables.backup。"
    fi
}

# 恢复防火墙规则
restore_firewall() {
    if [ -f /root/iptables.backup ]; then
        log "恢复 iptables 规则..."
        iptables-restore < /root/iptables.backup || { log "恢复 iptables 规则失败。"; exit 1; }
        log "iptables 规则已恢复。"

        if [[ "$CENTOS_VERSION" -ge 7 ]]; then
            # 重启 iptables 服务
            systemctl restart iptables || { log "重启 iptables 服务失败。"; exit 1; }
        else
            # 重启 iptables 服务
            service iptables restart || { log "重启 iptables 服务失败。"; exit 1; }
        fi
    else
        log "未找到 iptables 备份文件 /root/iptables.backup，跳过恢复防火墙规则。"
    fi
}

# 检测并卸载 firewalld（如果需要）
reinstall_firewalld() {
    read -p "是否需要重新安装 firewalld? [y/N]: " choice
    case "$choice" in
        y|Y )
            if rpm -q firewalld >/dev/null 2>&1; then
                log "firewalld 已安装。"
            else
                log "安装 firewalld..."
                $PKG_MANAGER -y install firewalld || { log "安装 firewalld 失败。"; exit 1; }
                log "firewalld 已安装。"
                systemctl start firewalld
                systemctl enable firewalld
                log "firewalld 服务已启动并设置为开机自启。"
            fi
            ;;
        * )
            log "跳过 firewalld 的重新安装。"
            ;;
    esac
}

# 停止并禁用 Kangle 服务
stop_disable_kangle() {
    log "停止并禁用 Kangle 服务..."

    if [[ "$CENTOS_VERSION" -ge 7 ]]; then
        KANGLE_SERVICE_FILE="/etc/systemd/system/kangle.service"
        if [ -f "$KANGLE_SERVICE_FILE" ]; then
            systemctl stop kangle || true
            systemctl disable kangle || true
            log "已停止并禁用 systemd 服务文件 kangle.service。"
            rm -f "$KANGLE_SERVICE_FILE" || { log "删除 systemd 服务文件失败。"; exit 1; }
            systemctl daemon-reload
            log "已删除 systemd 服务文件 kangle.service。"
        else
            log "systemd 服务文件 kangle.service 不存在，跳过。"
        fi
    else
        # 对于 CentOS 6，移除 rc.local 中的启动命令
        if grep -Fxq "$PREFIX/bin/kangle" /etc/rc.d/rc.local; then
            sed -i "\|$PREFIX/bin/kangle|d" /etc/rc.d/rc.local
            log "已从 /etc/rc.d/rc.local 中移除 Kangle 启动命令。"
        else
            log "rc.local 中未找到 Kangle 启动命令，跳过。"
        fi
    fi

    log "Kangle 服务已停止并禁用。"
}

# 删除 Kangle 文件
remove_kangle_files() {
    log "删除 Kangle 安装目录中的文件..."

    if [ -d "$PREFIX" ]; then
        rm -rf "$PREFIX" || { log "删除安装目录失败。"; exit 1; }
        log "已删除安装目录 $PREFIX。"
    else
        log "安装目录 $PREFIX 不存在，跳过删除。"
    fi
}

# 恢复被停止的服务
reenable_services() {
    log "重新启用被停止的服务: ${SERVICES[*]}"

    for svc in "${SERVICES[@]}"; do
        if [[ "$CENTOS_VERSION" -ge 7 ]]; then
            if systemctl list-unit-files | grep -q "^$svc\.service"; then
                systemctl enable "$svc" || { log "启用 $svc 服务失败。"; exit 1; }
                systemctl start "$svc" || { log "启动 $svc 服务失败。"; exit 1; }
                log "已启用并启动 $svc 服务。"
            else
                log "$svc 服务文件不存在，跳过启用和启动。"
            fi
        else
            if chkconfig --list "$svc" >/dev/null 2>&1; then
                chkconfig "$svc" on || { log "启用 $svc 服务失败。"; exit 1; }
                service "$svc" start || { log "启动 $svc 服务失败。"; exit 1; }
                log "已启用并启动 $svc 服务。"
            else
                log "$svc 服务不存在，跳过启用和启动。"
            fi
        fi
    done
}

# 删除防火墙规则（如果需要）
remove_firewall_rules() {
    read -p "是否需要删除通过脚本添加的 iptables 规则? [y/N]: " choice
    case "$choice" in
        y|Y )
            log "删除 iptables 中的指定端口规则..."
            for port in "${PORTS[@]}"; do
                if iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
                    iptables -D INPUT -p tcp --dport "$port" -j ACCEPT
                    log "已删除 iptables 中的端口 $port 规则。"
                else
                    log "iptables 中未找到端口 $port 的规则，跳过。"
                fi
            done

            # 保存 iptables 规则
            if [[ "$CENTOS_VERSION" -ge 7 ]]; then
                iptables-save > /etc/sysconfig/iptables || { log "保存 iptables 规则失败。"; exit 1; }
                systemctl restart iptables || { log "重启 iptables 服务失败。"; exit 1; }
            else
                /etc/init.d/iptables save || { log "保存 iptables 规则失败。"; exit 1; }
                service iptables restart || { log "重启 iptables 服务失败。"; exit 1; }
            fi

            log "iptables 规则已更新。"
            ;;
        * )
            log "跳过删除 iptables 规则。"
            ;;
    esac
}

# 删除备份文件
remove_backup() {
    if [ -f /root/iptables.backup ]; then
        read -p "是否需要删除 iptables 备份文件 /root/iptables.backup? [y/N]: " choice
        case "$choice" in
            y|Y )
                rm -f /root/iptables.backup || { log "删除备份文件失败。"; exit 1; }
                log "已删除 iptables 备份文件 /root/iptables.backup。"
                ;;
            * )
                log "保留 iptables 备份文件 /root/iptables.backup。"
                ;;
        esac
    else
        log "未找到 iptables 备份文件 /root/iptables.backup，跳过删除。"
    fi
}

# 删除日志文件（可选）
remove_log_file() {
    read -p "是否需要删除卸载日志文件 $LOG_FILE? [y/N]: " choice
    case "$choice" in
        y|Y )
            rm -f "$LOG_FILE" || { log "删除日志文件失败。"; exit 1; }
            log "已删除日志文件 $LOG_FILE。"
            ;;
        * )
            log "保留日志文件 $LOG_FILE。"
            ;;
    esac
}

# 恢复防火墙规则并重新启用服务
restore_system_state() {
    restore_firewall
    reenable_services
}

# 清理函数（恢复步骤）
cleanup() {
    log "执行清理操作..."
    # 恢复系统状态
    restore_system_state
}

# 捕获退出信号并执行清理
trap cleanup EXIT

# =============================================================================
# 主脚本流程
# =============================================================================

main() {
    check_root
    check_arguments "$@"
    initialize_log

    detect_os
    determine_version
    determine_pkg_manager
    set_arch

    # 备份当前防火墙规则（如果未备份）
    backup_firewall

    # 停止并禁用 Kangle 服务
    stop_disable_kangle

    # 删除 Kangle 文件
    remove_kangle_files

    # 删除通过脚本添加的防火墙规则
    remove_firewall_rules

    # 恢复防火墙规则并重新启用服务
    restore_system_state

    # 可选：重新安装 firewalld
    # reinstall_firewalld

    # 可选：删除 iptables 备份文件
    remove_backup

    # 可选：删除卸载日志文件
    remove_log_file

    log "Kangle 卸载完成。"
}

main "$@"
