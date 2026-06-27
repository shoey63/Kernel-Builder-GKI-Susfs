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
elif [[ "${VARIANT}" == "KernelSU-Next" ]]; then
    REPO="KernelSU-Next/KernelSU-Next"
elif [[ "${VARIANT}" == "SukiSU-Ultra" ]]; then
    REPO="SukiSU-Ultra/SukiSU-Ultra"
elif [[ "${VARIANT}" == "ReSukiSU" ]]; then
    REPO="ReSukiSU/ReSukiSU"
else
    REPO="tiann/KernelSU"
fi

echo ">>> Searching $REPO for the Release Manager APK built from commit: $UPSTREAM_HASH..."

RUNS_JSON=$(curl -s -H "Authorization: token $GH_TOKEN" \
  "https://api.github.com/repos/$REPO/actions/runs?head_sha=${UPSTREAM_HASH}&status=success")
  
RUN_IDS=$(echo "$RUNS_JSON" | jq -r '.workflow_runs[].id')

DOWNLOAD_URLS=""

for RUN_ID in $RUN_IDS; do
  ARTIFACTS=$(curl -s -H "Authorization: token $GH_TOKEN" \
    "https://api.github.com/repos/$REPO/actions/runs/$RUN_ID/artifacts")
    
  # Safely targets standard and spoofed managers while blocking '-gradle' and '-debug'
  DOWNLOAD_URLS=$(echo "$ARTIFACTS" | jq -r '.artifacts[] | select(.name | test("^(manager|Manager(-release)?|Spoofed-Manager-release|manager-spoofed)$")) | .archive_download_url')
  
  if [ -n "$DOWNLOAD_URLS" ] && [ "$DOWNLOAD_URLS" != "null" ]; then
    echo ">>> Found Release Manager artifact(s) on Run ID: $RUN_ID"
    break
  fi
done

if [ -z "$DOWNLOAD_URLS" ] || [ "$DOWNLOAD_URLS" == "null" ]; then
  echo "[-] Failed to locate a Release Manager artifact in recent builds for $REPO."
  exit 1
fi

mkdir -p manager_apk
COUNTER=1

for URL in $DOWNLOAD_URLS; do
  echo ">>> Downloading Manager from $URL..."
  curl -s -L -H "Authorization: token $GH_TOKEN" -o manager_${COUNTER}.zip "$URL"
  
  echo ">>> Extracting Manager..."
  unzip -q -o manager_${COUNTER}.zip -d manager_apk/
  rm manager_${COUNTER}.zip
  
  COUNTER=$((COUNTER+1))
done

echo ">>> Cleaning up unnecessary architectures..."
# GKI devices are strictly arm64. Deletes x86, 32-bit, and universal APKs.
find manager_apk/ -type f \( -name "*x86*.apk" -o -name "*armeabi-v7a*.apk" -o -name "*universal*.apk" \) -exec rm -f {} +

echo ">>> Manager(s) successfully staged for final upload!"
ls -1 manager_apk/
