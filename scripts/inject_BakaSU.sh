#!/usr/bin/env bash
# scripts/inject_BakaSU.sh

echo ">>> Executing Integration Module for BakaSU..."

# 1. Universally clone the target branch handed down by the YAML
# (Dynamic = Pristine Upstream. Stable = shoey63 Fork)
echo ">>> 1. Cloning target branch (${KSU_VARIANT_REF}) from ${KSU_VARIANT_REPO_URL}..."
git clone -b "${KSU_VARIANT_REF}" "${KSU_VARIANT_REPO_URL}" "${MANAGER_DIR}"

ln -sfn "../${MANAGER_DIR}" "common/${MANAGER_DIR}"
cd common
bash "${MANAGER_DIR}/kernel/setup.sh" "${KSU_VARIANT_REF}"
cd ..

cd "${MANAGER_DIR}"

echo ">>> 2. Fetching upstream data from ${UPSTREAM_REPO} to cross-reference..."
# Safely fetch without tags to prevent local collision panics during stable runs
git fetch --quiet "https://github.com/${UPSTREAM_REPO}.git" "${TARGET_BRANCH}"

if [ "${USE_DYNAMIC_TRANSPLANT}" == "true" ]; then
    echo ">>> 3. Dynamic mode active: Anchoring pristine clone to YAML-provided Upstream Hash (${UPSTREAM_HASH:0:7})..."
    
    # We are already in the official upstream repo. Just lock to the exact verified hash.
    git reset --hard "${UPSTREAM_HASH}"
    
    UPSTREAM_BRANCH="${TARGET_BRANCH}"

    echo ">>> Applying dynamic Kleaf bypass & Kconfig overrides..."
    sed -i 's/default KSU_TRACEPOINT_HOOK/default KSU_SUSFS/g' kernel/Kconfig
    sed -i 's/bool "Tracepoint Syscall Redirect"/bool "Tracepoint Syscall Redirect"\n\t\tdepends on n/g' kernel/Kconfig
    sed -i 's/depends on KSU != m/depends on n/g' kernel/Kconfig
    sed -i 's/ifeq ($(shell test -e $(srctree)\/fs\/susfs.c.*/ifeq (0,0)/g' kernel/Kbuild
    sed -i 's/cat $(srctree)\/include\/linux\/susfs.h |/cat $(srctree)\/include\/linux\/susfs.h 2>\/dev\/null |/g' kernel/Kbuild
else
    echo ">>> 3. Stable mode active: Calculating exact upstream anchor commit via merge-base..."
    
    # Mathematically finds the divergence point, bypassing any custom emergency commits
    UPSTREAM_HASH=$(git merge-base HEAD FETCH_HEAD)
    echo "  -> Found mathematically true upstream anchor: ${UPSTREAM_HASH:0:7}"
    
    # Export it so fetch_manager.sh can use it in the exact-match API hunt later
    echo "UPSTREAM_HASH=$UPSTREAM_HASH" >> $GITHUB_ENV
    UPSTREAM_BRANCH="${KSU_VARIANT_REF}"
fi

# 4. Calculate the official counts EXACTLY from the rock-solid hash
CALCULATED_COUNT=$(git rev-list --count "${UPSTREAM_HASH}" 2>/dev/null || echo "11950")
CALCULATED_TAG=$(git describe --tags --abbrev=0 "${UPSTREAM_HASH}" 2>/dev/null || echo "v0.0.0")

# ---------------------------------------------------------
# BakaSU Hotfixes (Applied universally to satisfy linkers)
# ---------------------------------------------------------

# We strip the $(error ...) directive to force compilation of our custom port.
SUSFS_COMPAT_MK="kernel/tools/susfs_compat.mk"
if [ -f "$SUSFS_COMPAT_MK" ]; then
    echo ">>> [HOTFIX] Neutering BakaSU strict SuSFS version gatekeeper..."
    sed -i '/Please wait susfs update/d' "$SUSFS_COMPAT_MK"
else
    echo ">>> [NOTICE] BakaSU gatekeeper file not found at $SUSFS_COMPAT_MK"
fi

# SELinux Hide LTO and Kernel Compat Patches
SELINUX_HIDE_FILE="kernel/feature/selinux_hide.c"
    
