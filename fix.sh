#!/usr/bin/env bash
#
# One-shot SteamOS bootloader repair. Self-contained on purpose.
#
# This file depends on nothing else in the repo so it can be downloaded on its
# own and run from a handheld with no keyboard:
#
#     sudo bash fix.sh
#     SLOT=B sudo -E bash fix.sh     # if slot A is not the live one
#
# It repairs SteamOS only. It does not read, mount, or write any Windows
# partition, and it will abort rather than touch one.
#
# Safety: copies files onto existing filesystems. Never formats, repartitions,
# or erases anything.

set -euo pipefail

DISK="${DISK:-/dev/nvme0n1}"
SLOT="${SLOT:-A}"
MNT="${MNT:-/mnt/steamos-repair}"

# Partition numbers on $DISK belonging to Windows. Never touched.
WINDOWS_PARTS="${WINDOWS_PARTS:-1 2 3 4 5}"

say() { printf '\n==> %s\n' "$*"; }
die() { printf '\nFAILED: %s\n\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run with sudo: sudo bash fix.sh"
[ -b "$DISK" ] || die "no such disk: $DISK"

case "$SLOT" in A|a) SLOT=A ;; B|b) SLOT=B ;; *) die "SLOT must be A or B" ;; esac

# Find a partition by GPT label, scanning $DISK only.
#
# Deliberately NOT /dev/disk/by-partlabel/ — that is a flat namespace with one
# symlink per label, and the SteamOS recovery USB carries the same labels as the
# internal install ('esp', 'efi-A', ...). Whichever device udev saw first owns
# the symlink, which on a machine booted from recovery media is the USB.
# Scanning $DISK makes targeting the wrong device impossible.
resolve() {
  local want="$1" name lbl matches='' n

  while read -r name lbl; do
    [ -n "${lbl:-}" ] || continue
    [ "$lbl" = "$want" ] || continue
    matches="${matches}/dev/${name} "
  done <<EOF
$(lsblk -rno NAME,PARTLABEL "$DISK" 2>/dev/null)
EOF

  # shellcheck disable=SC2086
  set -- $matches
  [ $# -ne 0 ] || die "no partition labeled '$want' on $DISK
        see what is there with:  lsblk -o NAME,SIZE,FSTYPE,PARTLABEL $DISK"
  [ $# -eq 1 ] || die "$DISK has multiple partitions labeled '$want': $*"

  for n in $WINDOWS_PARTS; do
    [ "$1" != "${DISK}p${n}" ] || die "$1 is a Windows partition. Refusing."
  done

  printf '%s\n' "$1"
}

ROOTFS="$(resolve "rootfs-${SLOT}")"
ESP="$(resolve esp)"
EFI="$(resolve "efi-${SLOT}")"

say "slot ${SLOT} on ${DISK}"
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

# Content backstop: an ESP holding EFI/Microsoft is Windows', whatever its label
# or number says. Catches the case where every assumption above was wrong.
[ ! -d "$MNT/esp/EFI/Microsoft" ] || die "$ESP contains EFI/Microsoft — that is Windows' boot partition. Refusing."

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

The SteamOS bootloader is back on the SteamOS ESP. Windows was not touched.

  sudo reboot

Pull the USB as it restarts. Hold Volume Down during boot to reach the boot
menu and pick SteamOS.

EOF
