#Requires -RunAsAdministrator
# delete-partition.ps1  --  Step 3 of safe removal: delete the Linux partition.
#
# MUST run only AFTER hand-back-boot.ps1 AND a successful reboot into Windows
# with no grub menu. Running this first leaves grub rescue -> unbootable.
#
# VERIFICATION GATES (this is the whole point of the script):
#   - Target is identified by GPT GUID, not by index/position.
#   - Target must be a Linux filesystem partition (GptType = LINUX_GUID).
#   - Target must have NO drive letter (Windows data partitions always do).
#   - Target Type must NOT be 'Basic' (Linux shows as Unknown/RAW to Windows).
#   - Target capacity must fall inside a window the operator explicitly confirms.
#   - Operator must type the exact capacity, then type DELETE, before anything moves.
#
# Run (must be admin):  powershell -ExecutionPolicy Bypass -File delete-partition.ps1
# Or:  run-as-admin.bat delete-partition.ps1

$ErrorActionPreference = 'Stop'
$LINUX_GUID = '{0fc63daf-8483-4772-8e79-3d69d8477de4}'
$LogFile    = Join-Path $PSScriptRoot "delete-partition.log"

function Say($m){ $m | Out-File $LogFile -Append -Encoding utf8; Write-Host $m }
function Fail($m){ Say "FAIL - $m"; exit 1 }
Start-Transcript -Path $LogFile -Force | Out-Null
Say "=== delete-partition started $(Get-Date) ==="

# --- show the real partition table (diskpart view) as a sanity reference -------
Say "Disk 0 partition list (from diskpart):"
"list disk`r`nselect disk 0`r`nlist partition`r`nexit`r`n" | diskpart | ForEach-Object { Say "  $_" }

# --- Gate 1: identify candidate by GPT GUID -------------------------------------
$cands = Get-Partition | Where-Object { $_.GptType -eq $LINUX_GUID }
if ($cands.Count -eq 0) { Fail "No Linux filesystem partition found by GUID $LINUX_GUID (already removed?)." }
if ($cands.Count -gt 1) { Fail "Multiple Linux partitions found ($($cands.Count)). Refusing to guess -- handle manually in diskmgmt.msc." }

$lin = $cands[0]
$gb  = [math]::Round($lin.Size/1GB, 1)
Say ("Target identified: disk {0} partition {1} / {2} GB / type={3} / letter={4}" -f `
     $lin.DiskNumber, $lin.PartitionNumber, $gb, $lin.Type, $(if($lin.DriveLetter){$lin.DriveLetter}else{'-'}))

# --- Gate 2: structural sanity (no letter, not Basic) ---------------------------
if ($lin.DriveLetter) { Fail "Target has a drive letter '$($lin.DriveLetter)' -- that is a Windows volume, NOT Linux. Aborting." }
if ($lin.Type -eq 'Basic') { Fail "Target Type is 'Basic' -- that is a Windows data partition. Aborting." }

# --- Gate 3: operator confirms the capacity -------------------------------------
$end = ($lin.PartitionNumber -eq (Get-Partition | Measure-Object PartitionNumber -Maximum).Maximum)
Say "Sanity check: the Linux partition has NO drive letter and sits at disk END = $end."
Say "It must NOT be C: and must NOT be E: (or any lettered Windows volume)."
$ans = Read-Host ("How many GB does the partition you want to delete have? (type {0} to proceed)" -f $gb)
if ($ans.Trim() -ne [string]$gb) { Fail "Capacity answer '$ans' != detected $gb GB. Aborting." }
Say "OK - capacity confirmed ($gb GB)."

# --- Gate 4: explicit DELETE acknowledgement ------------------------------------
$confirm = Read-Host "This will PERMANENTLY delete the Linux data. Type DELETE in all caps to continue"
if ($confirm -ne 'DELETE') { Fail "Confirmation was '$confirm', not 'DELETE'. Aborting -- nothing changed." }
Say "Confirmation received. Deleting..."

# --- Action: delete via diskpart (uses verified Get-Partition numbering) --------
$dps = "select disk $($lin.DiskNumber)`r`nselect partition $($lin.PartitionNumber)`r`ndelete partition override`r`nexit`r`n"
$dps | diskpart | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "diskpart delete returned code $LASTEXITCODE." }

# --- Verify it is actually gone -------------------------------------------------
$still = Get-Partition | Where-Object { $_.GptType -eq $LINUX_GUID }
if ($still) { Fail "Linux partition still present after delete. Investigate." }
Say "OK - Linux partition deleted. Disk 0 partition table now:"
Get-Partition | Select-Object PartitionNumber,Type,@{n='GB';e={[math]::Round($_.Size/1GB,1)}},DriveLetter |
    Format-Table -AutoSize | Out-String | ForEach-Object { Say "  $_" }
Say "Check diskmgmt.msc - the freed space should show as Unallocated."
Say "Leave it unallocated; a fresh Linux installer will use it."
Say "=== delete-partition done ==="
Stop-Transcript | Out-Null
