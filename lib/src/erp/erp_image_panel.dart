import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'interactive_erp_session.dart';

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
  });

  final InteractiveErpSession session;
  final int channelIndex;
  final List<int> trialIndices;
  final void Function(int trialIndex, bool reject) onToggleReject;
  final ValueChanged<int>? onInspectTrial;
  final double windowStartMs;
  final double windowEndMs;

  @override
  State<ErpImagePanel> createState() => _ErpImagePanelState();
}

class _ErpImagePanelState extends State<ErpImagePanel> {
  ErpImageSort _sort = ErpImageSort.chronological;
  bool _dragActionReject = true;
  int? _lastDraggedRow;
  Offset? _hoverPos;

  List<int> _sortedTrials() {
    final list = List<int>.from(widget.trialIndices);
    if (_sort == ErpImageSort.chronological || list.length <= 1) return list;
    final s = widget.session;
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

    double metric(int trialIdx) {
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

    final scores = {for (final idx in list) idx: metric(idx)};
    list.sort((a, b) => scores[b]!.compareTo(scores[a]!));
    return list;
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Wrap(
            spacing: 12,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                'ERPimage ($chName · ${sorted.length} trials)',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
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
              const Text(
                'Click or drag rows to exclude/include trials',
                style: TextStyle(fontSize: 11, color: Colors.white70),
              ),
              const Spacer(),
              _legendChip('Blue: −µV', const Color(0xFF3B82F6)),
              _legendChip('Red: +µV', const Color(0xFFEF4444)),
              _legendChip('Dim/Red bar: Excluded', const Color(0xFFDC2626)),
            ],
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: LayoutBuilder(
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
                        revision: s.revision,
                        hoverPos: _hoverPos,
                      ),
                      child: const SizedBox.expand(),
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
    required this.revision,
    required this.hoverPos,
  });

  final InteractiveErpSession session;
  final int channelIndex;
  final List<int> sortedTrials;
  final int revision;
  final Offset? hoverPos;

  @override
  void paint(Canvas canvas, Size size) {
    final box = Rect.fromLTRB(
      52,
      14,
      math.max(80, size.width - 14),
      math.max(40, size.height - 28),
    );
    canvas.drawRect(box, Paint()..color = const Color(0xFF0F172A));

    final nRows = sortedTrials.length;
    final pts = session.points;
    if (nRows == 0 || pts <= 1) return;

    final maxV = math.max(10.0, session.displayLimit(channelIndex) * 2.5);
    final rowH = box.height / nRows;
    // Downsample columns to <= 160 for fast 60fps painting
    final colStep = math.max(1, (pts / 160).floor());
    final cols = <int>[for (var k = 0; k < pts; k += colStep) k];
    final colW = box.width / cols.length;

    for (var r = 0; r < nRows; r++) {
      final trialIdx = sortedTrials[r];
      final rejected = session.rejected.contains(trialIdx);
      final y = box.top + r * rowH;

      // Left gutter status bar
      canvas.drawRect(
        Rect.fromLTWH(box.left - 8, y, 5, math.max(1.0, rowH)),
        Paint()
          ..color = rejected
              ? const Color(0xFFEF4444)
              : const Color(0xFF22C55E).withValues(alpha: 0.45),
      );

      for (var c = 0; c < cols.length; c++) {
        final v = session.trialSample(trialIdx, channelIndex, cols[c]);
        final norm = (v / maxV).clamp(-1.0, 1.0);
        Color cellColor;
        if (norm >= 0) {
          cellColor = Color.lerp(
            const Color(0xFF0F172A),
            const Color(0xFFEF4444),
            norm,
          )!;
        } else {
          cellColor = Color.lerp(
            const Color(0xFF0F172A),
            const Color(0xFF3B82F6),
            -norm,
          )!;
        }
        if (rejected) {
          cellColor = Color.lerp(cellColor, Colors.black, 0.72)!;
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
    }

    // 0 ms vertical line
    final tmin = session.epochs.epochTmin ?? -0.2;
    final dur = (pts - 1) / session.epochs.sampleRate;
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

    drawText('1', Offset(8, box.top));
    drawText('$nRows', Offset(8, box.bottom - 12));
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
      old.sortedTrials.length != sortedTrials.length ||
      old.revision != revision ||
      old.hoverPos != hoverPos;
}
