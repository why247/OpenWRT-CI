#!/bin/bash
# 私有定制脚本，由 Packages.sh 末尾 source 执行，CWD 与 Packages.sh 相同（package/ 目录）
# 好处：本文件上游仓库里不存在，Sync fork 永远不会因为它冲突

echo " "
echo "=========================================================="
echo "           Applying Private Customizations..."
echo "=========================================================="

#---------------------------------------------------------------
# 1) 拉取 Nikki 源码 (核心修复：自适应目录结构 + 分支回退)
#---------------------------------------------------------------
echo "[1/7] Fetching Nikki source code..."
# 清理可能存在的旧目录，确保干净克隆
rm -rf ./nikki ./luci-app-nikki ./luci-i18n-nikki-zh-cn ./nikki_temp

# 尝试克隆 main 分支，如果失败则自动回退尝试 master 分支
if ! git clone --depth=1 --single-branch --branch "main" "https://github.com/nikkinikki-org/OpenWrt-nikki.git" ./nikki_temp 2>/dev/null; then
    echo "  -> Branch 'main' not found, trying 'master'..."
    git clone --depth=1 --single-branch --branch "master" "https://github.com/nikkinikki-org/OpenWrt-nikki.git" ./nikki_temp
fi

if [ -d "./nikki_temp" ]; then
    echo "  -> Clone successful. Analyzing repository structure..."
    
    # 情况 A: 仓库根目录直接包含 Makefile (整个仓库就是一个包)
    if [ -f "./nikki_temp/Makefile" ] && [ ! -d "./nikki_temp/nikki" ]; then
        echo "  -> Detected single package structure. Moving to ./nikki"
        mv ./nikki_temp ./nikki
    # 情况 B: 仓库包含多个子目录 (如 nikki/, luci-app-nikki/)
    else
        echo "  -> Detected multi-package structure. Extracting components..."
        [ -d "./nikki_temp/nikki" ] && mv ./nikki_temp/nikki ./nikki && echo "     - Moved ./nikki"
        [ -d "./nikki_temp/luci-app-nikki" ] && mv ./nikki_temp/luci-app-nikki ./luci-app-nikki && echo "     - Moved ./luci-app-nikki"
        [ -d "./nikki_temp/luci-i18n-nikki-zh-cn" ] && mv ./nikki_temp/luci-i18n-nikki-zh-cn ./luci-i18n-nikki-zh-cn && echo "     - Moved ./luci-i18n-nikki-zh-cn"
        rm -rf ./nikki_temp
    fi
    
    # 强制刷新 OpenWrt 包索引 (确保新拉取的包被 make defconfig 识别)
    if [ -d "./nikki" ]; then
        echo "  -> Generating package index for Nikki..."
        # 打印目录结构以便在 Actions 日志中调试
        ls -la ./nikki | head -n 5
    fi
else
    echo "  -> [ERROR] Git clone failed! Nikki will not be compiled."
fi
echo "Nikki fetching process finished!"
#---------------------------------------------------------------
# 1) 先把 collections 下所有 Makefile 里写死的 +luci-theme-任意主题
#    统一纠正成 +luci-theme-bootstrap（VIKINGYFY 的 immortalwrt 源码里
#    luci-light 等合集包直接硬编码依赖 luci-theme-aurora，不是通过
#    Settings.sh 里 "luci-theme-bootstrap → luci-theme-$WRT_THEME" 这种
#    可替换文本生成的，所以必须在这里单独纠正一次），
#    确保依赖永远指向不会被删除的 bootstrap，之后才能安全删除其它主题源码
#---------------------------------------------------------------
sed -i -E "s/\+luci-theme-[a-zA-Z0-9_-]+/+luci-theme-bootstrap/g" $(find ../feeds/luci/collections/ -type f -name "Makefile")
echo "collections Makefile theme dependency corrected to bootstrap!"

#---------------------------------------------------------------
# 2) 删除 HomeProxy 以及除 Bootstrap 外的其它主题源码
#    （对应目录名取自各 UPDATE_PACKAGE 克隆下来的仓库名，而非第一个参数）
#    这样 Handles.sh 里 argon/aurora 的 [ -d ... ] 判断会自然为假，无需改 Handles.sh
#---------------------------------------------------------------
rm -rf ./luci-theme-argon ./luci-theme-aurora ./luci-app-aurora-config \
       ./luci-theme-kucat ./luci-app-kucat-config ./luci-theme-noobwrt \
       ./luci-theme-shadcn ./luci-theme-fluent ./homeproxy
echo "unwanted themes and homeproxy source removed!"

#---------------------------------------------------------------
# 3) 写入 sysctl.conf 网络缓冲区参数
#    sysctl.conf 本身就是 base-files 自带文件（不是独立包），直接覆盖不会冲突
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
# 4) cpufreq 默认参数：改用 uci-defaults 首次开机 uci set，而不是编译期
#    直接写 files/etc/config/cpufreq —— 避免和 cpufreq 包自己安装的
#    同名文件在 package/install 阶段发生"文件被两个包同时提供"的冲突
#---------------------------------------------------------------
mkdir -p ./base-files/files/etc/uci-defaults
cat > ./base-files/files/etc/uci-defaults/98-custom-cpufreq << 'CEOF'
#!/bin/sh

uci set cpufreq.cpufreq='settings'
uci set cpufreq.cpufreq.governor0='performance'
uci set cpufreq.cpufreq.minfreq0='1382400'
uci set cpufreq.cpufreq.maxfreq0='1382400'

uci set cpufreq.global='settings'
uci set cpufreq.global.set='1'

uci commit cpufreq

exit 0
CEOF
chmod +x ./base-files/files/etc/uci-defaults/98-custom-cpufreq
echo "cpufreq uci-defaults written!"

#---------------------------------------------------------------
# 5) 写入无线默认国家代码/信道/频宽/功率
#    以 uci-defaults 形式随固件写入，首次开机执行一次；
#    按 band（2g/5g）匹配，不依赖 radio0/radio1 的顺序，
#    对多设备（MULTI_PROFILE）固件包同样安全；wifi-no 变体没有
#    /etc/config/wireless，靠开头的判断直接跳过
#---------------------------------------------------------------
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
