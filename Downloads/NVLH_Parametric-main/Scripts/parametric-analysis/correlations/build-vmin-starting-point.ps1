#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InputCsv = "R:\Products\NVL\NVL-H\Weekly Runs\Vmin_NVLHM66A0H30N00S623_WW25_2026_merged.csv",
    [string]$OutputDir = ".\output\vmin-starting-point"
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
    param([double[]]$X,[double[]]$Y)
    $n = $X.Count
    if ($n -lt 3) { return [pscustomobject]@{ Slope=$null;Intercept=$null;R2=$null;Count=$n } }
    $sumX=($X|Measure-Object -Sum).Sum; $sumY=($Y|Measure-Object -Sum).Sum
    $sumXY=0.0; $sumXX=0.0
    for($i=0;$i -lt $n;$i++){$sumXY+=($X[$i]*$Y[$i]);$sumXX+=($X[$i]*$X[$i])}
    $den=($n*$sumXX)-($sumX*$sumX)
    if([math]::Abs($den) -lt 1e-12){return [pscustomobject]@{Slope=$null;Intercept=$null;R2=$null;Count=$n}}
    $slope=(($n*$sumXY)-($sumX*$sumY))/$den
    $intercept=($sumY-($slope*$sumX))/$n
    $meanY=$sumY/$n; $ssTot=0.0; $ssRes=0.0
    for($i=0;$i -lt $n;$i++){
        $pred=($slope*$X[$i])+$intercept
        $ssTot+=[math]::Pow(($Y[$i]-$meanY),2)
        $ssRes+=[math]::Pow(($Y[$i]-$pred),2)
    }
    $r2=if($ssTot -gt 0){1.0-($ssRes/$ssTot)}else{$null}
    [pscustomobject]@{Slope=$slope;Intercept=$intercept;R2=$r2;Count=$n}
}

