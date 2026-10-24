param(
    [string]$Endpoint,
    [string]$OutputRoot = "R:\Products\NVL\NVL-AX\Weekly data pull\Trace based data",
    [string]$FindJobsCsvPath = "",
    [string]$ExcludeLotSuffix = "MV",
    [string]$OutputPrefix = 'trace_classhot_bridge_real_nvlax62a0h25',
    [string[]]$RequiredLots = @(),
    [bool]$SafeMode = $true,
    [int]$MaxMissingLotRetryAttempts = 2,
    [bool]$RequireCcfData = $false,
    [string[]]$RequiredCcfLots = @(),
    [string[]]$RequiredCcfCorners = @('F1', 'F2', 'F3', 'F4', 'F7')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$cli = 'C:\Users\hmarkovi\AppData\Roaming\Code\User\globalStorage\forge-store\mcp-servers\trace-mcp\trace-cli.exe'
if (-not (Test-Path -LiteralPath $cli)) {
    throw "trace-cli not found: $cli"
}

if (-not [string]::IsNullOrWhiteSpace($Endpoint)) {
    $env:TRACE_MCP_ENDPOINT = $Endpoint
}

if ([string]::IsNullOrWhiteSpace($env:TRACE_MCP_ENDPOINT)) {
    throw 'TRACE_MCP_ENDPOINT is empty. Retrieve it with get_cli_endpoint and pass -Endpoint.'
}

function Invoke-TraceTool {
    param(
        [Parameter(Mandatory = $true)][string]$Tool,
        [Parameter(Mandatory = $true)][hashtable]$ToolArgs
    )

    $argsFile = Join-Path $env:TEMP ("trace-" + $Tool + "-" + [guid]::NewGuid().ToString('N') + '.json')
    try {
        $ToolArgs | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $argsFile
        $out = & $cli invoke --tool $Tool --args "@$argsFile"
        if ($LASTEXITCODE -ne 0) {
            throw "$Tool failed (exit $LASTEXITCODE)"
        }
        if ([string]::IsNullOrWhiteSpace($out)) {
            throw "$Tool returned empty stdout"
        }
        return ($out | ConvertFrom-Json)
    }
    finally {
        Remove-Item -LiteralPath $argsFile -ErrorAction SilentlyContinue
    }
}

function Get-OptionalStringProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return "" }
    if ($null -eq $p.Value) { return "" }
    return [string]$p.Value
}

function Get-OptionalPropertyValue {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $DefaultValue = $null
    )

    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $DefaultValue }
    return $p.Value
}

function Split-IntoChunks {
    param(
        [Parameter(Mandatory = $true)][object[]]$Items,
        [Parameter(Mandatory = $true)][int]$ChunkSize
    )

    $chunks = New-Object System.Collections.Generic.List[object[]]
    for ($i = 0; $i -lt $Items.Count; $i += $ChunkSize) {
        $end = [Math]::Min($i + $ChunkSize - 1, $Items.Count - 1)
        $chunk = @($Items[$i..$end])
        $chunks.Add($chunk)
    }
    return $chunks
}

function Get-LotFromJobName {
    param([string]$JobName)

    if ([string]::IsNullOrWhiteSpace($JobName)) { return "" }

    $trimmed = $JobName.Trim()
    $m = [regex]::Match($trimmed, '^(?<Lot>[^_]+)_')
    if ($m.Success) {
        return $m.Groups['Lot'].Value.Trim().ToUpperInvariant()
    }

    return $trimmed.ToUpperInvariant()
}

function Get-LotCoverage {
    param(
        [Parameter(Mandatory = $true)][string[]]$ExpectedLots,
        [Parameter(Mandatory = $true)][string[]]$PresentLots,
        [Parameter(Mandatory = $true)][string]$Stage
    )

    $expectedSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($lot in $ExpectedLots) {
        if (-not [string]::IsNullOrWhiteSpace($lot)) {
            [void]$expectedSet.Add($lot.Trim().ToUpperInvariant())
        }
    }

    $presentSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($lot in $PresentLots) {
        if (-not [string]::IsNullOrWhiteSpace($lot)) {
            [void]$presentSet.Add($lot.Trim().ToUpperInvariant())
        }
    }

    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($lot in $expectedSet) {
        if (-not $presentSet.Contains($lot)) {
            $missing.Add($lot)
        }
    }

    [pscustomobject]@{
        Stage = $Stage
        ExpectedLotCount = $expectedSet.Count
        PresentLotCount = $presentSet.Count
        MissingLotCount = $missing.Count
        ExpectedLots = @($expectedSet | Sort-Object)
        PresentLots = @($presentSet | Sort-Object)
        MissingLots = @($missing | Sort-Object)
    }
}

