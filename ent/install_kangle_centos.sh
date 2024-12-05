#!/bin/bash

set -euo pipefail  # 遇到错误立即退出，未定义变量报错，管道命令失败时退出

# =============================================================================
# 常量和变量
# =============================================================================

KANGLE_VERSION="3.5.21.16"
DSOVERSION="3.5.21.12"
PREFIX=""
BASE_DIR=""
LOG_FILE="/var/log/install_kangle.log"

SERVICES=("httpd" "nginx")
PORTS=(80 443 3311 3312 3313 21)
REQUIRED_COMMANDS=("wget" "unzip")

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
    if [ "$EUID" -ne 0 ]; then
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
    if [ -d "$PREFIX" ]; then
        log "安装目录 $PREFIX 已存在。"
    else
        log "创建安装目录 $PREFIX..."
        mkdir -p "$PREFIX" || { log "创建安装目录失败。"; exit 1; }
    fi
    # 设置目录所有权和权限（根据需要调整）
    chown root:root "$PREFIX"
    chmod 755 "$PREFIX"
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
    if [ "$CENTOS_VERSION" == "6" ] || [ "$CENTOS_VERSION" == "7" ] || [ "$CENTOS_VERSION" == "8" ]; then
        ARCH="-$CENTOS_VERSION"
        if [ "$(uname -m)" = "x86_64" ]; then
            ARCH="${ARCH}-x64"
        fi
    else
        log "不支持的 CentOS 版本: $CENTOS_VERSION"
        exit 1
    fi
    log "检测到的 ARCH: $ARCH"
}

# 添加用户确认
prompt_confirmation() {
    read -p "是否继续执行 [y/N]? " choice
    case "$choice" in 
      y|Y ) log "继续执行...";;
      * ) log "脚本已取消。"; exit 1;;
    esac
}

# 备份防火墙规则
backup_firewall() {
    log "备份当前 iptables 规则..."
    iptables-save > /root/iptables.backup || { log "备份 iptables 规则失败。"; exit 1; }
    log "已备份 iptables 规则到 /root/iptables.backup。"
}

# 检测并卸载 firewalld
uninstall_firewalld() {
    log "检测并卸载 firewalld（如果存在）..."

    if rpm -q firewalld >/dev/null 2>&1; then
        log "firewalld 已安装，准备卸载。"
        prompt_confirmation
        log "firewalld 已安装，正在停止并卸载..."

        # 停止 firewalld 服务
        systemctl stop firewalld || true

        # 禁用 firewalld 服务
        systemctl disable firewalld || true

        # 卸载 firewalld
        $PKG_MANAGER -y remove firewalld || { log "卸载 firewalld 失败。"; exit 1; }

        log "firewalld 已停止并卸载。"
    else
        log "firewalld 未安装，跳过卸载步骤。"
    fi
}

# 停止并禁用 httpd 和 nginx 服务
stop_disable_services() {
    log "停止并禁用 httpd 和 nginx 服务..."

    for svc in "${SERVICES[@]}"; do
        if [[ "$CENTOS_VERSION" -ge 7 ]]; then
            if systemctl list-units --type=service --all | grep -q "^$svc\.service"; then
                systemctl stop "$svc" || true
                systemctl disable "$svc" || true
                log "$svc 服务已停止并禁用。"
            else
                log "$svc 服务不存在或已停止。"
            fi
        else
            if service "$svc" status >/dev/null 2>&1; then
                service "$svc" stop || true
                chkconfig --level 2345 "$svc" off || true
                log "$svc 服务已停止并禁用。"
            else
                log "$svc 服务不存在或已停止。"
            fi
        fi
    done
}

# 安装 iptables-services（针对 CentOS 7 及以上）
install_iptables_services() {
    if [[ "$CENTOS_VERSION" -ge 7 ]]; then
        if ! rpm -q iptables-services >/dev/null 2>&1; then
            log "iptables-services 未安装，正在安装..."
            $PKG_MANAGER -y install iptables-services || { log "安装 iptables-services 失败。"; exit 1; }
            log "iptables-services 已安装。"
        else
            log "iptables-services 已安装。"
        fi
    fi
}

