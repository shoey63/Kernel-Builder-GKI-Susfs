#!/bin/bash
# scripts/fetch_manager.sh

set -euo pipefail

VARIANT="${1}"
GH_TOKEN="${2}"
UPSTREAM_HASH="${3:-}"

# Inherit the repository variable from the YAML environment
REPO="${UPSTREAM_REPO}"

echo ">>> Searching $REPO for a Release Manager..."

# ==========================================
# 0. SUKISU-NOVA FETCH (FORGEJO PRIMARY -> GITHUB FALLBACK)
# ==========================================
if [ "$VARIANT" == "SukiSU-Nova" ]; then
    mkdir -p manager_apk
    echo ">>> SukiSU-Nova detected: Querying Forgejo releases for matching arm64-v8a APK..."

    FORGEJO_JSON=$(curl -sL --retry 3 --connect-timeout 10 --max-time 30 \
      "https://git.zako.shirkneko.top:20004/api/v1/repos/shirkneko/SukiSU/releases" 2>/dev/null || true)

    # 1. Try exact commit match on Forgejo first, then fallback to Forgejo manager-ci / latest release
    APK_ENTRY=$(echo "$FORGEJO_JSON" | jq -r --arg sha "${UPSTREAM_HASH}" --arg short "${UPSTREAM_HASH:0:7}" '
      ([.[] | select(.target_commitish == $sha or (.target_commitish | startswith($short))) | .assets[]? | select(.name | test("arm64-v8a.*\\.apk$")) | "\(.name)|\(.browser_download_url)"] +
       [.[] | select(.tag_name == "manager-ci" or .tag_name == "v3.0.0") | .assets[]? | select(.name | test("arm64-v8a.*\\.apk$")) | "\(.name)|\(.browser_download_url)"]) | first // empty
    ' 2>/dev/null || true)

    if [ -n "$APK_ENTRY" ]; then
        APK_NAME=$(echo "$APK_ENTRY" | cut -d'|' -f1)
        APK_URL=$(echo "$APK_ENTRY" | cut -d'|' -f2)
        echo "  -> Found Forgejo APK: $APK_NAME"
        if curl -sL --retry 3 --connect-timeout 10 --max-time 120 -o "manager_apk/${APK_NAME}" "$APK_URL" && [ -s "manager_apk/${APK_NAME}" ]; then
            echo ">>> Manager successfully staged from Forgejo!"
            ls -1 manager_apk/
            exit 0
        else
            echo "  [!] Forgejo APK download failed or empty. Falling back to GitHub Releases..."
            rm -f "manager_apk/${APK_NAME}"
        fi
    else
        echo "  [!] Could not resolve APK from Forgejo. Falling back to GitHub Releases..."
    fi

    # 2. Fallback to GitHub Releases (latest release, then manager-ci tag)
    GH_REL_JSON=$(curl -sL -H "Authorization: token $GH_TOKEN" \
      "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null || true)

    GH_APK_ENTRY=$(echo "$GH_REL_JSON" | jq -r '
      .assets[]?
      | select(.name | test("arm64-v8a.*\\.apk$"))
      | "\(.name)|\(.browser_download_url)"' 2>/dev/null | head -n 1 || true)

    if [ -z "$GH_APK_ENTRY" ]; then
        GH_CI_JSON=$(curl -sL -H "Authorization: token $GH_TOKEN" \
          "https://api.github.com/repos/$REPO/releases/tags/manager-ci" 2>/dev/null || true)
        GH_APK_ENTRY=$(echo "$GH_CI_JSON" | jq -r '
          .assets[]?
          | select(.name | test("arm64-v8a.*\\.apk$"))
          | "\(.name)|\(.browser_download_url)"' 2>/dev/null | head -n 1 || true)
    fi

    if [ -n "$GH_APK_ENTRY" ]; then
        APK_NAME=$(echo "$GH_APK_ENTRY" | cut -d'|' -f1)
        APK_URL=$(echo "$GH_APK_ENTRY" | cut -d'|' -f2)
        echo ">>> Downloading fallback GitHub Release APK: $APK_NAME..."
        curl -sL -H "Authorization: token $GH_TOKEN" -o "manager_apk/${APK_NAME}" "$APK_URL"
        echo ">>> Manager successfully staged from GitHub Releases!"
        ls -1 manager_apk/
        exit 0
    else
        echo "[-] Warning: Failed to locate SukiSU-Nova APK on both Forgejo and GitHub Releases."
        exit 0
    fi
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
