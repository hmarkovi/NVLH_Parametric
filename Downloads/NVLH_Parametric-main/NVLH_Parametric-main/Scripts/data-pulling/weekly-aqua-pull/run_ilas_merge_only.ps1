<#
.SYNOPSIS
Run ILAS pull and merge for existing clean UPSVF CSV (functional bin 100 units only).

.DESCRIPTION
Pulls ILAS VMIN_DTS data for the units in the clean UPSVF CSV, filtered to functional bin 100,
then merges ILAS columns back into the clean CSV to create the final Vmin_*.csv output.

This is a standalone ILAS recovery script when the UPSVF+ILAS merge failed during the weekly pull.
#>

param(
    [string]$CleanUpsvfCsv = "\\ger\ec\proj\ha\mmgbd\MMGBD_PSA\Products\NVL\NVL-H\Weekly Runs\Vmin_NVLHM66A0H30N00S623_WW24_2026_clean.csv",
    [string]$OutputDirectory = "\\ger\ec\proj\ha\mmgbd\MMGBD_PSA\Products\NVL\NVL-H\Weekly Runs",
    [string]$AquaExe = "\\ger.corp.intel.com\ec\proj\ha\stav\DIS_Downloads\AquaHbase\AquaCMDClient\Client\AquaCmdLine.exe",
    [string]$AquaServer = "GER",
    [string]$IlasReportPath = "hmarkovi\ILAS_VMIN_DTS",
    [string]$ProgramPattern = "NVLHM66*",
    [string]$Operations = "6248",
    [string]$FunctionalBin = "100",
    [int]$AquaMaxRows = 150000,
    [int]$AquaPullTimeoutSeconds = 7200,
    [int]$AquaPullPollSeconds = 20,
    [int]$LotChunkTargetVisualIds = 2000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "ILAS Pull & Merge (Functional Bin 100)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path -LiteralPath $CleanUpsvfCsv)) {
    throw "Clean UPSVF CSV not found: $CleanUpsvfCsv"
}

Write-Host "Clean UPSVF CSV: $CleanUpsvfCsv"
Write-Host "Functional Bin Filter: $FunctionalBin"
Write-Host "Output Directory: $OutputDirectory"
Write-Host ""

# Resolve ILAS script
$weeklyScriptDir = Split-Path -Path $PSCommandPath -Parent
$dataPoolingDir = Split-Path -Path $weeklyScriptDir -Parent
$scriptsDir = Split-Path -Path $dataPoolingDir -Parent
$IlasScriptPath = Join-Path $scriptsDir "parametric-analysis\ilas\aqua_nvlh_ilas_vmin_analysis.ps1"

if (-not (Test-Path -LiteralPath $IlasScriptPath)) {
    throw "ILAS script not found: $IlasScriptPath"
}

Write-Host "Step 1: Pulling ILAS data (lot-chunked, functional bin $FunctionalBin)..."
Write-Host ""

