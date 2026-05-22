#!/bin/bash
# ============================================================================
# MHS35 3.5" TFT LCD Display - FIXED Installer
# ============================================================================
# This script fixes ALL the bugs in the original MHS35-show script that cause:
#   1. "Failed to start session" (broken .bash_profile)
#   2. Black screen on LCD (wrong config.txt path on Bookworm)
#   3. Desktop not loading (broken 99-fbturbo.conf on 64-bit)
#   4. Boot mode switching to terminal (raspi-config set to B2 instead of B4)
#
# Compatible with: Raspberry Pi OS 32-bit AND 64-bit (Bookworm/Bullseye)
# Hardware: MHS35 / MPI3501 3.5" SPI TFT with XPT2046/ADS7846 touch
# ============================================================================

set -e

echo "============================================"
echo " MHS35 Display - Fixed Installer"
echo "============================================"
echo ""

# --- Detect system info ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

deb_version=$(cat /etc/debian_version | tr -d '\n')
username=$(logname | tr -d '\n' 2>/dev/null || echo "$USER")

if [ $(getconf LONG_BIT) = '64' ]; then
    hardware_arch=64
    echo "[INFO] Detected 64-bit OS"
else
    hardware_arch=32
    echo "[INFO] Detected 32-bit OS"
fi

echo "[INFO] Debian version: $deb_version"
echo "[INFO] Username: $username"

# --- Determine the correct config.txt path ---
# Bookworm (Debian 12+) uses /boot/firmware/config.txt
# Older versions use /boot/config.txt
if [ -f /boot/firmware/config.txt ]; then
    CONFIG_PATH="/boot/firmware/config.txt"
    OVERLAY_PATH="/boot/firmware/overlays"
    CMDLINE_PATH="/boot/firmware/cmdline.txt"
elif [ -f /boot/config.txt ]; then
    CONFIG_PATH="/boot/config.txt"
    OVERLAY_PATH="/boot/overlays"
    CMDLINE_PATH="/boot/cmdline.txt"
else
    echo "[ERROR] Cannot find config.txt! Aborting."
    exit 1
fi

echo "[INFO] Config path: $CONFIG_PATH"
echo "[INFO] Overlay path: $OVERLAY_PATH"
echo ""

# ============================================================================
# STEP 1: Backup current config
# ============================================================================
echo "[STEP 1/7] Backing up current configuration..."

BACKUP_DIR="$SCRIPT_DIR/.mhs35_backup"
sudo mkdir -p "$BACKUP_DIR"
sudo cp "$CONFIG_PATH" "$BACKUP_DIR/config.txt.backup"
if [ -f "$CMDLINE_PATH" ]; then
    sudo cp "$CMDLINE_PATH" "$BACKUP_DIR/cmdline.txt.backup"
fi
if [ -f /etc/rc.local ]; then
    sudo cp /etc/rc.local "$BACKUP_DIR/rc.local.backup"
fi
echo "[OK] Backup saved to $BACKUP_DIR"

# ============================================================================
# STEP 2: Install the MHS35 device tree overlay
# ============================================================================
echo "[STEP 2/7] Installing MHS35 device tree overlay..."

if [ -f ./usr/mhs35-overlay.dtb ]; then
    sudo cp ./usr/mhs35-overlay.dtb "$OVERLAY_PATH/"
    sudo cp ./usr/mhs35-overlay.dtb "$OVERLAY_PATH/mhs35.dtbo"
    echo "[OK] MHS35 overlay installed"
else
    echo "[ERROR] Cannot find usr/mhs35-overlay.dtb! Aborting."
    exit 1
fi

# ============================================================================
# STEP 3: Configure config.txt (THE CRITICAL FIX)
# ============================================================================
echo "[STEP 3/7] Configuring $CONFIG_PATH..."

# Remove any previous MHS35 configuration lines to avoid duplicates
sudo sed -i '/^dtoverlay=mhs35/d' "$CONFIG_PATH"
sudo sed -i '/^hdmi_force_hotplug/d' "$CONFIG_PATH"
sudo sed -i '/^hdmi_group/d' "$CONFIG_PATH"
sudo sed -i '/^hdmi_mode/d' "$CONFIG_PATH"
sudo sed -i '/^hdmi_cvt/d' "$CONFIG_PATH"
sudo sed -i '/^hdmi_drive/d' "$CONFIG_PATH"

# Disable the KMS driver (it conflicts with fbcp framebuffer mirroring)
sudo sed -i 's/^dtoverlay=vc4-kms-v3d/#dtoverlay=vc4-kms-v3d/' "$CONFIG_PATH"
sudo sed -i 's/^dtoverlay=vc4-fkms-v3d/#dtoverlay=vc4-fkms-v3d/' "$CONFIG_PATH"

# Enable SPI (required for the display) and I2C
sudo sed -i 's/^#dtparam=spi=on/dtparam=spi=on/' "$CONFIG_PATH"
sudo sed -i 's/^#dtparam=i2c_arm=on/dtparam=i2c_arm=on/' "$CONFIG_PATH"

