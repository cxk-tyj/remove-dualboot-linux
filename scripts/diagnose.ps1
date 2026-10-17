# diagnose.ps1  --  READ-ONLY. Never mutates the disk or boot config.
#
# Purpose: figure out HOW Linux coexists with Windows before touching anything.
#   - Is it a physical dual-boot, WSL, or a VM?  (the removal path differs hugely)
#   - Which partition is the EFI system partition (by GPT GUID, never by index)?
#   - Which partition is the Linux filesystem (by GPT GUID)?
#   - Is {bootmgr} hijacked to point at \EFI\ubuntu\shimx64.efi?
#
# Run:  powershell -ExecutionPolicy Bypass -File diagnose.ps1
# No administrator rights required for the read-only checks.

$EFI_GUID  = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'   # EFI System Partition
$LINUX_GUID = '{0fc63daf-8483-4772-8e79-3d69d8477de4}'  # Linux filesystem

function Say($m){ Write-Host $m }

Say "==================== DIAGNOSE: Windows + Linux coexistence ===================="

# --- 1. WSL (not a real dual-boot) ---------------------------------------------
Say "`n[1] WSL distributions (if any):"
$wsl = & wsl --list --verbose 2>&1
if ($LASTEXITCODE -eq 0 -and $wsl) { $wsl | ForEach-Object { Say "    $_" } }
else { Say "    none / wsl not available" }

# --- 2. Partition table via Get-Partition (matches diskpart numbering) ----------
Say "`n[2] Partition table (Get-Partition view, numbers MATCH diskpart):"
$parts = Get-Partition
foreach ($p in $parts) {
    $gb  = [math]::Round($p.Size/1GB, 1)
    $ltr = if ($p.DriveLetter) { $p.DriveLetter } else { '-' }
    Say ("    #{0,-2} disk{1} type={2,-9} letter={3} GB={4,-7} gpt={5}" -f `
         $p.PartitionNumber, $p.DiskNumber, $p.Type, $ltr, $gb, $p.GptType)
}

# --- 3. Identify EFI and Linux partitions by GUID (NOT by position) -------------
$efi  = $parts | Where-Object { $_.GptType -eq $EFI_GUID }
$lin  = $parts | Where-Object { $_.GptType -eq $LINUX_GUID }

Say "`n[3] Target identification (by GPT GUID, position-independent):"
if ($efi) {
    Say ("    EFI system partition : disk {0} partition {1}  ({2} GB)" -f `
         $efi.DiskNumber, $efi.PartitionNumber, [math]::Round($efi.Size/1GB,1))
} else { Say "    EFI system partition : NOT FOUND" }

if ($lin) {
    $ltr = if ($lin.DriveLetter) { $lin.DriveLetter } else { '(no letter)' }
    Say ("    Linux partition      : disk {0} partition {1}  ({2} GB)  letter={3}" -f `
         $lin.DiskNumber, $lin.PartitionNumber, [math]::Round($lin.Size/1GB,1), $ltr)
    $linIsEnd = ($lin.PartitionNumber -eq ($parts | Measure-Object PartitionNumber -Maximum).Maximum)
    Say ("    Linux at disk END?   : {0}  (end position is ideal for deletion)" -f $linIsEnd)
} else { Say "    Linux partition      : NOT FOUND (maybe already gone, or this is WSL/VM)" }

# --- 4. Boot manager hijack check ----------------------------------------------
Say "`n[4] Boot manager entry ({bootmgr}) path check:"
$bm = & bcdedit /enum '{bootmgr}' 2>&1
$pathLine = ($bm | Where-Object { $_ -match 'path' }) -join ' '
Say "    $pathLine"
if ($pathLine -match 'ubuntu') {
    Say "    >>> WARNING: {bootmgr}.path points to Ubuntu (HIJACKED)."
    Say "        Deleting EFI\ubuntu without repairing this will make Windows unbootable."
} else {
    Say "    OK: {bootmgr} points to Microsoft boot loader."
}

# --- 5. Firmware boot entries ---------------------------------------------------
Say "`n[5] Firmware (NVRAM) boot entries:"
& bcdedit /enum firmware 2>&1 | ForEach-Object { Say "    $_" }

# --- 6. Verdict ----------------------------------------------------------------
Say "`n==================== VERDICT ===================="
if (-not $lin -and -not ($wsl | Where-Object { $_ -match 'Ubuntu' })) {
    Say "No Linux partition and no Ubuntu WSL found. Nothing to remove on disk."
} elseif ($lin) {
    Say "Physical dual-boot confirmed. Safe-removal order:"
    Say "  1) backup + remove EFI\ubuntu, and REPAIR {bootmgr} if hijacked"
    Say "  2) REBOOT and confirm Windows boots with NO grub menu"
    Say "  3) only then delete the Linux partition (scripts/delete-partition.ps1)"
    Say "NEVER delete the Linux partition before step 2 -- grub rescue black screen otherwise."
} else {
    Say "Looks like WSL/VM, not a physical dual-boot. Use a different removal method."
}
Say "=============================================="
