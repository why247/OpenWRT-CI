# --- AP8220 无线 (2026-10-04) ---
mkdir -p "${WRT_DIR}/files/etc/uci-defaults"
cat > "${WRT_DIR}/files/etc/uci-defaults/99-ap8220-wireless" <<'EOF'
#!/bin/sh
uci -q batch <<'EOU'
set wireless.radio0=wifi-device
set wireless.radio0.type='mac80211'
set wireless.radio0.channel='9'
set wireless.radio0.band='2g'
set wireless.radio0.htmode='HE20'
set wireless.radio0.country='US'
set wireless.radio0.txpower='24'
set wireless.radio0.disabled='0'
set wireless.radio1=wifi-device
set wireless.radio1.type='mac80211'
set wireless.radio1.channel='44'
set wireless.radio1.band='5g'
set wireless.radio1.htmode='HE160'
set wireless.radio1.country='US'
set wireless.radio1.txpower='25'
set wireless.radio1.disabled='0'
commit wireless
EOU
exit 0
EOF
chmod +x "${WRT_DIR}/files/etc/uci-defaults/99-ap8220-wireless"