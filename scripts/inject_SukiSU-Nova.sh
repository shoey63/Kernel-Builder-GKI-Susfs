#!/usr/bin/env bash
# scripts/inject_SukiSU-Nova.sh
# Dynamic/Stable SuSFS integration module for SukiSU-Nova

echo ">>> Executing Integration Module for SukiSU-Nova..."

echo ">>> 1. Cloning target branch (${KSU_VARIANT_REF}) from ${KSU_VARIANT_REPO_URL}..."
git clone -b "${KSU_VARIANT_REF}" "${KSU_VARIANT_REPO_URL}" "${MANAGER_DIR}"

ln -sfn "../${MANAGER_DIR}" "common/${MANAGER_DIR}"
cd common
bash "${MANAGER_DIR}/kernel/setup.sh" "${KSU_VARIANT_REF}"
cd ..

cd "${MANAGER_DIR}"

echo ">>> Configuring dummy Git identity for transplant and hotfix operations..."
git config --global user.email "runner@github.actions"
git config --global user.name "GitHub Actions Canary"

FORGEJO_GIT_URL="https://git.zako.shirkneko.top:20004/shirkneko/SukiSU.git"
GITHUB_GIT_URL="https://github.com/${UPSTREAM_REPO}.git"

echo ">>> 2. Fetching upstream data from Forgejo (with GitHub fallback)..."
if git fetch --quiet --tags --force "${FORGEJO_GIT_URL}" "${TARGET_BRANCH}" 2>/dev/null; then
    ACTIVE_UPSTREAM_URL="${FORGEJO_GIT_URL}"
    echo "  -> Synced upstream ${TARGET_BRANCH} from Forgejo."
else
    git fetch --quiet --tags --force "${GITHUB_GIT_URL}" "${TARGET_BRANCH}"
    ACTIVE_UPSTREAM_URL="${GITHUB_GIT_URL}"
    echo "  -> Synced upstream ${TARGET_BRANCH} from GitHub fallback."
fi

# Capture live upstream/main HEAD from Step 2 before Step 4 overwrites FETCH_HEAD
UPSTREAM_MAIN_HEAD=$(git rev-parse FETCH_HEAD 2>/dev/null || true)

if [ "${USE_DYNAMIC_TRANSPLANT}" == "true" ]; then
    echo ">>> 3. Dynamic mode active: Anchoring clone to YAML-provided Upstream Hash (${UPSTREAM_HASH:0:7})..."
    git reset --hard "${UPSTREAM_HASH}"

    echo ">>> 4. Fetching upstream builtin branch..."
    git fetch --quiet "${ACTIVE_UPSTREAM_URL}" builtin || git fetch --quiet "${GITHUB_GIT_URL}" builtin

    echo ">>> 5. Transplanting built-in SuSFS kernel/ tree onto pristine main anchor..."
    git rm -rf --quiet kernel/
    git checkout FETCH_HEAD -- kernel/

    git add kernel/
    git commit -m "chore: transplant built-in SuSFS kernel tree from upstream/builtin"
    UPSTREAM_BRANCH="${TARGET_BRANCH}"
else
    echo ">>> 3. Stable mode active: Resolving true upstream anchor via HEAD~1..."

    # Step back past the local 'chore: transplant...' commit to get the true upstream anchor
    UPSTREAM_HASH=$(git rev-parse HEAD~1)
    echo "  -> Locked stable anchor: ${UPSTREAM_HASH:0:7}"

    # Export it so fetch_manager.sh can use it later
    echo "UPSTREAM_HASH=${UPSTREAM_HASH}" >> "$GITHUB_ENV"
    UPSTREAM_BRANCH="${KSU_VARIANT_REF}"
fi

# Audit KERNEL_SU_UAPI_VERSION parity between live upstream/main (CNB Manager) and kernel's builtin uapi
UAPI_MAIN_REF="${UPSTREAM_MAIN_HEAD:-$UPSTREAM_HASH}"
MAIN_UAPI=$(git show "${UAPI_MAIN_REF}:uapi/supercall.h" 2>/dev/null \
    | sed -nE '/^[[:space:]]*(\/\/|\/\*|\*)/d; s/.*KERNEL_SU_UAPI_VERSION([[:space:]]*[,=][[:space:]]*|[[:space:]]+)([0-9]+).*/\2/p' \
    | head -n 1)
BUILTIN_UAPI=$(sed -nE '/^[[:space:]]*(\/\/|\/\*|\*)/d; s/.*KERNEL_SU_UAPI_VERSION([[:space:]]*[,=][[:space:]]*|[[:space:]]+)([0-9]+).*/\2/p' \
    kernel/include/uapi/supercall.h 2>/dev/null \
    | head -n 1)

