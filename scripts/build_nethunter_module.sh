#!/bin/bash
# scripts/build_nethunter_module.sh
# Usage: ./build_nethunter_module.sh <path_to_ko_files> <device_name>

KO_DIR=$1
DEVICE_NAME=${2:-"Generic"}
MODULE_DIR="ksu_nethunter_module"

echo ">>> Constructing NetHunter KernelSU Module for $DEVICE_NAME..."

# 1. Create the single, working vendor firmware overlay directory
mkdir -p "$MODULE_DIR/system/vendor/firmware"

# 2. Fetch official firmware directly from upstream into the vendor directory
echo "  -> Fetching MediaTek & Atheros firmware..."
curl -sL "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/mediatek/mt7662.bin" -o "$MODULE_DIR/system/vendor/firmware/mt7662.bin"
curl -sL "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/mediatek/mt7662_rom_patch.bin" -o "$MODULE_DIR/system/vendor/firmware/mt7662_rom_patch.bin"
curl -sL "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/htc_9271.fw" -o "$MODULE_DIR/system/vendor/firmware/htc_9271.fw"
curl -sL "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/htc_7010.fw" -o "$MODULE_DIR/system/vendor/firmware/htc_7010.fw"
curl -sL "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/carl9170-1.fw" -o "$MODULE_DIR/system/vendor/firmware/carl9170-1.fw"

# 3. Inject firmware into ALL known Android GKI paths to bypass vendor lockouts
for FW_DIR in "$MODULE_DIR/system/etc/firmware" "$MODULE_DIR/system/vendor/firmware"; do
    cp /tmp/htc_*.fw "$FW_DIR/" 2>/dev/null || true
    cp /tmp/carl9170*.fw "$FW_DIR/" 2>/dev/null || true
    cp /tmp/mt7662*.bin "$FW_DIR/" 2>/dev/null || true
    # Also drop MediaTek into the subfolders just in case
    cp /tmp/mt7662*.bin "$FW_DIR/mediatek/" 2>/dev/null || true
done

# 4. Copy all compiled drivers into the root of the module
echo "  -> Injecting compiled drivers..."
cp "$KO_DIR"/*.ko "$MODULE_DIR/" 2>/dev/null || true

# 5. Generate module.prop
cat << EOF > "$MODULE_DIR/module.prop"
id=nethunter-drivers-${DEVICE_NAME,,}
name=NetHunter Wireless & SDR Drivers ($DEVICE_NAME)
version=v1.0
versionCode=1
author=Shoey
description=Systemless NetHunter drivers (ALFA MT7612U, Atheros, RTL-SDR, BT) with Action Button control.
EOF

# 6. Generate service.sh (Disabled autoload)
cat << 'EOF' > "$MODULE_DIR/service.sh"
#!/system/bin/sh
MODDIR=${0%/*}
# Auto-load disabled. The Action button is in full control.
EOF

# 7. Generate action.sh (The Spines-First Topology & Bootloop Safe Unloader)
cat << 'EOF' > "$MODULE_DIR/action.sh"
#!/system/bin/sh
MODDIR=${0%/*}

if ip link show 2>/dev/null | grep -qE "(wlan1|wlan2|wlan3).*UP"; then
    echo "NetHunter stack being de-activated..."
    ip link set wlan1 down 2>/dev/null
    ip link set wlan2 down 2>/dev/null
    ip link set wlan3 down 2>/dev/null
    sleep 1
    echo "[SUCCESS!] Interfaces dropped. Modules kept in memory to prevent kernel panic."
else
    echo "NetHunter stack being activated..."

    # 1. CORE SUBSYSTEM SPINES (Load bottom-level dependencies first)
    insmod "$MODDIR/libarc4.ko" 2>/dev/null || true
    insmod "$MODDIR/bluetooth.ko" 2>/dev/null || true
    insmod "$MODDIR/btmtk.ko" 2>/dev/null || true
    insmod "$MODDIR/btbcm.ko" 2>/dev/null || true
    insmod "$MODDIR/btrtl.ko" 2>/dev/null || true
    insmod "$MODDIR/btintel.ko" 2>/dev/null || true
    insmod "$MODDIR/rfkill.ko" 2>/dev/null || true
    insmod "$MODDIR/cfg80211.ko" 2>/dev/null || true
    insmod "$MODDIR/mac80211.ko" 2>/dev/null || true
    insmod "$MODDIR/dvb-core.ko" 2>/dev/null || true
    insmod "$MODDIR/dvb_usb_v2.ko" 2>/dev/null || true
    insmod "$MODDIR/i2c-mux.ko" 2>/dev/null || true

    # 2. HARDWARE & ADAPTER DRIVERS (Now safe to load in one pass)
    for ko in "$MODDIR"/*.ko; do
        [ -f "$ko" ] && insmod "$ko" 2>/dev/null || true
    done

    # 3. HARDWARE BINDING
    echo "0e8d 7612" > /sys/bus/usb/drivers/mt76x2u/new_id 2>/dev/null || true
    
    sleep 1
    ip link set wlan1 up 2>/dev/null
    ip link set wlan2 up 2>/dev/null
    ip link set wlan3 up 2>/dev/null
    echo "[SUCCESS!] Stack armed."
fi
EOF

# 8. Generate customize.sh (KSU flashing UI)
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
