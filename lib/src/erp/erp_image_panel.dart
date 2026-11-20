import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'interactive_erp_session.dart';
import 'workbench_figures.dart';

enum ErpImageSort { chronological, meanAmplitude, peakAmplitude }

/// Interactive trial-by-time ERPimage heatmap with click/drag epoch rejection.
class ErpImagePanel extends StatefulWidget {
  const ErpImagePanel({
    super.key,
    required this.session,
    required this.channelIndex,
    required this.trialIndices,
    required this.onToggleReject,
    this.onInspectTrial,
    this.windowStartMs = 300.0,
    this.windowEndMs = 600.0,
    this.onTopoWindowChanged,
    this.activeTrialIndex,
    this.average,
  });

  final Widget? average;
  final InteractiveErpSession session;
  final int channelIndex;
  final List<int> trialIndices;
  final void Function(int trialIndex, bool reject) onToggleReject;
  final ValueChanged<int>? onInspectTrial;
  final double windowStartMs;
  final double windowEndMs;
  final ValueChanged<(double, double)>? onTopoWindowChanged;
  final int? activeTrialIndex;

  @override
  State<ErpImagePanel> createState() => _ErpImagePanelState();
}

class _ErpImagePanelState extends State<ErpImagePanel> {
  ErpImageSort _sort = ErpImageSort.chronological;
  int _smoothTrials = 5;
  String? _selectedCondition;
  bool _dragActionReject = true;
  int? _lastDraggedRow;
  Offset? _hoverPos;
  late final TextEditingController _topo0 = TextEditingController(
    text: '${widget.windowStartMs.round()}',
  );
  late final TextEditingController _topo1 = TextEditingController(
    text: '${widget.windowEndMs.round()}',
  );

