#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InputCsv = "R:\Products\NVL\NVL-H\Weekly Runs\Vmin_NVLHM66A0H30N00S623_WW25_2026_merged.csv",
    [string]$OutputDir = ".\output\core-example"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $PSCommandPath
if (-not [System.IO.Path]::IsPathRooted($OutputDir)) {
    $OutputDir = Join-Path $scriptDir $OutputDir
}

function Convert-ToDoubleOrNull {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $s = $Value.Trim().Trim('"')
    $out = 0.0
    if ([double]::TryParse($s, [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$out)) {
        return $out
    }
    return $null
}

function Get-LinearFit {
    param(
        [double[]]$X,
        [double[]]$Y
    )
    $n = $X.Count
    if ($n -lt 2) {
        return [pscustomobject]@{ Slope = $null; Intercept = $null; R2 = $null; Count = $n }
    }

    $sumX = ($X | Measure-Object -Sum).Sum
    $sumY = ($Y | Measure-Object -Sum).Sum
    $sumXY = 0.0
    $sumXX = 0.0
    for ($i = 0; $i -lt $n; $i++) {
        $sumXY += ($X[$i] * $Y[$i])
        $sumXX += ($X[$i] * $X[$i])
    }

    $den = ($n * $sumXX) - ($sumX * $sumX)
    if ([math]::Abs($den) -lt 1e-12) {
        return [pscustomobject]@{ Slope = $null; Intercept = $null; R2 = $null; Count = $n }
    }

    $slope = (($n * $sumXY) - ($sumX * $sumY)) / $den
    $intercept = ($sumY - ($slope * $sumX)) / $n

    $meanY = $sumY / $n
    $ssTot = 0.0
    $ssRes = 0.0
    for ($i = 0; $i -lt $n; $i++) {
        $pred = ($slope * $X[$i]) + $intercept
        $ssTot += [math]::Pow(($Y[$i] - $meanY), 2)
        $ssRes += [math]::Pow(($Y[$i] - $pred), 2)
    }
    $r2 = if ($ssTot -gt 0) { 1.0 - ($ssRes / $ssTot) } else { $null }

    return [pscustomobject]@{
        Slope = $slope
        Intercept = $intercept
        R2 = $r2
        Count = $n
    }
}

function New-ScatterFitChart {
    param(
        [double[]]$X,
        [double[]]$Y,
        [double]$Slope,
        [double]$Intercept,
        [string]$Title,
        [string]$XAxisTitle,
        [string]$YAxisTitle,
        [string]$OutputPath
    )

    Add-Type -AssemblyName System.Windows.Forms.DataVisualization
    $chart = New-Object System.Windows.Forms.DataVisualization.Charting.Chart
    $chart.Width = 1400
    $chart.Height = 900

    $area = New-Object System.Windows.Forms.DataVisualization.Charting.ChartArea
    $area.AxisX.Title = $XAxisTitle
    $area.AxisY.Title = $YAxisTitle
    $area.AxisX.MajorGrid.LineColor = [System.Drawing.Color]::LightGray
    $area.AxisY.MajorGrid.LineColor = [System.Drawing.Color]::LightGray
    $chart.ChartAreas.Add($area)

    $series = New-Object System.Windows.Forms.DataVisualization.Charting.Series
    $series.Name = 'Scatter'
    $series.ChartType = [System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::Point
    $series.MarkerSize = 5
    $series.Color = [System.Drawing.Color]::FromArgb(31, 119, 180)
    foreach ($pt in (0..($X.Count - 1))) {
        [void]$series.Points.AddXY($X[$pt], $Y[$pt])
    }
    $chart.Series.Add($series)

    if ($null -ne $Slope -and $null -ne $Intercept) {
        $xMin = ($X | Measure-Object -Minimum).Minimum
        $xMax = ($X | Measure-Object -Maximum).Maximum

        $fit = New-Object System.Windows.Forms.DataVisualization.Charting.Series
        $fit.Name = 'Fit'
        $fit.ChartType = [System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::Line
        $fit.BorderWidth = 3
        $fit.Color = [System.Drawing.Color]::FromArgb(214, 39, 40)
        [void]$fit.Points.AddXY($xMin, (($Slope * $xMin) + $Intercept))
        [void]$fit.Points.AddXY($xMax, (($Slope * $xMax) + $Intercept))
        $chart.Series.Add($fit)
    }

    $titleObj = New-Object System.Windows.Forms.DataVisualization.Charting.Title
    $titleObj.Text = $Title
    $titleObj.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
    [void]$chart.Titles.Add($titleObj)

    $chart.SaveImage($OutputPath, [System.Windows.Forms.DataVisualization.Charting.ChartImageFormat]::Png)
    $chart.Dispose()
}

function New-LineChart {
    param(
        [double[]]$X,
        [double[]]$Y,
        [string]$Title,
        [string]$XAxisTitle,
        [string]$YAxisTitle,
        [string]$OutputPath
    )

    Add-Type -AssemblyName System.Windows.Forms.DataVisualization
    $chart = New-Object System.Windows.Forms.DataVisualization.Charting.Chart
    $chart.Width = 1400
    $chart.Height = 900

    $area = New-Object System.Windows.Forms.DataVisualization.Charting.ChartArea
    $area.AxisX.Title = $XAxisTitle
    $area.AxisY.Title = $YAxisTitle
    $area.AxisX.MajorGrid.LineColor = [System.Drawing.Color]::LightGray
    $area.AxisY.MajorGrid.LineColor = [System.Drawing.Color]::LightGray
    $chart.ChartAreas.Add($area)

    $series = New-Object System.Windows.Forms.DataVisualization.Charting.Series
    $series.Name = 'Curve'
    $series.ChartType = [System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::Line
    $series.BorderWidth = 3
    $series.Color = [System.Drawing.Color]::FromArgb(44, 160, 44)
    $series.MarkerSize = 8
    $series.MarkerStyle = [System.Windows.Forms.DataVisualization.Charting.MarkerStyle]::Circle

    for ($i = 0; $i -lt $X.Count; $i++) {
        [void]$series.Points.AddXY($X[$i], $Y[$i])
    }
    $chart.Series.Add($series)

    $titleObj = New-Object System.Windows.Forms.DataVisualization.Charting.Title
    $titleObj.Text = $Title
    $titleObj.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
    [void]$chart.Titles.Add($titleObj)

    $chart.SaveImage($OutputPath, [System.Windows.Forms.DataVisualization.Charting.ChartImageFormat]::Png)
    $chart.Dispose()
}

function Add-TextBox {
    param(
        $Slide,
        [string]$Text,
        [float]$Left,
        [float]$Top,
        [float]$Width,
        [float]$Height,
        [int]$FontSize = 18,
        [bool]$Bold = $false
    )

    $shape = $Slide.Shapes.AddTextbox(1, $Left, $Top, $Width, $Height)
    $shape.TextFrame.TextRange.Text = $Text
    $shape.TextFrame.TextRange.Font.Size = $FontSize
    $shape.TextFrame.TextRange.Font.Bold = [int]($Bold)
    return $shape
}

if (-not (Test-Path -LiteralPath $InputCsv)) {
    throw "Input CSV not found: $InputCsv"
}

if (-not (Test-Path -LiteralPath $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

$upmU5Col = 'UPM_0107_DPMH156P48ULVTINVD4_FULLDIE_0950_MED_SORT_U1.U5'
$upmU5S2TCol = 'UPM_0107_DPMH156P48ULVTINVD4_FULLDIE_0950_MED_SORT_U1.U5 S2T'
$devRevU5Col = 'DevRevStep_SORT_U1.U5'
$devRevT0 = '8PY6CVT'
$targetU5S2T = 0.87

Write-Host "Reading header and selecting CR Vmin columns..."
$headerLine = Get-Content -LiteralPath $InputCsv -TotalCount 1
$allCols = $headerLine -split ',' | ForEach-Object { $_.Trim('"') }

$coreCols = @($allCols | Where-Object { $_ -like '*UPSVFPASSFLOW_U1PU5_RCS_CR_*' } | Sort-Object)
if ($coreCols.Count -eq 0) {
    throw 'No Core (CR) U1PU5 UPSVF columns were found.'
}

$requiredCols = @($upmU5Col, $devRevU5Col) + $coreCols
$missing = @($requiredCols | Where-Object { $allCols -notcontains $_ })
if ($missing.Count -gt 0) {
    throw ("Missing required columns: " + ($missing -join ', '))
}

$indexByName = @{}
for ($i = 0; $i -lt $allCols.Count; $i++) {
    $indexByName[$allCols[$i]] = $i
}

$colData = @{}
foreach ($col in $coreCols) {
    $freq = $null
    $core = $null
    if ($col -match '_CR_([0-9]+\.[0-9]+)_([0-9]+)$') {
        $freq = [double]::Parse($matches[1], [System.Globalization.CultureInfo]::InvariantCulture)
        $core = [int]$matches[2]
    }

    $colData[$col] = [pscustomobject]@{
        Column = $col
        Frequency = $freq
        Core = $core
        X = New-Object 'System.Collections.Generic.List[double]'
        Y = New-Object 'System.Collections.Generic.List[double]'
    }
}

$idxUpm = $indexByName[$upmU5Col]
$idxDevRev = $indexByName[$devRevU5Col]

Write-Host "Streaming CSV rows and extracting T0 data for Core Vmin analysis..."
$lineCount = 0
Get-Content -LiteralPath $InputCsv | Select-Object -Skip 1 | ForEach-Object {
    $lineCount++
    $vals = $_ -split ','

    if ($vals.Count -le $idxUpm -or $vals.Count -le $idxDevRev) { return }

    $devrev = $vals[$idxDevRev].Trim('"')
    if ($devrev -ne $devRevT0) { return }

    $upmRaw = Convert-ToDoubleOrNull -Value $vals[$idxUpm]
    if ($null -eq $upmRaw) { return }
    $x = $upmRaw / 9154.0

    foreach ($col in $coreCols) {
        $idx = $indexByName[$col]
        if ($vals.Count -le $idx) { continue }
        $yVal = Convert-ToDoubleOrNull -Value $vals[$idx]
        if ($null -eq $yVal) { continue }
        $bucket = $colData[$col]
        $bucket.X.Add($x)
        $bucket.Y.Add($yVal)
    }
}

Write-Host "Computing linear fits per Core frequency/core column..."
$fitRows = @()
foreach ($col in $coreCols) {
    $bucket = $colData[$col]
    $fit = Get-LinearFit -X $bucket.X.ToArray() -Y $bucket.Y.ToArray()
    $vAtTarget = if ($null -ne $fit.Slope -and $null -ne $fit.Intercept) { ($fit.Slope * $targetU5S2T) + $fit.Intercept } else { $null }

    $fitRows += [pscustomobject]@{
        Domain = 'CR'
        FrequencyGHz = $bucket.Frequency
        Core = $bucket.Core
        VminColumn = $col
        Samples = $fit.Count
        Slope = $fit.Slope
        Intercept = $fit.Intercept
        R2 = $fit.R2
        U5S2T_Target = $targetU5S2T
        Vmin_At_Target = $vAtTarget
    }
}

$fitRows = $fitRows | Sort-Object FrequencyGHz, Core

$summaryRows = $fitRows |
    Where-Object { $null -ne $_.Vmin_At_Target } |
    Group-Object FrequencyGHz |
    ForEach-Object {
        $v = ($_.Group | Measure-Object -Property Vmin_At_Target -Average).Average
        [pscustomobject]@{
            Domain = 'CR'
            Freq = [double]$_.Name
            Vmin = [math]::Round($v, 4)
        }
    } |
    Sort-Object Freq

$fitCsv = Join-Path $OutputDir 'core_vmin_linear_fit_summary.csv'
$summaryCsv = Join-Path $OutputDir 'core_normalized_vf_summary.csv'
$fitRows | Export-Csv -NoTypeInformation -Path $fitCsv -Encoding UTF8
$summaryRows | Export-Csv -NoTypeInformation -Path $summaryCsv -Encoding UTF8

# Charts
$exampleCol = 'VA-IN-NA-GSDS_D_S::UPSVFPASSFLOW_U1PU5_RCS_CR_1.200_2'
if ($coreCols -contains $exampleCol) {
    $ex = $colData[$exampleCol]
    $exFit = $fitRows | Where-Object { $_.VminColumn -eq $exampleCol } | Select-Object -First 1
    $scatterPng = Join-Path $OutputDir 'core_example_scatter_fit.png'
    New-ScatterFitChart -X $ex.X.ToArray() -Y $ex.Y.ToArray() -Slope $exFit.Slope -Intercept $exFit.Intercept `
        -Title "Core CR Example: Vmin vs U5 S2T (T0 only)" `
        -XAxisTitle $upmU5S2TCol -YAxisTitle $exampleCol -OutputPath $scatterPng
}
else {
    $scatterPng = $null
}

$vfPng = Join-Path $OutputDir 'core_normalized_vf_curve.png'
$xFreq = @($summaryRows | ForEach-Object { [double]$_.Freq })
$yVmin = @($summaryRows | ForEach-Object { [double]$_.Vmin })
if ($xFreq.Count -gt 0) {
    New-LineChart -X $xFreq -Y $yVmin -Title 'Core (CR) Normalized VF Curve @ U5 S2T=0.87' `
        -XAxisTitle 'Frequency (GHz)' -YAxisTitle 'Vmin (normalized)' -OutputPath $vfPng
}

# Notebook JSON
$generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
$tablePreview = ($summaryRows | Select-Object -First 20 | ConvertTo-Csv -NoTypeInformation) -join "`n"
$nb = [ordered]@{
    cells = @(
        [ordered]@{
            cell_type = 'markdown'
            metadata = @{ language = 'markdown' }
            source = @(
                '# Core (CR) Vmin Example Analysis',
                "Generated: $generatedAt",
                '',
                'This notebook demonstrates the requested Vmin analysis flow for one domain (Core/CR) using WW25 merged data.',
                '',
                '- Input file: R:\\Products\\NVL\\NVL-H\\Weekly Runs\\Vmin_NVLHM66A0H30N00S623_WW25_2026_merged.csv',
                '- Die mapping: Cdie = U5 (Core/CR)',
                '- U5 normalization: UPM_0107...U1.U5 / 9154 -> U5 S2T',
                '- T0 filter: DevRevStep_SORT_U1.U5 == 8PY6CVT',
                '- Target for U5 S2T: 0.87'
            )
        },
        [ordered]@{
            cell_type = 'code'
            metadata = @{ language = 'python' }
            source = @(
                'import re',
                'import numpy as np',
                'import pandas as pd',
                'import matplotlib.pyplot as plt',
                "csv_path = r'R:\\Products\\NVL\\NVL-H\\Weekly Runs\\Vmin_NVLHM66A0H30N00S623_WW25_2026_merged.csv'",
                "upm_u5_col = 'UPM_0107_DPMH156P48ULVTINVD4_FULLDIE_0950_MED_SORT_U1.U5'",
                "devrev_u5_col = 'DevRevStep_SORT_U1.U5'",
                "target_u5_s2t = 0.87",
                "df = pd.read_csv(csv_path, low_memory=False)",
                "df['UPM_0107_DPMH156P48ULVTINVD4_FULLDIE_0950_MED_SORT_U1.U5 S2T'] = pd.to_numeric(df[upm_u5_col], errors='coerce') / 9154.0",
                "core_cols = sorted([c for c in df.columns if 'UPSVFPASSFLOW_U1PU5_RCS_CR_' in c])",
                "len(core_cols), core_cols[:5]"
            )
        },
        [ordered]@{
            cell_type = 'code'
            metadata = @{ language = 'python' }
            source = @(
                "work = df[df[devrev_u5_col] == '8PY6CVT'].copy()",
                "x_col = 'UPM_0107_DPMH156P48ULVTINVD4_FULLDIE_0950_MED_SORT_U1.U5 S2T'",
                "fit_rows = []",
                "for c in core_cols:",
                "    y = pd.to_numeric(work[c], errors='coerce')",
                "    x = pd.to_numeric(work[x_col], errors='coerce')",
                "    m = x.notna() & y.notna()",
                "    x2 = x[m].values",
                "    y2 = y[m].values",
                "    if len(x2) < 3:",
                "        continue",
                "    slope, intercept = np.polyfit(x2, y2, 1)",
                "    yhat = slope * x2 + intercept",
                "    ss_res = np.sum((y2 - yhat)**2)",
                "    ss_tot = np.sum((y2 - np.mean(y2))**2)",
                "    r2 = 1 - ss_res/ss_tot if ss_tot > 0 else np.nan",
                "    mcol = re.search(r'_CR_([0-9]+\\.[0-9]+)_([0-9]+)$', c)",
                "    freq = float(mcol.group(1)) if mcol else np.nan",
                "    core = int(mcol.group(2)) if mcol else np.nan",
                "    fit_rows.append({'Domain':'CR','Freq':freq,'Core':core,'Column':c,'N':len(x2),'Slope':slope,'Intercept':intercept,'R2':r2,'Vmin_at_0p87':slope*target_u5_s2t+intercept})",
                "fit_df = pd.DataFrame(fit_rows).sort_values(['Freq','Core'])",
                "fit_df.head()"
            )
        },
        [ordered]@{
            cell_type = 'code'
            metadata = @{ language = 'python' }
            source = @(
                "example_col = 'VA-IN-NA-GSDS_D_S::UPSVFPASSFLOW_U1PU5_RCS_CR_1.200_2'",
                "tmp = work[[x_col, example_col]].copy()",
                "tmp[x_col] = pd.to_numeric(tmp[x_col], errors='coerce')",
                "tmp[example_col] = pd.to_numeric(tmp[example_col], errors='coerce')",
                "tmp = tmp.dropna()",
                "slope, intercept = np.polyfit(tmp[x_col].values, tmp[example_col].values, 1)",
                "xline = np.linspace(tmp[x_col].min(), tmp[x_col].max(), 100)",
                "yline = slope*xline + intercept",
                "plt.figure(figsize=(8,6))",
                "plt.scatter(tmp[x_col], tmp[example_col], s=10, alpha=0.5, label='Data')",
                "plt.plot(xline, yline, color='red', linewidth=2, label='Linear fit')",
                "plt.xlabel(x_col)",
                "plt.ylabel(example_col)",
                "plt.title('Core CR example: Vmin vs U5 S2T (T0 only)')",
                "plt.legend()",
                "plt.grid(True, alpha=0.3)",
                "plt.show()"
            )
        },
        [ordered]@{
            cell_type = 'code'
            metadata = @{ language = 'python' }
            source = @(
                "vf = fit_df.groupby('Freq', as_index=False)['Vmin_at_0p87'].mean().rename(columns={'Vmin_at_0p87':'Vmin'})",
                "vf.insert(0, 'Domain', 'CR')",
                "vf = vf.sort_values('Freq')",
                "vf",
                "",
                "plt.figure(figsize=(8,6))",
                "plt.plot(vf['Freq'], vf['Vmin'], marker='o', linewidth=2)",
                "plt.xlabel('Frequency (GHz)')",
                "plt.ylabel('Vmin (normalized)')",
                "plt.title('Core (CR) normalized VF curve @ U5 S2T=0.87')",
                "plt.grid(True, alpha=0.3)",
                "plt.show()"
            )
        },
        [ordered]@{
            cell_type = 'markdown'
            metadata = @{ language = 'markdown' }
            source = @(
                '## Summary Table (from generated PowerShell run)',
                '',
                '```csv',
                $tablePreview,
                '```'
            )
        }
    )
    metadata = @{
        kernelspec = @{ display_name = 'Python 3'; language = 'python'; name = 'python3' }
        language_info = @{ name = 'python' }
    }
    nbformat = 4
    nbformat_minor = 5
}

$nbPath = Join-Path $OutputDir 'core_vmin_example_analysis.ipynb'
($nb | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $nbPath -Encoding UTF8

# PPT generation
$pptPath = Join-Path $OutputDir 'core_vmin_example_analysis.pptx'
$pp = New-Object -ComObject PowerPoint.Application
$pp.Visible = -1
$presentation = $pp.Presentations.Add()

# Slide 1: Overview
$slide1 = $presentation.Slides.Add(1, 12)
[void](Add-TextBox -Slide $slide1 -Text 'Core (CR) Vmin Example Analysis' -Left 30 -Top 20 -Width 900 -Height 50 -FontSize 34 -Bold $true)
$overview = @(
    'Dataset: WW25 merged CSV (NVLHM66A0H30N00S623)',
    'Domain example: Core (CR) -> Cdie (U5)',
    'X-axis: UPM_0107...U1.U5 S2T = UPM/9154',
    'Filter: T0 only (DevRevStep_SORT_U1.U5 = 8PY6CVT)',
    'Linear fit generated per CR frequency/core column',
    'Normalized VF summary uses Vmin at U5 S2T target 0.87'
) -join "`r`n"
[void](Add-TextBox -Slide $slide1 -Text $overview -Left 40 -Top 100 -Width 1180 -Height 420 -FontSize 20)

# Slide 2: Scatter + fit
$slide2 = $presentation.Slides.Add(2, 12)
[void](Add-TextBox -Slide $slide2 -Text 'Example: CR_1.200_2 Vmin vs U5 S2T with Linear Fit' -Left 30 -Top 20 -Width 1200 -Height 40 -FontSize 28 -Bold $true)
if ($scatterPng -and (Test-Path -LiteralPath $scatterPng)) {
    [void]$slide2.Shapes.AddPicture($scatterPng, $false, $true, 60, 90, 1160, 620)
}

# Slide 3: Normalized VF curve
$slide3 = $presentation.Slides.Add(3, 12)
[void](Add-TextBox -Slide $slide3 -Text 'Core (CR) Normalized VF Curve @ U5 S2T=0.87' -Left 30 -Top 20 -Width 1200 -Height 40 -FontSize 28 -Bold $true)
if (Test-Path -LiteralPath $vfPng) {
    [void]$slide3.Shapes.AddPicture($vfPng, $false, $true, 60, 90, 1160, 620)
}

# Slide 4: Summary table
$slide4 = $presentation.Slides.Add(4, 12)
[void](Add-TextBox -Slide $slide4 -Text 'Core (CR) Summary Table (Domain, Freq, Vmin)' -Left 30 -Top 20 -Width 1200 -Height 40 -FontSize 28 -Bold $true)

$rows = [math]::Min($summaryRows.Count + 1, 20)
$cols = 3
$tableShape = $slide4.Shapes.AddTable($rows, $cols, 40, 90, 1160, 580)
$table = $tableShape.Table
$table.Cell(1,1).Shape.TextFrame.TextRange.Text = 'Domain'
$table.Cell(1,2).Shape.TextFrame.TextRange.Text = 'Freq (GHz)'
$table.Cell(1,3).Shape.TextFrame.TextRange.Text = 'Vmin'

for ($i = 0; $i -lt ($rows - 1); $i++) {
    $r = $summaryRows[$i]
    $table.Cell($i + 2, 1).Shape.TextFrame.TextRange.Text = [string]$r.Domain
    $table.Cell($i + 2, 2).Shape.TextFrame.TextRange.Text = ('{0:0.###}' -f $r.Freq)
    $table.Cell($i + 2, 3).Shape.TextFrame.TextRange.Text = ('{0:0.###}' -f $r.Vmin)
}

$presentation.SaveAs($pptPath)
$presentation.Close()
$pp.Quit()

Write-Host "Generated artifacts:"
Write-Host " - $fitCsv"
Write-Host " - $summaryCsv"
if ($scatterPng) { Write-Host " - $scatterPng" }
Write-Host " - $vfPng"
Write-Host " - $nbPath"
Write-Host " - $pptPath"
