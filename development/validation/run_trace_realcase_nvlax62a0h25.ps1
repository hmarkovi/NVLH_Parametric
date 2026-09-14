param(
    [string]$Endpoint,
    [string]$OutputRoot = "R:\Products\NVL\NVL-AX\Weekly data pull\Trace based data",
    [string]$FindJobsCsvPath = "",
    [string]$ExcludeLotSuffix = "MV"
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

$coreInstances = @('SICC', '_VMIN_', '_VMINFWCFG', '_DTS', '_LP', 'FUS_UNITINFO_HXX', 'FUS_UNITINFO_GXX', 'FUS_UNITINFO_CXX')
$binInstances = @('FUNCTIONAL_BIN', 'SOFT_BIN', 'HBIN', 'BIN')

$allRows = New-Object System.Collections.Generic.List[object]
$coreTotals = New-Object System.Collections.Generic.List[object]
$binTotals = New-Object System.Collections.Generic.List[object]
$coreNoFilePathJobs = New-Object System.Collections.Generic.List[string]
$binNoFilePathJobs = New-Object System.Collections.Generic.List[string]
$jobErrors = New-Object System.Collections.Generic.List[object]

for ($ji = 0; $ji -lt $jobs.Count; $ji++) {
    $jobNumber = $ji + 1
    $job = $jobs[$ji]
    Write-Host ("Processing job {0}/{1}: {2}" -f $jobNumber, $jobs.Count, $job.name)

    try {
        $pullCore = Invoke-TraceTool -Tool 'get_test_results' -ToolArgs @{ jobs = @($job); testInstanceNames = $coreInstances }
        $coreError = Get-OptionalStringProperty -Object $pullCore -Name 'errorMessage'
        if (-not [string]::IsNullOrWhiteSpace($coreError)) {
            throw $coreError
        }
        if ($pullCore.filePath -and (Test-Path -LiteralPath $pullCore.filePath)) {
            $coreChunkPath = Join-Path $runDir ("trace_test_results_core_job_{0:D3}.csv" -f $jobNumber)
            Copy-Item -LiteralPath $pullCore.filePath -Destination $coreChunkPath -Force
            $coreChunkRows = Import-Csv -LiteralPath $coreChunkPath
            foreach ($r in $coreChunkRows) { $allRows.Add($r) }
        }
        else {
            $coreNoFilePathJobs.Add([string]$job.name)
        }

        $coreTotals.Add([pscustomobject]@{
                JobNumber = $jobNumber
                JobName = $job.name
                TotalCount = $pullCore.totalCount
                TotalFileRows = $pullCore.totalFileRows
                Truncated = [bool](Get-OptionalPropertyValue -Object $pullCore -Name 'truncated' -DefaultValue $false)
            })

        $pullBin = Invoke-TraceTool -Tool 'get_test_results' -ToolArgs @{ jobs = @($job); testInstanceNames = $binInstances }
        $binError = Get-OptionalStringProperty -Object $pullBin -Name 'errorMessage'
        if (-not [string]::IsNullOrWhiteSpace($binError)) {
            throw $binError
        }
        if ($pullBin.filePath -and (Test-Path -LiteralPath $pullBin.filePath)) {
            $binChunkPath = Join-Path $runDir ("trace_test_results_bin_job_{0:D3}.csv" -f $jobNumber)
            Copy-Item -LiteralPath $pullBin.filePath -Destination $binChunkPath -Force
            $binChunkRows = Import-Csv -LiteralPath $binChunkPath
            foreach ($r in $binChunkRows) { $allRows.Add($r) }
        }
        else {
            $binNoFilePathJobs.Add([string]$job.name)
        }

        $binTotals.Add([pscustomobject]@{
                JobNumber = $jobNumber
                JobName = $job.name
                TotalCount = $pullBin.totalCount
                TotalFileRows = $pullBin.totalFileRows
                Truncated = [bool](Get-OptionalPropertyValue -Object $pullBin -Name 'truncated' -DefaultValue $false)
            })
    }
    catch {
        $jobErrors.Add([pscustomobject]@{
                JobNumber = $jobNumber
                JobName = [string]$job.name
                Error = [string]$_.Exception.Message
            })
        continue
    }
}

if (-not $allRows -or $allRows.Count -eq 0) {
    throw 'Merged TRACE test-result rows are empty.'
}

$rawAllPath = Join-Path $runDir 'trace_test_results_all_raw.csv'
$allRows | Export-Csv -LiteralPath $rawAllPath -NoTypeInformation

$mergedRows = @($allRows | Group-Object JobName, TestName, VisualId, Value | ForEach-Object { $_.Group | Select-Object -First 1 })
$mergedPath = Join-Path $runDir 'trace_test_results_merged.csv'
$mergedRows | Export-Csv -LiteralPath $mergedPath -NoTypeInformation

$bridge = 'C:\Users\hmarkovi\Downloads\NVLH_Parametric-main\NVLH_Parametric-main\Scripts\parametric-analysis\ilas\trace_classhot_parametric_bridge.ps1'
& $bridge -InputCsvPath $mergedPath -OutputDirectory $runDir -OutputPrefix 'trace_classhot_bridge_real_nvlax62a0h25'

$final = Get-ChildItem -LiteralPath $runDir -Filter 'trace_classhot_bridge_real_nvlax62a0h25_final_*.csv' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$vmin = Get-ChildItem -LiteralPath $runDir -Filter 'trace_classhot_bridge_real_nvlax62a0h25_vmin_stage_*.csv' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$sicc = Get-ChildItem -LiteralPath $runDir -Filter 'trace_classhot_bridge_real_nvlax62a0h25_sicc_stage_*.csv' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1

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
    CorePullTotalsByChunk = $coreTotals
    BinPullTotalsByChunk = $binTotals
    CoreNoFilePathJobs = $coreNoFilePathJobs
    BinNoFilePathJobs = $binNoFilePathJobs
    JobErrors = $jobErrors
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