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

# 6. Calculate the official counts EXACTLY from the rock-solid hash
CALCULATED_COUNT=$(git rev-list --count "${UPSTREAM_HASH}" 2>/dev/null || echo "11950")
CALCULATED_TAG=$(git describe --tags --abbrev=0 "${UPSTREAM_HASH}" 2>/dev/null || echo "v0.0.0")

cd .. 

echo "  -> Target Tag: $CALCULATED_TAG"
echo "  -> Target Hash: $UPSTREAM_HASH"
echo "  -> Target Count: $CALCULATED_COUNT"
echo ">>> KernelSU-Next integration complete."
