#!/usr/bin/env bash
cd common

echo ">>> Integrating WireGuard into GKI..."

# Path to the GKI defconfig (adjust based on your specific architecture if needed)
DEFCONFIG="arch/arm64/configs/gki_defconfig"

# Enable WireGuard and required dependencies
echo "CONFIG_WIREGUARD=y" >> $DEFCONFIG
echo "CONFIG_NET_UDP_TUNNEL=y" >> $DEFCONFIG

# Optional: Enable WireGuard Debugging for dmesg logs
# echo "CONFIG_WIREGUARD_DEBUG=y" >> $DEFCONFIG

echo ">>> WireGuard integration complete."
cd ..
