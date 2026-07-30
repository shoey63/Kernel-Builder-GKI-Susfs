#!/usr/bin/env bash
set -euo pipefail

cd kernel_workspace

[ -d common ] || { echo "[-] common/ not found in kernel_workspace" >&2; exit 1; }

echo ">>> Cloning susfs4ksu..."

# 1. Attempt to clone the primary target (usually has the -dev suffix)
if ! git clone --depth=1 -b "${SUSFS_NEXT_REF}" "${SUSFS_NEXT_URL}" susfs4ksu; then
    echo "[-] Branch '${SUSFS_NEXT_REF}' not found. Attempting fallback..."
    
    # 2. Strip the '-dev' suffix from the string
    FALLBACK_REF="${SUSFS_NEXT_REF%-dev}"
    
    # 3. Ensure we aren't just retrying the exact same string
    if [ "${SUSFS_NEXT_REF}" = "${FALLBACK_REF}" ]; then
        echo "[-] Error: Clone failed and no '-dev' suffix to fallback from. Exiting." >&2
        exit 1
    fi

    echo ">>> Trying fallback branch: '${FALLBACK_REF}'..."
    
    # 4. Clone the fallback. If this fails, the script will die here.
    git clone --depth=1 -b "${FALLBACK_REF}" "${SUSFS_NEXT_URL}" susfs4ksu || {
        echo "[-] Error: Fallback branch '${FALLBACK_REF}' also failed. Exiting." >&2
        exit 1
    }
fi

COMMON_PATCH_SRC="$(find susfs4ksu/kernel_patches -maxdepth 1 -type f -name '50_add_susfs_in_*.patch' | head -n1)"
[ -n "${COMMON_PATCH_SRC}" ] || { echo "[-] Could not find 50_add_susfs_in_*.patch" >&2; exit 1; }

echo ">>> Copying SUSFS files into common/..."
cp -f "${COMMON_PATCH_SRC}" common/
cp -rf susfs4ksu/kernel_patches/fs/* common/fs/
cp -rf susfs4ksu/kernel_patches/include/linux/* common/include/linux/

echo ">>> Applying common kernel SUSFS patch..."
(cd common && patch -p1 --no-backup-if-mismatch < "$(basename "${COMMON_PATCH_SRC}")") || true

echo ">>> SUSFS common-side integration complete!"
