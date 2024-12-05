#!/bin/bash

set -euo pipefail  # 遇到错误立即退出，未定义变量报错，管道命令失败时退出

# =============================================================================
# 常量和变量
# =============================================================================

PREFIX="/vhs/kangle"
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

# 禁用 Kangle 服务
stop_disable_kangle() {
    log "禁用 Kangle 服务..."
    if grep -Fxq "$PREFIX/bin/kangle" /etc/rc.d/rc.local; then
        sed -i "\|$PREFIX/bin/kangle|d" /etc/rc.d/rc.local
        log "已从 /etc/rc.d/rc.local 中移除 Kangle 启动命令。"
    else
        log "rc.local 中未找到 Kangle 启动命令，跳过。"
    fi
    log "Kangle 服务已禁用。"
}

# 删除 Kangle 文件
remove_kangle_files() {
    log "删除 Kangle 安装目录中的文件..."

    killall kangle
    if [ -d "$PREFIX" ]; then
        rm -rf "$PREFIX" || { log "删除安装目录失败。"; exit 1; }
        log "已删除安装目录 $PREFIX。"
    else
        log "安装目录 $PREFIX 不存在，跳过删除。"
    fi
    rm -rf /vhs
}


# 删除防火墙规则（如果需要）
remove_firewall_rules() {

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


# =============================================================================
# 主脚本流程
# =============================================================================

main() {
    check_root
    initialize_log

    # 备份当前防火墙规则（如果未备份）
    backup_firewall

    # 停止并禁用 Kangle 服务
    stop_disable_kangle

    # 删除 Kangle 文件
    remove_kangle_files

    # 删除通过脚本添加的防火墙规则
    remove_firewall_rules

    # 可选：删除 iptables 备份文件
    remove_backup

    rm -rf $LOG_FILE
    log "Kangle 卸载完成。"
}

main
