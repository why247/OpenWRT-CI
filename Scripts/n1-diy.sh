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
# Enable software flow offloading (verified with Nikki TCP redirect + TPROXY, no proxy bypass)
uci -q set firewall.@defaults[0].flow_offloading='1'
uci -q commit firewall
exit 0
EOF
chmod +x "$UCID_DIR/99-n1-defaults"

#---------------------------------------------------------------
# [4/7] /etc/init.d/n1-perf: 每次开机生效的性能调优 (uci-defaults 只跑一次，重启即失效)
#---------------------------------------------------------------
echo "=== N1 [4/7]: n1-perf init ==="
rm -f "$UCID_DIR/99-n1-perf" "$UCID_DIR/99-n1-kernel-perf"
mkdir -p "$PKG_DIR/base-files/files/etc/init.d" "$PKG_DIR/base-files/files/usr/sbin"
cat > "$PKG_DIR/base-files/files/etc/init.d/n1-perf" << 'EOF'
#!/bin/sh /etc/rc.common
# N1 (S905D) 性能调优：每次开机执行；n1-perf status 查看
START=99
EXTRA_COMMANDS="status"

set_gov() {
	# 双路径：policy* 与 cpu*/cpufreq 都写，兼容不同内核
	for g in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor \
	         /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
		[ -w "$g" ] && echo performance > "$g" 2>/dev/null
	done
}

