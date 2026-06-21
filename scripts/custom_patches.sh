#!/usr/bin/env bash
set -euo pipefail

echo "=== Applying Custom Kernel Patches ==="

# Navigate to the root of the freshly synced kernel source
cd kernel_workspace/common

echo ">>> Injecting ZeroMount Subsystem..."
# Use the patch command to apply the diff. 
# -p1 strips the 'a/' and 'b/' from the file paths in the diff.
patch -p1 < ../../patches/60_zeromount-android14-6.1.patch

echo ">>> ZeroMount successfully integrated!"
