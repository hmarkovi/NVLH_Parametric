<#
.SYNOPSIS
Parse ILAS VMIN_DTS raw AQUA data into detail and summary CSVs per VisualID unit.

.DESCRIPTION
Transforms stacked ILAS test data (TEST_NAME/TEST_RESULT format) into normalized Vmin, Setter, MaxDTS_C, LP columns.

CHANGES & AUTOMATED FIXES (2026-06-07):
- Opergroup filter: Only CLASSHOT tests retained (filter applied at Aqua pull stage via 6248_CLASSHOT default)
- Test name suffix cleaning: Rows with TEST_NAME ending in '_it' or '_scrb' removed immediately after Aqua pull
  Example filtered rows:
    IPC::SCN_ATOM_CX48::ATSPEED_ATOM_VMIN_K_F1XAT_X_AT_F1_1200_OCC_it
    IPC::SCN_ATOM_CX48::ATSPEED_ATOM_VMIN_K_F1XAT_X_AT_F1_1200_OCC_scrb
- Merge fix: Updated aqua_nvlh_weekly_pull.ps1 with Copy-Item -Force atomic replacement (lines ~480-485)
  Resolves temp-file collision when destination UPSVF+ILAS merge target already exists

CHANGES (2026-06-09):
- IlasReportPath default changed from "sbelyy\ILAS\ILAS_VMIN_DTS" to "hmarkovi\ILAS_VMIN_DTS"
  Reason: previous report path returned no data; hmarkovi path is the correct active report
- Removed -lastNDaysTestEnd from ILAS AQUA query args
  Reason: ILAS data is not date-bounded; date filter caused empty result on certain days
- ILAS AQUA query now uses VisualID as the only filter (removed -lots / -lotsfromfs)
  Reason: combining lot filter + VisualID filter caused AQUA to return no output file
- Post-query guard: if AQUA returns no output file, script throws immediately with clear message
  (previously script would wait the full AquaPullTimeoutSeconds before surfacing the failure)
- Pre-execution guard: if $aquaArgs contains -lots or -lotsfromfs, script throws before running AquaCmdLine
- Reference filtering changed from VisualID+lot key matching to VisualID-only HashSet match
  Reason: aligns post-pull row filtering with the VisualID-only query strategy
- Get-VisualLotReference: lot column is now optional; Keys set removed (no longer used)
  LotsOverride parameter still accepted but is ignored with an explicit warning for ILAS queries

.PARAMETER OpergroupFilter
Default: "6248_CLASSHOT" (ensures only Classhot opergroup data retained)
#>

param(
    [string]$AquaExe = "\\ger.corp.intel.com\ec\proj\ha\stav\DIS_Downloads\AquaHbase\AquaCMDClient\Client\AquaCmdLine.exe",
    [string]$AquaServer = "GER",
    [string]$IlasReportPath = "hmarkovi\ILAS_VMIN_DTS",
    [string]$OpergroupFilter = "6248_CLASSHOT",
    [string]$ProgramPattern = "NVLHM66*",
    [string]$Operations = "6248",
    [string]$OutputDirectory = "\\ger\ec\proj\ha\mmgbd\MMGBD_PSA\Products\NVL\NVL-H\Weekly Runs",
    [string]$FunctionalBin = "100",
    [int]$LastNDaysTestEnd = 7,
    [int]$AquaMaxRows = 0,
    [int]$AquaPullTimeoutSeconds = 3600,
    [int]$AquaPullPollSeconds = 15,
    [int]$VisualIdChunkSize = 750,
    [double]$MinValidVmin = 0.2,
    [double]$MaxValidVmin = 2.0,
    [string]$UpsvfReferenceCsv = "",
    [string]$RawInputFile = "",
    [string]$LotsOverride = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

function Get-VisualLotReference {
    param([string]$UpsvfCsvPath)

    if ([string]::IsNullOrWhiteSpace($UpsvfCsvPath)) {
        return [pscustomobject]@{
            Keys = $null
            VisualIds = @()
            Lots = @()
            UpsvfVisualColumn = ""
            UpsvfLotColumn = ""
        }
    }

    if (-not (Test-Path -LiteralPath $UpsvfCsvPath)) {
        throw "UpsvfReferenceCsv does not exist: $UpsvfCsvPath"
    }

    $rows = @(Import-Csv -LiteralPath $UpsvfCsvPath)
    if ($rows.Count -eq 0) {
        throw "UpsvfReferenceCsv is empty: $UpsvfCsvPath"
    }

    $cols = $rows[0].PSObject.Properties.Name
    $vidCol = Get-FirstExistingColumnName -CandidateNames @("Visual ID", "VISUAL_ID", "VisualId", "VISUALID", "VID", "VisualID") -AvailableNames $cols
    $lotCol = Get-FirstExistingColumnName -CandidateNames @("LOTFROMFS", "LotFromFs", "LOT", "Lot", "SortLot", "SORT_LOT", "LATO_LOT") -AvailableNames $cols

    if (-not $vidCol) {
        throw "UpsvfReferenceCsv is missing a Visual ID column."
    }
    $vidSet = New-Object 'System.Collections.Generic.HashSet[string]'
    $lotSet = New-Object 'System.Collections.Generic.HashSet[string]'

    foreach ($row in $rows) {
        $vid = [string]$row.$vidCol
        if ([string]::IsNullOrWhiteSpace($vid)) {
            continue
        }

        [void]$vidSet.Add($vid.Trim())
        if ($lotCol) {
            $lot = [string]$row.$lotCol
            if (-not [string]::IsNullOrWhiteSpace($lot)) {
                [void]$lotSet.Add($lot.Trim())
            }
        }
    }

    return [pscustomobject]@{
        Keys = $null
        VisualIds = @($vidSet)
        Lots = @($lotSet)
        UpsvfVisualColumn = $vidCol
        UpsvfLotColumn = $lotCol
    }
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

function Assert-NonEmptyFile {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path)) { throw "$Label was not created: $Path" }
    if ((Get-Item -LiteralPath $Path).Length -le 0) { throw "$Label is empty: $Path" }
}

