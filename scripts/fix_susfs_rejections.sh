#!/usr/bin/env bash
# scripts/fix_susfs_rejections.sh
set -euo pipefail

echo ">>> Starting SUSFS patch fixup routine..."

# Step into the kernel workspace where 'common' actually lives
cd kernel_workspace

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
