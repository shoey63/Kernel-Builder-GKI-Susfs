#!/usr/bin/env bash
set -euo pipefail
git config --global advice.detachedHead false

cd kernel_workspace

[ -d common ] || { echo "[-] common/ not found in kernel_workspace" >&2; exit 1; }

# 1. THE UNIVERSAL DIRECTORY
# By using a generic folder name, this script handles KSU, KSU-Next, and SukiSU interchangeably.
MANAGER_DIR="Root_Manager_Source"
rm -rf "${MANAGER_DIR}"

echo "=== Integrating Root Manager ==="
echo ">>> Cloning bleeding-edge branch: ${KSU_NEXT_REF}..."
git clone "${KSU_NEXT_REPO_URL}" -b "${KSU_NEXT_REF}" "${MANAGER_DIR}"

# 2. THE TAG TRAP FIX
# setup.sh will crash if it runs `git describe --tags` on a repo with no tags.
# We create a dummy tag locally. It never gets pushed to your GitHub; it just shuts setup.sh up.
echo ">>> Injecting dummy tag to bypass setup.sh fatal errors..."
git -C "${MANAGER_DIR}" tag v9.9.9

# We also explicitly export the version variable so setup.sh skips its tag-hunting logic where possible.
export KSU_VERSION="${KSU_NEXT_REF}"

echo ">>> Running upstream setup.sh..."
bash "${MANAGER_DIR}/kernel/setup.sh"

# 3. THE SLEDGEHAMMER
# Force the HEAD back to your branch tip, destroying any checkouts setup.sh performed.
echo ">>> Neutralizing setup.sh git manipulations..."
git -C "${MANAGER_DIR}" checkout "${KSU_NEXT_REF}"

echo ">>> Creating symlink for Bazel sandbox..."
DRIVER_ROOT="common/drivers"

# 4. THE DECOY KILLER
# Obliterate any rogue clones setup.sh might have dropped directly into the source tree.
rm -rf "${DRIVER_ROOT}/kernelsu"
ln -sfn "../../${MANAGER_DIR}/kernel" "${DRIVER_ROOT}/kernelsu"

# Quick sanity check
[ -L "${DRIVER_ROOT}/kernelsu" ] || { echo "[-] Symlink failed" >&2; exit 1; }

echo ">>> Root Manager integration complete!"
