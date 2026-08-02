#!/usr/bin/env bash
set -euo pipefail

cd kernel_workspace
[ -d common ] || { echo "[-] common/ not found in kernel_workspace" >&2; exit 1; }

VARIANT=$1
KSU_VARIANT_REF=$(echo "${KSU_VARIANT_REF:-}" | xargs)
USE_DYNAMIC_TRANSPLANT=$(echo "${USE_DYNAMIC_TRANSPLANT:-false}" | tr '[:upper:]' '[:lower:]')

# 1. Map the expected directory name based on the variant's internal setup.sh hardcoding
case "${VARIANT}" in
    "KernelSU-Next")
        MANAGER_DIR="KernelSU-Next"
        ;;
    "SukiSU-Ultra" | "ReSukiSU" | "KernelSU")
        MANAGER_DIR="KernelSU"
        ;;
    *)
        echo "[-] Error: Unsupported Variant '${VARIANT}'. Selected variant not supported" >&2
        exit 1
        ;;
esac

rm -rf "${MANAGER_DIR}"
echo "=== Integrating ${VARIANT} ==="

# ========================================================================
# CANARY DYNAMIC TRANSPLANT
# ========================================================================
if [[ "${USE_DYNAMIC_TRANSPLANT}" == "true" ]]; then

    if [[ "${VARIANT}" == "KernelSU-Next" ]]; then
        echo ">>> [CANARY] Executing Automated Dynamic Transplant for KernelSU-Next..."
        
        echo ">>> 1. Cloning pristine official KernelSU-Next..."
        git clone https://github.com/KernelSU-Next/KernelSU-Next.git "${MANAGER_DIR}"
        
        # Prevent setup.sh from performing a redundant clone and execute it BEFORE transplanting
        # so it doesn't git-reset our dynamic cherry-picks!
        ln -sfn "../${MANAGER_DIR}" "common/${MANAGER_DIR}"
        
        echo ">>> Executing native setup.sh to initialize branch..."
        cd common
        bash "${MANAGER_DIR}/kernel/setup.sh" dev
        cd ..
        
        cd "${MANAGER_DIR}"

        # CAPTURE THIS IMMEDIATELY BEFORE ANY CHERRY-PICKS!
        # Walk backward from HEAD, ignoring commits that ONLY touch website/docs
        UPSTREAM_HASH=$(git log -n 1 --format="%H" -- . ":!website" ":!docs")

        echo ">>> 2. Scraping the latest official release tag..."
        CALCULATED_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0")
        echo "  -> Target Tag: $CALCULATED_TAG"


        echo ">>> 3. Fetching Pershoot's live laboratory..."
        git remote add pershoot https://github.com/pershoot/KernelSU-Next.git
        git fetch pershoot dev-susfs

        echo ">>> 4. Calculating the merge-base for SuSFS commits..."
        MERGE_BASE=$(git merge-base HEAD pershoot/dev-susfs)

        echo ">>> 5. Generating dynamic commit list (Filtering out CI hacks)..."
        VALID_COMMITS=$(git log --reverse --format="%H %s" ${MERGE_BASE}..pershoot/dev-susfs | grep -v -i -E "setup:|manager" | awk '{print $1}')

        echo ">>> Configuring dummy Git identity for transplant operations..."
        git config --global user.email "runner@github.actions"
        git config --global user.name "GitHub Actions Canary"

        echo ">>> 6. Transplanting pure SuSFS commits onto upstream tree..."
        for commit in $VALID_COMMITS; do
            COMMIT_TITLE=$(git log --format="%s" -n 1 "$commit")
            echo "  -> Transplanting: $COMMIT_TITLE"
            if ! git cherry-pick "$commit"; then
                echo "[-] CRITICAL: Merge conflict detected on commit: $commit"
                echo ">>> Dumping conflict markers to console:"
                git --no-pager diff --diff-filter=U
                git cherry-pick --abort
                exit 1
            fi
        done

        echo ">>> Dynamic SuSFS integration complete!"

        # Step back out to the main workspace
        cd .. 

        # Lock in variables for the Kbuild Gatekeeper
        UPSTREAM_REPO="KernelSU-Next/KernelSU-Next"
        UPSTREAM_BRANCH="dev"
        CALCULATED_COUNT=$(git -C "${MANAGER_DIR}" rev-list --count "${UPSTREAM_HASH}")
        
    elif [[ "${VARIANT}" == "KernelSU" || "${VARIANT}" == "ReSukiSU" || "${VARIANT}" == "SukiSU-Ultra" ]]; then
        echo ">>> [CANARY] Executing Automated Dynamic Transplant for ${VARIANT}..."

        # Route to the correct GitHub organization/owner
        if [[ "${VARIANT}" == "KernelSU" ]]; then
            REPO_OWNER="tiann"
        else
            REPO_OWNER="${VARIANT}"
        fi

        echo ">>> 1. Cloning pristine official ${VARIANT}..."
        git clone "https://github.com/${REPO_OWNER}/${VARIANT}.git" "${MANAGER_DIR}"

        # Prevent setup.sh from performing a redundant clone and execute it BEFORE transplanting
        ln -sfn "../${MANAGER_DIR}" "common/${MANAGER_DIR}"
        
        echo ">>> Executing native setup.sh to initialize branch..."
        cd common
        bash "${MANAGER_DIR}/kernel/setup.sh" main
        cd ..

        cd "${MANAGER_DIR}"

        # CAPTURE THIS IMMEDIATELY BEFORE ANY CHERRY-PICKS!
        UPSTREAM_HASH=$(git log -n 1 --format="%H")

        echo ">>> 2. Scraping the latest official release tag..."
        CALCULATED_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0")
        echo "  -> Target Tag: $CALCULATED_TAG"

        echo ">>> Configuring dummy Git identity for transplant operations..."
        git config --global user.email "runner@github.actions"
        git config --global user.name "GitHub Actions Canary"

        echo ">>> 3. Fetching and cherry-picking susfs v 2.20 commit..."
        git fetch "https://github.com/shoey63/${VARIANT}.git" $KSU_VARIANT_REF

        if ! git cherry-pick FETCH_HEAD; then
            echo "[-] CRITICAL: Merge conflict detected on ${VARIANT} patch!"
            echo ">>> Dumping conflict markers to console:"
            git --no-pager diff --diff-filter=U
            git cherry-pick --abort
            exit 1
        fi

        echo ">>> Dynamic integration complete!"

        # Step back out to the main workspace
        cd .. 

        # Lock in variables for the Kbuild Gatekeeper
        UPSTREAM_REPO="${VARIANT}/${VARIANT}"
        UPSTREAM_BRANCH="main"
        CALCULATED_COUNT=$(git -C "${MANAGER_DIR}" rev-list --count "${UPSTREAM_HASH}")
    
    else
        echo "[-] Error: Dynamic transplant requested but not supported for '${VARIANT}'." >&2
        exit 1
    fi

