#!/usr/bin/env bash
#
# Reinstall the SteamOS bootloader onto the SteamOS ESP.
#
# This is the actual repair. It copies files onto existing filesystems and never
# formats, repartitions, or erases anything. It does not touch Windows' ESP.
#
# Works in both contexts:
#   - booted from the recovery USB  -> mounts the install and chroots into it
#   - booted into SteamOS itself    -> runs directly, no chroot
#
#   sudo ./20-repair-bootloader.sh            repair slot A
#   SLOT=B sudo -E ./20-repair-bootloader.sh  repair slot B
#   ASSUME_YES=1 sudo -E ./20-repair-bootloader.sh   no prompt

set -euo pipefail
cd "$(dirname "$0")"
. lib/common.sh

need_root
validate_slot

if running_on_installed_steamos; then
  log "running on the installed SteamOS — repairing in place, no chroot"
  confirm "Reinstall the bootloader onto the SteamOS ESP?"

  steamos-readonly disable
  steamcl-install
  steamos-readonly enable || warn "could not re-enable readonly; harmless, it returns on reboot"

  ok "bootloader reinstalled"
  printf '\nRun ./30-verify.sh to confirm.\n\n'
  exit 0
fi

log "running from recovery media — will chroot into slot ${SLOT}"

need_cmd chroot
mount_steamos

in_chroot 'command -v steamcl-install >/dev/null 2>&1' \
  || die "steamcl-install not found inside the install.
     The damage goes beyond the ESP. Run: sudo ./40-check-packages.sh"

confirm "Reinstall the bootloader onto the SteamOS ESP from slot ${SLOT}?"

log "disabling readonly"
in_chroot 'steamos-readonly disable'

log "writing the bootloader"
in_chroot 'steamcl-install'

log "restoring readonly"
in_chroot 'steamos-readonly enable' || warn "could not re-enable readonly; it returns on reboot"

cleanup_mounts
trap - EXIT INT TERM

ok "bootloader reinstalled to the SteamOS ESP"

cat <<'EOF'

Next:

  sudo ./30-verify.sh     confirm the files landed
  sudo reboot             then pull the USB

At the boot menu (hold Volume Down during startup) pick SteamOS. Once it
boots, set SteamOS in the BIOS boot order so the menu stops being necessary.

EOF
