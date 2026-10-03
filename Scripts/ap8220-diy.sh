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

UCID_DIR="$PKG_DIR/base-files/files/etc/uci-defaults"
mkdir -p "$UCID_DIR"

#---------------------------------------------------------------
# [1/4] RPS: 四核全开 (mask f)，把收包软中断摊到 4 核
#   EDMA 用 threaded NAPI，RX poll 已在 CPU1；RPS 把协议栈上半部再摊开。
#   与官方 smp_affinity（管硬中断）正交，不冲突。不要装 irqbalance。
#---------------------------------------------------------------
echo "=== AP8220 [1/4]: RPS tune (mask f for quad-core) ==="
cat > "$UCID_DIR/99-ap8220-rps" << 'RPS_EOF'
#!/bin/sh
# AP8220 (IPQ8071A, 4x Cortex-A53) RPS 调优
# 首次开机执行后自删除；mask f = CPU0+1+2+3 全开
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
echo "RPS uci-defaults written!"

#---------------------------------------------------------------
# [2/4] XPS: 发送端包转向，把 WAN 口各 TX 队列绑定到不同 CPU
#   RPS 管收包，XPS 管发包。HY2 在千兆下是 UDP 发送大户，减少发包锁竞争。
#---------------------------------------------------------------
echo "=== AP8220 [2/4]: XPS tune ==="
cat > "$UCID_DIR/99-ap8220-xps" << 'XPS_EOF'
#!/bin/sh
# AP8220 XPS: TX 队列 -> CPU 一一对应，减少发包锁竞争
# 首次开机执行后自删除
for iface in eth0 eth1; do
	i=0
	for q in /sys/class/net/$iface/queues/tx-*/xps_cpus 2>/dev/null; do
		[ -w "$q" ] || continue
		# CPU mask: 1<<i (tx-0->CPU0, tx-1->CPU1, ...)
		mask=$(printf '%x' $((1 << i)))
		echo "$mask" > "$q" 2>/dev/null
		i=$((i + 1))
		[ $i -ge 4 ] && break
	done
done
# Threaded NAPI: 让 NAPI 收包跑在独立内核线程，减少 softirq 抖动
for t in /sys/class/net/eth*/threaded 2>/dev/null; do
	[ -w "$t" ] && echo 1 > "$t" 2>/dev/null
done
# WAN 口 txqueuelen 1000->5000，突发时少丢包
for iface in eth0; do
	ip link set "$iface" txqueuelen 5000 2>/dev/null
done
exit 0
XPS_EOF
chmod +x "$UCID_DIR/99-ap8220-xps"
echo "XPS uci-defaults written!"

#---------------------------------------------------------------
# [3/4] dnsmasq 缓存加大 (15000)，重复查询延迟下降
#---------------------------------------------------------------
echo "=== AP8220 [3/4]: dnsmasq cache ==="
mkdir -p "$PKG_DIR/base-files/files/etc"
# 通过 uci-defaults 设置，避免覆盖用户现有配置
cat > "$UCID_DIR/99-ap8220-dnsmasq" << 'DNS_EOF'
#!/bin/sh
# dnsmasq 缓存 15000，1-2MB 内存换查询延迟下降
uci -q get dhcp.@dnsmasq[0] >/dev/null 2>&1 || exit 0
uci set dhcp.@dnsmasq[0].cachesize='15000'
uci commit dhcp
exit 0
DNS_EOF
chmod +x "$UCID_DIR/99-ap8220-dnsmasq"
echo "dnsmasq uci-defaults written!"

#---------------------------------------------------------------
# [4/4] 确认：NSS 关闭，irqbalance 不装，flow_offloading 关
#   （这些由 PRIVATE.sh 和 Config 控制，这里只做二次确认日志）
#---------------------------------------------------------------
echo "=== AP8220 [4/4]: sanity check ==="
echo "NSS: off by default (not in ImmortalWrt)"
echo "irqbalance: NOT installed (conflicts with smp_affinity)"
echo "flow_offloading: disabled by PRIVATE.sh [3b/6]"
echo ""
echo "AP8220 customizations applied!"