# ========================================================================
# STABLE / LEGACY VARIANTS
# ========================================================================
else
    echo ">>> [STABLE] Cloning custom pipeline branch: ${KSU_VARIANT_REF} from ${KSU_VARIANT_REPO_URL}..."
    git clone "${KSU_VARIANT_REPO_URL}" -b "${KSU_VARIANT_REF}" "${MANAGER_DIR}"

    # Prevent setup.sh from performing a redundant clone by spoofing its presence in common/
    ln -sfn "../${MANAGER_DIR}" "common/${MANAGER_DIR}"

    echo ">>> Executing native setup.sh..."
    cd common
    bash "${MANAGER_DIR}/kernel/setup.sh" "${KSU_VARIANT_REF}"
    cd ..

    # Route the URL and default branch based on the variant for sync calculation
    if [[ "${VARIANT}" == "KernelSU-Next" ]]; then
        UPSTREAM_REPO="KernelSU-Next/KernelSU-Next"
        UPSTREAM_BRANCH="dev"
    elif [[ "${VARIANT}" == "SukiSU-Ultra" ]]; then
        UPSTREAM_REPO="SukiSU-Ultra/SukiSU-Ultra"
        UPSTREAM_BRANCH="main"
    elif [[ "${VARIANT}" == "ReSukiSU" ]]; then
        UPSTREAM_REPO="ReSukiSU/ReSukiSU"
        UPSTREAM_BRANCH="main"
    elif [[ "${VARIANT}" == "KernelSU" ]]; then
        UPSTREAM_REPO="tiann/KernelSU"
        UPSTREAM_BRANCH="main"
    else
        echo "Error: Unknown variant '${VARIANT}'" >&2
        exit 1
    fi

    echo ">>> Locating official upstream sync point for ${UPSTREAM_REPO}..."
    git -C "${MANAGER_DIR}" fetch --quiet "https://github.com/${UPSTREAM_REPO}.git" "${UPSTREAM_BRANCH}"
    RAW_BASE=$(git -C "${MANAGER_DIR}" merge-base HEAD FETCH_HEAD)

    # Walk backward down the official mainline branch, ignoring commits that ONLY touch website/docs
    set +o pipefail
    UPSTREAM_HASH=$(git -C "${MANAGER_DIR}" log --first-parent "${RAW_BASE}" --format="%H" -n 1 -- . ":!website" ":!docs")
    set -o pipefail
    
    # Calculate exact versions for the Sandbox Gatekeeper
    CALCULATED_COUNT=$(git -C "${MANAGER_DIR}" rev-list --count "${UPSTREAM_HASH}" 2>/dev/null || echo "11950")
    CALCULATED_TAG=$(git -C "${MANAGER_DIR}" describe --tags --abbrev=0 "${UPSTREAM_HASH}" 2>/dev/null || echo "v3.2.0")