start() {
	set_gov
	# 等 eth0
	for i in 1 2 3 4 5 6 7 8 9 10; do [ -e /sys/class/net/eth0 ] && break; sleep 1; done
	ethtool --set-eee eth0 eee off 2>/dev/null
	# 硬中断 -> CPU1，RPS -> CPU0/2/3 (掩码 d)，互不抢核
	irq=$(awk -F: '/eth0/{gsub(/ /,"",$1);print $1;exit}' /proc/interrupts)
	[ -n "$irq" ] && echo 1 > /proc/irq/$irq/smp_affinity_list 2>/dev/null
	for q in /sys/class/net/eth0/queues/rx-*/rps_cpus; do echo d > "$q" 2>/dev/null; done
	for q in /sys/class/net/eth0/queues/rx-*/rps_flow_cnt; do echo 4096 > "$q" 2>/dev/null; done
	echo 16384 > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null
	# Ring 拉满；中断合并 30us 兼顾延迟与突发
	mrx=$(ethtool -g eth0 2>/dev/null | awk '/^RX:/{print $2;exit}')
	mtx=$(ethtool -g eth0 2>/dev/null | awk '/^TX:/{print $2;exit}')
	[ -n "$mrx" ] && [ -n "$mtx" ] && ethtool -G eth0 rx "$mrx" tx "$mtx" 2>/dev/null
	ethtool -K eth0 gro on gso on tso on rx on tx on sg on 2>/dev/null
	ethtool -C eth0 rx-usecs 30 2>/dev/null  # stmmac 不支持 rx-frames，合写会整条失败
	echo 2000 > /proc/sys/net/core/netdev_max_backlog
	echo 600 > /proc/sys/net/core/netdev_budget
	# 路由转发用 fq_codel 压排队延迟；BBR 自带 pacing，不依赖 fq
	sysctl -qw net.core.default_qdisc=fq_codel net.ipv4.tcp_congestion_control=bbr 2>/dev/null
	tc qdisc replace dev eth0 root fq_codel 2>/dev/null
	# quic-go/HY2 需要大 UDP 缓冲 (官方建议 >=7.5MB)，否则突发丢包
	sysctl -qw net.core.rmem_max=16777216 net.core.wmem_max=16777216 \
		net.core.rmem_default=1048576 net.core.wmem_default=1048576 \
		net.ipv4.udp_rmem_min=16384 net.ipv4.udp_wmem_min=16384 2>/dev/null
	# 连接跟踪：2GB 内存放宽，缩短 UDP 超时
	sysctl -qw net.netfilter.nf_conntrack_max=262144 \
		net.netfilter.nf_conntrack_udp_timeout=30 \
		net.netfilter.nf_conntrack_udp_timeout_stream=120 \
		net.netfilter.nf_conntrack_tcp_timeout_established=7200 2>/dev/null
	# 关 CPU 深度空闲状态：省掉唤醒延迟（换几度温度）
	for st in /sys/devices/system/cpu/cpu*/cpuidle/state[1-9]/disable; do
		[ -w "$st" ] && echo 1 > "$st"
	done
	for dev in /sys/bus/usb/devices/*/power/control; do [ -w "$dev" ] && echo auto > "$dev"; done
	logger -t n1-perf "applied (irq=$irq)"
}

status() {
	echo "governor: $(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null) $(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq 2>/dev/null)kHz"
	echo "link: $(ethtool eth0 2>/dev/null | awk -F': ' '/Speed|Duplex/{printf "%s ",$2}')"
	echo "eee: $(ethtool --show-eee eth0 2>/dev/null | grep -m1 -i 'EEE status')"
	echo "dtb: $(grep -h -o 'meson-gxl-s905d-phicomm-n1[^ ]*\.dtb' /boot/uEnv.txt 2>/dev/null)"
	echo "rps: $(cat /sys/class/net/eth0/queues/rx-0/rps_cpus 2>/dev/null)"
	echo "temp: $(( $(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0) / 1000 ))C"
	nft list flowtables 2>/dev/null | grep -q flowtable && echo "flow offload: on" || echo "flow offload: off"
}
EOF
chmod +x "$PKG_DIR/base-files/files/etc/init.d/n1-perf"

cat > "$UCID_DIR/99-n1-perf" << 'EOF'
#!/bin/sh
/etc/init.d/n1-perf enable
# 晶晨宝盒 CPU 设置也写成 performance（双路径之二，宝盒的 cpufreq 服务会读它）
uci -q set amlogic.armcpu.governor0='performance'
uci -q set amlogic.armcpu.maxfreq0='1512000'
uci -q set amlogic.armcpu.minfreq0='1512000'
# 晶晨宝盒在线升级：固件从本仓库 N1 Release 取，内核从 ophub flippy 6.18 取
uci -q set amlogic.config.amlogic_firmware_repo='https://github.com/why247/OpenWRT-CI'
uci -q set amlogic.config.amlogic_firmware_tag='ARMSR-N1'
uci -q set amlogic.config.amlogic_firmware_suffix='.img.gz'
uci -q set amlogic.config.amlogic_kernel_path='https://github.com/ophub/kernel'
uci -q set amlogic.config.amlogic_kernel_tags='kernel_flippy'
uci -q set amlogic.config.amlogic_kernel_branch='6.18'
uci -q commit amlogic
# 日志进内存，保护 eMMC
uci -q set system.@system[0].log_buffer_size='256'
uci -q commit system
exit 0
EOF
chmod +x "$UCID_DIR/99-n1-perf"

# PPPoE 重拨/接口重载时 netifd 会把 RPS 清零：iface ifup 时重新应用 n1-perf
mkdir -p "$PKG_DIR/base-files/files/etc/hotplug.d/iface"
cat > "$PKG_DIR/base-files/files/etc/hotplug.d/iface/99-n1-perf" << 'EOF'
#!/bin/sh
[ "$ACTION" = ifup ] || exit 0
case "$INTERFACE" in wan|lan) ;; *) exit 0 ;; esac
( sleep 3; /etc/init.d/n1-perf start ) >/dev/null 2>&1 &
EOF

#---------------------------------------------------------------
# [5/7] 内核参数: 只加 audit=0（去掉 isolcpus=3：没绑核时纯属浪费一个核）
#---------------------------------------------------------------
echo "=== N1 [5/7]: kernel args ==="
#---------------------------------------------------------------
# [6/7] uci-defaults: 99-n1-thresh-dtb (thresh DTB 自动切换 + 备份 uEnv.txt)
#---------------------------------------------------------------
echo "=== N1 [6/7]: 99-n1-thresh-dtb ==="
cat > "$UCID_DIR/99-n1-thresh-dtb" << 'EOF'
#!/bin/sh
# thresh DTB 启用 snps,force_thresh_dma_mode，解决 N1 单臂单连接测速腰斩
UENV=/boot/uEnv.txt
T=meson-gxl-s905d-phicomm-n1-thresh.dtb
for i in $(seq 1 15); do [ -f "$UENV" ] && break; sleep 2; done
[ -f "$UENV" ] || exit 0
if ! grep -q "$T" "$UENV"; then
	F=""
	for d in /boot/dtb/amlogic /dtb/amlogic; do [ -f "$d/$T" ] && F=1; done
	if [ -n "$F" ]; then
		cp -f "$UENV" "$UENV.bak.nothresh"
		sed -i "s|meson-gxl-s905d-phicomm-n1\.dtb|$T|g" "$UENV"
		grep -q "$T" "$UENV" || sed -i "s|^FDT=.*|FDT=/dtb/amlogic/$T|" "$UENV"
		logger -t n1-thresh-dtb "switched to $T (backup $UENV.bak.nothresh), reboot to apply"
	else
		logger -t n1-thresh-dtb "$T not found, skipped"
	fi
fi
# audit=0 追加到 APPEND 行；清除旧版的 isolcpus/rcu_nocbs
sed -i 's/ isolcpus=3//; s/ rcu_nocbs=3//' "$UENV"
grep -q 'audit=0' "$UENV" || sed -i 's/^APPEND=\(.*\)/APPEND=\1 audit=0/' "$UENV"
exit 0
EOF
chmod +x "$UCID_DIR/99-n1-thresh-dtb"

#---------------------------------------------------------------
# [7/7] hotplug: 10-disable-eee (RTL8211F EEE 硬件 bug)
#---------------------------------------------------------------
echo "=== N1 [7/7]: 10-disable-eee ==="
cat > "$HOTPLUG_DIR/10-disable-eee" << 'EOF'
#!/bin/sh
# Disable EEE (Energy Efficient Ethernet) on RTL8211F.
#
# The RTL8211F PHY has a hardware bug where EEE causes the link to drop
# ~20 seconds after boot on Amlogic S905D (Phicomm N1).
#
# This hotplug script runs when the kernel registers eth0, early enough
# to beat the link drop.
[ "$INTERFACE" = "eth0" ] || exit 0
[ "$ACTION" = "add" ] || exit 0
ethtool --set-eee eth0 eee off 2>/dev/null
EOF
chmod +x "$HOTPLUG_DIR/10-disable-eee"

#---------------------------------------------------------------
# 网络配置: /etc/config/network (PPPoE + IPv6)
# 注意: 通过 base-files 覆盖默认 network 配置
#---------------------------------------------------------------
echo "=== N1: network config ==="
NETWORK_DIR="$WRT_DIR/files/etc/config"
mkdir -p "$NETWORK_DIR"
cat > "$NETWORK_DIR/network" << 'EOF'
config interface 'loopback'
	option device 'lo'
	option proto 'static'
	option ipaddr '127.0.0.1'
	option netmask '255.0.0.0'

config globals 'globals'
	option packet_steering '0'

config device
	option name 'eth0'
	option mtu '1500'

config interface 'lan'
	option device 'eth0'
	option proto 'static'
	option ipaddr '192.168.1.99'
	option netmask '255.255.255.0'
	option ip6assign '60'

# 主路由拨号：请在 LuCI（网络 → 接口 → WAN → 编辑）里填写宽带账号和密码
config interface 'wan'
	option device 'eth0'
	option proto 'pppoe'
	option username ''
	option password ''

config interface 'wan6'
	option device '@wan'
	option proto 'dhcpv6'
EOF

#---------------------------------------------------------------
# DHCP 配置: /etc/config/dhcp
#---------------------------------------------------------------
echo "=== N1: dhcp config ==="
cat > "$NETWORK_DIR/dhcp" << 'EOF'
config dnsmasq
	option domainneeded '1'
	option localise_queries '1'
	option rebind_protection '0'
	# rebind 保护会误杀 sing-box Fake-IP v6 (fc00::/18 ⊂ ULA fc00::/7)，
	# 上游是可信的本地 sing-box，此处不适用
	option rebind_localhost '1'
	option local '/lan/'
	option domain 'lan'
	option expandhosts '1'
	option min_cache_ttl '3600'
	option use_stale_cache '3600'
	option cachesize '10000'
	option nonegcache '1'
	option authoritative '1'
	option readethers '1'
	option leasefile '/tmp/dhcp.leases'
	option resolvfile '/tmp/resolv.conf.d/resolv.conf.auto'
	option localservice '1'
	option ednspacket_max '1232'

config dhcp 'lan'
	option interface 'lan'
	option start '100'
	option limit '150'
	option leasetime '12h'
	option dhcpv4 'server'
	option ra 'server'
	option dhcpv6 'server'

config dhcp 'wan'
	option interface 'wan'
	option ignore '1'

config odhcpd 'odhcpd'
	option maindhcp '0'
	option leasefile '/tmp/hosts/odhcpd'
	option leasetrigger '/usr/sbin/odhcpd-update'
	option loglevel '4'
EOF

#---------------------------------------------------------------
# DDNS 配置: /etc/config/ddns (3322.org 模板)
#---------------------------------------------------------------
echo "=== N1: ddns config ==="
cat > "$NETWORK_DIR/ddns" << 'EOF'
config ddns 'global'
	option ddns_dateformat '%F %R'
	option ddns_loglines '250'
	option ddns_rundir '/var/run/ddns'
	option ddns_logdir '/var/log/ddns'

# 3322.org 动态域名模板
# 使用方法：在 LuCI（服务 → 动态 DNS）中填写以下字段后启用，
# 或直接编辑本文件后执行：/etc/init.d/ddns restart
config service 'my3322'
	option enabled '0'
	option service_name '3322.org'
	option domain 'yourname.3322.org'
	option username 'your-3322-username'
	option password 'your-3322-password'
	option interface 'wan'
	option ip_source 'network'
	option ip_network 'wan'
	option use_ipv6 '0'
	option check_interval '5'
	option check_unit 'minutes'
	option force_interval '72'
	option force_unit 'hours'
	option use_https '0'
EOF

#---------------------------------------------------------------
# 预下载 cn_ip.list (150K, 打进固件)
#---------------------------------------------------------------
echo "=== N1: pre-seed cn_ip.list ==="
CN_IP_DIR="$WRT_DIR/package/luci-app-homeproxy/root/etc/homeproxy/resources"
if [ -d "$WRT_DIR/package/luci-app-homeproxy" ]; then
	mkdir -p "$CN_IP_DIR"
	if curl -fsSL --retry 3 --max-time 60 \
		"https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@meta/geo/geoip/cn.list" \
		-o "$CN_IP_DIR/cn_ip.list.tmp"; then
		if [ "$(wc -l < "$CN_IP_DIR/cn_ip.list.tmp")" -ge 8000 ]; then
			mv "$CN_IP_DIR/cn_ip.list.tmp" "$CN_IP_DIR/cn_ip.list"
			date -u +%Y-%m-%d > "$CN_IP_DIR/cn_ip.ver"
			echo "Pre-seeded fresh cn_ip.list ($(wc -l < "$CN_IP_DIR/cn_ip.list") lines)"
		else
			echo "WARNING: downloaded cn_ip.list too small, keeping bundled copy" >&2
			rm -f "$CN_IP_DIR/cn_ip.list.tmp"
		fi
	else
		echo "WARNING: cn_ip.list download failed, keeping bundled copy" >&2
		rm -f "$CN_IP_DIR/cn_ip.list.tmp"
	fi
else
	echo "[WARN] luci-app-homeproxy not found, skipping cn_ip.list pre-seed"
fi

echo "=============================================="
echo "N1 customizations applied!"
echo "=============================================="

