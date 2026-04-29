#!/usr/bin/env bash
set -euo pipefail

cd kernel_workspace

[ -d common ] || { echo "[-] common/ not found in kernel_workspace" >&2; exit 1; }

echo ">>> Cloning susfs4ksu..."
git clone --depth=1 -b "${SUSFS_NEXT_REF}" "${SUSFS_NEXT_URL}" susfs4ksu

COMMON_PATCH_SRC="$(find susfs4ksu/kernel_patches -maxdepth 1 -type f -name '50_add_susfs_in_*.patch' | head -n1)"
[ -n "${COMMON_PATCH_SRC}" ] || { echo "[-] Could not find 50_add_susfs_in_*.patch" >&2; exit 1; }

echo ">>> Copying SUSFS files into common/..."
cp -f "${COMMON_PATCH_SRC}" common/
cp -rf susfs4ksu/kernel_patches/fs/* common/fs/
cp -rf susfs4ksu/kernel_patches/include/linux/* common/include/linux/

echo ">>> Applying manual fs/namespace.c fixes..."
if ! grep -q 'susfs_def.h' common/fs/namespace.c; then
  sed -i '/#include <linux\/mnt_idmapping.h>/a\
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\
#include <linux/susfs_def.h>\
#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\
' common/fs/namespace.c
fi

if ! grep -q 'susfs_is_sdcard_android_data_not_decrypted' common/fs/namespace.c; then
  sed -i '/#include "internal.h"/a\
\
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\
extern bool susfs_is_current_ksu_domain(void);\
extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;\
\
#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */\
\
#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\
' common/fs/namespace.c
fi

echo ">>> Applying common kernel SUSFS patch (expecting namespace.c hunk #1 to fail)..."
set +e
(cd common && patch -p1 < "$(basename "${COMMON_PATCH_SRC}")")
APPLY_RC=$?
set -e

# Collect any generated .rej files
mapfile -t REJ_FILES < <(find common -type f -name '*.rej')

if [ "$APPLY_RC" -ne 0 ]; then
  # If the ONLY reject is the expected namespace.c, we are good.
  if [ "${#REJ_FILES[@]}" -eq 1 ] && [ "${REJ_FILES[0]}" = "common/fs/namespace.c.rej" ]; then
    echo ">>> Expected failure caught and safely ignored. Cleaning up..."
    rm -f common/fs/namespace.c.rej
  else
    echo "[-] CRITICAL: Unexpected patch failures occurred!" >&2
    for f in "${REJ_FILES[@]}"; do echo "  - $f" >&2; done
    exit 1
  fi
fi

echo ">>> SUSFS common-side integration complete!"