function Wait-ForFileReady {
    param([string]$Path, [int]$TimeoutSeconds, [int]$PollSeconds, [int]$StableChecks = 2)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastLength = -1
    $stableCount = 0
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $Path) {
            $currentLength = (Get-Item -LiteralPath $Path).Length
            if ($currentLength -gt 0 -and $currentLength -eq $lastLength) {
                $stableCount++
                if ($stableCount -ge $StableChecks) { return $true }
            }
            else {
                $stableCount = 0
                $lastLength = $currentLength
            }
        }
        Start-Sleep -Seconds $PollSeconds
    }
    return $false
}

function Resolve-AquaExePathForAutomation {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceAquaExePath
    )
    
    # Cache AquaCmdLine.exe locally and unblock it to eliminate UNC security zone warnings
    # This allows fully unattended execution (e.g., at 5AM via Task Scheduler)
    
    $cacheDir = Join-Path $env:LOCALAPPDATA "NVLH\AquaCmdLine"
    $cachedExe = Join-Path $cacheDir "AquaCmdLine.exe"
    
    # Ensure cache directory exists
    if (-not (Test-Path -LiteralPath $cacheDir)) {
        New-Item -Path $cacheDir -ItemType Directory -Force | Out-Null
    }
    
    # Copy from UNC if not cached, or if source is newer
    $needsCopy = $false
    if (-not (Test-Path -LiteralPath $cachedExe)) {
        $needsCopy = $true
    } else {
        $sourceInfo = Get-Item -LiteralPath $SourceAquaExePath
        $cachedInfo = Get-Item -LiteralPath $cachedExe
        if ($sourceInfo.LastWriteTime -gt $cachedInfo.LastWriteTime) {
            $needsCopy = $true
        }
    }
    
    if ($needsCopy) {
        Copy-Item -LiteralPath $SourceAquaExePath -Destination $cachedExe -Force | Out-Null
        # Unblock the local copy to suppress security warnings
        Unblock-File -LiteralPath $cachedExe -ErrorAction SilentlyContinue
    }
    
    return $cachedExe
}

function Expand-GzipFile {
    param(
        [string]$SourcePath,
        [string]$DestinationPath
    )

    $sourceStream = $null
    $gzipStream = $null
    $destinationStream = $null

    try {
        $sourceStream = [System.IO.File]::OpenRead($SourcePath)
        $gzipStream = New-Object System.IO.Compression.GzipStream($sourceStream, [System.IO.Compression.CompressionMode]::Decompress)
        $destinationStream = [System.IO.File]::Create($DestinationPath)
        $gzipStream.CopyTo($destinationStream)
    }
    finally {
        if ($destinationStream) { $destinationStream.Dispose() }
        if ($gzipStream) { $gzipStream.Dispose() }
        if ($sourceStream) { $sourceStream.Dispose() }
    }
}

function Wait-ForAquaOutputReady {
    param(
        [string]$PreferredPath,
        [int]$TimeoutSeconds,
        [int]$PollSeconds
    )

    $gzipPath = "$PreferredPath.gz"

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastCsvLength = -1
    $lastGzipLength = -1
    $csvStableCount = 0
    $gzipStableCount = 0

    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $PreferredPath) {
            $csvLength = (Get-Item -LiteralPath $PreferredPath).Length
            if ($csvLength -gt 0 -and $csvLength -eq $lastCsvLength) {
                $csvStableCount++
                if ($csvStableCount -ge 2) {
                    return $PreferredPath
                }
            }
            else {
                $csvStableCount = 0
                $lastCsvLength = $csvLength
            }
        }

        if (Test-Path -LiteralPath $gzipPath) {
            $gzipLength = (Get-Item -LiteralPath $gzipPath).Length
            if ($gzipLength -gt 0 -and $gzipLength -eq $lastGzipLength) {
                $gzipStableCount++
                if ($gzipStableCount -ge 2) {
                    Write-Host "Detected compressed AQUA output. Expanding .gz payload..."
                    Expand-GzipFile -SourcePath $gzipPath -DestinationPath $PreferredPath
                    if (Wait-ForFileReady -Path $PreferredPath -TimeoutSeconds 30 -PollSeconds 2) {
                        return $PreferredPath
                    }
                }
            }
            else {
                $gzipStableCount = 0
                $lastGzipLength = $gzipLength
            }
        }

        Start-Sleep -Seconds $PollSeconds
    }

    return $null
}

