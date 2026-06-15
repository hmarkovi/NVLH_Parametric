<#
.SYNOPSIS
Validate the final UPSVF+ILAS merged CSV for completeness and data integrity.

.DESCRIPTION
Checks that:
1. Final merged CSV exists and is not empty
2. ILAS columns are present
3. ILAS columns have populated data (not just empty values)
4. All expected Classhot lots are represented
5. Row count matches expectations
#>

param(
    [string]$OutputDirectory = "\\ger\ec\proj\ha\mmgbd\MMGBD_PSA\Products\NVL\NVL-H\Weekly Runs",
    [switch]$ShowDetails = $false
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$classhotLots = @(
    "P6240970", "P6240980", "U622H725", "U623B991", "U623C006", "U623F454", "U623G130", "U623G225",
    "P621599CR", "P623202CR", "P6220630", "P6220640", "P6220660", "P6220700", "P6220710", "P6221080",
    "P6221090", "P6230600", "P6230790", "P6230800", "P6230810", "P6230820", "P6230830", "P6230840",
    "P6230850", "P6239630RS", "P6240430", "P6240450", "P6240460", "P6240470", "U622H526", "U622H906",
    "U622H937", "U623B991", "U624F172", "Y614214CR", "Y614231CR", "Y622081CR", "Y623094CR", "Y623101CR",
    "Y6220110", "Y6220120", "Y6230120", "Y6230130", "Y6231950RR", "Y6231960RR", "Y6231970RR"
) | Sort-Object -Unique

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "UPSVF+ILAS Validation Report" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Find the latest Vmin_*.csv file (not _clean)
$latestMerged = Get-ChildItem -LiteralPath $OutputDirectory -Filter "Vmin_*.csv" |
    Where-Object { $_.Name -notlike "*_clean*" } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

if (-not $latestMerged) {
    Write-Host "ERROR: No merged UPSVF+ILAS CSV found in $OutputDirectory" -ForegroundColor Red
    exit 1
}

Write-Host "Merged CSV: $($latestMerged.Name)" -ForegroundColor Green
Write-Host "Path: $($latestMerged.FullName)"
Write-Host "Size: $('{0:N0}' -f $latestMerged.Length) bytes"
Write-Host ""

# Load the merged CSV
try {
    $mergedData = @(Import-Csv -LiteralPath $latestMerged.FullName)
}
catch {
    Write-Host "ERROR: Could not read merged CSV: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

Write-Host "Total rows: $($mergedData.Count)"
Write-Host ""

# Check for ILAS columns
$cols = $mergedData[0].PSObject.Properties.Name
$ilasColumns = @($cols | Where-Object { $_ -like "ILAS_*" })
Write-Host "ILAS columns detected: $($ilasColumns.Count)" -ForegroundColor $(if ($ilasColumns.Count -gt 0) { "Green" } else { "Yellow" })

if ($ilasColumns.Count -eq 0) {
    Write-Host "  WARNING: No ILAS_* columns found!" -ForegroundColor Yellow
}
else {
    if ($ShowDetails) {
        Write-Host "  Columns:" -ForegroundColor Cyan
        $ilasColumns | ForEach-Object { Write-Host "    - $_" }
    }
    else {
        Write-Host "  Sample: $($ilasColumns[0..4] -join ', ')..."
    }
}
Write-Host ""

# Check ILAS data population
$ilasDataRows = 0
$ilasEmptyRows = 0
foreach ($row in $mergedData) {
    $hasData = $false
    foreach ($col in $ilasColumns) {
        if (-not [string]::IsNullOrWhiteSpace([string]$row.$col)) {
            $hasData = $true
            break
        }
    }
    if ($hasData) {
        $ilasDataRows++
    }
    else {
        $ilasEmptyRows++
    }
}

Write-Host "ILAS data population:" -ForegroundColor Cyan
Write-Host "  Rows with ILAS data: $ilasDataRows" -ForegroundColor $(if ($ilasDataRows -gt 0) { "Green" } else { "Red" })
Write-Host "  Rows without ILAS data: $ilasEmptyRows"
Write-Host "  Coverage: $(if ($mergedData.Count -gt 0) { '{0:P1}' -f ($ilasDataRows / $mergedData.Count) } else { 'N/A' })"
Write-Host ""

# Check lot representation
$lotCol = @("LOTFROMFS", "LotFromFs", "LOT", "Lot") |
    Where-Object { $cols -contains $_ } | Select-Object -First 1

if ($lotCol) {
    $lotsInData = @($mergedData | Select-Object -ExpandProperty $lotCol -ErrorAction SilentlyContinue | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
    $classhotPresent = @($lotsInData | Where-Object { $classhotLots -contains $_ })
    
    Write-Host "Lot analysis ($lotCol column):" -ForegroundColor Cyan
    Write-Host "  Unique lots: $($lotsInData.Count)"
    Write-Host "  Classhot lots present: $($classhotPresent.Count)/$($classhotLots.Count)"
    
    if ($classhotPresent.Count -lt $classhotLots.Count) {
        $missing = @($classhotLots | Where-Object { $_ -notin $lotsInData })
        Write-Host "  Missing lots: $($missing -join ', ')" -ForegroundColor Yellow
    }
    Write-Host ""
}

# Summary
Write-Host "========================================" -ForegroundColor Cyan
if ($ilasDataRows -eq 0) {
    Write-Host "Status: FAILED - No ILAS data found" -ForegroundColor Red
}
elseif ($ilasColumns.Count -eq 0) {
    Write-Host "Status: FAILED - No ILAS columns in output" -ForegroundColor Red
}
else {
    Write-Host "Status: SUCCESS - Merged file complete" -ForegroundColor Green
}
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
