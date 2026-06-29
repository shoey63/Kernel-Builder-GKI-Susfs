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

DOWNLOAD_URLS=""

# 1. Try to find the exact commit hash first
echo ">>> Checking exact upstream hash: ${UPSTREAM_HASH}"
RUNS_JSON=$(curl -s -H "Authorization: token $GH_TOKEN" \
  "https://api.github.com/repos/$REPO/actions/runs?head_sha=${UPSTREAM_HASH}&status=success")
RUN_ID=$(echo "$RUNS_JSON" | jq -r '.workflow_runs[0].id // empty')

if [ -n "$RUN_ID" ]; then
    echo ">>> Found Run ID: $RUN_ID. Fetching artifacts..."
    ARTIFACTS_JSON=$(curl -s -H "Authorization: token $GH_TOKEN" \
      "https://api.github.com/repos/$REPO/actions/runs/$RUN_ID/artifacts")
    
    DOWNLOAD_URLS=$(echo "$ARTIFACTS_JSON" | jq -r '
      .artifacts[]? 
      | select(.name | test("(?i)(SukiSU|KernelSU|manager|spoof)")) 
      | .archive_download_url // empty')
fi

# 2. Fallback if the run didn't exist OR if it had no artifacts
if [ -z "$DOWNLOAD_URLS" ]; then
    if [ -n "$RUN_ID" ]; then
        echo "[-] Run ID $RUN_ID exists but has no valid artifacts (likely a dependabot bump)."
    else
        echo "[-] No successful run found for exact hash."
    fi
    
    echo ">>> Falling back to recent successful runs on branch: $DEFAULT_BRANCH..."
    
    # Fetch the last 5 successful runs to ensure we bypass any empty dependabot runs on the main branch
    RUNS_JSON=$(curl -s -H "Authorization: token $GH_TOKEN" \
      "https://api.github.com/repos/$REPO/actions/runs?branch=${DEFAULT_BRANCH}&status=success&per_page=5")
    
    RUN_IDS=$(echo "$RUNS_JSON" | jq -r '.workflow_runs[].id // empty')
    
    for ID in $RUN_IDS; do
        echo ">>> Checking fallback Run ID: $ID..."
        ARTIFACTS_JSON=$(curl -s -H "Authorization: token $GH_TOKEN" \
          "https://api.github.com/repos/$REPO/actions/runs/$ID/artifacts")
        
        DOWNLOAD_URLS=$(echo "$ARTIFACTS_JSON" | jq -r '
          .artifacts[]? 
          | select(.name | test("(?i)(SukiSU|KernelSU|manager|spoof)")) 
          | .archive_download_url // empty')
          
        if [ -n "$DOWNLOAD_URLS" ]; then
            echo ">>> Valid artifacts located in fallback Run ID: $ID!"
            RUN_ID=$ID
            break
        fi
        echo "[-] No valid artifacts in Run $ID. Searching next..."
    done
fi

# Final sanity check before downloading
if [ -z "$DOWNLOAD_URLS" ]; then
    echo "[-] Critical: Failed to locate ANY valid Manager artifacts for $REPO."
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

