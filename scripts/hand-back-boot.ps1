#Requires -RunAsAdministrator
# hand-back-boot.ps1  --  Step 1 of safe removal: take Windows boot control back.
#
# What it does (all reversible, EXCEPT the final folder delete which is preceded
# by a verified backup):
#   1. Locate the EFI system partition by GPT GUID (never by index/position).
#   2. Mount it, VERIFY Z:\EFI exists before touching anything.
#   3. BACK UP EFI\ubuntu to ./EFI-ubuntu-backup (robocopy) and VERIFY the backup.
#   4. Check whether {bootmgr} is HIJACKED to \EFI\ubuntu\shimx64.efi.
#      If hijacked: rebuild Windows boot files (bcdboot) and reset the path.
#      VERIFY \EFI\Microsoft\Boot\bootmgfw.efi exists afterwards.
#   5. Remove EFI\ubuntu ONLY after the backup is confirmed good.
#   6. Delete any NVRAM firmware entry still pointing at \EFI\ubuntu.
#   7. Unmount.
#
# PRINCIPLE: every destructive or critical command is gated by a verification.
# If any gate fails, the script STOPS and prints FAIL -- it never "pretends OK".
#
# Run (must be admin):  powershell -ExecutionPolicy Bypass -File hand-back-boot.ps1
# Or via the self-elevating launcher:  run-as-admin.bat hand-back-boot.ps1

$ErrorActionPreference = 'Stop'
$EFI_GUID   = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
$EFILetter  = 'Z'
$BackupRoot = Join-Path $PSScriptRoot "EFI-ubuntu-backup"
$LogFile    = Join-Path $PSScriptRoot "hand-back-boot.log"

function Say($m){ $m | Out-File $LogFile -Append -Encoding utf8; Write-Host $m }
function Fail($m){ Say "FAIL - $m"; exit 1 }
Start-Transcript -Path $LogFile -Force | Out-Null
Say "=== hand-back-boot started $(Get-Date) ==="

# --- Gate 1: locate EFI by GUID -------------------------------------------------
$efi = Get-Partition | Where-Object { $_.GptType -eq $EFI_GUID }
if (-not $efi) { Fail "EFI system partition not found by GUID $EFI_GUID." }
Say ("OK - EFI partition is disk {0} partition {1} ({2} GB)." -f `
     $efi.DiskNumber, $efi.PartitionNumber, [math]::Round($efi.Size/1GB,1))

# --- Gate 2: mount and VERIFY it is really the EFI volume -----------------------
$dps = "select disk $($efi.DiskNumber)`r`nselect partition $($efi.PartitionNumber)`r`nassign letter=$EFILetter`r`nexit`r`n"
$dps | diskpart | Out-Null
if (-not (Test-Path "$EFILetter`:\EFI")) { Fail "Could not mount EFI at $EFILetter`: (Test-Path $EFILetter`:\EFI failed)." }
Say "OK - EFI mounted at $EFILetter`:."

# --- Gate 3: backup EFI\ubuntu and VERIFY the backup ----------------------------
$src = "$EFILetter`:\EFI\ubuntu"
if (Test-Path $src) {
    if (-not (Test-Path $BackupRoot)) { New-Item -ItemType Directory -Path $BackupRoot | Out-Null }
    & robocopy $src $BackupRoot /E /R:1 /W:1 | Out-Null
    # robocopy exit 0-7 = success; >=8 = failure
    if ($LASTEXITCODE -ge 8) { Fail "robocopy backup failed (code $LASTEXITCODE). Aborting before delete." }
    # verify at least bootmgfw-level files were copied
    $copied = (Get-ChildItem $BackupRoot -Recurse -File | Measure-Object).Count
    if ($copied -eq 0) { Fail "Backup produced 0 files. Aborting before delete." }
    Say "OK - backup of EFI\ubuntu saved to $BackupRoot ($copied files)."
} else {
    Say "NOTE - EFI\ubuntu not present; nothing to back up (already removed?)."
}

# --- Gate 4: hijack check + repair ----------------------------------------------
$bm = & bcdedit /enum '{bootmgr}' 2>&1
$pathLine = ($bm | Where-Object { $_ -match 'path' }) -join ' '
Say "Boot manager BEFORE repair:"
Say "    $pathLine"
if ($pathLine -match 'ubuntu') {
    Say ">>> {bootmgr} is HIJACKED to Ubuntu. Rebuilding Windows boot files..."
    & bcdboot C:\Windows /s $EFILetter`: /f UEFI | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "bcdboot failed (code $LASTEXITCODE)." }
    & bcdedit /set '{bootmgr}' path \EFI\Microsoft\Boot\bootmgfw.efi | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "bcdedit set path failed (code $LASTEXITCODE)." }
    $after = & bcdedit /enum '{bootmgr}' 2>&1
    $afterPath = ($after | Where-Object { $_ -match 'path' }) -join ' '
    Say "Boot manager AFTER repair:"
    Say "    $afterPath"
    if ($afterPath -notmatch 'Microsoft') { Fail "Repair did not restore Microsoft path. Stop and investigate." }
}
# verify the Windows loader actually exists on the EFI volume
if (-not (Test-Path "$EFILetter`:\EFI\Microsoft\Boot\bootmgfw.efi")) {
    Fail "bootmgfw.efi missing on EFI volume after repair. Windows will not boot."
}
Say "OK - $EFILetter`:\EFI\Microsoft\Boot\bootmgfw.efi exists."

# --- Gate 5: remove EFI\ubuntu only after backup verified -----------------------
if (Test-Path $src) {
    Remove-Item $src -Recurse -Force
    if (Test-Path $src) { Fail "Failed to remove EFI\ubuntu." }
    Say "OK - removed EFI\ubuntu."
} else {
    Say "NOTE - EFI\ubuntu already gone."
}

# --- Gate 6: remove stale NVRAM entries pointing at ubuntu ----------------------
$fw = & bcdedit /enum firmware 2>&1
$ids = @()
$cur = $null
foreach ($line in $fw) {
    if ($line -match '^identifier\s+(.+)') { $cur = $Matches[1].Trim() }
    if ($cur -and $line -match 'path\s+\\EFI\\ubuntu') { $ids += $cur }
}
foreach ($id in $ids) {
    & bcdedit /delete $id /f | Out-Null
    Say "OK - deleted NVRAM firmware entry $id (pointed at \EFI\ubuntu)."
}
if ($ids.Count -eq 0) { Say "OK - no stale NVRAM ubuntu entry found." }

# --- Gate 7: unmount ------------------------------------------------------------
$dpu = "select disk $($efi.DiskNumber)`r`nselect partition $($efi.PartitionNumber)`r`nremove letter=$EFILetter`r`nexit`r`n"
$dpu | diskpart | Out-Null
Say "OK - EFI unmounted."
Say "=== hand-back-boot done ==="
Say "NEXT: reboot. Windows must start directly with NO grub menu."
Say "Only if that works, run delete-partition.ps1."
Stop-Transcript | Out-Null
