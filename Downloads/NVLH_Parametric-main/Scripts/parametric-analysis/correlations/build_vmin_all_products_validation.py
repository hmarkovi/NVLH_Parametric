from __future__ import print_function
import csv
import math
import os
import sys
from collections import defaultdict

INPUT_CSV = r"R:\Products\NVL\NVL-H\Weekly Runs\Vmin_NVLHM66A0H30N00S623_WW25_2026_clean all products.csv"
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
OUTPUT_DIR = os.path.join(SCRIPT_DIR, 'output', 'vmin-all-products-validation-py')

UPM_U5_COL = 'UPM_0107_DPMH156P48ULVTINVD4_FULLDIE_0950_MED_SORT_U1.U5'


def ensure_dir(path):
    if not os.path.isdir(path):
        os.makedirs(path)


def to_float(value):
    if value is None:
        return None
    value = value.strip().strip('"')
    if not value:
        return None
    try:
        return float(value)
    except Exception:
        return None


def median(values):
    if not values:
        return None
    ordered = sorted(values)
    n = len(ordered)
    mid = n // 2
    if n % 2:
        return ordered[mid]
    return (ordered[mid - 1] + ordered[mid]) / 2.0


def linear_fit(xs, ys):
    n = len(xs)
    if n < 3:
        return None, None, None, n
    sum_x = sum(xs)
    sum_y = sum(ys)
    sum_xy = 0.0
    sum_xx = 0.0
    for i in range(n):
        sum_xy += xs[i] * ys[i]
        sum_xx += xs[i] * xs[i]
    den = (n * sum_xx) - (sum_x * sum_x)
    if abs(den) < 1e-12:
        return None, None, None, n
    slope = ((n * sum_xy) - (sum_x * sum_y)) / den
    intercept = (sum_y - slope * sum_x) / float(n)
    mean_y = sum_y / float(n)
    ss_tot = 0.0
    ss_res = 0.0
    for i in range(n):
        pred = slope * xs[i] + intercept
        ss_tot += (ys[i] - mean_y) ** 2
        ss_res += (ys[i] - pred) ** 2
    r2 = None
    if ss_tot > 0:
        r2 = 1.0 - (ss_res / ss_tot)
    return slope, intercept, r2, n


def parse_vmin_column(col):
    if not col.startswith('UPSVF-HOT_'):
        return None
    parts = col.split('_')
    if len(parts) < 4:
        return None
    try:
        domain = parts[1]
        freq = float(parts[2])
        core = int(parts[3])
    except Exception:
        return None
    return domain, freq, core


def get_die_config(domain, upm_u2_col, upm_u4_col):
    if domain in ('GT', 'GTVPG'):
        return ('GTDIE', upm_u4_col, upm_u4_col, None, 0.85)
    if domain in ('AT', 'CR', 'CCF', 'CLR') or domain.startswith('CR'):
        return ('CDIE', UPM_U5_COL, UPM_U5_COL + ' S2T', 9154.0, 0.87)
    return ('HUBDIE', upm_u2_col, upm_u2_col, None, 0.85)


def write_csv(path, headers, rows):
    with open(path, 'w', newline='') as fh:
        writer = csv.writer(fh)
        writer.writerow(headers)
        for row in rows:
            writer.writerow(row)


