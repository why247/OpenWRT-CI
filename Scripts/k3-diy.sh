#!/bin/bash
# K3 DIY script for OpenWRT-CI
# 由 PRIVATE.sh 末尾调用，或在 K3-ALL.yml 工作流中单独调用
# 用法: bash $GITHUB_WORKSPACE/Scripts/k3-diy.sh
# 注意: 必须在 feeds update/install 之后、make defconfig 之前调用

set -e

echo " "
echo "=============================================="
echo "Applying K3 customizations..."
echo "=============================================="

#---------------------------------------------------------------
# 定位 wrt 源码树 (照抄 PRIVATE.sh 的探测逻辑)
#---------------------------------------------------------------
if [ -d "./package/base-files" ]; then
	WRT_DIR="$(pwd)"
elif [ -d "./base-files" ]; then
	WRT_DIR="$(cd .. && pwd)"
else
	echo "[ERROR] WRT source tree not found, K3 customizations skipped!"
	exit 0
fi

PKG_DIR="$WRT_DIR/package"
echo "WRT source tree: $WRT_DIR"

# 只在 bcm53xx/K3 构建时执行
if [ -n "$WRT_TARGET" ] && [[ "${WRT_TARGET,,}" != *"bcm53xx"* ]]; then
	echo "Not bcm53xx target (WRT_TARGET=$WRT_TARGET), skipping K3 customizations."
	exit 0
fi

#---------------------------------------------------------------
# [1/6] WiFi 固件: asus-dhd24 (951031 字节校验)
#---------------------------------------------------------------
echo "=== K3 [1/6]: WiFi firmware (asus-dhd24) ==="
FW_DIR="$WRT_DIR/package/firmware/brcmfmac4366c0-firmware-k3/files"
if [ ! -d "$FW_DIR" ]; then
	echo "[WARN] $FW_DIR not found, skipping WiFi firmware replacement"
else
	wget -nv https://github.com/Hill-98/phicommk3-firmware/raw/master/brcmfmac4366c-pcie.bin.asus-dhd24 -O /tmp/brcmfmac4366c-pcie.bin
	SIZE=$(stat -c%s /tmp/brcmfmac4366c-pcie.bin)
	if [ "$SIZE" != "951031" ]; then
		echo "[ERROR] WiFi firmware size mismatch ($SIZE != 951031), aborting!"
		exit 1
	fi
	SHA=$(sha256sum /tmp/brcmfmac4366c-pcie.bin | cut -d' ' -f1)
	if [ "$SHA" != "3da2964bf33b22d443097ef642df615246adb50726b0d030eb9990a6e467c8cb" ]; then
		echo "[ERROR] WiFi firmware SHA256 mismatch ($SHA), aborting!"
		exit 1
	fi
	cp /tmp/brcmfmac4366c-pcie.bin "$FW_DIR/brcmfmac4366c-pcie.bin"
	echo "WiFi firmware replaced OK (size+sha256 verified)"
fi

#---------------------------------------------------------------
# [2/6] 屏幕驱动: yangxu52 (替换官方版 + 修 DEPENDS 新格式)
#---------------------------------------------------------------
echo "=== K3 [2/6]: Screen driver (yangxu52) ==="
rm -rf "$WRT_DIR/feeds/packages/utils/phicomm-k3screenctrl" "$WRT_DIR/package/feeds/packages/phicomm-k3screenctrl" 2>/dev/null || true
rm -rf "$WRT_DIR/feeds/luci/applications/luci-app-k3screenctrl" 2>/dev/null || true
mkdir -p "$PKG_DIR/k3custom"
if [ ! -d "$PKG_DIR/k3custom/k3screenctrl" ]; then
	git clone --depth 1 https://github.com/yangxu52/k3screenctrl_build.git "$PKG_DIR/k3custom/k3screenctrl"
fi
if [ ! -d "$PKG_DIR/k3custom/luci-app-k3screenctrl" ]; then
	git clone --depth 1 https://github.com/yangxu52/luci-app-k3screenctrl.git "$PKG_DIR/k3custom/luci-app-k3screenctrl"
fi
# 注意: yangxu52 的 DEPENDS 用的是 @(TARGET_bcm53xx_generic_DEVICE_phicomm_k3||...)
# 这是当前 OpenWrt 正确的设备级依赖格式，无需修改
echo "Screen driver replaced OK"

#---------------------------------------------------------------
# [3/6] hy2/sysctl: 写入 package/base-files/files (CI 正确机制)
# 注意: 仓库根的 files/ 不会被 WRT-CORE 复制，必须走这里
#---------------------------------------------------------------
echo "=== K3 [3/6]: hy2 sysctl ==="
SYSCTL_DIR="$PKG_DIR/base-files/files/etc/sysctl.d"
mkdir -p "$SYSCTL_DIR"
cat > "$SYSCTL_DIR/99-hy2.conf" << 'EOF'
# K3 (BCM4709) Hysteria2/QUIC 系统调优
# UDP 缓冲: QUIC/hy2 必备，内核默认 212992 太小会丢包
net.core.rmem_max = 8388608
net.core.wmem_max = 8388608
# 网卡收包队列
net.core.netdev_max_backlog = 5000
# BBR + fq (TCP 出站加速，fq pacing 平滑 hy2 UDP 突发)
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
# TCP Fast Open
net.ipv4.tcp_fastopen = 3
EOF
echo "sysctl written!"

