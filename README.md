# steamos-ally-repair1

Repair tooling for a dual-boot **ROG Ally** running Windows and SteamOS on one
NVMe drive, for when SteamOS stops booting because its bootloader is gone.

Written after a custom disk-cleaner emptied the SteamOS EFI System Partition and
put the device into a reboot loop at the ASUS logo. The scripts here are the
repair that fixed it, generalised and given guards.

---

## Is this your problem?

Selecting SteamOS reboots the device **at the vendor logo, before any Steam
logo appears**, while Windows still boots normally.

That means UEFI firmware never found a bootloader to execute. SteamOS itself
never started, so nothing in it crashed — the files that point the firmware at
it are missing. Your OS, your games, and Windows are all still on the disk.

If you reach a Steam logo and *then* reboot, this is the wrong repair — that is
a kernel or filesystem problem, not a bootloader one.

---

## Quick start

Boot the [SteamOS recovery image](https://help.steampowered.com/en/faqs/view/1B71-EDF2-EB6D-2BB3)
from a USB stick, open Konsole, then:

```sh
git clone https://github.com/CrookNoah/steamos-ally-repair1
cd steamos-ally-repair1/scripts
sudo ./00-preflight.sh          # back up the partition table to the USB
sudo ./10-diagnose.sh           # read-only: what is actually broken
sudo ./20-repair-bootloader.sh  # the repair
sudo ./30-verify.sh && sudo reboot
```

Pull the USB as it restarts. Hold **Volume Down** during boot to reach the boot
menu and pick SteamOS.

### No keyboard

On a handheld with no keyboard attached, `fix.sh` is self-contained and does the
repair in one command:

```sh
curl -sL https://raw.githubusercontent.com/CrookNoah/steamos-ally-repair1/main/fix.sh | sudo bash
```

In KDE you can also enable an on-screen keyboard at **System Settings → Input
Devices → Virtual Keyboard**, or long-press a downloaded `fix.sh` in Dolphin and
choose **Run In Konsole**.

---

## What each script does

| Script | Writes? | Purpose |
|---|---|---|
| `00-preflight.sh` | to USB only | Backs up the GPT and records the layout. Restorable with `sgdisk --load-backup`. |
| `10-diagnose.sh` | no | Reports labels, A/B slot builds, ESP contents, Windows ESP health, firmware boot entries. |
| `20-repair-bootloader.sh` | yes | Reinstalls the bootloader. Chroots from recovery media, or runs directly if already booted into SteamOS. |
| `30-verify.sh` | no | Confirms `EFI/steamos` and `steamcl.efi` landed, and that Windows' ESP is intact. Exits non-zero on failure. |
| `40-check-packages.sh` | no | Lists packages with files missing from disk — use when damage may extend past the ESP. |
| `fix.sh` | yes | Standalone one-shot repair with the same guards. For when you cannot type. |

---

## Safety

The repair copies files onto existing filesystems. It does **not** format,
repartition, or erase anything, and it refuses to write to Windows' ESP.

Three guards enforce that:

**Partitions are addressed by GPT label, never by number.** `p6` here is the
SteamOS ESP and `p9` is the root, but that is specific to this machine — the
numbers shift with however many partitions Windows occupies in front of them.
`resolve_label()` reads `/dev/disk/by-partlabel/`.

**Labels that resolve off the internal drive are refused.** The recovery USB
carries the same labels as the installed system. Anything that does not resolve
to `/dev/nvme0n1` is rejected rather than repaired.

**A mounted root without `/usr` aborts the run.** If the wrong slot or the wrong
partition mounts, the script stops before writing. A wrong guess costs an error
message, not a partition.

Set `DISK=` to target a different drive, `SLOT=B` to repair the other A/B slot.

---

## Documentation

- **[docs/partition-layout.md](docs/partition-layout.md)** — the full p1–p13 map, why there are two ESPs, how A/B slots pair up
- **[docs/postmortem.md](docs/postmortem.md)** — what broke, how it was diagnosed, the two wrong turns taken on the way
- **[docs/cleaner-safety.md](docs/cleaner-safety.md)** — how to write a disk cleaner that cannot delete a boot partition

---

## Known limitations

Tested on one machine: a ROG Ally with Windows on `p1`–`p5` and SteamOS on
`p6`–`p13`. The label-based addressing should carry to any SteamOS install
including a stock Steam Deck, but the Windows ESP default (`${DISK}p1`) assumes
Windows was installed first.

The recovery image's own GUI repair is not a substitute — it assumes SteamOS
owns the entire disk and targeted Windows' ESP on this machine. Drive the repair
manually.