function Parse-VminFwCfg {
    param([string]$CfgValue)
    $result = @()
    if ([string]::IsNullOrWhiteSpace($CfgValue)) { return $result }

    foreach ($entry in ($CfgValue -split "_")) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        $atParts = $entry -split "@", 2
        $domain  = $atParts[0].Trim()
        $corner = ""
        $flow = ""
        $freqGHz = ""
        if ($atParts.Count -gt 1) {
            $colonParts = $atParts[1] -split ":", 3
            if ($colonParts.Count -ge 1) { $corner = $colonParts[0].Trim() }
            if ($colonParts.Count -ge 2) { $flow = $colonParts[1].Trim() }
            if ($colonParts.Count -ge 3) { $freqGHz = $colonParts[2].Trim() }
        }
        $result += [pscustomobject]@{
            Domain = $domain
            FreqCorner = $corner
            Flow = $flow
            FreqGHz = $freqGHz
        }
    }

    return $result
}

function Parse-TestNameFreqInfo {
    param([string]$TestName)

    if ([string]::IsNullOrWhiteSpace($TestName)) {
        return [pscustomobject]@{ Corner = ""; FreqGHz = "" }
    }

    # Example: ..._FMIN_0400_... => FMIN at 0.400 GHz
    if ($TestName -match '_FMIN_(\d{3,4})(?:_|$)') {
        $mhzRaw = $Matches[1]
        $mhz = 0
        if ([int]::TryParse($mhzRaw, [ref]$mhz)) {
            $ghz = [double]$mhz / 1000.0
            return [pscustomobject]@{
                Corner = "FMIN"
                FreqGHz = $ghz.ToString("0.000", [System.Globalization.CultureInfo]::InvariantCulture)
            }
        }
    }

    return [pscustomobject]@{ Corner = ""; FreqGHz = "" }
}

function Get-MaxDts {
    param([string]$DtsValue)
    if ([string]::IsNullOrWhiteSpace($DtsValue)) { return $null }

    $maxTemp = $null
    foreach ($sensor in ($DtsValue -split "\|")) {
        $parts = $sensor.Trim() -split ":", 2
        if ($parts.Count -lt 2) { continue }

        $tempVal = 0.0
        if ([double]::TryParse($parts[1].Trim(),
                [System.Globalization.NumberStyles]::Any,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [ref]$tempVal)) {
            if ($null -eq $maxTemp -or $tempVal -gt $maxTemp) {
                $maxTemp = $tempVal
            }
        }
    }

    return $maxTemp
}

function Parse-PerCoreVminValues {
    param(
        [string]$VminRaw,
        [double]$MinValue = 0.2,
        [double]$MaxValue = 2.0
    )

    # Handles:
    # - Simple form: 1.150_1.170
    # - Multi-segment form: 0.450_0.450|0.800_0.800|1
    # For multi-segment values, use only the first pipe segment as the
    # effective per-core Vmin vector so index mapping stays aligned with
    # VMINFWCFG entry order.
    if ([string]::IsNullOrWhiteSpace($VminRaw)) { return @() }

    # Single-core form with one numeric value (for example: 0.570)
    # Keep it as core index 0.
    if ($VminRaw -notmatch "\|" -and $VminRaw -notmatch "_") {
        $single = 0.0
        if ([double]::TryParse($VminRaw.Trim(),
                [System.Globalization.NumberStyles]::Any,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [ref]$single) -and $single -ge $MinValue -and $single -le $MaxValue) {
            return @($single)
        }
        return @()
    }

    $pipeSegments = @($VminRaw -split "\|")
    if ($pipeSegments.Count -eq 0) { return @() }
    $primarySegment = [string]$pipeSegments[0]
    if ($null -eq $primarySegment) { return @() }
    $primarySegment = $primarySegment.Trim()
    if ([string]::IsNullOrWhiteSpace($primarySegment)) { return @() }

    $result = @()
    foreach ($part in ($primarySegment -split "_")) {
        $val = 0.0
        if ([double]::TryParse($part.Trim(),
                [System.Globalization.NumberStyles]::Any,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [ref]$val) -and $val -ge $MinValue -and $val -le $MaxValue) {
            $result += $val
        }
        else {
            $result += $null
        }
    }

    return $result
}

