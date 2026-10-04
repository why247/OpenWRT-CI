# --- N1 IPv6 + DTB (2026-10-04) ---
if [ -n "$WRT_DIR" ] && [ -d "$WRT_DIR/files" ]; then
  mkdir -p "$WRT_DIR/files/etc/uci-defaults"
  cat > "$WRT_DIR/files/etc/uci-defaults/99-n1-ipv6-off" <<'EOF'
#!/bin/sh
uci -q delete network.wan6 2>/dev/null
uci -q set network.wan.ipv6='0'
uci -q set network.lan.ipv6='0'
uci -q commit network
exit 0
EOF
  chmod +x "$WRT_DIR/files/etc/uci-defaults/99-n1-ipv6-off"
  cat > "$WRT_DIR/files/etc/uci-defaults/99-n1-thresh-dtb" <<'EOF'
#!/bin/sh
UENV=/boot/uEnv.txt
if [ -f "$UENV" ] && ! grep -q "thresh" "$UENV"; then
  cp -f "$UENV" "$UENV.bak.$(date +%Y%m%d)"
  sed -i "s|^FDT=.*|FDT=/dtb/amlogic/meson-gxl-s905d-phicomm-n1-thresh.dtb|" "$UENV"
fi
exit 0
EOF
  chmod +x "$WRT_DIR/files/etc/uci-defaults/99-n1-thresh-dtb"
fi