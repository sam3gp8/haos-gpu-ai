#!/usr/bin/env bash
# =============================================================================
# haos-gpu-updater.sh
#
# Decoupled OTA path. Instead of trusting the HAOS Supervisor updater (which
# points at the official version server and would try to hand us a stock
# bundle), we pull OUR OWN signed .raucb from OUR GitHub Releases and install it
# with rauc. RAUC still enforces the custom `compatible` string and our keyring,
# so even if this script somehow fetched the wrong artifact it would be rejected.
#
# Portable on the HAOS host: uses only busybox-safe sed/awk (no `grep -P`, no
# assumption that jq/python exist). Runs from a daily systemd timer.
# =============================================================================
set -euo pipefail

REPO="${HAOS_GPU_UPDATE_REPO:-sam3gp8/haos-gpu-ai}"
API="https://api.github.com/repos/${REPO}/releases/latest"

log() { echo "[haos-gpu-updater] $*"; }

# Running OS version and the compatible string we will enforce.
running_ver="$(. /etc/os-release; echo "${VERSION:-unknown}")"
compat="$(sed -n 's/^compatible=\(.*\)$/\1/p' /etc/rauc/system.conf | tr -d '"' | head -n1)"
log "running version=${running_ver} compatible=${compat}"

meta="$(curl -fsSL -H 'Accept: application/vnd.github+json' "$API")" || {
	log "release query failed - skipping"; exit 0; }

# Portable JSON field extraction (busybox sed).
tag="$(printf '%s\n' "$meta" | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
[ -n "$tag" ] || { log "no tag_name in latest release - skipping"; exit 0; }

if [ "$tag" = "$running_ver" ]; then
	log "already up to date (${tag})"; exit 0
fi

url="$(printf '%s\n' "$meta" \
	| tr ',' '\n' \
	| sed -n 's/.*"browser_download_url":[[:space:]]*"\([^"]*\.raucb\)".*/\1/p' \
	| head -n1)"
[ -n "$url" ] || { log "no .raucb asset in ${tag} - skipping"; exit 0; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
log "downloading ${url}"
curl -fsSL -o "$tmp/update.raucb" "$url"

# Verify the bundle's compatible matches before installing.
if rauc info "$tmp/update.raucb" 2>/dev/null | grep -q "$compat"; then
	log "compatible verified; installing to inactive slot"
	rauc install "$tmp/update.raucb"
	log "install complete - reboot to activate the new slot"
else
	log "ERROR: bundle compatible mismatch or unreadable; refusing"
	exit 1
fi
