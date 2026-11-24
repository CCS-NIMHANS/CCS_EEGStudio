import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'workbench_figures.dart';

/// Displays grouped Grand Average ERP waveforms (mean ± SEM) split by any
/// user-defined factor (e.g. Group, Session, Site) directly inside Stage 4.
class GroupedGrandAveragePlot extends StatefulWidget {
  const GroupedGrandAveragePlot({
    super.key,
    required this.files,
    required this.splitFactor,
    required this.fileFactors,
    required this.participantGroups,
    required this.roiLabels,
    required this.windowStartMs,
    required this.windowEndMs,
    this.selectedChannel,
    this.negativeUp = true,
  });

  final List<Map<String, dynamic>> files;
  final String splitFactor;
  final Map<String, Map<String, String>> fileFactors;
  final Map<String, String> participantGroups;
  final String? selectedChannel;
  final List<String> roiLabels;
  final double windowStartMs;
  final double windowEndMs;
  final bool negativeUp;

  @override
  State<GroupedGrandAveragePlot> createState() =>
      _GroupedGrandAveragePlotState();
}

class _GroupedGrandAveragePlotState extends State<GroupedGrandAveragePlot> {
  // true: Panels = Conditions, Lines = Factor levels
  // false: Panels = Factor levels, Lines = Conditions
  bool _panelsByCondition = true;
  bool _showSem = true;

  static const _palette = [
    Color(0xFF0072B2), // Okabe-Ito Blue
    Color(0xFFD55E00), // Vermilion
    Color(0xFF009E73), // Bluish Green
    Color(0xFFCC79A7), // Reddish Purple
    Color(0xFFE69F00), // Orange
    Color(0xFF56B4E9), // Sky Blue
    Color(0xFF8B5CF6), // Violet
    Color(0xFF334155), // Slate
  ];

  String _resolveFactorLevel(Map<String, dynamic> f) {
    final path = '${f['path'] ?? ''}';
    final fMap = widget.fileFactors[path];
    if (fMap != null) {
      final val = fMap[widget.splitFactor]?.trim();
      if (val != null && val.isNotEmpty) return val;
    }
    if (widget.splitFactor.toLowerCase() == 'group') {
      final subj = '${f['subject'] ?? ''}';
      final g = (widget.participantGroups[subj] ?? '${f['group'] ?? ''}').trim();
      if (g.isNotEmpty) return g;
    }
    return 'Unknown';
  }

