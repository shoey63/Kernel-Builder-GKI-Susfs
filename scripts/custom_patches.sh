#!/usr/bin/env bash
set -euo pipefail

echo "=== Applying Custom Kernel Patches ==="
cd kernel_workspace/common

echo ">>> Parsing Target Version from YAML Inputs..."
# Fallback to 6.1 if the YAML didn't pass anything
TARGET_RAW=${TARGET_VERSION:-"6.1"}
SU_VARIANT=${SU_VARIANT:-"KernelSU-Next"}

# Extract the base version (turns 6.6.118 into 6.6)
BASE_VER=$(echo "$TARGET_RAW" | cut -d. -f1,2)

# Dynamically map the base version to the Super-Builders branch
if [ "$BASE_VER" == "6.12" ]; then
    GKI_BRANCH="android16-6.12"
elif [ "$BASE_VER" == "6.6" ]; then
    GKI_BRANCH="android15-6.6"
elif [ "$BASE_VER" == "5.15" ]; then
    GKI_BRANCH="android14-5.15"
elif [ "$BASE_VER" == "5.10" ]; then
    GKI_BRANCH="android13-5.10"
else
    GKI_BRANCH="android14-6.1"
fi

echo ">>> Target Environment Detected: $GKI_BRANCH (from input $TARGET_RAW) with $SU_VARIANT"

# Construct the exact URL pointing to YOUR fork
PATCH_URL="https://raw.githubusercontent.com/shoey63/Super-Builders/main/${GKI_BRANCH}/${SU_VARIANT}/patches/60_zeromount-${GKI_BRANCH}.patch"

echo ">>> Fetching native ZeroMount patch directly from your Super-Builders fork..."
echo "    -> $PATCH_URL"

# Download the patch dynamically
if wget -qO native_zeromount.patch "$PATCH_URL"; then
    echo ">>> Successfully downloaded native patch! Injecting into kernel..."
    patch -p1 < native_zeromount.patch || echo "[-] Minor context mismatches detected. Passing to fixup routine..."
else
    echo "[-] WARNING: Could not find a native patch for $GKI_BRANCH / $SU_VARIANT on your fork."
    echo "    -> Falling back to the universal 6.1 patch + dynamic fixups..."
    patch -p1 < ../../patches/60_zeromount-android14-6.1.patch || true
fi

echo ">>> Starting ZeroMount patch fixup routine..."

# 1. Kconfig & Defconfig
echo ">>> Resolving fs/Kconfig..."
if ! grep -q "config ZEROMOUNT" fs/Kconfig; then
    echo -e '\nconfig ZEROMOUNT\n\tbool "ZeroMount Path Redirection Subsystem"\n\tdefault y' >> fs/Kconfig
fi
rm -f fs/Kconfig.rej arch/arm64/configs/gki_defconfig.rej

# 2. d_path.c
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

# 3. proc/base.c
if [ -f "fs/proc/base.c.rej" ] || grep -q "zeromount_should_skip" fs/proc/base.c; then
    echo ">>> Managing fs/proc/base.c fixes and headers..."
    
    # 1. Ensure the header definition is present so the compiler recognizes the functions
    if ! grep -q "linux/zeromount.h" fs/proc/base.c; then
        echo ">>> Injecting missing linux/zeromount.h header into base.c..."
        sed -i '/#include "internal.h"/a\
#ifdef CONFIG_ZEROMOUNT\
#include <linux/zeromount.h>\
#endif\
' fs/proc/base.c
    fi

    # 2. Apply your existing code injection if it hasn't been added yet
    if ! grep -q "zeromount_get_static_vpath" fs/proc/base.c; then
        echo ">>> Applying manual base.c code layout fix..."
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

# 4. proc/task_mmu.c
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

# 5. stat.c
if [ -f "fs/stat.c.rej" ]; then
    echo ">>> Found stat.c.rej. Applying manual fix..."
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

# 6. xattr.c
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

# 7. readdir.c - Smarter injection with duplicate detection
if [ -f "fs/readdir.c.rej" ]; then
    echo ">>> Resolving fs/readdir.c with duplicate-label protection..."
    
    awk '
    # If we see the label already exists from the native patch, set a flag
    /^[[:space:]]*zm_out:/ { has_zm_out = 1; }
    /^[[:space:]]*skip_real_iterate:/ { has_skip = 1; }

    /^[[:space:]]*f = fdget_pos\(fd\);/ {
        # Only inject initial_count if we are not in an old_readdir function
        if (in_old != 1) {
            print "#ifndef CONFIG_ZEROMOUNT_INJECTED"
            print "    int initial_count = count;"
            print "#endif"
        }
        print $0; next
    }

    /^[[:space:]]*if \(buf\.prev_reclen\)/ {
        if (in_old != 1) {
            buf_line = $0
            getline next_line
            is_64 = index(next_line, "dirent64")
            
            print "#ifdef CONFIG_ZEROMOUNT"
            # Only inject skip_real_iterate if the native patch missed it
            if (!has_skip) {
                print "skip_real_iterate:"
                print "    if (error >= 0 && !signal_pending(current)) {"
                if (is_64) {
                    print "        zeromount_inject_dents64(f.file, (void __user **)&dirent, &count, &f.file->f_pos);"
                } else {
                    print "        zeromount_inject_dents(f.file, (void __user **)&dirent, &count, &f.file->f_pos);"
                }
                print "        if (count != initial_count)"
                print "            error = initial_count - count;"
                print "        goto zm_out;"
                print "    }"
            }
            print "#endif"
            print buf_line
            print next_line
            next
        }
    }

    /^[[:space:]]*fdput_pos\(f\);/ {
        # Only inject zm_out if the native patch missed it
        if (!has_zm_out && in_old != 1) {
            print "#ifdef CONFIG_ZEROMOUNT"
            print "zm_out:"
            print "#endif"
        }
        print $0; next
    }
    { print $0 }
    ' fs/readdir.c > fs/readdir.c.tmp && mv fs/readdir.c.tmp fs/readdir.c
    
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
