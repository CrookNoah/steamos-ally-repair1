#!/usr/bin/env bash
#
# Shared helpers for the SteamOS repair scripts.
#
# This file owns device resolution, mounting, and the safety checks that keep
# the tooling off Windows' partitions and off the recovery USB. Every script
# sources it rather than reimplementing any of that.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration. Override any of these from the environment.
# ---------------------------------------------------------------------------

# The internal drive holding both operating systems.
DISK="${DISK:-/dev/nvme0n1}"

# Where the SteamOS root gets mounted while we work on it.
MNT="${MNT:-/mnt/steamos-repair}"

# Which A/B slot to repair.
SLOT="${SLOT:-A}"

# Partition numbers on $DISK that belong to Windows. Nothing here will ever be
# mounted, written to, or passed to steamcl-install. On this machine Windows
# holds 1-5 and SteamOS holds 6-13.
WINDOWS_PARTS="${WINDOWS_PARTS:-1 2 3 4 5}"

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_CYAN=$'\033[36m'
else
  C_RESET='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_CYAN=''
fi

log()  { printf '%s==>%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%swarn%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
note() { printf '%s     %s%s\n' "$C_DIM" "$*" "$C_RESET"; }
die()  { printf '%sfail%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------

need_root() {
  [ "$(id -u)" -eq 0 ] || die "needs root — rerun with sudo"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

need_disk() {
  [ -b "$DISK" ] || die "no such disk: ${DISK}
     list what this machine has with: lsblk -d -o NAME,SIZE,MODEL"
}

# True when running on the installed SteamOS rather than on the recovery USB.
# Repair is then a direct call, no chroot needed.
running_on_installed_steamos() {
  [ -e /etc/os-release ] || return 1
  grep -qi 'steamos' /etc/os-release || return 1
  command -v steamcl-install >/dev/null 2>&1 || return 1
  # The recovery image is also SteamOS, but it runs from removable media.
  findmnt -no SOURCE / 2>/dev/null | grep -q "^${DISK}" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# Device resolution
#
# Partitions are found by the GPT labels Valve writes at install time, but the
# lookup is scoped to $DISK rather than read from /dev/disk/by-partlabel/.
#
# That directory is a flat namespace with one symlink per label. The SteamOS
# recovery USB carries partitions labeled 'esp', 'efi-A' and so on, exactly like
# the internal install, so whichever device udev saw first owns the symlink and
# the other is unreachable through it. On a machine booted from recovery media,
# the symlink usually points at the USB.
#
# Scanning $DISK directly makes the collision structurally impossible: a device
# that is not on $DISK is never a candidate in the first place.
# ---------------------------------------------------------------------------

# resolve_label <label> -> absolute device path on $DISK
resolve_label() {
  local want="$1" name lbl matches=''

  while read -r name lbl; do
    [ -n "${lbl:-}" ] || continue
    [ "$lbl" = "$want" ] || continue
    matches="${matches}/dev/${name} "
  done <<EOF
$(lsblk -rno NAME,PARTLABEL "$DISK" 2>/dev/null)
EOF

  # shellcheck disable=SC2086
  set -- $matches
  case $# in
    0) die "no partition labeled '${want}' on ${DISK}
     Run scripts/10-diagnose.sh to see what labels this disk actually has.
     If the label exists on another device, that device is not the install." ;;
    1) ;;
    *) die "${DISK} has more than one partition labeled '${want}': $*
     Refusing to guess which is correct." ;;
  esac

  assert_not_windows "$1"
  printf '%s\n' "$1"
}

# Refuse any partition belonging to Windows, by number.
assert_not_windows() {
  local dev="$1" n
  for n in $WINDOWS_PARTS; do
    if [ "$dev" = "${DISK}p${n}" ] || [ "$dev" = "${DISK}${n}" ]; then
      die "${dev} is a Windows partition (WINDOWS_PARTS='${WINDOWS_PARTS}'). Refusing."
    fi
  done
}

# Content-based backstop: an ESP holding EFI/Microsoft is Windows', whatever it
# is labeled and whatever number it carries. Checked before anything is written.
assert_not_windows_esp() {
  local mountpoint="$1"
  if [ -d "${mountpoint}/EFI/Microsoft" ]; then
    die "the partition mounted at ${mountpoint} contains EFI/Microsoft.
     That is Windows' boot partition, not SteamOS's. Refusing to write to it."
  fi
}

label_devices_anywhere() {
  local want="$1" name lbl
  while read -r name lbl; do
    [ -n "${lbl:-}" ] || continue
    [ "$lbl" = "$want" ] || continue
    printf '/dev/%s\n' "$name"
  done <<EOF
$(lsblk -rno NAME,PARTLABEL 2>/dev/null)
EOF
}

label_exists_on_disk() {
  local want="$1" name lbl
  while read -r name lbl; do
    [ "${lbl:-}" = "$want" ] && return 0
  done <<EOF
$(lsblk -rno NAME,PARTLABEL "$DISK" 2>/dev/null)
EOF
  return 1
}

# ---------------------------------------------------------------------------
# Slot handling
# ---------------------------------------------------------------------------

validate_slot() {
  case "$SLOT" in
    A|a) SLOT=A ;;
    B|b) SLOT=B ;;
    *) die "SLOT must be A or B, got '${SLOT}'" ;;
  esac
}