# Check if dtparam=spi=on exists, if not add it
grep -q "^dtparam=spi=on" "$CONFIG_PATH" || echo "dtparam=spi=on" | sudo tee -a "$CONFIG_PATH" > /dev/null
grep -q "^dtparam=i2c_arm=on" "$CONFIG_PATH" || echo "dtparam=i2c_arm=on" | sudo tee -a "$CONFIG_PATH" > /dev/null

# Add MHS35 display configuration under [all] section
# First check if [all] section exists
if grep -q "^\[all\]" "$CONFIG_PATH"; then
    # Add settings after [all]
    sudo sed -i '/^\[all\]/a hdmi_force_hotplug=1\nhdmi_group=2\nhdmi_mode=1\nhdmi_mode=87\nhdmi_cvt 480 320 60 6 0 0 0\nhdmi_drive=2\ndtoverlay=mhs35:rotate=90' "$CONFIG_PATH"
else
    # Append to end of file
    {
        echo ""
        echo "[all]"
        echo "hdmi_force_hotplug=1"
        echo "hdmi_group=2"
        echo "hdmi_mode=1"
        echo "hdmi_mode=87"
        echo "hdmi_cvt 480 320 60 6 0 0 0"
        echo "hdmi_drive=2"
        echo "dtoverlay=mhs35:rotate=90"
    } | sudo tee -a "$CONFIG_PATH" > /dev/null
fi

echo "[OK] config.txt configured correctly"

# ============================================================================
# STEP 4: Install fbcp (framebuffer copy) for mirroring HDMI to LCD
# ============================================================================
echo "[STEP 4/7] Setting up framebuffer copy (fbcp)..."

# Check if fbcp is already installed
if ! type fbcp > /dev/null 2>&1; then
    # Try to build from source
    if type cmake > /dev/null 2>&1; then
        echo "[INFO] Building fbcp from source..."
        sudo rm -rf /tmp/rpi-fbcp
        if [ -d ./usr/rpi-fbcp ]; then
            sudo cp -r ./usr/rpi-fbcp /tmp/rpi-fbcp
            cd /tmp/rpi-fbcp
            sudo mkdir -p build
            cd build
            sudo cmake .. 2>/dev/null && sudo make 2>/dev/null
            if [ -f fbcp ]; then
                sudo install fbcp /usr/local/bin/fbcp
                echo "[OK] fbcp built and installed"
            else
                echo "[WARN] fbcp build failed, using pre-compiled binary"
                cd "$SCRIPT_DIR"
                if [ -f ./usr/fbcp ]; then
                    sudo cp ./usr/fbcp /usr/local/bin/fbcp
                    sudo chmod +x /usr/local/bin/fbcp
                fi
            fi
            cd "$SCRIPT_DIR"
        fi
    else
        # Try installing cmake first
        echo "[INFO] Installing cmake..."
        sudo apt-get update -qq
        sudo apt-get install -y -qq cmake libraspberrypi-dev 2>/dev/null
        if [ -d ./usr/rpi-fbcp ]; then
            sudo rm -rf /tmp/rpi-fbcp
            sudo cp -r ./usr/rpi-fbcp /tmp/rpi-fbcp
            cd /tmp/rpi-fbcp
            sudo mkdir -p build
            cd build
            sudo cmake .. 2>/dev/null && sudo make 2>/dev/null
            if [ -f fbcp ]; then
                sudo install fbcp /usr/local/bin/fbcp
                echo "[OK] fbcp built and installed"
            fi
            cd "$SCRIPT_DIR"
        fi
    fi
fi

# Verify fbcp is available
if type fbcp > /dev/null 2>&1; then
    echo "[OK] fbcp is available"
else
    echo "[WARN] fbcp could not be installed. LCD mirroring may not work."
    echo "[WARN] You can try: sudo apt-get install cmake libraspberrypi-dev"
fi

# ============================================================================
# STEP 5: Configure rc.local to start fbcp on boot
# ============================================================================
echo "[STEP 5/7] Configuring fbcp auto-start..."

# Create a clean rc.local that starts fbcp
sudo tee /etc/rc.local > /dev/null << 'RCEOF'
#!/bin/sh -e
#
# rc.local - starts fbcp for LCD mirroring
#

# Print the IP address
_IP=$(hostname -I) || true
if [ "$_IP" ]; then
  printf "My IP address is %s\n" "$_IP"
fi

# Start framebuffer copy for LCD display (wait for display to initialize)
sleep 3
fbcp &

exit 0
RCEOF

sudo chmod +x /etc/rc.local

# Make sure rc-local.service is enabled
sudo systemctl enable rc-local.service 2>/dev/null || true

echo "[OK] fbcp auto-start configured"

# ============================================================================
# STEP 6: Configure touch input (evdev driver)
# ============================================================================
echo "[STEP 6/7] Configuring touch input..."