#---------------------------------------------------------------
# [4/6] hy2/RPS: uci-defaults 写入 rc.local (幂等)
#---------------------------------------------------------------
echo "=== K3 [4/6]: hy2 RPS tune ==="
UCID_DIR="$PKG_DIR/base-files/files/etc/uci-defaults"
mkdir -p "$UCID_DIR"
cat > "$UCID_DIR/99-hy2-tune" << 'EOF'
#!/bin/sh
# K3 hy2 调优: governor + RPS，首次开机执行后自删除
[ -f /etc/rc.local ] || { echo -e "#!/bin/sh\nexit 0" > /etc/rc.local; }
if ! grep -q "hy2-tune: K3 governor+RPS" /etc/rc.local 2>/dev/null; then
	sed -i '/^exit 0$/d' /etc/rc.local
	cat >> /etc/rc.local <<'RCEOF'
# --- hy2-tune: K3 governor+RPS ---
for p in /sys/devices/system/cpu/cpufreq/policy*; do
	[ -w "$p/scaling_governor" ] && echo performance > "$p/scaling_governor" 2>/dev/null
done
for q in /sys/class/net/*/queues/rx-*/rps_cpus; do
	echo 3 > "$q" 2>/dev/null
done
# --- hy2-tune end ---
RCEOF
	echo "exit 0" >> /etc/rc.local
fi
for p in /sys/devices/system/cpu/cpufreq/policy*; do
	[ -w "$p/scaling_governor" ] && echo performance > "$p/scaling_governor" 2>/dev/null
done
for q in /sys/class/net/*/queues/rx-*/rps_cpus; do
	echo 3 > "$q" 2>/dev/null
done
exit 0
EOF
chmod +x "$UCID_DIR/99-hy2-tune"
echo "uci-defaults written!"

#---------------------------------------------------------------
# [5/6] K3 无线覆盖: ch149 VHT80 / ch6 HT20 / CN
# PRIVATE.sh 的 [5/6] 设的是 ch44/ch9 + US，K3 需要覆盖
# 文件名 99z-custom-wireless-k3 确保在 99z-custom-wireless 之后执行
#---------------------------------------------------------------
echo "=== K3 [5/6]: K3 wireless override ==="
cat > "$UCID_DIR/99z-custom-wireless-k3" << 'WEOF'
#!/bin/sh
# K3 无线覆盖: 5G ch149 VHT80 / 2.4G ch6 HT20 / 国家 CN
# 在 PRIVATE.sh 的 99z-custom-wireless 之后执行，按 band 覆盖
. /lib/functions.sh
[ -f /etc/config/wireless ] || exit 0
k3_wifi() {
	local device="$1"
	local band
	config_get band "$device" band
	case "$band" in
		2g)
			uci set wireless.$device.country='CN'
			uci set wireless.$device.channel='6'
			uci set wireless.$device.htmode='HT20'
			uci set wireless.$device.txpower='20'
			;;
		5g)
			uci set wireless.$device.country='CN'
			uci set wireless.$device.channel='149'
			uci set wireless.$device.htmode='VHT80'
			uci set wireless.$device.txpower='23'
			;;
	esac
}
config_load wireless
config_foreach k3_wifi wifi-device
uci commit wireless
exit 0
WEOF
chmod +x "$UCID_DIR/99z-custom-wireless-k3"
echo "K3 wireless override written!"

#---------------------------------------------------------------
# [6/6] sing-box: 1.14.2 + GOARM=5 (BCM4709 无 VFP/NEON，默认硬浮点会 illegal instruction)
#---------------------------------------------------------------
echo "=== K3 [6/6]: sing-box 1.14.2 GOARM=5 ==="
SB_MK="$PKG_DIR/packages/sing-box/Makefile"
if [ -f "$SB_MK" ]; then
	# 1.14.2
	sed -i 's/PKG_UPSTREAM_VERSION:=1.15.0-alpha.9/PKG_UPSTREAM_VERSION:=1.14.2/' "$SB_MK"
	sed -i 's/PKG_VERSION:=1.15.0_alpha9/PKG_VERSION:=1.14.2/' "$SB_MK"
	sed -i 's/PKG_HASH:=f8c261a56e82ade0149d73629f67ca0b38ed8386e6fadfd3f3bff5ef8f9bcd88/PKG_HASH:=67dd8f8c37ecaaadcfcafad1f0827eed4b034c963b86fd3aa5c0d7a36876845d/' "$SB_MK"
	# GO_ARM=5 (soft float, 不是 GOARM!)
	# golang-values.mk 里: GOARM="$(GO_ARM)"，且 GO_ARM 由 CONFIG_CPU_TYPE 的 FPU 决定
	# bcm53xx 的 Cortex-A9 默认会得 GO_ARM=7 (hard float)，在 K3 上 illegal instruction
	# 追加到文件末尾，覆盖 golang-values.mk 里算出来的值
	if ! grep -q "^GO_ARM:=5" "$SB_MK"; then
		echo "" >> "$SB_MK"
		echo "# K3: force soft float (BCM4709 has no VFP/NEON)" >> "$SB_MK"
		echo "GO_ARM:=5" >> "$SB_MK"
		echo "sing-box patched: 1.14.2 + GO_ARM=5"
	else
		echo "sing-box GO_ARM already set"
	fi
	# 验证
	grep -q "PKG_UPSTREAM_VERSION:=1.14.2" "$SB_MK" && grep -q "^GO_ARM:=5" "$SB_MK" \
		&& echo "sing-box patch verified OK" \
		|| { echo "[ERROR] sing-box patch failed!"; exit 1; }
else
	echo "[WARN] $SB_MK not found, skipping sing-box patch"
fi

echo "=============================================="
echo "K3 customizations applied!"
echo "=============================================="
