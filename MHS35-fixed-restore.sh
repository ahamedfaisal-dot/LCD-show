#!/bin/bash
# ============================================================================
# MHS35 3.5" TFT LCD Display - FIXED Restore Script
# ============================================================================
# Restores your Raspberry Pi to its original state (before the LCD was installed)
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

BACKUP_DIR="$SCRIPT_DIR/.mhs35_backup"

echo "============================================"
echo " MHS35 Display - System Restore"
echo "============================================"
echo ""

# Determine config path
if [ -f /boot/firmware/config.txt ]; then
    CONFIG_PATH="/boot/firmware/config.txt"
    OVERLAY_PATH="/boot/firmware/overlays"
elif [ -f /boot/config.txt ]; then
    CONFIG_PATH="/boot/config.txt"
    OVERLAY_PATH="/boot/overlays"
fi

# Restore config.txt from backup
if [ -f "$BACKUP_DIR/config.txt.backup" ]; then
    sudo cp "$BACKUP_DIR/config.txt.backup" "$CONFIG_PATH"
    echo "[OK] Restored config.txt"
else
    echo "[WARN] No config.txt backup found, cleaning manually..."
    # Remove MHS35 lines
    sudo sed -i '/^hdmi_force_hotplug/d' "$CONFIG_PATH"
    sudo sed -i '/^hdmi_group/d' "$CONFIG_PATH"
    sudo sed -i '/^hdmi_mode/d' "$CONFIG_PATH"
    sudo sed -i '/^hdmi_cvt/d' "$CONFIG_PATH"
    sudo sed -i '/^hdmi_drive/d' "$CONFIG_PATH"
    sudo sed -i '/^dtoverlay=mhs35/d' "$CONFIG_PATH"
    # Re-enable KMS driver
    sudo sed -i 's/^#dtoverlay=vc4-kms-v3d/dtoverlay=vc4-kms-v3d/' "$CONFIG_PATH"
fi

# Restore rc.local
if [ -f "$BACKUP_DIR/rc.local.backup" ]; then
    sudo cp "$BACKUP_DIR/rc.local.backup" /etc/rc.local
    echo "[OK] Restored rc.local"
else
    # Create a clean default rc.local
    sudo tee /etc/rc.local > /dev/null << 'EOF'
#!/bin/sh -e
_IP=$(hostname -I) || true
if [ "$_IP" ]; then
  printf "My IP address is %s\n" "$_IP"
fi
exit 0
EOF
    sudo chmod +x /etc/rc.local
    echo "[OK] Created clean rc.local"
fi

# Remove LCD overlay files
sudo rm -f "$OVERLAY_PATH/mhs35-overlay.dtb"
sudo rm -f "$OVERLAY_PATH/mhs35.dtbo"
echo "[OK] Removed LCD overlay"

# Remove touch calibration
sudo rm -f /etc/X11/xorg.conf.d/99-calibration.conf
echo "[OK] Removed touch calibration"

# Remove broken files
sudo rm -f /usr/share/X11/xorg.conf.d/99-fbturbo.conf
sudo rm -f /usr/share/X11/xorg.conf.d/99-fbturbo.~
echo "[OK] Cleaned up X11 configs"

# Set boot to Desktop Autologin
if type raspi-config > /dev/null 2>&1; then
    sudo raspi-config nonint do_boot_behaviour B4
    echo "[OK] Set boot to Desktop Autologin"
fi

echo ""
echo "============================================"
echo " System Restored Successfully!"
echo " Rebooting in 3 seconds..."
echo "============================================"

sudo sync
sleep 3
sudo reboot
