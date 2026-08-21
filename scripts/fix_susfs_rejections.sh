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

# 4. Fix fs/proc/task_mmu.c
if [ -f "common/fs/proc/task_mmu.c.rej" ]; then
  echo ">>> Found task_mmu.c.rej. Analyzing failure type..."
  
  # Path 1: 6.12 Behavior (Headers applied natively, show_smap logic rejected)
  if grep -q "show_smap" "common/fs/proc/task_mmu.c.rej"; then
    echo "  -> Logic rejection detected (6.12 behavior). Injecting show_smap patch..."
    
    # 6.12 initializes 'struct mem_size_stats mss = {};'. 
    # We MUST inject after this line to prevent C99 declaration errors.
    sed -i '/static int show_smap(struct seq_file \*m, void \*v)/,/struct mem_size_stats mss = {};/ {
      /struct mem_size_stats mss = {};/a\
\
#ifdef CONFIG_KSU_SUSFS_SUS_MAP\
	if (vma->vm_file) {\
		if (SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))\
			return 0;\
	}\
#endif \/\/ #ifdef CONFIG_KSU_SUSFS_SUS_MAP
    }' common/fs/proc/task_mmu.c

    if grep -q 'SUSFS_IS_INODE_SUS_MAP' common/fs/proc/task_mmu.c; then
      echo "  -> task_mmu.c 6.12 logic fix verified!"
      rm "common/fs/proc/task_mmu.c.rej"
    else
      echo "  [-] WARNING: task_mmu.c 6.12 logic fix failed!" >&2
    fi

  # Path 2: 5.15 Behavior (show_smap logic applied natively, headers rejected)
  elif grep -q "susfs_def.h" "common/fs/proc/task_mmu.c.rej" || grep -q "CONFIG_KSU_SUSFS_SUS_KSTAT" "common/fs/proc/task_mmu.c.rej"; then
    echo "  -> Header rejection detected (5.15 behavior). Injecting missing headers..."
    
    # Use uaccess.h as the anchor, since we know from the .rej file that it exists exactly where we need it
    if ! grep -q 'susfs_def.h' common/fs/proc/task_mmu.c; then
      sed -i '/#include <linux\/uaccess.h>/a\
#include <linux\/cred.h>\
#if defined(CONFIG_KSU_SUSFS_SUS_KSTAT) || defined(CONFIG_KSU_SUSFS_SUS_MAP) || defined(CONFIG_KSU_SUSFS_OPEN_REDIRECT)\
#include <linux\/susfs_def.h>\
#endif' common/fs/proc/task_mmu.c
    fi

    if grep -q 'susfs_def.h' common/fs/proc/task_mmu.c; then
      echo "  -> task_mmu.c 5.15 header fix verified!"
      rm "common/fs/proc/task_mmu.c.rej"
    else
      echo "  [-] WARNING: task_mmu.c 5.15 header fix failed!" >&2
    fi
    
  else
    echo "  [-] UNKNOWN rejection format in task_mmu.c.rej! Cannot safely patch." >&2
  fi
fi

# 5. Fix mm/rmap.c (Redundant Upstream Backport vs Legacy Kernel)
if [ -f "common/mm/rmap.c.rej" ]; then
  echo ">>> Found rmap.c.rej. Analyzing kernel version compatibility..."
  
  # We must check the ACTUAL C file, not the .rej file, to see if the kernel is modern
  if grep -q "tlb_gather_mmu_vma" "common/mm/rmap.c"; then
    echo "  -> Native mmu_gather logic detected in source (Android 15 / 6.6+ behavior)."
    echo "  -> The SuSFS backport is redundant. Safely ignoring the rejection!"
    rm "common/mm/rmap.c.rej"
  else
    echo "  [-] CRITICAL: Older kernel (e.g. 5.10 or 6.1) detected!" >&2
    echo "  [-] This kernel lacks the native TLB backport and GENUINELY needs the patch." >&2
    echo "  [-] A manual sed injection is required for this specific older kernel branch." >&2
    # We deliberately DO NOT delete the .rej file here. 
    # This ensures your Final Validation step catches it and halts the build 
    # so we don't compile a broken kernel!
  fi
fi

# 5.5 Fix fs/namei.c API Mismatch (4 args to 3 args for older kernels)
echo ">>> Checking set_nameidata API mismatch in fs/namei.c..."

# Extract kernel version dynamically from Makefile
K_VER=$(grep "^VERSION =" common/Makefile | tr -d ' ' | cut -d'=' -f2)
K_PATCH=$(grep "^PATCHLEVEL =" common/Makefile | tr -d ' ' | cut -d'=' -f2)

# Only check if building 5.10
if [ "$K_VER" = "5" ] && [ "$K_PATCH" = "10" ]; then
  # Check if the 4-arg version exists (in case upstream missed a branch)
  if grep -q "set_nameidata(nd,.*NULL);" common/fs/namei.c; then
    echo "  -> Kernel 5.10 detected with 4-arg set_nameidata. Downgrading to 3 arguments..."
    sed -i 's/set_nameidata(nd,[[:space:]]*old_dfd,[[:space:]]*fake_filename,[[:space:]]*NULL);/set_nameidata(nd, old_dfd, fake_filename);/g' common/fs/namei.c
    echo "  -> fs/namei.c API mismatch resolved for 5.10!"
  else
    echo "  -> Kernel 5.10 detected, but 3-arg set_nameidata is already present (Upstream patched). Skipping."
  fi
else
  echo "  -> Kernel $K_VER.$K_PATCH detected. Natively expects 4 arguments. Skipping."
fi

# 5.6 Fix fs/open.c API Mismatch (3 args to 2 args for Linux 6.12+)
echo ">>> Checking getname_flags API mismatch in fs/open.c..."

# Only check if building 6.12 or newer
if [ "$K_VER" = "6" ] && [ "$K_PATCH" -ge "12" ]; then
  if grep -q "getname_flags(filename, lookup_flags, NULL)" common/fs/open.c; then
    echo "  -> Kernel 6.12+ detected. Modifying getname_flags to use 2 arguments..."
    sed -i 's/getname_flags(filename, lookup_flags, NULL)/getname_flags(filename, lookup_flags)/g' common/fs/open.c
    echo "  -> fs/open.c API mismatch resolved for 6.12+!"
  else
    echo "  -> Kernel 6.12+ detected, but 2-arg getname_flags is already present. Skipping."
  fi
fi

# 6. Final Validation
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
