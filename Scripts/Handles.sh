#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (C) 2026 VIKINGYFY

FEEDS_PATH="./feeds"
PACKAGE_PATH="./package"

#修改argon主题字体和颜色
if [ -d "$PACKAGE_PATH/luci-theme-argon" ]; then
	echo " "
	if sed -i "s/primary '.*'/primary '#31a1a1'/g; s/'0.2'/'0.5'/g; s/'none'/'bing'/g; s/'600'/'normal'/g" \
		"$PACKAGE_PATH/luci-theme-argon/luci-app-argon-config/root/etc/config/argon"; then
		echo "theme-argon has been fixed!"
	else
		echo "theme-argon fix failed; continuing!"
	fi
fi

#修改aurora菜单式样
if [ -d "$PACKAGE_PATH/luci-app-aurora-config" ]; then
	echo " "
	if find "$PACKAGE_PATH/luci-app-aurora-config/root/usr/share/aurora/" -type f -name '*.template' -exec \
		sed -i "s/nav_type '.*'/nav_type 'dropdown'/g; s/struct_radius_base '.*'/struct_radius_base '0.125rem'/g" {} +; then
		echo "theme-aurora has been fixed!"
	else
		echo "theme-aurora fix failed; continuing!"
	fi
fi

#修改mini-diskmanager菜单位置
if [ -d "$PACKAGE_PATH/luci-app-mini-diskmanager" ]; then
	echo " "
	if sed -i "s/services/system/g" \
		"$PACKAGE_PATH/luci-app-mini-diskmanager/luci-app-mini-diskmanager/root/usr/share/luci/menu.d/luci-app-mini-diskmanager.json"; then
		echo "mini-diskmanager has been fixed!"
	else
		echo "mini-diskmanager fix failed; continuing!"
	fi
fi

#修改natmapt菜单位置
if [ -d "$PACKAGE_PATH/luci-app-natmapt" ]; then
	echo " "
	if sed -i "s/network/services/g" \
		"$PACKAGE_PATH/luci-app-natmapt/root/usr/share/luci/menu.d/luci-app-natmap.json"; then
		echo "natmapt has been fixed!"
	else
		echo "natmapt fix failed; continuing!"
	fi
fi

#修复Rust编译失败
if [ -d "$FEEDS_PATH/packages/lang/rust" ]; then
	echo " "
	if sed -i 's/ci-llvm=true/ci-llvm=false/g' \
		"$FEEDS_PATH/packages/lang/rust/Makefile"; then
		echo "rust has been fixed!"
	else
		echo "rust fix failed; continuing!"
	fi
fi

#应用HomeProxy redirect/tproxy补丁集
HP_SRC="$PACKAGE_PATH/packages/luci-app-homeproxy"
HP_RT="$(cd "$(dirname "$0")" && pwd)/homeproxy-rt"
if [ -d "$HP_SRC" ] && [ -f "$HP_RT/apply-patches.sh" ]; then
	echo " "
	echo "Applying HomeProxy patch set..."
	if sh "$HP_RT/apply-patches.sh" "$HP_SRC"; then
		echo "HomeProxy patches applied!"
		# 更新描述：TUN -> Redirect+TPROXY (用 sed，比 patch 更稳健)
		sed -i 's|Sing-Box/TUN/AI Edition|Sing-Box/Redirect+TPROXY|g' "$HP_SRC/Makefile"
		sed -i 's|Sing-Box/TUN/AI Edition|Sing-Box/Redirect+TPROXY|g' "$HP_SRC/htdocs/luci-static/resources/view/homeproxy/server.js"
		sed -i 's|Sing-Box/TUN/AI Edition|Sing-Box/Redirect+TPROXY|g' "$HP_SRC/htdocs/luci-static/resources/view/homeproxy/client.js"
		sed -i "s/import { isnan } from 'math';/const isnan = (x) => x !== x;/" "$HP_SRC/root/etc/homeproxy/scripts/generate_client.uc"
		echo "HomeProxy description updated"
		# sing-box Go 运行时：GOGC=200 减半 GC 次数，GOMEMLIMIT 兜底（AP8220 512MB）
		HP_INIT="$HP_SRC/root/etc/init.d/homeproxy"
		grep -q 'GOGC=200' "$HP_INIT" || sed -i '/QUIC_GO_DISABLE_GSO/a\\t\tprocd_append_param env GOGC=200 GOMEMLIMIT=192MiB' "$HP_INIT"
		grep -q 'GOGC=200' "$HP_INIT" && echo "sing-box GOGC/GOMEMLIMIT set" || echo "WARNING: GOGC not injected" >&2
		CN_IP_DIR="$HP_SRC/root/etc/homeproxy/resources"
		mkdir -p "$CN_IP_DIR"
		if curl -fsSL --retry 3 --max-time 60 "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@meta/geo/geoip/cn.list" -o "$CN_IP_DIR/cn_ip.list.tmp"; then
			if [ "$(wc -l < "$CN_IP_DIR/cn_ip.list.tmp")" -ge 8000 ]; then
				mv "$CN_IP_DIR/cn_ip.list.tmp" "$CN_IP_DIR/cn_ip.list"
				date -u +%Y-%m-%d > "$CN_IP_DIR/cn_ip.ver"
				echo "Pre-seeded cn_ip.list"
			else
				rm -f "$CN_IP_DIR/cn_ip.list.tmp"
			fi
		fi
	else
		echo "HomeProxy patches FAILED! Aborting build." >&2
		exit 1
	fi
fi
