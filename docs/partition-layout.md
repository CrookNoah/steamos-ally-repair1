# Partition layout

This machine runs Windows and SteamOS on one NVMe drive, `/dev/nvme0n1`.
SteamOS was installed with a custom script that produced Valve's standard
eight-partition set, placed after the Windows partitions.

## The map

| Partition | Label | Approx. size | Filesystem | Purpose |
|---|---|---|---|---|
| `p1` | — | 100–300 MB | vfat | **Windows ESP.** Not SteamOS's. Nothing in this repo writes here. |
| `p2` | — | 16 MB | — | Microsoft reserved |
| `p3` | — | bulk | ntfs | Windows `C:` |
| `p4`–`p5` | — | varies | ntfs | Windows recovery / vendor partitions |
| `p6` | `esp` | 64 MB | vfat | **SteamOS ESP.** The bootloader lives here. |
| `p7` | `efi-A` | 32 MB | vfat | Slot A EFI |
| `p8` | `efi-B` | 32 MB | vfat | Slot B EFI |
| `p9` | `rootfs-A` | 5 GB | ext4 | Slot A operating system |
| `p10` | `rootfs-B` | 5 GB | ext4 | Slot B operating system |
| `p11` | `var-A` | 256 MB | ext4 | Slot A mutable state |
| `p12` | `var-B` | 256 MB | ext4 | Slot B mutable state |
| `p13` | `home` | remainder | ext4 | Games, settings, user data |

Partitions 1–5 belong to Windows. Partitions 6–13 belong to SteamOS.

## Why the scripts never use these numbers

The numbers above are correct for this machine and wrong for almost any other,
because they depend on how many partitions Windows happens to occupy in front
of them. A standard Steam Deck has the same eight partitions at `p1`–`p8`.

Every script resolves partitions through `/dev/disk/by-partlabel/`, reading the
labels Valve writes into the GPT at install time. The numbers in this document
are for reading error messages, not for typing into commands.

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
