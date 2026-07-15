#!/bin/bash
# 私有定制脚本，由 Packages.sh 末尾 source 执行，CWD 与 Packages.sh 相同（package/ 目录）
# 好处：本文件上游仓库里不存在，Sync fork 永远不会因为它冲突

echo " "
echo "Applying private customizations..."

#---------------------------------------------------------------
# 0) 修正 collections 内被写死的主题依赖（例如 luci-light 硬依赖 +luci-theme-aurora）
#    不管当前写死的是哪个主题，统一纠正为 +luci-theme-bootstrap
#    必须在下面删除主题源码之前执行，否则依赖找不到包会导致 defconfig/编译报错：
#    "luci-theme-aurora (no such package): required by: luci-light...[luci-theme-aurora]"
#---------------------------------------------------------------
COLLECTIONS_FILES=$(find ../feeds/luci/collections/ -type f -name "Makefile" 2>/dev/null)
if [ -n "$COLLECTIONS_FILES" ]; then
	sed -i -E "s/\+luci-theme-[A-Za-z0-9_-]+/+luci-theme-bootstrap/g" $COLLECTIONS_FILES
	echo "collections default theme dependency normalized to bootstrap!"
else
	echo "Warning: feeds/luci/collections not found yet, theme dependency not normalized!"
fi

#---------------------------------------------------------------
# 1) 删除 HomeProxy 以及除 Bootstrap 外的其它主题源码
#    （对应目录名取自各 UPDATE_PACKAGE 克隆下来的仓库名，而非第一个参数）
#    这样 Handles.sh 里 argon/aurora 的 [ -d ... ] 判断会自然为假，无需改 Handles.sh
#---------------------------------------------------------------
rm -rf ./luci-theme-argon ./luci-theme-aurora ./luci-app-aurora-config \
       ./luci-theme-kucat ./luci-app-kucat-config ./luci-theme-noobwrt \
       ./luci-theme-shadcn ./luci-theme-fluent ./homeproxy
echo "unwanted themes and homeproxy source removed!"

#---------------------------------------------------------------
# 2) 写入 cpufreq 默认参数
#    先尝试定位已有的 cpufreq UCI 配置文件；找不到再兜底写入 base-files
#---------------------------------------------------------------
CPUFREQ_FILE=$(find . ../feeds -type f -wholename "*/etc/config/cpufreq" 2>/dev/null | head -n1)
[ -z "$CPUFREQ_FILE" ] && CPUFREQ_FILE="./base-files/files/etc/config/cpufreq"
mkdir -p "$(dirname "$CPUFREQ_FILE")"
cat > "$CPUFREQ_FILE" << 'EOF'
config settings 'cpufreq'
	option governor0 'performance'
	option minfreq0 '1382400'
	option maxfreq0 '1382400'

config settings 'global'
	option set '1'
EOF
echo "cpufreq default settings written to $CPUFREQ_FILE"

#---------------------------------------------------------------
# 3) 写入 sysctl.conf 网络缓冲区参数
#---------------------------------------------------------------
mkdir -p ./base-files/files/etc
cat > ./base-files/files/etc/sysctl.conf << 'EOF'
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 4194304
net.core.wmem_default = 4194304
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
EOF
echo "sysctl.conf written!"

#---------------------------------------------------------------
# 4) 写入无线默认国家代码/信道/频宽/功率
#    以 uci-defaults 形式随固件写入，首次开机执行一次；
#    按 band（2g/5g）匹配，不依赖 radio0/radio1 的顺序，
#    对多设备（MULTI_PROFILE）固件包同样安全
#---------------------------------------------------------------
mkdir -p ./base-files/files/etc/uci-defaults
cat > ./base-files/files/etc/uci-defaults/99-custom-wireless << 'WEOF'
#!/bin/sh
. /lib/functions.sh

[ -f /etc/config/wireless ] || exit 0

configure_wifi() {
	local device="$1"
	local band

	config_get band "$device" band

	case "$band" in
	2g)
		uci set wireless.$device.country='US'
		uci set wireless.$device.channel='9'
		uci set wireless.$device.htmode='HE20'
		uci set wireless.$device.txpower='24'
		;;
	5g)
		uci set wireless.$device.country='US'
		uci set wireless.$device.channel='44'
		uci set wireless.$device.htmode='HE160'
		uci set wireless.$device.txpower='25'
		;;
	esac
}

config_load wireless
config_foreach configure_wifi wifi-device
uci commit wireless

exit 0
WEOF
chmod +x ./base-files/files/etc/uci-defaults/99-custom-wireless
echo "wireless country/channel/power defaults written!"
