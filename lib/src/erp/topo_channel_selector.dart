import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../topostats/mne_constants.dart' show kStandard1020Topo;

/// Interactive 2D scalp topoplot for selecting one or multiple EEG electrodes.
class TopoChannelSelector extends StatefulWidget {
  const TopoChannelSelector({
    super.key,
    required this.availableChannels,
    required this.selectedChannels,
    this.onToggleChannel,
    this.onSelectChannel,
    this.multiSelect = true,
    this.channelValues = const {},
    this.size = 240,
    this.title,
  });

  final List<String> availableChannels;
  final Set<String> selectedChannels;
  final ValueChanged<String>? onToggleChannel;
  final ValueChanged<String>? onSelectChannel;
  final bool multiSelect;
  final Map<String, double> channelValues;
  final double size;
  final String? title;

  @override
  State<TopoChannelSelector> createState() => _TopoChannelSelectorState();
}

class _TopoChannelSelectorState extends State<TopoChannelSelector> {
  String? _hovered;

  static final Map<String, String> _upperToCanonical = {
    for (final k in kStandard1020Topo.keys) k.toUpperCase(): k,
  };

  List<({String label, Offset norm})> _mappedChannels() {
    final out = <({String label, Offset norm})>[];
    for (final ch in widget.availableChannels) {
      final canon = _upperToCanonical[ch.toUpperCase()];
      if (canon == null) continue;
      final pt = kStandard1020Topo[canon]!;
      out.add((label: ch, norm: Offset(pt[0] / 0.115, -pt[1] / 0.115)));
    }
    return out;
  }

  Offset _toCanvas(Offset norm, Size sz) {
    final cx = sz.width / 2;
    final cy = sz.height / 2 + 4;
    final r = math.min(sz.width, sz.height) * 0.38;
    return Offset(cx + norm.dx * r, cy + norm.dy * r);
  }

  String? _hitTest(Offset localPos, Size sz) {
    final mapped = _mappedChannels();
    String? best;
    var bestDist = 18.0;
    for (final item in mapped) {
      final pos = _toCanvas(item.norm, sz);
      final d = (pos - localPos).distance;
      if (d < bestDist) {
        bestDist = d;
        best = item.label;
      }
    }
    return best;
  }

  @override
  Widget build(BuildContext context) {
    final mapped = _mappedChannels();
    final selUpper = widget.selectedChannels.map((e) => e.toUpperCase()).toSet();
    final sz = Size(widget.size, widget.size);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.title != null) ...[
          Text(
            widget.title!,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
        ],
        MouseRegion(
          cursor: _hovered != null
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          onHover: (e) {
            final hit = _hitTest(e.localPosition, sz);
            if (hit != _hovered) setState(() => _hovered = hit);
          },
          onExit: (_) {
            if (_hovered != null) setState(() => _hovered = null);
          },
          child: GestureDetector(
            onTapDown: (e) {
              final hit = _hitTest(e.localPosition, sz);
              if (hit == null) return;
              if (widget.multiSelect) {
                widget.onToggleChannel?.call(hit);
              } else {
                widget.onSelectChannel?.call(hit);
              }
            },
            child: CustomPaint(
              size: sz,
              painter: _TopoSelectorPainter(
                channels: mapped,
                selectedUpper: selUpper,
                hovered: _hovered,
                values: widget.channelValues,
              ),
            ),
          ),
        ),
        Text(
          _hovered != null
              ? () {
                  final v = widget.channelValues[_hovered];
                  return v != null && v.isFinite
                      ? '$_hovered (${v.toStringAsFixed(2)} µV) · Click to ${widget.multiSelect ? "toggle" : "select"}'
                      : '$_hovered · Click to ${widget.multiSelect ? "toggle" : "select"}';
                }()
              : (widget.multiSelect
                  ? 'Click any electrode on scalp to toggle'
                  : 'Click any electrode on scalp to select'),
          style: const TextStyle(fontSize: 10.5, color: Color(0xFF64748B)),
        ),
      ],
    );
  }
}

