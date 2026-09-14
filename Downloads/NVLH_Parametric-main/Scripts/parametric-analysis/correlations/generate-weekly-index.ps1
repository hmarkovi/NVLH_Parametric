#Requires -Version 5.1
<#
.SYNOPSIS
Generates a JSON metadata index of all weekly CSV files in the R:\Products\NVL\NVL-H\Weekly Runs directory.

.DESCRIPTION
Scans the Weekly Runs folder for merged and clean CSV files, extracts metadata (row count, unique Visual IDs, 
Classhot TP, ILAS coverage), and writes a _index.json file for use by correlation analysis skills.

.PARAMETER WeeklyRunsPath
Path to the Weekly Runs directory. Defaults to R:\Products\NVL\NVL-H\Weekly Runs

.PARAMETER OutputIndexFile
Path where the index JSON will be written. Defaults to _index.json in WeeklyRunsPath.

.EXAMPLE
.\generate-weekly-index.ps1
.\generate-weekly-index.ps1 -WeeklyRunsPath "R:\Products\NVL\NVL-H\Weekly Runs"
#>

[CmdletBinding()]
param(
    [string]$WeeklyRunsPath = "R:\Products\NVL\NVL-H\Weekly Runs",
    [string]$OutputIndexFile = (Join-Path $WeeklyRunsPath "_index.json")
)

# ===== UTILITY FUNCTIONS =====

function Get-WeekYearFromFilename {
    param([string]$Filename)
    if ($Filename -match '_WW(\d{2})_(\d{4})') {
        return @{
            Week = [int]$matches[1]
            Year = [int]$matches[2]
            WeekYear = "WW$($matches[1])_$($matches[2])"
        }
    }
    return $null
}

function Get-ClasshotTpFromFilename {
    param([string]$Filename)
    if ($Filename -match 'Vmin_([A-Z0-9]+)_WW\d{2}') {
        return $matches[1]
    }
    return $null
}

function Get-CsvMetadata {
    param([string]$CsvPath)
    
    try {
        if (-not (Test-Path $CsvPath)) {
                Write-Verbose "File not found: $CsvPath"
                return $null
            }
        
            $fileItem = Get-Item $CsvPath
            $fileSizeMb = [math]::Round($fileItem.Length / 1MB, 2)
            $lastModified = $fileItem.LastWriteTimeUtc.ToString('o')
        
            # For very large files, use minimal analysis
            if ($fileSizeMb -gt 200) {
                Write-Verbose "Large file ($fileSizeMb MB), lite mode"
                $estimatedRowCount = [int]($fileItem.Length / (30 * 1KB))
                return @{
                    row_count = $estimatedRowCount
                    unique_visual_ids = 0
                    ilas_coverage = 0
                    ilas_columns_count = 0
                    file_size_mb = $fileSizeMb
                    last_modified = $lastModified
                }
            }
        
            # Small files: full analysis
            $data = @(Import-Csv -Path $CsvPath -ErrorAction Stop)
            $rowCount = if ($data.Count -lt 2) { 1 } else { $data.Count }
        
            $uniqueVidCount = 0
            $visualIdProp = $data[0].PSObject.Properties | Where-Object { $_.Name -ieq 'VISUAL_ID' } | Select-Object -First 1
            if ($visualIdProp) {
                $vids = @($data | Select-Object -ExpandProperty $visualIdProp.Name -Unique)
                $uniqueVidCount = $vids.Count
            }
        
            $ilasColumns = $data[0].PSObject.Properties | Where-Object { $_.Name -like 'ILAS_*' } | Select-Object -ExpandProperty Name
            $ilasColumnCount = $ilasColumns.Count
            $rowsWithIlasData = 0
        
            if ($ilasColumnCount -gt 0 -and $rowCount -gt 0) {
                $rowsWithIlasData = @($data | Where-Object { 
                    $hasIlas = $false
                    foreach ($col in $ilasColumns) { 
                        if ([string]::IsNullOrWhiteSpace($_.($col)) -eq $false) { 
                            $hasIlas = $true
                            break 
                        } 
                    }
                    $hasIlas
                }).Count
            }
        
            return @{
                row_count = $rowCount
                unique_visual_ids = $uniqueVidCount
                ilas_coverage = $rowsWithIlasData
                ilas_columns_count = $ilasColumnCount
                file_size_mb = $fileSizeMb
                last_modified = $lastModified
            }
    }
    catch {
        Write-Verbose "Error reading metadata from $CsvPath : $_"
        return $null
    }
}

# ===== MAIN LOGIC =====

Write-Verbose "Starting weekly index generation..."
Write-Verbose "Scanning directory: $WeeklyRunsPath"

if (-not (Test-Path $WeeklyRunsPath -PathType Container)) {
    Write-Error "Weekly Runs directory not found: $WeeklyRunsPath"
    exit 1
}