  @override
  void didUpdateWidget(covariant ErpImagePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.windowStartMs != widget.windowStartMs) {
      _topo0.text = '${widget.windowStartMs.round()}';
    }
    if (oldWidget.windowEndMs != widget.windowEndMs) {
      _topo1.text = '${widget.windowEndMs.round()}';
    }
  }

  @override
  void dispose() {
    _topo0.dispose();
    _topo1.dispose();
    super.dispose();
  }

  void _applyTopoWindow() {
    final a = double.tryParse(_topo0.text.trim());
    final b = double.tryParse(_topo1.text.trim());
    if (a != null && b != null) {
      final lo = math.min(a, b);
      final hi = math.max(a, b);
      widget.onTopoWindowChanged?.call((lo, hi));
    }
  }

  List<int> _sortedTrials() {
    final s = widget.session;
    final baseList = _selectedCondition != null
        ? [
            for (var i = 0; i < s.epochs.epochCount; i++)
              if (s.condition(i) == _selectedCondition) i,
          ]
        : List<int>.from(widget.trialIndices);
    if (baseList.length <= 1) return baseList;

    double metric(int trialIdx) {
      final pts = s.points;
      final tminMs = (s.epochs.epochTmin ?? -0.2) * 1000.0;
      final dtMs = 1000.0 / s.epochs.sampleRate;
      final winSamples = <int>[
        for (var k = 0; k < pts; k++)
          if (tminMs + k * dtMs >= widget.windowStartMs &&
              tminMs + k * dtMs <= widget.windowEndMs)
            k,
      ];
      final activeSamples = winSamples.isEmpty
          ? List<int>.generate(pts, (i) => i)
          : winSamples;
      if (_sort == ErpImageSort.meanAmplitude) {
        var sum = 0.0;
        for (final k in activeSamples) {
          sum += s.trialSample(trialIdx, widget.channelIndex, k);
        }
        return sum / activeSamples.length;
      } else {
        var peak = 0.0;
        for (final k in activeSamples) {
          final v = s.trialSample(trialIdx, widget.channelIndex, k).abs();
          if (v > peak) peak = v;
        }
        return peak;
      }
    }

    final scores = _sort == ErpImageSort.chronological
        ? const <int, double>{}
        : {for (final idx in baseList) idx: metric(idx)};

    final condOrder = {
      for (var i = 0; i < s.conditions.length; i++) s.conditions[i]: i,
    };
    baseList.sort((a, b) {
      final ca = condOrder[s.condition(a)] ?? 999;
      final cb = condOrder[s.condition(b)] ?? 999;
      if (ca != cb) return ca.compareTo(cb);
      if (_sort == ErpImageSort.chronological) return a.compareTo(b);
      return scores[b]!.compareTo(scores[a]!);
    });
    return baseList;
  }

  int? _rowAtY(double y, double height, int nRows) {
    if (nRows <= 0) return null;
    const topPad = 14.0;
    const bottomPad = 28.0;
    final plotH = math.max(1.0, height - topPad - bottomPad);
    if (y < topPad || y > topPad + plotH) return null;
    final row = ((y - topPad) / plotH * nRows).floor();
    return row.clamp(0, nRows - 1);
  }

  @override
  Widget build(BuildContext context) {
    final sorted = _sortedTrials();
    final s = widget.session;
    final chName = widget.channelIndex < s.epochs.labels.length
        ? s.epochs.labels[widget.channelIndex]
        : 'Ch ${widget.channelIndex + 1}';

    final condNames = s.conditions;
    final activeGroup = (_selectedCondition != null && condNames.contains(_selectedCondition))
        ? _selectedCondition
        : null;
    final groupDesc = activeGroup ??
        (condNames.length > 1
            ? condNames.join(' + ')
            : (condNames.isNotEmpty ? condNames.first : 'All'));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Wrap(
            spacing: 10,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                'ERPimage ($chName · $groupDesc · ${sorted.length} trials)',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
              if (condNames.length > 1)
                DropdownButton<String?>(
                  value: activeGroup,
                  isDense: true,
                  underline: const SizedBox.shrink(),
                  items: [
                    DropdownMenuItem<String?>(
                      value: null,
                      child: Text(
                        'Group: Both (${widget.trialIndices.length})',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    for (var ci = 0; ci < condNames.length; ci++)
                      DropdownMenuItem<String?>(
                        value: condNames[ci],
                        child: Text(
                          'Group: ${condNames[ci]} (${s.counts[condNames[ci]] ?? 0})',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                  ],
                  onChanged: (v) => setState(() => _selectedCondition = v),
                ),
              DropdownButton<ErpImageSort>(
                value: _sort,
                isDense: true,
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(
                    value: ErpImageSort.chronological,
                    child: Text(
                      'Sort: Trial order',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                  DropdownMenuItem(
                    value: ErpImageSort.meanAmplitude,
                    child: Text(
                      'Sort: Window mean µV',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                  DropdownMenuItem(
                    value: ErpImageSort.peakAmplitude,
                    child: Text(
                      'Sort: Window peak |µV|',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _sort = v);
                },
              ),
              DropdownButton<int>(
                value: _smoothTrials,
                isDense: true,
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(value: 1, child: Text('Smooth: Raw (1)', style: TextStyle(fontSize: 12))),
                  DropdownMenuItem(value: 3, child: Text('Smooth: 3 trials', style: TextStyle(fontSize: 12))),
                  DropdownMenuItem(value: 5, child: Text('Smooth: 5 trials', style: TextStyle(fontSize: 12))),
                  DropdownMenuItem(value: 10, child: Text('Smooth: 10 trials', style: TextStyle(fontSize: 12))),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _smoothTrials = v);
                },
              ),
              const Text(
                'Click or drag rows to exclude/include trials',
                style: TextStyle(fontSize: 11, color: Colors.white70),
              ),
              _legendChip('Blue: −µV', const Color(0xFF3B82F6)),
              _legendChip('Red: +µV', const Color(0xFFEF4444)),
              _legendChip('Dim/Red bar: Excluded', const Color(0xFFDC2626)),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Column(children: [Expanded(child: LayoutBuilder(
                    builder: (context, constraints) {
                final h = constraints.maxHeight;
                return MouseRegion(
                  onHover: (e) => setState(() => _hoverPos = e.localPosition),
                  onExit: (_) => setState(() => _hoverPos = null),
                  child: GestureDetector(
                    onTapDown: (d) {
                      final row = _rowAtY(
                        d.localPosition.dy,
                        h,
                        sorted.length,
                      );
                      if (row == null) return;
                      final trialIdx = sorted[row];
                      final isRejected = s.rejected.contains(trialIdx);
                      widget.onToggleReject(trialIdx, !isRejected);
                    },
                    onDoubleTapDown: (d) {
                      if (widget.onInspectTrial == null) return;
                      final row = _rowAtY(
                        d.localPosition.dy,
                        h,
                        sorted.length,
                      );
                      if (row != null) widget.onInspectTrial!(sorted[row]);
                    },
                    onVerticalDragStart: (d) {
                      final row = _rowAtY(
                        d.localPosition.dy,
                        h,
                        sorted.length,
                      );
                      if (row == null) return;
                      final trialIdx = sorted[row];
                      _dragActionReject = !s.rejected.contains(trialIdx);
                      _lastDraggedRow = row;
                      widget.onToggleReject(trialIdx, _dragActionReject);
                    },
                    onVerticalDragUpdate: (d) {
                      final row = _rowAtY(
                        d.localPosition.dy,
                        h,
                        sorted.length,
                      );
                      if (row == null || row == _lastDraggedRow) return;
                      final a = math.min(_lastDraggedRow ?? row, row);
                      final b = math.max(_lastDraggedRow ?? row, row);
                      for (var r = a; r <= b; r++) {
                        widget.onToggleReject(sorted[r], _dragActionReject);
                      }
                      _lastDraggedRow = row;
                    },
                    onVerticalDragEnd: (_) => _lastDraggedRow = null,
                    child: CustomPaint(
                      painter: _ErpImagePainter(
                        session: s,
                        channelIndex: widget.channelIndex,
                        sortedTrials: sorted,
                        sort: _sort,
                        revision: s.revision,
                        hoverPos: _hoverPos,
                        windowStartMs: widget.windowStartMs,
                        windowEndMs: widget.windowEndMs,
                        smoothTrials: _smoothTrials,
                        activeTrialIndex: widget.activeTrialIndex,
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                );
                },
              )),
                if (widget.average != null) widget.average!,
              ]),
                ),
                if (s.epochs.labels.length >= 4) ...[
                  const SizedBox(width: 10),
                  Container(
                    width: 230,
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFCBD5E1)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: CustomPaint(
                            painter: ErpWorkbenchTopoPainter(
                              {
                                'labels': s.epochs.labels,
                                'profile': const {'a_name': 'Accepted', 'b_name': ''},
                              },
                              valuesOverride: _computeTopoValues(s, sorted),
                              customTitle:
                                  'ERPimage Topo (${widget.windowStartMs.round()}–${widget.windowEndMs.round()} ms)',
                              showPValues: false,
                              selectedChannels: {chName},
                            ),
                            child: const SizedBox.expand(),
                          ),
                        ),
                        if (widget.onTopoWindowChanged != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Row(
                              children: [
                                const Text(
                                  'Topo ms:',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: Color(0xFF334155),
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: SizedBox(
                                    height: 24,
                                    child: TextField(
                                      controller: _topo0,
                                      style: const TextStyle(
                                        fontSize: 10,
                                        color: Color(0xFF0F172A),
                                      ),
                                      decoration: const InputDecoration(
                                        isDense: true,
                                        contentPadding: EdgeInsets.symmetric(
                                          horizontal: 4,
                                          vertical: 4,
                                        ),
                                        border: OutlineInputBorder(),
                                      ),
                                      onSubmitted: (_) => _applyTopoWindow(),
                                    ),
                                  ),
                                ),
                                const Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 3),
                                  child: Text(
                                    '–',
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: Color(0xFF334155),
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: SizedBox(
                                    height: 24,
                                    child: TextField(
                                      controller: _topo1,
                                      style: const TextStyle(
                                        fontSize: 10,
                                        color: Color(0xFF0F172A),
                                      ),
                                      decoration: const InputDecoration(
                                        isDense: true,
                                        contentPadding: EdgeInsets.symmetric(
                                          horizontal: 4,
                                          vertical: 4,
                                        ),
                                        border: OutlineInputBorder(),
                                      ),
                                      onSubmitted: (_) => _applyTopoWindow(),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                InkWell(
                                  onTap: _applyTopoWindow,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF1E293B),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: const Text(
                                      'Link',
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  List<double> _computeTopoValues(
    InteractiveErpSession s,
    List<int> trials,
  ) {
    final pts = s.points;
    final tminMs = (s.epochs.epochTmin ?? -0.2) * 1000.0;
    final dtMs = 1000.0 / s.epochs.sampleRate;
    final winSamples = <int>[
      for (var k = 0; k < pts; k++)
        if (tminMs + k * dtMs >= widget.windowStartMs &&
            tminMs + k * dtMs <= widget.windowEndMs)
          k,
    ];
    final activeSamples = winSamples.isEmpty
        ? List<int>.generate(pts, (i) => i)
        : winSamples;
    final included = trials.where((t) => !s.rejected.contains(t)).toList();
    final activeTrials = included.isEmpty ? trials : included;
    if (activeTrials.isEmpty) {
      return List<double>.filled(s.epochs.labels.length, 0.0);
    }
    return [
      for (var ch = 0; ch < s.epochs.labels.length; ch++)
        () {
          var sum = 0.0;
          for (final t in activeTrials) {
            for (final k in activeSamples) {
              sum += s.trialSample(t, ch, k);
            }
          }
          return sum / (activeTrials.length * activeSamples.length);
        }(),
    ];
  }

  Widget _legendChip(String text, Color color) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      const SizedBox(width: 4),
      Text(text, style: const TextStyle(fontSize: 10, color: Colors.white70)),
    ],
  );
}

class _ErpImagePainter extends CustomPainter {
  _ErpImagePainter({
    required this.session,
    required this.channelIndex,
    required this.sortedTrials,
    required this.sort,
    required this.revision,
    required this.hoverPos,
    required this.windowStartMs,
    required this.windowEndMs,
    this.smoothTrials = 5,
    this.activeTrialIndex,
  });

  final InteractiveErpSession session;
  final int channelIndex;
  final List<int> sortedTrials;
  final ErpImageSort sort;
  final int revision;
  final Offset? hoverPos;
  final double windowStartMs;
  final double windowEndMs;
  final int smoothTrials;
  final int? activeTrialIndex;

  @override
  void paint(Canvas canvas, Size size) {
    final box = Rect.fromLTRB(
      56,
      14,
      math.max(96, size.width - 52),
      math.max(40, size.height - 28),
    );
    canvas.drawRect(box, Paint()..color = const Color(0xFFF8FAFC));

    final nRows = sortedTrials.length;
    final pts = session.points;
    if (nRows == 0 || pts <= 1) return;

    // Robust amplitude scale from the active trials so low- or high-µV channels stay legible
    final mags = <double>[];
    final stepR = math.max(1, (nRows / 24).floor());
    final stepC = math.max(1, (pts / 32).floor());
    for (var r = 0; r < nRows; r += stepR) {
      final tIdx = sortedTrials[r];
      for (var c = 0; c < pts; c += stepC) {
        final v = session.trialSample(tIdx, channelIndex, c).abs();
        if (v.isFinite) mags.add(v);
      }
    }
    mags.sort();
    final p95 = mags.isNotEmpty ? mags[(mags.length * 0.95).floor().clamp(0, mags.length - 1)] : 10.0;
    final maxV = math.max(2.0, math.max(p95, session.displayLimit(channelIndex) * 1.5));
    final rowH = box.height / nRows;
    // Downsample columns to <= 160 for fast 60fps painting
    final colStep = math.max(1, (pts / 160).floor());
    final cols = <int>[for (var k = 0; k < pts; k += colStep) k];
    final colW = box.width / cols.length;

    const condColors = [
      Color(0xFF38BDF8),
      Color(0xFFF87171),
      Color(0xFF34D399),
      Color(0xFFFBBF24),
    ];
    final condColorMap = {
      for (var i = 0; i < session.conditions.length; i++)
        session.conditions[i]: condColors[i % condColors.length],
    };

    String? prevCond;
    for (var r = 0; r < nRows; r++) {
      final trialIdx = sortedTrials[r];
      final condLabel = session.condition(trialIdx);
      final rejected = session.rejected.contains(trialIdx);
      final y = box.top + r * rowH;

      // Condition color strip + left gutter status bar
      final condColor = condColorMap[condLabel] ?? const Color(0xFF94A3B8);
      canvas.drawRect(
        Rect.fromLTWH(box.left - 13, y, 4, math.max(1.0, rowH)),
        Paint()..color = condColor,
      );
      canvas.drawRect(
        Rect.fromLTWH(box.left - 8, y, 5, math.max(1.0, rowH)),
        Paint()
          ..color = rejected
              ? const Color(0xFFEF4444)
              : const Color(0xFF22C55E).withValues(alpha: 0.45),
      );

      final effSmooth = nRows >= 6 ? smoothTrials.clamp(1, nRows) : 1;
      final halfW = effSmooth ~/ 2;
      for (var c = 0; c < cols.length; c++) {
        double v;
        if (effSmooth <= 1 || rejected) {
          v = session.trialSample(trialIdx, channelIndex, cols[c]);
        } else {
          var sum = 0.0;
          var cnt = 0;
          final rLo = math.max(0, r - halfW);
          final rHi = math.min(nRows - 1, r + halfW);
          for (var rr = rLo; rr <= rHi; rr++) {
            final tN = sortedTrials[rr];
            if (!session.rejected.contains(tN) &&
                session.condition(tN) == condLabel) {
              sum += session.trialSample(tN, channelIndex, cols[c]);
              cnt++;
            }
          }
          v = cnt > 0
              ? sum / cnt
              : session.trialSample(trialIdx, channelIndex, cols[c]);
        }
        final norm = (v / maxV).clamp(-1.0, 1.0);
        Color cellColor;
        if (norm >= 0) {
          cellColor = norm < 0.5
              ? Color.lerp(const Color(0xFFF8FAFC), const Color(0xFFF97316), norm * 2)!
              : Color.lerp(const Color(0xFFF97316), const Color(0xFF991B1B), (norm - 0.5) * 2)!;
        } else {
          final a = -norm;
          cellColor = a < 0.5
              ? Color.lerp(const Color(0xFFF8FAFC), const Color(0xFF3B82F6), a * 2)!
              : Color.lerp(const Color(0xFF3B82F6), const Color(0xFF1E3A8A), (a - 0.5) * 2)!;
        }
        if (rejected) {
          cellColor = Color.lerp(cellColor, const Color(0xFF0F172A), 0.78)!;
        }
        canvas.drawRect(
          Rect.fromLTWH(
            box.left + c * colW,
            y,
            colW + 0.6,
            math.max(1.0, rowH + 0.5),
          ),
          Paint()..color = cellColor,
        );
      }
      if (prevCond != condLabel) {
        if (prevCond != null) {
          canvas.drawLine(
            Offset(box.left - 13, y),
            Offset(box.right, y),
            Paint()
              ..color = Colors.white
              ..strokeWidth = 1.8,
          );
        }
        final tp = TextPainter(
          text: TextSpan(
            text: ' $condLabel ',
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.bold,
              color: Colors.white,
              backgroundColor: const Color(0xCC0F172A),
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(box.left + 4, y + 2));
        prevCond = condLabel;
      }
      if (activeTrialIndex != null && trialIdx == activeTrialIndex) {
        canvas.drawRect(
          Rect.fromLTWH(box.left, y, box.width, math.max(2.0, rowH)),
          Paint()
            ..color = const Color(0xFFFACC15)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4,
        );
      }
    }

    // 0 ms vertical line + measurement/topo window highlight
    final tmin = session.epochs.epochTmin ?? -0.2;
    final dur = (pts - 1) / session.epochs.sampleRate;
    if (dur > 0) {
      final w0 = ((windowStartMs / 1000.0) - tmin) / dur;
      final w1 = ((windowEndMs / 1000.0) - tmin) / dur;
      final xW0 = (box.left + box.width * w0).clamp(box.left, box.right);
      final xW1 = (box.left + box.width * w1).clamp(box.left, box.right);
      if (xW1 > xW0) {
        canvas.drawRect(
          Rect.fromLTRB(xW0, box.top, xW1, box.bottom),
          Paint()..color = const Color(0xFFFACC15).withValues(alpha: 0.12),
        );
        final winEdge = Paint()
          ..color = const Color(0xFFFACC15).withValues(alpha: 0.55)
          ..strokeWidth = 1.0;
        canvas.drawLine(Offset(xW0, box.top), Offset(xW0, box.bottom), winEdge);
        canvas.drawLine(Offset(xW1, box.top), Offset(xW1, box.bottom), winEdge);
      }
    }
    if (tmin <= 0 && tmin + dur >= 0) {
      final x0 = box.left + box.width * (-tmin) / dur;
      canvas.drawLine(
        Offset(x0, box.top),
        Offset(x0, box.bottom),
        Paint()
          ..color = Colors.white70
          ..strokeWidth = 1.2,
      );
    }

    canvas.drawRect(
      box,
      Paint()
        ..color = Colors.white24
        ..style = PaintingStyle.stroke,
    );

    void drawText(String txt, Offset at, {Color color = Colors.white70}) {
      final tp = TextPainter(
        text: TextSpan(
          text: txt,
          style: TextStyle(color: color, fontSize: 10, fontFamily: 'DejaVuSans'),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, at);
    }

    // Y-axis epoch numbers (actual trial #)
    final tickCount = math.min(nRows, 6);
    if (tickCount == 1) {
      drawText('#${sortedTrials.first + 1}', Offset(6, box.top));
    } else {
      for (var i = 0; i < tickCount; i++) {
        final rIdx = ((nRows - 1) * i / (tickCount - 1)).round().clamp(0, nRows - 1);
        final yTick = box.top + rIdx * rowH;
        drawText(
          '#${sortedTrials[rIdx] + 1}',
          Offset(6, (yTick - 5).clamp(box.top, box.bottom - 12)),
        );
      }
    }
    // Right-side µV colorbar
    final cb = Rect.fromLTWH(box.right + 10, box.top, 10, box.height);
    for (var i = 0; i < 40; i++) {
      final frac = 1.0 - 2.0 * i / 39.0; // +1 at top, -1 at bottom
      final col = frac >= 0
          ? (frac < 0.5
              ? Color.lerp(const Color(0xFFF8FAFC), const Color(0xFFF97316), frac * 2)!
              : Color.lerp(const Color(0xFFF97316), const Color(0xFF991B1B), (frac - 0.5) * 2)!)
          : ((-frac) < 0.5
              ? Color.lerp(const Color(0xFFF8FAFC), const Color(0xFF3B82F6), (-frac) * 2)!
              : Color.lerp(const Color(0xFF3B82F6), const Color(0xFF1E3A8A), ((-frac) - 0.5) * 2)!);
      canvas.drawRect(
        Rect.fromLTWH(cb.left, cb.top + cb.height * i / 40, cb.width, cb.height / 40 + 0.5),
        Paint()..color = col,
      );
    }
    canvas.drawRect(cb, Paint()..color = Colors.white24..style = PaintingStyle.stroke);
    drawText('+${maxV.round()}', Offset(cb.right + 3, cb.top - 2));
    drawText('0 µV', Offset(cb.right + 3, cb.center.dy - 5));
    drawText('-${maxV.round()}', Offset(cb.right + 3, cb.bottom - 10));
    for (var i = 0; i <= 4; i++) {
      final ms = ((tmin + dur * i / 4) * 1000).round();
      drawText(
        '$ms ms',
        Offset(box.left + box.width * i / 4 - 14, box.bottom + 6),
      );
    }

    if (hoverPos != null && box.contains(hoverPos!)) {
      final r = ((hoverPos!.dy - box.top) / box.height * nRows)
          .floor()
          .clamp(0, nRows - 1);
      final c = ((hoverPos!.dx - box.left) / box.width * pts)
          .floor()
          .clamp(0, pts - 1);
      final trialIdx = sortedTrials[r];
      final v = session.trialSample(trialIdx, channelIndex, c);
      final ms = ((tmin + c / session.epochs.sampleRate) * 1000).round();
      final status = session.rejected.contains(trialIdx)
          ? 'EXCLUDED'
          : 'INCLUDED';
      final yRow = box.top + r * rowH;
      canvas.drawRect(
        Rect.fromLTWH(box.left, yRow, box.width, math.max(1.5, rowH)),
        Paint()
          ..color = Colors.amberAccent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0,
      );
      drawText(
        'Trial ${trialIdx + 1} (${session.condition(trialIdx)}) · $ms ms · ${v.toStringAsFixed(1)} µV · $status',
        Offset(box.left + 8, box.top + 4),
        color: Colors.amberAccent,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ErpImagePainter old) =>
      old.session != session ||
      old.channelIndex != channelIndex ||
      old.sort != sort ||
      old.smoothTrials != smoothTrials ||
      old.activeTrialIndex != activeTrialIndex ||
      old.windowStartMs != windowStartMs ||
      old.windowEndMs != windowEndMs ||
      old.sortedTrials.length != sortedTrials.length ||
      old.revision != revision ||
      old.hoverPos != hoverPos;
}

enum GroupErpImageSort { byGroupAndPeak, bySubject, byPeakAmplitude, byMeanAmplitude }

/// Group-level Participant x Time ERPimage panel for inspecting all participants
/// side-by-side at a chosen condition and channel/ROI, with row click to jump to subject.
class GroupErpImagePanel extends StatefulWidget {
  const GroupErpImagePanel({
    super.key,
    required this.files,
    required this.participantGroups,
    required this.conditions,
    required this.labels,
    this.selectedChannel = 'ROI',
    this.onChannelChanged,
    this.windowStartMs = 300.0,
    this.windowEndMs = 600.0,
    this.onSelectFile,
  });

  final List<Map<String, dynamic>> files;
  final Map<String, String> participantGroups;
  final List<String> conditions;
  final List<String> labels;
  final String selectedChannel;
  final ValueChanged<String>? onChannelChanged;
  final double windowStartMs;
  final double windowEndMs;
  final ValueChanged<String>? onSelectFile;

  @override
  State<GroupErpImagePanel> createState() => _GroupErpImagePanelState();
}

class _GroupErpImagePanelState extends State<GroupErpImagePanel> {
  String? _condition;
  String? _groupFilter;
  late String _channel;
  GroupErpImageSort _sort = GroupErpImageSort.byGroupAndPeak;
  Offset? _hoverPos;

  @override
  void initState() {
    super.initState();
    _channel = widget.selectedChannel;
    if (widget.conditions.isNotEmpty) {
      _condition = widget.conditions.first;
    }
  }

  @override
  void didUpdateWidget(covariant GroupErpImagePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedChannel != widget.selectedChannel) {
      _channel = widget.selectedChannel;
    }
    if ((_condition == null || !widget.conditions.contains(_condition)) &&
        widget.conditions.isNotEmpty) {
      _condition = widget.conditions.first;
    }
  }

  List<({String subject, String group, String path, List<double> wave, double score})>
  _buildParticipantRows() {
    if (widget.files.isEmpty) return const [];
    final firstTimes = erpNumbers(widget.files.first['times']);
    final timesMs = [for (final s in firstTimes) s * 1000.0];
    final cond = _condition ??
        (widget.conditions.isNotEmpty ? widget.conditions.first : 'A');

    // Group files by subject for equal participant weighting
    final bySubj = <String, List<Map<String, dynamic>>>{};
    for (final f in widget.files) {
      final subj = '${f['subject'] ?? f['path'] ?? ''}'.trim();
      final grp =
          (widget.participantGroups[subj] ?? '${f['group'] ?? ''}').trim();
      final effGrp = grp.isEmpty ? 'Unknown' : grp;
      if (_groupFilter != null && effGrp != _groupFilter) continue;
      bySubj.putIfAbsent(subj, () => []).add(f);
    }

    final rows =
        <({String subject, String group, String path, List<double> wave, double score})>[];
    for (final entry in bySubj.entries) {
      final sFiles = entry.value;
      final subj = entry.key;
      final grp =
          (widget.participantGroups[subj] ?? '${sFiles.first['group'] ?? ''}')
              .trim();
      final effGrp = grp.isEmpty ? 'Unknown' : grp;

      final waves = <List<double>>[];
      for (final f in sFiles) {
        if (_channel == 'ROI') {
          final cw = f['condition_waves'] as Map?;
          final w = cw?[cond] != null
              ? erpNumbers(cw![cond])
              : erpNumbers(f['b'] ?? f['a']);
          if (w.length == timesMs.length) waves.add(w);
        } else {
          final labels = (f['labels'] as List? ?? []).map((e) => '$e').toList();
          final chIdx = labels.indexWhere(
            (l) => l.toUpperCase() == _channel.toUpperCase(),
          );
          final chans = f['channel_conditions'] as Map?;
          final chRows = chans?[cond] as List?;
          if (chIdx >= 0 && chRows != null && chIdx < chRows.length) {
            final w = erpNumbers(chRows[chIdx]);
            if (w.length == timesMs.length) waves.add(w);
          }
        }
      }
      if (waves.isEmpty) continue;
      final nT = timesMs.length;
      final avg = List<double>.generate(nT, (t) {
        var s = 0.0;
        for (final w in waves) {
          s += w[t];
        }
        return s / waves.length;
      });

      var meanWin = 0.0;
      var peakWin = 0.0;
      var cnt = 0;
      for (var t = 0; t < nT; t++) {
        if (timesMs[t] >= widget.windowStartMs &&
            timesMs[t] <= widget.windowEndMs) {
          meanWin += avg[t];
          if (avg[t].abs() > peakWin) peakWin = avg[t].abs();
          cnt++;
        }
      }
      final score = _sort == GroupErpImageSort.byMeanAmplitude
          ? (cnt > 0 ? meanWin / cnt : 0.0)
          : peakWin;
      rows.add((
        subject: subj,
        group: effGrp,
        path: '${sFiles.first['path'] ?? ''}',
        wave: avg,
        score: score,
      ));
    }

    rows.sort((a, b) {
      switch (_sort) {
        case GroupErpImageSort.byGroupAndPeak:
          final gc = a.group.compareTo(b.group);
          return gc != 0 ? gc : b.score.compareTo(a.score);
        case GroupErpImageSort.bySubject:
          return a.subject.compareTo(b.subject);
        case GroupErpImageSort.byPeakAmplitude:
        case GroupErpImageSort.byMeanAmplitude:
          return b.score.compareTo(a.score);
      }
    });
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.files.isEmpty) {
      return const Center(
        child: Text('Run or load ERP results to view Group ERPimage.'),
      );
    }
    final timesMs = [
      for (final s in erpNumbers(widget.files.first['times'])) s * 1000.0,
    ];
    final availableGroups = widget.files
        .map((f) {
          final subj = '${f['subject'] ?? ''}';
          final g =
              (widget.participantGroups[subj] ?? '${f['group'] ?? ''}').trim();
          return g.isEmpty ? 'Unknown' : g;
        })
        .toSet()
        .toList()
      ..sort();
    final rows = _buildParticipantRows();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                'Group ERPimage (${rows.length} participants · $_channel · ${_condition ?? ""})',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 12.5,
                ),
              ),
              if (widget.conditions.isNotEmpty)
                DropdownButton<String>(
                  value: widget.conditions.contains(_condition)
                      ? _condition
                      : widget.conditions.first,
                  isDense: true,
                  underline: const SizedBox.shrink(),
                  items: [
                    for (final c in widget.conditions)
                      DropdownMenuItem(
                        value: c,
                        child: Text('Cond: $c', style: const TextStyle(fontSize: 12)),
                      ),
                  ],
                  onChanged: (v) => setState(() => _condition = v),
                ),
              DropdownButton<String>(
                value: (_channel == 'ROI' || widget.labels.contains(_channel))
                    ? _channel
                    : 'ROI',
                isDense: true,
                underline: const SizedBox.shrink(),
                items: [
                  const DropdownMenuItem(
                    value: 'ROI',
                    child: Text('Channel: Task ROI', style: TextStyle(fontSize: 12)),
                  ),
                  for (final ch in widget.labels)
                    DropdownMenuItem(
                      value: ch,
                      child: Text('Ch: $ch', style: const TextStyle(fontSize: 12)),
                    ),
                ],
                onChanged: (v) {
                  if (v != null) {
                    setState(() => _channel = v);
                    widget.onChannelChanged?.call(v);
                  }
                },
              ),
              if (availableGroups.length > 1)
                DropdownButton<String?>(
                  value: _groupFilter,
                  isDense: true,
                  underline: const SizedBox.shrink(),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('Group: All', style: TextStyle(fontSize: 12)),
                    ),
                    for (final g in availableGroups)
                      DropdownMenuItem<String?>(
                        value: g,
                        child: Text('Group: $g', style: TextStyle(fontSize: 12)),
                      ),
                  ],
                  onChanged: (v) => setState(() => _groupFilter = v),
                ),
              DropdownButton<GroupErpImageSort>(
                value: _sort,
                isDense: true,
                underline: const SizedBox.shrink(),
                items: const [
                  DropdownMenuItem(
                    value: GroupErpImageSort.byGroupAndPeak,
                    child: Text('Sort: Group + Peak', style: TextStyle(fontSize: 12)),
                  ),
                  DropdownMenuItem(
                    value: GroupErpImageSort.byMeanAmplitude,
                    child: Text('Sort: Window Mean', style: TextStyle(fontSize: 12)),
                  ),
                  DropdownMenuItem(
                    value: GroupErpImageSort.byPeakAmplitude,
                    child: Text('Sort: Window Peak', style: TextStyle(fontSize: 12)),
                  ),
                  DropdownMenuItem(
                    value: GroupErpImageSort.bySubject,
                    child: Text('Sort: Subject ID', style: TextStyle(fontSize: 12)),
                  ),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _sort = v);
                },
              ),
            ],
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            'Hover any participant row to inspect voltage; click a row to open that recording in detail view.',
            style: TextStyle(fontSize: 11, color: Colors.white60),
          ),
        ),
        const SizedBox(height: 6),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: LayoutBuilder(
              builder: (context, constraints) {
                return MouseRegion(
                  onHover: (ev) => setState(() => _hoverPos = ev.localPosition),
                  onExit: (_) => setState(() => _hoverPos = null),
                  child: GestureDetector(
                    onTapUp: (ev) {
                      if (rows.isEmpty || widget.onSelectFile == null) return;
                      const topPad = 14.0;
                      const bottomPad = 28.0;
                      final plotH = math.max(
                        1.0,
                        constraints.maxHeight - topPad - bottomPad,
                      );
                      final y = ev.localPosition.dy;
                      if (y >= topPad && y <= topPad + plotH) {
                        final r = ((y - topPad) / plotH * rows.length)
                            .floor()
                            .clamp(0, rows.length - 1);
                        if (rows[r].path.isNotEmpty) {
                          widget.onSelectFile!(rows[r].path);
                        }
                      }
                    },
                    child: CustomPaint(
                      size: Size(constraints.maxWidth, constraints.maxHeight),
                      painter: _GroupErpImagePainter(
                        rows: rows,
                        timesMs: timesMs,
                        winStartMs: widget.windowStartMs,
                        winEndMs: widget.windowEndMs,
                        hoverPos: _hoverPos,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

class _GroupErpImagePainter extends CustomPainter {
  const _GroupErpImagePainter({
    required this.rows,
    required this.timesMs,
    required this.winStartMs,
    required this.winEndMs,
    required this.hoverPos,
  });

  final List<({String subject, String group, String path, List<double> wave, double score})>
  rows;
  final List<double> timesMs;
  final double winStartMs;
  final double winEndMs;
  final Offset? hoverPos;

  static const _grpPalette = [
    Color(0xFF0072B2),
    Color(0xFFD55E00),
    Color(0xFF009E73),
    Color(0xFFCC79A7),
    Color(0xFFE69F00),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (rows.isEmpty || timesMs.isEmpty) return;
    const leftPad = 92.0;
    const rightPad = 54.0;
    const topPad = 14.0;
    const bottomPad = 28.0;
    final box = Rect.fromLTWH(
      leftPad,
      topPad,
      math.max(1.0, size.width - leftPad - rightPad),
      math.max(1.0, size.height - topPad - bottomPad),
    );

    var maxV = 1.0;
    for (final r in rows) {
      for (final v in r.wave) {
        if (v.isFinite && v.abs() > maxV) maxV = v.abs();
      }
    }
    maxV = math.min(maxV, 25.0);

    final distinctGroups = rows.map((r) => r.group).toSet().toList()..sort();
    final grpIndex = {for (var i = 0; i < distinctGroups.length; i++) distinctGroups[i]: i};

    final nRows = rows.length;
    final nT = timesMs.length;
    final rowH = box.height / nRows;
    final colStep = math.max(1, (nT / 180).ceil());
    final nCols = (nT / colStep).ceil();
    final colW = box.width / nCols;

    for (var r = 0; r < nRows; r++) {
      final y0 = box.top + r * rowH;
      final gi = grpIndex[rows[r].group] ?? 0;
      canvas.drawRect(
        Rect.fromLTWH(leftPad - 10, y0, 7, rowH + 0.4),
        Paint()..color = _grpPalette[gi % _grpPalette.length],
      );
      final w = rows[r].wave;
      for (var c = 0; c < nCols; c++) {
        final tIdx = c * colStep;
        final val = (w[tIdx] / maxV).clamp(-1.0, 1.0);
        final col = val >= 0
            ? (val < 0.5
                ? Color.lerp(const Color(0xFFF8FAFC), const Color(0xFFF97316), val * 2)!
                : Color.lerp(const Color(0xFFF97316), const Color(0xFF991B1B), (val - 0.5) * 2)!)
            : ((-val) < 0.5
                ? Color.lerp(const Color(0xFFF8FAFC), const Color(0xFF3B82F6), (-val) * 2)!
                : Color.lerp(const Color(0xFF3B82F6), const Color(0xFF1E3A8A), ((-val) - 0.5) * 2)!);
        canvas.drawRect(
          Rect.fromLTWH(box.left + c * colW, y0, colW + 0.6, rowH + 0.6),
          Paint()..color = col,
        );
      }
    }

    // Window guides + 0 ms line
    final tMin = timesMs.first;
    final tSpan = math.max(1e-6, timesMs.last - tMin);
    double xAt(double ms) => box.left + ((ms - tMin) / tSpan).clamp(0.0, 1.0) * box.width;
    if (0 >= tMin && 0 <= timesMs.last) {
      canvas.drawLine(
        Offset(xAt(0), box.top),
        Offset(xAt(0), box.bottom),
        Paint()..color = Colors.black54..strokeWidth = 1.2,
      );
    }
    if (winEndMs > winStartMs) {
      final p = Paint()..color = Colors.amberAccent.withValues(alpha: 0.75)..strokeWidth = 1.2;
      canvas.drawLine(Offset(xAt(winStartMs), box.top), Offset(xAt(winStartMs), box.bottom), p);
      canvas.drawLine(Offset(xAt(winEndMs), box.top), Offset(xAt(winEndMs), box.bottom), p);
    }

    canvas.drawRect(
      box,
      Paint()
        ..color = Colors.white24
        ..style = PaintingStyle.stroke,
    );

    void drawTxt(String s, Offset at, {Color color = Colors.white70}) {
      final tp = TextPainter(
        text: TextSpan(
          text: s,
          style: TextStyle(color: color, fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, at);
    }

    // Subject/Group row labels
    final stepRow = math.max(1, (nRows / 12).ceil());
    for (var r = 0; r < nRows; r += stepRow) {
      final y = box.top + r * rowH;
      drawTxt(
        '${rows[r].subject} (${rows[r].group})',
        Offset(2, (y - 2).clamp(box.top, box.bottom - 12)),
      );
    }

    // Colorbar
    final cb = Rect.fromLTWH(box.right + 10, box.top, 10, box.height);
    for (var i = 0; i < 32; i++) {
      final f = 1.0 - 2.0 * i / 31.0;
      final col = f >= 0
          ? Color.lerp(const Color(0xFFF8FAFC), const Color(0xFF991B1B), f)!
          : Color.lerp(const Color(0xFFF8FAFC), const Color(0xFF1E3A8A), -f)!;
      canvas.drawRect(
        Rect.fromLTWH(cb.left, cb.top + cb.height * i / 32, cb.width, cb.height / 32 + 0.5),
        Paint()..color = col,
      );
    }
    drawTxt('+${maxV.toStringAsFixed(0)}µV', Offset(cb.right + 3, cb.top - 2));
    drawTxt('-${maxV.toStringAsFixed(0)}µV', Offset(cb.right + 3, cb.bottom - 10));

    for (var i = 0; i <= 4; i++) {
      final ms = (tMin + tSpan * i / 4).round();
      drawTxt('$ms ms', Offset(box.left + box.width * i / 4 - 14, box.bottom + 6));
    }

    if (hoverPos != null && box.contains(hoverPos!)) {
      final r = ((hoverPos!.dy - box.top) / box.height * nRows)
          .floor()
          .clamp(0, nRows - 1);
      final c = ((hoverPos!.dx - box.left) / box.width * nT)
          .floor()
          .clamp(0, nT - 1);
      final row = rows[r];
      drawTxt(
        '${row.subject} (${row.group}) · ${timesMs[c].round()} ms · ${row.wave[c].toStringAsFixed(2)} µV  [Click to inspect]',
        Offset(box.left + 8, box.top + 4),
        color: Colors.amberAccent,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _GroupErpImagePainter old) => true;
}
