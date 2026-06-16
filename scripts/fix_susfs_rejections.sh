#!/usr/bin/env bash
set -euo pipefail

echo ">>> Starting SUSFS patch fixup routine..."

# Step into the kernel workspace where 'common' actually lives
cd kernel_workspace

# 1. Fix fs/exec.c
if [ -f "common/fs/exec.c.rej" ]; then
  echo ">>> Found exec.c.rej. Applying manual fix..."
  
  # Using uaccess.h as the anchor, inserting before it
  sed -i '/#include <linux\/uaccess.h>/i\
#ifdef CONFIG_KSU_SUSFS\
#include <linux/susfs_def.h>\
#endif\
' common/fs/exec.c

  # Sanity Check: Did the injection actually write to the file?
  if grep -q 'susfs_def.h' common/fs/exec.c; then
    echo "  -> exec.c fix verified!"
    rm "common/fs/exec.c.rej"
  else
    echo "  [-] WARNING: exec.c fix failed to inject! The anchor line may have changed." >&2
  fi
fi

# 2. Fix fs/proc/base.c
if [ -f "common/fs/proc/base.c.rej" ]; then
  echo ">>> Found base.c.rej. Applying manual fix..."
  
  # Using "internal.h" as the anchor since it's present in the .rej context
  sed -i '/#include "internal.h"/i\
#if defined(CONFIG_KSU_SUSFS_SUS_MAP) || defined(CONFIG_KSU_SUSFS_OPEN_REDIRECT)\
#include <linux/susfs_def.h>\
#endif\
' common/fs/proc/base.c

  # Sanity Check
  if grep -q 'susfs_def.h' common/fs/proc/base.c; then
    echo "  -> base.c fix verified!"
    rm "common/fs/proc/base.c.rej"
  else
    echo "  [-] WARNING: base.c fix failed to inject! The anchor line may have changed." >&2
  fi
fi


# 3. Fix fs/namespace.c
if [ -f "common/fs/namespace.c.rej" ]; then
  echo ">>> Found namespace.c.rej. Applying manual fix..."
  
  # Inject the headers before pnode.h
  sed -i '/#include "pnode.h"/i\
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\
#include <linux/susfs_def.h>\
#endif \/\/ #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\
' common/fs/namespace.c

  # Inject the externs and macros after trace/hooks/blk.h
  sed -i '/#include <trace\/hooks\/blk.h>/a\
\
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\
extern bool susfs_is_current_ksu_domain(void);\
extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;\
\
#define CL_COPY_MNT_NS BIT(25) \/* used by copy_mnt_ns() *\/\
\
#endif \/\/ #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\
' common/fs/namespace.c

  # Sanity Check: Did the injection actually write to the file?
  if grep -q 'susfs_is_sdcard_android_data_not_decrypted' common/fs/namespace.c; then
    echo "  -> namespace.c fix verified!"
    rm "common/fs/namespace.c.rej"
  else
    echo "  [-] WARNING: namespace.c fix failed to inject! The anchor line may have changed." >&2
  fi
fi


# 5. Final Validation
echo ">>> Checking for unresolved patch rejections..."
mapfile -t REMAINING_REJ < <(find common -type f -name '*.rej')

if [ ${#REMAINING_REJ[@]} -gt 0 ]; then
  echo "[-] CRITICAL: Unresolved patch rejections found!" >&2
  for f in "${REMAINING_REJ[@]}"; do
    echo "  - $f" >&2
    echo "=== $f Contents ===" >&2
    cat "$f" >&2
  done
  exit 1
else
  echo ">>> All patch rejections resolved successfully!"
fi
