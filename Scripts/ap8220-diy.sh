#!/bin/bash
# AP8220 DIY script for OpenWRT-CI (IPQ807x/IPQ8071A)
# 由 PRIVATE.sh 末尾调用；必须在 feeds update/install 之后、make defconfig 之前
#
# 说明：IRQ / NAPI / RPS 不在这里改。上游 qualcommax 自带
#   /usr/libexec/platform/packet-steering.sh + /etc/init.d/smp_affinity，
#   按 EDMA、ath11k 各中断精确分核，并在 netifd 事件后自动重新应用；
#   自定义 RPS/XPS 会与它互相覆盖。中断合并会增加延迟，也不再设置。
#   NSS 版：转发由 ECM/NSS 加速，PRIVATE.sh [3b/6] 关闭 fw4 flow offload。

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

# [1/3] dnsmasq 缓存 10000（dnsmasq 2.9x 超过 10000 会告警），1-2MB 内存换重复查询零延迟
cat > "$UCID_DIR/99-ap8220-dnsmasq" << 'DNS_EOF'
#!/bin/sh
uci -q get dhcp.@dnsmasq[0] >/dev/null 2>&1 || exit 0
uci set dhcp.@dnsmasq[0].cachesize='10000'
uci commit dhcp
exit 0
DNS_EOF
chmod +x "$UCID_DIR/99-ap8220-dnsmasq"
echo "[1/3] dnsmasq cache 10000"

# [2/3] 清理旧版本留下的自定义 RPS hotplug，交还给上游 packet steering
cat > "$UCID_DIR/99-ap8220-cleanup" << 'CL_EOF'
#!/bin/sh
rm -f /etc/hotplug.d/net/20-ap8220-rps
exit 0
CL_EOF
chmod +x "$UCID_DIR/99-ap8220-cleanup"
echo "[2/3] legacy RPS hotplug cleanup"

# [3/3] 开机强制 performance（cpufreq 包配置在 qualcommax 上不生效，实测为 schedutil）
#       调频切换会让突发流量第一拍落在低频上，固定满频换取最低延迟
INIT_DIR="$PKG_DIR/base-files/files/etc/init.d"
mkdir -p "$INIT_DIR"
cat > "$INIT_DIR/ap8220-perf" << 'PERF_EOF'
#!/bin/sh /etc/rc.common
START=99
EXTRA_COMMANDS="status"

start() {
	for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor \
		/sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do
		[ -w "$g" ] && echo performance > "$g" 2>/dev/null
	done
	sysctl -q -w net.netfilter.nf_conntrack_max=262144 2>/dev/null
	logger -t ap8220-perf "governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"
}

status() {
	cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort | uniq -c
	cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null | sort | uniq -c
	sysctl net.netfilter.nf_conntrack_max
}
PERF_EOF
chmod +x "$INIT_DIR/ap8220-perf"
cat > "$UCID_DIR/99-ap8220-perf" << 'PE_EOF'
#!/bin/sh
/etc/init.d/ap8220-perf enable
exit 0
PE_EOF
chmod +x "$UCID_DIR/99-ap8220-perf"
echo "[3/3] performance governor init script"

echo "AP8220 customizations applied!"

#---------------------------------------------------------------
# [4/4] NSS 核心频率 high（nss_freq 服务默认 mid = 748.8MHz）
#---------------------------------------------------------------
cat > "$UCID_DIR/99-ap8220-nssfreq" << 'NF_EOF'
#!/bin/sh
touch /etc/config/nss_freq
uci -q set nss_freq.settings='settings'
uci -q set nss_freq.settings.level='high'
uci -q commit nss_freq
exit 0
NF_EOF
chmod +x "$UCID_DIR/99-ap8220-nssfreq"
echo "[4/4] NSS frequency level high script written!"

#---------------------------------------------------------------
# [5/5] 频段引导：同名双频时远处手机易落到 2.4G
#       usteer 单机模式，2.4G 上能收到 5G 强于 -75 dBm 的双频设备每 10s 尝试推回 5G
#       需要 802.11k/v（wpad-openssl 完整版已满足）；包在 Config/IPQ807X-WIFI-YES.txt
#---------------------------------------------------------------
cat > "$UCID_DIR/99-ap8220-usteer" << 'US_EOF'
#!/bin/sh
for i in $(uci -q show wireless | sed -n "s/^wireless\.\([^.]*\)=wifi-iface$/\1/p"); do
	[ "$(uci -q get wireless.$i.mode)" = "ap" ] || continue
	uci set wireless.$i.ieee80211k='1'
	uci set wireless.$i.bss_transition='1'
done
uci commit wireless
[ -f /etc/config/usteer ] || exit 0
uci -q get usteer.@usteer[0] >/dev/null || uci add usteer usteer >/dev/null
uci set usteer.@usteer[0].local_mode='1'
uci set usteer.@usteer[0].band_steering_interval='10000'
uci set usteer.@usteer[0].band_steering_min_snr='-75'
uci commit usteer
/etc/init.d/usteer enable
exit 0
US_EOF
chmod +x "$UCID_DIR/99-ap8220-usteer"
echo "[5/5] usteer band steering script written!"
