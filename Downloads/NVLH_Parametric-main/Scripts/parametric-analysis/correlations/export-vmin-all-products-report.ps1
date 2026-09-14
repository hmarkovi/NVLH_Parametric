#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputDir = ".\output\vmin-all-products-validation-py",
    [string]$NotebookName = "vmin_all_products_validation.ipynb",
    [string]$PptName = "vmin_all_products_validation.pptx"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $PSCommandPath
if (-not [System.IO.Path]::IsPathRooted($OutputDir)) {
    $OutputDir = Join-Path $scriptDir $OutputDir
}
if (-not (Test-Path -LiteralPath $OutputDir)) {
    throw "Output directory does not exist: $OutputDir"
}

$fitCsv = Join-Path $OutputDir 'vmin_by_product_linear_fit_summary.csv'
$tableCsv = Join-Path $OutputDir 'vmin_by_product_normalized_table.csv'
$productSummaryCsv = Join-Path $OutputDir 'product_summary.csv'
$upmBoundsCsv = Join-Path $OutputDir 'upm_outlier_bounds.csv'

$required = @($fitCsv, $tableCsv, $productSummaryCsv, $upmBoundsCsv)
$missing = @($required | Where-Object { -not (Test-Path -LiteralPath $_) })
if ($missing.Count -gt 0) {
    throw ("Missing required CSV outputs:`n - " + ($missing -join "`n - "))
}

$fitRows = Import-Csv -LiteralPath $fitCsv
$tableRows = Import-Csv -LiteralPath $tableCsv
$productSummaryRows = Import-Csv -LiteralPath $productSummaryCsv
$upmRows = Import-Csv -LiteralPath $upmBoundsCsv

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

function Get-TopFitsText {
    param([object[]]$Rows)

    $top = @(
        $Rows |
            Where-Object { $_.Samples -and [int]$_.Samples -ge 20 -and $_.R2 -ne '' } |
            Sort-Object {[double]$_.R2} -Descending |
            Select-Object -First 15
    )

    $lines = @('Product | Die | Domain | Freq | Core | R2 | N | Vmin@Target')
    foreach ($r in $top) {
        $lines += ('{0} | {1} | {2} | {3:0.###} | {4} | {5:0.###} | {6} | {7:0.###}' -f
            $r.Product, $r.Die, $r.Domain, [double]$r.FrequencyGHz, [int]$r.Core, [double]$r.R2, [int]$r.Samples, [double]$r.Vmin_At_Target)
    }

    if ($top.Count -eq 0) {
        $lines += 'No fit rows met the Top Fits filter (Samples >= 20 with numeric R2).'
    }

    return ($lines -join "`r`n")
}

Write-Host 'Building notebook from grouped CSV outputs...'
$generatedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
$productPreview = ($productSummaryRows | Select-Object -First 20 | ConvertTo-Csv -NoTypeInformation) -join "`n"
$normalizedPreview = ($tableRows | Select-Object -First 40 | ConvertTo-Csv -NoTypeInformation) -join "`n"