# 更新系统包
update_system() {
    log "更新系统包..."

    if [[ "$PKG_MANAGER" == "dnf" ]]; then
        dnf -y upgrade
    else
        yum -y update
    fi
}

# 检查并安装依赖项
install_dependencies() {
    log "检查并安装必要的依赖项..."

    for cmd in "${REQUIRED_COMMANDS[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log "缺少命令: $cmd，正在安装..."
            $PKG_MANAGER -y install "$cmd"
        else
            log "命令 $cmd 已存在。"
        fi
    done

    log "安装其他必要的软件包..."
    $PKG_MANAGER -y install libjpeg-turbo libtiff libpng psmisc || { log "安装软件包失败。"; exit 1; }

    # 安装 iptables-services（针对 CentOS 7 及以上）
    install_iptables_services
}

# 使用 iptables 配置防火墙
configure_firewall() {
    backup_firewall

    log "配置防火墙..."
    PORTS=(80 443 3311 3312 3313 21)

    log "使用 iptables 配置防火墙端口..."
    for port in "${PORTS[@]}"; do
        # 检查规则是否已存在，避免重复添加
        if ! iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
            iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
            log "端口 $port 已添加到 iptables。"
        else
            log "端口 $port 已在 iptables 中配置。"
        fi
    done

    log "保存 iptables 规则..."
    if [[ "$CENTOS_VERSION" -ge 7 ]]; then
        # 保存规则到 /etc/sysconfig/iptables
        iptables-save > /etc/sysconfig/iptables || { log "保存 iptables 规则失败。"; exit 1; }
        # 启用并重启 iptables 服务
        systemctl enable iptables
        systemctl restart iptables || { log "重启 iptables 服务失败。"; exit 1; }
    else
        # 对于 CentOS 6
        /etc/init.d/iptables save || { log "保存 iptables 规则失败。"; exit 1; }
        chkconfig iptables on
        service iptables restart || { log "重启 iptables 服务失败。"; exit 1; }
    fi

    log "防火墙端口已通过 iptables 开放。"
}

# 停用 ip6tables
stop_disable_ip6tables() {
    log "停用 ip6tables..."

    if [[ "$CENTOS_VERSION" -ge 7 ]]; then
        systemctl stop ip6tables 2>/dev/null || true
        systemctl disable ip6tables 2>/dev/null || true
        log "ip6tables 已停用。"
    else
        service ip6tables stop 2>/dev/null || true
        chkconfig ip6tables off 2>/dev/null || true
        log "ip6tables 已停用。"
    fi
}

# 下载文件带重试机制
download_with_retry() {
    local url=$1
    local output=$2
    local retries=3
    local count=0
    until [ $count -ge $retries ]
    do
        wget "$url" -O "$output" && return 0
        count=$((count+1))
        log "下载 $url 失败，重试 $count/$retries..."
        sleep 5
    done
    log "下载 $url 失败超过 $retries 次。"
    exit 1
}

# 校验下载文件的校验和（如果有）
verify_checksum() {
    local file=$1
    local checksum_expected=$2
    echo "$checksum_expected  $file" | sha256sum -c -
}

