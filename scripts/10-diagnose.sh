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
need_disk

printf '\n'
log "internal disk — ${DISK}"
lsblk -o NAME,SIZE,FSTYPE,PARTLABEL "$DISK"

printf '\n'
log "other block devices (recovery USB, SD card)"
lsblk -o NAME,SIZE,FSTYPE,PARTLABEL,MOUNTPOINT | grep -v "^$(basename "$DISK")" || true

printf '\n'
log "SteamOS partition labels on ${DISK}"
missing=0
for label in esp efi-A efi-B rootfs-A rootfs-B var-A var-B home; do
  if label_exists_on_disk "$label"; then
    dev="$(resolve_label "$label" 2>/dev/null || true)"
    ok "$(printf '%-10s %s' "$label" "${dev:-refused}")"
  else
    warn "$(printf '%-10s not on %s' "$label" "$DISK")"
    missing=1
  fi

  # Duplicate labels elsewhere are the reason this repo does not use
  # /dev/disk/by-partlabel/. Report them so the situation is visible.
  others="$(label_devices_anywhere "$label" | grep -v "^${DISK}" || true)"
  if [ -n "$others" ]; then
    note "also on: $(printf '%s' "$others" | tr '\n' ' ') (ignored — not the install)"
  fi
done

printf '\n'
log "which symlink /dev/disk/by-partlabel/esp points at"
if [ -e /dev/disk/by-partlabel/esp ]; then
  target="$(readlink -f /dev/disk/by-partlabel/esp)"
  case "$target" in
    "${DISK}"p[0-9]*) ok "${target} (on the internal disk)" ;;
    *) warn "${target} — NOT the internal disk"
       note "this is why the scripts scan ${DISK} directly instead" ;;
  esac
else
  note "no such symlink"
fi

printf '\n'
log "A/B slots"
printf '     slot A build: %s\n' "$(slot_build_id A)"
printf '     slot B build: %s\n' "$(slot_build_id B)"
note "the newer build is normally the live slot; pass SLOT=B to target the other"

printf '\n'
log "SteamOS ESP contents (this is what a disk cleaner empties)"
esp_dev="$(resolve_label esp 2>/dev/null || true)"
if [ -n "$esp_dev" ]; then
  tmp="$(mktemp -d)"
  if mount -o ro "$esp_dev" "$tmp" 2>/dev/null; then
    if [ -d "$tmp/EFI/Microsoft" ]; then
      warn "${esp_dev} contains EFI/Microsoft — this is Windows' ESP, not SteamOS's"
      note "the repair would refuse this; check WINDOWS_PARTS and the label layout"
    elif [ -d "$tmp/EFI/steamos" ]; then
      ok "EFI/steamos present on ${esp_dev} — bootloader is installed"
      find "$tmp/EFI/steamos" -maxdepth 1 -type f 2>/dev/null | sed "s|^${tmp}|     |"
    else
      warn "no EFI/steamos on ${esp_dev} — bootloader missing, repair needed"
      [ -d "$tmp/EFI" ] && find "$tmp/EFI" -maxdepth 1 -mindepth 1 | sed "s|^${tmp}|     |"
    fi
    umount "$tmp" 2>/dev/null || true
  else
    warn "could not mount ${esp_dev}"
  fi
  rmdir "$tmp" 2>/dev/null || true
else
  warn "no usable esp partition found on ${DISK}"
  missing=1
fi

printf '\n'
log "Windows partitions — read-only check, never written"
note "protected partition numbers: ${WINDOWS_PARTS}"
for n in $WINDOWS_PARTS; do
  dev="${DISK}p${n}"
  [ -b "$dev" ] || continue
  tmp="$(mktemp -d)"
  if mount -o ro "$dev" "$tmp" 2>/dev/null; then
    if [ -d "$tmp/EFI/Microsoft" ]; then
      ok "${dev} holds EFI/Microsoft — Windows bootloader intact"
    fi
    umount "$tmp" 2>/dev/null || true
  fi
  rmdir "$tmp" 2>/dev/null || true
done

printf '\n'
log "firmware boot entries"
if command -v efibootmgr >/dev/null 2>&1; then
  efibootmgr 2>/dev/null | sed 's/^/     /' || note "efibootmgr failed (not booted via UEFI?)"
else
  note "efibootmgr not available in this environment"
fi

printf '\n'
if [ "$missing" -eq 1 ]; then
  warn "some SteamOS labels are missing from ${DISK} — read the warnings above"
else
  ok "layout looks consistent; safe to run 20-repair-bootloader.sh"
fi
printf '\n'
