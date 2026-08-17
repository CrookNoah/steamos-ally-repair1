#!/usr/bin/env bash
#
# Back up the GPT before anything else runs.
#
# On a dual-boot machine the partition table is the single point of failure that
# takes both operating systems with it. This writes a restorable copy plus a
# human-readable dump, to removable media rather than the drive being repaired.

set -euo pipefail
cd "$(dirname "$0")"
. lib/common.sh

need_root
need_cmd sgdisk
need_cmd lsblk

OUT="${OUT:-}"

# Default to the first writable removable mount, since writing the backup to the
# disk we might be about to break would be pointless.
if [ -z "$OUT" ]; then
  for candidate in /run/media/*/* /run/media/* /media/*/*; do
    if [ -d "$candidate" ] && [ -w "$candidate" ]; then
      case "$(findmnt -no SOURCE --target "$candidate" 2>/dev/null || true)" in
        "${DISK}"*) continue ;;
      esac
      OUT="$candidate"
      break
    fi
  done
fi

[ -n "$OUT" ] || die "no removable destination found — rerun as: OUT=/path/to/usb $0"
[ -d "$OUT" ] || die "destination is not a directory: ${OUT}"
[ -w "$OUT" ] || die "destination is not writable: ${OUT}"

STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="${OUT}/steamos-repair-${STAMP}"
mkdir -p "$DEST"

log "backing up the partition table of ${DISK}"
sgdisk --backup="${DEST}/gpt.bin" "$DISK" >/dev/null
ok "wrote ${DEST}/gpt.bin"

log "recording the current layout"
{
  printf '# captured %s\n\n' "$STAMP"
  printf '## lsblk\n'
  lsblk -o NAME,SIZE,FSTYPE,PARTLABEL,PARTUUID "$DISK"
  printf '\n## sgdisk --print\n'
  sgdisk --print "$DISK"
  printf '\n## by-partlabel\n'
  ls -l /dev/disk/by-partlabel/ 2>/dev/null || true
} > "${DEST}/layout.txt"
ok "wrote ${DEST}/layout.txt"

cat <<EOF

Backup complete: ${DEST}

To restore this table if a later step damages it:

  sudo sgdisk --load-backup=${DEST}/gpt.bin ${DISK}

Keep the USB stick. Restoring a GPT recovers both SteamOS and Windows;
without it, a damaged table means reinstalling both.
EOF
