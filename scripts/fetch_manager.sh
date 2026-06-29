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
RUN_ID=""

# 1. Try to find the exact commit hash first
echo ">>> Checking exact upstream hash: ${UPSTREAM_HASH} (Filtering by push event on ${DEFAULT_BRANCH})"
RUNS_JSON=$(curl -s -H "Authorization: token $GH_TOKEN" \
  "https://api.github.com/repos/$REPO/actions/runs?head_sha=${UPSTREAM_HASH}&status=success&event=push&branch=${DEFAULT_BRANCH}&per_page=100")

# Grab ALL run IDs associated with this commit
RUN_IDS=$(echo "$RUNS_JSON" | jq -r '.workflow_runs[]?.id // empty')

if [ -n "$RUN_IDS" ]; then
    for ID in $RUN_IDS; do
        echo ">>> Checking exact-match Run ID: $ID for artifacts..."
        ARTIFACTS_JSON=$(curl -s -H "Authorization: token $GH_TOKEN" \
          "https://api.github.com/repos/$REPO/actions/runs/$ID/artifacts")
        
        DOWNLOAD_URLS=$(echo "$ARTIFACTS_JSON" | jq -r '
          .artifacts[]? 
          | select(.name | test("(?i)(SukiSU|KernelSU|manager|spoof)")) 
          | .archive_download_url // empty')
          
        if [ -n "$DOWNLOAD_URLS" ]; then
            echo ">>> Valid Manager artifacts located in Run ID: $ID!"
            RUN_ID=$ID
            break
        fi
    done
fi

# 2. Fallback if the run didn't exist OR if none of its workflows had artifacts
if [ -z "$DOWNLOAD_URLS" ]; then
    echo "[-] No valid artifacts found for exact hash. (Jobs skipped or expired)."
    echo ">>> Falling back to recent successful runs on branch: $DEFAULT_BRANCH..."
    
    # Fetch the last 20 successful runs to comfortably cover multiple commits' worth of workflows
    RUNS_JSON=$(curl -s -H "Authorization: token $GH_TOKEN" \
      "https://api.github.com/repos/$REPO/actions/runs?branch=${DEFAULT_BRANCH}&status=success&per_page=20")
    
    FALLBACK_RUN_IDS=$(echo "$RUNS_JSON" | jq -r '.workflow_runs[]?.id // empty')
    
    for ID in $FALLBACK_RUN_IDS; do
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
    done
fi

# Final sanity check before downloading
if [ -z "$DOWNLOAD_URLS" ]; then
    echo "[-] Critical: Failed to locate ANY valid Manager artifacts for $REPO."
    exit 1
fi

mkdir -p manager_apk
COUNTER=1

# Change IFS so bash correctly handles URLs with spaces or newlines
IFS=$'\n'
for URL in $DOWNLOAD_URLS; do
  echo ">>> Downloading artifact $COUNTER..."
  curl -s -L -H "Authorization: token $GH_TOKEN" -o manager_${COUNTER}.zip "$URL"
  
  echo ">>> Extracting..."
  unzip -q -o manager_${COUNTER}.zip -d manager_apk/
  rm manager_${COUNTER}.zip
  
  COUNTER=$((COUNTER+1))
done
unset IFS

echo ">>> Cleaning up unnecessary architectures..."
find manager_apk/ -type f \( -name "*x86*.apk" -o -name "*armeabi-v7a*.apk" -o -name "*universal*.apk" \) -exec rm -f {} +

echo ">>> Manager(s) successfully staged for final upload!"
ls -1 manager_apk/


    



