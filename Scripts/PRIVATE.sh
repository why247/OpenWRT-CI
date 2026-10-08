#!/bin/bash

# 覆盖工作流的主题设置：用 Bootstrap
WRT_THEME=bootstrap
export WRT_THEME
# 私有定制脚本（上游仓库里不存在这个文件，Sync fork 永远不会因为它冲突）
# 由 Scripts/Packages.sh 末尾 source 执行（CWD 见下方第 0 节自动探测）
#
# 本文件承载全部私有定制，共 6 节 + 1 个前置步骤：
#   0) 前置：中和上游 Settings.sh 的主题逻辑（它在本脚本之后执行，
#      不中和的话 [1/6] 的改动会被它覆盖回去）
#   1) 主题：只保留 Bootstrap
#   2) 删除除 Bootstrap 外的其它主题源码（HomeProxy 保留，与 Nikki 共存）
#   3) /etc/config/cpufreq 固定为 performance + 1382400
#   4) /etc/sysctl.conf 网络缓冲区参数
#   5) 无线：2.4G/5G 国家代码、信道、频宽、发射功率
#   6) 去掉 LuCI “未设置密码” 警告（配合空密码使用）
#   （编号与下面注释里的 [n/6] 对应，方便在 CI 日志里核对）

echo " "
echo "=============================================="
echo "Applying private customizations..."
echo "=============================================="

#---------------------------------------------------------------
# 0) 定位 wrt 源码树
#    上游不同版本的 Packages.sh 工作目录不一样：
#      新版：CWD = wrt/        （脚本里写 ./package/ 前缀）
#      旧版：CWD = wrt/package/（脚本里写直接相对路径）
#    这里自动探测，Sync fork 后本脚本不会因为目录变化而静默失效。
#---------------------------------------------------------------
if [ -d "./package/base-files" ]; then
	WRT_DIR="$(pwd)"
elif [ -d "./base-files" ]; then
	WRT_DIR="$(cd .. && pwd)"
else
	echo "[ERROR] WRT source tree not found, private customizations skipped!"
	return 0 2>/dev/null || exit 0
fi

PKG_DIR="$WRT_DIR/package"
FEEDS_DIR="$WRT_DIR/feeds"
echo "WRT source tree: $WRT_DIR"

#---------------------------------------------------------------
# [0/6] 前置：中和上游 Settings.sh 的主题逻辑
#    上游 Settings.sh 在本脚本之后执行，会做两件事：
#      1) 把 feeds/luci/collections 里的 luci-theme-bootstrap 替换成
#         luci-theme-$WRT_THEME
#      2) 往 .config 里追加 CONFIG_PACKAGE_luci-theme-$WRT_THEME 和
#         CONFIG_PACKAGE_luci-app-$WRT_THEME-config
#    [1/6][2/6] 在本脚本执行时就已做完，拦不住之后执行的 Settings.sh，
#    所以这里直接把 Settings.sh 文件里的 luci-theme-$WRT_THEME
#    写死成 luci-theme-bootstrap。
#    只改 runner 工作区的临时文件，不动 git，Sync fork 不冲突；
#    万一上游改了 Settings.sh 的写法导致这里 sed 对不上，它会自动空转，
#    [1/6][2/6] 仍是兜底，CI 日志里能看到 [WARN]。
#---------------------------------------------------------------
SETTINGS_SH=""
for CAND in "$GITHUB_WORKSPACE/Scripts/Settings.sh" "$WRT_DIR/../Scripts/Settings.sh"; do
	if [ -f "$CAND" ]; then
		SETTINGS_SH="$CAND"
		break
	fi
done
if [ -n "$SETTINGS_SH" ]; then
	# \$ 转义保证匹配的是字面量的 $WRT_THEME，而不是 sed 的行尾锚点
	sed -i 's/luci-theme-\$WRT_THEME/luci-theme-bootstrap/g' "$SETTINGS_SH"
	echo "[0/6] Settings.sh theme logic neutralized -> bootstrap ($SETTINGS_SH)"
else
	echo "[0/6] [WARN] Settings.sh not found, theme neutralization skipped!"
fi

