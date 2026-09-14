#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InputCsv = "R:\Products\NVL\NVL-H\Weekly Runs\Vmin_NVLHM66A0H30N00S623_WW25_2026_clean all products.csv",
    [string]$OutputDir = ".\output\vmin-all-products-validation"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $PSCommandPath
if (-not [System.IO.Path]::IsPathRooted($OutputDir)) {
    $OutputDir = Join-Path $scriptDir $OutputDir
}
if (-not (Test-Path -LiteralPath $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}
$plotsDir = Join-Path $OutputDir 'plots'
if (-not (Test-Path -LiteralPath $plotsDir)) {
    New-Item -ItemType Directory -Path $plotsDir -Force | Out-Null
}
$overlayDir = Join-Path $plotsDir 'overlay_by_product_domain_freq'
$vfDir = Join-Path $plotsDir 'vf_by_product_domain'
foreach ($dir in @($overlayDir, $vfDir)) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

function Convert-ToDoubleOrNull {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $s = $Value.Trim().Trim('"')
    $num = 0.0
    if ([double]::TryParse($s, [System.Globalization.NumberStyles]::Any, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$num)) {
        return $num
    }
    return $null
}

function Get-Median {
    param([double[]]$Values)
    if ($Values.Count -eq 0) { return $null }
    $sorted = $Values | Sort-Object
    $n = $sorted.Count
    if ($n % 2 -eq 1) { return $sorted[($n - 1) / 2] }
    return ($sorted[$n / 2 - 1] + $sorted[$n / 2]) / 2.0
}

function Get-LinearFit {
    param([double[]]$X, [double[]]$Y)
    $n = $X.Count
    if ($n -lt 3) {
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
    [pscustomobject]@{ Slope = $slope; Intercept = $intercept; R2 = $r2; Count = $n }
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

function New-MultiCoreScatterFitChart {
    param(
        [object[]]$CoreSeries,
        [string]$Title,
        [string]$XAxisTitle,
        [string]$YAxisTitle,
        [string]$OutputPath
    )

    Add-Type -AssemblyName System.Windows.Forms.DataVisualization
    $chart = New-Object System.Windows.Forms.DataVisualization.Charting.Chart
    $chart.Width = 1600
    $chart.Height = 1000

    $area = New-Object System.Windows.Forms.DataVisualization.Charting.ChartArea
    $area.AxisX.Title = $XAxisTitle
    $area.AxisY.Title = $YAxisTitle
    $area.AxisX.MajorGrid.LineColor = [System.Drawing.Color]::LightGray
    $area.AxisY.MajorGrid.LineColor = [System.Drawing.Color]::LightGray
    $chart.ChartAreas.Add($area)

    $legend = New-Object System.Windows.Forms.DataVisualization.Charting.Legend
    $legend.Docking = [System.Windows.Forms.DataVisualization.Charting.Docking]::Bottom
    $chart.Legends.Add($legend)

    $palette = @(
        [System.Drawing.Color]::FromArgb(31, 119, 180),
        [System.Drawing.Color]::FromArgb(255, 127, 14),
        [System.Drawing.Color]::FromArgb(44, 160, 44),
        [System.Drawing.Color]::FromArgb(214, 39, 40),
        [System.Drawing.Color]::FromArgb(148, 103, 189),
        [System.Drawing.Color]::FromArgb(140, 86, 75)
    )

    $colorIdx = 0
    foreach ($core in ($CoreSeries | Sort-Object Core)) {
        $clr = $palette[$colorIdx % $palette.Count]
        $colorIdx++

        $sData = New-Object System.Windows.Forms.DataVisualization.Charting.Series
        $sData.Name = ("Core {0} data" -f $core.Core)
        $sData.ChartType = [System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::Point
        $sData.MarkerSize = 5
        $sData.Color = $clr
        $sData.LegendText = $sData.Name
        for ($i = 0; $i -lt $core.X.Count; $i++) {
            [void]$sData.Points.AddXY($core.X[$i], $core.Y[$i])
        }
        $chart.Series.Add($sData)

        if ($null -ne $core.Slope -and $null -ne $core.Intercept -and $core.X.Count -gt 0) {
            $xMin = ($core.X | Measure-Object -Minimum).Minimum
            $xMax = ($core.X | Measure-Object -Maximum).Maximum
            $sFit = New-Object System.Windows.Forms.DataVisualization.Charting.Series
            $sFit.Name = ("Core {0} fit" -f $core.Core)
            $sFit.ChartType = [System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::Line
            $sFit.BorderWidth = 3
            $sFit.Color = $clr
            $sFit.LegendText = $sFit.Name
            [void]$sFit.Points.AddXY($xMin, (($core.Slope * $xMin) + $core.Intercept))
            [void]$sFit.Points.AddXY($xMax, (($core.Slope * $xMax) + $core.Intercept))
            $chart.Series.Add($sFit)
        }
    }

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

function Get-DieConfigByDomain {
    param(
        [string]$Domain,
        [string]$UpmU5Col,
        [string]$UpmU2Col,
        [string]$UpmU4Col
    )

    if ($Domain -in @('GT', 'GTVPG')) {
        return [pscustomobject]@{
            Die = 'GTDIE'
            UpmCol = $UpmU4Col
            UpmLabel = $UpmU4Col
            NormalizeDivisor = $null
            Target = 0.85
        }
    }

    if ($Domain -in @('AT', 'CR', 'CCF', 'CLR') -or $Domain -like 'CR*') {
        return [pscustomobject]@{
            Die = 'CDIE'
            UpmCol = $UpmU5Col
            UpmLabel = ($UpmU5Col + ' S2T')
            NormalizeDivisor = 9154.0
            Target = 0.87
        }
    }

    return [pscustomobject]@{
        Die = 'HUBDIE'
        UpmCol = $UpmU2Col
        UpmLabel = $UpmU2Col
        NormalizeDivisor = $null
        Target = 0.85
    }
}

if (-not (Test-Path -LiteralPath $InputCsv)) {
    throw "Input CSV not found: $InputCsv"
}

Write-Host 'Reading header and identifying schema...'
$headerLine = Get-Content -LiteralPath $InputCsv -TotalCount 1
$allCols = $headerLine -split ',' | ForEach-Object { $_.Trim('"') }
$indexByName = @{}
for ($i = 0; $i -lt $allCols.Count; $i++) {
    $indexByName[$allCols[$i]] = $i
}

$prodCol = if ($indexByName.ContainsKey('prod')) { 'prod' } elseif ($indexByName.ContainsKey('product')) { 'product' } else { throw 'Could not find product grouping column (prod/product).' }
$upmU5Col = 'UPM_0107_DPMH156P48ULVTINVD4_FULLDIE_0950_MED_SORT_U1.U5'
$upmU2Col = ($allCols | Where-Object { $_ -like 'TPI_UPM::UPM_X_SCREEN_K_START_X_X_X_X_FEM_CALC_UPM_FEM_*FULLDIE_PDK0P9_0950MV_SORT_U1.U2' } | Select-Object -First 1)
$upmU4Col = ($allCols | Where-Object { $_ -like 'TPI_UPM::UPM_X_SCREEN_K_START_X_X_X_X_FEM_CALC_UPM_FEM_*FULLDIE_PDK0P9_0950MV_SORT_U1.U4' } | Select-Object -First 1)
if (-not $indexByName.ContainsKey($upmU5Col)) { throw "Required U5 UPM column missing: $upmU5Col" }
if ([string]::IsNullOrWhiteSpace($upmU2Col)) { throw 'Required U2 UPM column not found.' }
if ([string]::IsNullOrWhiteSpace($upmU4Col)) { throw 'Required U4 UPM column not found.' }

$vminCols = @($allCols | Where-Object { $_ -like 'UPSVF-HOT_*' })
if ($vminCols.Count -eq 0) {
    throw 'No UPSVF-HOT Vmin columns found.'
}

$metaList = @()
foreach ($col in $vminCols) {
    if ($col -notmatch '^UPSVF-HOT_([^_]+)_([0-9]+(?:\.[0-9]+)?)_([0-9]+)$') { continue }
    $domain = $matches[1]
    $freq = [double]::Parse($matches[2], [System.Globalization.CultureInfo]::InvariantCulture)
    $core = [int]$matches[3]
    $cfg = Get-DieConfigByDomain -Domain $domain -UpmU5Col $upmU5Col -UpmU2Col $upmU2Col -UpmU4Col $upmU4Col
    $metaList += [pscustomobject]@{
        VminColumn = $col
        Domain = $domain
        FrequencyGHz = $freq
        Core = $core
        Die = $cfg.Die
        UpmCol = $cfg.UpmCol
        UpmLabel = $cfg.UpmLabel
        NormalizeDivisor = $cfg.NormalizeDivisor
        Target = $cfg.Target
    }
}
if ($metaList.Count -eq 0) {
    throw 'No Vmin columns could be parsed from the all-products clean file.'
}
Write-Host ("Mapped Vmin columns: {0}" -f $metaList.Count)

$uniqueUpmCols = @($metaList | Select-Object -ExpandProperty UpmCol -Unique)
$upmAccumulators = @{}
foreach ($uc in $uniqueUpmCols) {
    $upmAccumulators[$uc] = New-Object 'System.Collections.Generic.List[double]'
}

Write-Host 'Pre-pass: collecting UPM population for 3-sigma bounds...'
Get-Content -LiteralPath $InputCsv | Select-Object -Skip 1 | ForEach-Object {
    $vals = $_ -split ','
    foreach ($uc in $uniqueUpmCols) {
        $idx = $indexByName[$uc]
        if ($vals.Count -le $idx) { continue }
        $v = Convert-ToDoubleOrNull -Value $vals[$idx]
        if ($null -ne $v) {
            $upmAccumulators[$uc].Add($v)
        }
    }
}

$upmBounds = @{}
foreach ($uc in $uniqueUpmCols) {
    $arr = $upmAccumulators[$uc].ToArray()
    if ($arr.Count -lt 4) { continue }
    $med = Get-Median -Values $arr
    $mean = ($arr | Measure-Object -Average).Average
    $sumSq = 0.0
    foreach ($v in $arr) { $sumSq += ($v - $mean) * ($v - $mean) }
    $sigma = [math]::Sqrt($sumSq / $arr.Count)
    $upmBounds[$uc] = [pscustomobject]@{
        Median = $med
        Sigma = $sigma
        Low = $med - 3.0 * $sigma
        High = $med + 3.0 * $sigma
        N = $arr.Count
    }
}

$fitAccumulator = @{}
$productRowCounts = @{}
$outlierSummaryByProduct = @{}
$outlierTotals = [ordered]@{
    VminOutOfRange_Excluded = 0
    UpmOutlier_Excluded = 0
    Accepted = 0
}

Write-Host 'Streaming all material and grouping by product...'
Get-Content -LiteralPath $InputCsv | Select-Object -Skip 1 | ForEach-Object {
    $vals = $_ -split ','
    if ($vals.Count -le $indexByName[$prodCol]) { return }

    $prod = $vals[$indexByName[$prodCol]].Trim('"')
    if ([string]::IsNullOrWhiteSpace($prod)) { return }

    if (-not $productRowCounts.ContainsKey($prod)) { $productRowCounts[$prod] = 0 }
    $productRowCounts[$prod]++

    if (-not $outlierSummaryByProduct.ContainsKey($prod)) {
        $outlierSummaryByProduct[$prod] = [ordered]@{ VminOutOfRange_Excluded = 0; UpmOutlier_Excluded = 0; Accepted = 0 }
    }

    foreach ($m in $metaList) {
        $idxV = $indexByName[$m.VminColumn]
        $idxU = $indexByName[$m.UpmCol]
        if ($vals.Count -le $idxV -or $vals.Count -le $idxU) { continue }

        $uRaw = Convert-ToDoubleOrNull -Value $vals[$idxU]
        $yRaw = Convert-ToDoubleOrNull -Value $vals[$idxV]
        if ($null -eq $uRaw -or $null -eq $yRaw) { continue }

        if ($yRaw -lt 0.0 -or $yRaw -ge 2.0) {
            $outlierTotals.VminOutOfRange_Excluded++
            $outlierSummaryByProduct[$prod].VminOutOfRange_Excluded++
            continue
        }

        if ($upmBounds.ContainsKey($m.UpmCol)) {
            $b = $upmBounds[$m.UpmCol]
            if ($uRaw -lt $b.Low -or $uRaw -gt $b.High) {
                $outlierTotals.UpmOutlier_Excluded++
                $outlierSummaryByProduct[$prod].UpmOutlier_Excluded++
                continue
            }
        }

        $outlierTotals.Accepted++
        $outlierSummaryByProduct[$prod].Accepted++

        $xVal = if ($null -ne $m.NormalizeDivisor) { $uRaw / $m.NormalizeDivisor } else { $uRaw }
        $key = '{0}|{1}|{2}|{3}|{4}|{5}' -f $prod, $m.Die, $m.Domain, ('{0:0.###}' -f $m.FrequencyGHz), $m.Core, $m.VminColumn
        if (-not $fitAccumulator.ContainsKey($key)) {
            $fitAccumulator[$key] = [pscustomobject]@{
                Product = $prod
                Die = $m.Die
                Domain = $m.Domain
                FrequencyGHz = $m.FrequencyGHz
                Core = $m.Core
                VminColumn = $m.VminColumn
                UpmLabel = $m.UpmLabel
                Target = $m.Target
                X = New-Object 'System.Collections.Generic.List[double]'
                Y = New-Object 'System.Collections.Generic.List[double]'
            }
        }
        $fitAccumulator[$key].X.Add($xVal)
        $fitAccumulator[$key].Y.Add($yRaw)
    }
}

Write-Host ("Outlier summary: Vmin excluded={0}  UPM excluded={1}  Accepted={2}" -f $outlierTotals.VminOutOfRange_Excluded, $outlierTotals.UpmOutlier_Excluded, $outlierTotals.Accepted)

Write-Host 'Computing per-product normalized Vmin tables...'
$fitRows = @()
foreach ($item in $fitAccumulator.Values) {
    $fit = Get-LinearFit -X $item.X.ToArray() -Y $item.Y.ToArray()
    $vAtTarget = if ($null -ne $fit.Slope -and $null -ne $fit.Intercept) { ($fit.Slope * $item.Target) + $fit.Intercept } else { $null }
    $fitRows += [pscustomobject]@{
        Product = $item.Product
        Die = $item.Die
        Domain = $item.Domain
        FrequencyGHz = $item.FrequencyGHz
        Core = $item.Core
        VminColumn = $item.VminColumn
        UpmLabel = $item.UpmLabel
        TargetS2T = $item.Target
        Samples = $fit.Count
        Slope = $fit.Slope
        Intercept = $fit.Intercept
        R2 = $fit.R2
        Vmin_At_Target = $vAtTarget
    }
}
$fitRows = $fitRows | Sort-Object Product, Die, Domain, FrequencyGHz, Core

$productNormalizedTable = $fitRows |
    Where-Object { $null -ne $_.Vmin_At_Target } |
    Group-Object Product, Die, Domain, FrequencyGHz |
    ForEach-Object {
        $g0 = $_.Group | Select-Object -First 1
        [pscustomobject]@{
            Product = $g0.Product
            Die = $g0.Die
            Domain = $g0.Domain
            Freq = [double]$g0.FrequencyGHz
            Vmin = [math]::Round((($_.Group | Measure-Object -Property Vmin_At_Target -Average).Average), 4)
            Contributors = $_.Group.Count
        }
    } |
    Sort-Object Product, Die, Domain, Freq

$productSummaryRows = @()
foreach ($prod in ($productRowCounts.Keys | Sort-Object)) {
    $stats = $outlierSummaryByProduct[$prod]
    $productSummaryRows += [pscustomobject]@{
        Product = $prod
        SourceRows = $productRowCounts[$prod]
        AcceptedPoints = $stats.Accepted
        VminExcluded = $stats.VminOutOfRange_Excluded
        UpmExcluded = $stats.UpmOutlier_Excluded
    }
}
$productSummaryRows = $productSummaryRows | Sort-Object Product

$fitCsv = Join-Path $OutputDir 'vmin_by_product_linear_fit_summary.csv'
$tableCsv = Join-Path $OutputDir 'vmin_by_product_normalized_table.csv'
$productSummaryCsv = Join-Path $OutputDir 'product_summary.csv'
$upmBoundsCsv = Join-Path $OutputDir 'upm_outlier_bounds.csv'
$fitRows | Export-Csv -NoTypeInformation -Path $fitCsv -Encoding UTF8
$productNormalizedTable | Export-Csv -NoTypeInformation -Path $tableCsv -Encoding UTF8
$productSummaryRows | Export-Csv -NoTypeInformation -Path $productSummaryCsv -Encoding UTF8
$upmBounds.GetEnumerator() | ForEach-Object {
    [pscustomobject]@{ UpmColumn = $_.Key; Median = $_.Value.Median; Sigma = $_.Value.Sigma; LowBound = $_.Value.Low; HighBound = $_.Value.High; N = $_.Value.N }
} | Export-Csv -NoTypeInformation -Path $upmBoundsCsv -Encoding UTF8

Write-Host 'Generating grouped plots by product...'
$overlayIndex = @()
$vfIndex = @()
foreach ($prod in ($productNormalizedTable | Select-Object -ExpandProperty Product -Unique | Sort-Object)) {
    $prodSlug = ($prod -replace '[^A-Za-z0-9_-]', '_')
    $prodOverlayDir = Join-Path $overlayDir $prodSlug
    $prodVfDir = Join-Path $vfDir $prodSlug
    foreach ($dir in @($prodOverlayDir, $prodVfDir)) {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }

    $productFits = @($fitRows | Where-Object { $_.Product -eq $prod })
    $productTable = @($productNormalizedTable | Where-Object { $_.Product -eq $prod })

    $pairGroups = $productFits | Group-Object Die, Domain, FrequencyGHz
    foreach ($g in $pairGroups) {
        $gRows = @($g.Group | Where-Object { $_.Samples -ge 10 } | Sort-Object Core)
        if ($gRows.Count -eq 0) { continue }
        $g0 = $gRows[0]
        $coreSeries = @()
        foreach ($r in $gRows) {
            $accKey = '{0}|{1}|{2}|{3}|{4}|{5}' -f $r.Product, $r.Die, $r.Domain, ('{0:0.###}' -f $r.FrequencyGHz), $r.Core, $r.VminColumn
            $acc = $fitAccumulator[$accKey]
            if ($null -eq $acc -or $acc.X.Count -lt 3) { continue }
            $coreSeries += [pscustomobject]@{
                Core = $r.Core
                X = $acc.X.ToArray()
                Y = $acc.Y.ToArray()
                Slope = $r.Slope
                Intercept = $r.Intercept
            }
        }
        if ($coreSeries.Count -eq 0) { continue }

        $freqLabel = ('{0:0.###}' -f [double]$g0.FrequencyGHz)
        $freqSlug = $freqLabel.Replace('.', 'p')
        $plotPath = Join-Path $prodOverlayDir ("overlay_{0}_{1}_{2}GHz.png" -f $g0.Die, $g0.Domain, $freqSlug)
        New-MultiCoreScatterFitChart -CoreSeries $coreSeries `
            -Title ("{0} | {1} | {2} | {3}GHz: Vmin vs UPM" -f $prod, $g0.Die, $g0.Domain, $freqLabel) `
            -XAxisTitle $g0.UpmLabel -YAxisTitle 'Vmin' -OutputPath $plotPath
        $overlayIndex += [pscustomobject]@{
            Product = $prod
            Die = $g0.Die
            Domain = $g0.Domain
            Freq = [double]$g0.FrequencyGHz
            CoreCount = $coreSeries.Count
            PlotPath = $plotPath
        }
    }

    foreach ($domainGroup in ($productTable | Group-Object Domain)) {
        $rows = @($domainGroup.Group | Sort-Object Freq)
        if ($rows.Count -lt 2) { continue }
        $g0 = $rows[0]
        $plotPath = Join-Path $prodVfDir ("vf_{0}_{1}.png" -f $g0.Die, $g0.Domain)
        New-LineChart -X @($rows | ForEach-Object { [double]$_.Freq }) -Y @($rows | ForEach-Object { [double]$_.Vmin }) `
            -Title ("{0} | {1} | {2}: normalized VF curve" -f $prod, $g0.Die, $g0.Domain) `
            -XAxisTitle 'Frequency (GHz)' -YAxisTitle 'Vmin @ target' -OutputPath $plotPath
        $vfIndex += [pscustomobject]@{
            Product = $prod
            Die = $g0.Die
            Domain = $g0.Domain
            PlotPath = $plotPath
        }
    }
}

$overlayIndexCsv = Join-Path $OutputDir 'plot_index_overlay_by_product_domain_freq.csv'
$vfIndexCsv = Join-Path $OutputDir 'plot_index_vf_by_product_domain.csv'
$overlayIndex | Sort-Object Product, Die, Domain, Freq | Export-Csv -NoTypeInformation -Path $overlayIndexCsv -Encoding UTF8
$vfIndex | Sort-Object Product, Die, Domain | Export-Csv -NoTypeInformation -Path $vfIndexCsv -Encoding UTF8

Write-Host 'Writing combined notebook...'
$nbPath = Join-Path $OutputDir 'vmin_all_products_validation.ipynb'
Write-Warning 'Notebook export is generated separately after the main validation run.'

Write-Host 'Building combined PPT...'
$pptPath = Join-Path $OutputDir 'vmin_all_products_validation.pptx'
try {
    $pp = New-Object -ComObject PowerPoint.Application
    $pp.Visible = -1
    $pres = $pp.Presentations.Add()

    $s1 = $pres.Slides.Add(1, 12)
    [void](Add-TextBox -Slide $s1 -Text 'Vmin Validation Across All Products' -Left 30 -Top 20 -Width 1200 -Height 50 -FontSize 34 -Bold $true)
    $overview = @(
        "Input: $InputCsv",
        "Grouped by: $prodCol",
        'Fixed targets regardless of DevRevStep:',
        '  Cdie/U5 -> 0.87',
        '  GT die/U4 -> 0.85',
        '  Hub die/U2 -> 0.85',
        '',
        "Outlier summary: Vmin excluded=$($outlierTotals.VminOutOfRange_Excluded)  UPM excluded=$($outlierTotals.UpmOutlier_Excluded)  Accepted=$($outlierTotals.Accepted)",
        "Products detected: $($productSummaryRows.Count)"
    ) -join "`r`n"
    [void](Add-TextBox -Slide $s1 -Text $overview -Left 40 -Top 100 -Width 1180 -Height 300 -FontSize 20)

    $slideNum = 2
    foreach ($prod in ($productSummaryRows | Select-Object -ExpandProperty Product)) {
        $rows = @($productNormalizedTable | Where-Object { $_.Product -eq $prod } | Select-Object -First 20)
        $slide = $pres.Slides.Add($slideNum, 12)
        [void](Add-TextBox -Slide $slide -Text ("Product {0}: Normalized Vmin Table" -f $prod) -Left 30 -Top 20 -Width 1200 -Height 40 -FontSize 28 -Bold $true)
        $tableRows = [math]::Max(2, [math]::Min($rows.Count + 1, 21))
        $shape = $slide.Shapes.AddTable($tableRows, 4, 30, 90, 1240, 580)
        $tbl = $shape.Table
        $tbl.Cell(1,1).Shape.TextFrame.TextRange.Text = 'Die'
        $tbl.Cell(1,2).Shape.TextFrame.TextRange.Text = 'Domain'
        $tbl.Cell(1,3).Shape.TextFrame.TextRange.Text = 'Freq (GHz)'
        $tbl.Cell(1,4).Shape.TextFrame.TextRange.Text = 'Vmin'
        for ($i = 0; $i -lt ($tableRows - 1) -and $i -lt $rows.Count; $i++) {
            $r = $rows[$i]
            $tbl.Cell($i + 2, 1).Shape.TextFrame.TextRange.Text = [string]$r.Die
            $tbl.Cell($i + 2, 2).Shape.TextFrame.TextRange.Text = [string]$r.Domain
            $tbl.Cell($i + 2, 3).Shape.TextFrame.TextRange.Text = ('{0:0.###}' -f $r.Freq)
            $tbl.Cell($i + 2, 4).Shape.TextFrame.TextRange.Text = ('{0:0.###}' -f $r.Vmin)
        }
        $slideNum++
    }

    try {
        $pres.SaveAs($pptPath)
    }
    catch {
        $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
        $pptPath = Join-Path $OutputDir ("vmin_all_products_validation_{0}.pptx" -f $ts)
        Write-Warning "Default PPT is locked/in use. Saving to timestamped file: $pptPath"
        $pres.SaveAs($pptPath)
    }

    try { $pres.Close() } catch { Write-Warning "PPT close: $($_.Exception.Message)" }
    try { $pp.Quit() } catch { Write-Warning "PPT quit: $($_.Exception.Message)" }
}
catch {
    Write-Warning "PowerPoint export skipped: $($_.Exception.Message)"
}

Write-Host 'Generated artifacts:'
Write-Host " - $fitCsv"
Write-Host " - $tableCsv"
Write-Host " - $productSummaryCsv"
Write-Host " - $upmBoundsCsv"
Write-Host " - $overlayIndexCsv"
Write-Host " - $vfIndexCsv"
Write-Host " - $nbPath"
Write-Host " - $pptPath"