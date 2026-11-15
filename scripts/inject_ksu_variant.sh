#!/usr/bin/env bash
# scripts/inject_ksu_variant.sh
set -euo pipefail

cd kernel_workspace
[ -d common ] || { echo "[-] common/ not found in kernel_workspace" >&2; exit 1; }

VARIANT=$1

# 1. Map the expected directory name based on the variant's target folder
case "${VARIANT}" in
    "KernelSU-Next")
        export MANAGER_DIR="KernelSU-Next"
        ;;
    "ReSukiSU")
        export MANAGER_DIR="ReSukiSU"
        ;;
    "SukiSU-Ultra" | "KernelSU" | "BakaSU")
        export MANAGER_DIR="KernelSU"
        ;;
    *)
        echo "[-] Error: Unsupported Variant '${VARIANT}'. Selected variant not supported" >&2
        exit 1
        ;;
esac

rm -rf "${MANAGER_DIR}"
echo "=== Integrating ${VARIANT} ==="

# ========================================================================
# MODULAR DELEGATION
# ========================================================================
# Note the '../' because we are currently inside the 'kernel_workspace' directory
INJECTOR_SCRIPT="../scripts/inject_${VARIANT}.sh"

if [ -f "$INJECTOR_SCRIPT" ]; then
    echo ">>> Delegating integration to modular script: $INJECTOR_SCRIPT"
    
    # We use 'source' so the child script runs in THIS environment.
    # This allows it to set UPSTREAM_HASH, UPSTREAM_BRANCH, CALCULATED_COUNT, and CALCULATED_TAG 
    # so we can use them in the Gatekeeper below.
    source "$INJECTOR_SCRIPT"
else
    echo "[-] CRITICAL: Modular script $INJECTOR_SCRIPT not found!" >&2
    exit 1
fi

# ========================================================================
# KLEAF SANDBOX IMMUTABLE GATEKEEPER
# ========================================================================
# (These variables were populated by the sourced variant script)
SHORT_HASH=${UPSTREAM_HASH:0:7}

echo ">>> Injecting Sandbox Variables into Build File..."

# Support both Kbuild (KernelSU-Next/old) and Makefile (SukiSU-Ultra builtin)
if [ -f "${MANAGER_DIR}/kernel/Kbuild" ]; then
    TARGET_BUILD_FILE="${MANAGER_DIR}/kernel/Kbuild"
elif [ -f "${MANAGER_DIR}/kernel/Makefile" ]; then
    TARGET_BUILD_FILE="${MANAGER_DIR}/kernel/Makefile"
else
    TARGET_BUILD_FILE=""
fi

if [ -n "$TARGET_BUILD_FILE" ] && [ -f "$TARGET_BUILD_FILE" ]; then
    {
        # --- Official & Next Namespaces ---
        echo "override KSU_GIT_VERSION_VALID := false" 
        echo "override KSU_GIT_VERSION := ${CALCULATED_COUNT}"
        echo "override KSU_GIT_TAG := ${CALCULATED_TAG}"
        echo "override KSU_COMMIT_SHA := ${SHORT_HASH}"
        echo "override KSU_GIT_BRANCH := ${UPSTREAM_BRANCH}"
        
        # --- BakaSU/ReSukiSUNamespaces ---
        echo "override LOCAL_GIT_EXISTS := 1"
        echo "override KSU_LOCAL_VERSION := ${CALCULATED_COUNT}"
        echo "override KSU_TAG_NAME := ${CALCULATED_TAG}"
        echo "override KSU_BRANCH_NAME := ${UPSTREAM_BRANCH}"
        echo "override KSU_COMMIT_SHA := ${SHORT_HASH}" 

        # --- SukiSU-Ultra Specific Namespaces ---
        echo "override LOCAL_COUNT := ${CALCULATED_COUNT}"
        echo "override git_commit_count := ${CALCULATED_COUNT}"
        echo "override git_short_sha := ${SHORT_HASH}"
        echo "override git_branch := ${UPSTREAM_BRANCH}"
        echo "override git_latest_tag := ${CALCULATED_TAG}"

        cat "$TARGET_BUILD_FILE"
    } > "${TARGET_BUILD_FILE}.tmp" && mv "${TARGET_BUILD_FILE}.tmp" "$TARGET_BUILD_FILE"

    echo "  -> Target Build File: ${TARGET_BUILD_FILE}"
    echo "  -> Prepend Immutable Count: ${CALCULATED_COUNT}"
    echo "  -> Prepend Immutable Tag: ${CALCULATED_TAG}"
    echo "  -> Prepend Immutable SHA: ${SHORT_HASH}"
    echo "  -> Prepend Immutable Branch: ${UPSTREAM_BRANCH}"
else
    echo "[-] Warning: Neither Kbuild nor Makefile found in ${MANAGER_DIR}/kernel/. Sandbox variables not injected."
fi

# ========================================================================
# KERNEL DRIVER SYMLINK
# ========================================================================
echo ">>> Injecting Bazel symlink..."
DRIVER_ROOT="common/drivers"
rm -rf "${DRIVER_ROOT}/kernelsu"
ln -sfn "../../${MANAGER_DIR}/kernel" "${DRIVER_ROOT}/kernelsu"
[ -L "${DRIVER_ROOT}/kernelsu" ] || { echo "[-] Symlink failed" >&2; exit 1; }

echo ">>> ${MANAGER_DIR} architecture locked, sanitized and integrated!"
