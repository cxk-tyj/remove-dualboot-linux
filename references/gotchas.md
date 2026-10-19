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

## Gotcha 6: never use Start-Transcript on the same log file as Out-File

A script that both calls `Start-Transcript -Path $LogFile` AND writes to the
same `$LogFile` via `Out-File -Append` (e.g. inside a `Say` helper) will fail
with "The process cannot access the file because it is being used by another
process" on the very first `Say`. With `$ErrorActionPreference='Stop'` this
aborts the whole script before it does anything -- the disk is left untouched
(safe), but the user gets a confusing error and the op never runs.

Fix: pick ONE logging mechanism. Here we drop `Start-Transcript` entirely and
let the `Say` helper own the log: it writes each line with `Out-File -Append`,
and the script resets the file once at startup with a plain `Out-File` (no
`-Append`) so each run starts clean. The `.log` file is then the single source
of truth for what actually happened.

## Optional cosmetic cleanup after success

- `{bootmgr}` description may still read "ubuntu" -- harmless. Fix with
  `bcdedit /set '{bootmgr}' description 'Windows Boot Manager'`.
- Delete the `EFI-ubuntu-backup` folder once the new OS is confirmed working.
- Old installer ISOs (e.g. ubuntu-20.04.6-desktop-amd64.iso) can be removed
  if a newer version is used.

---

# Gotchas: making GRUB appear / managing BootOrder after a Linux reinstall

The above is about *removing* Linux. The inverse problem — a freshly
reinstalled/grub-repaired Linux still boots straight to Windows with no GRUB
menu, and the BIOS "Boot Option" list only shows Windows — hit the same machine
and took many wasted hours. Lessons below; verification-first still applies.

## Gotcha 7: "everything exists" does not mean GRUB will show

After `grub-install --target=x86_64-efi ...` (or a reinstall), the machine may
still boot straight to Windows even though `EFI/ubuntu/shimx64.efi` is present
and a Linux NVRAM entry exists (F7/F12 one-time menu can still reach GRUB,
proving the files are fine). The real cause is almost always that the Linux
entry is **not in the firmware BootOrder** (the automatic sequence), or the
firmware refuses to honor a reordered BootOrder.

Read the truth before acting:
- Windows side (admin PowerShell): `bcdedit /enum firmware` → inspect the
  `displayorder` block under `{fwbootmgr}`.
- Linux side: `sudo efibootmgr` → read `BootOrder:` and the `Boot####` list.
- If the Linux entry exists but is not first in BootOrder, that is the bug.
  Do not assume reinstalling fixed it.

## Gotcha 8: Windows will not stay second — it self-promotes every cold boot

On this AMI/Windows machine, `bcdedit /set {fwbootmgr} displayorder ...` from
Windows did **not** stick: every cold boot, Windows Boot Manager re-inserted
itself at position 1, and Windows even **recreated** NVRAM entries we had
deleted. So:
- Do not rely on Windows `bcdedit` to demote Windows. Asking Windows to sort
  itself last is "asking the thief to lock the door."
- The AMI "Boot Option Priorities" dropdown folds per disk: it shows only the
  top BootOrder item, labelled by its description (usually "Windows Boot
  Manager"), so the Linux entry "disappears" from the list even when present.
  Find the full list in the **Hard Disk Drive BBS Priorities** (or "UEFI Hard
  Disk BBS Priorities") submenu. Also disable the firmware **Fast Boot** option
  — it skips full UEFI enumeration and hides extra entries / forces Windows
  first.
- The Control Panel "fast startup" toggle may be entirely **absent** on some
  machines (e.g. desktops); that is fine — it is the firmware Fast Boot that
  matters here, not the Windows one.

## Gotcha 9: the reliable fix — fallback file + delete the Windows NVRAM entry

Reordering alone is not enough on a firmware that re-sorts. Make the disk boot
GRUB by default:

1. From Linux, copy the signed shim into the disk's fallback path (this is the
   whole step — `cp` succeeding is success; it is silent):
   ```bash
   sudo mkdir -p /boot/efi/EFI/BOOT
   sudo cp /boot/efi/EFI/ubuntu/shimx64.efi /boot/efi/EFI/BOOT/bootx64.efi
   sudo cp /boot/efi/EFI/ubuntu/grubx64.efi /boot/efi/EFI/BOOT/grubx64.efi
   ```
   The firmware, when it falls back to the disk default, now loads shim → GRUB.
   This is independent of BootOrder.
2. Remove Windows' own NVRAM entry so the fallback is the only bootable path:
   ```bash
   sudo efibootmgr                 # find `BootXXXX* Windows Boot Manager`
   sudo efibootmgr -b XXXX -B      # delete it (XXXX = that number)
   sudo efibootmgr -o YYYY         # set BootOrder to the ubuntu entry only
   ```
   After this, a cold boot has no Windows entry to prefer → it boots GRUB.
   **Windows is still reachable** from the GRUB menu (see Gotcha 10), so nothing
   is lost.
3. Caveat: Windows self-heals its NVRAM entry when launched from GRUB, and may
   occasionally re-promote. If it ever boots straight to Windows again, repeat
   the delete, or keep firmware Fast Boot disabled. This is repeatable, not
   destructive.

Note: `efibootmgr` uses numeric `-b XXXX` flags (no braces); the `{}`-must-be-
quoted rule (Gotcha 3) is only for Windows `bcdedit` in PowerShell.

## Gotcha 10: modern Ubuntu hides other OSes in GRUB by default

If GRUB appears but the Windows entry is missing, it is not a boot failure —
`os-prober` is disabled by default on recent Ubuntu. The line
`GRUB_DISABLE_OS_PROBER` is often **absent** from `/etc/default/grub` (that is
normal, not an error — do not grep for it expecting it to exist). Add it
explicitly, then regenerate:
```bash
grep -q '^GRUB_DISABLE_OS_PROBER=' /etc/default/grub && \
  sudo sed -i 's/^GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub || \
  echo 'GRUB_DISABLE_OS_PROBER=false' | sudo tee -a /etc/default/grub
sudo update-grub
```
Confirm the output contains `Found Windows Boot Manager`. If not,
`sudo apt install os-prober` and re-run `update-grub`.

## Gotcha 11: judge boot success by actual boot, not the BIOS dropdown

The AMI dropdown label is cosmetic and caches the "Windows Boot Manager"
string. After changing BootOrder/fallback, **reboot and watch whether GRUB
actually appears** — that is the only real test. The BIOS list showing only
Windows does not mean the change failed.