function New-LineChart {
    param([double[]]$X,[double[]]$Y,[string]$Title,[string]$XAxisTitle,[string]$YAxisTitle,[string]$OutputPath)
    Add-Type -AssemblyName System.Windows.Forms.DataVisualization
    $chart=New-Object System.Windows.Forms.DataVisualization.Charting.Chart; $chart.Width=1400; $chart.Height=900
    $area=New-Object System.Windows.Forms.DataVisualization.Charting.ChartArea
    $area.AxisX.Title=$XAxisTitle; $area.AxisY.Title=$YAxisTitle
    $area.AxisX.MajorGrid.LineColor=[System.Drawing.Color]::LightGray
    $area.AxisY.MajorGrid.LineColor=[System.Drawing.Color]::LightGray
    $chart.ChartAreas.Add($area)
    $series=New-Object System.Windows.Forms.DataVisualization.Charting.Series
    $series.Name='Curve'; $series.ChartType=[System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::Line
    $series.BorderWidth=3; $series.Color=[System.Drawing.Color]::FromArgb(44,160,44)
    $series.MarkerSize=8; $series.MarkerStyle=[System.Windows.Forms.DataVisualization.Charting.MarkerStyle]::Circle
    for($i=0;$i -lt $X.Count;$i++){[void]$series.Points.AddXY($X[$i],$Y[$i])}
    $chart.Series.Add($series)
    $titleObj=New-Object System.Windows.Forms.DataVisualization.Charting.Title
    $titleObj.Text=$Title; $titleObj.Font=New-Object System.Drawing.Font('Segoe UI',14,[System.Drawing.FontStyle]::Bold)
    [void]$chart.Titles.Add($titleObj)
    $chart.SaveImage($OutputPath,[System.Windows.Forms.DataVisualization.Charting.ChartImageFormat]::Png); $chart.Dispose()
}

function New-ScatterFitChart {
    param([double[]]$X,[double[]]$Y,[double]$Slope,[double]$Intercept,[string]$Title,[string]$XAxisTitle,[string]$YAxisTitle,[string]$OutputPath)
    Add-Type -AssemblyName System.Windows.Forms.DataVisualization
    $chart=New-Object System.Windows.Forms.DataVisualization.Charting.Chart; $chart.Width=1400; $chart.Height=900
    $area=New-Object System.Windows.Forms.DataVisualization.Charting.ChartArea
    $area.AxisX.Title=$XAxisTitle; $area.AxisY.Title=$YAxisTitle
    $area.AxisX.MajorGrid.LineColor=[System.Drawing.Color]::LightGray
    $area.AxisY.MajorGrid.LineColor=[System.Drawing.Color]::LightGray
    $chart.ChartAreas.Add($area)
    $scatter=New-Object System.Windows.Forms.DataVisualization.Charting.Series
    $scatter.Name='Data'; $scatter.ChartType=[System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::Point
    $scatter.MarkerSize=5; $scatter.Color=[System.Drawing.Color]::FromArgb(31,119,180)
    for($i=0;$i -lt $X.Count;$i++){[void]$scatter.Points.AddXY($X[$i],$Y[$i])}
    $chart.Series.Add($scatter)
    if($null -ne $Slope -and $null -ne $Intercept -and $X.Count -gt 0){
        $xMin=($X|Measure-Object -Minimum).Minimum; $xMax=($X|Measure-Object -Maximum).Maximum
        $fit=New-Object System.Windows.Forms.DataVisualization.Charting.Series
        $fit.Name='Fit'; $fit.ChartType=[System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::Line
        $fit.BorderWidth=3; $fit.Color=[System.Drawing.Color]::FromArgb(214,39,40)
        [void]$fit.Points.AddXY($xMin,(($Slope*$xMin)+$Intercept))
        [void]$fit.Points.AddXY($xMax,(($Slope*$xMax)+$Intercept))
        $chart.Series.Add($fit)
    }
    $titleObj=New-Object System.Windows.Forms.DataVisualization.Charting.Title
    $titleObj.Text=$Title; $titleObj.Font=New-Object System.Drawing.Font('Segoe UI',14,[System.Drawing.FontStyle]::Bold)
    [void]$chart.Titles.Add($titleObj)
    $chart.SaveImage($OutputPath,[System.Windows.Forms.DataVisualization.Charting.ChartImageFormat]::Png); $chart.Dispose()
}

function New-MultiCoreScatterFitChart {
    param([object[]]$CoreSeries,[string]$Title,[string]$XAxisTitle,[string]$YAxisTitle,[string]$OutputPath)
    Add-Type -AssemblyName System.Windows.Forms.DataVisualization
    $chart=New-Object System.Windows.Forms.DataVisualization.Charting.Chart; $chart.Width=1600; $chart.Height=1000
    $area=New-Object System.Windows.Forms.DataVisualization.Charting.ChartArea
    $area.AxisX.Title=$XAxisTitle; $area.AxisY.Title=$YAxisTitle
    $area.AxisX.MajorGrid.LineColor=[System.Drawing.Color]::LightGray
    $area.AxisY.MajorGrid.LineColor=[System.Drawing.Color]::LightGray
    $chart.ChartAreas.Add($area)
    $legend=New-Object System.Windows.Forms.DataVisualization.Charting.Legend
    $legend.Docking=[System.Windows.Forms.DataVisualization.Charting.Docking]::Bottom
    $chart.Legends.Add($legend)
    $palette=@(
        [System.Drawing.Color]::FromArgb(31,119,180),
        [System.Drawing.Color]::FromArgb(255,127,14),
        [System.Drawing.Color]::FromArgb(44,160,44),
        [System.Drawing.Color]::FromArgb(214,39,40),
        [System.Drawing.Color]::FromArgb(148,103,189),
        [System.Drawing.Color]::FromArgb(140,86,75)
    )
    $colorIdx=0
    foreach($core in ($CoreSeries|Sort-Object Core)){
        $clr=$palette[$colorIdx % $palette.Count]; $colorIdx++
        $sData=New-Object System.Windows.Forms.DataVisualization.Charting.Series
        $sData.Name=("Core {0} data" -f $core.Core)
        $sData.ChartType=[System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::Point
        $sData.MarkerSize=5; $sData.Color=$clr; $sData.LegendText=$sData.Name
        for($i=0;$i -lt $core.X.Count;$i++){[void]$sData.Points.AddXY($core.X[$i],$core.Y[$i])}
        $chart.Series.Add($sData)
        if($null -ne $core.Slope -and $null -ne $core.Intercept -and $core.X.Count -gt 0){
            $xMin=($core.X|Measure-Object -Minimum).Minimum; $xMax=($core.X|Measure-Object -Maximum).Maximum
            $sFit=New-Object System.Windows.Forms.DataVisualization.Charting.Series
            $sFit.Name=("Core {0} fit" -f $core.Core)
            $sFit.ChartType=[System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::Line
            $sFit.BorderWidth=3; $sFit.Color=$clr; $sFit.LegendText=$sFit.Name
            [void]$sFit.Points.AddXY($xMin,(($core.Slope*$xMin)+$core.Intercept))
            [void]$sFit.Points.AddXY($xMax,(($core.Slope*$xMax)+$core.Intercept))
            $chart.Series.Add($sFit)
        }
    }
    $titleObj=New-Object System.Windows.Forms.DataVisualization.Charting.Title
    $titleObj.Text=$Title; $titleObj.Font=New-Object System.Drawing.Font('Segoe UI',14,[System.Drawing.FontStyle]::Bold)
    [void]$chart.Titles.Add($titleObj)
    $chart.SaveImage($OutputPath,[System.Windows.Forms.DataVisualization.Charting.ChartImageFormat]::Png); $chart.Dispose()
}

function Add-TextBox {
    param($Slide,[string]$Text,[float]$Left,[float]$Top,[float]$Width,[float]$Height,[int]$FontSize=18,[bool]$Bold=$false)
    $shape=$Slide.Shapes.AddTextbox(1,$Left,$Top,$Width,$Height)
    $shape.TextFrame.TextRange.Text=$Text
    $shape.TextFrame.TextRange.Font.Size=$FontSize
    $shape.TextFrame.TextRange.Font.Bold=[int]($Bold)
    return $shape
}

function Get-DieConfig {
    param([string]$VminColumn)
    if($VminColumn -match '_U1PU5_'){
        return [pscustomobject]@{Die='CDIE';UpmCol='UPM_0107_DPMH156P48ULVTINVD4_FULLDIE_0950_MED_SORT_U1.U5';UpmS2TCol='UPM_0107_DPMH156P48ULVTINVD4_FULLDIE_0950_MED_SORT_U1.U5 S2T';DevRevCol='DevRevStep_SORT_U1.U5';DevRevStep='8PY6CVT';Target=0.87;NormalizeDivisor=9154.0}
    }
    if($VminColumn -match '_U1PU4_'){
        return [pscustomobject]@{Die='GTDIE';UpmCol='TPI_UPM::UPM_X_SCREEN_K_START_X_X_X_X_FEM_CALC_UPM_FEM_ULVT_FULLDIE_PDK0P9_0950MV_SORT_U1.U4';UpmS2TCol='TPI_UPM::UPM_X_SCREEN_K_START_X_X_X_X_FEM_CALC_UPM_FEM_ULVT_FULLDIE_PDK0P9_0950MV_SORT_U1.U4';DevRevCol='DevRevStep_SORT_U1.U4';DevRevStep='8PQ8CVAA';Target=0.85;NormalizeDivisor=$null}
    }
    if($VminColumn -match '_U1PU2_'){
        return [pscustomobject]@{Die='HUBDIE';UpmCol='TPI_UPM::UPM_X_SCREEN_K_START_X_X_X_X_FEM_CALC_UPM_FEM_ULVT_FULLDIE_PDK0P9_0950MV_SORT_U1.U2';UpmS2TCol='TPI_UPM::UPM_X_SCREEN_K_START_X_X_X_X_FEM_CALC_UPM_FEM_ULVT_FULLDIE_PDK0P9_0950MV_SORT_U1.U2';DevRevCol='DevRevStep_SORT_U1.U2';DevRevStep='8PF9CVA';Target=0.85;NormalizeDivisor=$null}
    }
    return $null
}

if(-not (Test-Path -LiteralPath $InputCsv)){throw "Input CSV not found: $InputCsv"}

Write-Host 'Reading header and finding UPSVF Vmin columns...'
$headerLine=Get-Content -LiteralPath $InputCsv -TotalCount 1
$allCols=$headerLine -split ',' | ForEach-Object { $_.Trim('"') }
$vminCols=@($allCols | Where-Object { $_ -like '*UPSVFPASSFLOW*' -and $_ -like '*_RCS_*' })
if($vminCols.Count -eq 0){throw 'No UPSVF Vmin columns found.'}

$indexByName=@{}
for($i=0;$i -lt $allCols.Count;$i++){$indexByName[$allCols[$i]]=$i}

$metaList=@()
foreach($col in $vminCols){
    if($col -notmatch '_RCS_([A-Z0-9]+)_([0-9]+(?:\.[0-9]+)?)_([0-9]+)$'){continue}
    $domain=$matches[1]
    $freq=[double]::Parse($matches[2],[System.Globalization.CultureInfo]::InvariantCulture)
    $core=[int]$matches[3]
    $cfg=Get-DieConfig -VminColumn $col
    if($null -eq $cfg){continue}
    if(-not $indexByName.ContainsKey($cfg.UpmCol) -or -not $indexByName.ContainsKey($cfg.DevRevCol)){continue}
    $metaList+=[pscustomobject]@{VminColumn=$col;Domain=$domain;FrequencyGHz=$freq;Core=$core;Die=$cfg.Die;UpmCol=$cfg.UpmCol;UpmS2TCol=$cfg.UpmS2TCol;DevRevCol=$cfg.DevRevCol;DevRevStep=$cfg.DevRevStep;Target=$cfg.Target;NormalizeDivisor=$cfg.NormalizeDivisor;X=New-Object 'System.Collections.Generic.List[double]';Y=New-Object 'System.Collections.Generic.List[double]'}
}
if($metaList.Count -eq 0){throw 'No Vmin columns could be mapped with required UPM/DevRev columns.'}

$metaByVmin=@{}
foreach($m in $metaList){$metaByVmin[$m.VminColumn]=$m}
$vminActiveCols=@($metaList | Select-Object -ExpandProperty VminColumn)
Write-Host "Mapped Vmin columns: $($metaList.Count)"

# ===== OUTLIER PRE-PASS: compute UPM median +/- 3-sigma bounds from full population =====
$uniqueUpmCols=@($metaList | Select-Object -ExpandProperty UpmCol -Unique)
$upmAccumulators=@{}
foreach($uc in $uniqueUpmCols){$upmAccumulators[$uc]=New-Object 'System.Collections.Generic.List[double]'}

Write-Host 'Pre-pass: collecting UPM population for outlier bounds...'
Get-Content -LiteralPath $InputCsv | Select-Object -Skip 1 | ForEach-Object {
    $vals=$_ -split ','
    foreach($uc in $uniqueUpmCols){
        $idx=$indexByName[$uc]
        if($vals.Count -le $idx){continue}
        $v=Convert-ToDoubleOrNull -Value $vals[$idx]
        if($null -ne $v){$upmAccumulators[$uc].Add($v)}
    }
}

$upmBounds=@{}
foreach($uc in $uniqueUpmCols){
    $arr=$upmAccumulators[$uc].ToArray()
    if($arr.Count -lt 4){continue}
    $med=Get-Median -Values $arr
    $mean=($arr|Measure-Object -Average).Average
    $sumSq=0.0; foreach($v in $arr){$sumSq+=($v-$mean)*($v-$mean)}
    $sigma=[math]::Sqrt($sumSq/$arr.Count)
    $lo=$med-3.0*$sigma; $hi=$med+3.0*$sigma
    $upmBounds[$uc]=[pscustomobject]@{Median=$med;Sigma=$sigma;Low=$lo;High=$hi;N=$arr.Count}
    Write-Host ("  [{0}]  median={1:0.4f}  sigma={2:0.4f}  keep [{3:0.4f}, {4:0.4f}]  N={5}" -f $uc,$med,$sigma,$lo,$hi,$arr.Count)
}
# ===== END OUTLIER PRE-PASS =====

$outlierLog=[ordered]@{VminOutOfRange_Excluded=0;UpmOutlier_Excluded=0;Accepted=0}

Write-Host 'Streaming CSV and collecting data points (with outlier exclusion)...'
Get-Content -LiteralPath $InputCsv | Select-Object -Skip 1 | ForEach-Object {
    $vals=$_ -split ','
    foreach($vcol in $vminActiveCols){
        $m=$metaByVmin[$vcol]
        $idxV=$indexByName[$m.VminColumn]; $idxU=$indexByName[$m.UpmCol]; $idxD=$indexByName[$m.DevRevCol]
        if($vals.Count -le $idxV -or $vals.Count -le $idxU -or $vals.Count -le $idxD){continue}
        $dev=$vals[$idxD].Trim('"')
        if($dev -ne $m.DevRevStep){continue}
        $uRaw=Convert-ToDoubleOrNull -Value $vals[$idxU]
        $yRaw=Convert-ToDoubleOrNull -Value $vals[$idxV]
        if($null -eq $uRaw -or $null -eq $yRaw){continue}
        # Vmin range exclusion: must be in [0, 2)
        if($yRaw -lt 0.0 -or $yRaw -ge 2.0){$outlierLog.VminOutOfRange_Excluded++;continue}
        # UPM 3-sigma exclusion: must be within median +/- 3*sigma
        if($upmBounds.ContainsKey($m.UpmCol)){
            $b=$upmBounds[$m.UpmCol]
            if($uRaw -lt $b.Low -or $uRaw -gt $b.High){$outlierLog.UpmOutlier_Excluded++;continue}
        }
        $outlierLog.Accepted++
        $xVal=if($null -ne $m.NormalizeDivisor){$uRaw/$m.NormalizeDivisor}else{$uRaw}
        $m.X.Add($xVal); $m.Y.Add($yRaw)
    }
}
Write-Host ("Outlier summary: Vmin excluded={0}  UPM 3-sigma excluded={1}  Accepted={2}" -f $outlierLog.VminOutOfRange_Excluded,$outlierLog.UpmOutlier_Excluded,$outlierLog.Accepted)

Write-Host 'Computing fit statistics and target-point summaries...'
$fitRows=@()
foreach($m in $metaList){
    $fit=Get-LinearFit -X $m.X.ToArray() -Y $m.Y.ToArray()
    $vAtTarget=if($null -ne $fit.Slope -and $null -ne $fit.Intercept){($fit.Slope*$m.Target)+$fit.Intercept}else{$null}
    $fitRows+=[pscustomobject]@{Die=$m.Die;Domain=$m.Domain;FrequencyGHz=$m.FrequencyGHz;Core=$m.Core;VminColumn=$m.VminColumn;UpmS2TColumn=$m.UpmS2TCol;DevRevColumn=$m.DevRevCol;DevRevStep=$m.DevRevStep;TargetS2T=$m.Target;Samples=$fit.Count;Slope=$fit.Slope;Intercept=$fit.Intercept;R2=$fit.R2;Vmin_At_Target=$vAtTarget}
}
$fitRows=$fitRows | Sort-Object Die,Domain,FrequencyGHz,Core

$domainSummary=$fitRows |
    Where-Object {$null -ne $_.Vmin_At_Target} |
    Group-Object Die,Domain,FrequencyGHz |
    ForEach-Object {
        $g0=$_.Group | Select-Object -First 1
        [pscustomobject]@{Die=$g0.Die;Domain=$g0.Domain;Freq=[double]$g0.FrequencyGHz;Vmin=[math]::Round((($_.Group|Measure-Object -Property Vmin_At_Target -Average).Average),4);Contributors=$_.Group.Count}
    } |
    Sort-Object Die,Domain,Freq

$fitCsv=Join-Path $OutputDir 'vmin_all_columns_linear_fit_summary.csv'
$domainCsv=Join-Path $OutputDir 'vmin_domain_freq_summary.csv'
$upmBoundsCsv=Join-Path $OutputDir 'upm_outlier_bounds.csv'
$fitRows | Export-Csv -NoTypeInformation -Path $fitCsv -Encoding UTF8
$domainSummary | Export-Csv -NoTypeInformation -Path $domainCsv -Encoding UTF8
$upmBounds.GetEnumerator() | ForEach-Object {
    [pscustomobject]@{UpmColumn=$_.Key;Median=$_.Value.Median;Sigma=$_.Value.Sigma;LowBound=$_.Value.Low;HighBound=$_.Value.High;N=$_.Value.N}
} | Export-Csv -NoTypeInformation -Path $upmBoundsCsv -Encoding UTF8

Write-Host 'Generating domain-level VF and representative scatter plots...'
$plotIndexRows=@()
$overlayDir=Join-Path $plotsDir 'vmin_vs_upm_by_domain_freq'
if(-not (Test-Path -LiteralPath $overlayDir)){New-Item -ItemType Directory -Path $overlayDir -Force | Out-Null}

$overlayRows=@()
$pairGroups=$fitRows | Group-Object Die,Domain,FrequencyGHz
foreach($g in $pairGroups){
    $gRows=@($g.Group | Where-Object {$_.Samples -ge 10} | Sort-Object Core)
    if($gRows.Count -eq 0){continue}
    $g0=$gRows[0]; $coreSeries=@()
    foreach($r in $gRows){
        $m=$metaByVmin[$r.VminColumn]
        if($null -eq $m -or $m.X.Count -lt 3){continue}
        $coreSeries+=[pscustomobject]@{Core=$r.Core;X=$m.X.ToArray();Y=$m.Y.ToArray();Slope=$r.Slope;Intercept=$r.Intercept}
    }
    if($coreSeries.Count -eq 0){continue}
    $freqLabel=('{0:0.###}' -f [double]$g0.FrequencyGHz)
    $freqSlug=$freqLabel.Replace('.','p')
    $overlayPng=Join-Path $overlayDir ("overlay_{0}_{1}_{2}GHz.png" -f $g0.Die,$g0.Domain,$freqSlug)
    New-MultiCoreScatterFitChart -CoreSeries $coreSeries `
        -Title ("{0} {1} {2}GHz: Vmin vs UPM (cores overlaid)" -f $g0.Die,$g0.Domain,$freqLabel) `
        -XAxisTitle $g0.UpmS2TColumn -YAxisTitle 'Vmin' -OutputPath $overlayPng
    $overlayRows+=[pscustomobject]@{Die=$g0.Die;Domain=$g0.Domain;Freq=[double]$g0.FrequencyGHz;OverlayPlot=$overlayPng;CoreCount=$coreSeries.Count}
}

$domains=@($domainSummary | Select-Object -ExpandProperty Domain -Unique | Sort-Object)
foreach($d in $domains){
    $domainRows=@($domainSummary | Where-Object {$_.Domain -eq $d} | Sort-Object Freq)
    if($domainRows.Count -lt 2){continue}
    $vfPng=Join-Path $plotsDir ("vf_{0}.png" -f $d)
    New-LineChart -X @($domainRows|ForEach-Object{[double]$_.Freq}) -Y @($domainRows|ForEach-Object{[double]$_.Vmin}) `
        -Title ("{0} normalized VF curve" -f $d) -XAxisTitle 'Frequency (GHz)' -YAxisTitle 'Vmin @ target' -OutputPath $vfPng
    $cand=@($fitRows | Where-Object {$_.Domain -eq $d -and $_.Samples -ge 10} | Sort-Object FrequencyGHz,Core)
    $scatterPng=$null
    if($cand.Count -gt 0){
        $rep=$cand[0]; $meta=$metaByVmin[$rep.VminColumn]
        $scatterPng=Join-Path $plotsDir ("scatter_{0}.png" -f $d)
        New-ScatterFitChart -X $meta.X.ToArray() -Y $meta.Y.ToArray() -Slope $rep.Slope -Intercept $rep.Intercept `
            -Title ("{0}: Vmin vs UPM S2T" -f $d) -XAxisTitle $rep.UpmS2TColumn -YAxisTitle $rep.VminColumn -OutputPath $scatterPng
    }
    $plotIndexRows+=[pscustomobject]@{Domain=$d;VfPlot=$vfPng;ScatterPlot=$scatterPng}
}
$plotIndexCsv=Join-Path $OutputDir 'plot_index.csv'
$plotIndexRows | Export-Csv -NoTypeInformation -Path $plotIndexCsv -Encoding UTF8
$overlayCsv=Join-Path $OutputDir 'plot_index_overlay_domain_freq.csv'
$overlayRows | Sort-Object Die,Domain,Freq | Export-Csv -NoTypeInformation -Path $overlayCsv -Encoding UTF8

Write-Host 'Writing notebook starting point...'
$generatedAt=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
$domainPreview=($domainSummary | Select-Object -First 40 | ConvertTo-Csv -NoTypeInformation) -join "`n"

$nbObj=[ordered]@{
    cells=@(
        [ordered]@{cell_type='markdown';metadata=@{language='markdown'};source=@('# Vmin Starting-Point Analysis (All UPSVF Domains)',"Generated: $generatedAt",'','**Outlier exclusion applied:**','- Vmin: excluded if < 0 or >= 2','- UPM: excluded if outside median +/- 3*sigma of the full population')},
        [ordered]@{cell_type='code';metadata=@{language='python'};source=@('import re,numpy as np,pandas as pd,matplotlib.pyplot as plt',"csv_path=r'R:\\Products\\NVL\\NVL-H\\Weekly Runs\\Vmin_NVLHM66A0H30N00S623_WW25_2026_merged.csv'","df=pd.read_csv(csv_path,low_memory=False)","u5='UPM_0107_DPMH156P48ULVTINVD4_FULLDIE_0950_MED_SORT_U1.U5'","u2='TPI_UPM::UPM_X_SCREEN_K_START_X_X_X_X_FEM_CALC_UPM_FEM_ULVT_FULLDIE_PDK0P9_0950MV_SORT_U1.U2'","u4='TPI_UPM::UPM_X_SCREEN_K_START_X_X_X_X_FEM_CALC_UPM_FEM_ULVT_FULLDIE_PDK0P9_0950MV_SORT_U1.U4'","df[u5+' S2T']=pd.to_numeric(df[u5],errors='coerce')/9154.0","vmin_cols=[c for c in df.columns if 'UPSVFPASSFLOW' in c and '_RCS_' in c]","# UPM 3-sigma bounds","upm_bounds={}","for uc in [u5,u2,u4]:","    s=pd.to_numeric(df[uc],errors='coerce').dropna()","    if len(s)<4: continue","    med=s.median(); sig=s.std(ddof=0)","    upm_bounds[uc]=(med-3*sig,med+3*sig)","    print(f'{uc}: keep [{med-3*sig:.4f},{med+3*sig:.4f}]')","len(vmin_cols)")},
        [ordered]@{cell_type='code';metadata=@{language='python'};source=@('def die_cfg(c):','    if "_U1PU5_" in c: return {"die":"CDIE","x":u5+" S2T","xraw":u5,"dev":"DevRevStep_SORT_U1.U5","step":"8PY6CVT","target":0.87}','    if "_U1PU4_" in c: return {"die":"GTDIE","x":u4,"xraw":u4,"dev":"DevRevStep_SORT_U1.U4","step":"8PQ8CVAA","target":0.85}','    if "_U1PU2_" in c: return {"die":"HUBDIE","x":u2,"xraw":u2,"dev":"DevRevStep_SORT_U1.U2","step":"8PF9CVA","target":0.85}','    return None','rows=[]','for c in vmin_cols:','    m=re.search(r"_RCS_([A-Z0-9]+)_([0-9]+\\.?[0-9]*)_([0-9]+)$",c)','    if not m: continue','    dom,freq,core=m.group(1),float(m.group(2)),int(m.group(3))','    cfg=die_cfg(c)','    if not cfg: continue','    x=pd.to_numeric(df[cfg["x"]],errors="coerce")','    y=pd.to_numeric(df[c],errors="coerce")','    xraw=pd.to_numeric(df[cfg["xraw"]],errors="coerce")','    d_step=(df[cfg["dev"]]==cfg["step"])','    vmin_ok=(y>=0)&(y<2)','    upm_ok=pd.Series(True,index=df.index)','    if cfg["xraw"] in upm_bounds:','        lo,hi=upm_bounds[cfg["xraw"]]','        upm_ok=(xraw>=lo)&(xraw<=hi)','    msk=d_step&x.notna()&y.notna()&vmin_ok&upm_ok','    if msk.sum()<10: continue','    x2=x[msk].values; y2=y[msk].values','    slope,intercept=np.polyfit(x2,y2,1)','    yhat=slope*x2+intercept','    ss_res=np.sum((y2-yhat)**2); ss_tot=np.sum((y2-np.mean(y2))**2)','    r2=1-ss_res/ss_tot if ss_tot>0 else np.nan','    rows.append({"Die":cfg["die"],"Domain":dom,"Freq":freq,"Core":core,"N":int(msk.sum()),"Slope":slope,"Intercept":intercept,"R2":r2,"Vmin_at_target":slope*cfg["target"]+intercept})','fit_df=pd.DataFrame(rows).sort_values(["Die","Domain","Freq","Core"])','fit_df.head()')},
        [ordered]@{cell_type='code';metadata=@{language='python'};source=@('vf_df=fit_df.dropna(subset=["Vmin_at_target"]).groupby(["Die","Domain","Freq"],as_index=False).agg(Vmin=("Vmin_at_target","mean")).sort_values(["Die","Domain","Freq"])','vf_df.head(30)')},
        [ordered]@{cell_type='code';metadata=@{language='python'};source=@('for d,g in vf_df.groupby("Domain"):','    if len(g)<2: continue','    plt.figure(figsize=(6.5,4.5))','    plt.plot(g["Freq"],g["Vmin"],marker="o",linewidth=2)','    plt.title(f"{d} normalized VF curve")','    plt.xlabel("Frequency (GHz)")','    plt.ylabel("Vmin @ target")','    plt.grid(True,alpha=0.3)','    plt.show()')},
        [ordered]@{cell_type='markdown';metadata=@{language='markdown'};source=@('## Generated Summary Preview','','```csv',$domainPreview,'```')}
    )
    metadata=@{kernelspec=@{display_name='Python 3';language='python';name='python3'};language_info=@{name='python'}}
    nbformat=4
    nbformat_minor=5
}
$nbPath=Join-Path $OutputDir 'vmin_starting_point_analysis.ipynb'
($nbObj|ConvertTo-Json -Depth 30) | Set-Content -LiteralPath $nbPath -Encoding UTF8

Write-Host 'Building PowerPoint...'
$pptPath=Join-Path $OutputDir 'vmin_starting_point_analysis.pptx'
$pp=New-Object -ComObject PowerPoint.Application; $pp.Visible=-1
$pres=$pp.Presentations.Add()

$s1=$pres.Slides.Add(1,12)
[void](Add-TextBox -Slide $s1 -Text 'Vmin Starting-Point Analysis (All Domains)' -Left 30 -Top 20 -Width 1200 -Height 50 -FontSize 34 -Bold $true)
$upmBoundsText=($upmBounds.GetEnumerator()|Sort-Object Key|ForEach-Object{'  {0}: [{1:0.3f}, {2:0.3f}]' -f $_.Key,$_.Value.Low,$_.Value.High}) -join "`r`n"
$overview=@("Input: $InputCsv",'Outlier rules:','  Vmin: 0 <= Vmin < 2','  UPM: median +/- 3*sigma (full population)',"  Vmin excluded: $($outlierLog.VminOutOfRange_Excluded)  UPM excluded: $($outlierLog.UpmOutlier_Excluded)  Accepted: $($outlierLog.Accepted)",'',"UPM bounds:",$upmBoundsText,'',"Vmin columns: $($metaList.Count)  |  Summary rows: $($domainSummary.Count)") -join "`r`n"
[void](Add-TextBox -Slide $s1 -Text $overview -Left 40 -Top 90 -Width 1220 -Height 560 -FontSize 18)

$s2=$pres.Slides.Add(2,12)
[void](Add-TextBox -Slide $s2 -Text 'Top Fits by R2 (N>=100)' -Left 30 -Top 20 -Width 1200 -Height 40 -FontSize 30 -Bold $true)
$topFits=@($fitRows|Where-Object{$_.Samples -ge 100 -and $null -ne $_.R2}|Sort-Object R2 -Descending|Select-Object -First 12)
$lines=@('Domain | Freq | Core | R2 | N | Vmin@Target')
foreach($r in $topFits){$lines+='{0} | {1:0.###} | {2} | {3:0.###} | {4} | {5:0.###}' -f $r.Domain,$r.FrequencyGHz,$r.Core,$r.R2,$r.Samples,$r.Vmin_At_Target}
[void](Add-TextBox -Slide $s2 -Text ($lines -join "`r`n") -Left 40 -Top 90 -Width 1220 -Height 600 -FontSize 16)

$s3=$pres.Slides.Add(3,12)
[void](Add-TextBox -Slide $s3 -Text 'Normalized VF Summary Table' -Left 30 -Top 20 -Width 1200 -Height 40 -FontSize 30 -Bold $true)
$rows=[math]::Min($domainSummary.Count+1,22)
$tblShape=$s3.Shapes.AddTable($rows,4,30,90,1240,600); $tbl=$tblShape.Table
$tbl.Cell(1,1).Shape.TextFrame.TextRange.Text='Die'; $tbl.Cell(1,2).Shape.TextFrame.TextRange.Text='Domain'
$tbl.Cell(1,3).Shape.TextFrame.TextRange.Text='Freq (GHz)'; $tbl.Cell(1,4).Shape.TextFrame.TextRange.Text='Vmin'
for($i=0;$i -lt ($rows-1);$i++){
    $r=$domainSummary[$i]
    $tbl.Cell($i+2,1).Shape.TextFrame.TextRange.Text=[string]$r.Die
    $tbl.Cell($i+2,2).Shape.TextFrame.TextRange.Text=[string]$r.Domain
    $tbl.Cell($i+2,3).Shape.TextFrame.TextRange.Text=('{0:0.###}' -f $r.Freq)
    $tbl.Cell($i+2,4).Shape.TextFrame.TextRange.Text=('{0:0.###}' -f $r.Vmin)
}

$slideNum=4
foreach($p in $plotIndexRows){
    $sl=$pres.Slides.Add($slideNum,12)
    [void](Add-TextBox -Slide $sl -Text ("Domain {0}: VF and Vmin-vs-UPM" -f $p.Domain) -Left 30 -Top 20 -Width 1200 -Height 40 -FontSize 30 -Bold $true)
    if(Test-Path -LiteralPath $p.VfPlot){[void]$sl.Shapes.AddPicture($p.VfPlot,$false,$true,40,90,600,600)}
    if($p.ScatterPlot -and (Test-Path -LiteralPath $p.ScatterPlot)){[void]$sl.Shapes.AddPicture($p.ScatterPlot,$false,$true,660,90,600,600)}
    $slideNum++
}

try{$pres.SaveAs($pptPath)}
catch{
    $ts=Get-Date -Format 'yyyyMMdd_HHmmss'
    $pptPath=Join-Path $OutputDir ("vmin_starting_point_analysis_{0}.pptx" -f $ts)
    Write-Warning "PPT locked. Saving to: $pptPath"; $pres.SaveAs($pptPath)
}
try{$pres.Close()}catch{Write-Warning "PPT close: $($_.Exception.Message)"}
try{$pp.Quit()}catch{Write-Warning "PPT quit: $($_.Exception.Message)"}

Write-Host 'Generated artifacts:'
Write-Host " - $fitCsv"; Write-Host " - $domainCsv"; Write-Host " - $upmBoundsCsv"
Write-Host " - $plotIndexCsv"; Write-Host " - $overlayCsv"
Write-Host " - $nbPath"; Write-Host " - $pptPath"