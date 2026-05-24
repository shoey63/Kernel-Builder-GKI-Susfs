#!/usr/bin/env bash
set -euo pipefail

cd kernel_workspace
[ -d common ] || { echo "[-] common/ not found in kernel_workspace" >&2; exit 1; }

VARIANT=$1
MANAGER_DIR="KernelSU"
rm -rf "${MANAGER_DIR}"

echo "=== Integrating ${VARIANT} ==="
echo ">>> Cloning custom pipeline branch: ${KSU_VARIANT_REF}..."
git clone "${KSU_VARIANT_REPO_URL}" -b "${KSU_VARIANT_REF}" "${MANAGER_DIR}"

# Setup.sh runs cleanly because OWNER is patched at the source level
echo ">>> Executing native setup.sh..."
bash "${MANAGER_DIR}/kernel/setup.sh" "${KSU_VARIANT_REF}"

echo ">>> Enforcing CI symmetry (locking version strings to HEAD~1)..."
sed -i 's/rev-list --count HEAD/rev-list --count HEAD~1/g' "${MANAGER_DIR}/kernel/Kbuild" 2>/dev/null || true
sed -i 's/rev-list --count \$(REPO_BRANCH)/rev-list --count HEAD~1/g' "${MANAGER_DIR}/kernel/Kbuild" 2>/dev/null || true

# Obtain commit hash of the official base for the APK locator
UPSTREAM_HASH=$(git -C "${MANAGER_DIR}" rev-parse HEAD~1)

if [[ "${VARIANT}" == "KernelSU" ]]; then
    UPSTREAM_REPO="tiann/KernelSU"
elif [[ "${VARIANT}" == "KernelSU-Next" ]]; then
    UPSTREAM_REPO="KernelSU-Next/KernelSU-Next"
elif [[ "${VARIANT}" == "SukiSU-Ultra" ]]; then
    UPSTREAM_REPO="SukiSU-Ultra/SukiSU-Ultra"
else
    UPSTREAM_REPO="tiann/KernelSU"
fi

echo "----------------------------------------------"
echo ">>> Manager APK Locator:"
echo "URL: https://github.com/${UPSTREAM_REPO}/commit/${UPSTREAM_HASH}"
echo "-> Select the green checkmark (✅) -> Details -> Artifacts to download the matching Manager."
echo "----------------------------------------------"

echo ">>> Injecting Bazel symlink..."
DRIVER_ROOT="common/drivers"
rm -rf "${DRIVER_ROOT}/kernelsu"
ln -sfn "../../${MANAGER_DIR}/kernel" "${DRIVER_ROOT}/kernelsu"
[ -L "${DRIVER_ROOT}/kernelsu" ] || { echo "[-] Symlink failed" >&2; exit 1; }

echo ">>> ${MANAGER_DIR} architecture locked and integrated!"
