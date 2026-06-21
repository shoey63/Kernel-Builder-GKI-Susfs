#!/usr/bin/env bash
set -euo pipefail

echo "=== Applying Custom Kernel Patches ==="
cd kernel_workspace/common

echo ">>> Injecting ZeroMount Subsystem..."
patch -p1 < ../../patches/60_zeromount-android14-6.1.patch || echo "[-] Context mismatches detected. Resolving dynamically..."

echo ">>> Starting ZeroMount patch fixup routine..."

# 1. Kconfig & Defconfig
echo ">>> Resolving fs/Kconfig..."
if ! grep -q "config ZEROMOUNT" fs/Kconfig; then
    echo -e '\nconfig ZEROMOUNT\n\tbool "ZeroMount Path Redirection Subsystem"\n\tdefault y' >> fs/Kconfig
fi
rm -f fs/Kconfig.rej arch/arm64/configs/gki_defconfig.rej

# 2. d_path.c (Resolves 5.10 missing header)
if [ -f "fs/d_path.c.rej" ]; then
    echo ">>> Found d_path.c.rej. Applying manual fix..."
    if ! grep -q "linux/zeromount.h" fs/d_path.c; then
        sed -i '/#include "mount.h"/a\
#ifdef CONFIG_ZEROMOUNT\
#include <linux/zeromount.h>\
#endif\
' fs/d_path.c
    fi
    rm -f fs/d_path.c.rej
fi

# 3. proc/base.c (Resolves 5.15 d_path spoofing)
if [ -f "fs/proc/base.c.rej" ]; then
    echo ">>> Found base.c.rej. Applying manual fix..."
    if ! grep -q "zeromount_get_static_vpath" fs/proc/base.c; then
        sed -i '/pathname = d_path(path, tmp, PATH_MAX);/i\
#ifdef CONFIG_ZEROMOUNT\
    if (!zeromount_should_skip() && path->dentry) {\
        struct inode *inode = d_backing_inode(path->dentry);\
        if (inode) {\
            char *vpath = zeromount_get_static_vpath(inode);\
            if (vpath) {\
                int vlen = strlen(vpath);\
                if (vlen > buflen)\
                    vlen = buflen;\
                if (copy_to_user(buffer, vpath, vlen) == 0) {\
                    kfree(vpath);\
                    kfree(tmp);\
                    return vlen;\
                }\
                kfree(vpath);\
            }\
        }\
    }\
#endif\
' fs/proc/base.c
    fi
    rm -f fs/proc/base.c.rej
fi

# 4. proc/task_mmu.c (Resolves all header and 6.12 const pointer shifts)
if [ -f "fs/proc/task_mmu.c.rej" ]; then
    echo ">>> Found task_mmu.c.rej. Applying manual fix..."
    if ! grep -q "linux/zeromount.h" fs/proc/task_mmu.c; then
        sed -i '/#include <linux\/uaccess.h>/a\
#ifdef CONFIG_ZEROMOUNT\
#include <linux/zeromount.h>\
#endif\
' fs/proc/task_mmu.c
    fi
    if ! grep -q "zeromount_spoof_mmap_metadata" fs/proc/task_mmu.c; then
        sed -i '/ino = inode->i_ino;/a\
#ifdef CONFIG_ZEROMOUNT\
        zeromount_spoof_mmap_metadata((struct inode *)inode, \&dev, \&ino);\
#endif\
' fs/proc/task_mmu.c
    fi
    rm -f fs/proc/task_mmu.c.rej
fi

