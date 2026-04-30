#!/usr/bin/env bash
set -euo pipefail

cd kernel_workspace

[ -d common ] || { echo "[-] common/ not found in kernel_workspace" >&2; exit 1; }

echo "=== Integrating KernelSU-Next ==="
git clone "${KSU_NEXT_REPO_URL}" -b "${KSU_NEXT_REF}" KernelSU-Next

bash KernelSU-Next/kernel/setup.sh

# The Scalpel Check (Now with detached HEAD awareness)
CURRENT_BRANCH=$(git -C KernelSU-Next branch --show-current)
[ -z "$CURRENT_BRANCH" ] && CURRENT_BRANCH="detached HEAD"

if [ "$CURRENT_BRANCH" != "${KSU_NEXT_REF}" ]; then
    echo ">>> setup.sh hijacked the branch (currently on: $CURRENT_BRANCH). Restoring ${KSU_NEXT_REF} branch..."
    git -C KernelSU-Next checkout "${KSU_NEXT_REF}"
else
    >>> Verified branch: ${KSU_NEXT_REF}. No corrective checkout required.
fi

echo ">>> Creating symlink for Bazel sandbox..."
DRIVER_ROOT="common/drivers"
ln -sfn "../../KernelSU-Next/kernel" "${DRIVER_ROOT}/kernelsu"

# Quick sanity check
[ -L "${DRIVER_ROOT}/kernelsu" ] || { echo "[-] Symlink failed" >&2; exit 1; }

echo ">>> KernelSU-Next integration complete!"