# 1. Force compile manual hooks to satisfy 50_patch linker requirements
echo ">>> [HOTFIX] Exposing BakaSU static symbols for hooks.c linker..."
sed -i 's|#include "compat/kernel_compat.h"|#include "compat/kernel_compat.h"\n\n/* Force compile manual hooks */\n#undef KSU_COMPAT_HAS_SUSFS_FEATURE_SELINUX_HIDE|g' "$SELINUX_HIDE_FILE"
    
sed -i -E 's/(__maybe_static|static)[[:space:]]+ssize_t my_write_context/ssize_t my_write_context/g' "$SELINUX_HIDE_FILE"
sed -i -E 's/(__maybe_static|static)[[:space:]]+ssize_t my_write_access/ssize_t my_write_access/g' "$SELINUX_HIDE_FILE"

# 3. Polyfill 50_patch Linker Stubs (Weak Polyfills)
echo ">>> [HOTFIX] Injecting safe WEAK C stubs to bypass linker panics..."
cat << 'EOF' >> "$SELINUX_HIDE_FILE"

/* BakaSU 50_patch Hook Linker Stubs (WEAK to avoid collisions) */
struct filename;
struct user_arg_ptr;
struct task_struct;

/* Safely bypasses SuSFS preinit interception to prevent Rescue Party (Yields to native preinit.c if present) */
__attribute__((weak)) int ksu_setup_preinit_file(struct filename **filename_ptr, struct user_arg_ptr *argv_user) {
    return 0; 
}

__attribute__((weak)) int ksu_preinit_handle_post_execveat(int *fd, struct filename **filename_ptr,
                void *argv_user, void *envp_user,
                int *flags, int *retval, int *preinit_fd) {
    return 0;
}

/* Satisfies static hooks.c calls since upstream uses a macro alias that we undefine */
#if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 11, 0) || defined(KSU_COMPAT_SETPROCATTR_USE_NEW_PROTOTYPE)
__attribute__((weak)) int __nocfi my_setprocattr(const char *name, void *value, size_t size) {
    return ksu_handle_selinux_setprocattr(name, value, size);
}
#else
__attribute__((weak)) int __nocfi my_setprocattr(struct task_struct *p, char *name, void *value, size_t size) {
    return ksu_handle_selinux_setprocattr(p, name, value, size);
}
#endif
EOF

# 4. Un-hide static SELinux state variables to satisfy 50_patch linker requirements
echo ">>> [HOTFIX] Un-hiding BakaSU static SELinux state variables for 50_patch..."

# Strip static prefixes so the 50_ patch can link to BakaSU's native state
sed -i -E 's/(__maybe_static|static)[[:space:]]+bool ksu_selinux_hide/bool ksu_selinux_hide/g' "$SELINUX_HIDE_FILE"
sed -i -E 's/(__maybe_static|static)[[:space:]]+struct page \*fake_status/struct page \*fake_status/g' "$SELINUX_HIDE_FILE"
sed -i -E 's/(__maybe_static|static)[[:space:]]+DEFINE_STATIC_KEY_FALSE/DEFINE_STATIC_KEY_FALSE/g' "$SELINUX_HIDE_FILE"
sed -i -E 's/(__maybe_static|static)[[:space:]]+void initialize_fake_status/void initialize_fake_status/g' "$SELINUX_HIDE_FILE"
sed -i -E 's/(__maybe_static|static)[[:space:]]+struct selinux_policy \*backup_sepolicy/struct selinux_policy \*backup_sepolicy/g' "$SELINUX_HIDE_FILE"

# Universal fake_state polyfill to survive LTO
sed -i -E 's/^[ \t]*static[ \t]+struct selinux_state fake_state/struct selinux_state fake_state/g' "$SELINUX_HIDE_FILE"
if ! grep -q "KSU_FAKE_STATE_POLYFILL" "$SELINUX_HIDE_FILE"; then
    cat << 'EOF' >> "$SELINUX_HIDE_FILE"

/* KSU_FAKE_STATE_POLYFILL */
__attribute__((weak)) struct selinux_state fake_state = {0};
EOF
fi
echo "  -> BakaSU legacy variables safely un-hidden."

cd ..

echo "  -> Target Tag: $CALCULATED_TAG"
echo "  -> Target Hash: $UPSTREAM_HASH"
echo "  -> Target Count: $CALCULATED_COUNT"
echo ">>> BakaSU integration complete."
