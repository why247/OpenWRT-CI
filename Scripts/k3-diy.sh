#!/bin/bash
# K3 DIY script for OpenWRT-CI (ImmortalWrt 24.10)
# Run after feeds update, before make

set -e

echo "=== K3 DIY: WiFi firmware (asus-dhd24) ==="
FW_DIR="package/firmware/brcmfmac4366c0-firmware-k3/files"
wget -nv https://github.com/Hill-98/phicommk3-firmware/raw/master/brcmfmac4366c-pcie.bin.asus-dhd24 -O /tmp/brcmfmac4366c-pcie.bin
# Verify size (951031 bytes)
SIZE=$(stat -c%s /tmp/brcmfmac4366c-pcie.bin)
if [ "$SIZE" != "951031" ]; then
    echo "ERROR: WiFi firmware size mismatch ($SIZE != 951031), aborting!"
    exit 1
fi
cp /tmp/brcmfmac4366c-pcie.bin "$FW_DIR/brcmfmac4366c-pcie.bin"
echo "WiFi firmware replaced OK"

echo "=== K3 DIY: Screen driver (yangxu52) ==="
# Remove stock screen packages
rm -rf feeds/packages/utils/phicomm-k3screenctrl package/feeds/packages/phicomm-k3screenctrl 2>/dev/null || true
rm -rf feeds/luci/applications/luci-app-k3screenctrl 2>/dev/null || true
# Clone yangxu52 versions
mkdir -p package/k3custom
git clone --depth 1 https://github.com/yangxu52/k3screenctrl_build.git package/k3custom/k3screenctrl
git clone --depth 1 https://github.com/yangxu52/luci-app-k3screenctrl.git package/k3custom/luci-app-k3screenctrl
echo "Screen driver replaced OK"

echo "=== K3 DIY: Done ==="