function Write-AtomicCsv {
    param(
        [Parameter(Mandatory = $true)][object]$Rows,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $tmpPath = "{0}.tmp.{1}" -f $Path, ([guid]::NewGuid().ToString('N'))
    try {
        $rowItems = @()
        if ($Rows -is [System.Collections.IEnumerable] -and -not ($Rows -is [string])) {
            foreach ($item in $Rows) {
                $rowItems += $item
            }
        }
        else {
            $rowItems += $Rows
        }
        $rowItems | Export-Csv -LiteralPath $tmpPath -NoTypeInformation
        Move-Item -LiteralPath $tmpPath -Destination $Path -Force
    }
    catch {
        throw ("Atomic CSV write failed for '{0}': {1}" -f $Path, $_.Exception.Message)
    }
    finally {
        if (Test-Path -LiteralPath $tmpPath) {
            Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-PresentLotsFromRows {
    param([Parameter(Mandatory = $true)][object]$Rows)

    $lots = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $rowItems = if ($Rows -is [System.Collections.IEnumerable] -and -not ($Rows -is [string])) { $Rows } else { @($Rows) }
    foreach ($row in $rowItems) {
        if ($null -eq $row) { continue }
        $jobName = [string]$row.JobName
        if ([string]::IsNullOrWhiteSpace($jobName)) { continue }
        $lot = Get-LotFromJobName -JobName $jobName
        if (-not [string]::IsNullOrWhiteSpace($lot)) {
            [void]$lots.Add($lot)
        }
    }
    return @($lots | Sort-Object)
}

New-Item -Path $OutputRoot -ItemType Directory -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$runDir = Join-Path $OutputRoot ("classhot_nvlax62a0h25_" + $stamp)
New-Item -Path $runDir -ItemType Directory -Force | Out-Null

$find = $null
$resolvedFindCsv = ""

if (-not [string]::IsNullOrWhiteSpace($FindJobsCsvPath)) {
    if (-not (Test-Path -LiteralPath $FindJobsCsvPath)) {
        throw "FindJobsCsvPath not found: $FindJobsCsvPath"
    }
    $resolvedFindCsv = $FindJobsCsvPath
}
else {
    $find = Invoke-TraceTool -Tool 'find_jobs' -ToolArgs @{
        filter = @{
            type = 'Class'
            testProgramNames = 'NVLAX62A0H25'
            operation = '6248'
            processStep = 'CLASSHOT'
            includeSummary = $true
            mostRecent = $false
        }
    }

    $findError = Get-OptionalStringProperty -Object $find -Name 'errorMessage'
    if (-not [string]::IsNullOrWhiteSpace($findError)) {
        throw $findError
    }

    if (-not $find.filePath -or -not (Test-Path -LiteralPath $find.filePath)) {
        throw 'find_jobs did not return a readable filePath for full job list.'
    }

    $resolvedFindCsv = $find.filePath
    if ($find.summaries) {
        $find.summaries | Export-Csv -LiteralPath (Join-Path $runDir 'job_summaries_preview.csv') -NoTypeInformation
    }
    $find | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $runDir 'find_jobs_response.json')
}

Copy-Item -LiteralPath $resolvedFindCsv -Destination (Join-Path $runDir 'find_jobs_full.csv') -Force

$jobRows = Import-Csv -LiteralPath (Join-Path $runDir 'find_jobs_full.csv')
if (-not $jobRows -or $jobRows.Count -eq 0) {
    throw 'find_jobs_full.csv has no rows.'
}

$jobs = @(
    $jobRows | ForEach-Object {
        [pscustomobject]@{
            name = [string]$_.name
            source = if ([string]::IsNullOrWhiteSpace([string]$_.source)) { $null } else { [string]$_.source }
            site = if ([string]::IsNullOrWhiteSpace([string]$_.site)) { $null } else { [string]$_.site }
            dataSource = if ([string]::IsNullOrWhiteSpace([string]$_.dataSource)) { $null } else { [string]$_.dataSource }
            sortDataSource = if ([string]::IsNullOrWhiteSpace([string]$_.sortDataSource)) { $null } else { [string]$_.sortDataSource }
            id = if ([string]::IsNullOrWhiteSpace([string]$_.id)) { $null } else { [string]$_.id }
            sessionSequence = if ([string]::IsNullOrWhiteSpace([string]$_.sessionSequence)) { $null } else { [string]$_.sessionSequence }
        }
    }
)

$expectedLotsFromJobs = @($jobs | ForEach-Object { Get-LotFromJobName -JobName ([string]$_.name) } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
$requiredLotsNormalized = @($RequiredLots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim().ToUpperInvariant() } | Sort-Object -Unique)
if ($requiredLotsNormalized.Count -eq 0) {
    $requiredLotsNormalized = $expectedLotsFromJobs
}

$initialJobCount = $jobs.Count
$excludedByLotSuffixCount = 0
$excludedLotSuffix = if ([string]::IsNullOrWhiteSpace($ExcludeLotSuffix)) { "" } else { $ExcludeLotSuffix.Trim().ToUpperInvariant() }
if (-not [string]::IsNullOrWhiteSpace($excludedLotSuffix)) {
    $keptJobs = New-Object System.Collections.Generic.List[object]
    foreach ($job in $jobs) {
        $lot = Get-LotFromJobName -JobName ([string]$job.name)
        if ($lot.EndsWith($excludedLotSuffix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $excludedByLotSuffixCount++
            continue
        }
        $keptJobs.Add($job)
    }
    $jobs = [object[]]($keptJobs.ToArray())
}

if (-not $jobs -or $jobs.Count -eq 0) {
    throw "No jobs remain after applying lot suffix exclusion: $ExcludeLotSuffix"
}

$findCoverage = Get-LotCoverage -ExpectedLots $requiredLotsNormalized -PresentLots $expectedLotsFromJobs -Stage 'find_jobs'
$findCoverage | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $runDir 'find_jobs_coverage.json')

$coreInstances = @('SICC', '_VMIN_', '_VMINFWCFG', '_DTS', '_LP', 'FUS_UNITINFO_HXX', 'FUS_UNITINFO_GXX', 'FUS_UNITINFO_CXX')
$binInstances = @('FUNCTIONAL_BIN', 'SOFT_BIN', 'HBIN', 'BIN')

$allRows = New-Object System.Collections.Generic.List[object]
$coreTotals = New-Object System.Collections.Generic.List[object]
$binTotals = New-Object System.Collections.Generic.List[object]
$coreNoFilePathJobs = New-Object System.Collections.Generic.List[string]
$binNoFilePathJobs = New-Object System.Collections.Generic.List[string]
$jobErrors = New-Object System.Collections.Generic.List[object]

$jobsByLot = @{}
foreach ($job in $jobs) {
    $lot = Get-LotFromJobName -JobName ([string]$job.name)
    if (-not $jobsByLot.ContainsKey($lot)) {
        $jobsByLot[$lot] = New-Object System.Collections.Generic.List[object]
    }
    $jobsByLot[$lot].Add($job)
}

function Pull-JobData {
    param(
        [Parameter(Mandatory = $true)][object]$Job,
        [Parameter(Mandatory = $true)][int]$JobNumber,
        [object]$AllRows,
        [object]$CoreTotals,
        [object]$BinTotals,
        [object]$CoreNoFilePathJobs,
        [object]$BinNoFilePathJobs,
        [object]$JobErrors
    )

    try {
        $pullCore = Invoke-TraceTool -Tool 'get_test_results' -ToolArgs @{ jobs = @($Job); testInstanceNames = $coreInstances }
        $coreError = Get-OptionalStringProperty -Object $pullCore -Name 'errorMessage'
        if (-not [string]::IsNullOrWhiteSpace($coreError)) {
            throw $coreError
        }
        if ($pullCore.filePath -and (Test-Path -LiteralPath $pullCore.filePath)) {
            $coreChunkPath = Join-Path $runDir ("trace_test_results_core_job_{0:D3}.csv" -f $JobNumber)
            Copy-Item -LiteralPath $pullCore.filePath -Destination $coreChunkPath -Force
            $coreChunkRows = Import-Csv -LiteralPath $coreChunkPath
            foreach ($r in $coreChunkRows) { $AllRows.Add($r) }
        }
        else {
            $CoreNoFilePathJobs.Add([string]$Job.name)
        }

        $CoreTotals.Add([pscustomobject]@{
                JobNumber = $JobNumber
                JobName = $Job.name
                TotalCount = $pullCore.totalCount
                TotalFileRows = $pullCore.totalFileRows
                Truncated = [bool](Get-OptionalPropertyValue -Object $pullCore -Name 'truncated' -DefaultValue $false)
            })

        $pullBin = Invoke-TraceTool -Tool 'get_test_results' -ToolArgs @{ jobs = @($Job); testInstanceNames = $binInstances }
        $binError = Get-OptionalStringProperty -Object $pullBin -Name 'errorMessage'
        if (-not [string]::IsNullOrWhiteSpace($binError)) {
            throw $binError
        }
        if ($pullBin.filePath -and (Test-Path -LiteralPath $pullBin.filePath)) {
            $binChunkPath = Join-Path $runDir ("trace_test_results_bin_job_{0:D3}.csv" -f $JobNumber)
            Copy-Item -LiteralPath $pullBin.filePath -Destination $binChunkPath -Force
            $binChunkRows = Import-Csv -LiteralPath $binChunkPath
            foreach ($r in $binChunkRows) { $AllRows.Add($r) }
        }
        else {
            $BinNoFilePathJobs.Add([string]$Job.name)
        }

        $BinTotals.Add([pscustomobject]@{
                JobNumber = $JobNumber
                JobName = $Job.name
                TotalCount = $pullBin.totalCount
                TotalFileRows = $pullBin.totalFileRows
                Truncated = [bool](Get-OptionalPropertyValue -Object $pullBin -Name 'truncated' -DefaultValue $false)
            })
    }
    catch {
        $JobErrors.Add([pscustomobject]@{
                JobNumber = $JobNumber
                JobName = [string]$Job.name
                Error = [string]$_.Exception.Message
            })
    }
}

for ($ji = 0; $ji -lt $jobs.Count; $ji++) {
    $jobNumber = $ji + 1
    $job = $jobs[$ji]
    Write-Host ("Processing job {0}/{1}: {2}" -f $jobNumber, $jobs.Count, $job.name)

    Pull-JobData -Job $job -JobNumber $jobNumber -AllRows $allRows -CoreTotals $coreTotals -BinTotals $binTotals -CoreNoFilePathJobs $coreNoFilePathJobs -BinNoFilePathJobs $binNoFilePathJobs -JobErrors $jobErrors
}

$presentLotsAfterPull = Get-PresentLotsFromRows -Rows $allRows
$chunkCoverage = Get-LotCoverage -ExpectedLots $requiredLotsNormalized -PresentLots $presentLotsAfterPull -Stage 'post_pull'
$chunkCoverage | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $runDir 'chunk_coverage.json')

$retrySummaries = New-Object System.Collections.Generic.List[object]
if ($SafeMode -and $MaxMissingLotRetryAttempts -gt 0 -and $chunkCoverage.MissingLotCount -gt 0) {
    for ($attempt = 1; $attempt -le $MaxMissingLotRetryAttempts; $attempt++) {
        $missingLotsNow = @($chunkCoverage.MissingLots)
        if ($missingLotsNow.Count -eq 0) { break }

        $jobsToRetry = New-Object System.Collections.Generic.List[object]
        foreach ($lot in $missingLotsNow) {
            if ($jobsByLot.ContainsKey($lot)) {
                foreach ($j in $jobsByLot[$lot]) {
                    $jobsToRetry.Add($j)
                }
            }
        }

        if ($jobsToRetry.Count -eq 0) { break }

        foreach ($retryJob in $jobsToRetry) {
            $retryNum = $jobs.Count + $attempt
            Pull-JobData -Job $retryJob -JobNumber $retryNum -AllRows $allRows -CoreTotals $coreTotals -BinTotals $binTotals -CoreNoFilePathJobs $coreNoFilePathJobs -BinNoFilePathJobs $binNoFilePathJobs -JobErrors $jobErrors
        }

        $presentLotsAfterPull = Get-PresentLotsFromRows -Rows $allRows
        $chunkCoverage = Get-LotCoverage -ExpectedLots $requiredLotsNormalized -PresentLots $presentLotsAfterPull -Stage ('post_pull_retry_' + $attempt)
        $retrySummaries.Add($chunkCoverage)
        if ($chunkCoverage.MissingLotCount -eq 0) { break }
    }
}

if ($SafeMode -and $chunkCoverage.MissingLotCount -gt 0) {
    throw ("Safe mode gate failed after retries. Missing lots at pull stage: {0}" -f (($chunkCoverage.MissingLots -join ', ')))
}

if (-not $allRows -or $allRows.Count -eq 0) {
    throw 'Merged TRACE test-result rows are empty.'
}

$rawAllPath = Join-Path $runDir 'trace_test_results_all_raw.csv'
Write-AtomicCsv -Rows $allRows -Path $rawAllPath

$rawCoverage = Get-LotCoverage -ExpectedLots $requiredLotsNormalized -PresentLots (Get-PresentLotsFromRows -Rows $allRows) -Stage 'raw'
$rawCoverage | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $runDir 'raw_coverage.json')

if ($SafeMode -and $rawCoverage.MissingLotCount -gt 0) {
    throw ("Safe mode gate failed at raw stage. Missing lots: {0}" -f (($rawCoverage.MissingLots -join ', ')))
}

$mergedRows = @($allRows | Group-Object JobName, TestName, VisualId, Value | ForEach-Object { $_.Group | Select-Object -First 1 })
$mergedPath = Join-Path $runDir 'trace_test_results_merged.csv'
Write-AtomicCsv -Rows $mergedRows -Path $mergedPath

$mergedCoverage = Get-LotCoverage -ExpectedLots $requiredLotsNormalized -PresentLots (Get-PresentLotsFromRows -Rows $mergedRows) -Stage 'merged'
$mergedCoverage | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $runDir 'merged_coverage.json')

