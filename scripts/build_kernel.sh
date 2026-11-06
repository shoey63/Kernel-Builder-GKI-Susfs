#!/usr/bin/env bash
# scripts/build_kernel.sh
set -euo pipefail

ENABLE_NOMOUNT=${ENABLE_NOMOUNT:-false}
ENABLE_NET_OPTS=${ENABLE_NET_OPTS:-false}
BASE_VER=${BASE_VER:-}

echo "=== Initializing Execution Engine ==="

cd kernel_workspace
mkdir -p ../out out/dist

# Format exact UTC timestamp string (e.g. "Thu Sep  3 03:59:00 UTC 2026")
BUILD_TIMESTAMP="$(LC_ALL=C date -u -d "@${OFFICIAL_DATE}" '+%a %b %e %H:%M:%S UTC %Y')"
echo ">>> Target Build Timestamp: ${BUILD_TIMESTAMP}"
echo ">>> Target Release Suffix : -g${OFFICIAL_HASH}"

echo ">>> Hard-stamping release suffix and timestamp into Kleaf & Kbuild scripts (BASE_VER=${BASE_VER})..."

# 1. Release Suffix (-g<hash>-ab<id>): Branch by BASE_VER to prevent double-stamping
if [ "$BASE_VER" = "6.6" ] || [ "$BASE_VER" = "6.12" ]; then
    if [ -f "build/kernel/kleaf/impl/stamp.bzl" ]; then
        sed -i "s/stable_scmversion_cmd = _get_status_at_path.*/stable_scmversion_cmd = \"echo -g${OFFICIAL_HASH}\"/g" build/kernel/kleaf/impl/stamp.bzl
        sed -i "s/-maybe-dirty//g" build/kernel/kleaf/impl/stamp.bzl
        echo "  -> Patched stamp.bzl scmversion for $BASE_VER"
    fi
else
    if [ -f "common/scripts/setlocalversion" ]; then
        sed -i 's/echo "\$res"/res="${res%%-g*}"; res="${res%-maybe-dirty}"; res="${res%-dirty}"; echo "${res}-g'"${OFFICIAL_HASH}"'"/g' common/scripts/setlocalversion
        sed -i 's/echo "\${res}"/res="${res%%-g*}"; res="${res%-maybe-dirty}"; res="${res%-dirty}"; echo "${res}-g'"${OFFICIAL_HASH}"'"/g' common/scripts/setlocalversion
        echo "  -> Patched setlocalversion tail for $BASE_VER:"
        tail -n 3 common/scripts/setlocalversion || true
    fi
fi

# 2. Build Timestamp (uname -v): common/init/Makefile (6.1 / 6.6 / 6.12) & mkcompile_h (5.10 / 5.15)
if [ -f "common/init/Makefile" ] && grep -q "^build-timestamp =" common/init/Makefile; then
    sed -i "s|^build-timestamp = .*|build-timestamp = ${BUILD_TIMESTAMP}|g" common/init/Makefile
    echo "  -> Patched common/init/Makefile:"
    grep -n "build-timestamp =" common/init/Makefile || true
elif [ -f "common/scripts/mkcompile_h" ]; then
    sed -i "s|TIMESTAMP=\$KBUILD_BUILD_TIMESTAMP|TIMESTAMP=\"${BUILD_TIMESTAMP}\"|g" common/scripts/mkcompile_h
    sed -i "s|TIMESTAMP=\`date\`|TIMESTAMP=\"${BUILD_TIMESTAMP}\"|g" common/scripts/mkcompile_h
    echo "  -> Patched common/scripts/mkcompile_h for $BASE_VER"
fi

echo ">>> Marking repo as clean (sanitizes all custom configuration & source modifications)..."
# Dynamically safeguards all modifications 
git -C common ls-files -m | xargs -r git -C common update-index --assume-unchanged