fi


# ========================================================================
# KLEAF SANDBOX IMMUTABLE GATEKEEPER
# ========================================================================
SHORT_HASH=${UPSTREAM_HASH:0:7}
echo "UPSTREAM_HASH=${UPSTREAM_HASH}" >> $GITHUB_ENV

echo ">>> Injecting Sandbox Variables into Kbuild..."
TARGET_KBUILD="${MANAGER_DIR}/kernel/Kbuild"

if [ -f "$TARGET_KBUILD" ]; then

    # 2. Inject everything immutably
    {
        # --- Official & Next Namespaces ---
        echo "override KSU_GIT_VERSION_VALID := false" 
        echo "override KSU_GIT_VERSION := ${CALCULATED_COUNT}"
        echo "override KSU_GIT_TAG := ${CALCULATED_TAG}"
        echo "override KSU_COMMIT_SHA := ${SHORT_HASH}"
        echo "override KSU_GIT_BRANCH := ${UPSTREAM_BRANCH}"
        
        # --- ReSukiSU Namespaces ---
        echo "override LOCAL_GIT_EXISTS := 1"
        echo "override KSU_LOCAL_VERSION := ${CALCULATED_COUNT}"
        echo "override KSU_TAG_NAME := ${CALCULATED_TAG}"
        echo "override KSU_BRANCH_NAME := ${UPSTREAM_BRANCH}"
        echo "override KSU_COMMIT_SHA := ${SHORT_HASH}" 

        # --- SukiSU-Ultra Specific Namespaces ---
        echo "override LOCAL_COUNT := ${CALCULATED_COUNT}"
        echo "override git_commit_count := ${CALCULATED_COUNT}"
        echo "override git_short_sha := ${SHORT_HASH}"
        echo "override git_branch := ${UPSTREAM_BRANCH}"
        echo "override git_latest_tag := ${CALCULATED_TAG}"

        cat "$TARGET_KBUILD"
    } > "${TARGET_KBUILD}.tmp" && mv "${TARGET_KBUILD}.tmp" "$TARGET_KBUILD"

    echo "  -> Prepend Immutable Count: ${CALCULATED_COUNT}"
    echo "  -> Prepend Immutable Tag: ${CALCULATED_TAG}"
    echo "  -> Prepend Immutable SHA: ${SHORT_HASH}"
    echo "  -> Prepend Immutable Branch: ${UPSTREAM_BRANCH}"
fi

echo ">>> Injecting Bazel symlink..."
DRIVER_ROOT="common/drivers"
rm -rf "${DRIVER_ROOT}/kernelsu"
ln -sfn "../../${MANAGER_DIR}/kernel" "${DRIVER_ROOT}/kernelsu"
[ -L "${DRIVER_ROOT}/kernelsu" ] || { echo "[-] Symlink failed" >&2; exit 1; }

echo ">>> ${MANAGER_DIR} architecture locked, sanitized and integrated!"
