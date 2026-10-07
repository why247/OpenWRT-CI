#!/bin/bash
# AP8220 DIY script for OpenWRT-CI (IPQ807x/IPQ8071A)
# 由 PRIVATE.sh 末尾调用；必须在 feeds update/install 之后、make defconfig 之前
#
# 说明：IRQ / NAPI / RPS 不在这里改。上游 qualcommax 自带
#   /usr/libexec/platform/packet-steering.sh + /etc/init.d/smp_affinity，
#   按 EDMA、ath11k 各中断精确分核，并在 netifd 事件后自动重新应用；
#   自定义 RPS/XPS 会与它互相覆盖。中断合并会增加延迟，也不再设置。
#   flow offload + PPE 硬件卸载由 PRIVATE.sh [3b/6] 开启。

set -e

echo " "
echo "=============================================="
echo "Applying AP8220 customizations..."
echo "=============================================="

if [ -d "./package/base-files" ]; then
	WRT_DIR="$(pwd)"
elif [ -d "./base-files" ]; then
	WRT_DIR="$(cd .. && pwd)"
else
	echo "[ERROR] WRT source tree not found, AP8220 customizations skipped!"
	exit 0
fi

PKG_DIR="$WRT_DIR/package"

if [ -n "$WRT_TARGET" ] && [[ "${WRT_TARGET,,}" != *"ipq807x"* && "${WRT_TARGET,,}" != *"qualcommax"* ]]; then
	echo "Not ipq807x/qualcommax target (WRT_TARGET=$WRT_TARGET), skipping AP8220 customizations."
	exit 0
fi

UCID_DIR="$PKG_DIR/base-files/files/etc/uci-defaults"
mkdir -p "$UCID_DIR"

# [1/2] dnsmasq 缓存 15000，1-2MB 内存换重复查询零延迟
cat > "$UCID_DIR/99-ap8220-dnsmasq" << 'DNS_EOF'
#!/bin/sh
uci -q get dhcp.@dnsmasq[0] >/dev/null 2>&1 || exit 0
uci set dhcp.@dnsmasq[0].cachesize='15000'
uci commit dhcp
exit 0
DNS_EOF
chmod +x "$UCID_DIR/99-ap8220-dnsmasq"
echo "[1/2] dnsmasq cache 15000"

# [2/2] 清理旧版本留下的自定义 RPS hotplug，交还给上游 packet steering
cat > "$UCID_DIR/99-ap8220-cleanup" << 'CL_EOF'
#!/bin/sh
rm -f /etc/hotplug.d/net/20-ap8220-rps
exit 0
CL_EOF
chmod +x "$UCID_DIR/99-ap8220-cleanup"
echo "[2/2] legacy RPS hotplug cleanup"

echo "AP8220 customizations applied!"
