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

# Configure local git identity
git config --global user.name "github-actions[bot]"
git config --global user.email "github-actions[bot]@users.noreply.github.com"

# Stage all changes
git add .

# Create a commit for custom changes
git commit -m "ci: integrated KSU, SUSFS, and other patches if any" || true

cd ..

echo ">>> Fetching official commit metadata..."
# Get the date and the Unix timestamp (Seconds since 1970)
OFFICIAL_DATE=$(git -C common log -1 --format=%aD "$OFFICIAL_HASH")
OFFICIAL_TIMESTAMP=$(git -C common log -1 --format=%ct "$OFFICIAL_HASH")

echo ">>> Creating workspace status override..."
cat <<EOF > workspace_status.sh
#!/bin/bash
echo "STABLE_BUILD_VERSION g$OFFICIAL_HASH"
echo "STABLE_KBUILD_BUILD_TIMESTAMP $OFFICIAL_DATE"
echo "STABLE_BUILD_USER android-build"
echo "STABLE_BUILD_HOST google.com"
# This forces Kleaf to treat the 'source date' as the official commit time
echo "STABLE_SOURCE_DATE_EPOCH $OFFICIAL_TIMESTAMP" 
EOF
chmod +x workspace_status.sh

echo ">>> Compiling common Android arm64 kernel..."

# Adding --action_env=SOURCE_DATE_EPOCH is the final 'hammer' 
# to prevent the 1970/current-date fallback in the Kbuild process.
tools/bazel run --config=local --config=stamp \
  --workspace_status_command=./workspace_status.sh \
  --action_env=KBUILD_BUILD_TIMESTAMP="$OFFICIAL_DATE" \
  --action_env=SOURCE_DATE_EPOCH="$OFFICIAL_TIMESTAMP" \
  //common:kernel_aarch64_dist -- --destdir=out/dist

IMAGE_PATH="$(find out/dist -type f -name 'Image' | head -n1)"

if [ -z "${IMAGE_PATH}" ] || [ ! -f "${IMAGE_PATH}" ]; then
  echo "[-] No Image produced by common kernel build" >&2
  exit 1
fi

echo ">>> Selected Image: ${IMAGE_PATH}"
cp -f "${IMAGE_PATH}" ../out/Image

echo ">>> Extracting compiled kernel version string..."
strings ../out/Image | grep "Linux version" | head -n 1

echo ">>> Build complete!"