if [ -z "$MAIN_UAPI" ] || [ -z "$BUILTIN_UAPI" ]; then
    echo "  [!] WARNING: Could not parse KERNEL_SU_UAPI_VERSION (main=${MAIN_UAPI:-missing}, builtin=${BUILTIN_UAPI:-missing})."
elif [ "$MAIN_UAPI" != "$BUILTIN_UAPI" ]; then
    echo "  [!] WARNING: UAPI drift detected! main=v${MAIN_UAPI} vs builtin=v${BUILTIN_UAPI} — CNB Manager may prompt 'upgrade kernel' until builtin catches up."
else
    echo "  [+] UAPI parity verified: KERNEL_SU_UAPI_VERSION=${BUILTIN_UAPI}"
fi

# ==========================================
# KPM OVERRIDES & UNIVERSAL HOTFIXES
# ==========================================
echo ">>> Applying KPM overrides..."
sed -i '/config KPM/,/help/ s/default n/default y/' kernel/Kconfig 2>/dev/null || true
sed -i '/select KALLSYMS/d' kernel/Kconfig 2>/dev/null || true

# Fix #1: Version-aware LSM Hook compatibility using BASE_VER (${BASE_VER})
echo ">>> Auditing LSM hook compatibility for BASE_VER: ${BASE_VER}..."
LSM_HOOK_FILE="kernel/hook/lsm_hook.c"

if [ -f "$LSM_HOOK_FILE" ] && grep -q 'security_add_hooks(ksu_hooks, ARRAY_SIZE(ksu_hooks), "ksu");' "$LSM_HOOK_FILE"; then
    if [ "${BASE_VER}" = "6.12" ]; then
        echo "  -> BASE_VER is 6.12. Bypassing security_add_hooks() to prevent 'Too many LSMs registered' panic..."

        # Mark ksu_hooks[] as __maybe_unused so Clang -Werror doesn't trip when security_add_hooks is disabled
        sed -i 's/static struct security_hook_list ksu_hooks\[\]/static struct security_hook_list __maybe_unused ksu_hooks[]/' "$LSM_HOOK_FILE"

        # Comment out security_add_hooks() completely so it cannot be re-matched or compiled on 6.12
        sed -i 's/security_add_hooks(ksu_hooks, ARRAY_SIZE(ksu_hooks), "ksu");/\/\* bypassed on 6.12: security_add_hooks(ksu_hooks, ARRAY_SIZE(ksu_hooks), "ksu"); \*\//' "$LSM_HOOK_FILE"

        echo "  [+] APPLIED Fix #1: Disabled security_add_hooks() and marked ksu_hooks __maybe_unused for BASE_VER 6.12."
    else
        echo "  -> BASE_VER is ${BASE_VER}. Standard dynamic runtime LSM registration is compatible. Skipping bypass."
    fi
else
    echo "  [i] SKIPPED Fix #1: lsm_hook.c already patched or not present."
fi

# Fix #2: Restore AVC Spoofing from upstream/main into builtin amalgamation
echo ">>> Restoring AVC Spoofing feature from upstream/main (${UPSTREAM_HASH:0:7})..."
git checkout "${UPSTREAM_HASH}" -- \
    kernel/feature/avc_spoof.c \
    kernel/feature/avc_spoof.h \
    kernel/runtime/ksud_boot.h 2>/dev/null || true

# 1. Inject AVC spoofing directly into the amalgamation wrapper
if [ -f "kernel/ksu_main.c" ] && ! grep -q 'avc_spoof.c' "kernel/ksu_main.c"; then
    echo '#include "feature/avc_spoof.c"' >> kernel/ksu_main.c
    echo "  [+] Injected avc_spoof.c into ksu_main.c amalgamation."
fi

# 2. Restore the AVC Spoofing enum that the builtin tree omits
for f in include/uapi/feature.h kernel/include/uapi/feature.h uapi/feature.h; do
    if [ -f "$f" ] && ! grep -q 'KSU_FEATURE_AVC_SPOOF' "$f"; then
        sed -i '/KSU_FEATURE_MOUNT_HIDE = 16,/a \    KSU_FEATURE_AVC_SPOOF = 10003,' "$f"
        echo "  [+] Restored KSU_FEATURE_AVC_SPOOF (10003) enum in $f"
    fi
done

# 3. Fix namespace collision exposed by the 10003 enum in the amalgamation wrapper
if [ -f "kernel/policy/feature.c" ] && ! grep -q 'feat_forced_mask' "kernel/policy/feature.c"; then
    sed -i 's/forced_mask/feat_forced_mask/g' kernel/policy/feature.c
    sed -i 's/forced_pending/feat_forced_pending/g' kernel/policy/feature.c
    echo "  [+] Decoupled namespace collisions in feature.c"
fi

