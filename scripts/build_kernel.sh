#!/usr/bin/env bash
set -euo pipefail

WITH_WG=${WITH_WG:-false}

echo "=== Initializing Execution Engine ==="

cd kernel_workspace
mkdir -p ../out out/dist

echo ">>> Marking repo as clean (sanitizes all custom configuration & source modifications)..."
# Dynamically safeguards all modifications 
git -C common ls-files -m | xargs -r git -C common update-index --assume-unchanged

# Build method 
if [ -f "tools/bazel" ]; then
    echo ">>> Modern Kleaf/Bazel ecosystem detected..."
    tools/bazel run --config=local --config=stamp \
      --action_env=SOURCE_DATE_EPOCH="$OFFICIAL_DATE" \
      --action_env=STABLE_BUILD_VERSION="g$OFFICIAL_HASH" \
      --action_env=KLEAF_KERNEL_BUILD_VERSION="g$OFFICIAL_HASH" \
      --action_env=KLEAF_SKIP_ABI_CHECKS=true \
      --action_env=KLEAF_USER=android-build \
      //common:kernel_aarch64_dist \
      -- \
      --destdir=out/dist
else
    echo ">>> Legacy Hermetic Make ecosystem detected (5.10 or older)..."
    
    mkdir -p out/dist
    
    # 1. Export standard environment variables for legacy build.sh
    export KERNEL_DIR="common"
    export BUILD_CONFIG="common/build.config.gki.aarch64"
    export SOURCE_DATE_EPOCH="$OFFICIAL_DATE"
    
    # Inject the fragment
    export EXTRA_DEFCONFIG_FRAGMENTS="custom_legacy.fragment"

    export DIST_DIR="out/dist"
    
    # Inject official hash
    export EXTRA_LINUX_VERSION="-g${OFFICIAL_HASH}"
    
    # 2. Run the legacy orchestration script
    if [ -f "build/build.sh" ]; then
        echo "[+] Invoking build/build.sh..."
        bash build/build.sh
    elif [ -f "build.sh" ]; then
        echo "[+] Invoking build.sh..."
        bash build.sh
    else
        echo "[-] ERROR: Legacy build.sh orchestrator not found!" >&2
        exit 1
    fi
fi

IMAGE_PATH="$(find out/dist -type f -name 'Image' | head -n1)"

if [ -z "${IMAGE_PATH}" ] || [ ! -f "${IMAGE_PATH}" ]; then
  echo "[-] No compilation Image produced!" >&2
  exit 1
fi

echo ">>> Selected Image: ${IMAGE_PATH}"

cp -f "${IMAGE_PATH}" ../out/Image

echo ">>> Extracting kernel runtime version string..."
# Try matching the standard format first, then fall back to a looser grep for legacy banners
KERNEL_VERSION_STRING=$(strings ../out/Image | grep -E "Linux version [0-9]" | head -n 1 || true)

if [ -z "$KERNEL_VERSION_STRING" ]; then
    KERNEL_VERSION_STRING=$(strings ../out/Image | grep -i "Linux version" | head -n 1 || true)
fi

if [ -n "$KERNEL_VERSION_STRING" ]; then
    echo "    $KERNEL_VERSION_STRING"
else
    echo "    [!] Notice: Could not read raw banner string directly from compiled Image binary."
fi

if [ "$WITH_WG" = "true" ]; then
    # Group the dashboard inside an expandable GitHub Actions log section
    echo "::group::WireGuard & Hardware Crypto Injection Report"
    echo ""
    echo "=============================================="
    echo " WIREGUARD & HARDWARE CRYPTO INJECTION REPORT "
    echo "=============================================="

    # Locate the definitive compiled configuration source
    CONFIG_SRC=""
    if [ -f "out/dist/config.gz" ]; then
        CONFIG_SRC="out/dist/config.gz"
    elif [ -f "kernel_workspace/out/dist/config.gz" ]; then
        CONFIG_SRC="kernel_workspace/out/dist/config.gz"
    else
        # Fallback to inspecting build-tree artifacts if distribution archive isn't ready
        CONFIG_SRC=$(find out/ kernel_workspace/out/ -type f -name ".config" 2>/dev/null | head -n 1 || true)
    fi

    if [ -z "$CONFIG_SRC" ]; then
        echo "[!] CRITICAL ERROR: Could not locate compiled kernel configuration target."
        echo "::endgroup::"
        exit 1
    fi

    echo ">>> Extracting definitions from: $CONFIG_SRC"
    echo "----------------------------------------------"

    # Target features list to cross-check
    REQUIRED_CONFIGS=(
        "CONFIG_WIREGUARD"
        "CONFIG_NET_UDP_TUNNEL"
        "CONFIG_CRYPTO_CHACHA20_NEON"
        "CONFIG_CRYPTO_POLY1305_NEON"
        "CONFIG_NETFILTER_XT_MATCH_HASHLIMIT"
        "CONFIG_NETFILTER_XT_MATCH_LENGTH"
        "CONFIG_NETFILTER_XT_MATCH_MARK"
        "CONFIG_NETFILTER_XT_MATCH_POLICY"
    )

    FAILED_VALIDATION=0

    for CFG in "${REQUIRED_CONFIGS[@]}"; do
        # Extract setting state whether compressed or plain text
        if [[ "$CONFIG_SRC" == *.gz ]]; then
            VAL=$(zcat "$CONFIG_SRC" | grep -E "^${CFG}=" | cut -d'=' -f2 || true)
        else
            VAL=$(grep -E "^${CFG}=" "$CONFIG_SRC" | cut -d'=' -f2 || true)
        fi

        if [ "$VAL" = "y" ]; then
            printf "  [ PASS ] %-40s = %s (Built-in)\n" "$CFG" "$VAL"
        elif [ "$VAL" = "m" ]; then
            printf "  [ WARN ] %-40s = %s (Module Option)\n" "$CFG" "$VAL"
        else
            printf "  [ FAIL ] %-40s = MISSING\n" "$CFG"
            # Hard-fail only on core engine; degrade optimizations to soft warnings
            if [ "$CFG" = "CONFIG_WIREGUARD" ] || [ "$CFG" = "CONFIG_NET_UDP_TUNNEL" ]; then
                FAILED_VALIDATION=1
            fi
        fi
    done

    echo "=============================================="

    if [ "$FAILED_VALIDATION" -ne 0 ]; then
        echo "[!] PIPELINE FAILURE: Core WireGuard variables dropped during compilation."
        echo "::endgroup::"
        exit 1
    fi
    
    echo "[+] Pipeline successfully validated. Ready for distribution packaging."
    echo ""
    echo "::endgroup::"
fi

cd ..
echo ">>> Build execution loop completed"

