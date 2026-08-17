#!/usr/bin/env bash
#
# One-shot SteamOS bootloader repair. Self-contained on purpose.
#
# This file depends on nothing else in the repo so it can be downloaded on its
# own and run from a handheld with no keyboard:
#
#     sudo bash fix.sh
#
# It does the same work as scripts/20-repair-bootloader.sh with the same guards,
# collapsed into a single file. Prefer the numbered scripts when you have a
# working keyboard — they diagnose and verify around the repair.
#
# Safety: copies files onto existing filesystems. Never formats, repartitions,
# or erases. Never touches Windows' ESP.

set -euo pipefail

DISK="${DISK:-/dev/nvme0n1}"
SLOT="${SLOT:-A}"
MNT="${MNT:-/mnt/steamos-repair}"

say()  { printf '\n==> %s\n' "$*"; }
die()  { printf '\nFAILED: %s\n\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run with sudo: sudo bash fix.sh"

case "$SLOT" in A|a) SLOT=A ;; B|b) SLOT=B ;; *) die "SLOT must be A or B" ;; esac

# Resolve a GPT label, refusing anything that is not on the internal drive.
# Without this check the recovery USB's identical labels could be targeted.
resolve() {
  local dev
  dev="$(readlink -f "/dev/disk/by-partlabel/$1" 2>/dev/null || true)"
  [ -b "${dev:-}" ] || die "no partition labeled '$1' on this machine"
  case "$dev" in
    "${DISK}"p[0-9]*|"${DISK}"[0-9]*) ;;
    *) die "label '$1' resolves to $dev, not on $DISK — that is the USB, refusing" ;;
  esac
  printf '%s\n' "$dev"
}

ROOTFS="$(resolve "rootfs-${SLOT}")"
ESP="$(resolve esp)"
EFI="$(resolve "efi-${SLOT}")"

say "slot ${SLOT}"
printf '    rootfs  %s\n    esp     %s\n    efi     %s\n' "$ROOTFS" "$ESP" "$EFI"

mountpoint -q "$MNT" && die "$MNT already mounted — run: sudo umount -R $MNT"
mkdir -p "$MNT"

cleanup() { umount -R "$MNT" 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

say "mounting"
mount "$ROOTFS" "$MNT"

# If this is not a Linux root, stop before writing anything. This is what makes
# a wrong slot harmless instead of destructive.
[ -d "$MNT/usr" ] || die "$ROOTFS is not a Linux root. Wrong slot? Retry: SLOT=B sudo -E bash fix.sh"

mkdir -p "$MNT/esp" "$MNT/efi"
mount "$ESP" "$MNT/esp"
mount "$EFI" "$MNT/efi"
for d in dev proc sys run; do mount --bind "/$d" "$MNT/$d"; done

say "reinstalling the bootloader"
chroot "$MNT" /bin/bash -c 'steamos-readonly disable && steamcl-install'

say "verifying"
[ -d "$MNT/esp/EFI/steamos" ] || die "EFI/steamos still missing — repair did not take"

cleanup
trap - EXIT INT TERM

cat <<'EOF'

=== DONE ===

The SteamOS bootloader is back on the ESP.

  sudo reboot

Pull the USB as it restarts. Hold Volume Down during boot to reach the boot
menu and pick SteamOS.

EOF
