#!/usr/bin/env bash
# scripts/inject_SukiSU-Ultra.sh

echo ">>> Executing Integration Module for SukiSU-Ultra..."

# Override channel routing so both 'stable' and 'dynamic' runs pull the custom
# SuSFS pt_regs commits from the shoey63 fork (while leaving 'main' untouched).
if [ "${BUILD_CHANNEL}" != "main" ]; then
    echo ">>> [OVERRIDE] Routing SukiSU-Ultra base clone to shoey63/SukiSU-Ultra (stable)..."
    KSU_VARIANT_REPO_URL="https://github.com/shoey63/SukiSU-Ultra.git"
    KSU_VARIANT_REF="stable"
fi

echo ">>> 1. Cloning target branch (${KSU_VARIANT_REF}) from ${KSU_VARIANT_REPO_URL}..."
git clone -b "${KSU_VARIANT_REF}" "${KSU_VARIANT_REPO_URL}" "${MANAGER_DIR}"

ln -sfn "../${MANAGER_DIR}" "common/${MANAGER_DIR}"
cd common
# Run setup.sh BEFORE rebasing so it links common/drivers/kernelsu without clobbering git history
bash "${MANAGER_DIR}/kernel/setup.sh" "${KSU_VARIANT_REF}"
cd ..

cd "${MANAGER_DIR}"

echo ">>> 2. Fetching upstream data from ${UPSTREAM_REPO} to cross-reference..."
git fetch --quiet "https://github.com/${UPSTREAM_REPO}.git" "${TARGET_BRANCH}"

if [ "${USE_DYNAMIC_TRANSPLANT}" == "true" ]; then
    echo ">>> 3. Dynamic mode active: Rebasing clone onto YAML-provided Upstream Hash (${UPSTREAM_HASH:0:7})..."
    git config user.name "github-actions[bot]"
    git config user.email "github-actions[bot]@users.noreply.github.com"

    if git rebase "${UPSTREAM_HASH}"; then
        echo "  -> On-the-fly rebase succeeded cleanly!"
        UPSTREAM_BRANCH="${TARGET_BRANCH}"
    else
        echo "  -> [WARNING] Rebase conflict detected with latest upstream!"
        git rebase --abort
        echo "  -> Aborted rebase and fell back to '${KSU_VARIANT_REF}'."
        UPSTREAM_BRANCH="${KSU_VARIANT_REF}"
    fi
else
    echo ">>> 3. Stable mode active: Calculating exact upstream anchor commit via merge-base..."
    
    # Mathematically finds the divergence point, bypassing any custom emergency commits
    UPSTREAM_HASH=$(git merge-base HEAD FETCH_HEAD)
    echo "  -> Found mathematically true upstream anchor: ${UPSTREAM_HASH:0:7}"
    
    # Export it so fetch_manager.sh can use it in the exact-match API hunt later
    echo "UPSTREAM_HASH=$UPSTREAM_HASH" >> $GITHUB_ENV
    UPSTREAM_BRANCH="${KSU_VARIANT_REF}"
fi

# 4. Calculate the official counts EXACTLY from the rock-solid hash
CALCULATED_COUNT=$(git rev-list --count "${UPSTREAM_HASH}" 2>/dev/null || echo "11950")
CALCULATED_TAG=$(git describe --tags --abbrev=0 "${UPSTREAM_HASH}" 2>/dev/null || echo "v0.0.0")

cd ..

echo "  -> Target Tag: $CALCULATED_TAG"
echo "  -> Target Hash: $UPSTREAM_HASH"
echo "  -> Target Count: $CALCULATED_COUNT"

echo ">>> SukiSU-Ultra integration complete."
