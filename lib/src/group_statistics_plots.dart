import 'dart:math' as math;

import 'package:flutter/material.dart';

enum StatsPlotType { line, bar, boxplot }

class StatsPlotLayoutConfig {
  const StatsPlotLayoutConfig({
    this.xFactor,
    this.seriesFactor,
    this.facetColFactor,
    this.facetRowFactor,
    this.plotType = StatsPlotType.line,
    this.useSem = true,
    this.factorLabels = const {},
    this.levelLabels = const {},
    this.seriesColors = const {},
  });

  final String? xFactor;
  final String? seriesFactor;
  final String? facetColFactor;
  final String? facetRowFactor;
  final StatsPlotType plotType;
  final bool useSem;
  final Map<String, String> factorLabels;
  final Map<String, Map<String, String>> levelLabels;
  final Map<String, int> seriesColors;
  String factorLabel(String? raw) =>
      raw == null ? 'None' : factorLabels[raw] ?? raw;
  String levelLabel(String? factor, String raw) =>
      levelLabels[factor]?[raw] ?? raw;

  StatsPlotLayoutConfig copyWith({
    String? xFactor,
    bool clearX = false,
    String? seriesFactor,
    bool clearSeries = false,
    String? facetColFactor,
    bool clearFacetCol = false,
    String? facetRowFactor,
    bool clearFacetRow = false,
    StatsPlotType? plotType,
    bool? useSem,
    Map<String, String>? factorLabels,
    Map<String, Map<String, String>>? levelLabels,
    Map<String, int>? seriesColors,
  }) {
    return StatsPlotLayoutConfig(
      xFactor: clearX ? null : (xFactor ?? this.xFactor),
      seriesFactor: clearSeries ? null : (seriesFactor ?? this.seriesFactor),
      facetColFactor: clearFacetCol
          ? null
          : (facetColFactor ?? this.facetColFactor),
      facetRowFactor: clearFacetRow
          ? null
          : (facetRowFactor ?? this.facetRowFactor),
      plotType: plotType ?? this.plotType,
      useSem: useSem ?? this.useSem,
      factorLabels: factorLabels ?? this.factorLabels,
      levelLabels: levelLabels ?? this.levelLabels,
      seriesColors: seriesColors ?? this.seriesColors,
    );
  }
}

typedef StatsPlotBracket = ({
  int xA,
  int seriesA,
  int xB,
  int seriesB,
  String label,
});

List<StatsPlotBracket> statsPlotBrackets({
  required StatsPlotLayoutConfig config,
  required List<Map<String, dynamic>> contrasts,
  required List<String> factors,
  required Map<String, List<String>> levels,
  String? row,
  String? column,
}) {
  final matched = <({double pAdj, StatsPlotBracket bracket})>[];
  final xs = levels[config.xFactor] ?? ['All'],
      ss = levels[config.seriesFactor] ?? ['All'];
  for (final p in contrasts) {
    final qNum = p['p_adj'] as num?;
    if (qNum == null || qNum >= .05) continue;
    final f = '${p['factor']}';
    if (f != config.xFactor && f != config.seriesFactor) continue;
    final stratum = Map<String, dynamic>.from(p['stratum'] as Map? ?? {});
    if (config.facetColFactor != null &&
        stratum[config.facetColFactor] != column) {
      continue;
    }
    if (config.facetRowFactor != null &&
        stratum[config.facetRowFactor] != row) {
      continue;
    }
    final roles = {
      config.xFactor,
      config.seriesFactor,
      config.facetColFactor,
      config.facetRowFactor,
    };
    if (stratum.keys.any((key) => !roles.contains(key))) continue;
    if (stratum.isEmpty &&
        factors.any((other) => other != f && roles.contains(other))) {
      continue;
    }
    final isX = f == config.xFactor;
    final xa = isX
        ? xs.indexOf('${p['group_a']}')
        : xs.indexOf('${stratum[config.xFactor] ?? 'All'}');
    final xb = isX ? xs.indexOf('${p['group_b']}') : xa;
    final sa = isX
        ? ss.indexOf('${stratum[config.seriesFactor] ?? 'All'}')
        : ss.indexOf('${p['group_a']}');
    final sb = isX ? sa : ss.indexOf('${p['group_b']}');
    if ([xa, xb, sa, sb].any((v) => v < 0)) continue;
    final q = qNum.toDouble();
    final mark = q < .001
        ? '***'
        : q < .01
        ? '**'
        : '*';
    final label = isX
        ? '${config.levelLabel(config.seriesFactor, ss[sa])} $mark'
        : '${config.levelLabel(config.seriesFactor, ss[sa])}–${config.levelLabel(config.seriesFactor, ss[sb])} $mark';
    matched.add((
      pAdj: q,
      bracket: (xA: xa, xB: xb, seriesA: sa, seriesB: sb, label: label),
    ));
  }
  matched.sort((a, b) => a.pAdj.compareTo(b.pAdj));
  return matched.map((e) => e.bracket).toList();
}

