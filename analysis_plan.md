# NVLH Analysis Plan

## Objective
Establish a repeatable weekly analysis flow for NVLH parametric data that pulls AQUA UPSVF data, filters to valid CLASSHOT rows, runs ILAS analysis when available, merges ILAS-derived Vmin/Setter/MaxDTS_C/LP columns back into the final UPSVF output, and validates the final dataset for downstream use.

## Scope
- Source data: AQUA UPSVF weekly pull for NVLH
- Filtering: exclude lot suffixes like *MV, keep Classhot rows, limit by Visual ID set and retention windows
- ILAS step: run on the final VisualID+Lot set, merge summaries back into the final CSV
- Outputs: final Vmin CSV, clean CSV artifact, status log, health log

## Workflow
### 1. Data pull and normalization
- Pull raw UPSVF from AQUA using the weekly pull script.
- Validate that the file contains the expected Visual ID and lot columns.
- Drop irrelevant DS columns immediately after the raw export if they are not needed.
- Keep only rows that match the intended process-stage filter.

### 2. Quality filtering
- Exclude lot rows ending in *MV.
- Keep Classhot records using the process-step column, with fallback logic for newer report formats.
- Keep only the final Visual ID set within the maximum unit cap to avoid overloading the analysis.
- In output naming, use the dominant program name when present; otherwise use UNKNOWN_PROGRAM.

### 3. ILAS analysis step
- Run the ILAS regression/summary analysis only when the filtered UPSVF structure is valid.
- Use the final VisualID+Lot set as the analysis reference.
- Accept cases where ILAS output is not immediately available and keep the UPSVF-only CSV while waiting for data.
- Persist the ILAS summary output and status message for traceability.

### 4. Merge back into UPSVF
- Join ILAS rows to UPSVF using Visual ID + lot as the key.
- Prefix merged ILAS columns with ILAS_ to avoid collisions.
- Clear ILAS values when the corresponding UPSVF row does not have an underlying domain/frequency signal.
- Write the final merged CSV to the target output directory.

### 5. Retention and hygiene
- Remove expired raw/clean/merged temporary files based on retention days.
- Prune status CSV entries older than the configured retention threshold.
- Keep the health log and status CSV to track run history and failure conditions.

## Validation gates
1. Raw file exists and is non-empty.
2. Required columns exist: Visual ID and lot/class-lot columns.
3. Post-filter rows remain after removing *MV and non-Classhot rows.
4. Visual ID cap does not reduce the data to zero.
5. ILAS summary file is generated when expected.
6. Merged CSV is non-empty and passes the final export check.
7. Logs show the expected status: SUCCESS, WAITING_FOR_DATA, SKIPPED, or FAILED.

## Known risk areas
- AQUA schema drift such as changes in process-step column names.
- Older and newer report formats using different CLASSHOT indicators.
- Missing or delayed ILAS output; must not fail the whole UPSVF run if the data is just not ready.
- Temp-file collisions on repeated runs; use unique run stamps and safe overwrite patterns.

## Recommended next actions
- Validate the weekly AQUA pull against a known-good recent run.
- Check that the process-step detection logic still matches the latest report schema.
- Confirm the ILAS summary naming pattern and merge output remain stable.
- Review the final Weekly_Run_Status.csv entries for noise, retention, and completeness.
- Keep the final outputs in a single agreed directory structure for weekly automation.

## Deliverables
- Final merged Vmin CSV
- Optional clean CSV artifact
- Weekly_Run_Status.csv
- Vmin_health.csv
- ILAS summary CSV for each corresponding run
