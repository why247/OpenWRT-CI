#!/bin/bash
# N1 DIY script for OpenWRT-CI (armsr/armv8, Phicomm N1)
# 由 PRIVATE.sh 末尾调用
# 用法: bash $GITHUB_WORKSPACE/Scripts/n1-diy.sh
# 注意: 必须在 feeds update/install 之后、make defconfig 之前调用

set -e

echo " "
echo "=============================================="
echo "Applying N1 customizations..."
echo "=============================================="

#---------------------------------------------------------------
# 定位 wrt 源码树 (照抄 PRIVATE.sh 的探测逻辑)
#---------------------------------------------------------------
if [ -d "./package/base-files" ]; then
	WRT_DIR="$(pwd)"
elif [ -d "./base-files" ]; then
	WRT_DIR="$(cd .. && pwd)"
else
	echo "[ERROR] WRT source tree not found, N1 customizations skipped!"
	exit 0
fi

PKG_DIR="$WRT_DIR/package"
echo "WRT source tree: $WRT_DIR"

# 只在 armsr/N1 构建时执行
if [ -n "$WRT_TARGET" ] && [[ "${WRT_TARGET,,}" != *"armsr"* ]]; then
	echo "Not armsr target (WRT_TARGET=$WRT_TARGET), skipping N1 customizations."
	exit 0
fi

UCID_DIR="$PKG_DIR/base-files/files/etc/uci-defaults"
mkdir -p "$UCID_DIR"

HOTPLUG_DIR="$PKG_DIR/base-files/files/etc/hotplug.d/net"
mkdir -p "$HOTPLUG_DIR"

#---------------------------------------------------------------
# [1/7] 晶晨宝盒 luci-app-amlogic (eMMC 安装/在线升级/在线更新内核)
#---------------------------------------------------------------
echo "=== N1 [1/7]: luci-app-amlogic ==="
if [ ! -d "$PKG_DIR/luci-app-amlogic" ]; then
	git clone --depth=1 https://github.com/ophub/luci-app-amlogic "$PKG_DIR/luci-app-amlogic" || true
	echo "luci-app-amlogic cloned"
else
	echo "luci-app-amlogic already exists, skipping"
fi

#---------------------------------------------------------------
# [2/7] HomeProxy + sing-box: 使用 VIKINGYFY/packages 的版本
# 注意: PRIVATE.sh 已经打了补丁集，这里只确保源码版本正确
#---------------------------------------------------------------
echo "=== N1 [2/7]: sing-box version check ==="
# sing-box 由 PRIVATE.sh 的 UPDATE_PACKAGE 机制处理，这里不重复操作

#---------------------------------------------------------------
# [3/7] uci-defaults: 99-n1-defaults (主题+中文+基础sysctl)
#---------------------------------------------------------------
echo "=== N1 [3/7]: 99-n1-defaults ==="
cat > "$UCID_DIR/99-n1-defaults" << 'EOF'
#!/bin/sh
# Set Bootstrap as the default LuCI theme on first boot.
uci -q set luci.main.mediaurlbase='/luci-static/bootstrap'
uci -q commit luci
# Default language to Chinese
uci -q set luci.main.lang='zh_cn'
uci -q commit luci
# Ensure BBR sysctl settings are applied (in case sysctl.conf wasn't picked up)
sysctl -w net.ipv4.tcp_congestion_control=bbr 2>/dev/null
sysctl -w net.core.default_qdisc=fq 2>/dev/null
exit 0
EOF
chmod +x "$UCID_DIR/99-n1-defaults"

#---------------------------------------------------------------
# [4/7] uci-defaults: 99-n1-perf (CPU/RPS/IRQ/网卡调优)
#---------------------------------------------------------------
echo "=== N1 [4/7]: 99-n1-perf ==="
cat > "$UCID_DIR/99-n1-perf" << 'EOF'
#!/bin/sh
# N1 (S905D) 性能优化 - 首次开机执行

# --- 1. CPU governor -> performance (S905D 突发负载升频延迟, 直接锁最高频) ---
for gov in /sys/devices/system/cpu