#---------------------------------------------------------------
# [1/6] 主题只保留 Bootstrap
#    官方 luci 合集包（collections/luci-light 等）依赖的是
#    +luci-theme-bootstrap。上游 Settings.sh 原本会在本脚本之后把它
#    替换成 luci-theme-$WRT_THEME，已由前面的 [0/6] 中和；
#    这里再统一改回 bootstrap 作为兜底，保证被依赖、被安装的只有 bootstrap。
#    （luci-base 默认 /etc/config/luci 里 mediaurlbase 本身就是
#      /luci-static/bootstrap，主题包自带的 30_luci-theme-* 也只会在
#      被安装时才运行，所以只要安装集里只剩 bootstrap 就一定是 bootstrap）
#---------------------------------------------------------------
if [ -d "$FEEDS_DIR/luci/collections" ]; then
	# 用 BRE 写法（+ 在 BRE 里就是普通字符），不吃 GNU sed 的扩展转义
	find "$FEEDS_DIR/luci/collections/" -type f -name "Makefile" \
		-exec sed -i "s/+luci-theme-[a-zA-Z0-9_-][a-zA-Z0-9_-]*/+luci-theme-bootstrap/g" {} +
	echo "[1/6] collections theme dependency corrected to bootstrap!"
else
	echo "[1/6] [WARN] $FEEDS_DIR/luci/collections not found, skipped!"
fi

#---------------------------------------------------------------
# [2/6] 删除除 Bootstrap 外的其它主题源码（HomeProxy 保留，与 Nikki 共存）
#    主题目录名 = UPDATE_PACKAGE 克隆下来的仓库名（不是第一个参数），
#    例如 "aurora" 克隆出的是 luci-theme-aurora。
#    用通配删除 package/ 下的 luci-theme-*，这样上游以后新增主题也会被清掉；
#    -maxdepth 1 不会碰到 package/feeds/luci/ 里 feed 自身的主题（那些只是
#    install 出来的软链，没被任何合集依赖、没被 .config 选中就不会编译）。
#---------------------------------------------------------------
find "$PKG_DIR" -maxdepth 1 -type d -name 'luci-theme-*' ! -name 'luci-theme-bootstrap' \
	-exec rm -rf {} + 2>/dev/null
# 主题配套的配置插件目录名与 UPDATE_PACKAGE 参数同名，这里显式列出，
# 故意不用 luci-app-*-config 通配，免得上游以后新增别家的 *-config 被误删
for THEME_CFG in luci-app-aurora-config luci-app-kucat-config; do
	if [ -d "$PKG_DIR/$THEME_CFG" ]; then
		rm -rf "$PKG_DIR/$THEME_CFG"
		echo "    removed theme config app: $THEME_CFG"
	fi
done
echo "[2/6] non-bootstrap theme sources removed!"
#    HomeProxy 保留：源码在 $PKG_DIR/packages/luci-app-homeproxy
#    （UPDATE_PACKAGE "viking" 把 VIKINGYFY/packages 整个 clone 到 package/packages），
#    包选择由 Config/GENERAL.txt 的 luci-app-homeproxy=y 控制（PRIVATE.txt 不再覆盖），
#    与 Nikki 共存（nikki 用 mihomo 内核，homeproxy 用 sing-box 内核，互不冲突）。

#---------------------------------------------------------------
# [3/6] /etc/sysctl.conf 网络缓冲区参数
#    sysctl.conf 是 base-files 自带的文件（不是独立包），直接覆盖不会冲突；
#    上游该文件只有注释，覆盖不会丢掉有效配置。
#---------------------------------------------------------------
mkdir -p "$PKG_DIR/base-files/files/etc"
cat > "$PKG_DIR/base-files/files/etc/sysctl.conf" << 'EOF'
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.core.default_qdisc = fq_codel
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.core.netdev_max_backlog = 10000
net.netfilter.nf_conntrack_max = 262144
vm.min_free_kbytes = 16384
vm.swappiness = 10
EOF
echo "[3/6] sysctl.conf written!"

#---------------------------------------------------------------
# [3b/6] NSS 固件关闭 fw4 flow offload（软件 + 硬件），非 NSS（N1）保持开启
#    本固件是 NSS 版（qca-nss-drv + ECM），转发加速由 ECM 交给 NSS 硬件。
#    fw4 flowtable 会和 ECM 抢连接（实测 HW_OFFLOAD=0，软中断 15%），
#    关掉后测速软中断 0-4%（2026-10-09 AP8220 实测）。
#---------------------------------------------------------------
mkdir -p "$PKG_DIR/base-files/files/etc/uci-defaults"
cat > "$PKG_DIR/base-files/files/etc/uci-defaults/99z-flowoffload" << 'FOEOF'
#!/bin/sh
# NSS builds (AP8220): ECM accelerates, fw4 flowtable must be off.
# Non-NSS builds (N1 etc.): keep fw4 flow offload on.
if [ -x /etc/init.d/qca-nss-ecm ]; then
	uci set firewall.@defaults[0].flow_offloading='0' 2>/dev/null
	uci set firewall.@defaults[0].flow_offloading_hw='0' 2>/dev/null
