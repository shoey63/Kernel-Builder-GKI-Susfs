#!/bin/bash
# scripts/fetch_manager.sh

set -euo pipefail

VARIANT="${1}"
GH_TOKEN="${2}"
UPSTREAM_HASH="${3:-}"

# Inherit the repository variable from the YAML environment
REPO="${UPSTREAM_REPO}"

echo ">>> Searching $REPO for a Release Manager..."

# ReSukiSU (Frozen Museum Piece)
if [[ "${ROOT_MANAGER}" == "ReSukiSU" ]]; then
    echo ">>> Legacy ReSukiSU target detected. Bypassing API hunt..."
    echo ">>> Fetching frozen v4.2.0-rc3 Release APK..."
    
    mkdir -p manager_apk
    curl -s -L \
      -o "manager_apk/ReSukiSU_v4.2.0-rc3_35171-arm64-v8a-release.apk" \
      "https://github.com/Baka-SU/BakaSU/releases/download/v4.2.0-rc3/ReSukiSU_v4.2.0-rc3_35171-arm64-v8a-release.apk"
    
    echo ">>> Manager successfully staged for final upload!"
    ls -1 manager_apk/
    exit 0
fi

# ==========================================
# 1. DETERMINE RUN ID (DYNAMIC VS STABLE)
# ==========================================
if [ -n "${UPSTREAM_RUN_ID:-}" ]; then
    echo ">>> Dynamic Channel: Using pre-resolved YAML Run ID: ${UPSTREAM_RUN_ID}"
    TARGET_RUN_ID="$UPSTREAM_RUN_ID"
else
    echo ">>> Stable Channel: Hunting for exact-match Run ID for hash: ${UPSTREAM_HASH:0:7}..."
    
    EXACT_RUNS=$(curl -s -H "Authorization: token $GH_TOKEN" \
      "https://api.github.com/repos/$REPO/actions/workflows/$WORKFLOW_FILE/runs?head_sha=${UPSTREAM_HASH}&status=success&per_page=5")
    
    TARGET_RUN_ID=$(echo "$EXACT_RUNS" | jq -r '
      .workflow_runs[]? 
      | select(.artifacts_url != null) 
      | .id' | head -n 1)

    if [ -z "$TARGET_RUN_ID" ] || [ "$TARGET_RUN_ID" == "null" ]; then
        echo "[-] FATAL: Could not find a successful upstream run for stable hash ${UPSTREAM_HASH:0:7}."
        exit 1
    fi
    echo "  -> Found exact match Run ID: $TARGET_RUN_ID"
fi

# ==========================================
# 2. DOWNLOAD ARTIFACTS
# ==========================================
echo ">>> Requesting artifacts for Run ID: ${TARGET_RUN_ID}..."
ARTIFACTS_JSON=$(curl -s -H "Authorization: token $GH_TOKEN" \
  "https://api.github.com/repos/$REPO/actions/runs/$TARGET_RUN_ID/artifacts")

# Filter out unneeded architectures, debug/mapping files, and expired artifacts
DOWNLOAD_URLS=$(echo "$ARTIFACTS_JSON" | jq -r '
  .artifacts[]? 
  | select(.name | test("(?i)(manager|kernelsu[_-]v|bakasu|sukisu)"))
  | select(.name | test("(?i)(debug|mappings|gradle)") | not)
  | select(.name | test("(?i)(armeabi-v7a|universal|x86_64|riscv64)") | not)
  | select(.expired == false)
  | "ARTIFACT|\(.name)|\(.archive_download_url)" // empty')

if [ -z "$DOWNLOAD_URLS" ]; then
    echo "[-] Warning: Exhausted search. Failed to locate valid Manager artifacts for Run ID: $TARGET_RUN_ID."
    echo "[-] Continuing CI run to completion without staging Manager APKs."
    exit 0
fi

# ==========================================
# 3. EXTRACTION AND CLEANUP
# ==========================================
mkdir -p manager_apk

IFS=$'\n'
for ENTRY in $DOWNLOAD_URLS; do
  TYPE=$(echo "$ENTRY" | cut -d'|' -f1)
  ART_NAME=$(echo "$ENTRY" | cut -d'|' -f2)
  URL=$(echo "$ENTRY" | cut -d'|' -f3)
  
  if [[ "$TYPE" == *"ZIP"* ]] || [[ "$TYPE" == "ARTIFACT" ]]; then
      echo ">>> Downloading archive: $ART_NAME..."
      curl -s -L \
        -H "Authorization: token $GH_TOKEN" \
        -o "${ART_NAME}.zip" "$URL"
      
      echo ">>> Extracting $ART_NAME..."
      # Extract into an isolated subfolder to prevent APK name collisions
      mkdir -p "manager_apk/${ART_NAME}"
      unzip -q -o "${ART_NAME}.zip" -d "manager_apk/${ART_NAME}/"
      rm "${ART_NAME}.zip"
  fi
done
unset IFS

echo ">>> Cleaning up unnecessary architectures..."
# Only preserve the arm64-v8a files
find manager_apk/ -type f \( -name "*armeabi-v7a*" -o -name "*universal*" -o -name "*x86_64*" -o -name "*riscv64*" \) -exec rm -f {} +

echo ">>> Flattening directory and applying collision-safe naming..."
# Move all APKs to the root of manager_apk/ and prepend their artifact origin name
find manager_apk/ -mindepth 2 -type f -name "*.apk" | while read -r apk_path; do
    parent_dir=$(basename $(dirname "$apk_path"))
    base_name=$(basename "$apk_path")
    mv "$apk_path" "manager_apk/${parent_dir}_${base_name}"
done

# Clean up the empty extraction subdirectories
find manager_apk/ -mindepth 1 -type d -empty -delete

echo ">>> Manager(s) successfully staged for final upload!"
ls -1 manager_apk/
