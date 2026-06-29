#!/bin/bash
# scripts/fetch_manager.sh

set -euo pipefail

VARIANT="${1}"
GH_TOKEN="${2}"
UPSTREAM_HASH="${3:-}" # Optional: Not needed for ZeroMount

# ==========================================
# ZEROMOUNT FETCH LOGIC (Releases API)
# ==========================================
if [[ "${VARIANT}" == "ZeroMount" ]]; then
  echo ">>> Fetching latest ZeroMount release from Enginex0/zeromount..."
  
  LATEST_JSON=$(curl -s -H "Authorization: token $GH_TOKEN" "https://api.github.com/repos/Enginex0/zeromount/releases/latest")
  DOWNLOAD_URL=$(echo "$LATEST_JSON" | jq -r '.assets[] | select(.name | endswith(".zip")) | .browser_download_url' | head -n 1)
  
  if [ -z "$DOWNLOAD_URL" ] || [ "$DOWNLOAD_URL" == "null" ]; then
    echo "[-] Failed to find a ZeroMount module zip in the latest release."
    exit 1
  fi
  
  echo ">>> Downloading $DOWNLOAD_URL..."
  mkdir -p zeromount_module
  FILE_NAME=$(basename "$DOWNLOAD_URL")
  curl -s -L -H "Authorization: token $GH_TOKEN" -o "zeromount_module/$FILE_NAME" "$DOWNLOAD_URL"
  
  echo ">>> Extracting ZeroMount module to prevent double-zipping..."
  unzip -q -o "zeromount_module/$FILE_NAME" -d zeromount_module/
  rm "zeromount_module/$FILE_NAME"
  
  echo ">>> ZeroMount successfully staged for final upload!"
  exit 0
fi

# ==========================================
# ROOT MANAGER FETCH LOGIC (Artifacts API)
# ==========================================
echo ">>> Mapping selected variant to upstream repository..."
if [[ "${VARIANT}" == "KernelSU" ]]; then
    REPO="tiann/KernelSU"
    DEFAULT_BRANCH="main"
elif [[ "${VARIANT}" == "KernelSU-Next" ]]; then
    REPO="KernelSU-Next/KernelSU-Next"
    DEFAULT_BRANCH="dev"
elif [[ "${VARIANT}" == "SukiSU-Ultra" ]]; then
    REPO="SukiSU-Ultra/SukiSU-Ultra"
    DEFAULT_BRANCH="main"
elif [[ "${VARIANT}" == "ReSukiSU" ]]; then
    REPO="ReSukiSU/ReSukiSU"
    DEFAULT_BRANCH="main"
else
    REPO="tiann/KernelSU"
    DEFAULT_BRANCH="main"
fi

echo ">>> Searching $REPO for a Release Manager..."

# 1. Try to find the exact commit hash first
RUNS_JSON=$(curl -s -H "Authorization: token $GH_TOKEN" \
  "https://api.github.com/repos/$REPO/actions/runs?head_sha=${UPSTREAM_HASH}&status=success")
RUN_ID=$(echo "$RUNS_JSON" | jq -r '.workflow_runs[0].id // empty')

# 2. Fallback to the latest successful run on the default branch if the hash fails
if [ -z "$RUN_ID" ]; then
    echo "[-] Exact hash not found. Falling back to the latest successful run on branch: $DEFAULT_BRANCH..."
    RUNS_JSON=$(curl -s -H "Authorization: token $GH_TOKEN" \
      "https://api.github.com/repos/$REPO/actions/runs?branch=${DEFAULT_BRANCH}&status=success&per_page=1")
    RUN_ID=$(echo "$RUNS_JSON" | jq -r '.workflow_runs[0].id // empty')
fi

if [ -z "$RUN_ID" ]; then
    echo "[-] Critical: Failed to find ANY successful workflow run for $REPO."
    exit 1
fi

echo ">>> Fetching artifacts for Run ID: $RUN_ID"

ARTIFACTS_JSON=$(curl -s -H "Authorization: token $GH_TOKEN" \
  "https://api.github.com/repos/$REPO/actions/runs/$RUN_ID/artifacts")

# 3. Filter for both Regular and Spoofed managers. 
# Broad case-insensitive match for SukiSU, KernelSU, manager, and spoof.
DOWNLOAD_URLS=$(echo "$ARTIFACTS_JSON" | jq -r '
  .artifacts[] 
  | select(.name | test("(?i)(SukiSU|KernelSU|manager|spoof)")) 
  | .archive_download_url')

if [ -z "$DOWNLOAD_URLS" ] || [ "$DOWNLOAD_URLS" == "null" ]; then
    echo "[-] Failed to locate any valid Manager artifacts in Run ID: $RUN_ID"
    exit 1
fi

mkdir -p manager_apk
COUNTER=1

for URL in $DOWNLOAD_URLS; do
  echo ">>> Downloading artifact from URL $COUNTER..."
  curl -s -L -H "Authorization: token $GH_TOKEN" -o manager_${COUNTER}.zip "$URL"
  
  echo ">>> Extracting..."
  unzip -q -o manager_${COUNTER}.zip -d manager_apk/
  rm manager_${COUNTER}.zip
  
  COUNTER=$((COUNTER+1))
done

echo ">>> Cleaning up unnecessary architectures..."
# GKI devices are strictly arm64. Deletes x86, 32-bit, and universal APKs.
find manager_apk/ -type f \( -name "*x86*.apk" -o -name "*armeabi-v7a*.apk" -o -name "*universal*.apk" \) -exec rm -f {} +

echo ">>> Manager(s) successfully staged for final upload!"
ls -1 manager_apk/

