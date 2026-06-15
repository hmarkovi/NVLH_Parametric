# S622 vs S623 Analysis — Root Cause of ILAS Merge Failure

## Executive Summary
**Problem**: Current script runs fail with zero ILAS data, while historical runs (S622) succeeded.
**Root Cause**: Program variant changed from S622 (M00) to S623 (N00); ILAS has no data for S623 despite UPSVF pull succeeding.
**Difference**: S623 has higher row count in UPSVF → script picks it as "most abundant" → ILAS query for S623 returns 0 rows.

---

## Current vs Historical

| Aspect | Current (Failing) | Historical (Working) |
|--------|------------------|----------------------|
| **Program Name** | NVLHM66A0H30**N00**S623 | NVLHM66A0H30**M00**S622 |
| **Step Revision** | N00 (newer) | M00 (older) |
| **Release** | S623 | S622 |
| **UPSVF Data** | 1047 rows ✓ | Unknown (assumed present) |
| **ILAS Data** | 0 rows ✗ | Present ✓ (validation file exists) |
| **Date Pulled** | 2026-06-14 | 2026-06-02 |
| **Run Status** | FAILED | SUCCESS |

---

## Why the Script Selected S623

**Script Logic** (aqua_nvlh_weekly_pull.ps1, lines 764-772):
```powershell
$topProgram = $filteredRows |
    Group-Object -Property $programColumn |
    Sort-Object -Property Count -Descending |
    Select-Object -First 1

$mostAbundantProgram = if ($topProgram -and $topProgram.Name) { $topProgram.Name } else { "UNKNOWN_PROGRAM" }
```

**What Happened**:
1. User provided `-ProgramPattern "NVLHM66*"` (wildcard match)
2. AQUA query returned multiple programs matching pattern (likely both S622 M00 and S623 N00)
3. Script picked **S623** because it had more rows than S622
4. Script outputs filename based on most abundant: `Vmin_NVLHM66A0H30N00S623_WW24_2026.csv`

---

## Why ILAS Failed for S623

**Evidence**:
- UPSVF pull: 1047 rows from S623 ✓ (`Weekly_Run_Status.csv` shows `NVLHM66A0H30N00S623`)
- ILAS lot-chunk query: 0 rows returned ✗ (`Weekly_Run_Health.csv` shows failure)
- Exit code: 0 (AQUA process succeeded, but no output file created)
- Root cause: AQUA report `sbelyy\ILAS\ILAS_VMIN_DTS` has **no data** for S623 with Functional Bin 100 filter

**Possible Reasons**:
1. **S623 is too new** — ILAS data not yet populated for S623 program step
2. **Functional Bin 100 too restrictive** — All S623 units may be in other functional bins (e.g., Bin 1, Bin 13)
3. **ILAS report lagging** — ILAS data pipeline hasn't caught up to S623 yet (12 days old as of 2026-06-14)

---

## Why S622 Worked

**Historical Success** (2026-06-02):
- Validation file exists: `Vmin_NVLHM66A0H30M00S622_WW24_2026`
- ILAS data was available for S622 M00 step
- Either:
  - S622 M00 had more test results by that date, OR
  - ILAS report had been populated with S622 data at that time

**Key Insight**: Between 2026-06-02 and 2026-06-14, program data matured:
- More UPSVF test results came in for S623 N00 step (newer)
- But ILAS data still only exists for S622 M00 step (older, already in report)
- Script's "most abundant" logic preferred S623 because UPSVF had more rows

---

## Solution Options

### Option A: Force Script to Use S622 (Quick Fix)
**Approach**: Add parameter to override program pattern to exact program, not wildcard.
**Change**: Pass `-ProgramPattern "NVLHM66A0H30M00S622"` instead of `"NVLHM66*"`
**Pro**: Ensures backward compatibility with working version
**Con**: Misses new S623 data; temporary workaround only

### Option B: Skip ILAS if No Data (Robust Fix)
**Approach**: Detect when ILAS query returns 0 rows and skip enrichment gracefully.
**Current behavior**: Fails with "no output file" error
**Better behavior**: Output clean UPSVF CSV without ILAS columns; log warning
**Pro**: Handles both new and old programs; doesn't block on missing ILAS data
**Con**: Output structure varies (some weeks with ILAS, some without)

### Option C: Allow Program Selection Strategy (Flexible Fix)
**Approach**: Add script parameter to choose program selection:
- `-ProgramSelection "MostAbundant"` (current, default — fails on S623)
- `-ProgramSelection "Specific" -TargetProgram "NVLHM66A0H30M00S622"` (work with S622)
- `-ProgramSelection "MinimumViableWithIlas"` (pick first program that has ILAS data)
**Pro**: Adaptable to future program changes
**Con**: More complex logic

### Option D: Investigate ILAS Data Availability (Root Analysis)
**Approach**: Query AQUA directly to check if ILAS data exists for S623.
**Command**: Run ILAS query without Functional Bin filter, or with broader date range
**Goal**: Determine if:
  - S623 ILAS data doesn't exist at all
  - S623 ILAS data exists but not in Functional Bin 100
  - ILAS report is lagging behind UPSVF

---

## Recommendation

**Immediate (2026-06-14)**: 
- Use Option A as quick workaround: `.\aqua_nvlh_weekly_pull.ps1 -ProgramPattern "NVLHM66A0H30M00S622"`
- This restores 2026-06-02 working state

**Short-term (next 1-2 weeks)**:
- Implement Option B: Add graceful ILAS skip when 0 rows returned
- Output clean CSV even if ILAS merge fails
- Allows automation to proceed without blocking

**Long-term (future)**:
- Monitor when ILAS data becomes available for S623
- Switch to Option C: flexible program selection
- Or: Update ILAS report configuration to include S623 data sooner

---

## Files Reference
- Current failure: [Vmin_NVLHM66A0H30N00S623_WW24_2026_clean.csv](../validation/weekly_full_ilas_verify_20260614_1/Vmin_NVLHM66A0H30N00S623_WW24_2026_clean.csv)
- Historical success: Vmin_NVLHM66A0H30M00S622_WW24_2026.csv (2026-06-02 session)
- Script with "most abundant" logic: [aqua_nvlh_weekly_pull.ps1](../../Scripts/data-pulling/weekly-aqua-pull/aqua_nvlh_weekly_pull.ps1#L764-L772)
