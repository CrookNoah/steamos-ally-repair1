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

# Windows' own ESP. Named here so the scripts can refuse to touch it.
WINDOWS_ESP="${WINDOWS_ESP:-${DISK}p1}"

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

# True when this script is running on the installed SteamOS rather than on the
# recovery USB. Repair is a direct call in that case, no chroot needed.
running_on_installed_steamos() {
  [ -e /etc/os-release ] || return 1
  grep -qi 'steamos' /etc/os-release || return 1
  command -v steamcl-install >/dev/null 2>&1 || return 1
  # The recovery image is also SteamOS, but it runs from removable media.
  findmnt -no SOURCE / | grep -q "^${DISK}" || return 1
  return 0
}

# ---------------------------------------------------------------------------
# Device resolution
#
# Partitions are addressed by the GPT labels Valve writes at install time, not
# by number. Numbering shifts with the Windows partitions in front of them, and
# on this machine SteamOS sits at p6-p13 rather than the usual p1-p8.
# ---------------------------------------------------------------------------

# resolve_label <label> -> absolute device path
#
# Refuses to return anything that is not on $DISK. This is the check that stops
# a repair from targeting the recovery USB, which carries the same labels.
resolve_label() {
  local label="$1" dev
  dev="$(readlink -f "/dev/disk/by-partlabel/${label}" 2>/dev/null || true)"

  [ -n "$dev" ] || die "no partition labeled '${label}' — run scripts/10-diagnose.sh"
  [ -b "$dev" ] || die "label '${label}' does not resolve to a block device"

  case "$dev" in
    "${DISK}"p[0-9]*|"${DISK}"[0-9]*) ;;
    *) die "label '${label}' resolves to ${dev}, which is not on ${DISK}.
     That is almost certainly the recovery USB. Refusing to touch it." ;;
  esac

  [ "$dev" != "$WINDOWS_ESP" ] || die "label '${label}' resolves to the Windows ESP. Refusing."

  printf '%s\n' "$dev"
}

label_exists() {
  [ -e "/dev/disk/by-partlabel/$1" ]
}

# ---------------------------------------------------------------------------
# Slot handling
# ---------------------------------------------------------------------------

validate_slot() {
  case "$SLOT" in
    A|B) ;;
    a) SLOT=A ;;
    b) SLOT=B ;;
    *) die "SLOT must be A or B, got '${SLOT}'" ;;
  esac
}

rootfs_label() { printf 'rootfs-%s\n' "$SLOT"; }
efi_label()    { printf 'efi-%s\n' "$SLOT"; }

# Reports the SteamOS build present in a slot, for telling A and B apart.
slot_build_id() {
  local slot="$1" dev tmp id
  label_exists "rootfs-${slot}" || { printf 'absent\n'; return; }
  dev="$(readlink -f "/dev/disk/by-partlabel/rootfs-${slot}")"
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
#
# mount_steamos brings up a chroot-ready tree and registers a cleanup trap so an
# interrupted run never leaves the internal drive mounted.
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

  mountpoint -q "$MNT" && die "${MNT} is already mounted — run: sudo umount -R ${MNT}"

  mkdir -p "$MNT"
  trap cleanup_mounts EXIT INT TERM
  _MOUNTED=1

  log "mounting $(rootfs_label) (${rootfs}) at ${MNT}"
  mount "$rootfs" "$MNT"

  # The guard that makes a wrong slot harmless rather than destructive: if what
  # mounted is not a Linux root, stop before anything gets written.
  [ -d "$MNT/usr" ] || die "${rootfs} is not a Linux root (no /usr).
     Wrong slot? Retry with: SLOT=B $0"

  mkdir -p "$MNT/esp" "$MNT/efi"
  log "mounting esp (${esp}) and $(efi_label) (${efi})"
  mount "$esp" "$MNT/esp"
  mount "$efi" "$MNT/efi"

  for d in dev proc sys run; do
    mount --bind "/$d" "$MNT/$d"
  done

  ok "SteamOS slot ${SLOT} mounted and ready"
}

in_chroot() {
  chroot "$MNT" /bin/bash -c "$1"
}

confirm() {
  local prompt="$1"
  [ "${ASSUME_YES:-0}" = "1" ] && return 0
  [ -t 0 ] || die "not a terminal and ASSUME_YES is unset — refusing to guess"
  printf '%s [y/N] ' "$prompt"
  read -r reply
  case "$reply" in [yY]*) return 0 ;; *) die "cancelled" ;; esac
}
