<#
.SYNOPSIS
Execute UPSVF AQUA pull with Classhot lot filter and trigger ILAS analysis immediately.

.DESCRIPTION
Runs aqua_nvlh_weekly_pull.ps1 with a specific set of Classhot lots (LOTFROMFS filter).
This is an immediate/on-demand execution separate from the scheduled weekly task.

.NOTES
Generated: 2026-06-14
Lots filter: CLASSHOT only (user-provided list)
#>

param(
    [string]$UpsvfScriptPath = "",
    [string]$AquaExe = "\\ger.corp.intel.com\ec\proj\ha\stav\DIS_Downloads\AquaHbase\AquaCMDClient\Client\AquaCmdLine.exe",
    [string]$OutputDirectory = "\\ger\ec\proj\ha\mmgbd\MMGBD_PSA\Products\NVL\NVL-H\Weekly Runs",
    [switch]$SkipIlas = $false
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Classhot lots (LOTFROMFS) for this immediate run
$clashotLots = @(
    "P6240970",
    "P6240980",
    "U622H725",
    "U623B991",
    "U623C006",
    "U623F454",
    "U623G130",
    "U623G225",
    "P621599CR",
    "P623202CR",
    "P6220630",
    "P6220640",
    "P6220660",
    "P6220700",
    "P6220710",
    "P6221080",
    "P6221090",
    "P6230600",
    "P6230790",
    "P6230800",
    "P6230810",
    "P6230820",
    "P6230830",
    "P6230840",
    "P6230850",
    "P6239630RS",
    "P6240430",
    "P6240450",
    "P6240460",
    "P6240470",
    "U622H526",
    "U622H725",
    "U622H906",
    "U622H937",
    "U623B991",
    "U624F172",
    "Y614214CR",
    "Y614231CR",
    "Y622081CR",
    "Y623094CR",
    "Y623101CR",
    "Y6220110",
    "Y6220120",
    "Y6230120",
    "Y6230130",
    "Y6231950RR",
    "Y6231960RR",
    "Y6231970RR"
)

# Resolve script paths
if ([string]::IsNullOrWhiteSpace($UpsvfScriptPath)) {
    $scriptDir = Split-Path -Path $PSCommandPath -Parent
    $UpsvfScriptPath = Join-Path $scriptDir "aqua_nvlh_weekly_pull.ps1"
}

if (-not (Test-Path -LiteralPath $UpsvfScriptPath)) {
    throw "UPSVF script not found: $UpsvfScriptPath"
}

# Navigate from weekly-aqua-pull up to Scripts, then down to parametric-analysis/ilas
$weeklyAquaPullDir = Split-Path -Path $UpsvfScriptPath -Parent
$dataPoolingDir = Split-Path -Path $weeklyAquaPullDir -Parent  # up to data-pulling
$scriptsDir = Split-Path -Path $dataPoolingDir -Parent         # up to Scripts
$IlasScriptPath = Join-Path $scriptsDir "parametric-analysis\ilas\aqua_nvlh_ilas_vmin_analysis.ps1"

if (-not (Test-Path -LiteralPath $IlasScriptPath)) {
    throw "ILAS script not found: $IlasScriptPath"
}

# Build lot filter
$lotsFilter = ($clashotLots | Sort-Object -Unique) -join ","
Write-Host "Running UPSVF with Classhot lot filter..."
Write-Host "Lots count: $($clashotLots.Count) (after deduplication: $(($clashotLots | Sort-Object -Unique).Count))"
Write-Host ""

# Run UPSVF with lot filter
$upsvfArgs = @{
    AquaExe = $AquaExe
    AquaServer = "GER"
    ReportPath = "hmarkovi\BSAT_UPS2_POR_PTL_NVL WW12"
    ProgramPattern = "NVLHM66*"
    Operations = "6248"
    OutputDirectory = $OutputDirectory
    FunctionalBin = "100"
    LastNDaysTestEnd = 2
    RetentionDays = 366
    MaxVisualUnits = 100000
    AquaMaxRows = 150000
    AquaPullTimeoutSeconds = 7200
    AquaPullPollSeconds = 20
    IlasScriptPath = $IlasScriptPath
    LotsOverride = $lotsFilter
    KeepCleanCsvArtifact = $true
}

if ($SkipIlas) {
    $upsvfArgs['SkipIlasStep'] = $true
}

Write-Host "Starting UPSVF AQUA pull (with ILAS merge)..."
Write-Host "Output directory: $OutputDirectory"
Write-Host ""

try {
    & $UpsvfScriptPath @upsvfArgs
    Write-Host ""
    Write-Host "UPSVF and ILAS execution completed successfully"
}
catch {
    $errMsg = $_.Exception.Message
    Write-Host "ERROR: UPSVF execution failed: $errMsg"
    exit 1
}
