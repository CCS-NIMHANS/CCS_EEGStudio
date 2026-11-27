import 'dart:math' as math;
import 'package:flutter/material.dart';

import 'connectivity_data.dart';

const List<Color> kCommunityColors = [
  Color(0xFF3B82F6),
  Color(0xFFF59E0B),
  Color(0xFF22C55E),
  Color(0xFFEF4444),
  Color(0xFFA855F7),
  Color(0xFF06B6D4),
  Color(0xFFEC4899),
  Color(0xFF84CC16),
  Color(0xFFF97316),
  Color(0xFF14B8A6),
];

Color communityColor(int c) => kCommunityColors[c.abs() % kCommunityColors.length];

const List<Color> _viridis = [
  Color(0xFF440154),
  Color(0xFF3B528B),
  Color(0xFF21908C),
  Color(0xFF5DC863),
  Color(0xFFFDE725),
];

Color viridis(double t) {
  final x = t.isNaN ? 0.0 : t.clamp(0.0, 1.0) * (_viridis.length - 1);
  final i = math.min(x.floor(), _viridis.length - 2);
  return Color.lerp(_viridis[i], _viridis[i + 1], x - i)!;
}

/// Diverging blue–white–red for t in [-1, 1].
Color diverging(double t) {
  final x = t.isNaN ? 0.0 : t.clamp(-1.0, 1.0);
  return x >= 0
      ? Color.lerp(const Color(0xFFF1F5F9), const Color(0xFFEF4444), x)!
      : Color.lerp(const Color(0xFFF1F5F9), const Color(0xFF3B82F6), -x)!;
}

/// Node order: grouped by community (largest first) when available, otherwise as given.
List<int> communityOrder(ConnNetwork net) {
  final comm = net.communities;
  final idx = List<int>.generate(net.labels.length, (i) => i);
  if (comm != null) {
    idx.sort((a, b) => comm[a] != comm[b] ? comm[a].compareTo(comm[b]) : a.compareTo(b));
  }
  return idx;
}

TextPainter _text(String s, double size, Color color, {FontWeight? weight}) {
  final tp = TextPainter(
    text: TextSpan(text: s, style: TextStyle(fontSize: size, color: color, fontWeight: weight)),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  );
  tp.layout();
  return tp;
}

/// Edges kept for display: strongest `density` fraction (undirected: symmetric mean pairs).
List<(int, int, double)> topEdges(ConnNetwork net, double density) {
  final n = net.labels.length;
  final e = <(int, int, double)>[];
  for (var i = 0; i < n; i++) {
    for (var j = 0; j < n; j++) {
      if (i == j) continue;
      if (net.directed) {
        final v = net.matrix[i][j];
        if (!v.isNaN && v > 0) e.add((i, j, v));
      } else if (j < i) {
        final a = net.matrix[i][j], b = net.matrix[j][i];
        final v = a.isNaN ? b : (b.isNaN ? a : (a + b) / 2);
        if (!v.isNaN && v > 0) e.add((i, j, v));
      }
    }
  }
  e.sort((a, b) => b.$3.compareTo(a.$3));
  final total = net.directed ? n * (n - 1) : n * (n - 1) ~/ 2;
  return e.take(math.max(1, (total * density).round())).toList();
}

/// Channel x channel (or ROI x ROI) matrix, nodes grouped by Louvain community.
class ConnMatrixPainter extends CustomPainter {
  ConnMatrixPainter(this.net);
  final ConnNetwork net;

