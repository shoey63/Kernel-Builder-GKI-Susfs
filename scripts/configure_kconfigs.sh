#!/usr/bin/env bash
set -euo pipefail

# Configuration: Toggle custom Kconfig integration via ENV (Defaults to false)
WITH_CUSTOM=${WITH_CUSTOM:-false}

# Define the source fragment relative to the script execution point
FRAGMENT_SRC="$(pwd)/tools/custom.fragment"

echo "=== Configuring Kconfigs & Fragments ==="

cd kernel_workspace

echo ">>> Neutralizing ABI protected exports lists..."
for f in common/android/abi_gki_protected_exports*; do
  [ -f "$f" ] && > "$f"
done

if [ "$WITH_CUSTOM" = "true" ]; then
    if [ ! -f "$FRAGMENT_SRC" ]; then
        echo "[-] Error: Fragment file not found at $FRAGMENT_SRC"
        exit 1
    fi

    echo ">>> Integrating Kconfig Configurations from $FRAGMENT_SRC..."
    cd common
    
    # ========================================================================
    # MODERN BAZEL ECOSYSTEM (Android 13 / Kernel 5.15+)
    # ========================================================================
    if [ -f "BUILD.bazel" ]; then
        echo ">>> Modern Bazel detected: Exposing fragment to Sandbox..."
        
        # Copy the static fragment into the Bazel package boundary
        cp "$FRAGMENT_SRC" custom_fragment
        
        # Instruct Bazel to track the file as a valid build input
        echo 'exports_files(["custom_fragment"])' >> BUILD.bazel
        
        # Exclude the untracked fragment from standard git tracking status
        echo "custom_fragment" >> .git/info/exclude
        
        # --- KERNEL VERSION DETECTION & INJECTION ---
        if grep -q '"trim_nonlisted_kmi"' BUILD.bazel; then
            # ----------------------------------------------------
            # KERNEL 6.6+ (Android 15)
            # ----------------------------------------------------
            echo ">>> Detected 6.6+ Architecture. Applying native defconfig injection..."
            
            # Disable modern module trimming
            sed -i 's/"trim_nonlisted_kmi": True,/"trim_nonlisted_kmi": False,/g' BUILD.bazel
            
            # Inject standard fragment array into the target config dictionary
            sed -i '/"kernel_aarch64": {/a \        "defconfig_fragments": ["custom_fragment"],' BUILD.bazel

        elif grep -q '"kmi_symbol_list_strict_mode"' BUILD.bazel; then
            # ----------------------------------------------------
            # KERNEL 6.1 (Android 14)
            # ----------------------------------------------------
            echo ">>> Detected 6.1 Architecture. Disabling Bazel strict mode..."
            sed -i 's/"kmi_symbol_list_strict_mode": True,/"kmi_symbol_list_strict_mode": False,/g' BUILD.bazel

        else
            # ----------------------------------------------------
            # UNKNOWN/TRANSITIONAL BAZEL (Fallback)
            # ----------------------------------------------------
            echo ">>> Unknown Bazel version detected. Attempting generic build.config injection..."
            cp custom_fragment arch/arm64/configs/custom_wifi.fragment
            echo 'EXTRA_DEFCONFIG_FRAGMENTS+=" custom_wifi.fragment"' >> build.config.gki.aarch64
        fi
        
        # --- THE FINAL BOSS BYPASS (MONOLITHIC MODULE ALIGNMENT) ---
        if [ -f "modules.bzl" ]; then
            echo ">>> Syncing Kleaf's expected module list with monolithic payloads..."
    
            # Define the exact modules we baked into vmlinux via 0002 patch
            BAKED_MODULES=(
                "bluetooth.ko" "hci_uart.ko" "btusb.ko" "btsdio.ko" "btbcm.ko" "btqca.ko" "rfkill.ko" "rfcomm.ko" "bnep.ko" "hidp.ko" "cmtp.ko" "nfc.ko" "nci.ko" "hci.ko"
            )

             # Dynamically erase only our baked modules from the attendance sheet
            for mod in "${BAKED_MODULES[@]}"; do
                sed -i "/$mod/d" modules.bzl
            done
        fi        
        
    # ========================================================================
    # LEGACY MAKE ECOSYSTEM (Kernel 5.10 and older)
    # ========================================================================
    else
        echo ">>> Legacy Make detected (5.10 or older): Copying fragment..."
        cp "$FRAGMENT_SRC" arch/arm64/configs/custom_legacy.fragment
    fi
    
    cd ..
else
    echo ">>> Skipping custom Kconfig configuration..."
fi

cd ..
echo ">>> Kconfig configuration phase complete."