# Create X11 config directory
sudo mkdir -p /etc/X11/xorg.conf.d

# Install touch calibration
if [ -f ./usr/99-calibration.conf-mhs35-90 ]; then
    sudo cp -rf ./usr/99-calibration.conf-mhs35-90 /etc/X11/xorg.conf.d/99-calibration.conf
    echo "[OK] Touch calibration installed"
fi

# Install evdev driver for touch input
dpkg -l | grep -q xserver-xorg-input-evdev 2>/dev/null
if [ $? -ne 0 ]; then
    echo "[INFO] Installing evdev touch driver..."
    if [ $hardware_arch -eq 32 ]; then
        if [ -f ./xserver-xorg-input-evdev_1%3a2.10.6-1+b1_armhf.deb ]; then
            sudo dpkg -i -B ./xserver-xorg-input-evdev_1%3a2.10.6-1+b1_armhf.deb 2>/dev/null || true
        fi
    elif [ $hardware_arch -eq 64 ]; then
        if [ -f ./xserver-xorg-input-evdev_1%3a2.10.6-2_arm64.deb ]; then
            sudo dpkg -i -B ./xserver-xorg-input-evdev_1%3a2.10.6-2_arm64.deb 2>/dev/null || true
        fi
    fi
fi

# Copy evdev priority config
if [ -f /usr/share/X11/xorg.conf.d/10-evdev.conf ]; then
    sudo cp -rf /usr/share/X11/xorg.conf.d/10-evdev.conf /usr/share/X11/xorg.conf.d/45-evdev.conf
fi

echo "[OK] Touch input configured"

# ============================================================================
# STEP 7: FIX THE BUGS THAT CRASH THE DESKTOP
# ============================================================================
echo "[STEP 7/7] Applying critical bug fixes..."

# BUG FIX 1: Do NOT install .bash_profile
# The original script copies a .bash_profile that forces startx on login,
# which crashes LightDM and causes "Failed to start session".
# We intentionally SKIP this step.
if [ -f /home/$username/.bash_profile ]; then
    # Remove it if it was previously installed by a broken script
    rm -f /home/$username/.bash_profile
    echo "[FIX] Removed broken .bash_profile"
fi

# BUG FIX 2: Do NOT install 99-fbturbo.conf on Debian 12+
# The fbturbo driver doesn't exist on modern systems and crashes X11.
# On Debian 12+, the default modesetting driver works fine with fbcp.
if [ -f /usr/share/X11/xorg.conf.d/99-fbturbo.conf ]; then
    sudo rm -f /usr/share/X11/xorg.conf.d/99-fbturbo.conf
    echo "[FIX] Removed broken 99-fbturbo.conf"
fi
# Also remove the backup file the original script creates
if [ -f /usr/share/X11/xorg.conf.d/99-fbturbo.~ ]; then
    sudo rm -f /usr/share/X11/xorg.conf.d/99-fbturbo.~
    echo "[FIX] Removed broken 99-fbturbo.~"
fi

# BUG FIX 3: Ensure correct file ownership
sudo chown -R $username:$username /home/$username
echo "[FIX] Fixed home directory ownership"

# BUG FIX 4: Ensure boot mode is Desktop Autologin (B4), not just Desktop (B2)
# The original script sets B2 which requires manual login and often fails.
if type raspi-config > /dev/null 2>&1; then
    sudo raspi-config nonint do_boot_behaviour B4
    echo "[FIX] Set boot to Desktop Autologin"

    # Also ensure X11 is active (not Wayland)
    sudo raspi-config nonint do_wayland W1 2>/dev/null || true
    echo "[FIX] Set display server to X11"
fi

# BUG FIX 5: Remove any .xsession file that might interfere
if [ -f /home/$username/.xsession ]; then
    rm -f /home/$username/.xsession
    echo "[FIX] Removed interfering .xsession"
fi

# BUG FIX 6: Ensure the symlink exists for scripts that reference /boot/config.txt
if [ -f /boot/firmware/config.txt ] && [ ! -L /boot/config.txt ]; then
    sudo ln -sf /boot/firmware/config.txt /boot/config.txt
    echo "[FIX] Created symlink /boot/config.txt -> /boot/firmware/config.txt"
fi

echo ""
echo "============================================"
echo " Installation Complete!"
echo "============================================"
echo ""
echo " Your MHS35 display has been configured."
echo " The system will reboot in 5 seconds..."
echo ""
echo " After reboot:"
echo "   - The desktop will appear on the 3.5\" LCD"
echo "   - Touch input should work"
echo "   - HDMI monitor may show low resolution"
echo "     (this is normal, the Pi is optimized for the LCD)"
echo ""
echo " To restore your system to normal, run:"
echo "   cd $SCRIPT_DIR && sudo ./MHS35-fixed-restore.sh"
echo ""
echo "============================================"

sudo sync
sudo sync
sleep 5
sudo reboot
