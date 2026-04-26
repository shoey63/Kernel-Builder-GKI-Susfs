#!/bin/bash
set -e

WORKSPACE="workspace"
DIST_DIR="out/dist"

cd "${WORKSPACE}"

echo "=== Applying ABI Fixes ==="
> common/android/abi_gki_protected_exports_aarch64
> common/android/abi_gki_protected_exports_x86_64

echo "=== Integrating KernelSU-Next ==="
git clone https://github.com/shoey63/KernelSU-Next.git -b pixel9-susfs-gki-android14-6.1 KernelSU-Next

bash KernelSU-Next/kernel/setup.sh

echo "Restoring the custom pixel9-susfs branch..."
cd KernelSU-Next
git checkout pixel9-susfs-gki-android14-6.1

# --- THE VERSION FIX ---
echo "Grabbing Git info for KSU manager..."
KSU_TAG=$(git describe --abbrev=0 --tags 2>/dev/null || echo "v1.0.0")
KSU_HASH=$(git rev-parse HEAD 2>/dev/null || echo "unknown")

# --- HARD DEBUG TRAP ---
CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" != "pixel9-susfs-gki-android14-6.1" ]; then
    echo "CRITICAL ERROR: KernelSU-Next branch hijack detected!"
    exit 1
fi
cd ..

echo "Replacing KSU symlink with a hard copy for the Bazel sandbox..."
rm -f common/drivers/kernelsu
cp -r KernelSU-Next/kernel common/drivers/kernelsu

# --- THE UAPI FIX ---
echo "Hunting down missing uapi headers..."
UAPI_DIR=$(find KernelSU-Next -type d -name "uapi" | head -n 1)
if [ -n "$UAPI_DIR" ]; then
    echo "Found uapi at $UAPI_DIR, injecting into sandbox sightlines..."
    cp -r "$UAPI_DIR" common/drivers/kernelsu/
    cp -r "$UAPI_DIR" common/drivers/
else
    echo "WARNING: Could not find uapi folder in KernelSU-Next!"
fi

echo "Injecting KSU Git versions to silence Kbuild warnings..."
sed -i "1i KSU_GIT_VERSION := $KSU_HASH" common/drivers/kernelsu/Kbuild
sed -i "1i KSU_VERSION_TAG := $KSU_TAG" common/drivers/kernelsu/Kbuild

# Strip config constraints
sed -i '/default [yn]/d' common/drivers/kernelsu/Kconfig || true
sed -i 's/^config .*/&\n\tdefault y/g' common/drivers/kernelsu/Kconfig || true

echo "=== Integrating susfs4ksu ==="
git clone https://gitlab.com/shoey63/susfs4ksu.git -b gki-android14-6.1-dev susfs4ksu

cp -r susfs4ksu/kernel_patches/fs/* common/fs/
cp -r susfs4ksu/kernel_patches/include/linux/* common/include/linux/

echo "Applying susfs kernel patches..."
cd common
cp ../susfs4ksu/kernel_patches/50_add_susfs_in_*.patch .
patch -p1 < 50_add_susfs_in_*.patch || true

# --- Unwrapped Manual Hunk #1 Fix ---
if ! grep -q 'susfs_def.h' fs/namespace.c; then
  echo "Applying manual fs/namespace.c include fix..."
  sed -i '/#include <linux\/mnt_idmapping.h>/a\
#include <linux/susfs_def.h>\
' fs/namespace.c
fi

if ! grep -q 'DEFINE_IDA(susfs_mnt_id_ida)' fs/namespace.c; then
  echo "Applying manual fs/namespace.c SUSFS mount declarations fix..."
  sed -i '/#include "internal.h"/a\
\
extern bool susfs_is_current_ksu_domain(void);\
extern struct static_key_false susfs_set_sdcard_android_data_decrypted_key_false;\
\
#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */\
\
static DEFINE_IDA(susfs_mnt_id_ida);\
static DEFINE_IDA(susfs_mnt_group_ida);\
' fs/namespace.c
fi
rm -f fs/namespace.c.rej
cd ..

# --- UPSTREAM BUG FIX ---
echo "Fixing upstream typo in KernelSU-Next allowlist.c..."
sed -i 's/\.current_uid/.curr_uid/g' common/drivers/kernelsu/policy/allowlist.c || true

echo "======================================================="
echo "=== SUSFS / KSU INJECTION AUDIT (PRE-BUILD CHECK) ==="
echo "======================================================="
echo "--> 1. Verifying manual Hunk #1 injection in fs/namespace.c:"
grep -A 5 -B 2 "static DEFINE_IDA(susfs_mnt_id_ida);" common/fs/namespace.c
echo -e "\n--> 2. Verifying forced KSU configurations:"
grep -A 2 "config KSU_SUSFS$" common/drivers/kernelsu/Kconfig
echo -e "\n--> 3. Checking uapi header injection:"
ls -l common/drivers/kernelsu/uapi | head -n 3
echo "======================================================="

echo "=== Building GKI via Kleaf (Bazel) ==="
tools/bazel run --color=no --curses=no //common:kernel_aarch64_dist -- --dist_dir="${DIST_DIR}" 2>&1 | tee build.log

echo "=== Preparing Artifacts ==="
mv "${DIST_DIR}/Image" ./Image

echo "=== Build Complete ==="