enum _BracketMode { off, top4, all }

/// Configurable multi-factor statistical plot widget.
/// Renders either a live interactive dummy preview (before analysis) or real
/// cell descriptives (after analysis) using identical role-mapping and ordering.
class ConfigurableStatsPlotWidget extends StatefulWidget {
  const ConfigurableStatsPlotWidget({
    super.key,
    required this.config,
    required this.factorLevels,
    this.metricName = 'ERP Amplitude (µV)',
    this.cellDescriptives = const {},
    this.activeFactors = const [],
    this.isDummyPreview = false,
    this.height = 360,
    this.posthocs = const [],
  });

  final StatsPlotLayoutConfig config;
  final Map<String, List<String>> factorLevels;
  final String metricName;
  final Map<String, dynamic> cellDescriptives;
  final List<String> activeFactors;
  final bool isDummyPreview;
  final double height;
  final List<Map<String, dynamic>> posthocs;

  @override
  State<ConfigurableStatsPlotWidget> createState() =>
      _ConfigurableStatsPlotWidgetState();
}

class _ConfigurableStatsPlotWidgetState
    extends State<ConfigurableStatsPlotWidget> {
  _BracketMode _bracketMode = _BracketMode.top4;

  static const _palette = [
    Color(0xFF38BDF8),
    Color(0xFFF472B6),
    Color(0xFF34D399),
    Color(0xFFFBBF24),
    Color(0xFFA78BFA),
    Color(0xFFFB7185),
    Color(0xFF60A5FA),
    Color(0xFF2DD4BF),
  ];

  int get _maxBracketsPerPanel => switch (_bracketMode) {
    _BracketMode.off => 0,
    _BracketMode.top4 => 4,
    _BracketMode.all => 8,
  };

  List<String> _levelsOf(String? factor) {
    if (factor == null || factor.isEmpty || factor == 'None') {
      return const ['All'];
    }
    final lvls = widget.factorLevels[factor];
    return (lvls != null && lvls.isNotEmpty) ? lvls : const ['All'];
  }

  /// Aggregates cell descriptives (or generates deterministic dummy data)
  /// for a specific (facetRow, facetCol, series, x) cell.
  ({
    double mean,
    double err,
    double q1,
    double median,
    double q3,
    List<double> vals,
  })?
  _cellStats({
    required String? rowVal,
    required String? colVal,
    required String? seriesVal,
    required String xVal,
    required int rowIdx,
    required int colIdx,
    required int seriesIdx,
    required int xIdx,
  }) {
    if (widget.isDummyPreview) {
      // Deterministic, visually distinct dummy curves so users can inspect
      // line separation, X-axis progression, and subplot faceting.
      final base = 4.0 + seriesIdx * 1.8 + colIdx * 1.1 + rowIdx * 0.6;
      final wave = math.sin((xIdx + 1) * 0.9 + seriesIdx * 0.7) * 2.2;
      final mean = base + wave;
      final err = 0.65 + (seriesIdx % 3) * 0.15;
      final spread = err * 1.65;
      final vals = <double>[
        mean - spread * 1.85,
        mean - spread * 1.25,
        mean - spread * 0.95,
        mean - spread * 0.70,
        mean - spread * 0.45,
        mean - spread * 0.15,
        mean + spread * 0.12,
        mean + spread * 0.40,
        mean + spread * 0.68,
        mean + spread * 0.95,
        mean + spread * 1.30,
        mean + spread * 1.95,
      ]..sort();
      return (
        mean: mean,
        err: err,
        q1: vals[(vals.length * 0.25).floor()],
        median: vals[(vals.length * 0.5).floor()],
        q3: vals[(vals.length * 0.75).floor()],
        vals: vals,
      );
    }

    // Real data: match all cells in cellDescriptives that satisfy the role filters
    final matchedVals = <double>[];
    for (final entry in widget.cellDescriptives.entries) {
      final parts = <String, String>{};
      for (final seg in entry.key.split('|')) {
        final eq = seg.indexOf('=');
        if (eq > 0) {
          parts[seg.substring(0, eq)] = seg.substring(eq + 1);
        }
      }
      if (widget.config.xFactor != null &&
          parts[widget.config.xFactor] != xVal) {
        continue;
      }
      if (widget.config.seriesFactor != null &&
          seriesVal != null &&
          parts[widget.config.seriesFactor] != seriesVal) {
        continue;
      }
      if (widget.config.facetColFactor != null &&
          colVal != null &&
          parts[widget.config.facetColFactor] != colVal) {
        continue;
      }
      if (widget.config.facetRowFactor != null &&
          rowVal != null &&
          parts[widget.config.facetRowFactor] != rowVal) {
        continue;
      }
      final desc = entry.value as Map<String, dynamic>?;
      final vals = (desc?['values'] as List?)
          ?.map((e) => (e as num).toDouble())
          .toList();
      if (vals != null) matchedVals.addAll(vals);
    }

    if (matchedVals.isEmpty) return null;
    matchedVals.sort();
    final n = matchedVals.length;
    final mean = matchedVals.reduce((a, b) => a + b) / n;
    var ss = 0.0;
    for (final v in matchedVals) {
      ss += (v - mean) * (v - mean);
    }
    final sd = n > 1 ? math.sqrt(ss / (n - 1)) : 0.0;
    final sem = n > 0 ? sd / math.sqrt(n) : 0.0;
    return (
      mean: mean,
      err: widget.config.useSem ? sem : sd,
      q1: matchedVals[(n * 0.25).floor().clamp(0, n - 1)],
      median: matchedVals[(n * 0.5).floor().clamp(0, n - 1)],
      q3: matchedVals[(n * 0.75).floor().clamp(0, n - 1)],
      vals: matchedVals,
    );
  }

  List<Widget> _annotations() {
    if (widget.isDummyPreview) return [];
    final significant = widget.posthocs
        .where((p) => (p['p_adj'] as num? ?? 1) < .05)
        .toList();
    final subtitleText = switch (_bracketMode) {
      _BracketMode.off =>
        'Significance brackets hidden on plot. Expand for all adjusted comparisons.',
      _BracketMode.top4 =>
        'Markers show up to 4 most significant contrasts per panel. Expand for all adjusted comparisons.',
      _BracketMode.all =>
        'Markers show up to 8 matching cell contrasts per panel. Expand for all adjusted comparisons.',
    };
    return [
      ExpansionTile(
        title: Text(
          'Corrected contrast details · ${significant.length} significant',
        ),
        subtitle: Text(subtitleText),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Post-hoc comparisons: adjusted p < .05 (${significant.length}). Simple effects apply only to the named cohort/session cells; marginal contrasts collapse other factors.',
                  style: const TextStyle(fontSize: 11),
                ),
                const SizedBox(height: 4),
                if (significant.isEmpty)
                  const Text(
                    'No significant adjusted pairwise contrasts.',
                    style: TextStyle(fontSize: 11),
                  ),
                for (final p in significant)
                  Text(() {
                    final factor = '${p['factor']}';
                    final stratum = Map<String, dynamic>.from(
                      p['stratum'] as Map? ?? {},
                    );
                    final context = stratum.entries
                        .map(
                          (e) =>
                              '${widget.config.factorLabel(e.key)}=${widget.config.levelLabel(e.key, "${e.value}")}',
                        )
                        .join(', ');
                    final q = (p['p_adj'] as num).toDouble();
                    final mark = q < .001
                        ? '***'
                        : q < .01
                        ? '**'
                        : '*';
                    return '$mark ${widget.config.factorLabel(factor)}: ${widget.config.levelLabel(factor, "${p['group_a']}")} ↔ ${widget.config.levelLabel(factor, "${p['group_b']}")} · ${context.isEmpty ? 'marginal' : context} · adjusted p=${q.toStringAsPrecision(3)}';
                  }(), style: const TextStyle(fontSize: 11, color: Colors.tealAccent)),
              ],
            ),
          ),
        ],
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final xLevels = _levelsOf(widget.config.xFactor);
    final seriesLevels = _levelsOf(widget.config.seriesFactor);
    final colLevels = _levelsOf(widget.config.facetColFactor);
    final rowLevels = _levelsOf(widget.config.facetRowFactor);

    // Compute global Y range across all facets for consistent axis scaling
    var yMin = double.infinity;
    var yMax = double.negativeInfinity;
    for (var r = 0; r < rowLevels.length; r++) {
      for (var c = 0; c < colLevels.length; c++) {
        for (var s = 0; s < seriesLevels.length; s++) {
          for (var x = 0; x < xLevels.length; x++) {
            final st = _cellStats(
              rowVal: widget.config.facetRowFactor == null ? null : rowLevels[r],
              colVal: widget.config.facetColFactor == null ? null : colLevels[c],
              seriesVal: widget.config.seriesFactor == null
                  ? null
                  : seriesLevels[s],
              xVal: xLevels[x],
              rowIdx: r,
              colIdx: c,
              seriesIdx: s,
              xIdx: x,
            );
            if (st == null) continue;
            yMin = math.min(yMin, st.mean - st.err * 1.3);
            yMax = math.max(yMax, st.mean + st.err * 1.3);
            if (widget.config.plotType == StatsPlotType.boxplot &&
                st.vals.isNotEmpty) {
              yMin = math.min(yMin, st.vals.first);
              yMax = math.max(yMax, st.vals.last);
            }
          }
        }
      }
    }
    if (!yMin.isFinite || !yMax.isFinite || (yMax - yMin).abs() < 1e-6) {
      yMin = 0;
      yMax = 10;
    } else {
      final pad = (yMax - yMin) * 0.15;
      yMin -= pad;
      yMax += pad;
    }

    final dataPlotH = widget.isDummyPreview
        ? math.max(180.0, widget.height - 100.0)
        : 250.0;

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: widget.isDummyPreview
              ? Colors.amberAccent.withValues(alpha: 0.45)
              : Colors.white12,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (widget.isDummyPreview)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    color: Colors.amberAccent.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    'SAMPLE DUMMY PREVIEW',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: Colors.amberAccent,
                    ),
                  ),
                ),
              Expanded(
                child: Text(
                  '${widget.metricName}  ·  X: ${widget.config.factorLabel(widget.config.xFactor)}  |  Lines/Hue: ${widget.config.factorLabel(widget.config.seriesFactor)}  |  Cols: ${widget.config.factorLabel(widget.config.facetColFactor)}${widget.config.facetRowFactor != null ? "  |  Rows: ${widget.config.factorLabel(widget.config.facetRowFactor)}" : ""}',
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (!widget.isDummyPreview && widget.posthocs.isNotEmpty) ...[
                const SizedBox(width: 8),
                const Text(
                  'Brackets:',
                  style: TextStyle(fontSize: 11, color: Colors.white70),
                ),
                const SizedBox(width: 6),
                SegmentedButton<_BracketMode>(
                  showSelectedIcon: false,
                  style: SegmentedButton.styleFrom(
                    visualDensity: const VisualDensity(
                      horizontal: -3,
                      vertical: -3,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 0,
                    ),
                    textStyle: const TextStyle(fontSize: 10.5),
                    foregroundColor: Colors.white70,
                    selectedForegroundColor: Colors.white,
                    selectedBackgroundColor: const Color(0xFF1E3A8A),
                  ),
                  segments: const [
                    ButtonSegment(value: _BracketMode.off, label: Text('Off')),
                    ButtonSegment(
                      value: _BracketMode.top4,
                      label: Text('Top 4'),
                    ),
                    ButtonSegment(value: _BracketMode.all, label: Text('All')),
                  ],
                  selected: {_bracketMode},
                  onSelectionChanged: (s) =>
                      setState(() => _bracketMode = s.first),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          // Legend for Series / Hue
          if (widget.config.seriesFactor != null)
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                Text(
                  '${widget.config.factorLabel(widget.config.seriesFactor)}:',
                  style: const TextStyle(fontSize: 11, color: Colors.white70),
                ),
                for (var s = 0; s < seriesLevels.length; s++)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: Color(
                            widget.config.seriesColors[seriesLevels[s]] ??
                                _palette[s % _palette.length].toARGB32(),
                          ),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        widget.config.levelLabel(
                          widget.config.seriesFactor,
                          seriesLevels[s],
                        ),
                        style: const TextStyle(fontSize: 11),
                      ),
                    ],
                  ),
              ],
            ),
          const SizedBox(height: 6),
          for (var r = 0; r < rowLevels.length; r++)
            () {
              final colBrackets = [
                for (var c = 0; c < colLevels.length; c++)
                  statsPlotBrackets(
                    config: widget.config,
                    contrasts: widget.posthocs,
                    factors: widget.activeFactors,
                    levels: widget.factorLevels,
                    row: widget.config.facetRowFactor == null
                        ? null
                        : rowLevels[r],
                    column: widget.config.facetColFactor == null
                        ? null
                        : colLevels[c],
                  ).take(_maxBracketsPerPanel).toList(),
              ];
              final maxRowBrackets = colBrackets.fold<int>(
                0,
                (mx, list) => math.max(mx, list.length),
              );
              final bracketBandH = maxRowBrackets == 0
                  ? 0.0
                  : (maxRowBrackets * 20.0 + 14.0);
              final rowBoxH = dataPlotH + bracketBandH + 56.0;

              Widget buildCol(int c) {
                return Padding(
                  padding: const EdgeInsets.all(4),
                  child: Column(
                    children: [
                      if (widget.config.facetColFactor != null)
                        Text(
                          '${widget.config.factorLabel(widget.config.facetColFactor)}: ${widget.config.levelLabel(widget.config.facetColFactor, colLevels[c])}',
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: Colors.lightBlueAccent,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      Expanded(
                        child: CustomPaint(
                          size: Size.infinite,
                          painter: _FacetPlotPainter(
                            xLevels: xLevels
                                .map(
                                  (x) => widget.config.levelLabel(
                                    widget.config.xFactor,
                                    x,
                                  ),
                                )
                                .toList(),
                            seriesLevels: seriesLevels,
                            brackets: colBrackets[c],
                            sharedBracketSlots: maxRowBrackets,
                            plotType: widget.config.plotType,
                            yMin: yMin,
                            yMax: yMax,
                            palette: [
                              for (final (index, level) in seriesLevels.indexed)
                                Color(
                                  widget.config.seriesColors[level] ??
                                      _palette[index % _palette.length]
                                          .toARGB32(),
                                ),
                            ],
                            getCell: (sIdx, xIdx) => _cellStats(
                              rowVal: widget.config.facetRowFactor == null
                                  ? null
                                  : rowLevels[r],
                              colVal: widget.config.facetColFactor == null
                                  ? null
                                  : colLevels[c],
                              seriesVal: widget.config.seriesFactor == null
                                  ? null
                                  : seriesLevels[sIdx],
                              xVal: xLevels[xIdx],
                              rowIdx: r,
                              colIdx: c,
                              seriesIdx: sIdx,
                              xIdx: xIdx,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              }

              return SizedBox(
                height: rowBoxH,
                child: Row(
                  children: [
                    if (widget.config.facetRowFactor != null)
                      RotatedBox(
                        quarterTurns: 3,
                        child: Text(
                          '${widget.config.factorLabel(widget.config.facetRowFactor)}: ${widget.config.levelLabel(widget.config.facetRowFactor, rowLevels[r])}',
                          style: const TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.bold,
                            color: Colors.white70,
                          ),
                        ),
                      ),
                    if (colLevels.length > 3)
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              for (var c = 0; c < colLevels.length; c++)
                                SizedBox(
                                  width: 300.0,
                                  height: rowBoxH,
                                  child: buildCol(c),
                                ),
                            ],
                          ),
                        ),
                      )
                    else
                      for (var c = 0; c < colLevels.length; c++)
                        Expanded(child: buildCol(c)),
                  ],
                ),
              );
            }(),
          ..._annotations(),
        ],
      ),
    );
  }
}

