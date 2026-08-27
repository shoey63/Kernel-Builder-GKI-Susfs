#!/bin/bash
# scripts/build_nethunter_module.sh
# Usage: ./build_nethunter_module.sh <path_to_ko_files> <device_name>

KO_DIR=$1
DEVICE_NAME=${2:-"Generic"}
MODULE_DIR="ksu_nethunter_module"

echo ">>> Constructing NetHunter KernelSU Module for $DEVICE_NAME..."

# 1. Create the absolute directory structure for systemless injection
mkdir -p "$MODULE_DIR/system/etc/firmware/mediatek"

# 2. Curl the official firmware directly from upstream
echo "  -> Fetching MediaTek ALFA (MT7612U) firmware..."
curl -sL "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/mediatek/mt7662.bin" -o "$MODULE_DIR/system/etc/firmware/mediatek/mt7662.bin"
curl -sL "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/mediatek/mt7662_rom_patch.bin" -o "$MODULE_DIR/system/etc/firmware/mediatek/mt7662_rom_patch.bin"

echo "  -> Fetching Atheros (AR9271/AR7010 & AR9170) firmware..."
curl -sL "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/htc_9271.fw" -o "$MODULE_DIR/system/etc/firmware/htc_9271.fw"
curl -sL "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/htc_7010.fw" -o "$MODULE_DIR/system/etc/firmware/htc_7010.fw"
curl -sL "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/carl9170-1.fw" -o "$MODULE_DIR/system/etc/firmware/carl9170-1.fw"

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

# 6. Generate action.sh (The proven multi-pass logic)
cat << 'EOF' > "$MODULE_DIR/action.sh"
#!/system/bin/sh
MODDIR=${0%/*}

if ip link show 2>/dev/null | grep -qE "(wlan1|wlan2).*UP"; then
    echo "NetHunter stack being de-activated..."
    ip link set wlan1 down 2>/dev/null
    ip link set wlan2 down 2>/dev/null
    sleep 1
    
    # Safely unload the entire payload
    rmmod mt76x2u mt76x2_common mt76x02_usb mt76_usb mt76x02_lib mt76 >/dev/null 2>&1
    rmmod ath9k_htc ath9k_common ath9k_hw ath carl9170 >/dev/null 2>&1
    rmmod dvb_usb_rtl28xxu dvb_usb_v2 >/dev/null 2>&1
    rmmod btusb btrtl btintel btbcm btsdio bfusb >/dev/null 2>&1
    rmmod mac80211 cfg80211 >/dev/null 2>&1
    sleep 1
    echo "[SUCCESS!] Stack unloaded."
else
    echo "NetHunter stack being activated..."
    
    # Pre-load the master spines to heavily optimize the brute-force loop
    insmod "$MODDIR/cfg80211.ko" >/dev/null 2>&1
    insmod "$MODDIR/mac80211.ko" >/dev/null 2>&1
    insmod "$MODDIR/dvb_usb_v2.ko" >/dev/null 2>&1
    
    # Execute the forced dependency resolution loop
    for pass in 1 2 3 4; do
        for ko in "$MODDIR"/*.ko; do
            [ -f "$ko" ] && insmod "$ko" >/dev/null 2>&1
        done
    done
    
    # Wake up the MediaTek ALFA AC adapter
    echo "0e8d 7612" > /sys/bus/usb/drivers/mt76x2u/new_id 2>/dev/null || true
    sleep 1
    ip link set wlan1 up 2>/dev/null
    ip link set wlan2 up 2>/dev/null
    sleep 1
    echo "[SUCCESS!] Stack armed."
fi
EOF

# 7. Generate customize.sh (KSU flashing UI)
cat << 'EOF' > "$MODULE_DIR/customize.sh"
#!/system/bin/sh
ui_print "- Installing NetHunter Driver Stack..."
ui_print "- Device: $DEVICE_NAME"
ui_print "- Setting permissions..."
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/service.sh" 0 0 0755
ui_print "- Ready for OTG injection."
EOF

# Make shell scripts executable
chmod +x "$MODULE_DIR"/*.sh

echo ">>> KernelSU Module structure complete!"
