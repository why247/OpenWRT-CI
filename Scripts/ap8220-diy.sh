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
# 去掉 ImmortalWrt 默认的 min_cache_ttl/use_stale_cache 3600：会把 CDN 短 TTL 硬缓存 1 小时，B站晚高峰卡在旧节点（2026-10-13 实测）
uci -q delete dhcp.@dnsmasq[0].min_cache_ttl
uci -q delete dhcp.@dnsmasq[0].use_stale_cache
# EDNS 包长 512：1232 时 sing-box 带 authority/additional 大包回，dnsmasq 转给非 EDNS 客户端超 512 置 TC，
# 不重试 TCP 的客户端（电视/IoT/部分 App）首查为空；512 后冷查询 20/20 一次成功（2026-10-13 实测）
uci set dhcp.@dnsmasq[0].ednspacket_max='512'
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
# [5/5] Wi-Fi 漫游/频段引导：802.11k/v/WNM + usteer
#    手机贴在 2.4G（-69dBm、6~12Mbps）导致 B站拖动卡顿，开启后被引导回 5G（2026-11-14 实测）。
#    两个频段 SSID 同名（jy）才能引导；usteer 包由 Config/IPQ807X-WIFI-YES.txt 选中。
#    文件名 99zz 保证排在 99z-custom-wireless 之后执行。
#    回滚：/etc/init.d/usteer disable；删掉下面 4 个 wireless 选项；wifi reload
#---------------------------------------------------------------
cat > "$UCID_DIR/99zz-ap8220-roam" << 'RO_EOF'
#!/bin/sh
[ -f /etc/config/wireless ] || exit 0
for s in $(uci show wireless | sed -n "s/^wireless\.\([^.]*\)=wifi-iface$/\1/p"); do
	[ "$(uci -q get wireless.$s.mode)" = ap ] || continue
	uci set wireless.$s.ieee80211k='1'
	uci set wireless.$s.bss_transition='1'
	uci set wireless.$s.wnm_sleep_mode='1'
	uci set wireless.$s.time_advertisement='2'
done
uci commit wireless
if [ -f /etc/config/usteer ]; then
	uci -q get usteer.@usteer[0] >/dev/null || uci add usteer usteer >/dev/null
	uci set usteer.@usteer[0].band_steering_threshold='5'
	uci set usteer.@usteer[0].band_steering_interval='30000'
	uci set usteer.@usteer[0].syslog='1'
	uci commit usteer
	/etc/init.d/usteer enable
fi
exit 0
RO_EOF
chmod +x "$UCID_DIR/99zz-ap8220-roam"
echo "[5/5] Wi-Fi 802.11k/v + usteer band steering written!"

#---------------------------------------------------------------
# [C1] B站 PCDN/STUN 快速拒绝 (同步自 N1 2026-11-23; LAN=br-lan)
#---------------------------------------------------------------
mkdir -p "$PKG_DIR/base-files/files/etc/nftables.d"
cat > "$PKG_DIR/base-files/files/etc/nftables.d/20-bili-pcdn-reject.nft" << 'NFT_EOF'
chain bili_pcdn_reject {
    type filter hook forward priority -1; policy accept;
    iifname "br-lan" oifname != "br-lan" meta l4proto tcp tcp flags & (syn|ack) == syn tcp dport { 4480, 8000, 23861, 33861, 43861, 53861, 63861 } counter reject with tcp reset comment "bili-pcdn-tcp"
    iifname "br-lan" oifname != "br-lan" meta l4proto udp udp dport 3478 counter reject comment "bili-stun"
    iifname "br-lan" oifname != "br-lan" ip daddr 10.0.0.0/8 meta l4proto udp counter reject comment "bili-p2p-priv"
}
NFT_EOF

# [C3] HomeProxy 默认主节点 = why hysteria2 (存在才改)
cat > "$UCID_DIR/99-homeproxy-main" << 'HPM_EOF'
#!/bin/sh
s=$(uci -q -X show homeproxy | sed -n "s/^homeproxy\.\([^.]*\)\.label='why hysteria2'$/\1/p" | head -n1)
if [ -n "$s" ]; then
	uci -q set homeproxy.config.main_node="$s"
	uci -q commit homeproxy
	logger -t homeproxy-main "main_node -> $s (why hysteria2)"
fi
exit 0
HPM_EOF
chmod +x "$UCID_DIR/99-homeproxy-main"
echo "[6/6] bili PCDN reject + HomeProxy main node written!"
