#!/bin/bash
# scripts/build_nethunter_module.sh
# Usage: ./build_nethunter_module.sh <path_to_ko_files> <device_name>

KO_DIR=$1
DEVICE_NAME=${2:-"Generic"}
MODULE_DIR="ksu_nethunter_module"
FW_STAGING="fw_staging"

echo ">>> Constructing NetHunter KernelSU Module for $DEVICE_NAME..."

# 1. Fetch Full Suite Firmware via Git Sparse-Checkout
echo "  -> Fetching Full Suite Firmware (MediaTek, Atheros, Ralink, Realtek, Broadcom)..."
FW_STAGING="/tmp/fw_staging"
rm -rf "$FW_STAGING"
mkdir -p "$FW_STAGING"
cd "$FW_STAGING"

# Clone ONLY the specific files/folders needed without downloading the gigabytes of history
git clone --depth 1 --filter=blob:none --sparse https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git .
git sparse-checkout set rtlwifi rtl_bt brcm mediatek rt2870.bin rt73.bin rt3290.bin htc_9271.fw htc_7010.fw carl9170-1.fw
cd - > /dev/null

# 2. Inject firmware into ALL known Android GKI paths to bypass vendor lockouts
echo "  -> Injecting firmware into system overlays..."
for FW_DIR in "$MODULE_DIR/system/etc/firmware" "$MODULE_DIR/system/vendor/firmware"; do
    # Create required subdirectories
    mkdir -p "$FW_DIR/mediatek" "$FW_DIR/rtlwifi" "$FW_DIR/rtl_bt" "$FW_DIR/brcm"
    
    # Copy root level firmwares (Atheros & Legacy Ralink)
    cp "$FW_STAGING"/*.fw "$FW_DIR/" 2>/dev/null || true
    cp "$FW_STAGING"/*.bin "$FW_DIR/" 2>/dev/null || true
    
    # Copy directory-level firmwares (Realtek, MediaTek, Broadcom Bluetooth)
    cp -r "$FW_STAGING/rtlwifi/"* "$FW_DIR/rtlwifi/" 2>/dev/null || true
    cp -r "$FW_STAGING/rtl_bt/"* "$FW_DIR/rtl_bt/" 2>/dev/null || true
    cp -r "$FW_STAGING/brcm/"* "$FW_DIR/brcm/" 2>/dev/null || true
    cp -r "$FW_STAGING/mediatek/"* "$FW_DIR/mediatek/" 2>/dev/null || true
done

# Cleanup
rm -rf "$FW_STAGING"

# 3. Copy all compiled drivers into the root of the module
echo "  -> Injecting compiled drivers..."
cp "$KO_DIR"/*.ko "$MODULE_DIR/" 2>/dev/null || true

# 4. Generate module.prop
cat << EOF > "$MODULE_DIR/module.prop"
id=nethunter-drivers-${DEVICE_NAME,,}
name=NetHunter Wireless & SDR Drivers ($DEVICE_NAME)
version=v1.0
versionCode=1
author=Shoey
description=Systemless NetHunter drivers (ALFA MT7612U, Atheros, RTL-SDR, BT) with Action Button control.
EOF

# 5. Generate service.sh (Disabled autoload)
cat << 'EOF' > "$MODULE_DIR/service.sh"
#!/system/bin/sh
MODDIR=${0%/*}
# Auto-load disabled. The Action button is in full control.
EOF

# 6. Generate action.sh (The Spines-First Topology & Bootloop Safe Unloader)
cat << 'EOF' > "$MODULE_DIR/action.sh"
#!/system/bin/sh
MODDIR=${0%/*}

if ip link show 2>/dev/null | grep -qE "(wlan1|wlan2|wlan3|eth0|eth1|usb0).*UP"; then
    echo "NetHunter stack being de-activated..."
    ip link set wlan1 down 2>/dev/null
    ip link set wlan2 down 2>/dev/null
    ip link set wlan3 down 2>/dev/null
    ip link set eth0 down 2>/dev/null
    ip link set usb0 down 2>/dev/null
    sleep 1
    echo "[SUCCESS!] Interfaces dropped. Modules kept in memory to prevent kernel panic."
else
    echo "NetHunter stack being activated..."

    # 1. CORE SUBSYSTEM SPINES 
    insmod "$MODDIR/bluetooth.ko" 2>/dev/null || true
    insmod "$MODDIR/btmtk.ko" 2>/dev/null || true
    insmod "$MODDIR/btbcm.ko" 2>/dev/null || true
    insmod "$MODDIR/btrtl.ko" 2>/dev/null || true
    insmod "$MODDIR/btintel.ko" 2>/dev/null || true
    insmod "$MODDIR/cfg80211.ko" 2>/dev/null || true
    insmod "$MODDIR/mac80211.ko" 2>/dev/null || true
    insmod "$MODDIR/dvb-core.ko" 2>/dev/null || true
    insmod "$MODDIR/dvb_usb_v2.ko" 2>/dev/null || true
    insmod "$MODDIR/i2c-mux.ko" 2>/dev/null || true

    # 2. ATHEROS & MEDIATEK CHAINS (Explicit Priority)
    # Atheros
    insmod "$MODDIR/ath.ko" 2>/dev/null || true
    insmod "$MODDIR/ath9k_hw.ko" 2>/dev/null || true
    insmod "$MODDIR/ath9k_common.ko" 2>/dev/null || true
    insmod "$MODDIR/ath9k_htc.ko" 2>/dev/null || true
    insmod "$MODDIR/carl9170.ko" 2>/dev/null || true
    
    # MediaTek
    insmod "$MODDIR/mt76.ko" 2>/dev/null || true
    insmod "$MODDIR/mt76-usb.ko" 2>/dev/null || true
    insmod "$MODDIR/mt76x02-lib.ko" 2>/dev/null || true
    insmod "$MODDIR/mt76x02-usb.ko" 2>/dev/null || true
    insmod "$MODDIR/mt76x2-common.ko" 2>/dev/null || true
    insmod "$MODDIR/mt76x2u.ko" 2>/dev/null || true
    
    # 2.5 LEGACY WI-FI & BLUETOOTH
    insmod "$MODDIR/btusb.ko" 2>/dev/null || true
    insmod "$MODDIR/rt2x00lib.ko" 2>/dev/null || true
    insmod "$MODDIR/rt2x00usb.ko" 2>/dev/null || true
    insmod "$MODDIR/rt2800lib.ko" 2>/dev/null || true
    insmod "$MODDIR/rt2800usb.ko" 2>/dev/null || true
    insmod "$MODDIR/eeprom_93cx6.ko" 2>/dev/null || true
    insmod "$MODDIR/rtl8187.ko" 2>/dev/null || true
    insmod "$MODDIR/rtl8xxxu.ko" 2>/dev/null || true
    
    # 3. USB ETHERNET ADAPTERS (Wired Sniffing)
    insmod "$MODDIR/usbnet.ko" 2>/dev/null || true
    insmod "$MODDIR/cdc_ether.ko" 2>/dev/null || true
    insmod "$MODDIR/rndis_host.ko" 2>/dev/null || true
    insmod "$MODDIR/ax88179_178a.ko" 2>/dev/null || true
    insmod "$MODDIR/asix.ko" 2>/dev/null || true
    insmod "$MODDIR/r8152.ko" 2>/dev/null || true
    
    # 3.5. CARSENAL & USB SERIAL
    insmod "$MODDIR/can.ko" 2>/dev/null || true
    insmod "$MODDIR/can-dev.ko" 2>/dev/null || true
    insmod "$MODDIR/can-raw.ko" 2>/dev/null || true
    insmod "$MODDIR/can-bcm.ko" 2>/dev/null || true
    insmod "$MODDIR/can-gw.ko" 2>/dev/null || true
    insmod "$MODDIR/vcan.ko" 2>/dev/null || true
    insmod "$MODDIR/slcan.ko" 2>/dev/null || true
    insmod "$MODDIR/gs_usb.ko" 2>/dev/null || true
    
    insmod "$MODDIR/usbserial.ko" 2>/dev/null || true
    insmod "$MODDIR/cp210x.ko" 2>/dev/null || true
    insmod "$MODDIR/ftdi_sio.ko" 2>/dev/null || true
    insmod "$MODDIR/pl2303.ko" 2>/dev/null || true
    insmod "$MODDIR/ch341.ko" 2>/dev/null || true
    
    # 4. SDR FRONTENDS & TUNERS 
    # Load everything EXCEPT the USB bridges first to build the SDR foundations
    for ko in "$MODDIR"/*.ko; do
        [[ "$ko" == *"usb"* ]] && continue
        [ -f "$ko" ] && insmod "$ko" 2>/dev/null || true
    done

    # 5. SDR USB BRIDGES
    # Load these last so they can successfully hook into the frontends from Step 4
    for ko in "$MODDIR"/*usb*.ko; do
        [ -f "$ko" ] && insmod "$ko" 2>/dev/null || true
    done

    # 6. HARDWARE BINDING (With race-condition safeguard)
    sleep 1
    echo "0e8d 7612" > /sys/bus/usb/drivers/mt76x2u/new_id 2>/dev/null || true

    sleep 1
    ip link set wlan1 up 2>/dev/null
    ip link set wlan2 up 2>/dev/null
    ip link set wlan3 up 2>/dev/null
    ip link set eth0 up 2>/dev/null
    ip link set usb0 up 2>/dev/null
    echo "[SUCCESS!] Stack armed."
fi
EOF

# 7. Generate customize.sh (KSU flashing UI)
# Using unquoted EOF to expand DEVICE_NAME, but escaping MODPATH
cat << EOF > "$MODULE_DIR/customize.sh"
#!/system/bin/sh
ui_print "- Installing NetHunter Driver Stack..."
ui_print "- Device: $DEVICE_NAME"
ui_print "- Setting permissions..."
set_perm_recursive "\$MODPATH" 0 0 0755 0644
set_perm "\$MODPATH/action.sh" 0 0 0755
set_perm "\$MODPATH/service.sh" 0 0 0755
ui_print "- Ready for OTG injection."
EOF

# Make shell scripts executable
chmod +x "$MODULE_DIR"/*.sh

echo ">>> KernelSU Module structure complete!"
