#!/bin/bash

#修改默认主题
sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" $(find ./feeds/luci/collections/ -type f -name "Makefile")
#修改immortalwrt.lan关联IP
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $(find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js")
#添加编译日期标识
sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ $WRT_MARK-$WRT_DATE')/g" $(find ./feeds/luci/modules/luci-mod-status/ -type f -name "10_system.js")

#!/bin/bash

# 定义变量（根据需要调整）
WRT_SSID="YourSSID"  # 替换为您的 SSID
WRT_WORD="w882929342"  # WiFi 密码

WIFI_SH=$(find ./target/linux/{mediatek/filogic,qualcommax}/base-files/etc/uci-defaults/ -type f -name "*set-wireless.sh" 2>/dev/null)
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"

if [ -f "$WIFI_SH" ]; then
    # 修改 WIFI 名称
    sed -i "s/BASE_SSID='.*'/BASE_SSID='$WRT_SSID'/g" "$WIFI_SH"
    # 修改 WIFI 密码
    sed -i "s/BASE_WORD='.*'/BASE_WORD='$WRT_WORD'/g" "$WIFI_SH"
    echo "已修改 set-wireless.sh 文件。"
elif [ -f "$WIFI_UC" ]; then
    # 备份原文件
    cp "$WIFI_UC" "$WIFI_UC.bak"
    echo "开始修改 mac80211.uc 文件..."

    # 1. 修改国家代码为 US（精确匹配 print 语句）
    sed -i "s/set \${s}.country='\${country || ''}'/set \${s}.country='US'/g" "$WIFI_UC"

    # 2. 修改功率设置 - 插入条件逻辑，根据频段设置不同功率
    if grep -q "txpower" "$WIFI_UC"; then
        # 如果已存在，替换为条件块（假设替换整个 txpower 行）
        sed -i '/txpower=/c\
if (band_name == "5G") {\
    set \${s}.txpower="25";\
} else if (band_name == "2G") {\
    set \${s}.txpower="24";\
}' "$WIFI_UC"
    else
        # 在 disabled 行后插入条件 txpower 设置
        sed -i "/set \${s}.disabled='0'/a\\
if (band_name == \"5G\") {\\
    set \${s}.txpower='25'\\
} else if (band_name == \"2G\") {\\
    set \${s}.txpower='24'\\
}" "$WIFI_UC"
    fi

    # 3. 添加信道设置 - 在默认 channel 后插入自定义逻辑（5G=44, 2G=9）
    sed -i '/let channel = rband.default_channel ?? "auto";/a\
# 自定义信道设置\
if (band_name == "2G") {\
    channel = "9";\
} else if (band_name == "5G") {\
    channel = "44";\
}' "$WIFI_UC"

    # 4. 修改 htmode 逻辑 - 5G 使用 HE160，2G 使用 +width
    echo "=== 当前 htmode 设置逻辑 ==="
    grep -A 10 -B 5 "htmode" "$WIFI_UC"
    # 替换 htmode 块
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

    # 5. 修改 width 逻辑 - 2G=20, 5G=160, 其他<=80
    sed -i '/let width = band.max_width;/,+3c\
let width = band.max_width;\
if (band_name == "2G") {\
    width = 20;\
} else if (band_name == "5G") {\
    width = 160;\
} else if (width > 80) {\
    width = 80;\
}' "$WIFI_UC"

    # 6. 修改 SSID、加密和密钥（匹配 ?. 语法）
    sed -i "s/ssid='\${defaults?\\.ssid || \"ImmortalWRT\"}'/ssid='$WRT_SSID'/g" "$WIFI_UC"
    sed -i "s/encryption='\${defaults?\\.encryption || \"none\"}'/encryption='psk2'/g" "$WIFI_UC"
    sed -i "s/key='\${defaults?\\.key || \"\"}'/key='$WRT_WORD'/g" "$WIFI_UC"

    echo "修改完成，验证结果："
    echo "=== 国家设置 ==="
    grep "country" "$WIFI_UC" || echo "未找到 country 设置"
    echo "=== 功率设置 ==="
    grep -A 5 -B 5 "txpower" "$WIFI_UC" || echo "未找到 txpower 设置"
    echo "=== 信道设置 ==="
    grep -A 5 -B 5 "自定义信道设置" "$WIFI_UC" || echo "未找到自定义信道设置"
    echo "=== htmode 逻辑 ==="
    grep -A 5 -B 5 "htmode = filter" "$WIFI_UC"
    echo "=== width 逻辑 ==="
    grep -A 5 -B 5 "width = band.max_width" "$WIFI_UC"
    echo "=== SSID/密钥设置 ==="
    grep -A 2 "ssid\|key\|encryption" "$WIFI_UC"
else
    echo "未找到 WIFI_SH 或 WIFI_UC 文件，请检查路径。"
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
