<#
.SYNOPSIS
Single-lot validation run: LOTSFORMFS, cleared Aqua filters, 1 lot only, functional bin 100.

.DESCRIPTION
Runs aqua_nvlh_weekly_pull.ps1 for a single lot (Y6220110) using the LOTSFROMFS filter type.
All Aqua override filters (programNames, lastNDaysTestEnd, operations) are cleared so only
the saved report base config + lot filter + functional bin 100 apply.

Lot filter method: -lotsfromfs (LOTSFORMFS) — relies on the Aqua FilterSet containing Y6220110.
If you need to override the FilterSet, set -LotsExplicit to pass -lots instead.

.NOTES
Generated: 2026-06-14
Validation target: 1 lot — Y6220110, functional bin 100, all other Aqua filters cleared.
#>

param(
    [string]$UpsvfScriptPath    = "",
    [string]$AquaExe            = "\\ger.corp.intel.com\ec\proj\ha\stav\DIS_Downloads\AquaHbase\AquaCMDClient\Client\AquaCmdLine.exe",
    [string]$OutputDirectory    = "\\ger\ec\proj\ha\mmgbd\MMGBD_PSA\Products\NVL\NVL-H\Weekly Runs\validation",
    [string]$Lot                = "Y6220110",
    [string]$FunctionalBin      = "100",
    # When true: pass -lots $Lot (explicit). When false (default): leave LotsOverride empty so -lotsfromfs is used.
    [switch]$LotsExplicit,
    [switch]$SkipIlas
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ── Resolve script paths ────────────────────────────────────────────────────
if ([string]::IsNullOrWhiteSpace($UpsvfScriptPath)) {
    $scriptDir    = Split-Path -Path $PSCommandPath -Parent
    $UpsvfScriptPath = Join-Path $scriptDir "aqua_nvlh_weekly_pull.ps1"
}

if (-not (Test-Path -LiteralPath $UpsvfScriptPath)) {
    throw "UPSVF script not found: $UpsvfScriptPath"
}

$weeklyAquaPullDir = Split-Path -Path $UpsvfScriptPath -Parent
$dataPoolingDir    = Split-Path -Path $weeklyAquaPullDir -Parent
$scriptsDir        = Split-Path -Path $dataPoolingDir -Parent
$IlasScriptPath    = Join-Path $scriptsDir "parametric-analysis\ilas\aqua_nvlh_ilas_vmin_analysis.ps1"

if (-not (Test-Path -LiteralPath $IlasScriptPath)) {
    throw "ILAS script not found: $IlasScriptPath"
}

# ── Resolve output directory ─────────────────────────────────────────────────
$stamp     = Get-Date -Format "yyyyMMdd_HHmmss"
$runLabel  = "lot_single_{0}_{1}" -f $Lot, $stamp
$runOutDir = Join-Path $OutputDirectory $runLabel

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Single-Lot Validation Run" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Lot            : $Lot"
Write-Host "  Lot filter type: $(if ($LotsExplicit) { '-lots (explicit)' } else { '-lotsfromfs (LOTSFORMFS)' })"
Write-Host "  Functional bin : $FunctionalBin"
Write-Host "  Cleared filters: programNames, lastNDaysTestEnd, operations"
Write-Host "  Output dir     : $runOutDir"
Write-Host ""

# ── Build arguments ──────────────────────────────────────────────────────────
# ProgramPattern = ""   → skips -programNames in AQUA call
# Operations     = ""   → skips -operations in AQUA call (NOTE: -lotsfromfs may require operations;
#                         if AQUA rejects the call, switch -LotsExplicit to use -lots instead,
#                         or re-add Operations = "6248")
# LastNDaysTestEnd = 0  → skips -lastNDaysTestEnd in AQUA call (no date restriction)
$lotsOverrideValue = if ($LotsExplicit) { $Lot } else { "" }

$upsvfArgs = @{
    AquaExe              = $AquaExe
    AquaServer           = "GER"
    ReportPath           = "hmarkovi\BSAT_UPS2_POR_PTL_NVL WW12"
    ProgramPattern       = ""           # cleared — do not pass -programNames to Aqua
    Operations           = ""           # cleared — do not pass -operations to Aqua
    LastNDaysTestEnd     = 0            # cleared — do not pass -lastNDaysTestEnd to Aqua
    OutputDirectory      = $runOutDir
    FunctionalBin        = $FunctionalBin
    RetentionDays        = 366
    MaxVisualUnits       = 100000
    AquaMaxRows          = 150000
    AquaPullTimeoutSeconds = 7200
    AquaPullPollSeconds  = 20
    IlasScriptPath       = $IlasScriptPath
    LotsOverride         = $lotsOverrideValue   # "" → -lotsfromfs ; "Y6220110" → -lots Y6220110
    KeepCleanCsvArtifact = $true
}

if ($SkipIlas) {
    $upsvfArgs['SkipIlasStep'] = $true
}

# ── Run ───────────────────────────────────────────────────────────────────────
Write-Host "Starting UPSVF AQUA pull + ILAS merge..."
Write-Host ""

try {
    & $UpsvfScriptPath @upsvfArgs
    Write-Host ""
    Write-Host "Single-lot validation completed successfully" -ForegroundColor Green
    Write-Host "Output: $runOutDir"
}
catch {
    Write-Host ""
    Write-Host "ERROR: Validation run failed: $($_.Exception.Message)" -ForegroundColor Red

    # If the error looks like an Aqua LOTSFORMFS/operations conflict, suggest the workaround
    $msg = $_.Exception.Message
    if ($msg -match "lotsFromFs|lotsfromfs|LotsFromFs|operations" -or $msg -match "No new operation") {
        Write-Host ""
        Write-Host "HINT: -lotsfromfs requires an operations filter. Re-run with -LotsExplicit to use -lots Y6220110 instead:" -ForegroundColor Yellow
        Write-Host "  .\run_single_lot_validation.ps1 -LotsExplicit"
    }
    exit 1
}
