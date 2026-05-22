#!/usr/bin/env bash
set -euo pipefail
git config --global advice.detachedHead false

cd kernel_workspace

[ -d common ] || { echo "[-] common/ not found in kernel_workspace" >&2; exit 1; }

MANAGER_DIR="$1"
rm -rf "${MANAGER_DIR}"

echo "=== Integrating ${MANAGER_DIR} ==="
echo ">>> Cloning bleeding-edge branch: ${KSU_NEXT_REF}..."
git clone "${KSU_NEXT_REPO_URL}" -b "${KSU_NEXT_REF}" "${MANAGER_DIR}"

# --- THE LOGGING ENGINE ---
TIP_HASH=$(git -C "${MANAGER_DIR}" rev-parse --short HEAD)
TIP_MSG=$(git -C "${MANAGER_DIR}" log -1 --format="%s")

echo ">>> [PRE-FLIGHT] Proper HEAD secured:"
echo ">>> Commit: ${TIP_HASH}"
echo ">>> Message: ${TIP_MSG}"

# Mitigate 'no tags found' error 
echo ">>> Running upstream setup.sh..."
bash "${MANAGER_DIR}/kernel/setup.sh" "${KSU_NEXT_REF}"

echo "----------------------------------------------"
echo ">>> [POST-FLIGHT] setup.sh complete. HEAD currently at: $(git -C "${MANAGER_DIR}" rev-parse --short HEAD)"
echo "----------------------------------------------"

echo ">>> Neutralizing setup.sh git manipulations..."
git -C "${MANAGER_DIR}" checkout "${KSU_NEXT_REF}"

echo ">>> Executing universal version spoofing (forcing HEAD~1)..."
sed -i 's/rev-list --count HEAD/rev-list --count HEAD~1/g' "${MANAGER_DIR}/kernel/Kbuild" "${MANAGER_DIR}/kernel/Makefile" 2>/dev/null || true
sed -i 's/rev-list --count $(REPO_BRANCH)/rev-list --count HEAD~1/g' "${MANAGER_DIR}/kernel/Kbuild" "${MANAGER_DIR}/kernel/Makefile" 2>/dev/null || true

# --- THE MANAGER LOCATOR ---
# Grab the exact commit hash of the official base we just spoofed
UPSTREAM_HASH=$(git -C "${MANAGER_DIR}" rev-parse HEAD~1)

# Route the URL based on the variant being built
if [ "$1" == "KernelSU" ]; then
    UPSTREAM_REPO="tiann/KernelSU"
elif [ "$1" == "KernelSU-Next" ]; then
    UPSTREAM_REPO="KernelSU-Next/KernelSU-Next" # Change this if pershoot moves his repo
elif [ "$1" == "SukiSU-Ultra" ]; then
    UPSTREAM_REPO="rsuntk/SukiSU-Ultra" # Adjust to Ultra's actual upstream
else
    UPSTREAM_REPO="tiann/KernelSU"
fi

echo "==============================================="
echo "🎯 MATCHING MANAGER APK LOCATOR"
echo "Stop wading through Actions. Click here for your exact APK:"
echo "https://github.com/${UPSTREAM_REPO}/actions?query=commit%3A${UPSTREAM_HASH}"
echo "==============================================="

echo ">>> Creating symlink for Bazel sandbox..."
DRIVER_ROOT="common/drivers"
rm -rf "${DRIVER_ROOT}/kernelsu"
ln -sfn "../../${MANAGER_DIR}/kernel" "${DRIVER_ROOT}/kernelsu"
[ -L "${DRIVER_ROOT}/kernelsu" ] || { echo "[-] Symlink failed" >&2; exit 1; }

echo ">>> ${MANAGER_DIR} integration complete!"
