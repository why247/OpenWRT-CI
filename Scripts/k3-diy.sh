#!/bin/bash
# K3 DIY script for OpenWRT-CI
# 调用方式: 在 Scripts/Packages.sh 或 Scripts/Handles.sh 末尾添加:
#   bash $GITHUB_WORKSPACE/Scripts/k3-diy.sh
# 注意: WRT-CORE 在 ./wrt/ 目录下调用 Scripts，所以相对路径是 ./wrt/ 下的

set -e

echo "=== K3 DIY: WiFi firmware (asus-dhd24) ==="
FW_DIR="package/firmware/brcmfmac4366c0-firmware-k3/files"
if [ ! -d "$FW_DIR" ]; then
	echo "WARNING: $FW_DIR not found, skipping WiFi firmware replacement"
else
	wget -nv https://github.com/Hill-98/phicommk3-firmware/raw/master/brcmfmac4366c-pcie.bin.asus-dhd24 -O /tmp/brcmfmac4366c-pcie.bin
	# Verify size (951031 bytes)
	SIZE=$(stat -c%s /tmp/brcmfmac4366c-pcie.bin)
	if [ "$SIZE" != "951031" ]; then
		echo "ERROR: WiFi firmware size mismatch ($SIZE != 951031), aborting!"
		exit 1
	fi
	cp /tmp/brcmfmac4366c-pcie.bin "$FW_DIR/brcmfmac4366c-pcie.bin"
	echo "WiFi firmware replaced OK"
fi

echo "=== K3 DIY: Screen driver (yangxu52) ==="
# Remove stock screen packages (if present)
rm -rf feeds/packages/utils/phicomm-k3screenctrl package/feeds/packages/phicomm-k3screenctrl 2>/dev/null || true
rm -rf feeds/luci/applications/luci-app-k3screenctrl 2>/dev/null || true
# Clone yangxu52 versions (only if not already present)
mkdir -p package/k3custom
if [ ! -d "package/k3custom/k3screenctrl" ]; then
	git clone --depth 1 https://github.com/yangxu52/k3screenctrl_build.git package/k3custom/k3screenctrl
fi
if [ ! -d "package/k3custom/luci-app-k3screenctrl" ]; then
	git clone --depth 1 https://github.com/yangxu52/luci-app-k3screenctrl.git package/k3custom/luci-app-k3screenctrl
fi
echo "Screen driver replaced OK"

echo "=== K3 DIY: Done ==="
