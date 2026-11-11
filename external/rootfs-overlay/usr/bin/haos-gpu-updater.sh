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
# Portable on the HAOS host: busybox-safe sed/awk only (no `grep -P`, no
# `sort -V`, no assumption that jq/python exist). Runs from a daily timer.
#
# Operator overrides (optional) live on the WRITABLE data partition, because the
# rootfs is read-only. Create /mnt/data/haos-gpu-updater.conf with any of:
#     HAOS_GPU_ALLOW_MAJOR_UPGRADE=1   # allow cross-LINE upgrades (default 0)
#     HAOS_GPU_AUTO_REBOOT=1           # reboot after staging     (default 0)
#     HAOS_GPU_UPDATE_REPO=owner/name  # override the release source
# Defaults are the SAFE ones: line-pinned (a 17.x box never auto-jumps to 18.x -
# a major bump stays a deliberate manual flash) and stage-only (no surprise
# reboot). A staged bundle is inert until the next reboot either way.
# =============================================================================
set -euo pipefail

REPO="${HAOS_GPU_UPDATE_REPO:-sam3gp8/haos-gpu-ai}"
CONF="/mnt/data/haos-gpu-updater.conf"
STAGED_MARKER="/mnt/data/haos-gpu-update-pending"

log() { echo "[haos-gpu-updater] $*"; }

# Optional operator overrides from the writable data partition (rootfs is RO).
if [ -r "$CONF" ]; then . "$CONF" || log "WARN: could not source ${CONF}"; fi

REPO="${HAOS_GPU_UPDATE_REPO:-$REPO}"
RELEASES_API="https://api.github.com/repos/${REPO}/releases?per_page=100"
ALLOW_MAJOR="${HAOS_GPU_ALLOW_MAJOR_UPGRADE:-0}"   # 0 = line-pinned (safe default)
AUTO_REBOOT="${HAOS_GPU_AUTO_REBOOT:-0}"           # 0 = stage only; operator reboots

# Dotted-numeric "greater than": ver_gt A B is true when A > B (major, then
# minor). Written as explicit if/return so it is safe under `set -e`.
ver_gt() {
	av="$1"; bv="$2"
	a1="${av%%.*}"; b1="${bv%%.*}"
	case "$av" in *.*) a2="${av#*.}"; a2="${a2%%.*}";; *) a2=0;; esac
	case "$bv" in *.*) b2="${bv#*.}"; b2="${b2%%.*}";; *) b2=0;; esac
	if [ "$a1" -ne "$b1" ]; then
		if [ "$a1" -gt "$b1" ]; then return 0; else return 1; fi
	fi
	if [ "${a2:-0}" -gt "${b2:-0}" ]; then return 0; else return 1; fi
}

# --- Running version + line ---------------------------------------------------
running_raw="$(. /etc/os-release; echo "${VERSION:-unknown}")"
running_ver="${running_raw%%-*}"          # 17.3-gpu-ai-universal -> 17.3
running_major="${running_ver%%.*}"        # 17.3 -> 17
compat="$(sed -n 's/^compatible=\(.*\)$/\1/p' /etc/rauc/system.conf | tr -d '"' | head -n1)"
log "running=${running_raw} (line ${running_major}.x) compat=${compat} allow_major=${ALLOW_MAJOR} auto_reboot=${AUTO_REBOOT}"

case "$running_major" in
	''|*[!0-9]*) log "cannot parse a numeric major from '${running_raw}' - skipping"; exit 0 ;;
esac

# Clear a stale pending-reboot marker once the staged version is actually running.
if [ -r "$STAGED_MARKER" ]; then
	done_ver="$(sed -n 's/^staged=//p' "$STAGED_MARKER" 2>/dev/null | head -n1)"
	if [ "$done_ver" = "$running_ver" ]; then rm -f "$STAGED_MARKER" 2>/dev/null || true; fi
fi

