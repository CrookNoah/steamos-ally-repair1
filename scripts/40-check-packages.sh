#!/usr/bin/env bash
#
# List packages with files missing from disk.
#
# Run this when you suspect a disk cleaner reached past the ESP into the SteamOS
# root. No output means nothing else was touched. Read-only.

set -euo pipefail
cd "$(dirname "$0")"
. lib/common.sh

need_root
validate_slot

check='pacman -Qkk 2>&1 | grep -v ": 0 missing files" || true'

if running_on_installed_steamos; then
  log "checking the running system"
  eval "$check"
else
  log "checking slot ${SLOT}"
  mount_steamos
  in_chroot "$check"
fi

printf '\n'
note "empty output above means every package is complete"
note "to reinstall a damaged package: sudo pacman -S --overwrite '*' <name>"
printf '\n'