$ilasOutDir = Join-Path $OutputDirectory ("_ilas_recovery_{0}" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
if (-not (Test-Path -LiteralPath $ilasOutDir)) {
    New-Item -Path $ilasOutDir -ItemType Directory -Force | Out-Null
}

try {
    & $IlasScriptPath `
        -AquaExe $AquaExe `
        -AquaServer $AquaServer `
        -IlasReportPath $IlasReportPath `
        -ProgramPattern $ProgramPattern `
        -Operations $Operations `
        -FunctionalBin $FunctionalBin `
        -AquaMaxRows $AquaMaxRows `
        -AquaPullTimeoutSeconds $AquaPullTimeoutSeconds `
        -AquaPullPollSeconds $AquaPullPollSeconds `
        -LotChunkTargetVisualIds $LotChunkTargetVisualIds `
        -OutputDirectory $ilasOutDir `
        -UpsvfReferenceCsv $CleanUpsvfCsv

    Write-Host ""
    Write-Host "Step 2: Locating ILAS summary for merge..."
    Write-Host ""

    $ilasSummaryPath = Get-ChildItem -LiteralPath $ilasOutDir -Filter "ILAS_Vmin_Summary_*.csv" -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1 -ExpandProperty FullName

    if (-not $ilasSummaryPath) {
        throw "ILAS summary CSV was not generated in $ilasOutDir"
    }

    Write-Host "ILAS Summary: $(Split-Path -Path $ilasSummaryPath -Leaf)"
    Write-Host ""

    # Load both CSVs for merge
    Write-Host "Step 3: Merging ILAS data into clean UPSVF CSV..."
    Write-Host ""

    $upsRows = @(Import-Csv -LiteralPath $CleanUpsvfCsv)
    $ilasRows = @(Import-Csv -LiteralPath $ilasSummaryPath)

    if ($upsRows.Count -eq 0) { throw "Clean UPSVF CSV is empty" }
    if ($ilasRows.Count -eq 0) { throw "ILAS summary CSV is empty" }

    Write-Host "  UPSVF rows: $($upsRows.Count)"
    Write-Host "  ILAS rows: $($ilasRows.Count)"
    Write-Host ""

    # Helper function: get Visual+Lot key
    function Get-VisualLotKey {
        param([string]$VisualId, [string]$Lot)
        return ("{0}||{1}" -f $VisualId.Trim(), $Lot.Trim())
    }

    # Helper function: get first existing column
    function Get-FirstExistingColumnName {
        param(
            [string[]]$CandidateNames,
            [string[]]$AvailableNames
        )
        foreach ($candidate in $CandidateNames) {
            if ($AvailableNames -contains $candidate) {
                return $candidate
            }
        }
        return $null
    }

    $upsCols = $upsRows[0].PSObject.Properties.Name
    $ilasCols = $ilasRows[0].PSObject.Properties.Name

    $upsVidCol = Get-FirstExistingColumnName -CandidateNames @("Visual ID", "VISUAL_ID", "VisualId", "VISUALID", "VID", "VisualID") -AvailableNames $upsCols
    $upsLotCol = Get-FirstExistingColumnName -CandidateNames @("LOTFROMFS", "LotFromFs", "LOT", "Lot", "SortLot", "SORT_LOT", "LATO_LOT") -AvailableNames $upsCols
    $ilasVidCol = Get-FirstExistingColumnName -CandidateNames @("Visual ID", "VISUAL_ID", "VisualId", "VISUALID", "VID", "VisualID") -AvailableNames $ilasCols
    $ilasLotCol = Get-FirstExistingColumnName -CandidateNames @("LotFromFs", "LOTFROMFS", "LOT", "Lot", "SortLot", "SORT_LOT", "LATO_LOT") -AvailableNames $ilasCols

    if (-not $upsVidCol -or -not $upsLotCol) {
        throw "UPSVF CSV must contain Visual ID and lot columns."
    }
    if (-not $ilasVidCol -or -not $ilasLotCol) {
        throw "ILAS summary must contain Visual ID and LotFromFs columns."
    }

    # Build ILAS lookup
    $ilasDataColumns = @($ilasCols | Where-Object { $_ -ne $ilasVidCol -and $_ -ne $ilasLotCol })
    $ilasLookup = @{}
    foreach ($r in $ilasRows) {
        $vid = [string]$r.$ilasVidCol
        $lot = [string]$r.$ilasLotCol
        if ([string]::IsNullOrWhiteSpace($vid) -or [string]::IsNullOrWhiteSpace($lot)) { continue }
        $key = Get-VisualLotKey -VisualId $vid -Lot $lot
        $ilasLookup[$key] = $r
    }

    # Add ILAS columns to UPSVF rows
    $ilasPrefixedColumns = @($ilasDataColumns | ForEach-Object { "ILAS_{0}" -f $_ })
    $matchedByVisualLot = 0

    foreach ($row in $upsRows) {
        foreach ($col in $ilasPrefixedColumns) {
            $row | Add-Member -NotePropertyName $col -NotePropertyValue "" -Force
        }

        $vid = [string]$row.$upsVidCol
        $lot = [string]$row.$upsLotCol
        if ([string]::IsNullOrWhiteSpace($vid) -or [string]::IsNullOrWhiteSpace($lot)) { continue }

        $key = Get-VisualLotKey -VisualId $vid -Lot $lot
        if (-not $ilasLookup.ContainsKey($key)) { continue }
        $matchedByVisualLot++

        $ilasRow = $ilasLookup[$key]
        foreach ($srcCol in $ilasDataColumns) {
            $dstCol = "ILAS_{0}" -f $srcCol
            $row.$dstCol = $ilasRow.$srcCol
        }
    }

    # Count rows with ILAS data
    $rowsWithIlasData = 0
    foreach ($row in $upsRows) {
        $hasIlasData = $false
        foreach ($col in $ilasPrefixedColumns) {
            if (-not [string]::IsNullOrWhiteSpace([string]$row.$col)) {
                $hasIlasData = $true
                break
            }
        }
        if ($hasIlasData) {
            $rowsWithIlasData++
        }
    }

    Write-Host "  Matched Visual+Lot keys: $matchedByVisualLot"
    Write-Host "  Rows with ILAS data: $rowsWithIlasData"
    Write-Host ""

    if ($rowsWithIlasData -eq 0) {
        throw "ILAS merge produced zero populated ILAS fields. Check Visual/Lot key normalization."
    }

    # Export merged result
    $isoInfo = Get-IsoWeekYear -Date (Get-Date)
    $isoWeek = $isoInfo.Week
    $year = $isoInfo.Year
    $mergedCsvName = "Vmin_NVLHM66A0H30N00S623_WW{0:D2}_{1}.csv" -f $isoWeek, $year
    $mergedCsvPath = Join-Path $OutputDirectory $mergedCsvName

    $upsRows | Export-Csv -LiteralPath $mergedCsvPath -NoTypeInformation

    if (-not (Test-Path -LiteralPath $mergedCsvPath)) {
        throw "Failed to create merged CSV: $mergedCsvPath"
    }

    $fileSize = (Get-Item -LiteralPath $mergedCsvPath).Length / 1MB

    Write-Host "========================================" -ForegroundColor Green
    Write-Host "Step 4: Merge Complete!" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Final Output: $mergedCsvName" -ForegroundColor Green
    Write-Host "Path: $mergedCsvPath"
    Write-Host "Size: $($fileSize | ForEach-Object { '{0:N2}' -f $_ }) MB"
    Write-Host "Rows: $($upsRows.Count)"
    Write-Host "ILAS Columns: $($ilasPrefixedColumns.Count)"
    Write-Host "ILAS Data Coverage: $($rowsWithIlasData)/$($upsRows.Count) rows"
    Write-Host ""
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

function Get-IsoWeekYear {
    param([datetime]$Date)
    $isoWeekType = [type]::GetType("System.Globalization.ISOWeek")
    if ($isoWeekType) {
        return [pscustomobject]@{
            Week = [System.Globalization.ISOWeek]::GetWeekOfYear($Date)
            Year = [System.Globalization.ISOWeek]::GetYear($Date)
        }
    }

    $cal = [System.Globalization.CultureInfo]::InvariantCulture.Calendar
    $dateForWeek = $Date
    if ($Date.DayOfWeek -in @([System.DayOfWeek]::Monday, [System.DayOfWeek]::Tuesday, [System.DayOfWeek]::Wednesday)) {
        $dateForWeek = $Date.AddDays(3)
    }

    return [pscustomobject]@{
        Week = $cal.GetWeekOfYear($dateForWeek, [System.Globalization.CalendarWeekRule]::FirstFourDayWeek, [System.DayOfWeek]::Monday)
        Year = $dateForWeek.Year
    }
}
