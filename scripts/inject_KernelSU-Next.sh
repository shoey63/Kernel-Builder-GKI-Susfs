#!/usr/bin/env bash
# scripts/inject_KernelSU-Next.sh
# Dynamic SuSFS integration module for KernelSU-Next

echo ">>> Executing Integration Module for KernelSU-Next..."

echo ">>> 1. Cloning target branch (${KSU_VARIANT_REF}) from ${KSU_VARIANT_REPO_URL}..."
git clone -b "${KSU_VARIANT_REF}" "${KSU_VARIANT_REPO_URL}" "${MANAGER_DIR}"

ln -sfn "../${MANAGER_DIR}" "common/${MANAGER_DIR}"
cd common
bash "${MANAGER_DIR}/kernel/setup.sh" "${KSU_VARIANT_REF}"
cd ..

cd "${MANAGER_DIR}"

echo ">>> 2. Fetching upstream data from ${UPSTREAM_REPO} to cross-reference..."
git fetch --quiet "https://github.com/${UPSTREAM_REPO}.git" "${TARGET_BRANCH}"

if [ "${USE_DYNAMIC_TRANSPLANT}" == "true" ]; then
    echo ">>> 3. Dynamic mode active: Anchoring clone to YAML-provided Upstream Hash (${UPSTREAM_HASH:0:7})..."
    # Hard-reset to the exact verified hash before pulling in Pershoot's lab
    git reset --hard "${UPSTREAM_HASH}"

    echo ">>> 4. Fetching Pershoot's live laboratory..."
    git remote add pershoot https://github.com/pershoot/KernelSU-Next.git
    git fetch pershoot dev-susfs

    echo ">>> Configuring dummy Git identity for transplant operations..."
    git config --global user.email "runner@github.actions"
    git config --global user.name "GitHub Actions Canary"

    echo ">>> 5. Squashing and merging SuSFS features onto pristine upstream tree..."
    if ! git merge --squash pershoot/dev-susfs; then
        echo "[-] CRITICAL: Merge conflict detected during squash merge!"
        git --no-pager diff --diff-filter=U
        exit 1
    fi
 
    git commit -m "Merge susfs features from pershoot"
    UPSTREAM_BRANCH="${TARGET_BRANCH}"
else
    echo ">>> 3. Stable mode active: Calculating exact upstream anchor commit via merge-base..."
    
    # Mathematically finds the divergence point, bypassing the local squash-merge commit
    UPSTREAM_HASH=$(git merge-base HEAD FETCH_HEAD)
    echo "  -> Found mathematically true upstream anchor: ${UPSTREAM_HASH:0:7}"
    
    # Export it so fetch_manager.sh can use it in the exact-match API hunt later
    echo "UPSTREAM_HASH=$UPSTREAM_HASH" >> $GITHUB_ENV
    UPSTREAM_BRANCH="${KSU_VARIANT_REF}"
fi

echo ">>> Auditing and applying universal SELinux & SuSFS hotfixes (masked by assume-unchanged)..."

# Fix #1: Missing susfs_set_batch_sid() in handle_sepolicy() (rules.c)
if [ -f "kernel/selinux/rules.c" ] && [ "$(grep -c 'susfs_set_batch_sid();' kernel/selinux/rules.c)" -lt 2 ] && grep -q 'reset_avc_cache(0);' kernel/selinux/rules.c; then
    sed -i '/#else/{N;s/#else\n    reset_avc_cache(0);/#else\n    reset_avc_cache(0);\n    susfs_set_batch_sid();/2}' kernel/selinux/rules.c
    echo "  [+] APPLIED Fix #1: Injected missing susfs_set_batch_sid() into handle_sepolicy() (rules.c)."
else
    echo "  [i] SKIPPED Fix #1: susfs_set_batch_sid() already present in both policy handlers (or rules.c refactored)."
fi

# Fix #2: MLS CEXPR_L2H2 constraint typo (scontext -> tcontext in selinux_hide.c)
if [ -f "kernel/feature/selinux_hide.c" ] && grep -A 1 "case CEXPR_L2H2:" kernel/feature/selinux_hide.c | grep -q "scontext->range.level\[0\]"; then
    sed -i '/case CEXPR_L2H2:/{n;s/scontext->range.level\[0\]/tcontext->range.level[0]/;}' kernel/feature/selinux_hide.c
    echo "  [+] APPLIED Fix #2: Corrected CEXPR_L2H2 MLS range check from scontext to tcontext (selinux_hide.c)."
