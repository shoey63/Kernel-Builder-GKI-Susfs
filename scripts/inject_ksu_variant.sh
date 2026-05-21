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

echo "--------------------------------------------------------"
echo ">>> [PRE-FLIGHT] Proper HEAD secured:"
echo ">>> Commit: ${TIP_HASH}"
echo ">>> Message: ${TIP_MSG}"
echo "--------------------------------------------------------"

# Run the payload. We pass the branch name strictly to prevent fatal 
# "no tags found" git errors on fresh forks. 
echo ">>> Running upstream setup.sh..."
bash "${MANAGER_DIR}/kernel/setup.sh" "${KSU_NEXT_REF}"

echo "--------------------------------------------------------"
echo ">>> [POST-FLIGHT] setup.sh complete. HEAD currently at: $(git -C "${MANAGER_DIR}" rev-parse --short HEAD)"
echo "--------------------------------------------------------"

# THE SLEDGEHAMMER
echo ">>> Neutralizing setup.sh git manipulations..."
git -C "${MANAGER_DIR}" checkout "${KSU_NEXT_REF}"

echo ">>> Creating symlink for Bazel sandbox..."
DRIVER_ROOT="common/drivers"

rm -rf "${DRIVER_ROOT}/kernelsu"
ln -sfn "../../${MANAGER_DIR}/kernel" "${DRIVER_ROOT}/kernelsu"

# Quick sanity check
[ -L "${DRIVER_ROOT}/kernelsu" ] || { echo "[-] Symlink failed" >&2; exit 1; }

echo ">>> disable signature verification..."
echo 'KSU_EXPECTED_SIZE := ""' >> "${MANAGER_DIR}/kernel/Makefile"
echo 'KSU_EXPECTED_HASH := ""' >> "${MANAGER_DIR}/kernel/Makefile"

echo ">>> ${MANAGER_DIR} integration complete!"
