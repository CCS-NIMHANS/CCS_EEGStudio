"""Participant-weighted ERP and statistical publication figures.

No statistical significance is inferred from grand averages. Repeated recordings
within the same participant/cell are averaged before between-participant SEM.
Time grids must match; incompatible records are reported rather than resampled.
"""
import csv
import json
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import numpy as np
import matplotlib

matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D
from scipy.interpolate import griddata
from scipy import stats
from group_stats import (
    ELECTRODE_COORDS_2D,
    check_topoplot_suitability,
    normalize_channel_name,
)


_active_engine = None
_DEFAULT_PALETTE = [
    '#0072B2',
    '#D55E00',
    '#009E73',
    '#CC79A7',
    '#B45309',
    '#6D28D9',
    '#0284C7',
    '#334155',
]


def stop_engine(_signal, _frame):
    if _active_engine is not None:
        _active_engine.terminate()
        try:
            _active_engine.wait(timeout=3)
        except subprocess.TimeoutExpired:
            _active_engine.kill()
    raise SystemExit(143)


def run_engine(engine, path):
    global _active_engine
    _active_engine = subprocess.Popen(
        [engine, str(path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        stdout, stderr = _active_engine.communicate()
        if _active_engine.returncode:
            raise ValueError(stderr[-4000:])
        return json.loads(stdout)
    finally:
        _active_engine = None


def participant(value):
    return re.sub(r'(?i)(?:_?SESSION|_?SES[-_]?)[0-9]+.*$', '', str(value))


def read_records(options):
    folder = Path(options['folder'])
    paths = sorted(folder.glob('*_erp_results.ccserp'))
    if not paths:
        paths = sorted(folder.glob('*.ccserp'))
    if not paths and (folder / 'erp_results.json').exists():
        paths = [folder / 'erp_results.json']
    metadata = options.get('metadata', [])
    subjects = {str(row.get('subjid', '')) for row in metadata if row.get('subjid')}
    if subjects:
        selected = [
            path
            for path in paths
            if any(path.stem.startswith(value + '_') for value in subjects)
        ]
        if selected:
            paths = selected
    seen = set()
    for path in paths:
        with path.open(encoding='utf-8') as stream:
            payload = json.load(stream)
        for record in payload.get('files', []):
            identity = (record.get('path'), record.get('task'), record.get('subject'))
            if identity in seen:
                continue
            seen.add(identity)
            matches = [
                row
                for row in metadata
                if str(row.get('filename', '')) == record.get('path')
                or str(row.get('subjid', '')) == record.get('subject')
            ]
            if not matches:
                continue  # Never guess cohort membership from directory order.
            yield record, matches


def _resolve_color(palette, key, index):
    color = palette.get(key, _DEFAULT_PALETTE[index % len(_DEFAULT_PALETTE)])
    if isinstance(color, int):
        return f'#{color & 0xffffff:06x}'
    return str(color)


def _render_stats_plot(options):
    output = Path(options['output_dir'])
    output.mkdir(parents=True, exist_ok=True)
    payload = options.get('stats_payload', {})
    metric_label = payload.get('metric_label', 'ERP Metric')
    model_summary = payload.get('model_summary', '')
    contrast_summary = payload.get('contrast_summary', '')
    plot_type = payload.get('plot_type', 'boxplot')
    use_sem = bool(payload.get('use_sem', True))
    x_factor = payload.get('x_factor')
    series_factor = payload.get('series_factor')
    facet_col_factor = payload.get('facet_col_factor')
    facet_row_factor = payload.get('facet_row_factor')
    factor_labels = payload.get('factor_labels', {})
    level_labels = payload.get('level_labels', {})
    series_colors = payload.get('series_colors', {})
    factor_levels = payload.get('factor_levels', {})
    cell_descriptives = payload.get('cell_descriptives', {})
    brackets_by_panel = payload.get('brackets_by_panel', {})

    def f_label(f):
        return 'None' if not f else factor_labels.get(f, f)

    def l_label(f, val):
        return level_labels.get(f, {}).get(val, val) if f else val

    x_levels = factor_levels.get(x_factor, ['All']) if x_factor else ['All']
    series_levels = (
        factor_levels.get(series_factor, ['All']) if series_factor else ['All']
    )
    col_levels = (
        factor_levels.get(facet_col_factor, ['All'])
        if facet_col_factor
        else ['All']
    )
    row_levels = (
        factor_levels.get(facet_row_factor, ['All'])
        if facet_row_factor
        else ['All']
    )

    def cell_vals(row_v, col_v, ser_v, x_v):
        matched = []
        for k, desc in cell_descriptives.items():
            parts = {}
            for seg in str(k).split('|'):
                if '=' in seg:
                    kk, vv = seg.split('=', 1)
                    parts[kk] = vv
            if x_factor and parts.get(x_factor) != x_v:
                continue
            if series_factor and ser_v is not None and parts.get(series_factor) != ser_v:
                continue
            if facet_col_factor and col_v is not None and parts.get(facet_col_factor) != col_v:
                continue
            if facet_row_factor and row_v is not None and parts.get(facet_row_factor) != row_v:
                continue
            vals = desc.get('values') or []
            matched.extend(float(v) for v in vals)
        return np.asarray(sorted(matched), dtype=float)

    font_size = float(options.get('font_size', 10))
    plt.rcParams.update(
        {
            'font.size': font_size,
            'svg.fonttype': 'none',
            'pdf.fonttype': 42,
        }
    )

    nrows = max(1, len(row_levels))
    ncols = max(1, len(col_levels))
    width = float(
        options.get('width') or max(6.5, ncols * max(3.6, 0.9 * len(x_levels) + 1.8))
    )
    height = float(options.get('height') or max(4.2, nrows * 3.8 + 1.1))
    fig, axes = plt.subplots(
        nrows,
        ncols,
        squeeze=False,
        sharey=True,
        figsize=(width, height),
        layout='constrained',
    )

    # Compute global Y limits
    all_vals = []
    for r in row_levels:
        for c in col_levels:
            for s in series_levels:
                for x in x_levels:
                    arr = cell_vals(
                        r if facet_row_factor else None,
                        c if facet_col_factor else None,
                        s if series_factor else None,
                        x,
                    )
                    if arr.size:
                        all_vals.append(arr)
    if all_vals:
        cat = np.concatenate(all_vals)
        ymin, ymax = float(np.min(cat)), float(np.max(cat))
        span = max(1e-6, ymax - ymin)
        ymin -= span * 0.12
        ymax += span * 0.12
    else:
        ymin, ymax = 0.0, 10.0

    n_s = len(series_levels)
    rng = np.random.default_rng(42)

    for ri, r in enumerate(row_levels):
        for ci, c in enumerate(col_levels):
            ax = axes[ri, ci]
            panel_brackets = brackets_by_panel.get(f'{r}|{c}', [])
            n_b = len(panel_brackets)

            for si, s in enumerate(series_levels):
                col = _resolve_color(series_colors, s, si)
                xs_pos = []
                means = []
                errs = []
                for xi, x in enumerate(x_levels):
                    arr = cell_vals(
                        r if facet_row_factor else None,
                        c if facet_col_factor else None,
                        s if series_factor else None,
                        x,
                    )
                    if plot_type == 'line':
                        offset = (si - (n_s - 1) / 2.0) * 0.06 if n_s > 1 else 0.0
                    else:
                        offset = (
                            (si - (n_s - 1) / 2.0) * (0.72 / max(1, n_s))
                            if n_s > 1
                            else 0.0
                        )
                    xpos = xi + offset
                    if arr.size == 0:
                        continue
                    m = float(np.mean(arr))
                    sd = float(np.std(arr, ddof=1)) if arr.size > 1 else 0.0
                    err = sd / np.sqrt(arr.size) if use_sem else sd
                    xs_pos.append(xpos)
                    means.append(m)
                    errs.append(err)

                    if plot_type == 'bar':
                        bw = 0.62 / max(1, n_s)
                        ax.bar(
                            xpos,
                            m,
                            width=bw,
                            color=col,
                            alpha=0.72,
                            edgecolor=col,
                            linewidth=1.0,
                            zorder=3,
                        )
                        ax.errorbar(
                            xpos,
                            m,
                            yerr=err,
                            fmt='none',
                            ecolor='#334155',
                            elinewidth=1.2,
                            capsize=3,
                            zorder=4,
                        )
                    elif plot_type == 'boxplot':
                        bw = 0.58 / max(1, n_s)
                        bp = ax.boxplot(
                            [arr],
                            positions=[xpos],
                            widths=bw,
                            patch_artist=True,
                            showfliers=False,
                            zorder=3,
                        )
                        for box in bp['boxes']:
                            box.set_facecolor(col)
                            box.set_alpha(0.28)
                            box.set_edgecolor(col)
                            box.set_linewidth(1.3)
                        for med in bp['medians']:
                            med.set_color('#0F172A')
                            med.set_linewidth(1.8)
                        for wk in bp['whiskers'] + bp['caps']:
                            wk.set_color(col)
                            wk.set_linewidth(1.1)
                        jitter = rng.uniform(-bw * 0.3, bw * 0.3, size=arr.size)
                        ax.scatter(
                            xpos + jitter,
                            arr,
                            s=12,
                            color=col,
                            alpha=0.45,
                            edgecolors='none',
                            zorder=2,
                        )

                if plot_type == 'line' and xs_pos:
                    ax.errorbar(
                        xs_pos,
                        means,
                        yerr=errs,
                        color=col,
                        marker='o',
                        markersize=5.5,
                        linewidth=2.0,
                        capsize=3,
                        zorder=4,
                    )

            # Draw significance brackets above data range
            span = max(1e-6, ymax - ymin)
            bracket_step = span * 0.085
            top_lim = ymax + (n_b + 0.5) * bracket_step if n_b > 0 else ymax
            ax.set_ylim(ymin, top_lim)

            def bracket_x(xi, si):
                if plot_type == 'line':
                    return xi + ((si - (n_s - 1) / 2.0) * 0.06 if n_s > 1 else 0.0)
                return xi + (
                    (si - (n_s - 1) / 2.0) * (0.72 / max(1, n_s))
                    if n_s > 1
                    else 0.0
                )

            for bi, b in enumerate(panel_brackets):
                xa = bracket_x(int(b['x_a']), int(b['series_a']))
                xb = bracket_x(int(b['x_b']), int(b['series_b']))
                lx, rx = min(xa, xb), max(xa, xb)
                if b['series_a'] != b['series_b'] and (rx - lx) < 0.14:
                    mid = 0.5 * (lx + rx)
                    lx, rx = mid - 0.07, mid + 0.07
                by = ymax + (n_b - 1 - bi) * bracket_step + span * 0.02
                bcol = (
                    '#B45309'
                    if b['series_a'] != b['series_b']
                    else _resolve_color(
                        series_colors,
                        series_levels[int(b['series_a']) % n_s],
                        int(b['series_a']),
                    )
                )
                ax.plot(
                    [lx, lx, rx, rx],
                    [by - span * 0.015, by, by, by - span * 0.015],
                    color=bcol,
                    linewidth=1.2,
                    zorder=5,
                )
                ax.text(
                    0.5 * (lx + rx),
                    by + span * 0.008,
                    b['label'],
                    ha='center',
                    va='bottom',
                    fontsize=max(7.5, font_size - 1.5),
                    fontweight='bold',
                    color=bcol,
                )

            ax.axhline(0, color='#94A3B8', linewidth=0.8, zorder=1)
            ax.grid(axis='y', color='#E2E8F0', linewidth=0.7, zorder=0)
            ax.spines[['top', 'right']].set_visible(False)
            ax.set_xticks(range(len(x_levels)))
            ax.set_xticklabels([l_label(x_factor, x) for x in x_levels])
            ax.set_xlim(-0.55, len(x_levels) - 0.45)

            title_parts = []
            if facet_row_factor:
                title_parts.append(f'{f_label(facet_row_factor)}: {l_label(facet_row_factor, r)}')
            if facet_col_factor:
                title_parts.append(f'{f_label(facet_col_factor)}: {l_label(facet_col_factor, c)}')
            if title_parts:
                ax.set_title(' · '.join(title_parts), fontsize=font_size, fontweight='bold')
            if ci == 0:
                ax.set_ylabel(metric_label)

    if series_factor and series_levels:
        handles = [
            Line2D(
                [0],
                [0],
                color=_resolve_color(series_colors, s, si),
                marker='o' if plot_type == 'line' else 's',
                linestyle='-' if plot_type == 'line' else 'None',
                markersize=7,
                linewidth=2,
                label=l_label(series_factor, s),
            )
            for si, s in enumerate(series_levels)
        ]
        fig.legend(
            handles=handles,
            loc='upper center',
            ncol=min(len(handles), 6),
            frameon=False,
            fontsize=font_size,
            bbox_to_anchor=(0.5, 0.95),
        )
        fig.get_layout_engine().set(rect=(0.0, 0.03, 1.0, 0.87))

    suptitle = metric_label
    if model_summary:
        suptitle = f'{metric_label} — {model_summary}'
    fig.suptitle(suptitle, fontsize=font_size + 1, fontweight='bold', y=0.99)
    if contrast_summary:
        fig.text(
            0.5,
            0.01,
            contrast_summary,
            ha='center',
            va='bottom',
            fontsize=max(7.5, font_size - 2),
            color='#475569',
        )

    stem_str = options.get('output_stem')
    stem = Path(stem_str) if stem_str else (output / 'GroupStats_publication')
    paths = []
    dpi = int(options.get('dpi', 300))
    for suffix in ['png', 'svg', 'pdf']:
        path = stem.with_suffix('.' + suffix)
        fig.savefig(path, dpi=dpi, facecolor='white', bbox_inches='tight')
        paths.append(str(path))
    plt.close(fig)
    stem.with_suffix('.json').write_text(
        json.dumps(options, indent=2), encoding='utf-8'
    )
    return dict(paths=paths, warnings=[], n_matched_files=0)


def render(options):
    mode = options.get('mode', 'erp')
    if mode == 'stats_plot':
        return _render_stats_plot(options)

    output = Path(options['output_dir'])
    output.mkdir(parents=True, exist_ok=True)
    records = list(read_records(options))
    if not records:
        raise ValueError(
            'No saved ERP results match the reviewed measurement rows. Choose the folder containing the matching .ccserp files.'
        )

    factor_labels = options.get('factor_labels', {})
    aliases = options.get('level_labels', {})
    label = lambda factor, value: aliases.get(factor, {}).get(value, value)
    excluded = options.get('excluded_levels', {})
    metadata_allowed = lambda row: all(
        str(row.get(f, '')) not in values for f, values in excluded.items()
    )
    series_factor = options.get('series_factor')
    facet_factor = options.get('facet_factor')
    row_factor = options.get('row_factor')
    factor_value = lambda row, factor: str(row.get(factor, 'All')) if factor else 'All'
    grouping = lambda row: (
        factor_value(row, row_factor),
        factor_value(row, facet_factor),
        factor_value(row, series_factor),
    )
    subject_col = options.get('subject_col') or 'participant_id'
    subject = lambda row, record: str(
        row.get(subject_col) or participant(record.get('subject', record.get('path')))
    )

    if mode == 'difference_table':
        rows = []
        for record, matches in records:
            allowed = [row for row in matches if metadata_allowed(row)]
            if not allowed:
                continue
            measure = record.get('measurements', {}).get('B_minus_A')
            if not measure:
                continue
            row = dict(allowed[0])
            row.update(
                filename=record['path'],
                participant_id=subject(row, record),
                Condition='B_minus_A',
            )
            for key, source, scale in [
                ('mean_amplitude_ERP', 'mean', 1),
                ('signed_auc_ERP', 'signed_auc', 1),
                ('peak_amplitude_ERP', 'peak_amplitude', 1),
                ('peak_latency_ms_ERP', 'peak_latency', 1000),
                ('fractional_area_latency_ms_ERP', 'fractional_area_latency', 1000),
            ]:
                row[key] = measure.get(source, '')
                if isinstance(row[key], (float, int)):
                    row[key] *= scale
            rows.append(row)
        if not rows:
            raise ValueError(
                'No saved B-minus-A waveform measurements found. Compute the ERP difference in Measure ERP first.'
            )
        path = output / 'ERP_difference_group_input.csv'
        with path.open('w', newline='', encoding='utf-8') as stream:
            writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
            writer.writeheader()
            writer.writerows(rows)
        return dict(
            csv=str(path),
            n_records=len(rows),
            method='Saved B_minus_A waveform measurements, not subtraction of peak/latency scalars',
        )

    order = options.get('level_order', {})

    def ordered(values, factor):
        values = set(values)
        preferred = order.get(factor, [])
        return [v for v in preferred if v in values] + sorted(values - set(preferred))

    raw_conditions = list(
        dict.fromkeys(
            str(row.get('Condition', ''))
            for _, matches in records
            for row in matches
            if metadata_allowed(row) and row.get('Condition')
        )
    )
    raw_conditions = [v for v in raw_conditions if v not in ['B_minus_A', 'B - A']]
    raw_conditions = ordered(raw_conditions, 'Condition')

    plot_diff = bool(options.get('plot_differences_only', False)) and mode in [
        'erp',
        'topo',
    ]
    diff_pairs = []
    if plot_diff:
        for pair in options.get('difference_pairs', []):
            if isinstance(pair, (list, tuple)) and len(pair) == 2:
                cb, ca = str(pair[0]), str(pair[1])
                if cb != ca:
                    diff_pairs.append((cb, ca))
        if not diff_pairs and len(raw_conditions) >= 2:
            base = 'Freq' if 'Freq' in raw_conditions else raw_conditions[0]
            diff_pairs = [(c, base) for c in raw_conditions if c != base]
        conditions = [f'{cb} − {ca}' for cb, ca in diff_pairs]
    else:
        conditions = raw_conditions
        selected_conds = options.get('selected_conditions') or []
        if selected_conds:
            conditions = [c for c in conditions if c in selected_conds]

    if mode in ['rerp', 'ml']:
        conditions = [options.get('predictor', 'class') if mode == 'rerp' else 'AUC']

    channels = [
        v.strip().lower()
        for v in options.get('channels', 'Cz').split(',')
        if v.strip()
    ]
    selected_facets = set(options.get('selected_facets') or [])

    accumulated = {}
    grids = {}
    warnings = []
    tf_inputs = []
    tf_groups = {}
    tf_tmins = {}
    tf_counts = {}

    # Track canonical scalp channels for topography intersection across subjects
    topo_records = []

    for record, matches in records:
        used = set()
        for row in matches:
            if not metadata_allowed(row):
                continue
            group = grouping(row)
            if selected_facets and facet_factor and group[1] not in selected_facets:
                continue
            person = subject(row, record)
            if mode in ['ersp', 'itc']:
                if (group, person) in used:
                    continue
                used.add((group, person))
                requested = {
                    v.strip().lower()
                    for v in options.get('channels', 'Cz').split(',')
                    if v.strip()
                }
                if not requested.issubset(
                    {str(v).lower() for v in record.get('labels', [])}
                ):
                    warnings.append(
                        f'Missing requested TF ROI channels: {record.get("subject")}'
                    )
                    continue
                code = json.dumps(group)
                tf_groups[code] = group
                epoch = record.get('profile', {}).get('epoch')
                if epoch:
                    tf_tmins.setdefault(code, set()).add(float(epoch[0]) * 1000)
                tf_inputs.append(
                    dict(
                        path=record['path'],
                        subject=person,
                        group=code,
                        condition_a_labels=next(
                            (
                                c.get('codes', [c['name']])
                                for c in record.get('profile', {}).get('conditions', [])
                                if c['name'] == options.get('condition_a', 'Freq')
                            ),
                            [options.get('condition_a', 'Freq')],
                        ),
                        condition_b_labels=next(
                            (
                                c.get('codes', [c['name']])
                                for c in record.get('profile', {}).get('conditions', [])
                                if c['name'] == options.get('condition_b', 'Rare')
                            ),
                            [options.get('condition_b', 'Rare')],
                        ),
                    )
                )
                accepted = record.get('accepted_events', [])
                if accepted:
                    duration = float(accepted[0].get('epoch_end_s', 0)) - float(
                        accepted[0].get('epoch_start_s', 0)
                    )
                    if duration > 0 and all(
                        abs(
                            float(event.get('epoch_start_s', 0)) / duration
                            - round(float(event.get('epoch_start_s', 0)) / duration)
                        )
                        < 1e-4
                        for event in accepted
                    ):
                        item = tf_inputs[-1]
                        for kind in ['a', 'b']:
                            name = options.get(
                                'condition_' + kind, 'Freq' if kind == 'a' else 'Rare'
                            )
                            accepted_labels = set(
                                item['condition_' + kind + '_labels']
                            ) | {name}
                            item['condition_' + kind + '_trials'] = sorted(
                                {
                                    round(float(event['epoch_start_s']) / duration)
                                    for event in accepted
                                    if event.get('label') in accepted_labels
                                }
                            )
                        if (
                            not item['condition_a_trials']
                            or not item['condition_b_trials']
                        ):
                            warnings.append(
                                f'Missing accepted A/B trials: {record.get("subject")}'
                            )
                            tf_inputs.pop()
                continue

            if plot_diff:
                # Compute all requested difference pairs once per (group, person, record)
                times = np.asarray(record.get('times', []), dtype=float) * 1000
                labels = record.get('labels', [])
                ch_conds = record.get('channel_conditions', {})
                for cb, ca in diff_pairs:
                    cond_label = f'{cb} − {ca}'
                    if (group, person, cond_label) in used:
                        continue
                    data_b = np.asarray(ch_conds.get(cb, []), dtype=float)
                    data_a = np.asarray(ch_conds.get(ca, []), dtype=float)
                    if data_b.shape != (len(labels), len(times)) or data_a.shape != (
                        len(labels),
                        len(times),
                    ):
                        continue
                    used.add((group, person, cond_label))
                    diff_data = data_b - data_a
                    if mode == 'topo':
                        mask = (times >= options.get('window_start', 300)) & (
                            times <= options.get('window_end', 600)
                        )
                        if not mask.any():
                            continue
                        vals = diff_data[:, mask].mean(axis=1)
                        ch_map = {
                            normalize_channel_name(ch): float(vals[i])
                            for i, ch in enumerate(labels)
                            if normalize_channel_name(ch) in ELECTRODE_COORDS_2D
                        }
                        if len(ch_map) >= 4:
                            topo_records.append((group, cond_label, person, ch_map))
                    else:
                        picks = [
                            i
                            for i, name in enumerate(labels)
                            if name.lower() in channels
                        ]
                        if len(picks) != len(channels):
                            warnings.append(
                                f'Missing requested ROI channels: {record.get("subject")}'
                            )
                            continue
                        wave = diff_data[picks].mean(axis=0)
                        key = group + (cond_label,)
                        grid = tuple(times)
                        if key in grids and grids[key] != grid:
                            warnings.append(
                                f'Incompatible time grid skipped: {record.get("subject")}'
                            )
                            continue
                        grids[key] = grid
                        accumulated.setdefault((key, person), []).append(wave)
                continue

            condition = str(row.get('Condition', ''))
            if mode in ['erp', 'topo'] and condition not in conditions:
                continue
            if mode in ['rerp', 'ml']:
                condition = conditions[0]
            if (group, person, condition) in used:
                continue
            used.add((group, person, condition))
            times = np.asarray(record.get('times', []), dtype=float) * 1000
            labels = record.get('labels', [])
            if mode in ['erp', 'topo']:
                data = np.asarray(
                    record.get('channel_conditions', {}).get(condition, []),
                    dtype=float,
                )
                if data.shape != (len(labels), len(times)):
                    warnings.append(
                        f'Missing channel waveforms: {record.get("subject")} / {condition}'
                    )
                    continue
                if mode == 'topo':
                    mask = (times >= options.get('window_start', 300)) & (
                        times <= options.get('window_end', 600)
                    )
                    if not mask.any():
                        continue
                    vals = data[:, mask].mean(axis=1)
                    ch_map = {
                        normalize_channel_name(ch): float(vals[i])
                        for i, ch in enumerate(labels)
                        if normalize_channel_name(ch) in ELECTRODE_COORDS_2D
                    }
                    if len(ch_map) < 4:
                        warnings.append(
                            f'Insufficient scalp electrodes for topo: {record.get("subject")}'
                        )
                        continue
                    topo_records.append((group, condition, person, ch_map))
                    continue
                else:
                    picks = [
                        i for i, name in enumerate(labels) if name.lower() in channels
                    ]
                    if len(picks) != len(channels):
                        warnings.append(
                            f'Missing requested ROI channels: {record.get("subject")}'
                        )
                        continue
                    data = data[picks].mean(axis=0)
            else:
                model = record.get('regression' if mode == 'rerp' else 'decoding')
                if not model:
                    warnings.append(f'No saved {mode}: {record.get("subject")}')
                    continue
                times = np.asarray(model.get('times', []), dtype=float) * 1000
                if mode == 'ml':
                    data = np.asarray(model.get('auc', []), dtype=float)
                else:
                    predictors = model.get('predictors', [])
                    wanted = options.get('predictor', 'class')
                    if wanted not in predictors:
                        warnings.append(
                            f'Predictor {wanted} absent in {record.get("subject")} (available: {predictors})'
                        )
                        continue
                    picks = [
                        i
                        for i, name in enumerate(model.get('channels', []))
                        if name.lower() in channels
                    ]
                    if not picks:
                        continue
                    data = np.asarray(
                        model['coefficients'][predictors.index(wanted)], dtype=float
                    )[picks].mean(axis=0)
            key = group + (condition,)
            grid = tuple(times)
            if key in grids and grids[key] != grid:
                warnings.append(
                    f'Incompatible channel/time grid skipped: {record.get("subject")}'
                )
                continue
            grids[key] = grid
            accumulated.setdefault((key, person), []).append(data)

    if mode == 'topo' and topo_records:
        # Align across subjects by common intersection of recognized 10-20 electrodes
        common_chs = sorted(
            set.intersection(*(set(ch_map.keys()) for _, _, _, ch_map in topo_records))
        )
        ok, _ = check_topoplot_suitability(common_chs)
        if not ok:
            raise ValueError(
                'Topography needs at least four common recognized scalp electrodes with spatial coverage.'
            )
        common_tuple = tuple(common_chs)
        for group, cond_label, person, ch_map in topo_records:
            key = group + (cond_label,)
            grids[key] = common_tuple
            vec = np.asarray([ch_map[ch] for ch in common_chs], dtype=float)
            accumulated.setdefault((key, person), []).append(vec)

    if mode in ['ersp', 'itc']:
        if not tf_inputs:
            raise ValueError(
                'No matching epoch recordings for grouped time-frequency computation.'
            )
        conditions = [
            options.get('condition_a', 'Freq'),
            options.get('condition_b', 'Rare'),
            'B − A',
        ]
        sources = {}
        for code, group in tf_groups.items():
            selected_inputs = [v for v in tf_inputs if v['group'] == code]
            if not selected_inputs:
                continue
            starts = tf_tmins.get(code, set())
            if len(starts) > 1:
                raise ValueError(
                    'Incompatible epoch starts in a displayed TF cell; harmonize epochs before averaging.'
                )
            job = dict(
                job_type='group_ersp_itc',
                epoch_tmin_ms=next(iter(starts)) if starts else None,
                inputs=selected_inputs,
                channel_name='ROI',
                roi_channels=[
                    v.strip() for v in options.get('channels', 'Cz').split(',')
                ],
                fmin_hz=options.get('fmin', 2),
                fmax_hz=options.get('fmax', 40),
                n_freqs=options.get('n_freqs', 24),
                baseline_start_ms=options.get('baseline_start', -200),
                baseline_end_ms=options.get('baseline_end', 0),
                n_perm=20,
            )
            with tempfile.TemporaryDirectory(dir=output, prefix='tf_work_') as temp:
                path = Path(temp) / 'job.json'
                path.write_text(json.dumps(job), encoding='utf-8')
                tf = run_engine(options['engine'], path)
            sources[code] = tf
            tf_counts[group] = tf['n_subjects']
            for condition, field in zip(
                conditions,
                [
                    f'{mode}_a_db' if mode == 'ersp' else 'itc_a',
                    f'{mode}_b_db' if mode == 'ersp' else 'itc_b',
                    'ersp_diff_db' if mode == 'ersp' else 'itc_diff',
                ],
            ):
                values = tf.get(field)
                if values is not None:
                    key = group + (condition,)
                    accumulated[(key, 'grand')] = [
                        np.asarray(values).reshape(
                            len(tf['freqs_hz']), len(tf['times_ms'])
                        )
                    ]
                    grids[key] = tuple(tf['times_ms'])
            warnings.extend(str(v) for v in tf.get('failed_files', []))
        (output / f'group_{mode}_source.json').write_text(
            json.dumps(sources), encoding='utf-8'
        )

    cells = {}
    for (key, person), data in accumulated.items():
        cells.setdefault(key, []).append(np.stack(data).mean(axis=0))
    if not cells:
        raise ValueError(
            f'No valid {mode} data in selected results. '
            + '; '.join(warnings[:6])
            + '. Models must be computed from epochs before their coefficients or decoding scores can be averaged.'
        )

    rows = ordered([key[0] for key in cells], row_factor)
    facets = ordered([key[1] for key in cells], facet_factor)
    series = ordered([key[2] for key in cells], series_factor)
    conditions = [c for c in conditions if any(k[3] == c for k in cells)]

    font_size = float(options.get('font_size', 10))
    plt.rcParams.update(
        {
            'font.size': font_size,
            'svg.fonttype': 'none',
            'pdf.fonttype': 42,
        }
    )

    palette = options.get('colors', {})
    export_rows = []
    auto_size = bool(options.get('auto_size', False))

    if mode == 'topo':
        limit = options.get('color_limit')
        if not limit:
            limit = (
                max(
                    abs(np.stack(values).mean(axis=0)).max()
                    for values in cells.values()
                )
                or 1
            )
        # Real 2D grid: rows = cohorts (when >1 series) × cols = facets × conditions
        if len(rows) == 1 and len(series) > 1:
            grid_rows = [('series', s) for s in series]
            grid_cols = [(rows[0], f, c) for f in facets for c in conditions]
        elif len(rows) == 1 and len(series) == 1 and len(facets) > 1 and len(conditions) > 1:
            grid_rows = [('facet', f) for f in facets]
            grid_cols = [(rows[0], f, c) for f in [None] for c in conditions]
        else:
            grid_rows = [('row', r) for r in rows]
            grid_cols = [(r_item, f, c) for r_item in [None] for f in facets for c in conditions]

        nrows = max(1, len(grid_rows))
        ncols = max(1, len(grid_cols))
        if auto_size:
            width = max(5.5, 2.15 * ncols + 1.4)
            height = max(3.2, 2.15 * nrows + 0.9)
        else:
            width = float(options.get('width') or max(8, 2.3 * ncols))
            height = float(options.get('height') or max(3.2, 2.3 * nrows))

        fig, axes = plt.subplots(
            nrows,
            ncols,
            squeeze=False,
            figsize=(width, height),
            layout='constrained',
        )
        last_image = None
        for ri, (rk, rv) in enumerate(grid_rows):
            for ci, (r_fixed, f_fixed, cond) in enumerate(grid_cols):
                ax = axes[ri, ci]
                r_val = rv if rk == 'row' else r_fixed
                f_val = rv if rk == 'facet' else f_fixed
                s_val = rv if rk == 'series' else series[0]
                key = (r_val, f_val, s_val, cond)

                if ri == 0:
                    col_parts = [
                        label(facet_factor, f_val) if f_val not in (None, 'All') else '',
                        label('Condition', cond),
                    ]
                    col_title = ' · '.join(p for p in col_parts if p)
                    ax.set_title(col_title, fontsize=font_size, fontweight='bold', pad=8)

                if key not in cells:
                    ax.text(
                        0.5,
                        0.5,
                        'No data',
                        ha='center',
                        va='center',
                        transform=ax.transAxes,
                        fontsize=font_size - 1,
                        color='#64748B',
                    )
                    ax.set_xticks([])
                    ax.set_yticks([])
                    for sp in ax.spines.values():
                        sp.set_visible(False)
                else:
                    values = np.stack(cells[key])
                    mean = values.mean(axis=0)
                    labels = list(grids[key])
                    ok, positions = check_topoplot_suitability(labels)
                    if not ok:
                        raise ValueError(
                            'Topography needs at least four recognized scalp electrodes with spatial coverage.'
                        )
                    xy = np.asarray(list(positions.values()))
                    z = np.asarray([mean[labels.index(ch)] for ch in positions])
                    radius = max(np.sqrt((xy**2).sum(axis=1)).max(), 0.5) * 1.04
                    xx, yy = np.mgrid[-radius:radius:100j, -radius:radius:100j]
                    zz = griddata(xy, z, (xx, yy), method='cubic')
                    zz = np.ma.masked_where(xx**2 + yy**2 > radius**2, zz)
                    last_image = ax.pcolormesh(
                        xx,
                        yy,
                        zz,
                        cmap=options.get('colormap', 'RdBu_r'),
                        vmin=-limit,
                        vmax=limit,
                        shading='auto',
                        rasterized=True,
                    )
                    ax.add_patch(
                        plt.Circle((0, 0), radius, fill=False, color='black', linewidth=1)
                    )
                    ax.plot(
                        [-0.08 * radius, 0, 0.08 * radius],
                        [radius, 1.12 * radius, radius],
                        color='black',
                        linewidth=1,
                    )
                    ax.scatter(xy[:, 0], xy[:, 1], s=4, color='black')
                    ax.set_xlim(-radius * 1.15, radius * 1.15)
                    ax.set_ylim(-radius * 1.1, radius * 1.2)
                    ax.set_aspect('equal')
                    ax.set_xticks([])
                    ax.set_yticks([])
                    for sp in ax.spines.values():
                        sp.set_visible(False)
                    if rk == 'series':
                        ax.text(
                            0.5,
                            -0.06,
                            f'n={len(values)}',
                            ha='center',
                            va='top',
                            transform=ax.transAxes,
                            fontsize=max(7.5, font_size - 2),
                            color='#475569',
                        )

                if ci == 0 and (rk == 'series' or rk == 'facet' or (rk == 'row' and rv != 'All')):
                    row_lbl = (
                        label(series_factor, rv)
                        if rk == 'series'
                        else (label(facet_factor, rv) if rk == 'facet' else label(row_factor, rv))
                    )
                    ax.set_ylabel(
                        row_lbl,
                        fontsize=font_size,
                        fontweight='bold',
                        rotation=0,
                        ha='right',
                        va='center',
                        labelpad=12,
                    )

        if last_image is not None:
            fig.colorbar(
                last_image,
                ax=axes.ravel().tolist(),
                shrink=0.72,
                pad=0.02,
                label='µV',
            )
        win_start = options.get('window_start', 300)
        win_end = options.get('window_end', 600)
        fig.get_layout_engine().set(rect=(0.0, 0.0, 1.0, 0.93))
        fig.suptitle(
            f'Grand Average Scalp Topographies ({int(win_start)}–{int(win_end)} ms)',
            fontsize=font_size + 1,
            fontweight='bold',
            y=0.98,
        )
    elif mode in ['ersp', 'itc']:
        ncols = len(facets) * len(conditions)
        nrows = len(rows)
        if auto_size:
            width = max(7.0, 3.2 * ncols)
            height = max(3.6, 2.8 * nrows)
        else:
            width = float(options.get('width') or max(8, 3 * ncols))
            height = float(options.get('height') or max(3, 3 * nrows))
        fig, axes = plt.subplots(
            nrows,
            ncols,
            squeeze=False,
            figsize=(width, height),
            layout='constrained',
        )
        for ri, row in enumerate(rows):
            for fi, facet in enumerate(facets):
                for ci, condition in enumerate(conditions):
                    ax = axes[ri, fi * len(conditions) + ci]
                    found = False
                    for si, serie in enumerate(series):
                        key = (row, facet, serie, condition)
                        if key not in cells:
                            continue
                        values = np.stack(cells[key])
                        mean = values.mean(axis=0)
                        name = f'{label(series_factor, serie)} (n={tf_counts.get(key[:3], len(values))})'
                        if len(series) > 1:
                            map_ax = ax.inset_axes(
                                [0, si / len(series), 1, 0.85 / len(series)]
                            )
                            map_ax.set_title(name, fontsize=8)
                        else:
                            map_ax = ax
                        times = grids[key]
                        low, high = (
                            (-3, 3)
                            if mode == 'ersp'
                            else ((-1, 1) if condition == 'B − A' else (0, 1))
                        )
                        if options.get('color_limit'):
                            low, high = (-options['color_limit'], options['color_limit'])
                        image = map_ax.imshow(
                            mean,
                            origin='lower',
                            aspect='auto',
                            extent=[
                                times[0],
                                times[-1],
                                tf['freqs_hz'][0],
                                tf['freqs_hz'][-1],
                            ],
                            cmap=options.get('colormap', 'RdBu_r'),
                            vmin=low,
                            vmax=high,
                        )
                        map_ax.set_xlabel('Time (ms)')
                        map_ax.set_ylabel('Hz')
                        if si == len(series) - 1:
                            fig.colorbar(
                                image,
                                ax=ax,
                                shrink=0.65,
                                label='dB' if mode == 'ersp' else 'ITC',
                            )
                        if len(series) > 1:
                            ax.axis('off')
                        found = True
                    title = ' · '.join(
                        v
                        for v in [
                            label(row_factor, row) if row != 'All' else '',
                            label(facet_factor, facet) if facet != 'All' else '',
                            label('Condition', condition),
                        ]
                        if v
                    )
                    ax.set_title(title, fontsize=font_size)
                    if not found:
                        ax.text(
                            0.5,
                            0.5,
                            'No data',
                            ha='center',
                            va='center',
                            transform=ax.transAxes,
                        )
    else:
        # Smart 2D grid for waveforms (erp, rerp, ml):
        # When row_factor is unset and both facets & conditions > 1, arrange facets as rows × conditions as cols.
        use_2d_facet_grid = (
            row_factor is None
            and len(rows) == 1
            and len(facets) > 1
            and len(conditions) > 1
        )
        if use_2d_facet_grid:
            nrows, ncols = len(facets), len(conditions)
        else:
            nrows, ncols = len(rows), len(facets) * len(conditions)

        if auto_size:
            width = max(6.5, 3.6 * ncols)
            height = max(3.6, 2.7 * nrows + 0.8)
        else:
            width = float(options.get('width') or max(8, 3 * ncols))
            height = float(options.get('height') or max(3, 3 * nrows))

        fig, axes = plt.subplots(
            nrows,
            ncols,
            squeeze=False,
            sharey=True,
            sharex=True,
            figsize=(width, height),
            layout='constrained',
        )

        legend_entries = {}
        show_window = bool(options.get('show_window', False)) and mode == 'erp'
        win_start = float(options.get('window_start', 300))
        win_end = float(options.get('window_end', 600))

        for ri in range(nrows):
            for ci_grid in range(ncols):
                ax = axes[ri, ci_grid]
                if use_2d_facet_grid:
                    row = rows[0]
                    facet = facets[ri]
                    condition = conditions[ci_grid]
                else:
                    row = rows[ri]
                    facet = facets[ci_grid // len(conditions)]
                    condition = conditions[ci_grid % len(conditions)]

                found = False
                if show_window and win_end > win_start:
                    ax.axvspan(
                        win_start,
                        win_end,
                        color='#6366F1',
                        alpha=0.10,
                        linewidth=0,
                        zorder=0,
                    )

                for si, serie in enumerate(series):
                    key = (row, facet, serie, condition)
                    if key not in cells:
                        continue
                    values = np.stack(cells[key])
                    mean = values.mean(axis=0)
                    sem = (
                        values.std(axis=0, ddof=1) / np.sqrt(len(values))
                        if len(values) > 1
                        else np.zeros_like(mean)
                    )
                    color = _resolve_color(palette, serie, si)
                    disp_name = label(series_factor, serie)
                    legend_entries.setdefault(
                        serie,
                        (color, disp_name, len(values)),
                    )
                    # Keep max participant count for shared legend
                    prev_c, prev_n_lbl, prev_n = legend_entries[serie]
                    if len(values) > prev_n:
                        legend_entries[serie] = (prev_c, prev_n_lbl, len(values))

                    times = np.asarray(grids[key])
                    ax.plot(
                        times,
                        mean,
                        color=color,
                        lw=float(options.get('line_width', 1.5)),
                    )
                    band = options.get('error', 'SEM')
                    if band != 'None':
                        spread = sem * (
                            stats.t.ppf(0.975, len(values) - 1)
                            if band == '95% CI' and len(values) > 1
                            else 1
                        )
                        ax.fill_between(
                            times,
                            mean - spread,
                            mean + spread,
                            color=color,
                            alpha=0.15,
                            linewidth=0,
                        )
                    for index, time in enumerate(times):
                        export_rows.append(
                            [
                                row,
                                facet,
                                serie,
                                condition,
                                time,
                                mean[index],
                                sem[index],
                                len(values),
                            ]
                        )
                    found = True

                ax.axhline(
                    0.5 if mode == 'ml' else 0, color='#64748B', lw=0.7, ls='--'
                )
                ax.axvline(0, color='#64748B', lw=0.7, ls='--')
                if options.get('x_min') is not None or options.get('x_max') is not None:
                    ax.set_xlim(options.get('x_min'), options.get('x_max'))
                if options.get('y_min') is not None or options.get('y_max') is not None:
                    ax.set_ylim(options.get('y_min'), options.get('y_max'))
                if ri == nrows - 1:
                    ax.set_xlabel('Time (ms)')
                if ci_grid == 0:
                    ax.set_ylabel('AUC' if mode == 'ml' else 'µV')

                title = ' · '.join(
                    v
                    for v in [
                        label(row_factor, row) if row != 'All' else '',
                        label(facet_factor, facet) if facet != 'All' else '',
                        label('Condition', condition),
                    ]
                    if v
                )
                ax.set_title(title, fontsize=font_size, fontweight='bold')
                if not found:
                    ax.text(
                        0.5,
                        0.5,
                        'No data',
                        ha='center',
                        va='center',
                        transform=ax.transAxes,
                    )
                ax.spines[['right', 'top']].set_visible(False)

        if options.get('negative_up', True) and mode != 'ml':
            axes[0, 0].yaxis.set_inverted(True)

        if legend_entries:
            handles = [
                Line2D(
                    [0],
                    [0],
                    color=col,
                    lw=max(2.0, float(options.get('line_width', 1.5))),
                    label=f'{disp} (n={n_p})' if series_factor else f'n={n_p}',
                )
                for col, disp, n_p in legend_entries.values()
            ]
            fig.get_layout_engine().set(rect=(0.0, 0.0, 1.0, 0.93))
            fig.legend(
                handles=handles,
                loc='upper center',
                ncol=min(len(handles), 6),
                frameon=False,
                fontsize=font_size,
                bbox_to_anchor=(0.5, 0.99),
            )

    stem = output / f'GrandAverage_{mode}'
    paths = []
    for suffix in ['png', 'svg', 'pdf']:
        path = stem.with_suffix('.' + suffix)
        fig.savefig(
            path,
            dpi=int(options.get('dpi', 300)),
            facecolor='white',
            bbox_inches='tight',
        )
        paths.append(str(path))
    plt.close(fig)
    if export_rows:
        with stem.with_suffix('.csv').open('w', newline='', encoding='utf-8') as stream:
            writer = csv.writer(stream)
            writer.writerow(
                [
                    'row',
                    'facet',
                    'series',
                    'condition',
                    'time_ms',
                    'mean',
                    'sem',
                    'n_participants',
                ]
            )
            writer.writerows(export_rows)
    manifest = dict(
        options=options,
        n_matched_files=len(records),
        warnings=list(dict.fromkeys(warnings)),
        method='Equal participant weighting; within-participant/cell records averaged first. 95% CI is a pointwise t interval across participants; n=1 has no between-participant error estimate. No significance inferred from visual separation. TF maps are recomputed from epochs; ITC is mean participant ITC, not pooled trial phase locking.',
    )
    stem.with_suffix('.json').write_text(
        json.dumps(manifest, indent=2), encoding='utf-8'
    )
    return dict(
        paths=paths, warnings=manifest['warnings'], n_matched_files=len(records)
    )


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, stop_engine)
    try:
        options = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
        result = render(options)
        Path(sys.argv[2]).write_text(
            json.dumps(result, allow_nan=False), encoding='utf-8'
        )
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