else
    echo "  [i] SKIPPED Fix #2: CEXPR_L2H2 scontext bug not found in selinux_hide.c (already fixed upstream)."
fi

# Fix #3a: Unsafe LTO function pointer lookup for security_dump_masked_av
if [ -f "kernel/feature/selinux_hide.c" ] && grep -q "^[[:space:]]*security_dump_masked_av_fn = find_kernel_symbol_exact" kernel/feature/selinux_hide.c; then
    sed -i 's/^\([[:space:]]*\)security_dump_masked_av_fn = find_kernel_symbol_exact/\1\/\/ security_dump_masked_av_fn = find_kernel_symbol_exact/g' kernel/feature/selinux_hide.c
    echo "  [+] APPLIED Fix #3a: Disabled dynamic symbol lookup for security_dump_masked_av_fn (selinux_hide.c)."
else
    echo "  [i] SKIPPED Fix #3a: security_dump_masked_av_fn lookup not active (already disabled or fixed)."
fi

# Fix #3b: Unsafe LTO function pointer lookup for context_struct_compute_av
if [ -f "kernel/feature/selinux_hide.c" ] && grep -q "^[[:space:]]*context_struct_compute_av_fn = find_kernel_symbol_exact" kernel/feature/selinux_hide.c; then
    sed -i 's/^\([[:space:]]*\)context_struct_compute_av_fn = find_kernel_symbol_exact/\1\/\/ context_struct_compute_av_fn = find_kernel_symbol_exact/g' kernel/feature/selinux_hide.c
    echo "  [+] APPLIED Fix #3b: Disabled dynamic symbol lookup for context_struct_compute_av_fn (selinux_hide.c)."
else
    echo "  [i] SKIPPED Fix #3b: context_struct_compute_av_fn lookup not active (already disabled or fixed)."
fi

# Fix #4a: Strip custom CMD_SUSFS_SET_SUS_PATH_UID_FILTER case from dispatch.c
if [ -f "kernel/supercall/dispatch.c" ] && grep -q "CMD_SUSFS_SET_SUS_PATH_UID_FILTER" kernel/supercall/dispatch.c; then
    sed -i '/case CMD_SUSFS_SET_SUS_PATH_UID_FILTER:/,+2d' kernel/supercall/dispatch.c
    echo "  [+] APPLIED Fix #4a: Removed unsupported CMD_SUSFS_SET_SUS_PATH_UID_FILTER case from dispatch.c."
else
    echo "  [i] SKIPPED Fix #4a: CMD_SUSFS_SET_SUS_PATH_UID_FILTER not present in dispatch.c."
fi

# Fix #4b: Strip custom susfs_parse_sus_path_app_strings() from pkg_observer.c
if [ -f "kernel/manager/pkg_observer.c" ] && grep -q "susfs_parse_sus_path_app_strings" kernel/manager/pkg_observer.c; then
    sed -i '/susfs_parse_sus_path_app_strings();/d' kernel/manager/pkg_observer.c
    echo "  [+] APPLIED Fix #4b: Removed unsupported susfs_parse_sus_path_app_strings() from pkg_observer.c."
else
    echo "  [i] SKIPPED Fix #4b: susfs_parse_sus_path_app_strings() not present in pkg_observer.c."
fi

# Calculate the official counts EXACTLY from the rock-solid hash
CALCULATED_COUNT=$(git rev-list --count "${UPSTREAM_HASH}" 2>/dev/null || echo "11950")
CALCULATED_TAG=$(git describe --tags --abbrev=0 "${UPSTREAM_HASH}" 2>/dev/null || echo "v0.0.0")

cd .. 

echo "  -> Target Tag: $CALCULATED_TAG"
echo "  -> Target Hash: $UPSTREAM_HASH"
echo "  -> Target Count: $CALCULATED_COUNT"
echo ">>> KernelSU-Next integration complete."
