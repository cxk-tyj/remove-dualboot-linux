# Gotchas: removing a Linux dual-boot from Windows

These are the non-obvious lessons that turned a "simple delete" into a
multi-hour rescue. They are why the bundled scripts verify everything and
hardly trust positional assumptions.

## Principle: verification is the prerequisite, not an afterthought

For any destructive op (delete partition, delete boot entry, overwrite file):
do the read-only check FIRST, fail loudly if it does not pass, and only then
act. Never print "OK" for a command whose exit code was not checked. The
original hand-rolled script printed "OK - Windows Boot Manager set as first
boot option" even though the bcdedit command had silently failed -- that lie
is what nearly bricked the boot.

## Gotcha 1: diskpart partition number != WMI index + 1 (MSR is hidden)

`Win32_DiskPartition` / `Get-Disk` does NOT enumerate the 128 MB Microsoft
Reserved (MSR) partition. So on a typical GPT disk the visible WMI index is
offset by one from diskpart's partition number.

Concretely on the affected machine:
- diskpart showed 6 partitions; WMI reported 5 (the MSR was invisible).
- A script that computed "EFI = WMI index + 1" landed on the WRONG partition.
- Worse: the mismatched "delete target" would have been the E: data volume.

Fix: locate partitions by **GPT type GUID**, not by position. The script
`Get-Partition` numbering DOES match diskpart, so use `Get-Partition` and its
`GptType` property:
- EFI System Partition: `{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}`
- Linux filesystem:     `{0fc63daf-8483-4772-8e79-3d69d8477de4}`

## Gotcha 2: Ubuntu may HIJACK {bootmgr}, not just add an NVRAM entry

Standard advice says "Ubuntu adds its own NVRAM boot entry; just delete
EFI\ubuntu and Windows Boot Manager takes over." On this machine Ubuntu had
OVERWRITTEN the `{bootmgr}` entry's `path` to point at
`\EFI\ubuntu\shimx64.efi`. So deleting EFI\ubuntu left `{bootmgr}` dangling
while it sat first in the firmware boot order -> unbootable.

Fix: always read `bcdedit /enum {bootmgr}` and inspect the `path` line. If it
contains `ubuntu`, rebuild Windows boot files with
`bcdboot C:\Windows /s Z: /f UEFI` and reset the path to
`\EFI\Microsoft\Boot\bootmgfw.efi`, then VERIFY `bootmgfw.efi` exists on the
EFI volume before removing anything.

## Gotcha 3: bcdedit identifiers must be quoted in PowerShell

`bcdedit /set {fwbootmgr} displayorder {bootmgr} /addfirst` fails in
PowerShell because `{...}` is parsed as a script block -> error
"ParameterSpecifiedAlready" / "已指定 command 参数", and the command silently
does nothing while the script may claim success.

Fix: single-quote the identifiers:
`bcdedit /set '{fwbootmgr}' displayorder '{bootmgr}' /addfirst`

## Gotcha 4: the safe order is non-negotiable

1. Backup EFI\ubuntu, repair {bootmgr} if hijacked, remove EFI\ubuntu.
2. REBOOT and confirm Windows boots with NO grub menu.
3. Only then delete the Linux partition.

Skipping step 2 (or doing step 3 first) drops the machine into
`grub rescue>` with no working OS. Step 2 is the verification gate for step 3.

## Gotcha 5: diskpart / bcdedit need elevation the agent does not have

The agent's sandbox cannot run diskpart/bcdedit even with
`dangerouslyDisableSandbox`. Ship the scripts to the user and provide a
self-elevating `.bat` (run-as-admin.bat) so the user double-clicks -> UAC ->
runs as admin. Never assume the agent can execute these live.

## Optional cosmetic cleanup after success

- `{bootmgr}` description may still read "ubuntu" -- harmless. Fix with
  `bcdedit /set '{bootmgr}' description 'Windows Boot Manager'`.
- Delete the `EFI-ubuntu-backup` folder once the new OS is confirmed working.
- Old installer ISOs (e.g. ubuntu-20.04.6-desktop-amd64.iso) can be removed
  if a newer version is used.
