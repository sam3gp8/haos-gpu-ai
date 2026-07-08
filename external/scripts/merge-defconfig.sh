#!/usr/bin/env bash
# =============================================================================
# merge-defconfig.sh
#
# Produces a merged defconfig = upstream HAOS generic_x86_64_defconfig + our
# GPU/AI overlay, WITHOUT modifying the submodule.
#
# The output lands in OUR external tree's configs/ directory. Buildroot searches
# the configs/ dir of every BR2_EXTERNAL tree, so `make generic_x86_64_gpu_ai_
# defconfig` finds it there. The generated file is git-ignored.
#
# Multi-value, space-separated variables that upstream already sets are APPENDED
# in place (a naive re-assignment would win last and silently drop upstream's
# values). Purely additive symbols come from configs/gpu_ai.fragment.
# =============================================================================
set -euo pipefail

EXT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # external/
ROOT="$(cd "$EXT/.." && pwd)"                            # repo root
SRC="${ROOT}/upstream/buildroot-external/configs/generic_x86_64_defconfig"
OUT="${EXT}/configs/generic_x86_64_gpu_ai_defconfig"

# Build profile selects the kernel fragment + additive fragment. The output
# defconfig name is stable across profiles (only its contents differ), so
# build.sh / the workflow do not need to change.
#   all        : NVIDIA + Intel + AMD (includes the Xe driver)
#   nvidia-amd : NVIDIA + AMD only, no Xe (smallest-surface NVIDIA target)
#   intel-amd  : Intel + AMD only, in-tree drivers, NO NVIDIA (pipeline proof;
#                near-certain to build on any kernel, incl. bleeding-edge 6.18)
PROFILE="${1:-all}"
case "$PROFILE" in
	all)
		FRAG="${EXT}/configs/gpu_ai.fragment"
		KFRAG='$(BR2_EXTERNAL_HAOS_GPU_AI_PATH)/kernel/gpu-ai.config' ;;
	nvidia-amd)
		FRAG="${EXT}/configs/gpu_ai-nvidia-amd.fragment"
		KFRAG='$(BR2_EXTERNAL_HAOS_GPU_AI_PATH)/kernel/gpu-ai-nvidia-amd.config' ;;
	intel-amd)
		FRAG="${EXT}/configs/gpu_ai-intel-amd.fragment"
		KFRAG='$(BR2_EXTERNAL_HAOS_GPU_AI_PATH)/kernel/gpu-ai.config' ;;
	*)
		echo "ERROR: unknown profile '$PROFILE' (use: all | nvidia-amd | intel-amd)" >&2; exit 1 ;;
esac
echo "Profile: $PROFILE"
OVERLAY='$(BR2_EXTERNAL_HAOS_GPU_AI_PATH)/rootfs-overlay'
PATCHDIR='$(BR2_EXTERNAL_HAOS_GPU_AI_PATH)/patches'
POSTBUILD='$(BR2_EXTERNAL_HAOS_GPU_AI_PATH)/scripts/post-build.sh'

[ -f "$SRC" ] || { echo "ERROR: upstream defconfig missing: $SRC" >&2
	echo "       Did you run: git submodule update --init --recursive ?" >&2; exit 1; }

mkdir -p "$(dirname "$OUT")"
cp "$SRC" "$OUT"

# append_var VAR VALUE : append " VALUE" inside VAR's quoted string, or add it.
append_var() {
	local var="$1" val="$2"
	if grep -q "^${var}=\"" "$OUT"; then
		# insert before the closing quote of the existing assignment
		sed -i "s|^\(${var}=\"[^\"]*\)\"|\1 ${val}\"|" "$OUT"
	else
		printf '%s="%s"\n' "$var" "$val" >> "$OUT"
	fi
}

append_var BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES "$KFRAG"
append_var BR2_ROOTFS_OVERLAY                     "$OVERLAY"
append_var BR2_GLOBAL_PATCH_DIR                    "$PATCHDIR"
append_var BR2_ROOTFS_POST_BUILD_SCRIPT           "$POSTBUILD"

# Purely additive symbols.
{
	echo ""
	echo "# ==== appended by merge-defconfig.sh ===="
	cat "$FRAG"
} >> "$OUT"

echo "Merged GPU/AI defconfig -> $OUT"
