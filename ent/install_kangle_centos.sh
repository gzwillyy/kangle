#!/bin/bash

set -e  # 在出现错误时立即退出脚本

# =============================================================================
# 配置参数
# =============================================================================

VERSION="3.5.21.16"
DSOVERSION="3.5.21.12"

echo "设置软件源..."
# 使用 printf 模拟用户输入：选择 1 并确认使用 HTTP 协议
curl -sSL https://linuxmirrors.cn/main.sh | bash --abroad <<EOF
1
Y
EOF

if [ $? -ne 0 ]; then
    echo "设置软件源失败。"
    exit 1
fi

# =============================================================================
# 检查输入参数
# =============================================================================

if [ $# -ne 1 ]; then
    echo "Usage: $0 <install_directory>"
    exit 1
fi

PREFIX=$1

# =============================================================================
# 检测操作系统类型和版本
# =============================================================================

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    VERSION_ID=${VERSION_ID%%.*}
else
    echo "无法检测操作系统类型。"
    exit 1
fi

if [[ "$OS" != "centos" ]]; then
    echo "此脚本仅适用于 CentOS 6、7-8 / Stream 8。"
    exit 1
fi

# =============================================================================
# 确定 CentOS 版本
# =============================================================================

if [[ "$VERSION_ID" == "6" ]]; then
    CENTOS_VERSION=6
elif [[ "$VERSION_ID" == "7" || "$VERSION_ID" == "8" ]]; then
    CENTOS_VERSION=$VERSION_ID
elif [[ "$VERSION_ID" == "Stream" ]]; then
    # 对于 CentOS Stream 8，VERSION_ID 仍为 "8"
    CENTOS_VERSION="8"
else
    echo "不支持的 CentOS 版本: $VERSION_ID"
    exit 1
fi

echo "检测到的 CentOS 版本: $CENTOS_VERSION"

# =============================================================================
# 确定包管理器
# =============================================================================

if [[ "$CENTOS_VERSION" -ge 8 ]]; then
    if command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
    else
        PKG_MANAGER="yum"
    fi
else
    PKG_MANAGER="yum"
fi

echo "使用的包管理器: $PKG_MANAGER"

# =============================================================================
# 设置 ARCH 变量
# =============================================================================

ARCH="-$CENTOS_VERSION"

if [ "$(arch)" = "x86_64" ]; then
    ARCH="${ARCH}-x64"
fi

echo "检测到的 ARCH: $ARCH"

# =============================================================================
# 停止并禁用 httpd 和 nginx 服务
# =============================================================================

echo "停止并禁用 httpd 和 nginx 服务..."

SERVICES=("httpd" "nginx")

for svc in "${SERVICES[@]}"; do
    if [[ "$CENTOS_VERSION" -ge 7 ]]; then
        if systemctl list-units --type=service --all | grep -q "$svc"; then
            sudo systemctl stop "$svc" || true
            sudo systemctl disable "$svc" || true
            echo "$svc 服务已停止并禁用。"
        else
            echo "$svc 服务不存在或已停止。"
        fi
    else
        if service "$svc" status >/dev/null 2>&1; then
            sudo service "$svc" stop || true
            sudo chkconfig --level 2345 "$svc" off || true
            echo "$svc 服务已停止并禁用。"
        else
            echo "$svc 服务不存在或已停止。"
        fi
    fi
done

# =============================================================================
# 安装必要的软件包
# =============================================================================

echo "安装必要的软件包..."

# 更新包管理器
sudo $PKG_MANAGER -y update

# 安装软件包
sudo $PKG_MANAGER -y install libjpeg-turbo libtiff libpng unzip wget

# =============================================================================
# 配置防火墙
# =============================================================================

echo "配置防火墙..."

PORTS=(80 443 3311 3312 3313 21)

if [[ "$CENTOS_VERSION" -ge 7 ]]; then
    echo "使用 iptables 配置防火墙端口..."
    for port in "${PORTS[@]}"; do
        sudo /sbin/iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
    done
    sudo /etc/rc.d/init.d/iptables save
    echo "防火墙端口已开放。"
else
    echo "使用 iptables 配置防火墙端口..."
    for port in "${PORTS[@]}"; do
        sudo /sbin/iptables -I INPUT -p tcp --dport "$port" -j ACCEPT
    done
    sudo /etc/rc.d/init.d/iptables save
    echo "防火墙端口已开放。"
fi

# =============================================================================
# 停用 IPv6 防火墙和 firewalld
# =============================================================================

echo "停用 firewalld 和 ip6tables..."

if [[ "$CENTOS_VERSION" -ge 7 ]]; then
    sudo systemctl stop firewalld 2>/dev/null || true
    sudo systemctl disable firewalld 2>/dev/null || true
    sudo systemctl stop ip6tables 2>/dev/null || true
    sudo systemctl disable ip6tables 2>/dev/null || true
    echo "firewalld 和 ip6tables 已停用。"
else
    sudo service ip6tables stop 2>/dev/null || true
    sudo chkconfig ip6tables off 2>/dev/null || true
    echo "firewalld 和 ip6tables 已停用。"
fi

# =============================================================================
# 安装 Kangle
# =============================================================================

echo "安装 Kangle..."

KANGLE_TAR="kangle-ent-${VERSION}${ARCH}.tar.gz"
KANGLE_URL="https://github.com/gzwillyy/kangle/raw/dev/ent/${KANGLE_TAR}"

wget "$KANGLE_URL" -O "$KANGLE_TAR"
echo "已下载 Kangle 安装包。"

tar xzf "$KANGLE_TAR"
cd kangle || { echo "解压 Kangle 安装包失败。"; exit 1; }

# 停止已有的 Kangle 实例
echo "停止已有的 Kangle 实例（如果有）..."
sudo $PREFIX/bin/kangle -q || true
sudo killall -9 kangle || true
sleep 3

mkdir -p "$PREFIX"

# 下载许可文件
LICENSE_URL="https://github.com/gzwillyy/kangle/raw/dev/ent/license/Ultimate/license.txt"
wget "$LICENSE_URL" -O "$PREFIX/license.txt"
echo "已下载许可文件。"

# 运行安装脚本
echo "运行 Kangle 安装脚本..."
sudo ./install.sh "$PREFIX"
echo "Kangle 安装脚本已运行。"

# 启动 Kangle
echo "启动 Kangle..."
sudo $PREFIX/bin/kangle

# =============================================================================
# 配置开机自启
# =============================================================================

echo "配置开机自启..."

if [[ "$CENTOS_VERSION" -eq 6 ]]; then
    # 对于 CentOS 6，使用 rc.local
    echo "$PREFIX/bin/kangle" | sudo tee -a /etc/rc.d/rc.local
    sudo chmod +x /etc/rc.d/rc.local
    echo "已将 Kangle 添加到 /etc/rc.d/rc.local 以实现开机自启。"
elif [[ "$CENTOS_VERSION" -ge 7 ]]; then
    # 对于 CentOS 7-8 / Stream 8，使用 systemd
    KANGLE_SERVICE_FILE="/etc/systemd/system/kangle.service"

    if [ ! -f "$KANGLE_SERVICE_FILE" ]; then
        sudo bash -c "cat > $KANGLE_SERVICE_FILE" <<EOL
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

        sudo systemctl daemon-reload
        sudo systemctl enable kangle
        sudo systemctl start kangle
        echo "已创建并启用 systemd 服务文件 kangle.service。"
    else
        echo "systemd 服务文件 kangle.service 已存在。"
    fi
fi

# =============================================================================
# 更新首页
# =============================================================================

echo "更新 Kangle 首页..."

sudo rm -rf "$PREFIX/www/index.html"
EASY_PANEL_URL="https://github.com/gzwillyy/kangle/raw/dev/easypanel/index.html"
wget "$EASY_PANEL_URL" -O "$PREFIX/www/index.html"
echo "首页已更新。"

# 重启 Kangle 以应用更改
echo "重启 Kangle 以应用更改..."
sudo $PREFIX/bin/kangle -q
sudo $PREFIX/bin/kangle -z /var/cache/kangle

cd ..

# =============================================================================
# 安装 DSO
# =============================================================================

echo "安装 DSO..."

DSO_ZIP="kangle-dso-${DSOVERSION}.zip"
DSO_URL="https://github.com/gzwillyy/kangle/raw/dev/dso/${DSO_ZIP}"

wget "$DSO_URL" -O "$DSO_ZIP"
echo "已下载 DSO 包。"

unzip -o "$DSO_ZIP"
echo "已解压 DSO 包。"

cd dso || { echo "进入 dso 目录失败。"; exit 1; }

sudo cp -rf bin "$PREFIX"
sudo cp -rf ext "$PREFIX"

# 启动 Kangle 以应用 DSO 更改
echo "启动 Kangle 以应用 DSO 更改..."
sudo $PREFIX/bin/kangle

cd ..

# =============================================================================
# 完成安装
# =============================================================================

echo "Kangle 安装完成。"
