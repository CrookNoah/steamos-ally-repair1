#!/usr/bin/env bash
#
# Report the state of the install without changing anything.
#
# Read-only. Run this first, and run it again after a repair. Everything it
# prints is something the repair depends on being true.

set -euo pipefail
cd "$(dirname "$0")"
. lib/common.sh

need_root
need_cmd lsblk

printf '\n'
log "disk layout — ${DISK}"
lsblk -o NAME,SIZE,FSTYPE,PARTLABEL "$DISK"

printf '\n'
log "partition labels"
missing=0
for label in esp efi-A efi-B rootfs-A rootfs-B var-A var-B home; do
  if label_exists "$label"; then
    dev="$(readlink -f "/dev/disk/by-partlabel/${label}")"
    case "$dev" in
      "${DISK}"p[0-9]*|"${DISK}"[0-9]*)
        ok "$(printf '%-10s %s' "$label" "$dev")" ;;
      *)
        warn "$(printf '%-10s %s  <- NOT on %s, would be refused' "$label" "$dev" "$DISK")"
        missing=1 ;;
    esac
  else
    warn "$(printf '%-10s absent' "$label")"
    missing=1
  fi
done

printf '\n'
log "A/B slots"
printf '     slot A build: %s\n' "$(slot_build_id A)"
printf '     slot B build: %s\n' "$(slot_build_id B)"
note "the newer build is normally the live slot; pass SLOT=B to target the other"

printf '\n'
log "SteamOS ESP contents (this is what a disk cleaner empties)"
if label_exists esp; then
  esp_dev="$(resolve_label esp)"
  tmp="$(mktemp -d)"
  if mount -o ro "$esp_dev" "$tmp" 2>/dev/null; then
    if [ -d "$tmp/EFI" ]; then
      find "$tmp/EFI" -maxdepth 2 -mindepth 1 | sed "s|^${tmp}|     |"
      if [ -d "$tmp/EFI/steamos" ]; then
        ok "steamos bootloader present"
      else
        warn "no EFI/steamos directory — bootloader missing, repair needed"
      fi
    else
      warn "no EFI directory at all — this ESP has been emptied"
    fi
    umount "$tmp" 2>/dev/null || true
  else
    warn "could not mount ${esp_dev}"
  fi
  rmdir "$tmp" 2>/dev/null || true
fi

printf '\n'
log "Windows ESP (${WINDOWS_ESP}) — must be left intact"
tmp="$(mktemp -d)"
if mount -o ro "$WINDOWS_ESP" "$tmp" 2>/dev/null; then
  if [ -d "$tmp/EFI/Microsoft" ]; then
    ok "EFI/Microsoft present — Windows will still boot"
  else
    warn "EFI/Microsoft missing — Windows bootloader is gone."
    note "recover with Windows install media: bootrec /rebuildbcd"
  fi
  umount "$tmp" 2>/dev/null || true
else
  warn "could not mount ${WINDOWS_ESP} (may not be an ESP on this machine)"
fi
rmdir "$tmp" 2>/dev/null || true

printf '\n'
log "firmware boot entries"
if command -v efibootmgr >/dev/null 2>&1; then
  efibootmgr | sed 's/^/     /'
else
  note "efibootmgr not available in this environment"
fi

printf '\n'
if [ "$missing" -eq 1 ]; then
  warn "some labels are missing or off-disk — read the warnings above before repairing"
else
  ok "layout looks consistent; safe to run 20-repair-bootloader.sh"
fi
printf '\n'
