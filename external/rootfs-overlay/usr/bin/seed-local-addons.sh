#!/bin/sh
# =============================================================================
# seed-local-addons.sh   (POSIX / busybox-ash)
#
# Local add-ons live on the DATA partition (/mnt/data/supervisor/addons/local),
# which the read-only rootfs cannot contain. This oneshot copies the add-on(s)
# bundled in the image (/usr/share/haos-gpu/) onto the data partition before
# the Supervisor's first scan, so "Ollama (GPU-AI Universal)" appears under
# Local add-ons with no Samba/SSH copying. Idempotent: never overwrites an
# existing (possibly user-modified) copy.
# =============================================================================
set -u
log() { echo "[seed-addons] $*"; }

SRC=/usr/share/haos-gpu/addon-ollama
DST=/mnt/data/supervisor/addons/local/ollama_gpu_ai

[ -d "$SRC" ] || { log "no bundled add-on found at $SRC"; exit 0; }
if [ -d "$DST" ]; then
	log "already seeded at $DST (leaving user copy untouched)"
	exit 0
fi
mkdir -p "$(dirname "$DST")"
if cp -r "$SRC" "$DST"; then
	log "seeded Ollama local add-on -> $DST"
else
	log "warn: copy failed (data partition not ready?)"
fi
exit 0
