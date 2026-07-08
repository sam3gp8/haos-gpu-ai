#!/usr/bin/env bash
# =============================================================================
# build.sh
#
# Drives a full HAOS GPU/AI build. Intended to run INSIDE the HAOS builder
# container (see .github/workflows/build-and-track.yml) but also works on any
# host that satisfies Buildroot's prerequisites.
#
# Key mechanics:
#   * BR2_EXTERNAL chains BOTH trees (colon-separated): HAOS's own
#     buildroot-external first, then ours. This is the supported Buildroot way
#     to layer external trees and keeps the submodule pristine.
#   * ota_compatible is exported so HAOS's RAUC templates bake our custom
#     `compatible` string into both the running system and the bundle.
# =============================================================================
set -euo pipefail

EXT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # external/
ROOT="$(cd "$EXT/.." && pwd)"                            # repo root
UPSTREAM="${ROOT}/upstream"
BR="${UPSTREAM}/buildroot"
EXT_HAOS="${UPSTREAM}/buildroot-external"
O="${ROOT}/output"
DEFCONFIG="generic_x86_64_gpu_ai_defconfig"

[ -d "$BR" ]       || { echo "ERROR: buildroot submodule missing: $BR" >&2; exit 1; }
[ -d "$EXT_HAOS" ] || { echo "ERROR: HAOS external tree missing: $EXT_HAOS" >&2; exit 1; }

# Build profile: 'all' (default), 'nvidia-amd' (NVIDIA+AMD, no Xe), or
# 'intel-amd' (in-tree only, no NVIDIA - the pipeline-proof target).
PROFILE="${PROFILE:-all}"

# 0. Fast-fail gate: kernel<->driver compatibility + asset reachability, run
#    BEFORE the long build. STRICT=1 aborts on hard failures.
STRICT="${STRICT:-1}" "${EXT}/scripts/preflight-check.sh" "$PROFILE"

# 1. Generate the merged defconfig in our tree's configs/.
# --- system partition size override (see README/SETUP: HAOS hardcodes 256M) ----
# HAOS sets the generic-x86-64 system partition to 256M in its
# buildroot-external/scripts/hdd-image.sh with NO env/meta override. A full
# tri-vendor GPU rootfs (~294M) does not fit, so bump it to 512M at build time.
# This edits the submodule WORKING TREE only (its committed revision is
# unchanged); it is idempotent and re-applied every build, with the logic kept
# here in our tree rather than as a committed change to upstream.
HDD_IMAGE_SH="${UPSTREAM}/buildroot-external/scripts/hdd-image.sh"
if [ -f "$HDD_IMAGE_SH" ] && grep -q '^SYSTEM_SIZE=256M$' "$HDD_IMAGE_SH"; then
	sed -i 's/^SYSTEM_SIZE=256M$/SYSTEM_SIZE=512M/' "$HDD_IMAGE_SH"
	echo ">>> bumped system partition SYSTEM_SIZE 256M -> 512M (fits GPU rootfs)"
fi

"${EXT}/scripts/merge-defconfig.sh" "$PROFILE"

# 2. DELIVERABLE E (a): custom RAUC `compatible` string.
#    HARDWARE-PROVEN FACT: exporting ota_compatible does NOTHING - HAOS derives
#    the string via the shell function hassos_rauc_compatible() at every
#    consumer (runtime system.conf AND the bundle manifest), overwriting any
#    env. So append our suffix at every CALL SITE in the upstream WORKING TREE
#    (commit untouched, idempotent, reapplied each build - same pattern as the
#    SYSTEM_SIZE bump). Result: system.conf and .raucb both carry
#    haos-generic-x86-64-gpu-ai, and stock bundles are rejected PRE-signature.
GPU_AI_COMPAT_SUFFIX="-gpu-ai"
for f in $(grep -rl --include='*.sh' 'hassos_rauc_compatible' "${UPSTREAM}/buildroot-external" 2>/dev/null); do
	grep -q '\$(hassos_rauc_compatible)' "$f" || continue           # callsites only, not the definition
	grep -q "hassos_rauc_compatible)${GPU_AI_COMPAT_SUFFIX}" "$f" && continue   # idempotent
	sed -i "s|\$(hassos_rauc_compatible)|\$(hassos_rauc_compatible)${GPU_AI_COMPAT_SUFFIX}|g" "$f"
	echo ">>> E: compatible suffix ${GPU_AI_COMPAT_SUFFIX} applied in ${f#${ROOT}/}"
done

# 2b. DELIVERABLE E (b): sign with YOUR CA, not a throwaway.
#     HARDWARE-PROVEN FACT: the genimage rauc block hardcodes key=/build/key.pem
#     cert=/build/cert.pem; when absent, HAOS self-signs with a FRESH throwaway
#     pair every run (that cert also becomes the baked /etc/rauc/keyring.pem).
#     Stage the user's CA there so the bundle signature AND the on-device
#     keyring are yours - stock (HA-signed) bundles then fail verification too.
GPU_AI_CA_STAGED=0
for d in "${ROOT}/pki" "${ROOT}"; do
	if [ -f "${d}/cert.pem" ] && [ -f "${d}/key.pem" ]; then
		mkdir -p /build 2>/dev/null || true
		cp "${d}/cert.pem" /build/cert.pem
		cp "${d}/key.pem"  /build/key.pem
		chmod 600 /build/key.pem
		echo ">>> E: RAUC signing with YOUR CA from ${d#${ROOT}/}/ (bundle + baked keyring)"
		GPU_AI_CA_STAGED=1
		break
	fi
done
if [ "${GPU_AI_CA_STAGED}" -ne 1 ]; then
	echo ">>> E WARNING: no pki/{cert,key}.pem found - a THROWAWAY self-signed key"
	echo ">>>            will be used and OTA decoupling is NOT secured."
	echo ">>>            Run: ./external/scripts/generate-ca.sh ./pki"
fi

# 3. Chain both external trees.
export BR2_EXTERNAL="${EXT_HAOS}:${EXT}"

mkdir -p "$O"

echo ">>> defconfig"
make -C "$BR" O="$O" BR2_EXTERNAL="$BR2_EXTERNAL" "$DEFCONFIG"

echo ">>> build (this is long: kernel + three GPU stacks + image assembly)"
make -C "$BR" O="$O" BR2_EXTERNAL="$BR2_EXTERNAL"

echo ">>> artifacts"
ls -lh "$O/images" || true
