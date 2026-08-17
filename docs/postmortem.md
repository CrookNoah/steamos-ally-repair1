# Postmortem: the reboot loop

## Symptom

Selecting SteamOS from the boot menu rebooted the device at the ASUS logo. It
never reached a Steam logo, never showed a kernel message, never reached a
console. Windows booted normally.

## Diagnosis

The stage the failure happens at localises it precisely:

| Failure point | Meaning |
|---|---|
| Reboots at vendor logo, no Steam logo | Firmware never loaded a bootloader — ESP problem |
| Steam logo then reboot | Kernel or root filesystem problem |
| "Steam is updating" then reboot | Failed A/B update, stale slot |

The first row matched. That rules out SteamOS itself: the OS never started, so
nothing in it could have crashed. The failure was that UEFI firmware could not
find anything to execute.

## Cause

A home-built disk cleaner had been run on the machine. It emptied the SteamOS
ESP (`p6`) — roughly 4 MB of bootloader files, including `EFI/steamos/` and
`steamcl.efi`.

The ESP is a near-perfect false positive for a naive cleaner:

- FAT32, while every other partition on a Windows machine is NTFS
- 64 MB, small enough to look like leftover scratch space
- no `\Windows` directory, no program files, no recognisable application data
- usually no drive letter, so it looks unmounted or orphaned

Any heuristic along the lines of "delete what isn't recognised" classifies it as
junk. Nothing about it looks load-bearing until the machine won't boot.

## What was actually lost

Only the loader. The SteamOS install on `rootfs-A`/`rootfs-B`, the user data on
`home`, and the entire Windows installation were untouched. The repair was to
rewrite the loader with `steamcl-install`; total data recovered from backup: none
needed.

## Missteps worth recording

**The recovery image's GUI repair targeted `p1`.** That is Windows' ESP, not
SteamOS's. The wizard assumes a Steam Deck where SteamOS owns the whole disk and
its ESP is first on the drive. On a dual-boot machine that assumption is wrong.
Driving the repair manually, addressing partitions by label, avoided it.

**An early attempt assumed `p6` was the root filesystem.** It is the ESP; the
root is `p9`. The command carried a `test -d /mnt/usr` guard, which aborted
before anything was written. That guard is now in `resolve_label()` and in
`fix.sh` permanently — a wrong guess should cost an error message, not a
partition.

## Preventing a repeat

See [cleaner-safety.md](cleaner-safety.md). The short version: identify the ESP
by its GPT partition type GUID, not by heuristics about what its contents look
like.