else
	uci set firewall.@defaults[0].flow_offloading='1' 2>/dev/null
	uci set firewall.@defaults[0].flow_offloading_hw='1' 2>/dev/null
fi
uci commit firewall 2>/dev/null
exit 0
FOEOF
chmod +x "$PKG_DIR/base-files/files/etc/uci-defaults/99z-flowoffload"
echo "[3b/6] flow offload script written (off on NSS/ECM, on otherwise)!"

#---------------------------------------------------------------
# [4/6] /etc/config/cpufreq 固定为 performance + 1382400
#    直接覆盖 cpufreq 包自带的默认配置文件（package/emortal/cpufreq/files/
#    cpufreq.config，包 Makefile 用 INSTALL_CONF 把它装成 /etc/config/cpufreq），
#    这样装进固件的 /etc/config/cpufreq 就是要求的内容。
#    额外好处：global.set=1 会让 cpufreq 包自带的 /etc/uci-defaults/10-cpufreq
#    开机自动探测逻辑直接退出，不会再改掉这里的值。
#---------------------------------------------------------------
CPUFREQ_CFG="$PKG_DIR/emortal/cpufreq/files/cpufreq.config"
if [ -f "$CPUFREQ_CFG" ]; then
	cat > "$CPUFREQ_CFG" << 'EOF'
config settings 'cpufreq'
	option governor0 'performance'
	option minfreq0 '1382400'
	option maxfreq0 '1382400'

config settings 'global'
	option set '1'
EOF
	echo "[4/6] cpufreq default config overwritten!"
else
	echo "[4/6] [WARN] $CPUFREQ_CFG not found (upstream moved it?), uci-defaults fallback still applies!"
fi

# 兜底：首次开机再 uci set 一遍（幂等）。
# 覆盖两种情况下上面的文件覆盖不生效的场景：包没被选中（x86 上 cpufreq 依赖
# arm/aarch64，装了也没有这个文件）、或者升级时保留了旧 /etc/config/cpufreq。
mkdir -p "$PKG_DIR/base-files/files/etc/uci-defaults"
cat > "$PKG_DIR/base-files/files/etc/uci-defaults/99z-custom-cpufreq" << 'CEOF'
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
chmod +x "$PKG_DIR/base-files/files/etc/uci-defaults/99z-custom-cpufreq"
echo "[4/6] cpufreq uci-defaults fallback written!"

#---------------------------------------------------------------
# [5/6] 无线默认值：2.4G / 5G 国家代码 US，信道、频宽、发射功率，SSID/密码并启用
#    主路径：改生成器 mac80211.uc（/etc/config/wireless 由它生成：
#    /sbin/wifi config -> ucode /lib/wifi/mac80211.uc | uci -q batch）。
#    值直接写进生成结果，不依赖任何开机脚本的执行时机，最可靠；
#    上游 Settings.sh 改默认 SSID/密码用的也是同一个文件。
#    原生逻辑：2.4G 强制 20MHz，5G 频宽上限被压到 80MHz，且完全不写 txpower，
#    所以这里必须自己改。
#---------------------------------------------------------------
WIFI_UC="$PKG_DIR/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
if [ -f "$WIFI_UC" ]; then
	# 2.4G -> 信道 9 / 20MHz；5G -> 信道 44 / 160MHz
	# （band_name 此时还是大写，lc() 在后面才调用；htmode 由 width 拼出来，
	#   所以 5G 的 width=160 会生成 HE160，2.4G 保持 HE20）
	# 5G 的 width 写成 band.max_width > 160 ? 160 : band.max_width，
	# 即"取网卡上报能力、上限 160"，这样同平台镜像里若有只支持 80MHz 的网卡
	# （例如某些 x86 网卡），也不会被写出驱动不支持的模式导致无线起不来。
	# 注意：sed 的 c\ 会吃掉行首空白，所以插入的这几行没有缩进。
	# ucode 不依赖缩进，功能不受影响。
	sed -i '/if (band_name == "2G")/,/width = 80;/c\
if (band_name == "2G") {\
width = 20;\
channel = "auto";\
}\
else if (band_name == "5G") {\
width = band.max_width > 160 ? 160 : band.max_width;\
channel = 44;\
}\
else if (width > 80)\
width = 80;' "$WIFI_UC"

	# 国家代码统一 US（最优功率）；并补上 txpower（2.4G 20dBm / 5G 25dBm / 其它频段 0=驱动默认）
	sed -i "s@set \${s}\.country='\${country || [^}]*}'@set \${s}.country='US'\nset \${s}.txpower='\${band_name == '2g' ? 20 : (band_name == '5g' ? 25 : 0)}'@" "$WIFI_UC"

	if grep -q 'channel = "auto";' "$WIFI_UC" && grep -q 'channel = 44;' "$WIFI_UC" \
		&& grep -q "country='US'" "$WIFI_UC" && grep -q 'txpower' "$WIFI_UC"; then
		echo "[5/6] wifi generator patched (2.4G: US auto(1/6/11) HE20 15dBm, 5G: US ch44 up-to-HE160 25dBm)!"
	else
		echo "[5/6] [WARN] wifi generator patch did not fully apply (upstream mac80211.uc changed?), relying on uci-defaults!"
	fi
