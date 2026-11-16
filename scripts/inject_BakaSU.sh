#!/usr/bin/env bash
# scripts/inject_BakaSU.sh

echo ">>> Executing Integration Module for BakaSU..."

# 1. Universally clone the target branch handed down by the YAML
# (Dynamic = Pristine Upstream. Stable = shoey63 Fork)
echo ">>> 1. Cloning target branch (${KSU_VARIANT_REF}) from ${KSU_VARIANT_REPO_URL}..."
git clone -b "${KSU_VARIANT_REF}" "${KSU_VARIANT_REPO_URL}" "${MANAGER_DIR}"

ln -sfn "../${MANAGER_DIR}" "common/${MANAGER_DIR}"
cd common
bash "${MANAGER_DIR}/kernel/setup.sh" "${KSU_VARIANT_REF}"
cd ..

cd "${MANAGER_DIR}"

echo ">>> 2. Fetching upstream data from ${UPSTREAM_REPO} to cross-reference..."
# Safely fetch without tags to prevent local collision panics during stable runs
git fetch --quiet "https://github.com/${UPSTREAM_REPO}.git" "${TARGET_BRANCH}"

    echo ">>> Configuring dummy Git identity for transplant operations..."
    git config --global user.email "runner@github.actions"
    git config --global user.name "GitHub Actions Canary"
    
if [ "${USE_DYNAMIC_TRANSPLANT}" == "true" ]; then
    echo ">>> 3. Dynamic mode active: Anchoring pristine clone to YAML-provided Upstream Hash (${UPSTREAM_HASH:0:7})..."
    
    # Hard-reset to the exact verified hash before pulling in the sync-up lab
    git reset --hard "${UPSTREAM_HASH}"

    echo ">>> 4. Fetching BakaSU sync-up laboratory..."
    git remote add bakasu_sync https://github.com/Baka-SU/BakaSU.git
    git fetch bakasu_sync sync-up

    echo ">>> 5. Squashing and merging sync-up features onto pristine upstream tree..."
    if ! git merge --squash bakasu_sync/sync-up; then
        echo "[-] CRITICAL: Merge conflict detected during squash merge!"
        git --no-pager diff --diff-filter=U
        exit 1
    fi
    
# Force SuSFS Kconfig Default
echo ">>> Selecting KSU_SUSFS as default hooking method in Kconfig..."
sed -i 's/default KSU_TRACEPOINT_HOOK/default KSU_SUSFS/g' kernel/Kconfig
sed -i 's/depends on KSU != m/depends on n/g' kernel/Kconfig

    git add  kernel/Kconfig
    git commit -m "Merge susfs features from sync-up"
    UPSTREAM_BRANCH="${TARGET_BRANCH}"

else
    echo ">>> 3. Stable mode active: Calculating exact upstream anchor commit via merge-base..."
    
    # Mathematically finds the divergence point, bypassing any custom emergency commits
    UPSTREAM_HASH=$(git merge-base HEAD FETCH_HEAD)
    echo "  -> Found mathematically true upstream anchor: ${UPSTREAM_HASH:0:7}"
    
    # Export it so fetch_manager.sh can use it in the exact-match API hunt later
    echo "UPSTREAM_HASH=$UPSTREAM_HASH" >> $GITHUB_ENV
    UPSTREAM_BRANCH="${KSU_VARIANT_REF}"
fi

echo ">>> Auditing and applying universal BakaSU hotfixes..."

# Fix #1: Add missing <linux/task_work.h> header for TWA_RESUME in throne_tracker.c (5.10, 6.1, 6.6)
if [ -f "kernel/manager/throne_tracker.c" ] && grep -q "TWA_RESUME" "kernel/manager/throne_tracker.c" && ! grep -q "<linux/task_work.h>" "kernel/manager/throne_tracker.c"; then
    sed -i '1i #include <linux/task_work.h>' kernel/manager/throne_tracker.c
    echo "  [+] APPLIED Fix #1: Injected <linux/task_work.h> into throne_tracker.c for TWA_RESUME."
else
    echo "  [i] SKIPPED Fix #1: <linux/task_work.h> already present or TWA_RESUME not used."
fi

# Fix #2: Bypass unguarded selinux_hide_init_setxattr() call when SuSFS SELinux hide is active
if [ -f "kernel/feature/selinux_hide.c" ] && grep -q "ret = selinux_hide_init_setxattr();" "kernel/feature/selinux_hide.c"; then
    sed -i 's/ret = selinux_hide_init_setxattr();/ret = 0; \/* bypassed unguarded call under SuSFS *\//' kernel/feature/selinux_hide.c
    echo "  [+] APPLIED Fix #2: Replaced unguarded selinux_hide_init_setxattr() call with ret = 0 in selinux_hide.c."
else
    echo "  [i] SKIPPED Fix #2: selinux_hide_init_setxattr() call not found in selinux_hide.c."
fi

git add -A
if ! git diff --cached --quiet; then
    git commit -m "chore: apply BakaSU hotfixes"
fi

# 4. Calculate the official counts EXACTLY from the rock-solid hash
CALCULATED_COUNT=$(git rev-list --count "${UPSTREAM_HASH}" 2>/dev/null || echo "11950")
CALCULATED_TAG=$(git describe --tags --abbrev=0 "${UPSTREAM_HASH}" 2>/dev/null || echo "v0.0.0")

cd ..

echo "  -> Target Tag: $CALCULATED_TAG"
echo "  -> Target Hash: $UPSTREAM_HASH"
echo "  -> Target Count: $CALCULATED_COUNT"
echo ">>> BakaSU integration complete."
