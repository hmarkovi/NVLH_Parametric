param(
    [string]$TaskName = "Aqua NVLH Weekly Pull",
    [string]$WeeklyScriptPath = "c:\Projects\NVL\.docs\Scripts\data-pulling\weekly-aqua-pull\aqua_nvlh_weekly_pull.ps1",
    [string]$IlasScriptPath = "c:\Projects\NVL\.docs\Scripts\parametric-analysis\ilas\aqua_nvlh_ilas_vmin_analysis.ps1",
    [string]$OutputDirectory = "\\ger\ec\proj\ha\mmgbd\MMGBD_PSA\Products\NVL\NVL-H\Weekly Runs"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "Setting up Windows Task Scheduler for weekly NVLH UPSVF+ILAS automation..."

if (-not (Test-Path -LiteralPath $WeeklyScriptPath)) {
    throw "Weekly script not found: $WeeklyScriptPath"
}
if (-not (Test-Path -LiteralPath $IlasScriptPath)) {
    throw "ILAS script not found: $IlasScriptPath"
}
if (-not (Test-Path -LiteralPath $OutputDirectory)) {
    New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
}

try {
    Unblock-File -LiteralPath $WeeklyScriptPath -ErrorAction SilentlyContinue
    Unblock-File -LiteralPath $IlasScriptPath -ErrorAction SilentlyContinue
}
catch {
    Write-Warning "Could not unblock one or more scripts (continuing): $($_.Exception.Message)"
}

$existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existingTask) {
    Write-Host "Removing existing task: $TaskName"
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false | Out-Null
}

$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At "05:00"

$psCmd = @"
`$ErrorActionPreference = 'Stop'
`$logPath = '{0}'
`$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
`$logFile = Join-Path `$logPath ('Weekly_Run_Log_' + `$timestamp + '.log')
try {{
    & '{1}' -OutputDirectory '{0}' -IlasScriptPath '{2}' -KeepCleanCsvArtifact 2>&1 | Tee-Object -FilePath `$logFile
    exit `$LASTEXITCODE
}} catch {{
    Add-Content -LiteralPath `$logFile -Value ("ERROR: `$($_.Exception.Message)`r`n" + `$_.ScriptStackTrace)
    exit 1
}}
"@ -f $OutputDirectory, $WeeklyScriptPath, $IlasScriptPath

$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command `"$psCmd`""

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RunOnlyIfNetworkAvailable `
    -MultipleInstances IgnoreNew

$task = Register-ScheduledTask `
    -TaskName $TaskName `
    -Trigger $trigger `
    -Action $action `
    -Settings $settings `
    -Description "Weekly AQUA UPSVF pull, ILAS merge, and CSV export for NVL-H" `
    -RunLevel Highest

Write-Host ""
Write-Host "Task created successfully."
Write-Host "  Name: $($task.TaskName)"
Write-Host "  Trigger: Every Sunday at 05:00 (machine local time)"
Write-Host "  Output directory: $OutputDirectory"
Write-Host "  Weekly script: $WeeklyScriptPath"
Write-Host "  ILAS script: $IlasScriptPath"