else
	echo "[5/6] [WARN] $WIFI_UC not found, relying on uci-defaults!"
fi

# 兜底：首次开机（含刷机后保留旧配置的场景）再 uci set 一遍。
# 按 band 匹配，不依赖 radio0/radio1 顺序；非 AX 网卡不动 htmode，
# 避免给出驱动不支持的模式（x86 上的 AC 网卡等）。
# 同时把所有 AP 接口的 SSID/密码写好并启用（生成器默认 disabled=1 不广播，
# 不在这里启用的话刷机后搜不到 WiFi）。
cat > "$PKG_DIR/base-files/files/etc/uci-defaults/99z-custom-wireless" << 'WEOF'
#!/bin/sh
. /lib/functions.sh

[ -f /etc/config/wireless ] || exit 0

configure_wifi() {
	local device="$1"
	local band htmode

	config_get band "$device" band
	config_get htmode "$device" htmode

	uci set wireless.$device.short_preamble='1'
	case "$band" in
	2g)
		uci set wireless.$device.country='US'
		uci set wireless.$device.channel='auto'
		uci set wireless.$device.channels='1 6 11'
		uci set wireless.$device.txpower='20'
		case "$htmode" in
		HE*) uci set wireless.$device.htmode='HE20' ;;
		esac
		;;
	5g)
		uci set wireless.$device.country='US'
		uci set wireless.$device.channel='44'
		uci set wireless.$device.txpower='25'
		case "$htmode" in
		HE*) uci set wireless.$device.htmode='HE160' ;;
		esac
		;;
	esac
}

# 无线网络：统一 SSID/密码并启用
configure_iface() {
	local iface="$1"
	local mode

	config_get mode "$iface" mode
	[ "$mode" = "ap" ] || return 0

	uci set wireless.$iface.ssid='jy'
	uci set wireless.$iface.encryption='psk2'
	uci set wireless.$iface.key='123456789@'
	uci set wireless.$iface.disabled='0'
	# 低延迟：DTIM 1 + 组播转单播（与 K3 一致）
	uci set wireless.$iface.dtim_period='1'
	uci set wireless.$iface.multicast_to_unicast='1'
}

config_load wireless
config_foreach configure_wifi wifi-device
config_foreach configure_iface wifi-iface
uci commit wireless

exit 0
WEOF
chmod +x "$PKG_DIR/base-files/files/etc/uci-defaults/99z-custom-wireless"
echo "[5/6] wireless uci-defaults fallback written!"

#---------------------------------------------------------------
# [6/6] 去掉 LuCI “未设置密码” 警告（空密码专用）
#    提示由主题模板渲染：登录后 header.ut 里判断
#      getuid() == 0 && getspnam('root')?.pwdp === ''  -> 显示警告
#    （中文文案 “尚未设置密码。请设置管理员密码以保护此设备。” / “转到密码配置…”）
#    这里把判断条件替换成 false，模板结构不动，只在编译期改模板；
#    需要注意这只去掉提示，root 仍然是空密码，能访问到 LuCI 的人就能登录。
#    主题模板在 luci feed 里，Settings.sh 也是直接改 feed 源，且
#    feeds install 出来的 package/feeds/... 是软链，改 feed 生效。
#---------------------------------------------------------------
if [ -d "$FEEDS_DIR/luci/themes" ]; then
	find "$FEEDS_DIR/luci/themes" -type f \( -name 'header.ut' -o -name 'notices.ut' \) \
		-exec sed -i "s@getuid() == 0 && getspnam('root')?.pwdp === ''@false@" {} +

	if grep -rq "getuid() == 0 && getspnam" "$FEEDS_DIR/luci/themes" 2>/dev/null; then
		echo "[6/6] [WARN] password warning still present in some theme template!"
	else
		echo "[6/6] LuCI 'no password set' warning removed!"
	fi
