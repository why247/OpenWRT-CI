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
    sed -i "s/country='.*'/country='US'/g" $WIFI_UC
   
    # 2. 修改功率设置 - 在正确的位置插入
    # 先检查是否已存在txpower设置
    if grep -q "txpower" "$WIFI_UC"; then
        sed -i "s/txpower='[^']*'/txpower='25'/g" "$WIFI_UC"
    else
        # 在disabled行后插入txpower
        sed -i "/set \${s}.disabled='0'/a set \${s}.txpower='25'" "$WIFI_UC"
    fi
   
    # 3. 修改信道设置
    # 在channel定义后添加信道设置逻辑
    sed -i '/let channel = rband.default_channel ?? "auto";/a\
    # 自定义信道设置\
    if (band_name == "2G") {\
        channel = "9";\
    } else if (band_name == "5G") {\
        channel = "44";\
    }' "$WIFI_UC"
   
    # 4. 修改通道宽度 - 需要更精确的处理
    # 首先查看当前的htmode设置逻辑
    echo "=== 当前htmode设置逻辑 ==="
    grep -A 10 -B 5 "htmode" "$WIFI_UC"
   
    # 修改htmode生成逻辑 - 更精确的替换
    # 找到htmode设置的代码块并替换
    sed -i '/let htmode = filter(htmode_order, (m) => band$lc(m)$)$0$;/,+4c\
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
   
    # 5. 确保5G频段使用160MHz宽度
    # 修改width设置逻辑
    sed -i '/let width = band.max_width;/,+5c\
        let width = band.max_width;\
        if (band_name == "2G") {\
            width = 20;\
        } else if (band_name == "5G") {\
            width = 160;\
        } else if (width > 80) {\
            width = 80;\
        }' "$WIFI_UC"
   
    # 6. 修改SSID和加密
    sed -i "s/ssid='\${defaults?\.ssid || \"ImmortalWRT\"}'/ssid='$WRT_SSID'/g" "$WIFI_UC"
    sed -i "s/encryption='\${defaults?\.encryption || \"none\"}'/encryption='psk2'/g" "$WIFI_UC"
    sed -i "s/key='\${defaults?\.key || \"\"}'/key='$WRT_WORD'/g" "$WIFI_UC"
   
    echo "修改完成，验证修改结果："
    echo "=== 国家设置 ==="
    grep "country" "$WIFI_UC"
    echo "=== 功率设置 ==="
    grep "txpower" "$WIFI_UC" || echo "未找到txpower设置"
    echo "=== 信道设置修改 ==="
    grep -A 5 -B 5 "自定义信道设置" "$WIFI_UC" || echo "未找到自定义信道设置"
    echo "=== 带宽设置逻辑 ==="
    grep -A 5 -B 5 "htmode.*=" "$WIFI_UC"
    echo "=== 宽度设置逻辑 ==="
    grep -A 5 -B 5 "width.*=" "$WIFI_UC"
   
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