# --- Pick the highest-VERSION eligible release (not newest-by-timestamp) ------
# GitHub /releases/latest orders by publish time, which is unreliable here (the
# forced 17.3 release was published after 18.3). Select by VERSION over the whole
# feed, honoring the line pin unless HAOS_GPU_ALLOW_MAJOR_UPGRADE=1. Skip
# drafts/prereleases so marking a release prerelease still hides it from OTA.
list="$(curl -fsSL -H 'Accept: application/vnd.github+json' "$RELEASES_API")" || {
	log "release query failed - skipping"; exit 0; }

all_tags="$(printf '%s\n' "$list" | tr ',' '\n' \
	| sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p')"
[ -n "$all_tags" ] || { log "no releases found - skipping"; exit 0; }

cand=""; url=""
for t in $all_tags; do
	case "$t" in ''|*[!0-9.]*) continue ;; esac                      # numeric tags only
	if [ "$ALLOW_MAJOR" != "1" ] && [ "${t%%.*}" != "$running_major" ]; then
		continue                                                     # line pin
	fi
	if [ -n "$cand" ] && ! ver_gt "$t" "$cand"; then continue; fi    # keep the max
	rel="$(curl -fsSL -H 'Accept: application/vnd.github+json' \
		"https://api.github.com/repos/${REPO}/releases/tags/${t}")" || continue
	printf '%s' "$rel" | grep -q '"draft"[[:space:]]*:[[:space:]]*true' && continue
	printf '%s' "$rel" | grep -q '"prerelease"[[:space:]]*:[[:space:]]*true' && continue
	t_url="$(printf '%s\n' "$rel" | tr ',' '\n' \
		| sed -n 's/.*"browser_download_url":[[:space:]]*"\([^"]*\.raucb\)".*/\1/p' | head -n1)"
	[ -n "$t_url" ] || continue
	cand="$t"; url="$t_url"
done

[ -n "$cand" ] || { log "no eligible release with a .raucb asset - skipping"; exit 0; }

if ! ver_gt "$cand" "$running_ver"; then
	log "already up to date (running ${running_ver}, newest eligible ${cand})"; exit 0
fi

log "update available: ${running_ver} -> ${cand} (allow_major=${ALLOW_MAJOR})"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
log "downloading ${url}"
curl -fsSL -o "$tmp/update.raucb" "$url"

# Verify compatible AND signature. Do NOT hide rauc stderr: a keyring/signature
# rejection must be reported as such, not misread as a "compatible mismatch".
info_rc=0
info_out="$(rauc info "$tmp/update.raucb" 2>&1)" || info_rc=$?
if [ "$info_rc" -ne 0 ]; then
	log "ERROR: rauc info failed (rc=${info_rc}) - signature/keyring rejected or bundle unreadable; refusing"
	printf '%s\n' "$info_out"
	exit 1
fi
if ! printf '%s' "$info_out" | grep -q "$compat"; then
	log "ERROR: bundle compatible does not match '${compat}' - refusing"
	exit 1
fi

log "compatible + signature verified; installing ${cand} to the inactive slot"
if ! rauc install "$tmp/update.raucb"; then
	log "ERROR: rauc install failed for ${cand} - inactive slot unchanged"
	exit 1
fi

# Pending-reboot visibility: a staged bundle is inert until reboot. Stock HAOS
# raises a Supervisor UI notification; we run outside Supervisor, so leave a loud
# journal line + a marker on the writable data partition.
{ echo "staged=${cand}"; echo "from=${running_ver}"; echo "at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"; } \
	> "$STAGED_MARKER" 2>/dev/null || log "WARN: could not write ${STAGED_MARKER}"
log "NOTICE: ${cand} staged to the inactive slot - REBOOT REQUIRED to activate (marker: ${STAGED_MARKER})."

if [ "$AUTO_REBOOT" = "1" ]; then
	log "HAOS_GPU_AUTO_REBOOT=1 -> rebooting now to activate ${cand}"
	systemctl reboot
else
	log "set HAOS_GPU_AUTO_REBOOT=1 in ${CONF} for hands-off reboot, or reboot manually (ha host reboot)."
fi