  @override
  void paint(Canvas canvas, Size size) {
    final order = communityOrder(net);
    final n = order.length;
    if (n == 0) return;
    final left = 64.0, top = 52.0, right = 56.0, bottom = 8.0;
    final side = math.min(size.width - left - right, size.height - top - bottom);
    if (side <= 10) return;
    final cell = side / n;
    var lo = double.infinity, hi = -double.infinity;
    for (final r in net.matrix) {
      for (final v in r) {
        if (v.isNaN) continue;
        lo = math.min(lo, v);
        hi = math.max(hi, v);
      }
    }
    if (!lo.isFinite || hi <= lo) {
      lo = 0;
      hi = 1;
    }
    for (var a = 0; a < n; a++) {
      for (var b = 0; b < n; b++) {
        final v = net.matrix[order[a]][order[b]];
        final color = a == b || v.isNaN ? const Color(0xFFE2E8F0) : viridis((v - lo) / (hi - lo));
        canvas.drawRect(Rect.fromLTWH(left + b * cell, top + a * cell, cell + .5, cell + .5), Paint()..color = color);
      }
    }
    // community blocks
    final comm = net.communities;
    if (comm != null) {
      var start = 0;
      for (var a = 1; a <= n; a++) {
        if (a == n || comm[order[a]] != comm[order[start]]) {
          canvas.drawRect(
            Rect.fromLTWH(left + start * cell, top + start * cell, (a - start) * cell, (a - start) * cell),
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2
              ..color = communityColor(comm[order[start]]),
          );
          start = a;
        }
      }
    }
    final fs = math.max(6.0, math.min(10.0, cell * .8));
    if (cell >= 6) {
      for (var a = 0; a < n; a++) {
        final color = comm == null ? const Color(0xFF1E293B) : communityColor(comm[order[a]]);
        final t = _text(net.labels[order[a]], fs, color);
        t.paint(canvas, Offset(left - t.width - 4, top + a * cell + (cell - t.height) / 2));
        canvas.save();
        canvas.translate(left + a * cell + (cell + t.height) / 2, top - 4);
        canvas.rotate(-math.pi / 2);
        t.paint(canvas, Offset.zero);
        canvas.restore();
      }
    }
    final head = _text(net.directed ? 'rows = source  →  columns = target' : 'symmetric (undirected)', 10, const Color(0xFF64748B));
    head.paint(canvas, Offset(left, 4));
    // colour bar
    final bx = left + side + 14;
    for (var i = 0; i < 100; i++) {
      canvas.drawRect(
        Rect.fromLTWH(bx, top + side * (1 - (i + 1) / 100), 10, side / 100 + .5),
        Paint()..color = viridis(i / 99),
      );
    }
    _text(hi.toStringAsFixed(2), 9, const Color(0xFF475569)).paint(canvas, Offset(bx + 13, top - 4));
    _text(lo.toStringAsFixed(2), 9, const Color(0xFF475569)).paint(canvas, Offset(bx + 13, top + side - 10));
  }

  @override
  bool shouldRepaint(covariant ConnMatrixPainter old) => old.net != net;
}

/// Node-link diagram. `positions` null -> circular layout (source / ROI level); otherwise scalp positions in [0,1]².
class ConnGraphPainter extends CustomPainter {
  ConnGraphPainter({
    required this.net,
    required this.positions,
    required this.density,
    required this.metric,
    required this.showLabels,
  });

  final ConnNetwork net;
  final List<Offset>? positions; // normalised scalp positions, one per label
  final double density;
  final String metric;
  final bool showLabels;