def main():
    ensure_dir(OUTPUT_DIR)

    with open(INPUT_CSV, 'r', newline='') as fh:
        reader = csv.reader(fh)
        headers = next(reader)

    header_index = dict((name, idx) for idx, name in enumerate(headers))
    prod_col = 'prod' if 'prod' in header_index else ('product' if 'product' in header_index else None)
    if prod_col is None:
        raise RuntimeError('Could not find prod/product column')

    upm_u2_col = None
    upm_u4_col = None
    for name in headers:
        if upm_u2_col is None and name.startswith('TPI_UPM::UPM_X_SCREEN_K_START_X_X_X_X_FEM_CALC_UPM_FEM_') and name.endswith('SORT_U1.U2'):
            upm_u2_col = name
        if upm_u4_col is None and name.startswith('TPI_UPM::UPM_X_SCREEN_K_START_X_X_X_X_FEM_CALC_UPM_FEM_') and name.endswith('SORT_U1.U4'):
            upm_u4_col = name
    if UPM_U5_COL not in header_index:
        raise RuntimeError('Missing U5 UPM column')
    if upm_u2_col is None or upm_u4_col is None:
        raise RuntimeError('Missing U2/U4 UPM columns')

    meta = []
    for col in headers:
        parsed = parse_vmin_column(col)
        if not parsed:
            continue
        domain, freq, core = parsed
        die, upm_col, upm_label, divisor, target = get_die_config(domain, upm_u2_col, upm_u4_col)
        meta.append({
            'vmin_col': col,
            'domain': domain,
            'freq': freq,
            'core': core,
            'die': die,
            'upm_col': upm_col,
            'upm_label': upm_label,
            'divisor': divisor,
            'target': target,
            'idx_vmin': header_index[col],
            'idx_upm': header_index[upm_col],
        })

    print('Mapped Vmin columns:', len(meta))

    upm_indices = dict((col, header_index[col]) for col in set(m['upm_col'] for m in meta))

    upm_values = dict((col, []) for col in upm_indices)
    print('Pre-pass: collecting UPM population for 3-sigma bounds...')
    with open(INPUT_CSV, 'r', newline='') as fh:
        reader = csv.reader(fh)
        next(reader)
        row_count = 0
        for row in reader:
            row_count += 1
            for col, values in upm_values.items():
                idx = upm_indices[col]
                if idx >= len(row):
                    continue
                val = to_float(row[idx])
                if val is not None:
                    values.append(val)
            if row_count % 10000 == 0:
                print('  pre-pass rows:', row_count)

    upm_bounds = {}
    for col, values in upm_values.items():
        if len(values) < 4:
            continue
        med = median(values)
        mean = sum(values) / float(len(values))
        sigma = math.sqrt(sum((v - mean) ** 2 for v in values) / float(len(values)))
        upm_bounds[col] = {
            'median': med,
            'sigma': sigma,
            'low': med - 3.0 * sigma,
            'high': med + 3.0 * sigma,
            'n': len(values),
        }
        print('  [%s] median=%.4f sigma=%.4f keep [%.4f, %.4f] N=%d' % (col, med, sigma, med - 3.0 * sigma, med + 3.0 * sigma, len(values)))

    points = defaultdict(lambda: {'xs': [], 'ys': [], 'product': None, 'die': None, 'domain': None, 'freq': None, 'core': None, 'vmin_col': None, 'upm_label': None, 'target': None})
    product_rows = defaultdict(int)
    outliers = defaultdict(lambda: {'vmin': 0, 'upm': 0, 'accepted': 0})
    totals = {'vmin': 0, 'upm': 0, 'accepted': 0}
    raw_points_csv = os.path.join(OUTPUT_DIR, 'accepted_points_by_product.csv')

    print('Second pass: grouping all material by product...')
    with open(raw_points_csv, 'w', newline='') as raw_fh:
        raw_writer = csv.writer(raw_fh)
        raw_writer.writerow(['Product', 'Die', 'Domain', 'Freq', 'Core', 'VminColumn', 'X', 'Y'])
        with open(INPUT_CSV, 'r', newline='') as fh:
            reader = csv.reader(fh)
            next(reader)
            row_count = 0
            for row in reader:
                row_count += 1
                prod = row[header_index[prod_col]].strip().strip('"') if header_index[prod_col] < len(row) else ''
                if not prod:
                    continue
                product_rows[prod] += 1
                for m in meta:
                    if m['idx_vmin'] >= len(row) or m['idx_upm'] >= len(row):
                        continue
                    upm_raw = to_float(row[m['idx_upm']])
                    vmin_raw = to_float(row[m['idx_vmin']])
                    if upm_raw is None or vmin_raw is None:
                        continue
                    if vmin_raw < 0.0 or vmin_raw >= 2.0:
                        totals['vmin'] += 1
                        outliers[prod]['vmin'] += 1
                        continue
                    b = upm_bounds.get(m['upm_col'])
                    if b is not None and (upm_raw < b['low'] or upm_raw > b['high']):
                        totals['upm'] += 1
                        outliers[prod]['upm'] += 1
                        continue
                    totals['accepted'] += 1
                    outliers[prod]['accepted'] += 1
                    x_val = upm_raw / m['divisor'] if m['divisor'] else upm_raw
                    key = (prod, m['die'], m['domain'], m['freq'], m['core'], m['vmin_col'])
                    bucket = points[key]
                    if bucket['product'] is None:
                        bucket['product'] = prod
                        bucket['die'] = m['die']
                        bucket['domain'] = m['domain']
                        bucket['freq'] = m['freq']
                        bucket['core'] = m['core']
                        bucket['vmin_col'] = m['vmin_col']
                        bucket['upm_label'] = m['upm_label']
                        bucket['target'] = m['target']
                    bucket['xs'].append(x_val)
                    bucket['ys'].append(vmin_raw)
                    raw_writer.writerow([prod, m['die'], m['domain'], m['freq'], m['core'], m['vmin_col'], x_val, vmin_raw])
                if row_count % 5000 == 0:
                    print('  second-pass rows:', row_count, 'accepted points:', totals['accepted'])

    print('Outlier summary: Vmin excluded=%d UPM excluded=%d Accepted=%d' % (totals['vmin'], totals['upm'], totals['accepted']))

    fit_rows = []
    normalized_groups = defaultdict(list)
    for key, bucket in points.items():
        slope, intercept, r2, count = linear_fit(bucket['xs'], bucket['ys'])
        vmin_at_target = None
        if slope is not None and intercept is not None:
            vmin_at_target = slope * bucket['target'] + intercept
            normalized_groups[(bucket['product'], bucket['die'], bucket['domain'], bucket['freq'])].append(vmin_at_target)
        fit_rows.append([
            bucket['product'], bucket['die'], bucket['domain'], bucket['freq'], bucket['core'], bucket['vmin_col'],
            bucket['upm_label'], bucket['target'], count, slope, intercept, r2, vmin_at_target
        ])

    normalized_rows = []
    for group_key, values in sorted(normalized_groups.items()):
        product, die, domain, freq = group_key
        normalized_rows.append([product, die, domain, freq, round(sum(values) / float(len(values)), 4), len(values)])

    product_summary_rows = []
    for prod in sorted(product_rows.keys()):
        stats = outliers[prod]
        product_summary_rows.append([prod, product_rows[prod], stats['accepted'], stats['vmin'], stats['upm']])

    fit_csv = os.path.join(OUTPUT_DIR, 'vmin_by_product_linear_fit_summary.csv')
    table_csv = os.path.join(OUTPUT_DIR, 'vmin_by_product_normalized_table.csv')
    product_summary_csv = os.path.join(OUTPUT_DIR, 'product_summary.csv')
    upm_bounds_csv = os.path.join(OUTPUT_DIR, 'upm_outlier_bounds.csv')
    write_csv(fit_csv,
              ['Product', 'Die', 'Domain', 'FrequencyGHz', 'Core', 'VminColumn', 'UpmLabel', 'TargetS2T', 'Samples', 'Slope', 'Intercept', 'R2', 'Vmin_At_Target'],
              sorted(fit_rows, key=lambda r: (r[0], r[1], r[2], r[3], r[4])))
    write_csv(table_csv,
              ['Product', 'Die', 'Domain', 'Freq', 'Vmin', 'Contributors'],
              normalized_rows)
    write_csv(product_summary_csv,
              ['Product', 'SourceRows', 'AcceptedPoints', 'VminExcluded', 'UpmExcluded'],
              product_summary_rows)
    write_csv(upm_bounds_csv,
              ['UpmColumn', 'Median', 'Sigma', 'LowBound', 'HighBound', 'N'],
              [[col, b['median'], b['sigma'], b['low'], b['high'], b['n']] for col, b in sorted(upm_bounds.items())])

    print('Generated artifacts:')
    print(' - ' + fit_csv)
    print(' - ' + table_csv)
    print(' - ' + product_summary_csv)
    print(' - ' + upm_bounds_csv)
    print(' - ' + raw_points_csv)


if __name__ == '__main__':
    main()