# 安装 Kangle
install_kangle() {
    log "安装 Kangle..."

    # 保存当前目录
    BASE_DIR=$(pwd)

    # 构造 Kangle 安装包文件名
    KANGLE_TAR="kangle-ent-${KANGLE_VERSION}${ARCH}.tar.gz"
    KANGLE_URL="https://github.com/gzwillyy/kangle/raw/dev/ent/${KANGLE_TAR}"
    KANGLE_CHECKSUM="your_expected_sha256_checksum_here"  # 替换为实际校验和

    log "下载 Kangle 安装包..."
    download_with_retry "$KANGLE_URL" "/tmp/$KANGLE_TAR"
    # 如果有校验和，启用以下行
    # verify_checksum "$KANGLE_TAR" "$KANGLE_CHECKSUM" || { log "Kangle 安装包校验失败。"; exit 1; }
    log "已下载 Kangle 安装包。"

    log "解压 Kangle 安装包..."
    tar xzf "$KANGLE_TAR"  -C /tmp/kangle || { log "解压 Kangle 安装包失败。"; exit 1; }

    cd /tmp/kangle || { log "进入 kangle 目录失败。"; exit 1; }

    log "停止已有的 Kangle 实例（如果有）..."
    if [ -x "$PREFIX/bin/kangle" ]; then
        "$PREFIX/bin/kangle" -q || true
    fi
    killall -9 kangle || true
    sleep 3

    mkdir -p "$PREFIX"

    # 下载许可文件
    LICENSE_URL="https://github.com/gzwillyy/kangle/raw/dev/ent/license/Ultimate/license.txt"
    LICENSE_CHECKSUM="your_license_checksum_here"  # 替换为实际校验和
    log "下载许可文件..."
    download_with_retry "$LICENSE_URL" "$PREFIX/license.txt"
    # 如果有校验和，启用以下行
    # verify_checksum "$PREFIX/license.txt" "$LICENSE_CHECKSUM" || { log "许可文件校验失败。"; exit 1; }
    log "已下载许可文件。"

    # 确保 install.sh 具有执行权限
    if [ ! -x ./install.sh ]; then
        chmod +x install.sh || { log "设置 install.sh 执行权限失败。"; exit 1; }
        log "已为 install.sh 设置执行权限。"
    fi

    # 运行安装脚本
    log "运行 Kangle 安装脚本..."
    ./install.sh "$PREFIX" || { log "运行 Kangle 安装脚本失败。"; exit 1; }
    log "Kangle 安装脚本已运行。"

    # 配置权限和所有权
    configure_kangle_permissions() {
        log "配置 Kangle 文件权限和所有权..."
        chown -R root:root "$PREFIX"
        chmod -R 755 "$PREFIX/bin"
        log "Kangle 文件权限和所有权已配置。"
    }
    configure_kangle_permissions

    # 启动 Kangle
    log "启动 Kangle..."
    "$PREFIX/bin/kangle"

    # 返回原始目录
    cd "$BASE_DIR" || exit
}

# 配置开机自启
configure_autostart() {
    log "配置开机自启..."

    if [[ "$CENTOS_VERSION" -eq 6 ]]; then
        # 对于 CentOS 6，使用 rc.local
        if ! grep -Fxq "$PREFIX/bin/kangle" /etc/rc.d/rc.local; then
            echo "$PREFIX/bin/kangle" >> /etc/rc.d/rc.local
            chmod +x /etc/rc.d/rc.local
            log "已将 Kangle 添加到 /etc/rc.d/rc.local 以实现开机自启。"
        else
            log "Kangle 已在 /etc/rc.d/rc.local 中配置。"
        fi
    elif [[ "$CENTOS_VERSION" -ge 7 ]]; then
        # 对于 CentOS 7-8 / Stream 8，使用 systemd
        KANGLE_SERVICE_FILE="/etc/systemd/system/kangle.service"

        if [ ! -f "$KANGLE_SERVICE_FILE" ]; then
            log "创建 systemd 服务文件 kangle.service..."
            cat > "$KANGLE_SERVICE_FILE" <<EOL
[Unit]
Description=Kangle Web Server
After=network.target

[Service]
Type=simple
ExecStart=$PREFIX/bin/kangle
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOL

            systemctl daemon-reload
            systemctl enable kangle
            systemctl start kangle
            log "已创建并启用 systemd 服务文件 kangle.service。"
        else
            log "systemd 服务文件 kangle.service 已存在。"
        fi
    fi
}

# 更新 Kangle 首页
update_homepage() {
    log "更新 Kangle 首页..."

    EASY_PANEL_URL="https://github.com/gzwillyy/kangle/raw/dev/easypanel/index.html"
    EASY_PANEL_CHECKSUM="your_easypanel_checksum_here"  # 替换为实际校验和
    TMP_INDEX="/tmp/index.html"

    log "下载首页文件..."
    download_with_retry "$EASY_PANEL_URL" "$TMP_INDEX"
    # 如果有校验和，启用以下行
    # verify_checksum "$TMP_INDEX" "$EASY_PANEL_CHECKSUM" || { log "首页文件校验失败。"; exit 1; }

    # 仅当内容不同才替换
    if [ ! -f "$PREFIX/www/index.html" ] || ! cmp -s "$TMP_INDEX" "$PREFIX/www/index.html"; then
        mv "$TMP_INDEX" "$PREFIX/www/index.html" || { log "替换首页文件失败。"; exit 1; }
        log "首页已更新。"
        # 重启 Kangle 以应用更改
        log "重启 Kangle 以应用更改..."
        "$PREFIX/bin/kangle" -q
        "$PREFIX/bin/kangle" -z /var/cache/kangle
    else
        log "首页文件未更改，跳过更新。"
    fi
}

