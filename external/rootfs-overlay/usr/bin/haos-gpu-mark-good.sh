#!/bin/sh
# =============================================================================
# haos-gpu-mark-good.sh   (POSIX / busybox-ash)
#
# Marks the currently-booted RAUC slot GOOD so the grub A/B "try" counter is
# reset and the bootloader keeps booting this slot instead of eventually falling
# back to the rescue shell.
#
# WHY THIS EXISTS: HAOS's grub.cfg only auto-boots a slot while OK==1 AND TRY<3,
# and it increments TRY on every boot attempt. On stock HAOS the Supervisor
# calls the equivalent of `rauc status mark-good` once it is healthy, which
# resets TRY. This custom branch cannot rely on that (a slow or networkless boot
# never reaches that point), so TRY climbs to 3 and the box strands in rescue.
# This runs early every boot and resets it directly.
#
# TRADE-OFF: marking good this early trades some A/B rollback safety for boot
# robustness on a (typically) single-slot appliance. A stricter version would
# gate on Supervisor/HA health, but that requires a fully-up Supervisor - the
# exact thing a networkless boot lacks. Breaking the rescue loop wins here.
# =============================================================================
set -u
log() { echo "[mark-good] $*"; }

# 1. Tell RAUC this slot booted OK (updates its status view).
if command -v rauc >/dev/null 2>&1; then
	rauc status mark-good >/dev/null 2>&1 && log "rauc status mark-good ok" \
		|| log "warn: rauc status mark-good failed (continuing)"
fi

# 2. Reset the grub try counter directly. RAUC's grub backend does not reliably
#    reset TRY against HAOS's grubenv, AND HAOS ships TWO grubenv files
#    (/mnt/boot/EFI/grubenv and /mnt/boot/EFI/BOOT/grubenv) - grub may read a
#    different one than rauc/system.conf writes. So update EVERY grubenv file we
#    find under the boot partition; whichever grub actually reads will be good.
SLOT="$(tr ' ' '\n' < /proc/cmdline | sed -n 's/^rauc\.slot=//p' | head -n1)"
found_any=0
for GRUBENV in $(find /mnt/boot -name grubenv 2>/dev/null); do
	command -v grub-editenv >/dev/null 2>&1 || break
	found_any=1
	case "$SLOT" in
		A) grub-editenv "$GRUBENV" set A_OK=1; grub-editenv "$GRUBENV" set A_TRY=0 ;;
		B) grub-editenv "$GRUBENV" set B_OK=1; grub-editenv "$GRUBENV" set B_TRY=0 ;;
		*) grub-editenv "$GRUBENV" set A_TRY=0; grub-editenv "$GRUBENV" set B_TRY=0 ;;
	esac
	log "reset try counter for slot '${SLOT:-?}' in $GRUBENV"
done
if [ "$found_any" -eq 1 ]; then
	# Flush to the vfat boot partition so the NEXT boot's grub read sees it.
	sync
else
	log "warn: no grubenv found under /mnt/boot or grub-editenv missing"
fi

log "boot marked good"
exit 0
