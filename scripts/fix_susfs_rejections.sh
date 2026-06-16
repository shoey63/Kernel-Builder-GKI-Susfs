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
  
  # INJECTION: Drop headers, externs, and macros together right above the first include
  if ! grep -q 'susfs_is_sdcard_android_data_not_decrypted' common/fs/namespace.c; then
    sed -i '0,/^#include/ {
      /^#include/i\
#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\
#include <linux/susfs_def.h>\
extern bool susfs_is_current_ksu_domain(void);\
extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;\
#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */\
#endif // CONFIG_KSU_SUSFS_SUS_MOUNT\

    }' common/fs/namespace.c
  fi

  # Sanity Check: Verify BOTH the header and the macro were injected
  if grep -q 'susfs_def.h' common/fs/namespace.c && grep -q 'susfs_is_sdcard_android_data_not_decrypted' common/fs/namespace.c; then
    echo "  -> namespace.c fix verified (Header & Macros injected)!"
    rm "common/fs/namespace.c.rej"
  else
    echo "  [-] WARNING: namespace.c fix failed! Either the header or macros are missing." >&2
  fi
fi


# 4. Fix fs/proc/task_mmu.c
if [ -f "common/fs/proc/task_mmu.c.rej" ]; then
  echo ">>> Found task_mmu.c.rej. Applying manual fix..."
  
  # INJECTION 1: Bulletproof header injection
  if ! grep -q '#include <linux/susfs.h>' common/fs/proc/task_mmu.c; then
    # Finds the very first #include line and inserts susfs.h directly above it
    sed -i '0,/^#include/s//#include <linux\/susfs.h>\n&/' common/fs/proc/task_mmu.c
  fi
  
  # INJECTION 2: Inject the SUS_MAP check inside show_smap()
  sed -i '/static int show_smap(struct seq_file \*m, void \*v)/,/struct vm_area_struct \*vma = v;/ {
    /struct vm_area_struct \*vma = v;/a\
\
#ifdef CONFIG_KSU_SUSFS_SUS_MAP\
	if (vma->vm_file) {\
		if (SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))\
			return 0;\
	}\
#endif \/\/ #ifdef CONFIG_KSU_SUSFS_SUS_MAP
  }' common/fs/proc/task_mmu.c

  # Sanity Check
  if grep -q '#include <linux/susfs.h>' common/fs/proc/task_mmu.c && grep -q 'SUSFS_IS_INODE_SUS_MAP' common/fs/proc/task_mmu.c; then
    echo "  -> task_mmu.c fix verified (Header & Macro injected)!"
    rm "common/fs/proc/task_mmu.c.rej"
  else
    echo "  [-] WARNING: task_mmu.c fix failed! Either the header or the macro is missing." >&2
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
