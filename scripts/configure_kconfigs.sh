#!/usr/bin/env bash
set -euo pipefail

WITH_CUSTOM=${WITH_CUSTOM:-false}
FRAGMENT_SRC="$(pwd)/tools/custom.fragment"
BASE_VER=${BASE_VER:-}

echo "=== Configuring Kconfigs & ABI Neutralization for Kernel $BASE_VER ==="

cd kernel_workspace

# 1. NEUTRALIZE LEGACY ABI PROTECTED EXPORTS (modpost bypass for 5.10-6.6)
for f in common/android/abi_gki_protected_exports* android/abi_gki_protected_exports*; do
    [ -f "$f" ] && > "$f" || true
done

cd common

# 2. NEUTRALIZE STRICT SYMBOL LISTS (modpost bypass for older Bazel)
# Note: module trimming is handled globally via --notrim in build_kernel.sh
case "$BASE_VER" in
    5.15|6.1|6.6)
        echo ">>> Disabling strict ABI mode in BUILD.bazel for $BASE_VER..."
        sed -i -E 's/(["\x27]?kmi_symbol_list_strict_mode["\x27]?[[:space:]]*[:=][[:space:]]*)True/\1False/g' BUILD.bazel
        ;;
    *)
        echo ">>> Kleaf >= 6.12 handles ABI bypass natively via CLI. Skipping strict mode sed."
        ;;
esac

# 3. INTEGRATE CUSTOM KCONFIG FRAGMENT
if [ "$WITH_CUSTOM" = "true" ]; then
    if [ ! -f "$FRAGMENT_SRC" ]; then
        echo "[-] Error: Fragment not found at $FRAGMENT_SRC"
        exit 1
    fi

    case "$BASE_VER" in
        5.10)
            echo ">>> Injecting Legacy 5.10 Kconfig Fragment..."
            cp "$FRAGMENT_SRC" arch/arm64/configs/custom_legacy.fragment
            ;;
        5.15|6.1)
            echo ">>> Injecting Bazel 5.15 to 6.1 Kconfig Fragment..."
            cp "$FRAGMENT_SRC" custom_fragment
            sed -i '/name = "kernel_aarch64",/a \    post_defconfig_fragments = ["custom_fragment"],' BUILD.bazel
            ;;
        *) 
            # 6.6+
            echo ">>> Injecting Bazel 6.6+ Kconfig Fragment..."
            cp "$FRAGMENT_SRC" custom_fragment
            sed -i '/"kernel_aarch64": {/a \        "defconfig_fragments": ["custom_fragment"],' BUILD.bazel
            ;;
    esac
fi

cd ../..
echo ">>> Configuration complete."