rootfs_label() { printf 'rootfs-%s\n' "$SLOT"; }
efi_label()    { printf 'efi-%s\n' "$SLOT"; }

# Reports the SteamOS build present in a slot, for telling A and B apart.
slot_build_id() {
  local slot="$1" dev tmp id=''
  dev="$(SLOT="$slot"; resolve_label "rootfs-${slot}" 2>/dev/null || true)"
  [ -n "$dev" ] || { printf 'absent\n'; return; }
  tmp="$(mktemp -d)"
  if mount -o ro "$dev" "$tmp" 2>/dev/null; then
    id="$(sed -n 's/^BUILD_ID=//p' "$tmp/etc/os-release" 2>/dev/null | tr -d '"')"
    umount "$tmp" 2>/dev/null || true
  fi
  rmdir "$tmp" 2>/dev/null || true
  printf '%s\n' "${id:-unknown}"
}

# ---------------------------------------------------------------------------
# Mounting
# ---------------------------------------------------------------------------

_MOUNTED=0

cleanup_mounts() {
  [ "$_MOUNTED" -eq 1 ] || return 0
  _MOUNTED=0
  umount -R "$MNT" 2>/dev/null || true
  rmdir "$MNT" 2>/dev/null || true
}

mount_steamos() {
  local rootfs esp efi d

  rootfs="$(resolve_label "$(rootfs_label)")"
  esp="$(resolve_label esp)"
  efi="$(resolve_label "$(efi_label)")"

  log "resolved on ${DISK}"
  note "rootfs  ${rootfs}"
  note "esp     ${esp}"
  note "efi     ${efi}"

  mountpoint -q "$MNT" && die "${MNT} is already mounted — run: sudo umount -R ${MNT}"

  mkdir -p "$MNT"
  trap cleanup_mounts EXIT INT TERM
  _MOUNTED=1

  mount "$rootfs" "$MNT"

  # If what mounted is not a Linux root, stop before anything is written. This
  # is what makes a wrong slot harmless rather than destructive.
  [ -d "$MNT/usr" ] || die "${rootfs} is not a Linux root (no /usr).
     Wrong slot? Retry with: SLOT=B sudo -E $0"

  mkdir -p "$MNT/esp" "$MNT/efi"
  mount "$esp" "$MNT/esp"

  # Backstop against every earlier assumption being wrong at once.
  assert_not_windows_esp "$MNT/esp"

  mount "$efi" "$MNT/efi"

  for d in dev proc sys run; do
    mount --bind "/$d" "$MNT/$d"
  done

  ok "SteamOS slot ${SLOT} mounted, Windows untouched"
}

in_chroot() {
  chroot "$MNT" /bin/bash -c "$1"
}

confirm() {
  local prompt="$1" reply
  [ "${ASSUME_YES:-0}" = "1" ] && return 0
  [ -t 0 ] || die "not a terminal and ASSUME_YES is unset — refusing to guess"
  printf '%s [y/N] ' "$prompt"
  read -r reply
  case "$reply" in [yY]*) return 0 ;; *) die "cancelled" ;; esac
}
