#!/usr/bin/env bash
# =============================================================================
# post-build.sh   (BR2_ROOTFS_POST_BUILD_SCRIPT)
#
# Runs after the target rootfs is assembled, before image packing. Buildroot
# passes the target directory as $1.
#
# Responsibilities:
#   1. Append the cosmetic "-gpu-ai-universal" suffix to /etc/os-release VERSION.
#      This is UX only - it stops the HA frontend from cleanly matching an
#      official version and offering a stock update. The HARD guards against a
#      stock image replacing ours are the RAUC `compatible` string + our keyring
#      (see rootfs-overlay/etc/rauc/system.conf), not this suffix.
#   2. Enable our systemd units (belt-and-suspenders vs. shipping .wants symlinks
#      in the overlay).
# =============================================================================
set -euo pipefail

TARGET="${1:?post-build.sh requires the target dir as \$1}"
SUFFIX="${HAOS_GPU_AI_SUFFIX:--gpu-ai-universal}"
OSREL="${TARGET}/etc/os-release"

if [ -f "$OSREL" ] && ! grep -q -- "$SUFFIX" "$OSREL"; then
	sed -i "s/^\(VERSION=\"[^\"]*\)\"/\1${SUFFIX}\"/" "$OSREL" || true
	sed -i "s/^\(PRETTY_NAME=\"[^\"]*\)\"/\1 ${SUFFIX}\"/" "$OSREL" || true
	echo "[post-build] applied version suffix ${SUFFIX} to os-release"
fi

# Enable units by creating the wants symlinks in the target.
enable_unit() {
	local unit="$1" target_wants="$2"
	local dir="${TARGET}/etc/systemd/system/${target_wants}.wants"
	mkdir -p "$dir"
	ln -sf "/usr/lib/systemd/system/${unit}" "${dir}/${unit}"
	echo "[post-build] enabled ${unit} (${target_wants})"
}

enable_unit gpu-autodetect.service     multi-user.target
enable_unit haos-gpu-updater.timer      timers.target

# --- host ldconfig (REQUIRED by nvidia-container-toolkit >= 1.17) -------------
# The toolkit bind-mounts the HOST's ldconfig into every GPU container to
# refresh its ld cache (the container-side mode was removed as a CVE fix).
# Without a host ldconfig the createContainer hook dies with
# "stat /sbin/ldconfig: no such file or directory" and every GPU container
# fails to start. Buildroot's glibc builds ldconfig but does not install it by
# default; BR2_PACKAGE_GLIBC_UTILS=y (set in our fragments) should install it -
# this is the belt-and-suspenders fallback that copies it from the glibc build
# tree if it is still missing. Buildroot exports BUILD_DIR to post-build hooks.
if [ ! -e "${TARGET}/usr/sbin/ldconfig" ] && [ ! -e "${TARGET}/sbin/ldconfig" ]; then
	ldc="$(find "${BUILD_DIR}"/glibc-*/build -type f -name ldconfig -path '*/elf/*' 2>/dev/null | head -n1)"
	if [ -n "$ldc" ]; then
		install -D -m 0755 "$ldc" "${TARGET}/usr/sbin/ldconfig"
		echo "[post-build] installed host ldconfig (from glibc build tree) -> /usr/sbin/ldconfig"
	else
		echo "[post-build] WARNING: no ldconfig available - NVIDIA GPU containers will fail their ldcache hook"
	fi
else
	echo "[post-build] host ldconfig already present"
fi
