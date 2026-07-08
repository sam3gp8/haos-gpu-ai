#!/usr/bin/env bash
# =============================================================================
# validate-image.sh - static validation of a built HAOS GPU-AI target rootfs.
#
# Confirms every GPU component we intend to ship is actually present and wired
# into the built image, WITHOUT flashing hardware. Run it against output/target
# after a build (inside the builder container is easiest, since that tree is
# root-owned):
#
#   docker run --rm -v "$PWD:/workspace" -w /workspace \
#     haos-gpu-builder bash external/scripts/validate-image.sh output/target
#
# Exit code 0 = all checks passed.
# =============================================================================
set -uo pipefail   # deliberately NOT -e: run every check even if some fail

T="${1:-output/target}"
FAILED=0
pass(){ echo "  [PASS] $1"; }
fail(){ echo "  [FAIL] $1"; FAILED=1; }
info(){ echo "  [info] $1"; }
hasfile(){ [ -e "$T/$1" ] || ls "$T/$1" >/dev/null 2>&1; }
hasmod(){ find "$T/lib/modules" -name "$1" 2>/dev/null | grep -q .; }

[ -d "$T" ] || { echo "target dir not found: $T"; exit 2; }
echo "== validating rootfs: $T =="

echo "-- NVIDIA kernel modules --"
for m in nvidia nvidia-uvm nvidia-modeset nvidia-drm nvidia-peermem; do
	hasmod "${m}.ko*" && pass "${m}.ko" || fail "${m}.ko"
done

echo "-- Intel + AMD kernel modules --"
for m in i915 amdgpu; do
	hasmod "${m}.ko*" && pass "${m}.ko" || fail "${m}.ko"
done
hasmod "xe.ko*" && pass "xe.ko" || info "xe.ko not built (acceptable; i915 covers Intel)"

echo "-- NVIDIA driver user-space --"
for f in usr/lib/libcuda.so.1 usr/lib/libnvidia-ml.so.1 usr/bin/nvidia-smi usr/bin/nvidia-modprobe; do
	hasfile "$f" && pass "$f" || fail "$f"
done
hasfile "usr/lib/libnvidia-ptxjitcompiler.so.1" \
	&& info "libnvidia-ptxjitcompiler present (runtime PTX JIT)" \
	|| info "libnvidia-ptxjitcompiler absent (fine for Ada/RTX 4090)"

echo "-- NVIDIA container runtime (toolkit) --"
for f in usr/bin/nvidia-container-runtime usr/bin/nvidia-ctk; do
	hasfile "$f" && pass "$f" || fail "$f"
done
hasfile "usr/lib/libnvidia-container.so*" && pass "libnvidia-container.so" || fail "libnvidia-container.so"

echo "-- firmware --"
[ -d "$T/lib/firmware/amdgpu" ] && pass "amdgpu firmware ($(ls "$T/lib/firmware/amdgpu" 2>/dev/null | wc -l) files)" || fail "amdgpu firmware"
[ -d "$T/lib/firmware/i915" ]   && pass "i915 firmware ($(ls "$T/lib/firmware/i915" 2>/dev/null | wc -l) files)"   || fail "i915 firmware"

echo "-- host integration --"
hasfile "etc/udev/rules.d/99-gpu-compute-passthrough.rules" && pass "udev passthrough rules" || fail "udev rules"
hasfile "etc/docker/daemon.json"                            && pass "docker daemon.json"      || fail "daemon.json"
hasfile "etc/modprobe.d/gpu-ai.conf"                        && pass "modprobe (nouveau blacklist)" || fail "modprobe conf"

echo "-- boot-time services enabled --"
hasfile "etc/systemd/system/multi-user.target.wants/gpu-autodetect.service" && pass "gpu-autodetect.service enabled" || fail "gpu-autodetect.service NOT enabled"
hasfile "etc/systemd/system/timers.target.wants/haos-gpu-updater.timer"     && pass "haos-gpu-updater.timer enabled"  || fail "updater timer NOT enabled"
[ -x "$T/usr/bin/gpu-autodetect.sh" ]   && pass "gpu-autodetect.sh executable"   || fail "gpu-autodetect.sh missing/not executable"
[ -x "$T/usr/bin/haos-gpu-updater.sh" ] && pass "haos-gpu-updater.sh executable" || fail "haos-gpu-updater.sh missing/not executable"

echo "-- version + vendor contracts --"
info "$(grep -h '^VERSION=' "$T/etc/os-release" 2>/dev/null | head -1)"
for c in "$T"/usr/lib/haos-gpu/*.contract; do [ -f "$c" ] && info "$(basename "$c"): $(head -1 "$c")"; done

echo "== result =="
if [ "$FAILED" -eq 0 ]; then
	echo "  ALL STATIC CHECKS PASSED - the image carries the full tri-vendor stack."
else
	echo "  SOME CHECKS FAILED - see [FAIL] lines above."
fi
exit "$FAILED"
