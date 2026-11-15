#!/usr/bin/env bash
# scripts/inject_SukiSU-Nova.sh
# Dynamic SuSFS integration module for SukiSU-Nova

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

echo ">>> 2. Fetching upstream data from ${UPSTREAM_REPO} to cross-reference..."
git fetch --quiet "https://github.com/${UPSTREAM_REPO}.git" "${TARGET_BRANCH}"

if [ "${USE_DYNAMIC_TRANSPLANT}" == "true" ]; then
    echo ">>> 3. Dynamic mode active: Anchoring clone to YAML-provided Upstream Hash (${UPSTREAM_HASH:0:7})..."
    git reset --hard "${UPSTREAM_HASH}"

    echo ">>> 4. Fetching upstream builtin branch..."
    git fetch --quiet "https://github.com/${UPSTREAM_REPO}.git" builtin

    echo ">>> 5. Transplanting built-in SuSFS kernel/ tree onto pristine main anchor..."
    git rm -rf --quiet kernel/
    git checkout FETCH_HEAD -- kernel/

    git add kernel/
    git commit -m "chore: transplant built-in SuSFS kernel tree from upstream/builtin"
    UPSTREAM_BRANCH="${TARGET_BRANCH}"
else
    echo ">>> 3. Stable mode active: Calculating exact upstream anchor commit via merge-base..."
    
    # Mathematically finds the divergence point on main, bypassing the local transplant commit
    UPSTREAM_HASH=$(git merge-base HEAD FETCH_HEAD)
    echo "  -> Found mathematically true upstream anchor: ${UPSTREAM_HASH:0:7}"
    
    # Export it so fetch_manager.sh can use it in the exact-match API hunt later
    echo "UPSTREAM_HASH=$UPSTREAM_HASH" >> $GITHUB_ENV
    UPSTREAM_BRANCH="${KSU_VARIANT_REF}"
fi

echo ">>> Applying KPM overrides..."
sed -i '/config KPM/,/help/ s/default n/default y/' kernel/Kconfig 2>/dev/null || true
sed -i '/select KALLSYMS/d' kernel/Kconfig 2>/dev/null || true

echo ">>> Auditing and applying universal SukiSU-Nova hotfixes..."

# Fix #2: Safety check for MLS CEXPR_L2H2 constraint typo (scontext -> tcontext in selinux_hide.c)
if [ -f "kernel/feature/selinux_hide.c" ] && grep -A 1 "case CEXPR_L2H2:" kernel/feature/selinux_hide.c | grep -q "scontext->range.level\[0\]"; then
    sed -i '/case CEXPR_L2H2:/{n;s/scontext->range.level\[0\]/tcontext->range.level[0]/;}' kernel/feature/selinux_hide.c
    echo "  [+] APPLIED Fix #2: Corrected CEXPR_L2H2 MLS range check from scontext to tcontext (selinux_hide.c)."
else
    echo "  [i] SKIPPED Fix #2: CEXPR_L2H2 scontext bug not found in selinux_hide.c."
fi

# Fix #3: Version-aware LSM Hook compatibility using BASE_VER (${BASE_VER})
echo ">>> Auditing LSM hook compatibility for BASE_VER: ${BASE_VER}..."
LSM_HOOK_FILE="kernel/hook/lsm_hook.c"

if [ -f "$LSM_HOOK_FILE" ] && grep -q 'security_add_hooks(ksu_hooks, ARRAY_SIZE(ksu_hooks), "ksu");' "$LSM_HOOK_FILE"; then
    if [ "${BASE_VER}" = "6.12" ]; then
        echo "  -> BASE_VER is 6.12. Bypassing security_add_hooks() to prevent 'Too many LSMs registered' panic..."
        
        # 1. Mark ksu_hooks[] as __maybe_unused so Clang -Werror doesn't trip when security_add_hooks is disabled
        sed -i 's/static struct security_hook_list ksu_hooks\[\]/static struct security_hook_list __maybe_unused ksu_hooks[]/' "$LSM_HOOK_FILE"
        
        # 2. Comment out security_add_hooks() completely so it cannot be re-matched or compiled on 6.12
        sed -i 's/security_add_hooks(ksu_hooks, ARRAY_SIZE(ksu_hooks), "ksu");/\/\* bypassed on 6.12: security_add_hooks(ksu_hooks, ARRAY_SIZE(ksu_hooks), "ksu"); \*\//' "$LSM_HOOK_FILE"
        
        echo "  [+] APPLIED Fix #3: Disabled security_add_hooks() and marked ksu_hooks __maybe_unused for BASE_VER 6.12."
    else
        echo "  -> BASE_VER is ${BASE_VER}. Standard dynamic runtime LSM registration is compatible. Skipping bypass."
    fi
else
    echo "  [i] SKIPPED Fix #3: lsm_hook.c already patched or not present."
fi

# Fix #4: Restore AVC Spoofing from upstream/main into builtin amalgamation
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
if [ -f "kernel/policy/feature.c" ]; then
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

git add -A
if ! git diff --cached --quiet; then
    git commit -m "chore: apply SukiSU-Nova hotfixes"
fi

# Calculate the official counts EXACTLY from the rock-solid hash
CALCULATED_COUNT=$(git rev-list --count "${UPSTREAM_HASH}" 2>/dev/null || echo "11950")
CALCULATED_TAG=$(git describe --tags --abbrev=0 "${UPSTREAM_HASH}" 2>/dev/null | sed 's/^v//' || echo "0.0.0")

cd ..

echo "  -> Target Tag: $CALCULATED_TAG"
echo "  -> Target Hash: $UPSTREAM_HASH"
echo "  -> Target Count: $CALCULATED_COUNT"
echo ">>> SukiSU-Nova integration complete."
