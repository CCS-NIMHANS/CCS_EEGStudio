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
  final out = <StatsPlotBracket>[];
  final xs = levels[config.xFactor] ?? ['All'],
      ss = levels[config.seriesFactor] ?? ['All'];
  for (final p in contrasts) {
    if ((p['p_adj'] as num? ?? 1) >= .05) continue;
    final f = '${p['factor']}';
    if (f != config.xFactor && f != config.seriesFactor) continue;
    final stratum = Map<String, dynamic>.from(p['stratum'] as Map? ?? {});
    if (config.facetColFactor != null &&
        stratum[config.facetColFactor] != column)
      continue;
    if (config.facetRowFactor != null && stratum[config.facetRowFactor] != row)
      continue;
    final roles = {
      config.xFactor,
      config.seriesFactor,
      config.facetColFactor,
      config.facetRowFactor,
    };
    if (stratum.keys.any((key) => !roles.contains(key))) continue;
    if (stratum.isEmpty &&
        factors.any((other) => other != f && roles.contains(other)))
      continue;
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
    final q = (p['p_adj'] as num).toDouble();
    final mark = q < .001
        ? '***'
        : q < .01
        ? '**'
        : '*';
    out.add((
      xA: xa,
      xB: xb,
      seriesA: sa,
      seriesB: sb,
      label:
          '${isX ? config.levelLabel(config.seriesFactor, ss[sa]) : config.levelLabel(config.xFactor, xs[xa])} $mark',
    ));
  }
  return out;
}

/// Configurable multi-factor statistical plot widget.
/// Renders either a live interactive dummy preview (before analysis) or real
/// cell descriptives (after analysis) using identical role-mapping and ordering.
class ConfigurableStatsPlotWidget extends StatelessWidget {
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

