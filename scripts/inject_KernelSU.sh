#!/usr/bin/env bash
# scripts/inject_KernelSU.sh

echo ">>> Executing Integration Module for standard KernelSU..."

# 1. Universally clone the target branch handed down by the YAML
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
    # Hard-reset to the exact verified hash before applying patches
    git reset --hard "${UPSTREAM_HASH}"

    echo ">>> 4. Fetching Simonpunk's dynamic 10_enable_susfs_for_ksu patch..."
    PATCH_URL="https://gitlab.com/simonpunk/susfs4ksu/-/raw/gki-android15-6.6-dev/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch"

    if wget -qO 10_enable_susfs_for_ksu.patch "$PATCH_URL"; then
        echo ">>> 5. Applying SuSFS patch dynamically..."
        patch -p1 < 10_enable_susfs_for_ksu.patch || exit 1
        
        echo ">>> 6. Injecting SuSFS Macros & Compiler Overrides into Kbuild..."
        cat << 'EOF' >> kernel/Kbuild

# --- Force SuSFS Macros and Compiler Overrides ---
ccflags-y += -Wno-pointer-bool-conversion
ccflags-y += -DCONFIG_KSU_SUSFS=1
ccflags-y += -DCONFIG_KSU_SUSFS_SUS_PATH=1
ccflags-y += -DCONFIG_KSU_SUSFS_SUS_MOUNT=1
ccflags-y += -DCONFIG_KSU_SUSFS_SUS_KSTAT=1
ccflags-y += -DCONFIG_KSU_SUSFS_SPOOF_UNAME=1
ccflags-y += -DCONFIG_KSU_SUSFS_ENABLE_LOG=1
ccflags-y += -DCONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=1
ccflags-y += -DCONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=1
ccflags-y += -DCONFIG_KSU_SUSFS_OPEN_REDIRECT=1
ccflags-y += -DCONFIG_KSU_SUSFS_SUS_MAP=1
# --- Print SuSFS Version ---
ifeq ($(strip $(CONFIG_KSU_SUSFS)),y)
ifeq ($(shell test -e $(srctree)/fs/susfs.c; echo $$?),0)
$(eval SUSFS_VERSION=$(shell cat $(srctree)/include/linux/susfs.h | grep -E '^#define SUSFS_VERSION' | cut -d' ' -f3 | sed 's/"//g'))
$(info -- SuSFS version: $(SUSFS_VERSION))
endif
endif
EOF
        rm 10_enable_susfs_for_ksu.patch
    else
        echo "[-] CRITICAL: Failed to download the SuSFS patch."
        exit 1
    fi
    
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

# 7. Calculate the official counts EXACTLY from the rock-solid hash
CALCULATED_COUNT=$(git rev-list --count "${UPSTREAM_HASH}" 2>/dev/null || echo "11950")
CALCULATED_TAG=$(git describe --tags --abbrev=0 "${UPSTREAM_HASH}" 2>/dev/null || echo "v0.0.0")

# Exit the MANAGER_DIR universally
cd ..

echo "  -> Target Tag: $CALCULATED_TAG"
echo "  -> Target Hash: $UPSTREAM_HASH"
echo "  -> Target Count: $CALCULATED_COUNT"
echo ">>> Standard KernelSU injection complete."
