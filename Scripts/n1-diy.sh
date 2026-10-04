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
for gov in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -w "$gov" ] && echo performance > "$gov" 2>/dev/null
done

# --- 2. Threaded NAPI (RPS 生效的前提, 节点存在才开) ---
if [ -w /sys/class/net/eth0/threaded ]; then
    echo 1 > /sys/class/net/eth0/threaded 2>/dev/null
fi

# --- 3. RPS: 按实际 CPU 数生成 mask (N1=4核 -> f) ---
# 等待 eth0 就绪 (uci-defaults 时网卡可能还没起来)
for i in 1 2 3 4 5; do
    [ -e /sys/class/net/eth0/queues/rx-0/rps_cpus ] && break
    sleep 2
done
nproc=$(nproc 2>/dev/null || echo 4)
# 生成全核 mask: 4核->f, 以此类推
mask=$(printf '%x' $(( (1 << nproc) - 1 )) )
for q in /sys/class/net/eth0/queues/rx-*/rps_cpus; do
    [ -w "$q" ] && echo "$mask" > "$q" 2>/dev/null
done

# --- 3b. 硬 IRQ 绑 CPU1 (dwmac 单队列单 IRQ, RPS 已摊软中断) ---
# 实测: smp_affinity 写 hex mask '2' 会 EINVAL, 用 smp_affinity_list 写 '1' 才行
eth_irq=$(grep -l 'eth0' /proc/irq/*/actions 2>/dev/null | head -1 | cut -d/ -f4)
if [ -n "$eth_irq" ] && [ -w "/proc/irq/$eth_irq/smp_affinity_list" ]; then
    echo "1" > "/proc/irq/$eth_irq/smp_affinity_list" 2>/dev/null
fi

# --- 4. Ring Buffer 拉到驱动报告的最大值 (禁止硬编码, 先读 ethtool -g) ---
if command -v ethtool >/dev/null 2>&1; then
    # 解析 "RX: 4096" 这类 Pre-set maximums 行
    max_rx=$(ethtool -g eth0 2>/dev/null | awk '/^RX:/{print $2; exit}')
    max_tx=$(ethtool -g eth0 2>/dev/null | awk '/^TX:/{print $2; exit}')
    [ -n "$max_rx" ] && [ -n "$max_tx" ] && \
        ethtool -G eth0 rx "$max_rx" tx "$max_tx" 2>/dev/null
fi

# --- 5. GRO / 校验和 offload 保持开启 (QUIC 收包依赖) ---
if command -v ethtool >/dev/null 2>&1; then
    ethtool -K eth0 gro on rx on tx on 2>/dev/null
    # 高爆发：中断合并，减少高吞吐时的中断开销
    # rx-usecs 100 = 100微秒内合并中断，tx-frames 32 = 32帧合并一次
    ethtool -C eth0 rx-usecs 100 tx-usecs 100 rx-frames 32 tx-frames 32 2>/dev/null
fi

# --- 6. 系统日志走内存, 不写 eMMC (eMMC 随机写差, 延长寿命) ---
uci -q set system.@system[0].log_buffer_size='256'
uci -q set system.@system[0].log_file='/tmp/system.log'
uci -q commit system

# --- 7. Go 运行时: 只保留 madvdontneed ---
if [ -f /etc/init.d/homeproxy ]; then
    grep -q 'GODEBUG=madvdontneed=1' /etc/init.d/homeproxy || \
        sed -i '1a export GODEBUG=madvdontneed=1' /etc/init.d/homeproxy
fi

# --- 散热：USB 自动休眠 (降温 1-3°C，S905D 80°C 降频红线) ---
for dev in /sys/bus/usb/devices/*/power/control; do
    [ -w "$dev" ] && echo auto > "$dev" 2>/dev/null
done

exit 0
EOF
chmod +x "$UCID_DIR/99-n1-perf"

#---------------------------------------------------------------
# [5/7] uci-defaults: 99-n1-kernel-perf (内核启动参数)
# 注意: flippy 的 uEnv.txt 用 APPEND= 不是 extraargs=
#---------------------------------------------------------------
echo "=== N1 [5/7]: 99-n1-kernel-perf ==="
cat > "$UCID_DIR/99-n1-kernel-perf" << 'EOF'
#!/bin/sh
# 99-n1-kernel-perf: 首次启动添加内核性能参数到 uEnv.txt
# isolcpus=3: 隔离 CPU3 给 sing-box
# rcu_nocbs=3: RCU 回调从 CPU3 卸载
# audit=0: 关闭内核审计，减开销
# 注意：flippy 的 uEnv.txt 用 APPEND= 不是 extraargs=

UENV="/boot/uEnv.txt"
PERF_ARGS="isolcpus=3 rcu_nocbs=3 audit=0"

# /boot 可能还没挂载，等待一下（U盘启动较慢，等30秒）
for i in $(seq 1 15); do
    [ -f "$UENV" ] && break
    sleep 2
done

[ -f "$UENV" ] || { logger -t n1-kernel-perf "ERROR: $UENV not found after 30s"; exit 1; }

# 已经加过了就跳过
grep -q "isolcpus=3" "$UENV" 2>/dev/null && exit 0

# 备份原文件
cp "$UENV" "$UENV.bak" 2>/dev/null

# 追加到 APPEND= 行（flippy 格式）
if grep -q "^APPEND=" "$UENV"; then
    sed -i "s/^APPEND=\(.*\)/APPEND=\1 $PERF_ARGS/" "$UENV"
else
    echo "APPEND=$PERF_ARGS" >> "$UENV"
fi

# 记录日志
logger -t n1-kernel-perf "Added kernel perf args: $PERF_ARGS (backup: $UENV.bak)"

exit 0
EOF
chmod +x "$UCID_DIR/99-n1-kernel-perf"

#---------------------------------------------------------------
# [6/7] uci-defaults: 99-n1-thresh-dtb (thresh DTB 自动切换)
#---------------------------------------------------------------
echo "=== N1 [6/7]: 99-n1-thresh-dtb ==="
cat > "$UCID_DIR/99-n1-thresh-dtb" << 'EOF'
#!/bin/sh
# 99-n1-thresh-dtb: 首次启动自动切换到 thresh 版 DTB
# thresh DTB 启用 snps,force_thresh_dma_mode，解决单臂模式下
# 交换机流控协商失败导致的单连接测速腰斩问题
# 只在 thresh 文件存在且当前不是 thresh 时才切换

THRESH_DTB="meson-gxl-s905d-phicomm-n1-thresh.dtb"
UENV="/boot/uEnv.txt"

# /boot 可能还没挂载，等待一下
for i in 1 2 3 4 5; do
    [ -f "$UENV" ] && break
    sleep 2
done

[ -f "$UENV" ] || exit 0

# thresh 文件存在吗？
THRESH_PATH=""
for d in /boot/dtb/amlogic /dtb/amlogic; do
    if [ -f "$d/$THRESH_DTB" ]; then
        THRESH_PATH="$d/$THRESH_DTB"
        break
    fi
done
[ -n "$THRESH_PATH" ] || exit 0

# 已经是 thresh 了就不动
grep -q "$THRESH_DTB" "$UENV" && exit 0

# 备份并切换
cp "$UENV" "$UENV.bak.nothresh" 2>/dev/null
sed -i "s|meson-gxl-s905d-phicomm-n1\.dtb|$THRESH_DTB|g" "$UENV"

# 记录日志
logger -t n1-thresh-dtb "Switched to $THRESH_DTB, reboot to take effect"

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
NETWORK_DIR="$PKG_DIR/base-files/files/etc/config"
mkdir -p "$NETWORK_DIR"
cat > "$NETWORK_DIR/network" << 'EOF'
config interface 'loopback'
	option device 'lo'
	option proto 'static'
	option ipaddr '127.0.0.1'
	option netmask '255.0.0.0'

config globals 'globals'
	option packet_steering '1'
	option steering_flows '256'

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
	option cachesize '1000'
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
	option ip_source 'web'
	option ip_url 'http://members.3322.org/dyndns/getip'
	option check_interval '10'
	option check_unit 'minutes'
	option force_interval '72'
	option force_unit 'hours'
	option use_https '0'
	# 3322.org 更新接口（兼容 dyndns2 协议）
	option update_url 'http://members.3322.org/dyndns/update?hostname=[DOMAIN]&myip=[IP]'
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

# --- N1 IPv6 + DTB (2026-10-04) ---
if [ -n "$WRT_DIR" ] && [ -d "$WRT_DIR/files" ]; then
  mkdir -p "$WRT_DIR/files/etc/uci-defaults"
  cat > "$WRT_DIR/files/etc/uci-defaults/99-n1-ipv6-off" <<'EOF'
#!/bin/sh
uci -q delete network.wan6 2>/dev/null
uci -q set network.wan.ipv6='0'
uci -q set network.lan.ipv6='0'
uci -q commit network
exit 0
EOF
  chmod +x "$WRT_DIR/files/etc/uci-defaults/99-n1-ipv6-off"
  cat > "$WRT_DIR/files/etc/uci-defaults/99-n1-thresh-dtb" <<'EOF'
#!/bin/sh
UENV=/boot/uEnv.txt
if [ -f "$UENV" ] && ! grep -q "thresh" "$UENV"; then
  cp -f "$UENV" "$UENV.bak.$(date +%Y%m%d)"
  sed -i "s|^FDT=.*|FDT=/dtb/amlogic/meson-gxl-s905d-phicomm-n1-thresh.dtb|" "$UENV"
fi
exit 0
EOF
  chmod +x "$WRT_DIR/files/etc/uci-defaults/99-n1-thresh-dtb"
fi