function Build-DetailRecordsFromStackedRows {
    param(
        [object[]]$RawRows,
        [string]$VisualIdColumn,
        [string]$LotColumn,
        [string]$TestNameColumn,
        [string]$ResultColumn,
        [double]$MinValidVmin = 0.2,
        [double]$MaxValidVmin = 2.0
    )

    # Group companion rows by (VisualID, base test instance)
    $testLookup = @{}

    foreach ($row in $RawRows) {
        $visualId = [string]$row.$VisualIdColumn
        $lotFromFs = [string]$row.$LotColumn
        $testName = [string]$row.$TestNameColumn
        $result   = [string]$row.$ResultColumn

        if ([string]::IsNullOrWhiteSpace($visualId) -or [string]::IsNullOrWhiteSpace($lotFromFs) -or [string]::IsNullOrWhiteSpace($testName)) {
            continue
        }

        # Rule: only tests with _VMIN_ in instance name are relevant.
        if ($testName -notlike "*_VMIN_*") { continue }

        $upperTest = $testName.ToUpperInvariant()
        $kind = "Base"
        $base = $testName

        if ($upperTest.EndsWith("_DTS")) {
            $kind = "DTS"
            $base = $testName.Substring(0, $testName.Length - 4)
        }
        elseif ($upperTest.EndsWith("_VMINFWCFG")) {
            $kind = "CFG"
            $base = $testName.Substring(0, $testName.Length - 10)
        }
        elseif ($upperTest.EndsWith("_LP")) {
            $kind = "LP"
            $base = $testName.Substring(0, $testName.Length - 3)
        }
        elseif ($upperTest.EndsWith("_IT")) {
            # Metadata row, not the Vmin value row.
            continue
        }

        $key = "{0}||{1}||{2}" -f $visualId, $lotFromFs, $base
        if (-not $testLookup.ContainsKey($key)) {
            $testLookup[$key] = [ordered]@{
                VisualID = $visualId
            LotFromFs = $lotFromFs
                BaseTest = $base
                VminRaw  = ""
                CfgRaw   = ""
                DtsRaw   = ""
                LpRaw    = ""
            }
        }

        switch ($kind) {
            "Base" { if (-not [string]::IsNullOrWhiteSpace($result)) { $testLookup[$key].VminRaw = $result } }
            "CFG"  { if (-not [string]::IsNullOrWhiteSpace($result)) { $testLookup[$key].CfgRaw  = $result } }
            "DTS"  { if (-not [string]::IsNullOrWhiteSpace($result)) { $testLookup[$key].DtsRaw  = $result } }
            "LP"   { if (-not [string]::IsNullOrWhiteSpace($result)) { $testLookup[$key].LpRaw   = $result } }
        }
    }

    $records = New-Object System.Collections.Generic.List[object]

    foreach ($item in $testLookup.Values) {
        if ([string]::IsNullOrWhiteSpace($item.VminRaw)) { continue }
        if ([string]::IsNullOrWhiteSpace($item.CfgRaw)) { continue }

        $cfgList = @(Parse-VminFwCfg -CfgValue $item.CfgRaw)
        if ($cfgList.Count -eq 0) { continue }
        $maxDts  = Get-MaxDts -DtsValue $item.DtsRaw
        $vminValues = @(Parse-PerCoreVminValues -VminRaw $item.VminRaw -MinValue $MinValidVmin -MaxValue $MaxValidVmin)
        $testFreqInfo = Parse-TestNameFreqInfo -TestName $item.BaseTest

        # Keep exact positional correspondence with VMINFWCFG order.
        $pairCount = [Math]::Min($cfgList.Count, $vminValues.Count)
        for ($idx = 0; $idx -lt $pairCount; $idx++) {
            $v = $vminValues[$idx]
            if ($null -eq $v) { continue }

            $domain = $cfgList[$idx].Domain
            $freqCorner = $cfgList[$idx].FreqCorner
            $flow = $cfgList[$idx].Flow
            $freq   = $cfgList[$idx].FreqGHz
            $coreIndex = $idx
            if ($domain -match '(\d+)$') {
                $coreIndex = [int]$Matches[1]
            }

            $records.Add([pscustomobject]@{
                VisualID       = $item.VisualID
                LotFromFs      = $item.LotFromFs
                TestName       = $item.BaseTest
                Domain         = $domain
                FreqCorner     = $freqCorner
                Flow           = $flow
                FreqGHz        = $freq
                TestFreqCorner = $testFreqInfo.Corner
                TestFreqGHz    = $testFreqInfo.FreqGHz
                CoreIndex      = $coreIndex
                Vmin           = $v
                LimiterPattern = $item.LpRaw
                MaxDTS_C       = if ($null -ne $maxDts) { $maxDts } else { "" }
            })
        }
    }

    return $records
}

function Filter-RowsByOpergroup {
    param(
        [object[]]$Rows,
        [string]$OpergroupFilterValue
    )

    if (-not $Rows -or $Rows.Count -eq 0) {
        return @()
    }

    if ([string]::IsNullOrWhiteSpace($OpergroupFilterValue)) {
        return $Rows
    }

    $cols = $Rows[0].PSObject.Properties.Name
    $opergroupCol = @("OPERGROUP", "Opergroup", "OPGROUP", "OpGroup") |
        Where-Object { $cols -contains $_ } | Select-Object -First 1

    if (-not $opergroupCol) {
        Write-Warning "OPERGROUP column not found in ILAS raw data; skipping opergroup filter."
        return $Rows
    }

    $before = $Rows.Count
    $filtered = @($Rows | Where-Object { [string]$_.$opergroupCol -eq $OpergroupFilterValue })
    Write-Host ("Filtered ILAS rows by OPERGROUP={0}: {1} -> {2}" -f $OpergroupFilterValue, $before, $filtered.Count)

    if ($filtered.Count -eq 0) {
        throw "No ILAS rows remain after applying OPERGROUP filter: $OpergroupFilterValue"
    }

    return $filtered
}

function Filter-RowsByTestNameSuffix {
    param(
        [object[]]$Rows,
        [string[]]$ExcludeSuffixes = @("_it", "_scrb")
    )

    if (-not $Rows -or $Rows.Count -eq 0) {
        return @()
    }

    $cols = $Rows[0].PSObject.Properties.Name
    $testNameCol = @("TEST_NAME", "Test Name", "TESTNAME", "TestName") |
        Where-Object { $cols -contains $_ } | Select-Object -First 1

    if (-not $testNameCol) {
        Write-Warning "TEST_NAME column not found; skipping test name suffix filter."
        return $Rows
    }

    $before = $Rows.Count
    $filtered = @(
        $Rows | Where-Object {
            $testName = [string]$_.$testNameCol
            $testNameLower = $testName.ToLowerInvariant()
            foreach ($suffix in $ExcludeSuffixes) {
                if ($testNameLower.EndsWith($suffix)) {
                    return $false
                }
            }
            return $true
        }
    )
    Write-Host ("Filtered ILAS rows by test name suffix {0}: {1} -> {2}" -f ($ExcludeSuffixes -join ","), $before, $filtered.Count)

    return $filtered
}

