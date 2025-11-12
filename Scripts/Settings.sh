#!/bin/bash

#修改默认主题
sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" $(find ./feeds/luci/collections/ -type f -name "Makefile")
#修改immortalwrt.lan关联IP
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $(find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js")
#添加编译日期标识
sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ $WRT_MARK-$WRT_DATE')/g" $(find ./feeds/luci/modules/luci-mod-status/ -type f -name "10_system.js")

#!/bin/bash

WIFI_SH=$(find ./target/linux/{mediatek/filogic,qualcommax}/base-files/etc/uci-defaults/ -type f -name "*set-wireless.sh" 2>/dev/null)
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"

if [ -f "$WIFI_SH" ]; then
    # 修改WIFI名称
    sed -i "s/BASE_SSID='.*'/BASE_SSID='$WRT_SSID'/g" "$WIFI_SH"
    # 修改WIFI密码
    sed -i "s/BASE_WORD='.*'/BASE_WORD='$WRT_WORD'/g" "$WIFI_SH"
elif [ -f "$WIFI_UC" ]; then
    # 备份原文件
    cp "$WIFI_UC" "$WIFI_UC.bak"
    echo "开始修改mac80211.uc文件..."
    
    # 1. 修改国家代码
    sed -i "s/country='.*'/country='US'/g" "$WIFI_UC"
    
    # 2. 修改功率设置
    if grep -q "txpower" "$WIFI_UC"; then
        sed -i "s/txpower='[^']*'/txpower='25'/g" "$WIFI_UC"
    else
        # 在disabled行后插入txpower
        sed -i "/set \${s}.disabled='0'/a\set \${s}.txpower='25';" "$WIFI_UC"
    fi
    
    # 3. 修改信道设置 - 使用更安全的方法
    # 先检查是否已存在自定义信道设置
    if ! grep -q "自定义信道设置" "$WIFI_UC"; then
        sed -i '/let channel = rband.default_channel ?? "auto";/a\
// 自定义信道设置\
if (band_name == "2G") {\
\tchannel = "9";\
} else if (band_name == "5G") {\
\tchannel = "44";\
}' "$WIFI_UC"
    fi
    
    # 4. 修改htmode设置 - 更精确的替换
    # 先找到htmode设置的代码块
    if grep -q "let htmode = filter(htmode_order, (m) => band\[lc(m)\])\[0\];" "$WIFI_UC"; then
        # 创建临时文件来存储修改后的内容
        sed '/let htmode = filter(htmode_order, (m) => band\[lc(m)\])\[0\];/,+4c\
let htmode = filter(htmode_order, (m) => band[lc(m)])[0];\
if (htmode) {\
\tif (band_name == "5G") {\
\t\thtmode = "HE160";\
\t} else {\
\t\thtmode += width;\
\t}\
} else {\
\thtmode = "NOHT";\
}' "$WIFI_UC" > "$WIFI_UC.tmp" && mv "$WIFI_UC.tmp" "$WIFI_UC"
    fi
    
    # 5. 修改width设置 - 更安全的方法
    # 查找并替换width设置逻辑
    sed -i '/if (band_name == "2G")/{n;n;n;n;c\
\t\tif (band_name == "2G")\
\t\t\twidth = 20;\
\t\telse if (band_name == "5G")\
\t\t\twidth = 160;\
\t\telse if (width > 80)\
\t\t\twidth = 80;' "$WIFI_UC"
    
    # 6. 修改SSID和加密
    sed -i "s/ssid='\${defaults?.ssid || \"ImmortalWRT\"}'/ssid='$WRT_SSID'/g" "$WIFI_UC"
    sed -i "s/encryption='\${defaults?.encryption || \"none\"}'/encryption='psk2'/g" "$WIFI_UC"
    sed -i "s/key='\${defaults?.key || \"\"}'/key='$WRT_WORD'/g" "$WIFI_UC"
    
    echo "修改完成，验证修改结果："
    echo "=== 国家设置 ==="
    grep "country" "$WIFI_UC"
    echo "=== 功率设置 ==="
    grep "txpower" "$WIFI_UC" || echo "未找到txpower设置"
    echo "=== 信道设置修改 ==="
    grep -A 5 -B 5 "自定义信道设置" "$WIFI_UC" || echo "未找到自定义信道设置"
    echo "=== 带宽设置逻辑 ==="
    grep -A 5 -B 5 "htmode" "$WIFI_UC" | head -20
    echo "=== 宽度设置逻辑 ==="
    grep -A 5 -B 5 "width =" "$WIFI_UC" || grep -A 5 -B 5 "width=" "$WIFI_UC"
fi
#高通平台调整
DTS_PATH="./target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/"
if [[ "${WRT_TARGET^^}" == *"QUALCOMMAX"* ]]; then
	#取消nss相关feed
	echo "CONFIG_FEED_nss_packages=n" >> ./.config
	echo "CONFIG_FEED_sqm_scripts_nss=n" >> ./.config
	#开启sqm-nss插件
	echo "CONFIG_PACKAGE_luci-app-sqm=y" >> ./.config
	echo "CONFIG_PACKAGE_sqm-scripts-nss=y" >> ./.config
	#设置NSS版本
	echo "CONFIG_NSS_FIRMWARE_VERSION_11_4=n" >> ./.config
	if [[ "${WRT_CONFIG,,}" == *"ipq50"* ]]; then
		echo "CONFIG_NSS_FIRMWARE_VERSION_12_2=y" >> ./.config
	else
		echo "CONFIG_NSS_FIRMWARE_VERSION_12_5=y" >> ./.config
	fi
	#无WIFI配置调整Q6大小
	if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
		find $DTS_PATH -type f ! -iname '*nowifi*' -exec sed -i 's/ipq\(6018\|8074\).dtsi/ipq\1-nowifi.dtsi/g' {} +
		echo "qualcommax set up nowifi successfully!"
	fi
	