  @override
  void paint(Canvas canvas, Size size) {
    final n = net.labels.length;
    if (n == 0) return;
    final c = size.center(Offset.zero);
    final r = math.min(size.width, size.height) / 2 - 26;
    if (r <= 20) return;
    final nodes = List<Offset>.filled(n, c);
    if (positions == null) {
      final order = communityOrder(net);
      for (var k = 0; k < n; k++) {
        final a = -math.pi / 2 + 2 * math.pi * k / n;
        nodes[order[k]] = c + Offset(math.cos(a), math.sin(a)) * r;
      }
    } else {
      final head = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = const Color(0xFF94A3B8);
      canvas.drawCircle(c, r + 12, head);
      canvas.drawPath(
        Path()
          ..moveTo(c.dx - 14, c.dy - r - 11)
          ..lineTo(c.dx, c.dy - r - 26)
          ..lineTo(c.dx + 14, c.dy - r - 11),
        head,
      );
      for (var i = 0; i < n; i++) {
        final p = positions![i];
        nodes[i] = c + Offset((p.dx - .5) * 2 * r * .92, (p.dy - .5) * 2 * r * .92);
      }
    }
    final edges = topEdges(net, density);
    if (edges.isNotEmpty) {
      final hi = edges.first.$3, lo = edges.last.$3;
      final comm = net.communities;
      for (final (i, j, v) in edges.reversed) {
        final t = hi > lo ? (v - lo) / (hi - lo) : 1.0;
        final same = comm != null && comm[i] == comm[j];
        final color = (same ? communityColor(comm[i]) : const Color(0xFF94A3B8)).withValues(alpha: .18 + .6 * t);
        final paint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = .6 + 3 * t
          ..color = color;
        final a = nodes[i], b = nodes[j];
        final mid = Offset.lerp(a, b, .5)!;
        final toCenter = positions == null ? (c - mid) * .35 : Offset.zero;
        final perp = net.directed ? Offset(-(b - a).dy, (b - a).dx) * .12 : Offset.zero;
        final ctrl = mid + toCenter + perp;
        canvas.drawPath(Path()..moveTo(a.dx, a.dy)..quadraticBezierTo(ctrl.dx, ctrl.dy, b.dx, b.dy), paint);
        if (net.directed) {
          final tip = b;
          final dir = (b - ctrl);
          final len = dir.distance;
          if (len > 1) {
            final u = dir / len;
            final tail = tip - u * 11;
            final n1 = Offset(-u.dy, u.dx) * 4;
            canvas.drawPath(
              Path()..moveTo(tip.dx - u.dx * 7, tip.dy - u.dy * 7)..lineTo(tail.dx + n1.dx, tail.dy + n1.dy)..lineTo(tail.dx - n1.dx, tail.dy - n1.dy)..close(),
              Paint()..color = color.withValues(alpha: math.min(1, color.a + .25)),
            );
          }
        }
      }
    }
    // nodes
    final comm = net.communities;
    final values = metric == 'community' ? null : net.nodeMeasures[metric];
    var lo = double.infinity, hi = -double.infinity;
    if (values != null) {
      for (final v in values) {
        if (v.isNaN) continue;
        lo = math.min(lo, v);
        hi = math.max(hi, v);
      }
    }
    final strength = net.nodeMeasures['strength'] ?? net.nodeMeasures['out_strength'];
    var smax = 0.0;
    if (strength != null) {
      for (final v in strength) {
        if (!v.isNaN) smax = math.max(smax, v);
      }
    }
    for (var i = 0; i < n; i++) {
      Color color;
      if (values == null || !lo.isFinite) {
        color = comm == null ? const Color(0xFF60A5FA) : communityColor(comm[i]);
      } else if (metric == 'net_flow') {
        color = diverging(values[i]);
      } else {
        color = viridis(hi > lo ? (values[i] - lo) / (hi - lo) : .5);
      }
      final base = positions == null ? 5.0 : 6.5;
      final rad = strength != null && smax > 0 && !strength[i].isNaN ? base + 7 * (strength[i] / smax) : base + 2;
      canvas.drawCircle(nodes[i], rad, Paint()..color = color);
      canvas.drawCircle(
        nodes[i],
        rad,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = comm == null ? const Color(0xFF475569) : communityColor(comm[i]),
      );
      if (showLabels) {
        final t = _text(net.labels[i], 9, const Color(0xFF1E293B));
        Offset at = nodes[i] - Offset(t.width / 2, t.height / 2);
        if (positions == null) {
          final dir = nodes[i] - c;
          final u = dir.distance > 0 ? dir / dir.distance : const Offset(0, -1);
          at = nodes[i] + u * (rad + 4) - Offset(u.dx < 0 ? t.width : 0, t.height / 2);
        }
        t.paint(canvas, at);
      }
    }
    if (values != null && lo.isFinite) {
      final lt = _text('${kMeasureTitles[metric] ?? metric}: ${lo.toStringAsFixed(2)} – ${hi.toStringAsFixed(2)}', 10, const Color(0xFF475569));
      lt.paint(canvas, Offset(8, size.height - lt.height - 6));
    }
  }

  @override
  bool shouldRepaint(covariant ConnGraphPainter old) =>
      old.net != net || old.density != density || old.metric != metric || old.showLabels != showLabels || old.positions != positions;
}