$nbObj = [ordered]@{
    cells = @(
        [ordered]@{
            cell_type = 'markdown'
            metadata = @{ language = 'markdown' }
            source = @(
                '# Vmin All-Products Validation Report',
                "Generated: $generatedAt",
                '',
                'This notebook is generated from precomputed grouped CSV outputs.',
                'Outlier policy used by the data pipeline:',
                '- Vmin excluded when < 0 or >= 2',
                '- UPM excluded when outside median +/- 3*sigma'
            )
        },
        [ordered]@{
            cell_type = 'code'
            metadata = @{ language = 'python' }
            source = @(
                'import pandas as pd',
                "out_dir = r'$($OutputDir -replace '\\','\\\\')'",
                "fit_path = out_dir + r'\\vmin_by_product_linear_fit_summary.csv'",
                "table_path = out_dir + r'\\vmin_by_product_normalized_table.csv'",
                "prod_path = out_dir + r'\\product_summary.csv'",
                "upm_path = out_dir + r'\\upm_outlier_bounds.csv'",
                'fit_df = pd.read_csv(fit_path)',
                'table_df = pd.read_csv(table_path)',
                'prod_df = pd.read_csv(prod_path)',
                'upm_df = pd.read_csv(upm_path)',
                'fit_df.head()'
            )
        },
        [ordered]@{
            cell_type = 'code'
            metadata = @{ language = 'python' }
            source = @(
                'prod_df.sort_values("SourceRows", ascending=False)',
                'table_df.sort_values(["Product","Die","Domain","Freq"]).head(50)'
            )
        },
        [ordered]@{
            cell_type = 'code'
            metadata = @{ language = 'python' }
            source = @(
                'vf_curves = table_df.groupby(["Product","Die","Domain"]).size().reset_index(name="points")',
                'vf_curves.sort_values(["Product","Die","Domain"]).head(100)'
            )
        },
        [ordered]@{
            cell_type = 'markdown'
            metadata = @{ language = 'markdown' }
            source = @(
                '## Product Summary Preview',
                '',
                '```csv',
                $productPreview,
                '```',
                '',
                '## Normalized Table Preview',
                '',
                '```csv',
                $normalizedPreview,
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

$nbPath = Join-Path $OutputDir $NotebookName
($nbObj | ConvertTo-Json -Depth 30) | Set-Content -LiteralPath $nbPath -Encoding UTF8

Write-Host 'Building PowerPoint from grouped CSV outputs...'
$pptPath = Join-Path $OutputDir $PptName

try {
    $pp = New-Object -ComObject PowerPoint.Application
    $pp.Visible = -1
    $pres = $pp.Presentations.Add()

    $s1 = $pres.Slides.Add(1, 12)
    [void](Add-TextBox -Slide $s1 -Text 'Vmin Validation Across All Products' -Left 30 -Top 20 -Width 1200 -Height 50 -FontSize 34 -Bold $true)

    $products = @($productSummaryRows | Select-Object -ExpandProperty Product)
    $outlierSummary = @($productSummaryRows | Measure-Object -Property VminExcluded -Sum)
    $upmSummary = @($productSummaryRows | Measure-Object -Property UpmExcluded -Sum)
    $acceptedSummary = @($productSummaryRows | Measure-Object -Property AcceptedPoints -Sum)

    $overview = @(
        "CSV output directory: $OutputDir",
        "Products: $($products -join ', ')",
        "Rows in fit summary: $($fitRows.Count)",
        "Rows in normalized table: $($tableRows.Count)",
        '',
        'Outlier policy:',
        '  Vmin: exclude if < 0 or >= 2',
        '  UPM: exclude if outside median +/- 3*sigma',
        '',
        ('Totals from product summary: Accepted={0}  VminExcluded={1}  UpmExcluded={2}' -f
            [int]$acceptedSummary.Sum, [int]$outlierSummary.Sum, [int]$upmSummary.Sum)
    ) -join "`r`n"
    [void](Add-TextBox -Slide $s1 -Text $overview -Left 40 -Top 100 -Width 1180 -Height 320 -FontSize 19)

    $upmLines = @('UPM bounds:')
    foreach ($u in $upmRows) {
        $upmLines += ('- {0}: [{1:0.###}, {2:0.###}]  N={3}' -f $u.UpmColumn, [double]$u.LowBound, [double]$u.HighBound, [int]$u.N)
    }
    [void](Add-TextBox -Slide $s1 -Text ($upmLines -join "`r`n") -Left 40 -Top 430 -Width 1180 -Height 240 -FontSize 14)

    $s2 = $pres.Slides.Add(2, 12)
    [void](Add-TextBox -Slide $s2 -Text 'Top Fits by R2 (Samples >= 20)' -Left 30 -Top 20 -Width 1200 -Height 40 -FontSize 30 -Bold $true)
    [void](Add-TextBox -Slide $s2 -Text (Get-TopFitsText -Rows $fitRows) -Left 40 -Top 90 -Width 1220 -Height 620 -FontSize 14)

    $slideNum = 3
    foreach ($prod in $products) {
        $rows = @($tableRows | Where-Object { $_.Product -eq $prod } | Sort-Object Die, Domain, {[double]$_.Freq} | Select-Object -First 20)
        $slide = $pres.Slides.Add($slideNum, 12)
        [void](Add-TextBox -Slide $slide -Text ("Product {0}: Normalized Vmin Table" -f $prod) -Left 30 -Top 20 -Width 1200 -Height 40 -FontSize 28 -Bold $true)

        $tableRowsCount = [math]::Max(2, [math]::Min($rows.Count + 1, 21))
        $shape = $slide.Shapes.AddTable($tableRowsCount, 4, 30, 90, 1240, 580)
        $tbl = $shape.Table
        $tbl.Cell(1,1).Shape.TextFrame.TextRange.Text = 'Die'
        $tbl.Cell(1,2).Shape.TextFrame.TextRange.Text = 'Domain'
        $tbl.Cell(1,3).Shape.TextFrame.TextRange.Text = 'Freq (GHz)'
        $tbl.Cell(1,4).Shape.TextFrame.TextRange.Text = 'Vmin'

        for ($i = 0; $i -lt ($tableRowsCount - 1) -and $i -lt $rows.Count; $i++) {
            $r = $rows[$i]
            $tbl.Cell($i + 2, 1).Shape.TextFrame.TextRange.Text = [string]$r.Die
            $tbl.Cell($i + 2, 2).Shape.TextFrame.TextRange.Text = [string]$r.Domain
            $tbl.Cell($i + 2, 3).Shape.TextFrame.TextRange.Text = ('{0:0.###}' -f [double]$r.Freq)
            $tbl.Cell($i + 2, 4).Shape.TextFrame.TextRange.Text = ('{0:0.###}' -f [double]$r.Vmin)
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
Write-Host " - $nbPath"
Write-Host " - $pptPath"
