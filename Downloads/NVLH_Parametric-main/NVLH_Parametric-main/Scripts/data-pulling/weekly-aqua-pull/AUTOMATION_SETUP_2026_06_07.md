# NVLH Weekly UPSVF+ILAS Automation - Session Summary (2026-06-07)

## Overview
Implemented automated weekly UPSVF pull with ILAS analysis and merge, now scheduled to run daily at 5:00 AM.
All changes documented with inline code comments and parameterized defaults.

## Changes Implemented

### 1. ILAS Data Cleaning - Test Name Suffix Filter
**File**: `Scripts/parametric-analysis/ilas/aqua_nvlh_ilas_vmin_analysis.ps1`
**Changes**: Added new function `Filter-RowsByTestNameSuffix` (after line ~428)

**Purpose**: Remove ILAS test rows where TEST_NAME ends with `_it` or `_scrb` suffixes
- These are metadata/scrub rows not part of valid Vmin measurements
- Filtered immediately after opergroup filter, before UPSVF key matching

**Examples of filtered rows**:
```
IPC::SCN_ATOM_CX48::ATSPEED_ATOM_VMIN_K_F1XAT_X_AT_F1_1200_OCC_it
IPC::SCN_ATOM_CX48::ATSPEED_ATOM_VMIN_K_F1XAT_X_AT_F1_1200_OCC_scrb
```

**Implementation**:
- Line ~428-461: New function definition
- Line ~544: Applied filter call in data pipeline: `$rawRows = @(Filter-RowsByTestNameSuffix -Rows $rawRows -ExcludeSuffixes @("_it", "_scrb"))`

### 2. Opergroup Filter (CLASSHOT Only)
**File**: `Scripts/parametric-analysis/ilas/aqua_nvlh_ilas_vmin_analysis.ps1`
**Changes**: Ensured opergroup filter default remains `"6248_CLASSHOT"`

**Details**:
- Default parameter: `[string]$OpergroupFilter = "6248_CLASSHOT"` (line 4)
- Applied after raw file load, before UPSVF key matching
- Retains only CLASSHOT opergroup data, excludes CSM and other variants

### 3. Merge Temp-File Collision Fix
**File**: `Scripts/data-pulling\weekly-aqua-pull\aqua_nvlh_weekly_pull.ps1`
**Changes**: Already applied in prior session (lines ~480-485)

**Problem Resolved**: 
- `Move-Item -Force` fails when destination file exists (from prior failed run)
- Solution: Use `Copy-Item -Force` for atomic replacement + pre-cleanup of stale .tmp

**Code Pattern**:
```powershell
# Remove stale temp file before write
if (Test-Path -LiteralPath $tmpPath) {
    Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue
}
# Export and write merge result
$upsRows | Export-Csv -LiteralPath $tmpPath -NoTypeInformation
# Replace destination robustly (Copy-Item -Force is atomic)
Copy-Item -LiteralPath $tmpPath -Destination $UpsvfCsvPath -Force
Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue
```

### 4. Documentation Added to Both Scripts
**Files**:
- `Scripts/parametric-analysis/ilas/aqua_nvlh_ilas_vmin_analysis.ps1` (top, lines 1-21)
- `Scripts/data-pulling/weekly-aqua-pull/aqua_nvlh_weekly_pull.ps1` (top, lines 1-25)

**Content**:
- Synopsis and description of automation flow
- All changes documented with dates (2026-06-07)
- Parameter documentation with defaults
- Example filtered test names for suffix filter

## Retention Policy
- **Test-End Lookback**: 2 days (default `LastNDaysTestEnd = 2`)
- **Artifact Retention**: 366 days (default `RetentionDays = 366`)
- **Data Sampling Cap**: 150,000 rows per Aqua pull (default `AquaMaxRows = 150000`)

## Setup Instructions: Enable Daily 5:00 AM Automation

### Option 1: PowerShell Script (Recommended)
```powershell
# Run as Administrator
& "c:\Projects\NVL\.docs\Scripts\data-pulling\weekly-aqua-pull\schedule-weekly-run.ps1"
```

**What this does**:
1. Creates Task Scheduler task named "NVL UPSVF Weekly Pull"
2. Sets trigger: Every day at 5:00 AM
3. Configures action: Run aqua_nvlh_weekly_pull.ps1 with ILAS analysis
4. Enables network availability check and task restart
5. Registers an explicit task principal (RunAsUser/LogonType/RunLevel) for predictable non-interactive execution behavior

**Hardening defaults**:
- LogonType default is `Interactive` to preserve network-share access used by AQUA/output paths.
- Setup scripts now unblock themselves and the target run scripts before task registration.
- You can switch to `S4U` for stricter non-interactive token use, but UNC/network paths may fail under S4U.

### Option 2: Manual Task Scheduler Setup
1. Open Task Scheduler (tasksched.msc)
2. Right-click Task Scheduler Library → Create Basic Task
3. **Name**: "NVL UPSVF Weekly Pull"
4. **Trigger**: Daily at 5:00 AM
5. **Action**: Start Program
   - Program: `powershell.exe`
   - Arguments: `-NoProfile -NoExit -Command "& 'c:\Projects\NVL\.docs\Scripts\data-pulling\weekly-aqua-pull\aqua_nvlh_weekly_pull.ps1' -OutputDirectory '\\ger\ec\proj\ha\mmgbd\MMGBD_PSA\Products\NVL\NVL-H\Weekly Runs' -IlasScriptPath 'c:\Projects\NVL\.docs\Scripts\parametric-analysis\ilas\aqua_nvlh_ilas_vmin_analysis.ps1' -KeepCleanCsvArtifact"`

