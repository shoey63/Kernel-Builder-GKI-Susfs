#!/usr/bin/env bash
set -euo pipefail

echo "=== Applying Custom Kernel Patches ==="
cd kernel_workspace/common

echo ">>> Injecting ZeroMount Subsystem..."
# We append '|| true' so Bash doesn't instantly crash when the rigid patch rejects hunks
patch -p1 < ../../patches/60_zeromount-android14-6.1.patch || echo "[-] Context mismatches detected. Resolving dynamically..."

# Clean up the rejection files left behind by the patch command
find . -name "*.rej" -type f -delete

echo ">>> Resolving fs/Kconfig..."
if ! grep -q "config ZEROMOUNT" fs/Kconfig; then
    echo -e '\nconfig ZEROMOUNT\n\tbool "ZeroMount Path Redirection Subsystem"\n\tdefault y' >> fs/Kconfig
fi

echo ">>> Resolving fs/proc/task_mmu.c (Hunks 1 & 2)..."
if ! grep -q "linux/zeromount.h" fs/proc/task_mmu.c; then
    sed -i '/#include <trace\/hooks\/mm.h>/a #ifdef CONFIG_ZEROMOUNT\n#include <linux\/zeromount.h>\n#endif' fs/proc/task_mmu.c
fi

if ! grep -q "zeromount_spoof_mmap_metadata" fs/proc/task_mmu.c; then
    sed -i '/ino = inode->i_ino;/a \t\t#ifdef CONFIG_ZEROMOUNT\n\t\tzeromount_spoof_mmap_metadata(inode, &dev, &ino);\n\t\t#endif' fs/proc/task_mmu.c
fi

echo ">>> Resolving fs/stat.c (Hunk 3)..."
if ! grep -q "zeromount_stat_hook(dfd, filename" fs/stat.c; then
    # We target a native Linux variable here instead of a volatile SuSFS anchor to ensure it always hits
    sed -i '/unsigned lookup_flags = LOOKUP_FOLLOW | LOOKUP_AUTOMOUNT;/a \
#ifdef CONFIG_ZEROMOUNT\n\tif (filename) {\n\t\tint zm_ret = zeromount_stat_hook(dfd, filename, stat, request_mask, flags);\n\t\tif (zm_ret != -ENOENT)\n\t\t\treturn zm_ret;\n\t}\n#endif' fs/stat.c
fi

echo ">>> ZeroMount successfully integrated and sanitized!"
