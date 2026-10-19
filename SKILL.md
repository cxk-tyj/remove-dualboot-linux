---
name: remove-dualboot-linux
description: Safely remove a Linux (e.g. Ubuntu) dual-boot partition from a Windows UEFI machine, without bricking the boot. Use when the user wants to delete dual-boot Linux, free its disk space, or replace Linux with a newer distro. Triggers: "删除双系统", "卸载 Ubuntu", "删掉 Linux 分区", "remove dual boot", "uninstall Ubuntu", "清理 grub". This skill is also a reference pattern for ANY destructive disk/boot operation — verification must precede action.
---

# Remove Dual-Boot Linux (safely)

## Overview

Remove a Linux dual-boot (Ubuntu/Fedora/etc.) from a Windows UEFI/GPT machine
and hand boot control back to Windows — **without turning the PC into an
unbootable `grub rescue>` brick**.

The dangerous part is not deleting the partition; it is the **boot order**.
Linux installers either (a) add their own NVRAM entry or, sneakier, (b)
**hijack the Windows `{bootmgr}` entry's `path`** to point at their own
`shimx64.efi`. If you delete the Linux partition (or its EFI folder) before
Windows can boot on its own, the machine dies.

**Core principle — verification is the prerequisite, never an afterthought:**
every destructive step is gated by a read-only check that must pass first, and
no command is reported as "OK" unless its exit code was actually checked.

## When to use

- User wants to delete dual-boot Linux, free its disk, or replace it with a new distro.
- Also use the bundled scripts as a **template pattern** for any destructive
  disk/boot task (partition delete, boot entry delete, file overwrite): the
  verify-before-act discipline transfers directly.

## What it is NOT for

- WSL distros → use `wsl --unregister`.
- Linux inside a VM → delete the VM, not the disk.
- A pure "resize/merge partition" request with no Linux involved.

## Workflow (strict order — never skip or reorder)

```
[diagnose.ps1]  read-only: confirm physical dual-boot, find EFI & Linux by GUID,
                check if {bootmgr} is hijacked
        │
        ▼
[hand-back-boot.ps1]  backup EFI\ubuntu → repair {bootmgr} if hijacked →
                      delete EFI\ubuntu → clean NVRAM → unmount   (reversible)
        │
        ▼
[REBOOT]  ★ MANDATORY GATE ★  Windows must boot directly with NO grub menu.
          If grub rescue / menu still appears → STOP, do not proceed.
        │
        ▼
[delete-partition.ps1]  multi-gate + typed-confirmation delete of the Linux
                        partition (150GB etc.) → leaves Unallocated for reuse
```

### Step 1 — Diagnose (read-only, no admin needed)

```
powershell -ExecutionPolicy Bypass -File scripts/diagnose.ps1
```
Tells you: is it physical dual-boot / WSL / VM? Where is the EFI partition
(100MB) and the Linux partition, **located by GPT GUID, not by index**? Is
`{bootmgr}` hijacked to `\EFI\ubuntu\shimx64.efi`?

### Step 2 — Hand boot control back (must be admin)

```
scripts/run-as-admin.bat scripts/hand-back-boot.ps1
```
Double-click → UAC "Yes". The script:
1. Finds EFI by GUID; mounts it; **verifies `Z:\EFI` exists** before touching.
2. **Backs up** `EFI\ubuntu` via robocopy and verifies file count > 0.
3. Reads `{bootmgr}`; if hijacked, runs `bcdboot` + resets path, then **verifies
   `bootmgfw.efi` exists on the EFI volume**.
4. Deletes `EFI\ubuntu` only after the backup is confirmed.
5. Deletes stale NVRAM entries pointing at `\EFI\ubuntu`.
Every gate that fails stops the script with `FAIL` — it never lies "OK".

### Step 3 — Reboot and verify (the critical gate)

Reboot. **Expect: straight into Windows, no grub menu.** This proves Windows
can boot on its own. Only now is it safe to delete the partition. If anything
looks wrong, the backup lives in `scripts/EFI-ubuntu-backup/`.

### Step 4 — Delete the Linux partition (must be admin)

```
scripts/run-as-admin.bat scripts/delete-partition.ps1
```
Gates, in order:
- Target identified by **GPT GUID** (Linux filesystem), not by position.
- Target must have **no drive letter** and Type **not `Basic`** (Windows data
  volumes always have a letter / are Basic).
- Operator must **type the detected capacity** (e.g. `150`) to proceed.
- Operator must **type `DELETE`** (all caps) before anything moves.
After delete, it re-reads the table to confirm the Linux partition is gone.
Freed space shows as **Unallocated** in diskmgmt.msc — leave it for the new OS.

## Resources

### scripts/
- `diagnose.ps1` — read-only reconnaissance (WSL vs dual-boot, GUID-based
  partition location, `{bootmgr}` hijack check).
- `hand-back-boot.ps1` — backup EFI + repair hijacked `{bootmgr}` + remove GRUB
  + clean NVRAM. Reversible, verification-gated.
- `delete-partition.ps1` — multi-gate, typed-confirmation delete of the Linux
  partition only.
- `run-as-admin.bat <script.ps1>` — self-elevating launcher; double-click → UAC.

### references/
- `gotchas.md` — the hard-won lessons that shaped this skill: why verification
  must precede action, the diskpart-vs-WMI partition-number offset (MSR is
  hidden), Ubuntu hijacking `{bootmgr}`, bcdedit quoting in PowerShell, the
  non-negotiable reboot gate, that the agent cannot run diskpart itself, **and
  (added later) the boot-order / GRUB-visibility war after a Linux reinstall**:
  Windows self-promoting to BootOrder #1 every cold boot, AMI Boot-Option
  dropdown folding per disk, firmware Fast Boot hiding entries, the
  fallback-`EFI/BOOT/bootx64.efi` + delete-Windows-NVRAM-entry fix, and
  `GRUB_DISABLE_OS_PROBER=false` for Windows to show in GRUB.

## Hard rules (do not violate)

1. **Never** delete the Linux partition before a confirmed clean reboot into
   Windows. That is what creates `grub rescue>`.
2. **Never** locate the EFI/Linux partition by index/position — use GPT GUID.
   `Win32_DiskPartition` hides the 128MB MSR, so index-based math is off by one
   and can target the wrong (Windows) volume.
3. **Always** check `$LASTEXITCODE` after `diskpart`/`bcdboot`/`bcdedit` and
   print `OK` only on success. A false "OK" is how boots get bricked.
4. **Always** quote bcdedit identifiers in PowerShell: `'{bootmgr}'`, not `{bootmgr}`.
5. The agent cannot run diskpart/bcdedit (no elevation). Ship the scripts and
   let the user run them via the self-elevating `.bat`.