$indexData = @{
    generated_at = ([datetime]::UtcNow).ToString('o')
    scan_directory = $WeeklyRunsPath
    files = @{}
    summary = @{
        total_weeks = 0
        classhot_tps = @()
    }
}

$csvFiles = Get-ChildItem -Path $WeeklyRunsPath -Filter "Vmin_*_WW*_*.csv" -File
Write-Verbose "Found $($csvFiles.Count) CSV files"

$weekYearGroups = @{}

foreach ($file in $csvFiles) {
    $weekYearInfo = Get-WeekYearFromFilename -Filename $file.Name
    if (-not $weekYearInfo) {
        Write-Verbose "Skipping file (cannot extract week/year): $($file.Name)"
        continue
    }
    
    $isMerged = $file.Name -like "*_merged.csv"
    $isClean = $file.Name -like "*_clean.csv"
    
    if (-not $isMerged -and -not $isClean) {
        Write-Verbose "Skipping file (invalid naming): $($file.Name)"
        continue
    }
    
    $weekYear = $weekYearInfo.WeekYear
    $classhotTp = Get-ClasshotTpFromFilename -Filename $file.Name
    
    Write-Verbose "Processing: $($file.Name)"
    
    if (-not $weekYearGroups.ContainsKey($weekYear)) {
        $weekYearGroups[$weekYear] = @{
            merged = $null
            clean = $null
            classhot_tps = @()
            week = $weekYearInfo.Week
            year = $weekYearInfo.Year
        }
    }
    
    $metadata = Get-CsvMetadata -CsvPath $file.FullName
    if ($null -eq $metadata) {
        Write-Verbose "  [SKIP] Could not read metadata"
        continue
    }
    
    $fileMetadata = @{
        file = $file.Name
        row_count = $metadata.row_count
        unique_visual_ids = $metadata.unique_visual_ids
        classhot_tp = $classhotTp
        ilas_coverage = $metadata.ilas_coverage
        ilas_columns_count = $metadata.ilas_columns_count
        file_size_mb = $metadata.file_size_mb
        last_modified = $metadata.last_modified
    }
    
    if ($isMerged) {
        $weekYearGroups[$weekYear].merged = $fileMetadata
    }
    elseif ($isClean) {
        $weekYearGroups[$weekYear].clean = $fileMetadata
    }
    
    if ($classhotTp -and -not $weekYearGroups[$weekYear].classhot_tps.Contains($classhotTp)) {
        $weekYearGroups[$weekYear].classhot_tps += $classhotTp
    }
    
    Write-Verbose "  [OK] Rows: $($metadata.row_count), Unique VIDs: $($metadata.unique_visual_ids), ILAS: $($metadata.ilas_coverage)/$($metadata.ilas_columns_count)"
}

$allClasshotTps = @()
$allWeeks = @()

foreach ($weekYear in ($weekYearGroups.Keys | Sort-Object -Descending)) {
    $groupData = $weekYearGroups[$weekYear]
    
    $weekEntry = @{}
    if ($groupData.merged) {
        $weekEntry.merged = $groupData.merged
    }
    if ($groupData.clean) {
        $weekEntry.clean = $groupData.clean
    }
    
    $indexData.files[$weekYear] = $weekEntry
    
    $allWeeks += @{
        week_year = $weekYear
        week_num = $groupData.week
        year = $groupData.year
    }
    
    $allClasshotTps += $groupData.classhot_tps
}

$indexData.summary.total_weeks = $weekYearGroups.Count
$indexData.summary.classhot_tps = @($allClasshotTps | Select-Object -Unique | Sort-Object)
$indexData.summary.weeks_list = @($allWeeks | Sort-Object @{Expression='year'; Descending=$true}, @{Expression='week_num'; Descending=$true})

if ($allWeeks.Count -gt 0) {
    $latestWeek = ($allWeeks | Sort-Object @{Expression='year'; Descending=$true}, @{Expression='week_num'; Descending=$true} | Select-Object -First 1)
    $oldestWeek = ($allWeeks | Sort-Object @{Expression='year'; Ascending=$true}, @{Expression='week_num'; Ascending=$true} | Select-Object -First 1)
    $indexData.summary.date_range = @{
        latest_week = $latestWeek.week_year
        oldest_week = $oldestWeek.week_year
    }
}

try {
    $indexJson = $indexData | ConvertTo-Json -Depth 10
    $indexJson | Set-Content -Path $OutputIndexFile -Encoding UTF8 -ErrorAction Stop
    Write-Verbose "[OK] Index written to: $OutputIndexFile"
    Write-Host "[OK] Weekly index generated successfully"
    Write-Host "  Location: $OutputIndexFile"
    Write-Host "  Weeks indexed: $($indexData.summary.total_weeks)"
    if ($indexData.summary.classhot_tps.Count -gt 0) {
        Write-Host "  Classhot TPs: $($indexData.summary.classhot_tps -join ', ')"
    }
}
catch {
    Write-Error "Failed to write index JSON: $_"
    exit 1
}

exit 0

