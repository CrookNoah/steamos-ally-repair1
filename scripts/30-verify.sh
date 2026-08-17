#!/usr/bin/env bash
#
# Confirm the repair landed. Read-only.
#
# Exits non-zero if the SteamOS bootloader is still missing, so it can gate a
# reboot: sudo ./30-verify.sh && sudo reboot

set -euo pipefail
cd "$(dirname "$0")"
. lib/common.sh

need_root

fail=0

printf '\n'
log "checking the SteamOS ESP"
esp_dev="$(resolve_label esp)"
tmp="$(mktemp -d)"
trap 'umount "$tmp" 2>/dev/null || true; rmdir "$tmp" 2>/dev/null || true' EXIT

mount -o ro "$esp_dev" "$tmp" || die "could not mount ${esp_dev}"

if [ -d "$tmp/EFI/steamos" ]; then
  ok "EFI/steamos present on ${esp_dev}"
  find "$tmp/EFI/steamos" -maxdepth 1 -type f | sed "s|^${tmp}|     |"
else
  warn "EFI/steamos still missing — the repair did not take"
  fail=1
fi

if find "$tmp" -iname 'steamcl.efi' -print -quit | grep -q .; then
  ok "steamcl.efi found"
else
  warn "steamcl.efi not found on the ESP"
  fail=1
fi

umount "$tmp" 2>/dev/null || true

printf '\n'
log "checking Windows was left alone"
if mount -o ro "$WINDOWS_ESP" "$tmp" 2>/dev/null; then
  if [ -d "$tmp/EFI/Microsoft" ]; then
    ok "EFI/Microsoft intact on ${WINDOWS_ESP}"
  else
    warn "EFI/Microsoft missing from ${WINDOWS_ESP}"
    note "recover with Windows install media: bootrec /rebuildbcd"
    fail=1
  fi
  umount "$tmp" 2>/dev/null || true
else
  note "could not mount ${WINDOWS_ESP}; skipping"
fi

printf '\n'
if [ "$fail" -eq 0 ]; then
  ok "verification passed — safe to reboot"
  printf '\n     sudo reboot    (then pull the USB)\n\n'
else
  die "verification failed — do not reboot expecting it to work"
fi
