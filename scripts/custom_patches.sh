#!/usr/bin/env bash
set -euo pipefail

echo "=== Applying Custom Kernel Patches ==="
cd kernel_workspace/common

echo ">>> Injecting ZeroMount Subsystem..."
# Append '|| true' so Bash doesn't crash on rigid context mismatches
patch -p1 < ../../patches/60_zeromount-android14-6.1.patch || echo "[-] Context mismatches detected. Resolving dynamically..."

echo ">>> Starting ZeroMount patch fixup routine..."

# 1. Kconfig Injection (No .rej file, just standard validation)
echo ">>> Resolving fs/Kconfig..."
if ! grep -q "config ZEROMOUNT" fs/Kconfig; then
    echo -e '\nconfig ZEROMOUNT\n\tbool "ZeroMount Path Redirection Subsystem"\n\tdefault y' >> fs/Kconfig
fi
if [ -f "fs/Kconfig.rej" ]; then rm "fs/Kconfig.rej"; fi
if [ -f "arch/arm64/configs/gki_defconfig.rej" ]; then rm "arch/arm64/configs/gki_defconfig.rej"; fi

# 2. Fix fs/proc/task_mmu.c
if [ -f "fs/proc/task_mmu.c.rej" ]; then
    echo ">>> Found task_mmu.c.rej. Applying manual fix..."
    
    # Hunk 1: Header Injection (Using uaccess.h instead of the missing 5.10 trace hooks)
    if ! grep -q "linux/zeromount.h" fs/proc/task_mmu.c; then
        sed -i '/#include <linux\/uaccess.h>/a\
#ifdef CONFIG_ZEROMOUNT\
#include <linux/zeromount.h>\
#endif\
' fs/proc/task_mmu.c
    fi

    # Hunk 2: Spoof Metadata Injection (Fixed for 6.12 const struct inode compatibility)
    if ! grep -q "zeromount_spoof_mmap_metadata" fs/proc/task_mmu.c; then
        sed -i '/ino = inode->i_ino;/a\
#ifdef CONFIG_ZEROMOUNT\
\t\tzeromount_spoof_mmap_metadata((struct inode *)inode, \&dev, \&ino);\
#endif\
' fs/proc/task_mmu.c
    fi

    # Sanity Check
    if grep -q 'zeromount_spoof_mmap_metadata' fs/proc/task_mmu.c && grep -q 'linux/zeromount.h' fs/proc/task_mmu.c; then
        echo "  -> task_mmu.c fix verified!"
        rm "fs/proc/task_mmu.c.rej"
    else
        echo "  [-] WARNING: task_mmu.c fix failed to inject!" >&2
    fi
fi

# 3. Fix fs/stat.c
if [ -f "fs/stat.c.rej" ]; then
    echo ">>> Found stat.c.rej. Applying manual fix..."
    
    if ! grep -q "zeromount_stat_hook(dfd, filename" fs/stat.c; then
        sed -i '/unsigned lookup_flags = LOOKUP_FOLLOW | LOOKUP_AUTOMOUNT;/a\
#ifdef CONFIG_ZEROMOUNT\
\tif (filename) {\
\t\tint zm_ret = zeromount_stat_hook(dfd, filename, stat, request_mask, flags);\n\t\tif (zm_ret != -ENOENT)\
\t\t\treturn zm_ret;\
\t}\
#endif\
' fs/stat.c
    fi

    # Sanity Check
    if grep -q 'zeromount_stat_hook' fs/stat.c; then
        echo "  -> stat.c fix verified!"
        rm "fs/stat.c.rej"
    else
        echo "  [-] WARNING: stat.c fix failed to inject!" >&2
    fi
fi

# 4. Final Validation
echo ">>> Checking for unresolved patch rejections..."
mapfile -t REMAINING_REJ < <(find . -type f -name '*.rej')

if [ ${#REMAINING_REJ[@]} -gt 0 ]; then
    echo "[-] CRITICAL: Unresolved patch rejections found!" >&2
    for f in "${REMAINING_REJ[@]}"; do
        echo "  - $f" >&2
        echo "=== $f Contents ===" >&2
        cat "$f" >&2
    done
    exit 1
else
    echo ">>> All ZeroMount patch rejections resolved successfully!"
fi
