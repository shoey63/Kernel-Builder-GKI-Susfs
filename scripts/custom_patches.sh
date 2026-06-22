#!/usr/bin/env bash
# set -e

# ---------------------------------------------------------
# CUSTOM PATCHES & CHERRY-PICKS
# ---------------------------------------------------------
# This script runs AFTER 'repo sync' but BEFORE 'build_kernel.sh'.
# Use it to modify the source tree (Makefile, Kconfig, etc.)
# ---------------------------------------------------------

# Example: 
# cd kernel_workspace/common
# git fetch https://android.googlesource.com/kernel/common <branch>
# git cherry-pick <hash>
# cd ../..

# echo ">>> User modifications complete."