$runStart = Get-Date
$tempRawFile = ""
$tempChunkFiles = @()
$pulledRawInThisRun = $false
$reference = $null

try {
    if (-not (Test-Path -LiteralPath $OutputDirectory)) {
        New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
    }

    $runStamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $tempRawFile = Join-Path $OutputDirectory ("_ilas_raw_{0}.csv" -f $runStamp)
    $sourceRawFile = ""

    $reference = Get-VisualLotReference -UpsvfCsvPath $UpsvfReferenceCsv

    $visualIdChunks = @()
    if ($reference -and $reference.VisualIds.Count -gt 0) {
        $maxVisualIdsArgLength = 6500
        $chunkBuilder = New-Object System.Collections.Generic.List[string]
        $chunkLength = 0
        foreach ($vidObj in $reference.VisualIds) {
            $vid = ([string]$vidObj).Trim()
            if ([string]::IsNullOrWhiteSpace($vid)) { continue }

            $candidateLength = if ($chunkBuilder.Count -eq 0) { $vid.Length } else { $chunkLength + 1 + $vid.Length }
            $wouldExceedChunkSize = $chunkBuilder.Count -ge $VisualIdChunkSize
            $wouldExceedArgLength = $candidateLength -gt $maxVisualIdsArgLength -and $chunkBuilder.Count -gt 0
            if (($wouldExceedChunkSize -or $wouldExceedArgLength) -and $chunkBuilder.Count -gt 0) {
                $visualIdChunks += ($chunkBuilder -join ",")
                $chunkBuilder.Clear()
                [void]$chunkBuilder.Add($vid)
                $chunkLength = $vid.Length
            }
            else {
                [void]$chunkBuilder.Add($vid)
                $chunkLength = $candidateLength
            }
        }

        if ($chunkBuilder.Count -gt 0) {
            $visualIdChunks += ($chunkBuilder -join ",")
        }

        if ($visualIdChunks.Count -gt 0) {
            Write-Host ("Using {0} VisualID(s) from UPSVF reference for ILAS pull in {1} chunk(s)." -f $reference.VisualIds.Count, $visualIdChunks.Count)
        }
        else {
            throw "No UPSVF Visual IDs found to build ILAS query. VisualID-only filtering is required."
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($LotsOverride)) {
        Write-Warning "LotsOverride was provided but will be ignored for ILAS query. VisualID is the only allowed AQUA filter."
    }

    if ($visualIdChunks.Count -eq 0 -and [string]::IsNullOrWhiteSpace($RawInputFile)) {
        throw "No UPSVF Visual IDs found to build ILAS query. VisualID-only filtering is required."
    }

    if (-not [string]::IsNullOrWhiteSpace($RawInputFile)) {
        if (-not (Test-Path -LiteralPath $RawInputFile)) { throw "Provided RawInputFile does not exist: $RawInputFile" }
        Write-Host "Using existing ILAS raw file: $RawInputFile"
        $sourceRawFile = $RawInputFile
    }
    else {
        if (-not (Test-Path -LiteralPath $AquaExe)) { throw "Aqua executable not found: $AquaExe" }

        # Resolve AquaCmdLine.exe to local cache (eliminates UNC security warnings for unattended execution)
        $AquaExe = Resolve-AquaExePathForAutomation -SourceAquaExePath $AquaExe
        
        Write-Host "Pulling ILAS VMIN_DTS from AQUA..."
        $aquaArgs = @(
            "-aquaserver", $AquaServer,
            "-reportpath", $IlasReportPath,
            "-outputfilename", $tempRawFile,
            "-programNames", $ProgramPattern,
            "-operations", $Operations,
            "-UnitFunctionalBin", $FunctionalBin
        )
        if ($visualIdChunks.Count -eq 1) {
            if ($AquaMaxRows -gt 0) {
                $aquaArgs += @("-dataSampling", [string]$AquaMaxRows)
            }
            $aquaArgs += @("-visualIds", $visualIdChunks[0])

            if (($aquaArgs -contains "-lots") -or ($aquaArgs -contains "-lotsfromfs")) {
                throw "ILAS AQUA query validation failed: lot-based filters are not allowed."
            }

            Write-Host "ILAS AQUA query filters: VisualID only."
            & $AquaExe @aquaArgs

            if (-not (Test-Path -LiteralPath $tempRawFile)) {
                throw "AQUA ILAS query completed without creating an output file. This indicates no ILAS rows were returned for the current query filters."
            }

            Write-Host "Waiting for AQUA output file to be ready..."
            $resolvedRawFile = Wait-ForAquaOutputReady -PreferredPath $tempRawFile -TimeoutSeconds $AquaPullTimeoutSeconds -PollSeconds $AquaPullPollSeconds
            if (-not $resolvedRawFile) { throw "AQUA ILAS output was not ready within $AquaPullTimeoutSeconds seconds: $tempRawFile" }

            $sourceRawFile = $resolvedRawFile
            $pulledRawInThisRun = $true
            Write-Host "AQUA pull complete: $sourceRawFile"
        }
        else {
            Write-Host "ILAS AQUA query filters: VisualID only (chunked mode)."
            $combinedRows = New-Object System.Collections.Generic.List[object]

            for ($i = 0; $i -lt $visualIdChunks.Count; $i++) {
                $chunkIndex = $i + 1
                $chunkFile = Join-Path $OutputDirectory ("_ilas_raw_{0}_part{1:D3}.csv" -f $runStamp, $chunkIndex)
                $tempChunkFiles += $chunkFile

                $chunkArgs = @(
                    "-aquaserver", $AquaServer,
                    "-reportpath", $IlasReportPath,
                    "-outputfilename", $chunkFile,
                    "-programNames", $ProgramPattern,
                    "-operations", $Operations,
                    "-UnitFunctionalBin", $FunctionalBin
                )
                if ($AquaMaxRows -gt 0) {
                    $chunkArgs += @("-dataSampling", [string]$AquaMaxRows)
                }
                $chunkArgs += @("-visualIds", $visualIdChunks[$i])

                if (($chunkArgs -contains "-lots") -or ($chunkArgs -contains "-lotsfromfs")) {
                    throw "ILAS AQUA query validation failed: lot-based filters are not allowed."
                }

                Write-Host ("Running ILAS AQUA chunk {0}/{1}..." -f $chunkIndex, $visualIdChunks.Count)
                & $AquaExe @chunkArgs

                if (-not (Test-Path -LiteralPath $chunkFile)) {
                    throw ("AQUA ILAS chunk {0} completed without creating an output file." -f $chunkIndex)
                }

                $resolvedChunkFile = Wait-ForAquaOutputReady -PreferredPath $chunkFile -TimeoutSeconds $AquaPullTimeoutSeconds -PollSeconds $AquaPullPollSeconds
                if (-not $resolvedChunkFile) {
                    throw ("AQUA ILAS output chunk {0} was not ready within {1} seconds: {2}" -f $chunkIndex, $AquaPullTimeoutSeconds, $chunkFile)
                }

                $chunkRows = @(Import-Csv -LiteralPath $resolvedChunkFile)
                foreach ($row in $chunkRows) { $combinedRows.Add($row) }
                Write-Host ("Chunk {0} rows loaded: {1}" -f $chunkIndex, $chunkRows.Count)
            }

            if ($combinedRows.Count -eq 0) {
                throw "No ILAS rows were returned across all VisualID chunks."
            }

            $combinedRows | Export-Csv -LiteralPath $tempRawFile -NoTypeInformation
            $sourceRawFile = $tempRawFile
            $pulledRawInThisRun = $true
            Write-Host ("AQUA pull complete (chunked): {0} row(s) combined into {1}" -f $combinedRows.Count, $sourceRawFile)
        }
    }

    $rawRows = @(Import-Csv -LiteralPath $sourceRawFile)
    if ($rawRows.Count -eq 0) { throw "ILAS raw file is empty: $sourceRawFile" }
    Write-Host ("Loaded {0} rows from ILAS file." -f $rawRows.Count)

    $rawRows = @(Filter-RowsByOpergroup -Rows $rawRows -OpergroupFilterValue $OpergroupFilter)

    $rawRows = @(Filter-RowsByTestNameSuffix -Rows $rawRows -ExcludeSuffixes @("_it", "_scrb"))

    $allColumns = $rawRows[0].PSObject.Properties.Name

    $visualIdColumn = @("Visual ID", "VISUAL_ID", "VisualId", "VISUALID", "VID") |
        Where-Object { $allColumns -contains $_ } | Select-Object -First 1
    if (-not $visualIdColumn) { throw "Could not find Visual ID column." }

    if ($reference -and $reference.VisualIds -and $reference.VisualIds.Count -gt 0) {
        $visualIdSet = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($vid in $reference.VisualIds) {
            if (-not [string]::IsNullOrWhiteSpace([string]$vid)) {
                [void]$visualIdSet.Add(([string]$vid).Trim())
            }
        }

        $before = $rawRows.Count
        $rawRows = @(
            $rawRows | Where-Object {
                $vid = [string]$_.$visualIdColumn
                if ([string]::IsNullOrWhiteSpace($vid)) { return $false }
                return $visualIdSet.Contains($vid.Trim())
            }
        )
        Write-Host ("Filtered ILAS rows by UPSVF VisualID set: {0} -> {1}" -f $before, $rawRows.Count)
        if ($rawRows.Count -eq 0) {
            throw "No ILAS rows remain after applying UPSVF VisualID filtering."
        }
    }

    $lotColumn = @("LOTFROMFS", "LotFromFs", "LOT", "Lot", "SortLot", "SORT_LOT", "LATO_LOT") |
        Where-Object { $allColumns -contains $_ } | Select-Object -First 1
    if (-not $lotColumn) { throw "Could not find lot/class-lot column in ILAS raw data." }

    $testNameColumn = @("TEST_NAME", "Test Name", "TESTNAME", "TestName") |
        Where-Object { $allColumns -contains $_ } | Select-Object -First 1
    $resultColumn = @("TEST_RESULT", "Test Result", "RESULT", "VALUE") |
        Where-Object { $allColumns -contains $_ } | Select-Object -First 1

    $allRecords = New-Object System.Collections.Generic.List[object]

    if ($testNameColumn -and $resultColumn) {
        Write-Host ("Detected stacked ILAS format ({0}/{1})." -f $testNameColumn, $resultColumn)
        $stackedRecords = @(Build-DetailRecordsFromStackedRows -RawRows $rawRows -VisualIdColumn $visualIdColumn -LotColumn $lotColumn -TestNameColumn $testNameColumn -ResultColumn $resultColumn -MinValidVmin $MinValidVmin -MaxValidVmin $MaxValidVmin)
        foreach ($r in $stackedRecords) { $allRecords.Add($r) }
    }
    else {
        throw "Unsupported ILAS format: expected stacked TEST_NAME + TEST_RESULT columns."
    }

    Write-Host ("Built {0} detail records." -f $allRecords.Count)
    if ($allRecords.Count -eq 0) { throw "No detail records produced after parsing." }

    $maxVminLookup = @{}
    foreach ($rec in $allRecords) {
        # FMIN instances must not participate in main F* (VMINFWCFG) max calculation.
        if ([string]::Equals([string]$rec.TestFreqCorner, "FMIN", [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        $k = "{0}||{1}||{2}||{3}||{4}||{5}||{6}" -f $rec.VisualID, $rec.LotFromFs, $rec.Domain, $rec.FreqCorner, $rec.Flow, $rec.FreqGHz, $rec.CoreIndex
        if (-not $maxVminLookup.ContainsKey($k)) {
            $maxVminLookup[$k] = $rec
            continue
        }

        $current = $maxVminLookup[$k]
        if ($rec.Vmin -gt $current.Vmin) {
            $maxVminLookup[$k] = $rec
            continue
        }

        if ($rec.Vmin -eq $current.Vmin) {
            $recHasLp = -not [string]::IsNullOrWhiteSpace([string]$rec.LimiterPattern)
            $curHasLp = -not [string]::IsNullOrWhiteSpace([string]$current.LimiterPattern)
            if ($recHasLp -and -not $curHasLp) {
                $maxVminLookup[$k] = $rec
                continue
            }

            $recHasDts = -not [string]::IsNullOrWhiteSpace([string]$rec.MaxDTS_C)
            $curHasDts = -not [string]::IsNullOrWhiteSpace([string]$current.MaxDTS_C)
            if ($recHasDts -and -not $curHasDts) {
                $maxVminLookup[$k] = $rec
            }
        }
    }

    $uniqueVisualLots = New-Object 'System.Collections.Generic.SortedSet[string]'
    $uniqueCombos = New-Object 'System.Collections.Generic.SortedSet[string]'
    foreach ($rec in $allRecords) {
        [void]$uniqueVisualLots.Add(("{0}||{1}" -f $rec.VisualID, $rec.LotFromFs))
    }
    foreach ($rec in $maxVminLookup.Values) {
        [void]$uniqueVisualLots.Add(("{0}||{1}" -f $rec.VisualID, $rec.LotFromFs))
        [void]$uniqueCombos.Add("$($rec.Domain)||$($rec.FreqCorner)||$($rec.Flow)||$($rec.FreqGHz)||$($rec.CoreIndex)")
    }

    $fminLookup = @{}
    foreach ($rec in $allRecords) {
        if ([string]::Equals([string]$rec.TestFreqCorner, "FMIN", [System.StringComparison]::OrdinalIgnoreCase) -and -not [string]::IsNullOrWhiteSpace([string]$rec.TestFreqGHz)) {
            $k = "{0}||{1}||{2}||{3}||{4}" -f $rec.VisualID, $rec.LotFromFs, $rec.Domain, $rec.TestFreqGHz, $rec.CoreIndex
            if (-not $fminLookup.ContainsKey($k)) {
                $fminLookup[$k] = $rec
                continue
            }

            $current = $fminLookup[$k]
            if ($rec.Vmin -gt $current.Vmin) {
                $fminLookup[$k] = $rec
                continue
            }

            if ($rec.Vmin -eq $current.Vmin) {
                $recHasLp = -not [string]::IsNullOrWhiteSpace([string]$rec.LimiterPattern)
                $curHasLp = -not [string]::IsNullOrWhiteSpace([string]$current.LimiterPattern)
                if ($recHasLp -and -not $curHasLp) {
                    $fminLookup[$k] = $rec
                    continue
                }

                $recHasDts = -not [string]::IsNullOrWhiteSpace([string]$rec.MaxDTS_C)
                $curHasDts = -not [string]::IsNullOrWhiteSpace([string]$current.MaxDTS_C)
                if ($recHasDts -and -not $curHasDts) {
                    $fminLookup[$k] = $rec
                }
            }
        }
    }

    $uniqueFminCombos = New-Object 'System.Collections.Generic.SortedSet[string]'
    foreach ($rec in $fminLookup.Values) {
        [void]$uniqueFminCombos.Add("$($rec.Domain)||$($rec.TestFreqGHz)||$($rec.CoreIndex)")
    }

    $finalRows = New-Object System.Collections.Generic.List[object]
    foreach ($visualLot in $uniqueVisualLots) {
        $idParts = $visualLot -split "\|\|", 2
        $vid = $idParts[0]
        $lot = $idParts[1]
        $rowData = [ordered]@{ VisualID = $vid; LotFromFs = $lot }

        foreach ($combo in $uniqueCombos) {
            $cparts = $combo -split "\|\|", 5
            $domain = $cparts[0]
            $corner = $cparts[1]
            $flow = $cparts[2]
            $freq = $cparts[3]
            $coreIdx = $cparts[4]
            $lookupKey = "{0}||{1}||{2}||{3}||{4}||{5}||{6}" -f $vid, $lot, $domain, $corner, $flow, $freq, $coreIdx

            $cornerToken = if ([string]::IsNullOrWhiteSpace($corner)) { "NA" } else { ($corner -replace '[^A-Za-z0-9]', '_') }
            $flowToken = if ([string]::IsNullOrWhiteSpace($flow)) { "NA" } else { ($flow -replace '[^A-Za-z0-9]', '_') }
            $freqToken = if ([string]::IsNullOrWhiteSpace($freq)) { "NA" } else { ($freq -replace '[^A-Za-z0-9\.]', '_') }
            $prefix = "{0}_{1}_Flow{2}_Freq{3}_C{4}" -f $domain, $cornerToken, $flowToken, $freqToken, $coreIdx

            if ($maxVminLookup.ContainsKey($lookupKey)) {
                $rec = $maxVminLookup[$lookupKey]
                $rowData["${prefix}_Vmin"] = $rec.Vmin
                $rowData["${prefix}_Setter"] = $rec.TestName
                $rowData["${prefix}_MaxDTS_C"] = $rec.MaxDTS_C
                $rowData["${prefix}_LP"] = $rec.LimiterPattern
            }
            else {
                $rowData["${prefix}_Vmin"] = ""
                $rowData["${prefix}_Setter"] = ""
                $rowData["${prefix}_MaxDTS_C"] = ""
                $rowData["${prefix}_LP"] = ""
            }
        }

        foreach ($combo in $uniqueFminCombos) {
            $cparts = $combo -split "\|\|", 3
            $domain = $cparts[0]
            $freq = $cparts[1]
            $coreIdx = $cparts[2]
            $lookupKey = "{0}||{1}||{2}||{3}||{4}" -f $vid, $lot, $domain, $freq, $coreIdx
            $freqToken = if ([string]::IsNullOrWhiteSpace($freq)) { "NA" } else { ($freq -replace '[^A-Za-z0-9\.]', '_') }
            $prefix = "{0}_FMIN_Freq{1}_C{2}" -f $domain, $freqToken, $coreIdx

            if ($fminLookup.ContainsKey($lookupKey)) {
                $rec = $fminLookup[$lookupKey]
                $rowData["${prefix}_Vmin"] = $rec.Vmin
                $rowData["${prefix}_Setter"] = $rec.TestName
                $rowData["${prefix}_MaxDTS_C"] = $rec.MaxDTS_C
                $rowData["${prefix}_LP"] = $rec.LimiterPattern
            }
            else {
                $rowData["${prefix}_Vmin"] = ""
                $rowData["${prefix}_Setter"] = ""
                $rowData["${prefix}_MaxDTS_C"] = ""
                $rowData["${prefix}_LP"] = ""
            }
        }

        $finalRows.Add([pscustomobject]$rowData)
    }

    $isoInfo = Get-IsoWeekYear -Date (Get-Date)
    $suffix = "WW{0:D2}_{1}" -f $isoInfo.Week, $isoInfo.Year
    if (-not [string]::IsNullOrWhiteSpace($LotsOverride)) {
        $safeLot = ($LotsOverride -replace '[^A-Za-z0-9]', '_')
        $suffix = "{0}_{1}" -f $safeLot, $suffix
    }

    $detailCsv = Join-Path $OutputDirectory ("ILAS_Vmin_Detail_{0}.csv" -f $suffix)
    $finalCsv = Join-Path $OutputDirectory ("ILAS_Vmin_Summary_{0}.csv" -f $suffix)

    $allRecords | Export-Csv -LiteralPath $detailCsv -NoTypeInformation
    $finalRows | Export-Csv -LiteralPath $finalCsv -NoTypeInformation

    Assert-NonEmptyFile -Path $detailCsv -Label "ILAS detail CSV"
    Assert-NonEmptyFile -Path $finalCsv -Label "ILAS summary CSV"

    Write-Host ""
    Write-Host ("Detail CSV  : {0}" -f $detailCsv)
    Write-Host ("Summary CSV : {0}" -f $finalCsv)
    Write-Host ("Units       : {0}" -f $uniqueVisualLots.Count)
    Write-Host ("Domain/Freq : {0}" -f $uniqueCombos.Count)
    Write-Host ("Detail rows : {0}" -f $allRecords.Count)
}
finally {
    foreach ($chunkFile in $tempChunkFiles) {
        if (Test-Path -LiteralPath $chunkFile) {
            Remove-Item -LiteralPath $chunkFile -Force -ErrorAction SilentlyContinue
        }
        $chunkGzipFile = "$chunkFile.gz"
        if (Test-Path -LiteralPath $chunkGzipFile) {
            Remove-Item -LiteralPath $chunkGzipFile -Force -ErrorAction SilentlyContinue
        }
    }

    if ($pulledRawInThisRun -and $tempRawFile -ne "" -and (Test-Path -LiteralPath $tempRawFile)) {
        Remove-Item -LiteralPath $tempRawFile -Force -ErrorAction SilentlyContinue
    }
    if ($pulledRawInThisRun -and $tempRawFile -ne "") {
        $tempRawGzipFile = "$tempRawFile.gz"
        if (Test-Path -LiteralPath $tempRawGzipFile) {
            Remove-Item -LiteralPath $tempRawGzipFile -Force -ErrorAction SilentlyContinue
        }
    }
}