# 4. Restore AVC Spoofing boot sequence directly into the amalgamation file
if [ -f "kernel/ksu_main.c" ] && ! grep -q 'ksu_avc_spoof_init();' "kernel/ksu_main.c"; then
    sed -i '/ksu_selinux_hide_init();/i \    extern void ksu_avc_spoof_init(void);' kernel/ksu_main.c
    sed -i '/ksu_selinux_hide_init();/a \    ksu_avc_spoof_init();' kernel/ksu_main.c

    sed -i '/ksu_selinux_hide_exit();/i \    extern void ksu_avc_spoof_exit(void);' kernel/ksu_main.c
    sed -i '/ksu_selinux_hide_exit();/a \    ksu_avc_spoof_exit();' kernel/ksu_main.c

    sed -i '/ksu_feature_apply_forced();/i \    extern void ksu_avc_spoof_late_init(void);' kernel/ksu_main.c
    sed -i '/ksu_feature_apply_forced();/i \    ksu_avc_spoof_late_init();' kernel/ksu_main.c

    echo "  [+] Restored AVC Spoofing ignition switches in ksu_main.c"
fi

# ==========================================
# VERSION & METADATA RESOLUTION (CNB -> FORGEJO -> GITHUB FALLBACK)
# ==========================================
echo ">>> Resolving SukiSU-Nova version metadata (CNB primary, Forgejo/GitHub fallback)..."

UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

# 1. Determine base tag from git (filtering only v[0-9]* tags like manager/build.gradle.kts)
CALCULATED_TAG=$(git describe --tags --abbrev=0 --match "v[0-9]*" "${UPSTREAM_HASH}" 2>/dev/null | sed 's/^v//' || git tag --list "v[0-9]*" --sort=-v:refname | head -n 1 | sed 's/^v//' || echo "3.0.0")
CALCULATED_TAG="${CALCULATED_TAG:-3.0.0}"