# Build method 
if [ "$BASE_VER" != "5.10" ] && [ -f "tools/bazel" ]; then
    echo ">>> Modern Kleaf/Bazel ecosystem detected for $BASE_VER..."
    
    # 5.15 Kleaf doesn't support the --notrim wrapper flag. 
    # (configure_kconfigs.sh handles it physically via the dictionary injection)
    TRIM_FLAGS=""
    if [ "$BASE_VER" = "5.15" ]; then
        echo "  -> 5.15 detected. Relying on physical Bazel dictionary patch (omitting --notrim)..."
    else
        TRIM_FLAGS="--notrim"
    fi
    
    # Enforce standard sandboxing, disable trimming dynamically, and inject MAKEFLAGS
    tools/bazel run --config=stamp \
      $TRIM_FLAGS \
      --action_env=SOURCE_DATE_EPOCH="$OFFICIAL_DATE" \
      --action_env=KBUILD_BUILD_TIMESTAMP="$BUILD_TIMESTAMP" \
      --action_env=STABLE_BUILD_VERSION="-g$OFFICIAL_HASH" \
      --action_env=KLEAF_KERNEL_BUILD_VERSION="-g$OFFICIAL_HASH" \
      --action_env=KLEAF_SKIP_ABI_CHECKS=true \
      --action_env=KLEAF_USER=android-build \
      //common:kernel_aarch64_dist \
      -- \
      --destdir=out/dist
else
    echo ">>> Legacy Hermetic Make ecosystem detected (5.10 or fallback)..."
    
    mkdir -p out/dist
    export DIST_DIR="out/dist"
    
    # Export standard environment variables for legacy build.sh
    export KERNEL_DIR="common"
    export BUILD_CONFIG="common/build.config.gki.aarch64"
    export SOURCE_DATE_EPOCH="$OFFICIAL_DATE"
    export KBUILD_BUILD_TIMESTAMP="$BUILD_TIMESTAMP"
    
    # Inject official hash and Make overrides
    export EXTRA_LINUX_VERSION="-g${OFFICIAL_HASH}"
    
    # Run the legacy orchestration script
    if [ -f "build/build.sh" ]; then
        echo "[+] Invoking build/build.sh..."
        bash build/build.sh
    else
        echo "[-] ERROR: Legacy build/build.sh orchestrator not found!" >&2
        exit 1
    fi
fi

IMAGE_PATH="$(find out/dist -type f -name 'Image' -print -quit)"
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

# --- DYNAMIC KCONFIG VALIDATION REPORT ---
if [ "$ENABLE_NOMOUNT" = "true" ] || [ "$ENABLE_NET_OPTS" = "true" ]; then
    echo "::group::Custom Kconfig Integration Report"
    echo ""
    echo "=============================================="
    echo " CUSTOM KCONFIG VALIDATION REPORT             "
    echo "=============================================="

    FRAGMENT_FILE="../tools/custom_combined.fragment"
    
    if [ ! -f "$FRAGMENT_FILE" ]; then
        echo "[-] Notice: tools/custom.fragment not found. Skipping validation."
    else
        # Locate the definitive compiled configuration source
        CONFIG_SRC=""
        if [ -f "out/dist/config.gz" ]; then
            CONFIG_SRC="out/dist/config.gz"
        elif [ -f "out/dist/.config" ]; then
            CONFIG_SRC="out/dist/.config"
        else
            CONFIG_SRC=$(find out/ -type f \( -name "config.gz" -o -name ".config" \) 2>/dev/null | head -n 1 || true)
        fi

        if [ -z "$CONFIG_SRC" ]; then
            echo "[!] WARN: Could not locate compiled kernel configuration target."
        else
            echo ">>> Extracting definitions from: $CONFIG_SRC"
            echo "----------------------------------------------"
            
            # Extract requested configs from fragment, ignoring comments and empty lines
            REQUESTED_CONFIGS=$(grep -E '^CONFIG_' "$FRAGMENT_FILE" | cut -d'=' -f1 || true)
            
            if [ -z "$REQUESTED_CONFIGS" ]; then
                echo "  [-] No active custom configs found in fragment."
            else
                for CFG in $REQUESTED_CONFIGS; do
                    # Search compiled config for the requested variable
                    if [[ "$CONFIG_SRC" == *.gz ]]; then
                        VAL=$(zgrep -E "^${CFG}=" "$CONFIG_SRC" | cut -d'=' -f2 || true)
                    else
                        VAL=$(grep -E "^${CFG}=" "$CONFIG_SRC" | cut -d'=' -f2 || true)
                    fi

                    # Print clean validation status
                    if [ "$VAL" = "y" ]; then
                        printf "  [ PASS ] %-40s = %s\n" "$CFG" "$VAL"
                    elif [ "$VAL" = "m" ]; then
                        printf "  [ WARN ] %-40s = %s (Module)\n" "$CFG" "$VAL"
                    else
                        printf "  [ DROP ] %-40s = MISSING/OVERRIDDEN\n" "$CFG"
                    fi
                done
            fi
        fi
    fi

    echo "=============================================="
    echo "::endgroup::"
fi

cd ..
echo ">>> Build execution loop completed"