# 5. stat.c (Resolves 5.15 missing function definition & hooks)
if [ -f "fs/stat.c.rej" ]; then
    echo ">>> Found stat.c.rej. Applying manual fix..."
    
    # Inject the massive function definition
    if ! grep -q "static inline int zeromount_stat_hook" fs/stat.c; then
        sed -i '/static int vfs_statx(/i\
#ifdef CONFIG_ZEROMOUNT\
static inline int zeromount_stat_hook(int dfd, struct filename *filename, struct kstat *stat, unsigned int request_mask, int flags) {\
    if (zm_is_recursive() || IS_ERR_OR_NULL(filename)) return -ENOENT;\
    if (filename && filename->name) {\
        const char *kname = filename->name;\
        if (kname[0] != '\''/'\'') {\
            char *abs_path = zeromount_build_absolute_path(dfd, kname);\
            if (abs_path) {\
                char *resolved = zeromount_resolve_path(abs_path);\
                if (resolved) {\
                    struct path zm_path;\
                    int zm_ret;\
                    zm_enter();\
                    zm_ret = kern_path(resolved, (flags & AT_SYMLINK_NOFOLLOW) ? 0 : LOOKUP_FOLLOW, &zm_path);\
                    zm_exit();\
                    kfree(resolved);\
                    kfree(abs_path);\
                    if (zm_ret == 0) {\
                        zm_ret = vfs_getattr(&zm_path, stat, request_mask, (flags & AT_SYMLINK_NOFOLLOW) ? AT_SYMLINK_NOFOLLOW : 0);\
                        path_put(&zm_path);\
                        return zm_ret;\
                    }\
                } else {\
                    kfree(abs_path);\
                }\
            }\
        }\
    }\
    return -ENOENT;\
}\
#endif\
' fs/stat.c
    fi

    # Inject the hook call itself
    if ! grep -q "zeromount_stat_hook(dfd, filename" fs/stat.c; then
        if grep -q "CONFIG_KSU_SUSFS_UNICODE_FILTER" fs/stat.c; then
            sed -i '/#ifdef CONFIG_KSU_SUSFS_UNICODE_FILTER/i\
#ifdef CONFIG_ZEROMOUNT\
    if (filename) {\
        int zm_ret = zeromount_stat_hook(dfd, filename, stat, request_mask, flags);\
        if (zm_ret != -ENOENT)\
            return zm_ret;\
    }\
#endif\
' fs/stat.c
        else
            sed -i '/unsigned lookup_flags = LOOKUP_FOLLOW | LOOKUP_AUTOMOUNT;/a\
#ifdef CONFIG_ZEROMOUNT\
    if (filename) {\
        int zm_ret = zeromount_stat_hook(dfd, filename, stat, request_mask, flags);\
        if (zm_ret != -ENOENT)\
            return zm_ret;\
    }\
#endif\
' fs/stat.c
        fi
    fi
    rm -f fs/stat.c.rej
fi

# 6. xattr.c (Resolves 6.6 mnt_userns -> idmap shift)
if [ -f "fs/xattr.c.rej" ]; then
    echo ">>> Found xattr.c.rej. Applying manual fix..."
    if ! grep -q "zeromount_spoof_xattr" fs/xattr.c; then
        sed -i '/error = xattr_permission(/i\
#ifdef CONFIG_ZEROMOUNT\
    {\
        ssize_t zm_ret;\
        zm_ret = zeromount_spoof_xattr(dentry, name, value, size);\
        if (zm_ret != -EOPNOTSUPP)\
            return zm_ret;\
    }\
#endif\
' fs/xattr.c
    fi
    rm -f fs/xattr.c.rej
fi

# 7. readdir.c (Resolves the 6.6 and older getdents iteration restructuring)
if [ -f "fs/readdir.c.rej" ]; then
    echo ">>> Found readdir.c.rej. Applying manual fix..."
    
    # We now inject the entire block as a singular, scoped entity to prevent scope-leakage
    # This prevents 'unused variable' errors because it's now all contained inside one #ifdef
    sed -i '/f = fdget_pos(fd);/i\
#ifdef CONFIG_ZEROMOUNT\
    int initial_count = count;\
    if (f.file->f_pos >= ZEROMOUNT_MAGIC_POS) {\
        error = 0;\
        goto skip_real_iterate;\
    }\
#endif\
' fs/readdir.c

    # Now we inject the logic block, ensuring the label is IN the same #ifdef scope
    sed -i '/struct linux_dirent __user \*.*lastdirent/i\
#ifdef CONFIG_ZEROMOUNT\
skip_real_iterate:\
    if (error >= 0 && !signal_pending(current)) {\
        zeromount_inject_dents(f.file, (void __user **)&dirent, &count, &f.file->f_pos);\
        if (count != initial_count)\
            error = initial_count - count;\
        goto zm_out;\
    }\
zm_out:\
#endif\
' fs/readdir.c

    sed -i '/struct linux_dirent64 __user \*.*lastdirent/i\
#ifdef CONFIG_ZEROMOUNT\
skip_real_iterate:\
    if (error >= 0 && !signal_pending(current)) {\
        zeromount_inject_dents64(f.file, (void __user **)&dirent, &count, &f.file->f_pos);\
        if (count != initial_count)\
            error = initial_count - count;\
        goto zm_out;\
    }\
zm_out:\
#endif\
' fs/readdir.c

    sed -i '/struct compat_linux_dirent __user \*.*lastdirent/i\
#ifdef CONFIG_ZEROMOUNT\
skip_real_iterate:\
    if (error >= 0 && !signal_pending(current)) {\
        zeromount_inject_dents(f.file, (void __user **)&dirent, &count, &f.file->f_pos);\
        if (count != initial_count)\
            error = initial_count - count;\
        goto zm_out;\
    }\
zm_out:\
#endif\
' fs/readdir.c

    # Remove the old zm_out injection since we now place it inside the block
    sed -i '/fdput_pos(f);/d' fs/readdir.c 2>/dev/null || true
    rm -f fs/readdir.c.rej
fi

# Final Audit
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
