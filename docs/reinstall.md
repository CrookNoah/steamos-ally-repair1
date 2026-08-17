# Reinstalling SteamOS without losing Windows

Last resort. Try `scripts/20-repair-bootloader.sh` first — if the only damage is
a missing bootloader, a reinstall rebuilds several gigabytes to fix four
megabytes, and destroys your games on the way.

Run `scripts/40-check-packages.sh` to decide. Empty output means the install is
complete and a reinstall is not warranted.

## The one rule

**Never use the recovery image's "Reimage Steam Deck", "Reimage SteamOS", or any
option offering to repartition the drive.**

Those assume a Steam Deck where SteamOS owns the whole disk. On this machine
they will rewrite `/dev/nvme0n1` into the standard eight-partition layout, and
Windows on p1–p5 goes with it. This is the failure mode that converts a
bootloader problem into losing both operating systems.

Reinstall with the same tool that did the original install:
[Josh5/steamos_dual_boot_installer_patch](https://github.com/Josh5/steamos_dual_boot_installer_patch).
It installs into unallocated space and explicitly preserves existing partitions.

## Procedure

### 1. Back up the partition table

```sh
sudo ./scripts/00-preflight.sh
```

Writes `gpt.bin` to removable media. If a later step damages the table, this is
what restores Windows. Do not skip it.

### 2. Copy `home` off the machine

The installer needs the SteamOS space to be unallocated, which means deleting
`home` (p13). Your Steam library, saves, and settings live there.

```sh
sudo mkdir -p /mnt/home-backup
sudo mount /dev/disk/by-partlabel/home /mnt/home-backup   # verify it is on nvme first
ls /mnt/home-backup/deck
```

Copy `/mnt/home-backup/deck` to an external drive. Expect this to be large — a
Steam library is usually the biggest thing on the disk. Games can be
redownloaded; save data in `~/.local/share/Steam/userdata` generally cannot if
Steam Cloud was off for that title.

### 3. Confirm which partitions are SteamOS

```sh
lsblk -o NAME,SIZE,FSTYPE,PARTLABEL /dev/nvme0n1
```

The eight carrying SteamOS labels are the ones to remove. Everything else is
Windows. Write the numbers down and check them twice — this is the step where a
mistake is unrecoverable without the backup from step 1.

Expected on this machine:

| Partition | Label |
|---|---|
| p6 | `esp` |
| p7 | `efi-A` |
| p8 | `efi-B` |
| p9 | `rootfs-A` |
| p10 | `rootfs-B` |
| p11 | `var-A` |
| p12 | `var-B` |
| p13 | `home` |

### 4. Return the SteamOS space to unallocated

```sh
sudo sgdisk -d 13 -d 12 -d 11 -d 10 -d 9 -d 8 -d 7 -d 6 /dev/nvme0n1
sudo partprobe /dev/nvme0n1
```

Deleting from highest to lowest avoids renumbering surprises mid-command.

Verify Windows survived before going further:

```sh
lsblk -o NAME,SIZE,FSTYPE,PARTLABEL /dev/nvme0n1
```

p1–p5 must still be listed. If they are not, stop and restore:

```sh
sudo sgdisk --load-backup=/path/to/gpt.bin /dev/nvme0n1
```

### 5. Reinstall

Follow Josh5's instructions. In short:

```sh
sudo TARGET_DISK=/dev/nvme0n1 ./run.sh
```

Its defaults produce the same layout you had: ESP 256M, EFI 64M, root 11G,
var 1G, home taking the remainder.

### 6. Restore `home`

Copy your backed-up `deck` directory back into the new `home` partition, then
fix ownership:

```sh
sudo chown -R 1000:1000 /mnt/new-home/deck
```

## Windows-side prerequisites

Josh5's README requires these before installing. If the original install worked,
they were set once — but a Windows update can revert them, and a reverted
setting looks exactly like a failed install.

- BitLocker / device encryption **off**
- Fast Startup **off**
- Secure Boot **off**
- System clock set to **UTC**

Fast Startup in particular will make a correctly installed SteamOS fail to boot,
because Windows leaves the disk in a hibernated state that Linux cannot safely
mount.