  List<double>? _extractWaveForTarget(
    Map<String, dynamic> f,
    String condKey,
    List<String> targetLabels,
  ) {
    final labels = (f['labels'] as List? ?? const [])
        .map((e) => '$e'.toUpperCase())
        .toList();
    if (labels.isEmpty) return null;
    final indices = <int>[];
    for (final t in targetLabels) {
      final idx = labels.indexOf(t.toUpperCase());
      if (idx >= 0) indices.add(idx);
    }
    if (indices.isEmpty) return null;

    List? condGrid;
    final chans = f['channel_conditions'] as Map?;
    if (chans != null && chans.containsKey(condKey)) {
      condGrid = chans[condKey] as List?;
    } else if (condKey == 'A' || condKey == erpMap(f['profile'])['a_name']) {
      condGrid = f['channel_a'] as List?;
    } else if (condKey == 'B' || condKey == erpMap(f['profile'])['b_name']) {
      condGrid = f['channel_b'] as List?;
    }
    if (condGrid == null) return null;

    List<double>? avg;
    var count = 0;
    for (final ci in indices) {
      if (ci >= condGrid.length) continue;
      final wave = erpNumbers(condGrid[ci]);
      if (wave.isEmpty) continue;
      avg ??= List<double>.filled(wave.length, 0.0);
      if (wave.length != avg.length) continue;
      for (var t = 0; t < wave.length; t++) {
        avg[t] += wave[t];
      }
      count++;
    }
    if (avg == null || count == 0) return null;
    if (count > 1) {
      final inv = 1.0 / count;
      for (var t = 0; t < avg.length; t++) {
        avg[t] *= inv;
      }
    }
    return avg;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.files.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: Text('No recordings available.')),
      );
    }
    final first = widget.files.first;
    final timesSec = erpNumbers(first['times']);
    final timesMs = timesSec.map((t) => t * 1000.0).toList();
    if (timesMs.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: Text('No time axis found in recordings.')),
      );
    }

    final targetLabels = widget.selectedChannel != null
        ? [widget.selectedChannel!]
        : (widget.roiLabels.isNotEmpty
              ? widget.roiLabels
              : (first['labels'] as List? ?? const [])
                    .take(1)
                    .map((e) => '$e')
                    .toList());

    final condSet = <String>{};
    final levelSet = <String>{};
    // (level, cond) -> list of waves
    final cellWaves = <String, Map<String, List<List<double>>>>{};

    for (final f in widget.files) {
      final level = _resolveFactorLevel(f);
      levelSet.add(level);
      final chans = f['channel_conditions'] as Map?;
      final condKeys = <String>[
        if (chans != null)
          ...chans.keys.map((k) => '$k').where((k) => k != 'B_minus_A')
        else ...[
          if (f['channel_a'] != null)
            '${erpMap(f['profile'])['a_name'] ?? 'A'}',
          if (f['channel_b'] != null)
            '${erpMap(f['profile'])['b_name'] ?? 'B'}',
        ],
      ];
      for (final ck in condKeys) {
        final w = _extractWaveForTarget(f, ck, targetLabels);
        if (w == null || w.length != timesMs.length) continue;
        condSet.add(ck);
        cellWaves
            .putIfAbsent(level, () => {})
            .putIfAbsent(ck, () => [])
            .add(w);
      }
    }

    final levels = levelSet.toList()..sort();
    final conditions = condSet.toList();
    if (levels.isEmpty || conditions.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(
          child: Text('Could not extract grouped channel/ROI waveforms.'),
        ),
      );
    }

    // Compute mean & SEM per (level, cond)
    final stats = <String, Map<String, ({List<double> mean, List<double> sem, int n})>>{};
    var yMaxAbs = 1.0;
    for (final lv in levels) {
      for (final ck in conditions) {
        final waves = cellWaves[lv]?[ck] ?? const [];
        if (waves.isEmpty) continue;
        final n = waves.length;
        final nT = timesMs.length;
        final mean = List<double>.filled(nT, 0.0);
        final sem = List<double>.filled(nT, 0.0);
        for (var t = 0; t < nT; t++) {
          var s = 0.0;
          for (final w in waves) {
            s += w[t];
          }
          final m = s / n;
          mean[t] = m;
          if (n > 1) {
            var ss = 0.0;
            for (final w in waves) {
              final d = w[t] - m;
              ss += d * d;
            }
            sem[t] = math.sqrt(ss / (n - 1)) / math.sqrt(n);
          }
          yMaxAbs = math.max(yMaxAbs, m.abs() + (_showSem ? sem[t] : 0.0));
        }
        stats.putIfAbsent(lv, () => {})[ck] = (mean: mean, sem: sem, n: n);
      }
    }
    yMaxAbs *= 1.15;

    final panelKeys = _panelsByCondition ? conditions : levels;
    final lineKeys = _panelsByCondition ? levels : conditions;

    // Count unique subjects/recordings per line key for legend
    final lineCounts = <String, int>{};
    for (final lk in lineKeys) {
      var maxN = 0;
      for (final pk in panelKeys) {
        final lv = _panelsByCondition ? lk : pk;
        final ck = _panelsByCondition ? pk : lk;
        final cell = stats[lv]?[ck];
        if (cell != null && cell.n > maxN) maxN = cell.n;
      }
      lineCounts[lk] = maxN;
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFCBD5E1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: const BoxDecoration(
              color: Color(0xFFF1F5F9),
              borderRadius: BorderRadius.vertical(top: Radius.circular(7)),
            ),
            child: Wrap(
              spacing: 12,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  'Grouped Grand Average by ${widget.splitFactor} · ${widget.selectedChannel != null ? "Electrode: ${widget.selectedChannel}" : "ROI: ${targetLabels.join(", ")}"}',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                    color: Color(0xFF0F172A),
                  ),
                ),
                SegmentedButton<bool>(
                  segments: [
                    ButtonSegment(
                      value: true,
                      label: Text(
                        'Panels: Condition · Lines: ${widget.splitFactor}',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                    ButtonSegment(
                      value: false,
                      label: Text(
                        'Panels: ${widget.splitFactor} · Lines: Condition',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                  ],
                  selected: {_panelsByCondition},
                  onSelectionChanged: (s) =>
                      setState(() => _panelsByCondition = s.first),
                ),
                FilterChip(
                  visualDensity: VisualDensity.compact,
                  label: const Text('± SEM', style: TextStyle(fontSize: 11)),
                  selected: _showSem,
                  onSelected: (v) => setState(() => _showSem = v),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
            child: Wrap(
              spacing: 14,
              runSpacing: 4,
              children: [
                for (var i = 0; i < lineKeys.length; i++)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 14,
                        height: 3,
                        color: _palette[i % _palette.length],
                      ),
                      const SizedBox(width: 5),
                      Text(
                        '${lineKeys[i]} (n=${lineCounts[lineKeys[i]] ?? 0})',
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 2, 8, 10),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final cols = panelKeys.length <= 4
                    ? panelKeys.length
                    : (panelKeys.length <= 6 ? 3 : 4);
                final rowsCount = (panelKeys.length / cols).ceil();
                final panelHeight = rowsCount == 1 ? 260.0 : 210.0;
                return Column(
                  children: [
                    for (var r = 0; r < rowsCount; r++)
                      SizedBox(
                        height: panelHeight,
                        child: Row(
                          children: [
                            for (var c = 0; c < cols; c++)
                              if (r * cols + c < panelKeys.length)
                                Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.all(4),
                                    child: _buildSinglePanel(
                                      title: panelKeys[r * cols + c],
                                      timesMs: timesMs,
                                      yMaxAbs: yMaxAbs,
                                      traces: [
                                        for (var i = 0; i < lineKeys.length; i++)
                                          () {
                                            final pk = panelKeys[r * cols + c];
                                            final lk = lineKeys[i];
                                            final lv = _panelsByCondition
                                                ? lk
                                                : pk;
                                            final ck = _panelsByCondition
                                                ? pk
                                                : lk;
                                            final cell = stats[lv]?[ck];
                                            return (
                                              label: lk,
                                              color:
                                                  _palette[i % _palette.length],
                                              mean: cell?.mean,
                                              sem: cell?.sem,
                                            );
                                          }(),
                                      ],
                                    ),
                                  ),
                                )
                              else
                                const Expanded(child: SizedBox.shrink()),
                          ],
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSinglePanel({
    required String title,
    required List<double> timesMs,
    required double yMaxAbs,
    required List<
      ({String label, Color color, List<double>? mean, List<double>? sem})
    >
    traces,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFE2E8F0)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: const BoxDecoration(
              color: Color(0xFFF8FAFC),
              borderRadius: BorderRadius.vertical(top: Radius.circular(5)),
            ),
            child: Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.bold,
                color: Color(0xFF0F172A),
              ),
            ),
          ),
          Expanded(
            child: CustomPaint(
              painter: _GroupedPanelPainter(
                timesMs: timesMs,
                yMaxAbs: yMaxAbs,
                traces: traces,
                winStartMs: widget.windowStartMs,
                winEndMs: widget.windowEndMs,
                negativeUp: widget.negativeUp,
                showSem: _showSem,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GroupedPanelPainter extends CustomPainter {
  const _GroupedPanelPainter({
    required this.timesMs,
    required this.yMaxAbs,
    required this.traces,
    required this.winStartMs,
    required this.winEndMs,
    required this.negativeUp,
    required this.showSem,
  });

  final List<double> timesMs;
  final double yMaxAbs;
  final List<
    ({String label, Color color, List<double>? mean, List<double>? sem})
  >
  traces;
  final double winStartMs;
  final double winEndMs;
  final bool negativeUp;
  final bool showSem;

  @override
  void paint(Canvas canvas, Size size) {
    if (timesMs.isEmpty || size.width < 20 || size.height < 20) return;

    const leftPad = 36.0;
    const rightPad = 8.0;
    const topPad = 8.0;
    const bottomPad = 20.0;
    final plotW = math.max(1.0, size.width - leftPad - rightPad);
    final plotH = math.max(1.0, size.height - topPad - bottomPad);

    final tMin = timesMs.first;
    final tMax = timesMs.last;
    final tSpan = math.max(1e-6, tMax - tMin);
    double xOf(double ms) => leftPad + ((ms - tMin) / tSpan) * plotW;

    double yOf(double uv) {
      final norm = (uv / yMaxAbs).clamp(-1.0, 1.0);
      final signed = negativeUp ? norm : -norm;
      return topPad + plotH * 0.5 * (1.0 + signed);
    }

    // Measurement window shading
    if (winEndMs > winStartMs) {
      final x0 = xOf(winStartMs.clamp(tMin, tMax));
      final x1 = xOf(winEndMs.clamp(tMin, tMax));
      canvas.drawRect(
        Rect.fromLTRB(x0, topPad, x1, topPad + plotH),
        Paint()..color = const Color(0xFF6366F1).withValues(alpha: 0.12),
      );
    }

    // Grid & axes
    final gridPaint = Paint()
      ..color = const Color(0xFFE2E8F0)
      ..strokeWidth = 1.0;
    canvas.drawRect(
      Rect.fromLTWH(leftPad, topPad, plotW, plotH),
      gridPaint..style = PaintingStyle.stroke,
    );
    final zeroPaint = Paint()
      ..color = const Color(0xFF64748B)
      ..strokeWidth = 1.0;
    canvas.drawLine(
      Offset(leftPad, yOf(0)),
      Offset(leftPad + plotW, yOf(0)),
      zeroPaint,
    );
    if (0 >= tMin && 0 <= tMax) {
      canvas.drawLine(
        Offset(xOf(0), topPad),
        Offset(xOf(0), topPad + plotH),
        zeroPaint,
      );
    }

    // Waveforms + SEM ribbons
    for (final tr in traces) {
      final mean = tr.mean;
      final sem = tr.sem;
      if (mean == null || mean.length != timesMs.length) continue;

      if (showSem && sem != null && sem.length == timesMs.length) {
        final band = Path();
        for (var i = 0; i < timesMs.length; i++) {
          final x = xOf(timesMs[i]);
          final y = yOf(mean[i] + sem[i]);
          if (i == 0) {
            band.moveTo(x, y);
          } else {
            band.lineTo(x, y);
          }
        }
        for (var i = timesMs.length - 1; i >= 0; i--) {
          band.lineTo(xOf(timesMs[i]), yOf(mean[i] - sem[i]));
        }
        band.close();
        canvas.drawPath(
          band,
          Paint()..color = tr.color.withValues(alpha: 0.16),
        );
      }

      final path = Path();
      for (var i = 0; i < timesMs.length; i++) {
        final pt = Offset(xOf(timesMs[i]), yOf(mean[i]));
        if (i == 0) {
          path.moveTo(pt.dx, pt.dy);
        } else {
          path.lineTo(pt.dx, pt.dy);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = tr.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8,
      );
    }

    // Y ticks
    for (final uv in [yMaxAbs, 0.0, -yMaxAbs]) {
      final tp = TextPainter(
        text: TextSpan(
          text: uv.toStringAsFixed(1),
          style: const TextStyle(color: Color(0xFF475569), fontSize: 9),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(4, yOf(uv) - tp.height / 2));
    }

    // X ticks
    for (final ms in [tMin, 0.0, tMax]) {
      if (ms < tMin || ms > tMax) continue;
      final tp = TextPainter(
        text: TextSpan(
          text: '${ms.round()}',
          style: const TextStyle(color: Color(0xFF475569), fontSize: 9),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(xOf(ms) - tp.width / 2, topPad + plotH + 4));
    }
  }

  @override
  bool shouldRepaint(covariant _GroupedPanelPainter oldDelegate) => true;
}