if ($SafeMode -and $mergedCoverage.MissingLotCount -gt 0) {
    throw ("Safe mode gate failed at merged stage. Missing lots: {0}" -f (($mergedCoverage.MissingLots -join ', ')))
}

$bridge = 'C:\Users\hmarkovi\Downloads\NVLH_Parametric-main\NVLH_Parametric-main\Scripts\parametric-analysis\ilas\trace_classhot_parametric_bridge.ps1'
& $bridge -InputCsvPath $mergedPath -OutputDirectory $runDir -OutputPrefix $OutputPrefix -RequireCcfData:$RequireCcfData -RequiredCcfLots $RequiredCcfLots -RequiredCcfCorners $RequiredCcfCorners

$final = Get-ChildItem -LiteralPath $runDir -Filter ($OutputPrefix + '_final_*.csv') -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$vmin = Get-ChildItem -LiteralPath $runDir -Filter ($OutputPrefix + '_vmin_stage_*.csv') -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$sicc = Get-ChildItem -LiteralPath $runDir -Filter ($OutputPrefix + '_sicc_stage_*.csv') -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1

$summary = [pscustomobject]@{
    RunDirectory = $runDir
    FindCsvUsed = $resolvedFindCsv
    FindTotalCount = if ($null -ne $find) { $find.totalCount } else { $jobRows.Count }
    FindReturnedCount = if ($null -ne $find -and $find.jobs) { $find.jobs.Count } else { $jobRows.Count }
    FindTotalFileRows = if ($null -ne $find) { $find.totalFileRows } else { $jobRows.Count }
    FindTruncated = if ($null -ne $find) { $find.truncated } else { $false }
    FullJobRows = $jobRows.Count
    PullChunkCount = $jobs.Count
    InitialJobRows = $initialJobCount
    ExcludedLotSuffix = $excludedLotSuffix
    ExcludedByLotSuffixCount = $excludedByLotSuffixCount
    OutputPrefix = $OutputPrefix
    CorePullTotalsByChunk = $coreTotals
    BinPullTotalsByChunk = $binTotals
    CoreNoFilePathJobs = $coreNoFilePathJobs
    BinNoFilePathJobs = $binNoFilePathJobs
    JobErrors = $jobErrors
    RetrySummaries = $retrySummaries
    FindCoverage = $findCoverage
    PullCoverage = $chunkCoverage
    RawCoverage = $rawCoverage
    MergedCoverage = $mergedCoverage
    RequireCcfData = $RequireCcfData
    RequiredCcfLots = $RequiredCcfLots
    RequiredCcfCorners = $RequiredCcfCorners
    RawRowCount = $allRows.Count
    MergedRowCount = $mergedRows.Count
    RawAllCsv = $rawAllPath
    MergedInputCsv = $mergedPath
    VminStage = if ($vmin) { $vmin.FullName } else { '' }
    SiccStage = if ($sicc) { $sicc.FullName } else { '' }
    FinalCsv = if ($final) { $final.FullName } else { '' }
}

$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $runDir 'run_summary.json')
$summary | Format-List | Out-String