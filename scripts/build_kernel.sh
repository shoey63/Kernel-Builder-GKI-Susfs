#!/usr/bin/env bash
set -euo pipefail

WITH_WG=${WITH_WG:-false}

echo "=== Initializing Bazel Execution Engine ==="

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

echo ">>> Extracting version string..."
strings ../out/Image | grep "Linux version" | head -n 1

if [ "$WITH_WG" = "true" ]; then
    # verify wireguard core#
    echo ">>> Validating custom WireGuard & Hardware Crypto pipeline..."
    if ! strings ../out/Image | grep -qi "wireguard"; then
        echo "[-] ERROR: Core WireGuard engine missing from binary!" >&2
        exit 1
    fi
    # confirm NEON flags
    if strings ../out/Image | grep -qE "chacha_neon|poly1305_blocks_neon"; then
        echo ">>> SUCCESS: WireGuard NEON hardware crypto acceleration validated!"
    else
        echo "[-] WARNING: Core WireGuard present, but NEON hardware crypto symbols missing." >&2
        echo "    Your custom Kconfig fragments may have failed to layer onto Bazel." >&2
        exit 1
    fi
fi

cd ..
echo ">>> Build execution loop completed"
