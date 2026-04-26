#!/bin/bash
set -e

# --- Configuration ---
MANIFEST_URL="https://android.googlesource.com/kernel/manifest"
BRANCH="common-android14-6.1-2026-03"
WORKSPACE="workspace"
DIST_DIR="out/dist"

echo "=== Installing Dependencies ==="
sudo apt-get update
sudo apt-get install -y git curl python3 rsync

echo "=== Setting up 'repo' tool ==="
mkdir -p ~/.bin
export PATH="${HOME}/.bin:${PATH}"
curl https://storage.googleapis.com/git-repo-downloads/repo > ~/.bin/repo
chmod a+rx ~/.bin/repo

echo "=== Configuring Git ==="
git config --global user.name "GitHub Action"
git config --global user.email "action@github.com"
git config --global color.ui false

echo "=== Initializing and Syncing AOSP Kernel Source ==="
mkdir -p "${WORKSPACE}"
cd "${WORKSPACE}"

repo init -u "${MANIFEST_URL}" -b "${BRANCH}" --depth=1
repo sync -c -j$(nproc) --no-clone-bundle --no-tags

echo "=== Building GKI via Kleaf (Bazel) ==="
# Notice the flags are now AFTER the 'run' command
tools/bazel run --color=no --curses=no //common:kernel_aarch64_dist -- --dist_dir="${DIST_DIR}" 2>&1 | tee build.log

echo "=== Build Complete ==="
