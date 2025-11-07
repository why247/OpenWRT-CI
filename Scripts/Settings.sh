#!/bin/bash
# OpenWrt固件自定义配置脚本
# 修改默认主题
sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" $(find ./feeds/luci/collections/ -type f -name "Makefile")
# 修改immortalwrt.lan关联IP
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $(find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js")
# 添加编译日期标识
sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ $WRT_MARK-$WRT_DATE')/g" $(find ./feeds/luci/modules/luci-mod-status/ -type f -name "10_system.js")
WIFI_SH=$(find ./target/linux/{mediatek/filogic,qualcommax}/base-files/etc/uci-defaults/ -type f -name "*set-wireless.sh" 2>/dev/null)
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
if [ -f "$WIFI_SH" ]; then
# 修改WIFI名称
sed -i "s/BASE_SSID='.*'/BASE_SSID='$WRT_SSID'/g" $WIFI_SH
# 修改WIFI密码
sed -i "s/BASE_WORD='.*'/BASE_WORD='$WRT_WORD'/g" $WIFI_SH
elif [ -f "$WIFI_UC" ]; then
# 分别配置radio0(5G)和radio1(2.4G)
# 修改radio0(5G)的SSID和密码
sed -i "/config wifi-iface 'default_radio0'/,/^$/ {
s/ssid='[^']*'/ssid='$WRT_SSID'/g
s/key='[^']*'/key='$WRT_WORD'/g
s/encryption='[^']*'/encryption='psk2+ccmp'/g
}" $WIFI_UC
# 修改radio1(2.4G)的SSID和密码
sed -i "/config wifi-iface 'default_radio1'/,/^$/ {
s/ssid='[^']*'/ssid='$WRT_SSID'/g
s/key='[^']*'/key='$WRT_WORD'/g
s/encryption='[^']*'/encryption='psk2+ccmp'/g
}" $WIFI_UC
# 修改radio0(5G)设备参数 - 国家代码US，信道44，160MHz宽度，24dBm功率
sed -i "/config wifi-device 'radio0'/,/^config/ {
s/country='[^']*'/country='US'/g
s/\(option channel\).*/\1 '44'/g
s/\(option htmode\).*/\1 'HE160'/g
s/\(option txpower\).*/\1 '24'/g
}" $WIFI_UC
# 修改radio1(2.4G)设备参数 - 国家代码US，信道9，24dBm功率
sed -i "/config wifi-device 'radio1'/,/^config/ {
s/country='[^']*'/country='US'/g
s/\(option channel\).*/\1 '9'/g
s/\(option txpower\).*/\1 '24'/g
}" $WIFI_UC
fi
CFG_FILE="./package/base-files/files/bin/config_generate"
# 修改默认IP地址
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $CFG_FILE
# 修改默认主机名
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" $CFG_FILE
# 配置文件修改
echo "CONFIG_PACKAGE_luci=y" >> ./.config
echo "CONFIG_LUCI_LANG_zh_Hans=y" >> ./.config
echo "CONFIG_PACKAGE_luci-theme-$WRT_THEME=y" >> ./.config
echo "CONFIG_PACKAGE_luci-app-$WRT_THEME-config=y" >> ./.config
# 添加CPU频率配置
echo "CONFIG_PACKAGE_luci-app-cpufreq=y" >> ./.config
echo "CONFIG_PACKAGE_cpufreq=y" >> ./.config
# 手动调整的插件
if [ -n "$WRT_PACKAGE" ]; then
echo -e "$WRT_PACKAGE" >> ./.config
fi
# 高通平台调整
DTS_PATH="./target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/"
if [[ "${WRT_TARGET^^}" == *"QUALCOMMAX"* ]]; then
# 取消nss相关feed
echo "CONFIG_FEED_nss_packages=n" >> ./.config
echo "CONFIG_FEED_sqm_scripts_nss=n" >> ./.config
# 开启sqm-nss插件
echo "CONFIG_PACKAGE_luci-app-sqm=y" >> ./.config
echo "CONFIG_PACKAGE_sqm-scripts-nss=y" >> ./.config
# 设置NSS版本
echo "CONFIG_NSS_FIRMWARE_VERSION_11_4=n" >> ./.config
if [[ "${WRT_CONFIG,,}" == *"ipq50"* ]]; then
echo "CONFIG_NSS_FIRMWARE_VERSION_12_2=y" >> ./.config
else
echo "CONFIG_NSS_FIRMWARE_VERSION_12_5=y" >> ./.config
fi
# 无WIFI配置调整Q6大小
if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
find $DTS_PATH -type f ! -iname '*nowifi*' -exec sed -i 's/ipq\(6018\|8074\).dtsi/ipq\1-nowifi.dtsi/g' {} +
echo "qualcommax set up nowifi successfully!"
fi
fi
# 配置CPU频率管理为performance模式
CPU_CONFIG="./package/base-files/files/etc/config/cpufreq"
mkdir -p $(dirname "$CPU_CONFIG")
cat > "$CPU_CONFIG" << EOF
config global 'global'
option governor 'performance'
config cpu 'cpu0'
option governor 'performance'
option minfreq '${WRT_CPU_MIN_FREQ:-800000}'
option maxfreq '${WRT_CPU_MAX_FREQ:-1800000}'
config cpu 'cpu1'
option governor 'performance'
option minfreq '${WRT_CPU_MIN_FREQ:-800000}'
option maxfreq '${WRT_CPU_MAX_FREQ:-1800000}'
config cpu 'cpu2'
option governor 'performance'
option minfreq '${WRT_CPU_MIN_FREQ:-800000}'
option maxfreq '${WRT_CPU_MAX_FREQ:-1800000}'
config cpu 'cpu3'
option governor 'performance'
option minfreq '${WRT_CPU_MIN_FREQ:-800000}'
option maxfreq '${WRT_CPU_MAX_FREQ:-1800000}'
EOF
# 创建CPU调频启动脚本
CPU_INIT="./package/base-files/files/etc/init.d/cpufreq"
mkdir -p $(dirname "$CPU_INIT")
cat > "$CPU_INIT" << EOF
#!/bin/sh /etc/rc.common

START=99

start() {
    sleep 10
    global_governor=\$(uci -q get cpufreq.global.governor || echo 'performance')
    for dir in /sys/devices/system/cpu/cpu[0-9]*; do
        cpu=\$(echo \$dir | sed 's/.+\\/cpu//')
        gov=\$(uci -q get cpufreq.cpu\$cpu.governor || echo \$global_governor)
        minfreq=\$(uci -q get cpufreq.cpu\$cpu.minfreq)
        maxfreq=\$(uci -q get cpufreq.cpu\$cpu.maxfreq)
        echo \$gov > \$dir/cpufreq/scaling_governor
        [ -n "\$minfreq" ] && echo \$minfreq > \$dir/cpufreq/scaling_min_freq
        [ -n "\$maxfreq" ] && echo \$maxfreq > \$dir/cpufreq/scaling_max_freq
    done
}

stop() {
    for dir in /sys/devices/system/cpu/cpu[0-9]*; do
        echo ondemand > \$dir/cpufreq/scaling_governor
    done
}
EOF
chmod +x "$CPU_INIT" 2>/dev/null || true
echo "无线和CPU配置完成！"
echo "5G无线: 国家US, 信道44, 160MHz, 24dBm"
echo "2.4G无线: 国家US, 信道9, 24dBm"
echo "CPU模式: performance"
