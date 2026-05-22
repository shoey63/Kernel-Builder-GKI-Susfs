#!/usr/bin/env bash
set -euo pipefail
git config --global advice.detachedHead false

cd kernel_workspace

[ -d common ] || { echo "[-] common/ not found in kernel_workspace" >&2; exit 1; }

VARIANT=$1
MANAGER_DIR="KernelSU"
rm -rf "${MANAGER_DIR}"

echo "=== Integrating ${VARIANT} ==="
echo ">>> Cloning bleeding-edge branch: ${KSU_VARIANT_REF}..."
git clone "${KSU_VARIANT_REPO_URL}" -b "${KSU_VARIANT_REF}" "${MANAGER_DIR}"

# --- THE LOGGING ENGINE ---
TIP_HASH=$(git -C "${MANAGER_DIR}" rev-parse --short HEAD)
TIP_MSG=$(git -C "${MANAGER_DIR}" log -1 --format="%s")

echo ">>> Pre-initialisation - proper HEAD secured:"
echo ">>> Commit: ${TIP_HASH}"
echo ">>> Message: ${TIP_MSG}"

# Mitigate 'no tags found' error 
echo ">>> Running upstream setup.sh..."
bash "${MANAGER_DIR}/kernel/setup.sh" "${KSU_VARIANT_REF}"

echo "----------------------------------------------"
echo ">>> setup.sh complete. HEAD currently at: $(git -C "${MANAGER_DIR}" rev-parse --short HEAD)"
echo "----------------------------------------------"

echo ">>> Neutralizing setup.sh git manipulations..."
git -C "${MANAGER_DIR}" checkout "${KSU_VARIANT_REF}"

echo ">>> Integrating upstream commit into manager version (forcing HEAD~1)..."
sed -i 's/rev-list --count HEAD/rev-list --count HEAD~1/g' "${MANAGER_DIR}/kernel/Kbuild" 2>/dev/null || true
sed -i 's/rev-list --count \$(REPO_BRANCH)/rev-list --count HEAD~1/g' "${MANAGER_DIR}/kernel/Kbuild" 2>/dev/null || true

# Obtain commit hash of the official base
UPSTREAM_HASH=$(git -C "${MANAGER_DIR}" rev-parse HEAD~1)

# Route the URL based on the variant being built
if [ "$1" == "KernelSU" ]; then
    UPSTREAM_REPO="tiann/KernelSU"
elif [ "$1" == "KernelSU-Next" ]; then
    UPSTREAM_REPO="KernelSU-Next/KernelSU-Next"
elif [ "$1" == "SukiSU-Ultra" ]; then
    UPSTREAM_REPO="SukiSU-Ultra/SukiSU-Ultra"
else
    UPSTREAM_REPO="tiann/KernelSU"
fi

echo "To get the matching manager, go directly to the exact commit here:"
echo "https://github.com/${UPSTREAM_REPO}/commit/${UPSTREAM_HASH}"
echo "-> Click the green checkmark (✅) next to the commit title and get the #<run number>"
echo "Then locate the action run to obtain the Manager zip which will contain the APK"

echo ">>> Creating symlink for Bazel sandbox..."
DRIVER_ROOT="common/drivers"
rm -rf "${DRIVER_ROOT}/kernelsu"
ln -sfn "../../${MANAGER_DIR}/kernel" "${DRIVER_ROOT}/kernelsu"
[ -L "${DRIVER_ROOT}/kernelsu" ] || { echo "[-] Symlink failed" >&2; exit 1; }

echo ">>> ${MANAGER_DIR} integration complete!"
