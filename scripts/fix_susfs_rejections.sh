#!/usr/bin/env bash
# scripts/fix_susfs_rejections.sh
set -euo pipefail

echo ">>> Starting SUSFS patch fixup routine..."
cd kernel_workspace

ENABLE_UPSTREAM_FIXES="true" # <-- SWITCH: Change to "true" to re-enable hotfixes

if [ "$ENABLE_UPSTREAM_FIXES" = "true" ]; then

# 1. Kernel 5.10: Fix preinit.c API Mismatches (KernelSU & SuSFS)
if [ "${BASE_VER:-}" = "5.10" ]; then
    echo ">>> Checking close_fd API compatibility in preinit.c..."
    PREINIT_FILE="common/drivers/kernelsu/preinit/preinit.c"
    
    if [ -f "$PREINIT_FILE" ]; then
        if grep -q "ksu___close_fd" "$PREINIT_FILE"; then
            echo "  -> Translating obsolete SuSFS macro to native 5.10 API..."
            sed -i 's/ksu___close_fd/__close_fd/g' "$PREINIT_FILE"
        fi
        
        if grep -E -q "\bclose_fd\(" "$PREINIT_FILE"; then
            echo "  -> Translating modern close_fd() to native 5.10 __close_fd()..."
            sed -i -E 's/\bclose_fd\(([^)]+)\)/__close_fd(current->files, \1)/g' "$PREINIT_FILE"
        fi
    fi
fi

else
    echo ">>> [TESTING] Bypassing hotfixes (ENABLE_UPSTREAM_FIXES=false)."
fi


# 1.5. SukiSU-Ultra: Dynamic Amputation of Legacy SuSFS Hooks
if [ "${ROOT_MANAGER:-}" = "SukiSU-Ultra" ]; then
    echo ">>> SukiSU-Ultra detected via ROOT_MANAGER. Routing legacy SuSFS wrappers..."

    if [ -f "common/security/selinux/selinuxfs.c" ]; then
        sed -i 's/return my_write_context/return sel_write_context/g' common/security/selinux/selinuxfs.c
        sed -i 's/return my_write_access/return sel_write_access/g' common/security/selinux/selinuxfs.c
    fi
    
    if [ -f "common/security/selinux/hooks.c" ]; then
        sed -i 's/return my_setprocattr/return selinux_setprocattr/g' common/security/selinux/hooks.c
    fi

    # Neutralize static_branch(&ksu_su_compat_enabled) type collision (struct static_key_true vs bool)
    for f in common/fs/exec.c common/fs/open.c common/fs/stat.c; do
        if [ -f "$f" ]; then
            sed -i 's/extern struct static_key_true ksu_su_compat_enabled;//g' "$f"
            sed -i 's/static_branch_likely(&ksu_su_compat_enabled)/0/g' "$f"
        fi
    done

    # Neutralize static_branch(&ksu_is_init_rc_hook_enabled) & input hook in VFS/input
    for f in common/fs/read_write.c common/fs/stat.c common/drivers/input/input.c; do
        if [ -f "$f" ]; then
            sed -i 's/static_branch_unlikely(&ksu_is_init_rc_hook_enabled)/0/g' "$f"
            sed -i 's/static_branch_unlikely(&ksu_is_input_hook_enabled)/0/g' "$f"
        fi
    done

    # Unconditionally sever 50_ patch exec.c calls so strong SukiSU symbols don't double-fire
    if [ -f "common/fs/exec.c" ]; then
        echo ">>> [HOTFIX] Severing 50_ patch execveat hooks for SukiSU-Ultra..."
        sed -i 's/.*(void)ksu_handle_post_execveat_sucompat.*/\t\t(void)0; \/\/ ksu_handle_post_execveat_sucompat bypassed/g' common/fs/exec.c
        sed -i '1i #define KSU_NO_PREINIT 1' common/fs/exec.c
    fi

    # Prevent 3-arg ksu_handle_setresuid(ruid, euid, suid) in kernel/sys.c from colliding with 2-arg pt_regs hook
    if [ -f "common/kernel/sys.c" ]; then
        sed -i 's/(void)ksu_handle_setresuid(ruid, euid, suid);/(void)0;/g' common/kernel/sys.c
    fi
fi

# 1.6. Suppress -Werror,-Wunused-function in fs/susfs.c when SUS_SU / TRY_UMOUNT are disabled
if [ -f "common/fs/susfs.c" ]; then
    echo ">>> Marking unused cred helper functions as __maybe_unused in fs/susfs.c..."
    sed -i 's/static struct cred \*susfs_switch_to_ksu_domain/static __maybe_unused struct cred *susfs_switch_to_ksu_domain/g' common/fs/susfs.c
    sed -i 's/static void susfs_restore_creds/static __maybe_unused void susfs_restore_creds/g' common/fs/susfs.c
fi

# 2. Kernel 6.6+: Fix mm/rmap.c Redundant SuSFS Backport
if [ -f "common/mm/rmap.c.rej" ]; then
    echo ">>> Found rmap.c.rej. Analyzing kernel version compatibility..."
    if grep -q "tlb_gather_mmu_vma" "common/mm/rmap.c"; then
        echo "  -> Native mmu_gather logic detected in source (6.6+ behavior)."
        echo "  -> The SuSFS backport is redundant. Safely ignoring the rejection!"
        rm "common/mm/rmap.c.rej"
    else
        echo "  [-] CRITICAL: Kernel lacks native TLB backport and genuinely needs the patch." >&2
    fi
fi

# 3. Kernel 6.6+: Fix fs/proc/task_mmu.c show_smaps_rollup rejection
if [ -f "common/fs/proc/task_mmu.c.rej" ]; then
    echo ">>> Found task_mmu.c.rej. Analyzing failure type..."
    if grep -q "show_smaps_rollup" "common/fs/proc/task_mmu.c.rej"; then
        echo "  -> show_smaps_rollup rejection detected. Injecting bypass logic surgically..."
        
        # Use an awk state machine to inject EXACTLY once, only inside show_smaps_rollup
        awk '
        BEGIN { state = 0 }
        
        # State 0: Hunt for the target function
        state == 0 && /static int show_smaps_rollup/ { state = 1 }
        
        # State 1: Inside function, hunt for the specific "if" block
        state == 1 && /if \(vma->vm_start < last_vma_end\) \{/ {
            print "#ifdef CONFIG_KSU_SUSFS_SUS_MAP"
            print "\t\tif (vma->vm_file && SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))"
            print "\t\t\tgoto bypass_orig_flow;"
            print "#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP"
            state = 2
        }
        
        # State 2: Hunt for the VERY NEXT variable assignment to inject the label
        state == 2 && /last_vma_end = vma->vm_end;/ {
            print "#ifdef CONFIG_KSU_SUSFS_SUS_MAP"
            print "bypass_orig_flow:"
            print "#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MAP"
            state = 3 # Shut down injection logic permanently
        }
        
        { print $0 }
        ' common/fs/proc/task_mmu.c > common/fs/proc/task_mmu.tmp && mv common/fs/proc/task_mmu.tmp common/fs/proc/task_mmu.c

        # Sanity validation
        if grep -q 'bypass_orig_flow:' common/fs/proc/task_mmu.c; then
            echo "  -> task_mmu.c bypass logic fix verified!"
            rm "common/fs/proc/task_mmu.c.rej"
        else
            echo "  [-] WARNING: task_mmu.c bypass fix failed!" >&2
        fi
    fi
fi

# Final Validation
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
