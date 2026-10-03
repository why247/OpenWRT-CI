#!/bin/bash
# AP8220 DIY script for OpenWRT-CI (IPQ807x/IPQ8071A)
# 由 PRIVATE.sh 末尾调用
# 用法: bash $GITHUB_WORKSPACE/Scripts/ap8220-diy.sh
# 注意: 必须在 feeds update/install 之后、make defconfig 之前调用

set -e

echo " "
echo "=============================================="
echo "Applying AP8220 customizations..."
echo "=============================================="

#---------------------------------------------------------------
# 定位 wrt 源码树 (照抄 PRIVATE.sh 的探测逻辑)
#---------------------------------------------------------------
if [ -d "./package/base-files" ]; then
	WRT_DIR="$(pwd)"
elif [ -d "./base-files" ]; then
	WRT_DIR="$(cd .. && pwd)"
else
	echo "[ERROR] WRT source tree not found, AP8220 customizations skipped!"
	exit 0
fi

PKG_DIR="$WRT_DIR/package"
echo "WRT source tree: $WRT_DIR"

# 只在 ipq807x/AP8220 构建时执行
if [ -n "$WRT_TARGET" ] && [[ "${WRT_TARGET,,}" != *"ipq807x"* && "${WRT_TARGET,,}" != *"qualcommax"* ]]; then
	echo "Not ipq807x/qualcommax target (WRT_TARGET=$WRT_TARGET), skipping AP8220 customizations."
	exit 0
fi

#---------------------------------------------------------------
# [1/1] RPS: 四核全开 (mask f)，把收包软中断摊到 4 核
#   EDMA 用 threaded NAPI，RX poll 已在 CPU1；RPS 把协议栈上半部再摊开。
#   与官方 smp_affinity（管硬中断）正交，不冲突。不要装 irqbalance。
#---------------------------------------------------------------
echo "=== AP8220 [1/1]: RPS tune (mask f for quad-core) ==="
UCID_DIR="$PKG_DIR/base-files/files/etc/uci-defaults"
mkdir -p "$UCID_DIR"
cat > "$UCID_DIR/99-ap8220-rps" << 'RPS_EOF'
#!/bin/sh
# AP8220 (IPQ8071A, 4x Cortex-A53) RPS 调优
# 首次开机执行后自删除；mask f = CPU0+1+2+3 全开
# 官方 smp_affinity 管硬中断亲和，本脚本只管 RPS 软中断分发，两者正交
for q in /sys/class/net/*/queues/rx-*/rps_cpus; do
	case "$q" in */lo/*) continue;; esac
	[ -w "$q" ] && echo f > "$q" 2>/dev/null
done
# 持久化：hotplug 脚本，接口 up 时自动设置
mkdir -p /etc/hotplug.d/net
cat > /etc/hotplug.d/net/20-ap8220-rps <<'HOTPLUG_EOF'
[ "$ACTION" = "add" ] || exit 0
[ "$INTERFACE" = "lo" ] && exit 0
for q in /sys/class/net/$INTERFACE/queues/rx-*/rps_cpus; do
	[ -w "$q" ] && echo f > "$q" 2>/dev/null
done
HOTPLUG_EOF
chmod +x /etc/hotplug.d/net/20-ap8220-rps
exit 0
RPS_EOF
chmod +x "$UCID_DIR/99-ap8220-rps"
echo "AP8220 RPS uci-defaults written!"
echo "AP8220 customizations applied!"