class _FacetPlotPainter extends CustomPainter {
  const _FacetPlotPainter({
    required this.xLevels,
    required this.seriesLevels,
    required this.plotType,
    required this.yMin,
    required this.yMax,
    required this.palette,
    required this.getCell,
    this.brackets = const [],
    this.sharedBracketSlots = 0,
  });

  final List<String> xLevels;
  final List<String> seriesLevels;
  final StatsPlotType plotType;
  final List<StatsPlotBracket> brackets;
  final int sharedBracketSlots;
  final double yMin;
  final double yMax;
  final List<Color> palette;
  final ({
    double mean,
    double err,
    double q1,
    double median,
    double q3,
    List<double> vals,
  })?
  Function(int sIdx, int xIdx)
  getCell;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 20 || size.height < 20 || xLevels.isEmpty) return;

    const leftPad = 46.0;
    const rightPad = 14.0;
    final topPad =
        12.0 + (sharedBracketSlots > 0 ? sharedBracketSlots * 20.0 + 10.0 : 0.0);
    const bottomPad = 26.0;
    final plotW = math.max(1.0, size.width - leftPad - rightPad);
    final plotH = math.max(1.0, size.height - topPad - bottomPad);

    double yOf(double v) {
      final frac = ((v - yMin) / math.max(1e-9, yMax - yMin)).clamp(0.0, 1.0);
      return topPad + plotH * (1.0 - frac);
    }

    double xCenter(int xIdx) {
      final step = plotW / xLevels.length;
      return leftPad + step * (xIdx + 0.5);
    }

    double bracketX(int x, int series) {
      final step = plotW / xLevels.length;
      if (plotType == StatsPlotType.line) {
        return xCenter(x) +
            (seriesLevels.length > 1
                ? (series - (seriesLevels.length - 1) / 2.0) * 6.0
                : 0.0);
      }
      return xCenter(x) +
          (series - (seriesLevels.length - 1) / 2.0) *
              step *
              0.7 /
              math.max(1, seriesLevels.length);
    }

    for (final (i, b) in brackets.indexed) {
      final rawA = bracketX(b.xA, b.seriesA);
      final rawZ = bracketX(b.xB, b.seriesB);
      var leftX = math.min(rawA, rawZ);
      var rightX = math.max(rawA, rawZ);
      final isCrossSeries = b.seriesA != b.seriesB;
      if (isCrossSeries && (rightX - leftX) < 20.0) {
        final mid = (leftX + rightX) / 2.0;
        leftX = mid - 10.0;
        rightX = mid + 10.0;
      }
      final y = topPad - 14.0 - (brackets.length - 1 - i) * 20.0;
      final bracketColor = isCrossSeries
          ? Colors.amberAccent
          : palette[b.seriesA % palette.length];
      final paint = Paint()
        ..color = bracketColor.withValues(alpha: 0.9)
        ..strokeWidth = 1.2;
      canvas.drawLine(Offset(leftX, y + 4.0), Offset(leftX, y), paint);
      canvas.drawLine(Offset(leftX, y), Offset(rightX, y), paint);
      canvas.drawLine(Offset(rightX, y), Offset(rightX, y + 4.0), paint);
      final text = TextPainter(
        text: TextSpan(
          text: b.label,
          style: TextStyle(
            fontSize: 10.0,
            fontWeight: FontWeight.w600,
            color: bracketColor,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final labelX = ((leftX + rightX) / 2.0 - text.width / 2.0)
          .clamp(
            leftPad - 4.0,
            math.max(leftPad - 4.0, size.width - text.width - 2.0),
          )
          .toDouble();
      text.paint(canvas, Offset(labelX, y - text.height - 1.0));
    }

    // Axes & grid
    final gridPaint = Paint()
      ..color = Colors.white12
      ..strokeWidth = 1.0;
    canvas.drawRect(
      Rect.fromLTWH(leftPad, topPad, plotW, plotH),
      Paint()
        ..color = Colors.white12
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0,
    );

    final span = (yMax - yMin).abs();
    final decimals = span >= 100
        ? 0
        : span >= 2
        ? 1
        : 2;
    for (var i = 0; i < 5; i++) {
      final rawYVal = yMin + (yMax - yMin) * (i / 4.0);
      final yVal = rawYVal.abs() < 1e-6 ? 0.0 : rawYVal;
      final y = yOf(rawYVal);
      canvas.drawLine(
        Offset(leftPad, y),
        Offset(leftPad + plotW, y),
        gridPaint,
      );
      final tp = TextPainter(
        text: TextSpan(
          text: yVal.toStringAsFixed(decimals),
          style: const TextStyle(color: Colors.white70, fontSize: 10.5),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
        canvas,
        Offset(math.max(0.0, leftPad - tp.width - 5.0), y - tp.height / 2),
      );
    }

    if (yMin < 0 && yMax > 0) {
      final zeroY = yOf(0.0);
      canvas.drawLine(
        Offset(leftPad, zeroY),
        Offset(leftPad + plotW, zeroY),
        Paint()
          ..color = Colors.white30
          ..strokeWidth = 1.2,
      );
    }

    // X labels
    for (var x = 0; x < xLevels.length; x++) {
      final cx = xCenter(x);
      final tp = TextPainter(
        text: TextSpan(
          text: xLevels[x],
          style: const TextStyle(color: Colors.white70, fontSize: 11.0),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: math.max(10.0, plotW / xLevels.length - 4.0));
      tp.paint(canvas, Offset(cx - tp.width / 2, topPad + plotH + 6));
    }

    final nS = seriesLevels.length;
    final step = plotW / xLevels.length;

    if (plotType == StatsPlotType.line) {
      for (var s = 0; s < nS; s++) {
        final col = palette[s % palette.length];
        final path = Path();
        var started = false;
        final offsetPx = nS > 1 ? (s - (nS - 1) / 2.0) * 6.0 : 0.0;
        final pts = <Offset>[];
        for (var x = 0; x < xLevels.length; x++) {
          final st = getCell(s, x);
          if (st == null) continue;
          final px = xCenter(x) + offsetPx;
          final py = yOf(st.mean);
          pts.add(Offset(px, py));
          if (!started) {
            path.moveTo(px, py);
            started = true;
          } else {
            path.lineTo(px, py);
          }
          // Error bar
          final yTop = yOf(st.mean + st.err);
          final yBot = yOf(st.mean - st.err);
          final errPaint = Paint()
            ..color = col.withValues(alpha: 0.85)
            ..strokeWidth = 1.6;
          canvas.drawLine(Offset(px, yTop), Offset(px, yBot), errPaint);
          canvas.drawLine(
            Offset(px - 4.0, yTop),
            Offset(px + 4.0, yTop),
            errPaint,
          );
          canvas.drawLine(
            Offset(px - 4.0, yBot),
            Offset(px + 4.0, yBot),
            errPaint,
          );
        }
        if (started) {
          canvas.drawPath(
            path,
            Paint()
              ..color = col
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2.2,
          );
          final outlinePaint = Paint()
            ..color = const Color(0xFF0F172A)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.2;
          final fillPaint = Paint()..color = col;
          for (final pt in pts) {
            canvas.drawCircle(pt, 4.5, fillPaint);
            canvas.drawCircle(pt, 4.5, outlinePaint);
          }
        }
      }
    } else {
      // Bar or Boxplot grouped side-by-side at each X
      final groupW = step * 0.75;
      final itemW = math.max(6.0, groupW / math.max(1, nS));
      final baseY = yOf(yMin < 0 && yMax > 0 ? 0.0 : yMin);
      for (var x = 0; x < xLevels.length; x++) {
        final cx = xCenter(x);
        for (var s = 0; s < nS; s++) {
          final st = getCell(s, x);
          if (st == null) continue;
          final col = palette[s % palette.length];
          final bx = cx - groupW / 2 + s * itemW + itemW * 0.5;
          if (plotType == StatsPlotType.bar) {
            final topY = yOf(st.mean);
            final rect = Rect.fromLTRB(
              bx - itemW * 0.38,
              math.min(topY, baseY),
              bx + itemW * 0.38,
              math.max(topY, baseY),
            );
            canvas.drawRect(rect, Paint()..color = col.withValues(alpha: 0.7));
            final errPaint = Paint()
              ..color = Colors.white70
              ..strokeWidth = 1.3;
            canvas.drawLine(
              Offset(bx, yOf(st.mean + st.err)),
              Offset(bx, yOf(st.mean - st.err)),
              errPaint,
            );
          } else {
            // Boxplot with Tukey whiskers + subtle individual data points
            final iqr = (st.q3 - st.q1).abs();
            final lowFence = st.q1 - 1.5 * iqr;
            final highFence = st.q3 + 1.5 * iqr;
            var whiskLow = st.q1;
            var whiskHigh = st.q3;
            if (st.vals.isNotEmpty) {
              whiskLow = math.min(
                st.q1,
                st.vals.firstWhere((v) => v >= lowFence, orElse: () => st.q1),
              );
              whiskHigh = math.max(
                st.q3,
                st.vals.lastWhere((v) => v <= highFence, orElse: () => st.q3),
              );
            }
            final yQ3 = yOf(st.q3);
            final yQ1 = yOf(st.q1);
            final yWhiskHi = yOf(whiskHigh);
            final yWhiskLo = yOf(whiskLow);
            final whiskPaint = Paint()
              ..color = col.withValues(alpha: 0.65)
              ..strokeWidth = 1.2;
            final capHalfW = itemW * 0.22;
            canvas.drawLine(Offset(bx, yWhiskHi), Offset(bx, yQ3), whiskPaint);
            canvas.drawLine(
              Offset(bx - capHalfW, yWhiskHi),
              Offset(bx + capHalfW, yWhiskHi),
              whiskPaint,
            );
            canvas.drawLine(Offset(bx, yQ1), Offset(bx, yWhiskLo), whiskPaint);
            canvas.drawLine(
              Offset(bx - capHalfW, yWhiskLo),
              Offset(bx + capHalfW, yWhiskLo),
              whiskPaint,
            );

            final rect = Rect.fromLTRB(
              bx - itemW * 0.35,
              yQ3,
              bx + itemW * 0.35,
              yQ1,
            );
            canvas.drawRect(rect, Paint()..color = col.withValues(alpha: 0.24));
            canvas.drawRect(
              rect,
              Paint()
                ..color = col
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1.4,
            );

            final nPts = st.vals.length;
            final ptRadius = nPts > 40 ? 2.0 : 2.3;
            final ptFill = Paint()..color = col.withValues(alpha: 0.34);
            final ptStroke = Paint()
              ..color = Colors.white.withValues(alpha: 0.24)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 0.6;
            final maxJitter = itemW * 0.24;
            for (var vi = 0; vi < nPts; vi++) {
              final jFrac =
                  (((vi * 0.61803398875 + x * 0.37 + s * 0.19) % 1.0) - 0.5) *
                  2.0;
              final center = Offset(bx + jFrac * maxJitter, yOf(st.vals[vi]));
              canvas.drawCircle(center, ptRadius, ptFill);
              canvas.drawCircle(center, ptRadius, ptStroke);
            }

            canvas.drawLine(
              Offset(rect.left, yOf(st.median)),
              Offset(rect.right, yOf(st.median)),
              Paint()
                ..color = Colors.white
                ..strokeWidth = 2.0,
            );
          }
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _FacetPlotPainter oldDelegate) => true;
}
