# TRACE Classhot Parametric Plan (NVLAX62A0H25*)

## Goal
Run real-case Classhot parametric extraction for all Class jobs where test program contains `NVLAX62A0H25*`, and save outputs under:
`R:\Products\NVL\NVL-AX\Weekly data pull\Trace based data`

## Scripts Saved
- Bridge parser:
  - `Scripts/parametric-analysis/ilas/trace_classhot_parametric_bridge.ps1`
- Real-case runner:
  - `development/validation/run_trace_realcase_nvlax62a0h25.ps1`

## Implemented Logic Snapshot
- VMIN
  - Parse `_VMIN_` base with companions `_VMINFWCFG`, `_DTS`, `_LP`
  - Winner-only output per `VisualID+ClasshotLot+Domain+Corner+Flow+Freq+Core`
  - Equal-VMIN tie-break prefers non-missing `_LP`, else first stable record
- DTS
  - Core/Atom domain-aware max rules
  - HUB/GT uses global max sensor temperature
- SICC
  - Parse caret payload entries and test-name fallback
  - Domain/core normalization
  - Source-aware die mapping for `PP_SICC_U1PUx`, `GTSICC`, `SASICC`
- Sort lot data
  - Parse `FUS_UNITINFO_*...MAIN_FUSE_READ` values
  - Populate base and die-suffix geometry columns: `U1.U2`, `U1.U4`, `U1.U5`
- Functional bin
  - Pass-through from source when any of these columns exists:
    - `FUNCTIONAL_BIN`, `FunctionalBin`, `HBIN`, `SOFT_BIN`, `SoftBin`

## Real-Case Workflow
1. Discover jobs using `find_jobs` filter (`Class`, `6248`, `CLASSHOT`, `NVLAX62A0H25`).
2. Use full jobs CSV from `find_jobs.filePath` (all rows, not preview slice).
3. Pull per-job `get_test_results` for:
   - Core set: `SICC`, `_VMIN_`, `_VMINFWCFG`, `_DTS`, `_LP`, `FUS_UNITINFO_HXX`, `FUS_UNITINFO_GXX`, `FUS_UNITINFO_CXX`
   - Bin set: `FUNCTIONAL_BIN`, `SOFT_BIN`, `HBIN`, `BIN`
4. Merge + dedupe rows by `JobName+TestName+VisualId+Value`.
5. Run bridge parser and export final artifacts.

## Output Contract
- Stage files:
  - `<prefix>_vmin_stage_<timestamp>.csv`
  - `<prefix>_sicc_stage_<timestamp>.csv`
- Final file:
  - `<prefix>_final_<timestamp>.csv`
- Final file includes VMIN ILAS-style columns and SICC GSDS-style columns.
- Final file excludes old validation payload text columns.

## Current Execution Note
Some very large jobs (notably PG jobs) produce very large pull files. Runner supports per-job progression and fault capture so execution can continue and artifacts can still be built from completed pulls.
