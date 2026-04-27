#!/usr/bin/env bash
set -euo pipefail

die() {
  echo "[-] $*" >&2
  exit 1
}

info() {
  echo "[+] $*"
}

cd kernel_workspace
mkdir -p ../out

[ -d common ] || die "common/ not found in kernel_workspace"

KSU_NEXT_SETUP_URL="${KSU_NEXT_SETUP_URL:-https://raw.githubusercontent.com/pershoot/KernelSU-Next/dev-susfs/kernel/setup.sh}"
KSU_NEXT_REF="${KSU_NEXT_REF:-dev-susfs}"
KSU_NEXT_HOOK_MODE="${KSU_NEXT_HOOK_MODE:-}"

SETUP_SH="/tmp/ksu_next_setup.sh"

info "Fetching KernelSU-Next setup script"
curl -LSs "$KSU_NEXT_SETUP_URL" -o "$SETUP_SH"
chmod +x "$SETUP_SH"

ARGS=()
if [ -n "$KSU_NEXT_HOOK_MODE" ]; then
  ARGS+=("$KSU_NEXT_HOOK_MODE")
fi

info "Running KernelSU-Next setup"
bash "$SETUP_SH" "${ARGS[@]}" > ../out/ksu_next_setup.log 2>&1 || {
  cat ../out/ksu_next_setup.log
  die "KernelSU-Next setup failed"
}

KSU_REPO=""
if [ -d KernelSU-Next/.git ]; then
  KSU_REPO="KernelSU-Next"
elif [ -d KernelSU/.git ]; then
  KSU_REPO="KernelSU"
else
  cat ../out/ksu_next_setup.log || true
  die "KernelSU repo not found after setup"
fi

info "Forcing ${KSU_REPO} checkout to ${KSU_NEXT_REF}"
git -C "$KSU_REPO" fetch origin "$KSU_NEXT_REF" --depth=1 >> ../out/ksu_next_setup.log 2>&1 || {
  cat ../out/ksu_next_setup.log
  die "Failed to fetch KernelSU-Next ref ${KSU_NEXT_REF}"
}

git -C "$KSU_REPO" checkout -B "$KSU_NEXT_REF" FETCH_HEAD >> ../out/ksu_next_setup.log 2>&1 || {
  cat ../out/ksu_next_setup.log
  die "Failed to checkout KernelSU-Next ref ${KSU_NEXT_REF}"
}

detect_driver_root() {
  if [ -d common/drivers ]; then
    printf '%s\n' "common/drivers"
  elif [ -d aosp/drivers ]; then
    printf '%s\n' "aosp/drivers"
  elif [ -d drivers ]; then
    printf '%s\n' "drivers"
  else
    return 1
  fi
}

DRIVER_ROOT="$(detect_driver_root)" || die "Could not determine drivers root"
KSU_LINK="${DRIVER_ROOT}/kernelsu"
DRIVER_MAKEFILE="${DRIVER_ROOT}/Makefile"
DRIVER_KCONFIG="${DRIVER_ROOT}/Kconfig"

mkdir -p "$DRIVER_ROOT"
ln -sfn "../../${KSU_REPO}/kernel" "$KSU_LINK"

[ -L "$KSU_LINK" ] || [ -d "$KSU_LINK" ] || die "KernelSU link not found at $KSU_LINK"
[ -f "$DRIVER_MAKEFILE" ] || die "Missing $DRIVER_MAKEFILE"
[ -f "$DRIVER_KCONFIG" ] || die "Missing $DRIVER_KCONFIG"

KSU_TREE="$(readlink -f "$KSU_LINK" || true)"
[ -n "$KSU_TREE" ] || die "Could not resolve KernelSU symlink"

KSU_GIT_HEAD="$(git -C "$KSU_REPO" rev-parse --short HEAD 2>/dev/null || true)"
KSU_GIT_DESCRIBE="$(git -C "$KSU_REPO" describe --tags --always 2>/dev/null || true)"
KSU_GIT_BRANCH="$(git -C "$KSU_REPO" branch --show-current 2>/dev/null || true)"

{
  echo "KSU_NEXT_SETUP_URL=$KSU_NEXT_SETUP_URL"
  echo "KSU_NEXT_REF=$KSU_NEXT_REF"
  echo "KSU_NEXT_HOOK_MODE=${KSU_NEXT_HOOK_MODE:-<default>}"
  echo "KSU_REPO=$KSU_REPO"
  echo "DRIVER_ROOT=$DRIVER_ROOT"
  echo "KSU_LINK=$KSU_LINK"
  echo "KSU_TREE=$KSU_TREE"
  echo "KSU_GIT_HEAD=$KSU_GIT_HEAD"
  echo "KSU_GIT_DESCRIBE=$KSU_GIT_DESCRIBE"
  echo "KSU_GIT_BRANCH=${KSU_GIT_BRANCH:-<detached>}"
} > ../out/ksu_next_integration_report.txt

grep -n 'obj-\$(CONFIG_KSU).*kernelsu/' "$DRIVER_MAKEFILE" \
  > ../out/ksu_next_makefile_probe.txt || true

grep -n 'source "drivers/kernelsu/Kconfig"' "$DRIVER_KCONFIG" \
  > ../out/ksu_next_driver_kconfig_probe.txt || true

find -L "$KSU_LINK" -maxdepth 2 -type f | sort \
  > ../out/ksu_next_tree_files.txt || true

grep -R -n 'config KSU\|config KSU_' "$KSU_REPO/kernel" \
  > ../out/ksu_next_symbols.txt || true

{
  echo "=== KSU repo ==="
  echo "$KSU_REPO"
  echo
  echo "=== branch ==="
  git -C "$KSU_REPO" branch --show-current || true
  echo
  echo "=== HEAD ==="
  git -C "$KSU_REPO" rev-parse --short HEAD || true
  echo
  echo "=== describe ==="
  git -C "$KSU_REPO" describe --tags --always || true
  echo
  echo "=== recent log ==="
  git -C "$KSU_REPO" log --oneline -n 8 || true
  echo
  echo "=== search whole repo for SUSFS ==="
  grep -R -n -i 'susfs\|KSU_SUSFS' "$KSU_REPO" || true
  echo
  echo "=== symlinked tree ==="
  readlink -f "$KSU_LINK" || true
  echo
  echo "=== search symlinked tree for SUSFS ==="
  grep -R -n -i 'susfs\|KSU_SUSFS' "$KSU_LINK" || true
} > ../out/ksu_ref_probe.txt

cat ../out/ksu_ref_probe.txt

info "KernelSU-Next integration complete"
