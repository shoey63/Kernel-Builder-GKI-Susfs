#!/usr/bin/env bash
# scripts/inject_ReSukiSU.sh

echo ">>> Executing Legacy Integration Module for ReSukiSU..."
echo ">>> [NOTICE] Bypassing CI variables. Hardcoding to frozen ResukiSU-Legacy branch..."

# Updated to the newly renamed repository
LEGACY_REPO="https://github.com/shoey63/BakaSU.git"
LEGACY_BRANCH="ResukiSU-Legacy"
# The specific commit hash required to match the v4.2.0-rc3 Manager APK
TARGET_APK_HASH="239e1e88"

echo ">>> 1. Cloning frozen legacy repository..."
git clone -b "${LEGACY_BRANCH}" "${LEGACY_REPO}" "${MANAGER_DIR}"

# Prevent setup.sh from performing a redundant clone
ln -sfn "../${MANAGER_DIR}" "common/${MANAGER_DIR}"
cd common
bash "${MANAGER_DIR}/kernel/setup.sh" "${LEGACY_BRANCH}"
cd ..

cd "${MANAGER_DIR}"

echo ">>> 2. Anchoring Kbuild to legacy APK hash (${TARGET_APK_HASH})..."
UPSTREAM_HASH="${TARGET_APK_HASH}"
CALCULATED_TAG=$(git describe --tags --abbrev=0 "${TARGET_APK_HASH}" 2>/dev/null || echo "v4.2.0-rc3")
CALCULATED_COUNT=$(git rev-list --count "${TARGET_APK_HASH}" 2>/dev/null || echo "11950")
UPSTREAM_BRANCH="${LEGACY_BRANCH}"

cd ..

echo "  -> Target Tag: $CALCULATED_TAG"
echo "  -> Target Hash: $UPSTREAM_HASH"
echo "  -> Target Count: $CALCULATED_COUNT"
echo ">>> ReSukiSU legacy integration complete."
