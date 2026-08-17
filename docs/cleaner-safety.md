# Writing a disk cleaner that can't do this

The tool that caused this outage was a custom disk cleaner. The failure was not
a bug in a particular line — it was the design: it decided what to delete by
asking whether a volume *looked* important.

## The check that actually works

Every EFI System Partition on every GPT disk carries the same partition type
GUID:

```
C12A7328-F81F-11D2-BA4B-00A0C93EC93B
```

This is defined by the UEFI specification. It is not a heuristic, not
vendor-specific, and not something a user can accidentally change. Any volume
carrying it is a boot partition and must never be cleaned.

**PowerShell**

```powershell
Get-Partition | Where-Object { $_.GptType -ne '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' }
```

**Linux**

```sh
lsblk -o NAME,PARTTYPE   # ESPs show c12a7328-f81f-11d2-ba4b-00a0c93ec93b
```

Add the Microsoft Reserved partition (`E3C9E316-0B5C-4DB8-817D-F92DF00215AE`)
and the Windows Recovery partition (`DE94BBA4-06D1-4D40-A16A-BFD50179D6AC`) to
the same refusal list.

## Heuristics that fail

Each of these was plausible, and each one would have deleted the ESP:

| Heuristic | Why it fails |
|---|---|
| "Skip volumes with a drive letter" | The ESP normally has none. Neither do most system partitions. |
| "Skip NTFS, clean the rest" | The ESP is FAT32. So are most vendor recovery partitions. |
| "Skip anything over 1 GB" | The ESP is 64 MB. Small is not the same as unimportant. |
| "Skip volumes containing `\Windows`" | Correct in isolation, but it does not protect Linux partitions on a dual-boot machine. |
| "Delete files not owned by an installed program" | Nothing on the ESP is owned by an installed program. |

## Structural rules

**Allowlist, never blacklist.** Enumerate the directories you intend to clean —
`%TEMP%`, `%LOCALAPPDATA%\Temp`, browser caches, a named download folder — and
never walk anything else. A blacklist can only block the disasters you already
thought of; this outage was one nobody had thought of.

**Dry-run by default.** Deleting should require an explicit flag. The default
run prints what it would remove and exits zero.

**Refuse to run against the whole disk.** If the target is a drive root rather
than a directory, stop. There is no legitimate cleaning operation whose scope is
"the entire volume".

**Log every deletion before performing it,** to a file outside the cleaning
scope. If this tool had done that, diagnosing this outage would have taken one
minute instead of an afternoon.

**Treat unmounted and unrecognised as dangerous, not disposable.** The instinct
runs the other way — unfamiliar content looks like clutter. On a system disk,
unfamiliar content is usually firmware, recovery, or boot data. Familiar-looking
files are the ones safe to delete.