else
	echo "[6/6] [WARN] $FEEDS_DIR/luci/themes not found, skipped!"
fi

echo "=============================================="
echo "Private customizations applied!"
echo "=============================================="

# HomeProxy + sing-box：仓库内固化版本，不再跟随上游
#   luci-app-homeproxy = VIKINGYFY/packages 23b2ec21 + homeproxy-rt/patches 01-15（已打好）
#   sing-box           = 同一提交的 Makefile，版本号在下面改成编译时的最新发布
# 上游改动不会再让编译失败；要升级时在 sandbox 重新生成这两个 tar.gz。
# UPDATE_PACKAGE 仍把 VIKINGYFY/packages clone 到 $PKG_DIR/packages（其它包要用），这里覆盖这两个目录。
HP_VENDOR="$GITHUB_WORKSPACE/Scripts/homeproxy-rt/vendor"
for HP_PKG in luci-app-homeproxy sing-box; do
	rm -rf "$PKG_DIR/packages/$HP_PKG"
	if ! tar -xzf "$HP_VENDOR/$HP_PKG.tar.gz" -C "$PKG_DIR/packages"; then
		echo "[ERROR] vendored $HP_PKG extract failed!"
		exit 1
	fi
	echo "vendored $HP_PKG installed"
done

# sing-box 编译时跟随 SagerNet 最新发布（含测试版；AP8220/N1 用户要求 2026-10-09）
# 查询失败则保留 vendored 的版本。K3 在 k3-immortalwrt 仓库里固定版本，不走这里。
SB_MK="$PKG_DIR/packages/sing-box/Makefile"
SB_AUTH=""
[ -n "$GITHUB_TOKEN" ] && SB_AUTH="Authorization: Bearer $GITHUB_TOKEN"
SB_LATEST=$(curl -fsSL --retry 3 --max-time 30 ${SB_AUTH:+-H "$SB_AUTH"} \
	"https://api.github.com/repos/SagerNet/sing-box/releases?per_page=1" \
	| sed -n 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/p' | sed -n 1p)
if echo "$SB_LATEST" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[a-z]+\.[0-9]+)?$'; then
	SB_PKGVER=$(echo "$SB_LATEST" | sed 's/-\([a-z]*\)\.\([0-9]*\)$/_\1\2/')
	sed -i "s/^PKG_UPSTREAM_VERSION:=.*/PKG_UPSTREAM_VERSION:=$SB_LATEST/" "$SB_MK"
	sed -i "s/^PKG_VERSION:=.*/PKG_VERSION:=$SB_PKGVER/" "$SB_MK"
	sed -i "s/^PKG_HASH:=.*/PKG_HASH:=skip/" "$SB_MK"
	echo "sing-box -> latest $SB_LATEST"
else
	echo "[WARN] sing-box latest lookup failed, keeping vendored version"
fi
grep -m1 "PKG_UPSTREAM_VERSION" "$SB_MK"

# K3 专用定制 (bcm53xx/phicomm_k3 构建时执行，其它目标自动跳过)
# 内容：asus-dhd24 WiFi 固件 / yangxu52 屏幕驱动 / hy2 sysctl+RPS / 无线覆盖 / sing-box 1.14.2 GO_ARM=5
bash "$GITHUB_WORKSPACE/Scripts/k3-diy.sh"

# AP8220 专用定制 (ipq807x 构建时执行，其它目标自动跳过)
# 内容：dnsmasq 缓存（IRQ/RPS 交给上游 packet-steering + smp_affinity）
bash "$GITHUB_WORKSPACE/Scripts/ap8220-diy.sh"

# N1 专用定制 (armsr 构建时执行，其它目标自动跳过)
bash "$GITHUB_WORKSPACE/Scripts/n1-diy.sh"