  List<String> _levelsOf(String? factor) {
    if (factor == null || factor.isEmpty || factor == 'None')
      return const ['All'];
    final lvls = factorLevels[factor];
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
    if (isDummyPreview) {
      // Deterministic, visually distinct dummy curves so users can inspect
      // line separation, X-axis progression, and subplot faceting.
      final base = 4.0 + seriesIdx * 1.8 + colIdx * 1.1 + rowIdx * 0.6;
      final wave = math.sin((xIdx + 1) * 0.9 + seriesIdx * 0.7) * 2.2;
      final mean = base + wave;
      final err = 0.65 + (seriesIdx % 3) * 0.15;
      return (
        mean: mean,
        err: err,
        q1: mean - err * 1.2,
        median: mean + 0.1,
        q3: mean + err * 1.2,
        vals: [mean - err, mean, mean + err],
      );
    }

    // Real data: match all cells in cellDescriptives that satisfy the role filters
    final matchedVals = <double>[];
    for (final entry in cellDescriptives.entries) {
      final parts = <String, String>{};
      for (final seg in entry.key.split('|')) {
        final eq = seg.indexOf('=');
        if (eq > 0) {
          parts[seg.substring(0, eq)] = seg.substring(eq + 1);
        }
      }
      if (config.xFactor != null && parts[config.xFactor] != xVal) continue;
      if (config.seriesFactor != null &&
          seriesVal != null &&
          parts[config.seriesFactor] != seriesVal) {
        continue;
      }
      if (config.facetColFactor != null &&
          colVal != null &&
          parts[config.facetColFactor] != colVal) {
        continue;
      }
      if (config.facetRowFactor != null &&
          rowVal != null &&
          parts[config.facetRowFactor] != rowVal) {
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
      err: config.useSem ? sem : sd,
      q1: matchedVals[(n * 0.25).floor().clamp(0, n - 1)],
      median: matchedVals[(n * 0.5).floor().clamp(0, n - 1)],
      q3: matchedVals[(n * 0.75).floor().clamp(0, n - 1)],
      vals: matchedVals,
    );
  }

  List<Widget> _annotations() {
    if (isDummyPreview) return [];
    final significant = posthocs
        .where((p) => (p['p_adj'] as num? ?? 1) < .05)
        .toList();
    return [
      ExpansionTile(
        title: Text(
          'Corrected contrast details · ${significant.length} significant',
        ),
        subtitle: const Text(
          'Markers show up to eight matching cell contrasts per panel. Expand for all adjusted comparisons.',
        ),
        children: [
          Text(
            'Post-hoc comparisons: adjusted p < .05 (${significant.length}). Simple effects apply only to the named cohort/session cells; marginal contrasts collapse other factors.',
            style: const TextStyle(fontSize: 11),
          ),
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
                        '${config.factorLabel(e.key)}=${config.levelLabel(e.key, "${e.value}")}',
                  )
                  .join(', ');
              final q = (p['p_adj'] as num).toDouble();
              final mark = q < .001
                  ? '***'
                  : q < .01
                  ? '**'
                  : '*';
              return '$mark ${config.factorLabel(factor)}: ${config.levelLabel(factor, "${p['group_a']}")} ↔ ${config.levelLabel(factor, "${p['group_b']}")} · ${context.isEmpty ? 'marginal' : context} · adjusted p=${q.toStringAsPrecision(3)}';
            }(), style: const TextStyle(fontSize: 11, color: Colors.tealAccent)),
        ],
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final xLevels = _levelsOf(config.xFactor);
    final seriesLevels = _levelsOf(config.seriesFactor);
    final colLevels = _levelsOf(config.facetColFactor);
    final rowLevels = _levelsOf(config.facetRowFactor);

    // Compute global Y range across all facets for consistent axis scaling
    var yMin = double.infinity;
    var yMax = double.negativeInfinity;
    for (var r = 0; r < rowLevels.length; r++) {
      for (var c = 0; c < colLevels.length; c++) {
        for (var s = 0; s < seriesLevels.length; s++) {
          for (var x = 0; x < xLevels.length; x++) {
            final st = _cellStats(
              rowVal: config.facetRowFactor == null ? null : rowLevels[r],
              colVal: config.facetColFactor == null ? null : colLevels[c],
              seriesVal: config.seriesFactor == null ? null : seriesLevels[s],
              xVal: xLevels[x],
              rowIdx: r,
              colIdx: c,
              seriesIdx: s,
              xIdx: x,
            );
            if (st == null) continue;
            yMin = math.min(yMin, st.mean - st.err * 1.3);
            yMax = math.max(yMax, st.mean + st.err * 1.3);
            if (config.plotType == StatsPlotType.boxplot &&
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

    return Container(
      height: height,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isDummyPreview
              ? Colors.amberAccent.withValues(alpha: 0.45)
              : Colors.white12,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (isDummyPreview)
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
                  '$metricName  ·  X: ${config.factorLabel(config.xFactor)}  |  Lines/Hue: ${config.factorLabel(config.seriesFactor)}  |  Cols: ${config.factorLabel(config.facetColFactor)}${config.facetRowFactor != null ? "  |  Rows: ${config.facetRowFactor}" : ""}',
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Legend for Series / Hue
          if (config.seriesFactor != null)
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                Text(
                  '${config.factorLabel(config.seriesFactor)}:',
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
                            config.seriesColors[seriesLevels[s]] ??
                                _palette[s % _palette.length].toARGB32(),
                          ),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        config.levelLabel(config.seriesFactor, seriesLevels[s]),
                        style: const TextStyle(fontSize: 11),
                      ),
                    ],
                  ),
              ],
            ),
          const SizedBox(height: 6),
          Expanded(
            child: Column(
              children: [
                for (var r = 0; r < rowLevels.length; r++)
                  Expanded(
                    child: Row(
                      children: [
                        if (config.facetRowFactor != null)
                          RotatedBox(
                            quarterTurns: 3,
                            child: Text(
                              '${config.factorLabel(config.facetRowFactor)}: ${config.levelLabel(config.facetRowFactor, rowLevels[r])}',
                              style: const TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.bold,
                                color: Colors.white70,
                              ),
                            ),
                          ),
                        for (var c = 0; c < colLevels.length; c++)
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: Column(
                                children: [
                                  if (config.facetColFactor != null)
                                    Text(
                                      '${config.factorLabel(config.facetColFactor)}: ${config.levelLabel(config.facetColFactor, colLevels[c])}',
                                      style: const TextStyle(
                                        fontSize: 11,
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
                                              (x) => config.levelLabel(
                                                config.xFactor,
                                                x,
                                              ),
                                            )
                                            .toList(),
                                        seriesLevels: seriesLevels,
                                        brackets: statsPlotBrackets(
                                          config: config,
                                          contrasts: posthocs,
                                          factors: activeFactors,
                                          levels: factorLevels,
                                          row: config.facetRowFactor == null
                                              ? null
                                              : rowLevels[r],
                                          column: config.facetColFactor == null
                                              ? null
                                              : colLevels[c],
                                        ),
                                        plotType: config.plotType,
                                        yMin: yMin,
                                        yMax: yMax,
                                        palette: [
                                          for (final (index, level)
                                              in seriesLevels.indexed)
                                            Color(
                                              config.seriesColors[level] ??
                                                  _palette[index %
                                                          _palette.length]
                                                      .toARGB32(),
                                            ),
                                        ],
                                        getCell: (sIdx, xIdx) => _cellStats(
                                          rowVal: config.facetRowFactor == null
                                              ? null
                                              : rowLevels[r],
                                          colVal: config.facetColFactor == null
                                              ? null
                                              : colLevels[c],
                                          seriesVal: config.seriesFactor == null
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
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
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
  });

  final List<String> xLevels;
  final List<String> seriesLevels;
  final StatsPlotType plotType;
  final List<StatsPlotBracket> brackets;
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

    const leftPad = 38.0;
    const rightPad = 10.0;
    final topPad = 24.0 + math.min(brackets.length, 8) * 16;
    const bottomPad = 24.0;
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
      if (plotType == StatsPlotType.line)
        return xCenter(x) +
            (seriesLevels.length > 1
                ? (series - (seriesLevels.length - 1) / 2) * 4
                : 0);
      return xCenter(x) +
          (series - (seriesLevels.length - 1) / 2) *
              step *
              .7 /
              seriesLevels.length;
    }

    for (final (i, b) in brackets.take(8).indexed) {
      final a = bracketX(b.xA, b.seriesA),
          z = bracketX(b.xB, b.seriesB),
          y = 16.0 + i * 16;
      final paint = Paint()
        ..color = Colors.white70
        ..strokeWidth = 1;
      canvas.drawLine(Offset(a, y + 4), Offset(a, y), paint);
      canvas.drawLine(Offset(a, y), Offset(z, y), paint);
      canvas.drawLine(Offset(z, y), Offset(z, y + 4), paint);
      final text = TextPainter(
        text: TextSpan(
          text: b.label,
          style: const TextStyle(fontSize: 9, color: Colors.white),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      text.paint(canvas, Offset((a + z) / 2 - text.width / 2, y - text.height));
    }

    // Axes & grid
    final gridPaint = Paint()
      ..color = Colors.white12
      ..strokeWidth = 1.0;
    canvas.drawRect(
      Rect.fromLTWH(leftPad, topPad, plotW, plotH),
      gridPaint..style = PaintingStyle.stroke,
    );

    for (final yVal in [yMin, (yMin + yMax) * 0.5, yMax]) {
      final y = yOf(yVal);
      canvas.drawLine(
        Offset(leftPad, y),
        Offset(leftPad + plotW, y),
        gridPaint,
      );
      final tp = TextPainter(
        text: TextSpan(
          text: yVal.toStringAsFixed(1),
          style: const TextStyle(color: Colors.white54, fontSize: 9),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(2, y - tp.height / 2));
    }

    // X labels
    for (var x = 0; x < xLevels.length; x++) {
      final cx = xCenter(x);
      final tp = TextPainter(
        text: TextSpan(
          text: xLevels[x],
          style: const TextStyle(color: Colors.white70, fontSize: 9.5),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout(maxWidth: plotW / xLevels.length);
      tp.paint(canvas, Offset(cx - tp.width / 2, topPad + plotH + 5));
    }

    final nS = seriesLevels.length;
    final step = plotW / xLevels.length;

    if (plotType == StatsPlotType.line) {
      for (var s = 0; s < nS; s++) {
        final col = palette[s % palette.length];
        final path = Path();
        var started = false;
        final offsetPx = nS > 1 ? (s - (nS - 1) / 2.0) * 4.0 : 0.0;
        for (var x = 0; x < xLevels.length; x++) {
          final st = getCell(s, x);
          if (st == null) continue;
          final px = xCenter(x) + offsetPx;
          final py = yOf(st.mean);
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
            ..color = col.withValues(alpha: 0.75)
            ..strokeWidth = 1.4;
          canvas.drawLine(Offset(px, yTop), Offset(px, yBot), errPaint);
          canvas.drawLine(Offset(px - 3, yTop), Offset(px + 3, yTop), errPaint);
          canvas.drawLine(Offset(px - 3, yBot), Offset(px + 3, yBot), errPaint);
          canvas.drawCircle(Offset(px, py), 4.0, Paint()..color = col);
        }
        if (started) {
          canvas.drawPath(
            path,
            Paint()
              ..color = col
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2.0,
          );
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
            // Boxplot
            final rect = Rect.fromLTRB(
              bx - itemW * 0.35,
              yOf(st.q3),
              bx + itemW * 0.35,
              yOf(st.q1),
            );
            canvas.drawRect(rect, Paint()..color = col.withValues(alpha: 0.35));
            canvas.drawRect(
              rect,
              Paint()
                ..color = col
                ..style = PaintingStyle.stroke
                ..strokeWidth = 1.4,
            );
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