# 2. Try CNB manager-ci first (with 1 retry for cnb_clear_assets rotation window)
APK_FILENAME=""
for attempt in 1 2; do
    CNB_RESP=$(curl -sSL -A "$UA" --retry 3 --connect-timeout 10 --max-time 25 \
        -w "\nHTTP_CODE:%{http_code}" \
        "https://cnb.cool/shirkneko/sukisu-result/-/releases/tag/manager-ci" 2>&1 || true)
    CNB_CODE=$(echo "$CNB_RESP" | tail -n 1 | sed 's/^HTTP_CODE://')
    CNB_BODY=$(echo "$CNB_RESP" | sed '$d')

    APK_FILENAME=$(echo "$CNB_BODY" \
        | grep -oE '/shirkneko/sukisu-result/-/releases/download/manager-ci/[^"'\'' <>]+arm64-v8a[^"'\'' <>]*\.apk' \
        | grep -vi 'debug' | head -n 1 | xargs -r basename 2>/dev/null || true)

    [ -n "$APK_FILENAME" ] && break
    echo "  [!] [Attempt ${attempt}/2] CNB scrape empty (HTTP ${CNB_CODE})."
    if [ "$attempt" -lt 2 ]; then
        sleep 15
    fi
done

# 3. Fallback to Forgejo releases if CNB is unavailable
if [ -z "$APK_FILENAME" ]; then
    echo "  [!] CNB release metadata unavailable. Falling back to Forgejo..."
    FORGEJO_REL_JSON=$(curl -sL --retry 3 --connect-timeout 10 --max-time 25 \
        "https://git.zako.shirkneko.top:20004/api/v1/repos/shirkneko/SukiSU/releases" 2>/dev/null || true)

    # 3a. Parse bleeding-edge version code from Forgejo's manager-ci release title: "Manager CI (35055)"
    FJ_CI_TITLE=$(echo "$FORGEJO_REL_JSON" | jq -r '.[] | select(.tag_name == "manager-ci") | .name // empty' 2>/dev/null | head -n 1 || true)
    FJ_CI_CODE=$(echo "$FJ_CI_TITLE" | sed -nE 's/.*\(([0-9]+)\).*/\1/p')

    if [ -n "$FJ_CI_CODE" ]; then
        APK_FILENAME="SukiSU_Nova_v${CALCULATED_TAG}_${FJ_CI_CODE}-arm64-v8a-release.apk"
        echo "  -> Resolved bleeding-edge version from Forgejo manager-ci title ('${FJ_CI_TITLE}'): ${FJ_CI_CODE}"
    else
        # 3b. Fall back to Forgejo release assets (exact SHA -> manager-ci -> newest v[0-9]*)
        APK_FILENAME=$(echo "$FORGEJO_REL_JSON" | jq -r --arg sha "${UPSTREAM_HASH}" --arg short "${UPSTREAM_HASH:0:7}" '
            def pick_apk:
              [.assets[]? | select(.name | test("\\.apk$")) | select(.name | test("(?i)(debug|armeabi-v7a|x86_64|riscv64)") | not)]
              | (map(select(.name | test("arm64-v8a"))) + .)
              | .[0].name // empty;

            (
              [.[] | select((.target_commitish // "") as $tc | $tc == $sha or ($short != "" and ($tc | startswith($short)))) | pick_apk] +
              [.[] | select(.tag_name == "manager-ci") | pick_apk] +
              [.[] | select(.tag_name | test("^v[0-9]")) | pick_apk]
            ) | first // empty
        ' 2>/dev/null || true)
    fi
fi

# 4. Fallback to GitHub Releases if both CNB and Forgejo are unavailable
if [ -z "$APK_FILENAME" ]; then
    echo "  [!] Forgejo release metadata unavailable. Falling back to GitHub Releases..."
    GH_REL_JSON=$(curl -sL --connect-timeout 10 "https://api.github.com/repos/${UPSTREAM_REPO}/releases/latest" 2>/dev/null || true)
    APK_FILENAME=$(echo "$GH_REL_JSON" | jq -r '
        [.assets[]? | select(.name | test("\\.apk$")) | select(.name | test("(?i)(debug|armeabi-v7a|x86_64|riscv64)") | not)]
        | (map(select(.name | test("arm64-v8a"))) + .)
        | .[0].name // empty
    ' 2>/dev/null || true)
fi

# Extract version code and tag (works with or without -arm64-v8a in the filename)
APK_VER_CODE=$(echo "$APK_FILENAME" | sed -nE 's/.*_([0-9]+)(-[^.]*)?\.apk$/\1/p')
APK_VER_TAG=$(echo "$APK_FILENAME" | sed -nE 's/^SukiSU(_Nova)?_v?([^_]+)_[0-9]+.*\.apk$/\2/p')

if [ -n "$APK_VER_TAG" ]; then
    CALCULATED_TAG="$APK_VER_TAG"
fi

if [ -n "$APK_VER_CODE" ]; then
    TARGET_KSU_VER="$APK_VER_CODE"
    # Back-calculate count using SukiSU-Nova main formula: 30000 + COUNT + 996
    CALCULATED_COUNT=$((TARGET_KSU_VER - 30000 - 996))
    echo "  -> Matched Manager APK (${APK_FILENAME}): Version=${TARGET_KSU_VER}, Count=${CALCULATED_COUNT}, Tag=${CALCULATED_TAG}"
else
    # Pure local Git fallback using main's formula (30000 + count + 996)
    CALCULATED_COUNT=$(git rev-list --count "${UPSTREAM_HASH}" 2>/dev/null || echo "4002")
    TARGET_KSU_VER=$((30000 + CALCULATED_COUNT + 996))
    echo "  -> Fallback local Git math: Version=${TARGET_KSU_VER}, Count=${CALCULATED_COUNT}, Tag=${CALCULATED_TAG}"
fi

# Fix #3: Overwrite builtin's outdated version math (- 4001) with main's math (+ 996) and lock metadata for Kleaf sandbox
if [ -f "kernel/Makefile" ]; then
    SHORT_SHA="${UPSTREAM_HASH:0:8}"
    sed -i "s|^CURL_BIN[[:space:]]*:=.*|CURL_BIN := true|" kernel/Makefile
    sed -i "s|^VERSION_OFFSET[[:space:]]*:=.*|VERSION_OFFSET := 996|" kernel/Makefile
    sed -i "s|expr \$(VERSION_BASE) + \$(LOCAL_COUNT) - \$(VERSION_OFFSET)|expr \$(VERSION_BASE) + \$(LOCAL_COUNT) + \$(VERSION_OFFSET)|" kernel/Makefile
    sed -i "s|^KSU_VERSION[[:space:]]*:=.*|KSU_VERSION := ${TARGET_KSU_VER}|" kernel/Makefile
    sed -i "s|^VERSION_TAG[[:space:]]*:=.*|VERSION_TAG := ${CALCULATED_TAG}|" kernel/Makefile
    sed -i "s|^KSU_VERSION_FULL[[:space:]]*:=.*|KSU_VERSION_FULL := v${CALCULATED_TAG}-${SHORT_SHA}@${UPSTREAM_BRANCH}|" kernel/Makefile
    echo "  [+] APPLIED Fix #3: Locked kernel/Makefile to KSU_VERSION=${TARGET_KSU_VER} [v${CALCULATED_TAG}-${SHORT_SHA}@${UPSTREAM_BRANCH}]"
fi

git add -A
if ! git diff --cached --quiet; then
    git commit -m "chore: apply SukiSU-Nova hotfixes"
fi

cd ..

echo "  -> Target Tag: $CALCULATED_TAG"
echo "  -> Target Hash: $UPSTREAM_HASH"
echo "  -> Target Count: $CALCULATED_COUNT"
echo ">>> SukiSU-Nova integration complete."