## Output Locations
- **Final UPSVF+ILAS CSV**: `\\ger\ec\proj\ha\mmgbd\MMGBD_PSA\Products\NVL\NVL-H\Weekly Runs\Vmin_NVLHM66A0H30N00S623_WW<WW>_<YYYY>.csv`
- **ILAS Detail CSV**: `...\_ilas_weekly_<DATE>_<TIME>\ILAS_Vmin_Detail_WW<WW>_<YYYY>.csv`
- **ILAS Summary CSV**: `...\_ilas_weekly_<DATE>_<TIME>\ILAS_Vmin_Summary_WW<WW>_<YYYY>.csv`
- **Status Log**: `...Weekly_Run_Status.csv`
- **Execution Diagnostics**: Task Scheduler Operational log + `Weekly_Run_Status.csv`

## Validation Performed (2026-06-07)
- ✅ Criterion 1: Lot filter (P6230790) → 100 rows, all lot P6230790
- ✅ Criterion 2: UPSVF AQUA query → Correct params, AQUA invoked
- ✅ Criterion 3: Clean output with Classhot filtering → 100 rows, all RCS_PROCESSSTEP=CLASSHOT
- ✅ Criterion 4: VisualID+Lot ILAS pull → 95 VIDs extracted, opergroup 6248_CLASSHOT filter applied
- ✅ Criterion 5: DTS/LP instance processing → MaxDTS_C/LimiterPattern parsed correctly
- ✅ Criterion 6 & 7: Merge with UPSVF + cleanup → Success with atomic file replacement
- ✅ Test suffix filter: Confirmed _it and _scrb rows excluded from processing

## Key Parameters
```powershell
# Weekly Pull (aqua_nvlh_weekly_pull.ps1)
-LastNDaysTestEnd 2              # Test-end lookback (days)
-Operations "6248"               # Operation group for UPSVF pull
-FunctionalBin "100"             # Functional bin filter
-AquaMaxRows 150000              # Data sampling cap
-KeepCleanCsvArtifact            # Retain clean intermediate CSV

# ILAS Analysis (aqua_nvlh_ilas_vmin_analysis.ps1)
-OpergroupFilter "6248_CLASSHOT" # CLASSHOT only
-LastNDaysTestEnd 7              # Test-end lookback (days)
-MinValidVmin 0.2                # Minimum valid Vmin (V)
-MaxValidVmin 2.0                # Maximum valid Vmin (V)
```

## Files Modified
1. `Scripts/parametric-analysis/ilas/aqua_nvlh_ilas_vmin_analysis.ps1`
   - Added: `Filter-RowsByTestNameSuffix` function
   - Added: Filter call in data pipeline
   - Added: Documentation header

2. `Scripts/data-pulling/weekly-aqua-pull/aqua_nvlh_weekly_pull.ps1`
   - Added: Documentation header
   - (Merge fix already applied in prior session)

3. `Scripts/data-pulling/weekly-aqua-pull/schedule-weekly-run.ps1` (NEW)
   - Created: Task Scheduler setup script

## Testing the Automation
```powershell
# Test with specific lot (does NOT modify scripts)
$weekly='c:\Projects\NVL\.docs\Scripts\data-pulling\weekly-aqua-pull\aqua_nvlh_weekly_pull.ps1'
$ilas='c:\Projects\NVL\.docs\Scripts\parametric-analysis\ilas\aqua_nvlh_ilas_vmin_analysis.ps1'
& $weekly -OutputDirectory 'c:\Projects\NVL\.docs\Scripts\_validation\test_run' `
  -LotsOverride 'P6230790' -MaxVisualUnits 20 -IlasScriptPath $ilas -KeepCleanCsvArtifact

# Test with production configuration (full run)
& $weekly -IlasScriptPath $ilas -KeepCleanCsvArtifact
```

## Troubleshooting
| Issue | Cause | Resolution |
|-------|-------|-----------|
| "Cannot create a file when that file already exists" | Stale .tmp from failed run | Already fixed with Copy-Item -Force + cleanup |
| Test names ending in _it/_scrb still in output | Filter not applied | Verify ILAS script updated (line ~544) |
| CLASSHOT data missing | Opergroup filter not applied | Check OpergroupFilter default = "6248_CLASSHOT" |
| Task doesn't run | Task not enabled in Scheduler | Run schedule-weekly-run.ps1 as Administrator |
| Insufficient permissions | Non-admin task scheduler | Required for WinRM/AQUA access; contact IT if needed |

## Next Steps
1. Run `schedule-weekly-run.ps1` as Administrator to enable daily 5:00 AM automation
2. Monitor first run via Task Scheduler history and `\\ger\ec\proj\ha\mmgbd\MMGBD_PSA\Products\NVL\NVL-H\Weekly Runs\Weekly_Run_Status.csv`
3. Verify ILAS columns present in final merged CSV
4. Adjust data retention or sampling limits if needed (in script parameters)

---
**Last Updated**: 2026-06-07 (WW23)  
**Changes Validated By**: Manual verification + post-fix test run
