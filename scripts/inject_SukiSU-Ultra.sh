#!/usr/bin/env bash
# scripts/inject_SukiSU-Ultra.sh

echo ">>> Executing Integration Module for SukiSU-Ultra..."

if [ "${USE_DYNAMIC_TRANSPLANT}" == "true" ]; then
    echo ">>> 1. Cloning pristine official SukiSU-Ultra upstream..."
     git clone -b "${TARGET_BRANCH}" "https://github.com/shoey63/SukiSU-Ultra.git" "${MANAGER_DIR}"
    
    cd "${MANAGER_DIR}"
    
    # Capture the pristine upstream hash for the Gatekeeper BEFORE we apply the SuSFS hooks
    UPSTREAM_HASH=$(git log -n 1 --format="%H" -i --grep="ci skip" --grep="skip ci" --grep="clippy" --invert-grep -- manager/ kernel/ userspace/ .github/workflows/ ":!*Cargo.lock" ":!*Cargo.toml")
    CALCULATED_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0")
    CALCULATED_COUNT=$(git rev-list --count "${UPSTREAM_HASH}")
    UPSTREAM_BRANCH="${TARGET_BRANCH}"

    echo ">>> 2. Fetching curated SuSFS patch commit from your stable branch..."
    git remote add shoey "https://github.com/shoey63/SukiSU-Ultra.git"
    git fetch --quiet shoey stable

    # Locate the exact hash of your Termux staging commit
    PATCH_COMMIT=$(git log shoey/stable --grep="chore: apply surgical SuSFS port from builtin branch" --format="%H" -n 1)

    if [ -z "$PATCH_COMMIT" ]; then
        echo "[-] Error: Could not locate the 'chore: apply surgical SuSFS port' commit on your stable branch."
        exit 1
    fi

    echo ">>> 3. Cherry-picking SuSFS hooks (Commit: $PATCH_COMMIT) onto bleeding-edge main..."
    
    # Configure temporary Git user for the cherry-pick merge
    git config --global user.email "runner@github.actions"
    git config --global user.name "GitHub Actions Canary"

    # Attempt the cherry-pick. Catch conflicts and trigger the manual trapdoor if they arise.
    if ! git cherry-pick "$PATCH_COMMIT"; then
        echo "[-] CRITICAL: Cherry-pick failed due to upstream code divergence!"
        echo "================ MERGE CONFLICTS ================"
        git status --short
        echo "-------------------------------------------------"
        git diff
        echo "================================================="
        echo "[-] CI halted. Please run your Termux staging script locally to resolve conflicts and update your stable branch."
        exit 1
    fi
    
    echo ">>> SuSFS hooks successfully woven into main!"
    cd ..

    # Run setup.sh to link the newly patched kernel code into the GKI source tree
    ln -sfn "../${MANAGER_DIR}" "common/${MANAGER_DIR}"
    cd common
    bash "${MANAGER_DIR}/kernel/setup.sh" "${TARGET_BRANCH}"
    cd ..
else
    echo ">>> Safe fallback channel detected. Cloning custom pipeline branch..."
    git clone -b "${KSU_VARIANT_REF}" "${KSU_VARIANT_REPO_URL}" "${MANAGER_DIR}"
    
    ln -sfn "../${MANAGER_DIR}" "common/${MANAGER_DIR}"
    cd common
    bash "${MANAGER_DIR}/kernel/setup.sh" "${KSU_VARIANT_REF}"
    cd ..
    
    UPSTREAM_BRANCH="${KSU_VARIANT_REF}"
    
    cd "${MANAGER_DIR}"
    
    echo ">>> Locating official upstream sync point for ${UPSTREAM_REPO}..."
    git fetch --quiet "https://github.com/${UPSTREAM_REPO}.git" "${TARGET_BRANCH}"
    RAW_BASE=$(git merge-base HEAD FETCH_HEAD)
    
    set +o pipefail
    UPSTREAM_HASH=$(git log -n 1 --first-parent "${RAW_BASE}" --format="%H" -i --grep="ci skip" --grep="skip ci" --grep="clippy" --invert-grep -- manager/ kernel/ userspace/ .github/workflows/ ":!*Cargo.lock" ":!*Cargo.toml")
    set -o pipefail

    CALCULATED_COUNT=$(git rev-list --count "${UPSTREAM_HASH}" 2>/dev/null || echo "11950")
    CALCULATED_TAG=$(git describe --tags --abbrev=0 "${UPSTREAM_HASH}" 2>/dev/null || echo "v0.0.0")
    
    cd ..
fi

# ---------------------------------------------------------
# SukiSU-Ultra 6.12+ LSM Hook API Fix
# ---------------------------------------------------------
echo ">>> Checking for Linux 6.12+ LSM API Mismatch in SukiSU-Ultra..."
K_VER=$(grep "^VERSION =" common/Makefile | tr -d ' ' | cut -d'=' -f2)
K_PATCH=$(grep "^PATCHLEVEL =" common/Makefile | tr -d ' ' | cut -d'=' -f2)

if [ "$K_VER" = "6" ] && [ "$K_PATCH" -ge "12" ]; then
    LSM_HOOK_FILE="common/drivers/kernelsu/hook/lsm_hook.c"

    if [ -f "$LSM_HOOK_FILE" ] && grep -q 'security_add_hooks' "$LSM_HOOK_FILE"; then
        echo "  -> Kernel 6.12+ detected. Disarming deprecated LSM hook registration..."
        sed -i 's/security_add_hooks.*/(void)ksu_hooks;/g' "$LSM_HOOK_FILE"
        echo "  -> lsm_hook.c runtime panic trap bypassed!"
    else
        echo "  -> LSM hook is already updated or file missing. Skipping."
    fi
else
    echo "  -> Kernel $K_VER.$K_PATCH detected. Legacy LSM string hook is perfectly valid."
fi

echo "  -> Target Tag: $CALCULATED_TAG"
echo "  -> Target Hash: $UPSTREAM_HASH"
echo "  -> Target Count: $CALCULATED_COUNT"
echo ">>> SukiSU-Ultra integration complete."
