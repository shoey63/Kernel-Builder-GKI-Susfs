#!/bin/bash
set -e

WORKSPACE="workspace"
DIST_DIR="out/dist"

cd "${WORKSPACE}"

echo "=== Applying ABI Fixes ==="
echo "Neutralizing ABI protected exports for Pixel compatibility..."
> common/android/abi_gki_protected_exports_aarch64
> common/android/abi_gki_protected_exports_x86_64

echo "=== Integrating KernelSU-Next ==="
echo "Cloning shoey63/KernelSU-Next..."
git clone https://github.com/shoey63/KernelSU-Next.git -b pixel9-susfs-gki-android14-6.1 KernelSU-Next

echo "Running KernelSU-Next setup..."
bash KernelSU-Next/kernel/setup.sh

echo "Restoring the custom pixel9-susfs branch..."
cd KernelSU-Next
git checkout pixel9-susfs-gki-android14-6.1
cd ..

echo "=== Integrating susfs4ksu ==="
echo "Cloning shoey63/susfs4ksu..."
git clone https://gitlab.com/shoey63/susfs4ksu.git -b gki-android14-6.1-dev susfs4ksu

echo "Copying susfs source files..."
cp -r susfs4ksu/kernel_patches/fs/* common/fs/
cp -r susfs4ksu/kernel_patches/include/linux/* common/include/linux/

echo "Applying susfs kernel patches..."
cd common
cp ../susfs4ksu/kernel_patches/50_add_susfs_in_*.patch .
patch -p1 < 50_add_susfs_in_*.patch || true

if [ -f "fs/namespace.c.rej" ]; then
    echo "Patch conflict detected in fs/namespace.c! Manually injecting susfs.h..."
    if ! grep -q "#include <linux/susfs.h>" fs/namespace.c; then
        sed -i '32i #include <linux/susfs.h>' fs/namespace.c
    fi
    rm -f fs/namespace.c.rej
fi
cd ..

echo "=== Configuring KSU & SUSFS for Kleaf ==="
# 1. Strip any existing 'default y' or 'default n' lines from the KSU Kconfig so we don't create syntax errors
sed -i '/default [yn]/d' KernelSU-Next/kernel/Kconfig || true

# 2. Forcefully inject 'default y' immediately after every 'config' declaration in the file
sed -i 's/^config .*/&\n\tdefault y/g' KernelSU-Next/kernel/Kconfig || true

echo "=== Preparing Artifacts ==="
mv "${DIST_DIR}/Image" ./Image

echo "=== Build Complete ==="
