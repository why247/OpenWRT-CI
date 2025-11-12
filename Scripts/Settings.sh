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
    
# 1. 国家代码
    sed -i "s/set \${s}.country='\${country || ''}'/set \${s}.country='US'/g" "$WIFI_UC"

    # 2. 功率设置（5G=25, 2G=24）
    if grep -q "txpower" "$WIFI_UC"; then
        sed -i '/set \${s}.txpower/d' "$WIFI_UC"  # 先删除旧的
    fi
    sed -i "/set \${s}.disabled='0'/a \\
if (band_name == \"5G\") {\\
    set \${s}.txpower='25'\\
} else if (band_name == \"2G\") {\\
    set \${s}.txpower='24'\\
}" "$WIFI_UC"

    # 3. 信道设置 - 关键修复：插在 rband 定义后，且加 null 保护
    # 找到 rband 定义行后插入
    sed -i '/let rband = radio\.bands\[band_name\];/a\
\ \ \ \ if (rband) {\
\ \ \ \ \ \ \ \ # 自定义信道设置（仅当 rband 存在时）\
\ \ \ \ \ \ \ \ if (band_name == "2G") {\
\ \ \ \ \ \ \ \ \ \ \ \ channel = "9";\
\ \ \ \ \ \ \ \ } else if (band_name == "5G") {\
\ \ \ \ \ \ \ \ \ \ \ \ channel = "44";\
\ \ \ \ \ \ \ \ }\
\ \ \ \ } else {\
\ \ \ \ \ \ \ \ channel = "auto";\
\ \ \ \ }' "$WIFI_UC"

    # 删除原默认 channel 行（避免重复）
    sed -i '/let channel = rband\.default_channel ?? "auto";/d' "$WIFI_UC"

    # 4. htmode 修复
    sed -i '/let htmode = filter(htmode_order, (m) => band\[lc(m)\])\[0\];/,+3c\
let htmode = filter(htmode_order, (m) => band[lc(m)])[0];\
if (htmode) {\
    if (band_name == "5G") {\
        htmode = "HE160";\
    } else {\
        htmode += width;\
    }\
} else {\
    htmode = "NOHT";\
}' "$WIFI_UC"

    # 5. width 修复
    sed -i '/let width = band\.max_width;/,+2c\
let width = band.max_width;\
if (band_name == "2G") {\
    width = 20;\
} else if (band_name == "5G") {\
    width = 160;\
} else if (width > 80) {\
    width = 80;\
}' "$WIFI_UC"

    # 6. SSID 和密码
    sed -i "s/ssid='\${defaults?\\.ssid || \"ImmortalWRT\"}'/ssid='$WRT_SSID'/g" "$WIFI_UC"
    sed -i "s/encryption='\${defaults?\\.encryption || \"none\"}'/encryption='psk2'/g" "$WIFI_UC"
    sed -i "s/key='\${defaults?\\.key || \"\"}'/key='$WRT_WORD'/g" "$WIFI_UC"

    echo "修复完成！验证关键修改："
    echo "=== 信道安全逻辑 ==="
    grep -A 8 -B 2 "rband.*band_name" "$WIFI_UC" | head -15
    echo "=== 功率条件逻辑 ==="
    grep -A 3 "txpower" "$WIFI_UC"
    echo "=== commit 是否存在 ==="
    grep "commit wireless" "$WIFI_UC" && echo "OK"

else
    echo "未找到文件！"
fi


CFG_FILE="./package/base-files/files/bin/config_generate"
#修改默认IP地址
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $CFG_FILE
#修改默认主机名
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" $CFG_FILE

#配置文件修改
echo "CONFIG_PACKAGE_luci=y" >> ./.config
echo "CONFIG_LUCI_LANG_zh_Hans=y" >> ./.config
echo "CONFIG_PACKAGE_luci-theme-$WRT_THEME=y" >> ./.config
echo "CONFIG_PACKAGE_luci-app-$WRT_THEME-config=y" >> ./.config

#手动调整的插件
if [ -n "$WRT_PACKAGE" ]; then
	echo -e "$WRT_PACKAGE" >> ./.config
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
fi
