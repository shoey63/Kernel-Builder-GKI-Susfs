#!/usr/bin/env bash
set -euo pipefail

WITH_WG=${WITH_WG:-false}

echo "=== Step 3: Initializing Bazel Execution Engine ==="

cd kernel_workspace
mkdir -p ../out out/dist

echo ">>> Marking repo as clean (cloaking all custom configuration & source modifications)..."
# Dynamically gathers every single modification from scripts 1 and 2 and shields them
git -C common ls-files -m | xargs -r git -C common update-index --assume-unchanged

echo ">>> Commencing build: g$OFFICIAL_HASH"
tools/bazel run --config=local --config=stamp \
  --action_env=SOURCE_DATE_EPOCH="$OFFICIAL_DATE" \
  --action_env=STABLE_BUILD_VERSION="g$OFFICIAL_HASH" \
  --action_env=KLEAF_KERNEL_BUILD_VERSION="g$OFFICIAL_HASH" \
  --action_env=KLEAF_SKIP_ABI_CHECKS=true \
  --action_env=KLEAF_USER=android-build \
  //common:kernel_aarch64_dist \
  -- \
  --destdir=out/dist
  
IMAGE_PATH="$(find out/dist -type f -name 'Image' | head -n1)"

if [ -z "${IMAGE_PATH}" ] || [ ! -f "${IMAGE_PATH}" ]; then
  echo "[-] No compilation Image produced!" >&2
  exit 1
fi

echo ">>> Selected Image: ${IMAGE_PATH}"
cp -f "${IMAGE_PATH}" ../out/Image

echo ">>> Verifying built image version details..."
strings ../out/Image | grep "Linux version" | head -n 1

if [ "$WITH_WG" = "true" ]; then
    echo ">>> Validating WireGuard symbol integration status..."
    if strings ../out/Image | grep -qi "wireguard"; then
        echo ">>> SUCCESS: WireGuard core symbols validated."
    else
        echo ">>> ERROR: WireGuard symbols missing from compiled binary."
        exit 1
    fi
fi

cd ..
echo ">>> Build execution loop completed"
