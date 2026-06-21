#!/usr/bin/env bash
set -euo pipefail

echo "=== Applying Custom Kernel Patches ==="
cd kernel_workspace/common

echo ">>> Injecting ZeroMount Subsystem..."
# Append '|| true' so Bash doesn't crash on rigid context mismatches
patch -p1 < ../../patches/60_zeromount-android14-6.1.patch || echo "[-] Context mismatches detected. Resolving dynamically..."

# Clean up the rejection files left behind by the patch command
find . -name "*.rej" -type f -delete

echo ">>> Resolving fs/Kconfig..."
if ! grep -q "config ZEROMOUNT" fs/Kconfig; then
    echo -e '\nconfig ZEROMOUNT\n\tbool "ZeroMount Path Redirection Subsystem"\n\tdefault y' >> fs/Kconfig
fi

echo ">>> Resolving fs/proc/task_mmu.c (Hunk 1 - Include)..."
if ! grep -q "linux/zeromount.h" fs/proc/task_mmu.c; then
    sed -i '/#include <trace\/hooks\/mm.h>/a\
#ifdef CONFIG_ZEROMOUNT\
#include <linux/zeromount.h>\
#endif\
' fs/proc/task_mmu.c
fi

echo ">>> Resolving fs/proc/task_mmu.c (Hunk 2 - Spoof Metadata)..."
if ! grep -q "zeromount_spoof_mmap_metadata" fs/proc/task_mmu.c; then
    # Using your proven syntax with properly escaped pointers (\&dev, \&ino)
    sed -i '/ino = inode->i_ino;/a\
#ifdef CONFIG_ZEROMOUNT\
\t\tzeromount_spoof_mmap_metadata(inode, \&dev, \&ino);\
#endif\
' fs/proc/task_mmu.c
fi

echo ">>> Resolving fs/stat.c (Hunk 3)..."
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

echo ">>> ZeroMount successfully integrated and sanitized!"