class _TopoSelectorPainter extends CustomPainter {
  _TopoSelectorPainter({
    required this.channels,
    required this.selectedUpper,
    required this.hovered,
    required this.values,
  });

  final List<({String label, Offset norm})> channels;
  final Set<String> selectedUpper;
  final String? hovered;
  final Map<String, double> values;

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2 + 4;
    final r = math.min(size.width, size.height) * 0.38;

    // Head background
    canvas.drawCircle(
      Offset(cx, cy),
      r,
      Paint()..color = const Color(0xFFFFFFFF),
    );
    final outlinePaint = Paint()
      ..color = const Color(0xFF64748B)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;
    canvas.drawCircle(Offset(cx, cy), r, outlinePaint);

    // Nose
    final nose = Path()
      ..moveTo(cx - r * 0.12, cy - r * 0.99)
      ..lineTo(cx, cy - r * 1.13)
      ..lineTo(cx + r * 0.12, cy - r * 0.99);
    canvas.drawPath(nose, outlinePaint);

    // Ears
    canvas.drawArc(
      Rect.fromCenter(center: Offset(cx - r * 1.01, cy), width: r * 0.14, height: r * 0.36),
      math.pi * 0.5,
      math.pi,
      false,
      outlinePaint,
    );
    canvas.drawArc(
      Rect.fromCenter(center: Offset(cx + r * 1.01, cy), width: r * 0.14, height: r * 0.36),
      -math.pi * 0.5,
      math.pi,
      false,
      outlinePaint,
    );

    double maxAbs = 0.0;
    for (final v in values.values) {
      if (v.isFinite) maxAbs = math.max(maxAbs, v.abs());
    }
    if (maxAbs <= 1e-6) maxAbs = 1.0;

    for (final item in channels) {
      final pos = Offset(cx + item.norm.dx * r, cy + item.norm.dy * r);
      final isSel = selectedUpper.contains(item.label.toUpperCase());
      final isHov = hovered?.toUpperCase() == item.label.toUpperCase();

      Color fill = const Color(0xFFE2E8F0);
      final val = values[item.label];
      if (val != null && val.isFinite) {
        final t = (val / maxAbs).clamp(-1.0, 1.0);
        if (t >= 0) {
          fill = Color.lerp(const Color(0xFFE2E8F0), const Color(0xFFEF4444), t)!;
        } else {
          fill = Color.lerp(const Color(0xFFE2E8F0), const Color(0xFF3B82F6), -t)!;
        }
      } else if (isSel) {
        fill = const Color(0xFF06B6D4);
      }

      final dotR = isSel ? 9.5 : (isHov ? 8.5 : 6.5);
      canvas.drawCircle(pos, dotR, Paint()..color = fill);
      if (isSel || isHov) {
        canvas.drawCircle(
          pos,
          dotR + 1.5,
          Paint()
            ..color = isSel ? const Color(0xFF0284C7) : const Color(0xFF475569)
            ..style = PaintingStyle.stroke
            ..strokeWidth = isSel ? 2.2 : 1.4,
        );
      } else {
        canvas.drawCircle(
          pos,
          dotR,
          Paint()
            ..color = const Color(0xFFCBD5E1)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.0,
        );
      }

      final tp = TextPainter(
        text: TextSpan(
          text: item.label,
          style: TextStyle(
            fontSize: isSel ? 8.5 : 7.5,
            fontWeight: isSel ? FontWeight.bold : FontWeight.w500,
            color: (val != null && val.abs() / maxAbs < 0.35)
                ? Colors.black87
                : const Color(0xFF1E293B),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, pos - Offset(tp.width / 2, tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant _TopoSelectorPainter old) =>
      old.selectedUpper != selectedUpper ||
      old.hovered != hovered ||
      old.channels.length != channels.length ||
      old.values != values;
}
