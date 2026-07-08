#!/bin/sh
# =============================================================================
# gpu-autodetect.sh   (POSIX / busybox-ash - HAOS may not ship bash, and /bin/sh
# is always busybox ash; the script below uses only POSIX constructs)
#
# Runs once at boot (before docker.service). Detects which GPU vendor is present
# and loads ONLY that vendor's driver stack, then sets Docker's default runtime
# to nvidia iff an NVIDIA GPU is present.
#
# IMPORTANT: HAOS does NOT ship `lspci`, and its /bin/sh is busybox ash. So we
# detect GPUs by reading PCI vendor/class straight from the kernel's sysfs tree
# (always present), and every step is non-fatal: a box with only one vendor must
# not error. `set -e` is deliberately NOT used - a missing vendor is a normal
# outcome, not a failure - and the systemd unit uses ExecStart=- so this can
# never wedge boot.
# =============================================================================
set -u

NVIDIA_PRESENT=0
AMD_PRESENT=0
INTEL_PRESENT=0

log() { echo "[gpu-autodetect] $*"; }

# has_vendor <id>: true if any PCI *display* controller (class 0x03xxxx) reports
# the given vendor id. Pure sysfs; no external tools (no lspci).
has_vendor() {
	want="0x$1"
	for dev in /sys/bus/pci/devices/*; do
		[ -r "$dev/class" ] || continue
		class="$(cat "$dev/class" 2>/dev/null)"
		case "$class" in
			0x03*) : ;;          # VGA / 3D / Display controller
			*) continue ;;
		esac
		vendor="$(cat "$dev/vendor" 2>/dev/null)"
		[ "$vendor" = "$want" ] && return 0
	done
	return 1
}

# --- NVIDIA (10de) --------------------------------------------------------
if has_vendor 10de; then
	log "NVIDIA GPU detected - loading proprietary stack"
	modprobe nvidia         || log "warn: modprobe nvidia failed"
	modprobe nvidia-uvm     || log "warn: modprobe nvidia-uvm failed"
	modprobe nvidia-modeset || log "warn: modprobe nvidia-modeset failed"
	modprobe nvidia-drm     || log "warn: modprobe nvidia-drm failed"
	if command -v nvidia-modprobe >/dev/null 2>&1; then
		nvidia-modprobe -c 0 -u || log "warn: nvidia-modprobe node creation failed"
	fi
	NVIDIA_PRESENT=1
fi

# --- AMD (1002) -----------------------------------------------------------
if has_vendor 1002; then
	log "AMD GPU detected - loading amdgpu + KFD"
	modprobe amdgpu || log "warn: modprobe amdgpu failed"
	AMD_PRESENT=1
fi

# --- Intel (8086) ---------------------------------------------------------
if has_vendor 8086; then
	log "Intel GPU detected - loading i915/xe"
	modprobe i915 || log "warn: modprobe i915 failed"
	modprobe xe 2>/dev/null || true
	INTEL_PRESENT=1
fi

log "detection summary: nvidia=$NVIDIA_PRESENT amd=$AMD_PRESENT intel=$INTEL_PRESENT"

# --- Docker default runtime ---------------------------------------------------
# /etc/docker is part of the READ-ONLY rootfs on HAOS (no overlay bind for it),
# so daemon.json CANNOT be rewritten at boot - a conditional runtime switch here
# is structurally impossible. "default-runtime": "nvidia" is therefore BAKED
# into the image's daemon.json. Tri-vendor safe: the nvidia runtime is a runc
# shim whose hook no-ops unless a container sets NVIDIA_VISIBLE_DEVICES, so on
# Intel/AMD-only hosts every normal container (Supervisor, Core, add-ons) runs
# untouched; only a container explicitly requesting NVIDIA fails - correctly.
log "docker default-runtime is baked into daemon.json (read-only /etc/docker)"

log "GPU autodetect complete"
exit 0