# 安装 DSO
install_dso() {
    log "安装 DSO..."

    DSO_ZIP="kangle-dso-${DSOVERSION}.zip"
    DSO_URL="https://github.com/gzwillyy/kangle/raw/dev/dso/${DSO_ZIP}"
    DSO_CHECKSUM="your_dso_checksum_here"  # 替换为实际校验和
    TMP_DSO_ZIP="/tmp/$DSO_ZIP"

    # 检查 DSO 是否已安装
    if [ -d "$PREFIX/ext" ] && [ -d "$PREFIX/bin" ]; then
        log "DSO 已安装，跳过安装。"
        return
    fi

    log "下载 DSO 包..."
    download_with_retry "$DSO_URL" "$TMP_DSO_ZIP"
    # 如果有校验和，启用以下行
    # verify_checksum "$TMP_DSO_ZIP" "$DSO_CHECKSUM" || { log "DSO 包校验失败。"; exit 1; }
    log "已下载 DSO 包。"

    log "解压 DSO 包..."
    unzip -o "$TMP_DSO_ZIP" -d /tmp || { log "解压 DSO 包失败。"; exit 1; }
    log "已解压 DSO 包。"

    cd /tmp/dso || { log "进入 dso 目录失败。"; exit 1; }

    log "复制 DSO 文件到安装目录..."
    cp -rf bin "$PREFIX" || { log "复制 bin 目录失败。"; exit 1; }
    cp -rf ext "$PREFIX" || { log "复制 ext 目录失败。"; exit 1; }

    # 启动 Kangle 以应用 DSO 更改
    log "启动 Kangle 以应用 DSO 更改..."
    "$PREFIX/bin/kangle"

    # 返回原始目录
    cd "$BASE_DIR" || exit
}

# 完成安装
finish_installation() {
    log "Kangle 安装完成。"
}

# 检查系统资源
check_system_requirements() {
    REQUIRED_DISK_MB=10240  # 10GB
    REQUIRED_MEMORY_MB=2048  # 2GB

    AVAILABLE_DISK_MB=$(df / | tail -1 | awk '{print $4}')
    AVAILABLE_MEMORY_MB=$(free -m | grep Mem | awk '{print $7}')

    if [[ "$AVAILABLE_DISK_MB" -lt "$REQUIRED_DISK_MB" ]]; then
        log "磁盘空间不足。需要至少 ${REQUIRED_DISK_MB}MB，可用 ${AVAILABLE_DISK_MB}MB。"
        exit 1
    fi

    if [[ "$AVAILABLE_MEMORY_MB" -lt "$REQUIRED_MEMORY_MB" ]]; then
        log "内存不足。需要至少 ${REQUIRED_MEMORY_MB}MB，可用 ${AVAILABLE_MEMORY_MB}MB。"
        exit 1
    fi

    log "系统资源检查通过。"
}

# 清理函数（恢复步骤）
cleanup() {
    log "执行清理操作..."
    # 删除残留文件和目录
    log "删除安装残留文件..."
    rm -rf /tmp/kangle-ent-*.tar.gz
    rm -rf /tmp/kangle-dso-*.zip
    rm -rf /tmp/index.html
    rm -rf /tmp/dso
    log "安装残留文件已清除。"
}

# 捕获退出信号
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

    check_system_requirements

    uninstall_firewalld
    stop_disable_services
    update_system
    install_dependencies
    configure_firewall
    stop_disable_ip6tables
    install_kangle
    configure_autostart
    update_homepage
    install_dso
    finish_installation
}

main "$@"
