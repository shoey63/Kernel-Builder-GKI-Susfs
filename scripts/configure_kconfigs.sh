#!/usr/bin/env bash
set -euo pipefail

# Configuration: Toggle custom Kconfig integration via ENV (Defaults to false)
WITH_WG=${WITH_WG:-false}

echo "=== Configuring Kconfigs & Fragments ==="

cd kernel_workspace

echo ">>> Neutralizing ABI protected exports lists..."
for f in common/android/abi_gki_protected_exports*; do
  [ -f "$f" ] && > "$f"
done

if [ "$WITH_WG" = "true" ]; then
    echo ">>> Integrating Kconfig Fragments..."
    cd common
    
    # Create the configuration fragment
    cat > custom_fragment << 'EOF'
# --- CORE WIREGUARD ---
CONFIG_WIREGUARD=y
CONFIG_NET_UDP_TUNNEL=y

# --- ARM64 HARDWARE CRYPTO ACCELERATION ---
CONFIG_CRYPTO_CURVE25519=y
CONFIG_CRYPTO_CURVE25519_NEON=y
CONFIG_CRYPTO_CHACHA20_NEON=y
CONFIG_CRYPTO_POLY1305_NEON=y
CONFIG_CRYPTO_BLAKE2S_ARM64=y

# --- ANDROID NETD ROUTING HOOKS ---
CONFIG_NETFILTER_XT_MATCH_HASHLIMIT=y
CONFIG_NETFILTER_XT_MATCH_LENGTH=y
CONFIG_NETFILTER_XT_MATCH_MARK=y
CONFIG_NETFILTER_XT_MATCH_POLICY=y

# --- ADDITIONAL CONFIGS ---
# <LIST EXTRA KERNEL CONFIGS HERE>

EOF

    # Inject fragment targeting into the Bazel build rules
    echo 'exports_files(["custom_fragment"])' >> BUILD.bazel
    sed -i '/name = "kernel_aarch64",/a \    post_defconfig_fragments = ["custom_fragment"],' BUILD.bazel
    
    # Exclude the untracked fragment from standard git tracking status
    echo "custom_fragment" >> .git/info/exclude
    cd ..
else
    echo ">>> Skipping custom Kconfig configuration..."
fi

cd ..
echo ">>> Kconfig configuration phase complete."
