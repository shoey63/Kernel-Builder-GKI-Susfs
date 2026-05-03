#!/usr/bin/env bash
set -euo pipefail

cd kernel_workspace
mkdir -p ../out out/dist

[ -d common ] || { echo "[-] common/ not found in kernel_workspace" >&2; exit 1; }
[ -x tools/bazel ] || { echo "[-] tools/bazel not found or not executable" >&2; exit 1; }

echo ">>> Neutralizing ABI protected exports lists..."
for f in common/android/abi_gki_protected_exports*; do
  if [ -f "$f" ]; then
    > "$f"
  fi
done

echo ">>> Satisfying Kleaf's git status checks to remove -dirty and fix timestamp..."
cd common

# Configure dummy git details for the CI runner
git config --global user.name "github-actions[bot]"
git config --global user.email "github-actions[bot]@users.noreply.github.com"

# Stage all KSU and Susfs modifications
git add .

# Commit the changes. This does two things:
# 1. Makes the tree "clean", removing the -dirty flag.
# 2. Sets the HEAD commit timestamp to RIGHT NOW, which Kleaf uses for the build date.
git commit -m "ci: inject KSU and SusFS patches" || true

cd ..

echo ">>> Compiling common Android arm64 kernel..."
tools/bazel run --config=local --config=stamp //common:kernel_aarch64_dist -- --destdir=out/dist

IMAGE_PATH="$(find out/dist -type f -name 'Image' | head -n1)"

if [ -z "${IMAGE_PATH}" ] || [ ! -f "${IMAGE_PATH}" ]; then
  echo "[-] No Image produced by common kernel build" >&2
  exit 1
fi

echo ">>> Selected Image: ${IMAGE_PATH}"
cp -f "${IMAGE_PATH}" ../out/Image

echo ">>> Build complete!"
