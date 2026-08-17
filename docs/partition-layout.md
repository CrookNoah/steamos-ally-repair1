# Partition layout

This machine runs Windows and SteamOS on one NVMe drive, `/dev/nvme0n1`.
SteamOS was installed with
[Josh5/steamos_dual_boot_installer_patch](https://github.com/Josh5/steamos_dual_boot_installer_patch),
which installs into pre-allocated unallocated space and appends Valve's standard
eight-partition set after the existing Windows partitions rather than wiping
them.

## The map

| Partition | Label | Size | Filesystem | Purpose |
|---|---|---|---|---|
| `p1` | — | 100–300 MB | vfat | **Windows ESP.** Not SteamOS's. Nothing in this repo writes here. |
| `p2` | — | 16 MB | — | Microsoft reserved |
| `p3` | — | bulk | ntfs | Windows `C:` |
| `p4`–`p5` | — | varies | ntfs | Windows recovery / vendor partitions |
| `p6` | `esp` | 256 MB | vfat | **SteamOS ESP.** The bootloader lives here. |
| `p7` | `efi-A` | 64 MB | vfat | Slot A EFI |
| `p8` | `efi-B` | 64 MB | vfat | Slot B EFI |
| `p9` | `rootfs-A` | 11 GB | ext4 | Slot A operating system |
| `p10` | `rootfs-B` | 11 GB | ext4 | Slot B operating system |
| `p11` | `var-A` | 1 GB | ext4 | Slot A mutable state |
| `p12` | `var-B` | 1 GB | ext4 | Slot B mutable state |
| `p13` | `home` | remainder | ext4 | Games, settings, user data |

Partitions 1–5 belong to Windows. Partitions 6–13 belong to SteamOS.

Sizes are the installer's documented defaults (`ESP_SIZE=256M`, `EFI_SIZE=64M`,
`ROOT_SIZE=11G`, `VAR_SIZE=1G`); they are not checked by any script here, which
matches on labels alone.

## Why the scripts never use these numbers

The numbers above are correct for this machine and wrong for almost any other,
because they depend on how many partitions Windows happens to occupy in front
of them. A standard Steam Deck has the same eight partitions at `p1`–`p8`.

Every script finds partitions by the labels Valve writes into the GPT at install
time. The numbers in this document are for reading error messages, not for
typing into commands.

## The label collision with the recovery USB

Labels are looked up by scanning `lsblk -rno NAME,PARTLABEL /dev/nvme0n1`, not by
reading `/dev/disk/by-partlabel/`. This matters more than it sounds.

The SteamOS recovery image on the USB stick is itself a SteamOS install, and it
carries partitions with **the same labels** — `esp`, `efi-A`, `rootfs-A`.
`/dev/disk/by-partlabel/` is a flat namespace holding one symlink per label, so
when two devices both claim `esp`, whichever udev enumerated first wins and the
other becomes unreachable through that path.

On a machine booted from the recovery USB, the winner is usually the USB:

```
$ readlink -f /dev/disk/by-partlabel/esp
/dev/sdb1                 # the USB stick, not the install
```

A repair driven off that symlink would write the bootloader onto the recovery
stick and leave the internal disk exactly as broken as before. Scanning the
internal disk directly removes the ambiguity — a device that is not on
`/dev/nvme0n1` is never a candidate.

`scripts/10-diagnose.sh` reports both the scoped result and what the symlink
points at, so the collision is visible rather than surprising.

## Two ESPs

The single most confusing thing about this layout: there are **two** EFI System
Partitions.

- `p1` is Windows'. It holds `EFI/Microsoft`.
- `p6` is SteamOS's. It holds `EFI/steamos`.

`steamcl-install` writes to the SteamOS one. A repair tool that assumes the
first ESP on the disk is the right one will target Windows' by mistake — which
is what the recovery image's GUI repair appeared to do before we switched to
driving it manually.

`resolve_label()` in `scripts/lib/common.sh` refuses to return `p1` for exactly
this reason.

## A/B slots

SteamOS keeps two complete copies of the OS and swaps between them on update, so
a failed update can fall back. `rootfs-A` and `efi-A` are one set; `rootfs-B` and
`efi-B` are the other. When repairing, keep the letters matched — an `A` rootfs
with a `B` EFI is not a valid combination.

`scripts/10-diagnose.sh` prints the SteamOS build ID found in each slot. The
newer build is normally the live one.
