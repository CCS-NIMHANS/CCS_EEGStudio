import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/services.dart' show rootBundle;

import 'mpl_text.dart';

class GlassBrainRegion {
  const GlassBrainRegion({
    required this.name,
    required this.centers2d,
    required this.pos3d,
    required this.outlines,
  });

  final String name;
  final List<Offset> centers2d; // [Sagittal, Coronal, Axial]
  final List<double> pos3d; // [x, y, z]
  final List<List<List<Offset>>> outlines; // per view -> list of polylines
}

class GlassBrainAtlas {
  GlassBrainAtlas._(this.views, this.shells, this.regions)
      : byUpper = {for (final r in regions) r.name.toUpperCase(): r};

  static GlassBrainAtlas? _cached;
  static Future<GlassBrainAtlas>? _loading;

  static GlassBrainAtlas? get cached => _cached;

  static Future<GlassBrainAtlas> ensureLoaded() {
    if (_cached != null) return Future.value(_cached!);
    return _loading ??= _load();
  }

  static Future<GlassBrainAtlas> _load() async {
    final raw = await rootBundle.loadString('assets/source_review_geometry.json');
    final map = jsonDecode(raw) as Map<String, dynamic>;
    final views = (map['views'] as List).cast<String>();
    final shells = [
      for (final s in map['shells'] as List)
        [for (final pt in s as List) Offset((pt[0] as num).toDouble(), (pt[1] as num).toDouble())],
    ];
    final regions = <GlassBrainRegion>[];
    for (final r in (map['regions'] as List).cast<Map>()) {
      final centers = [
        for (final c in r['centers'] as List)
          Offset((c[0] as num).toDouble(), (c[1] as num).toDouble()),
      ];
      // centers[0] = Sagittal [-y, z], centers[1] = Coronal [x, z], centers[2] = Axial [x, y]
      final x = centers.length > 1 ? centers[1].dx : 0.0;
      final y = centers.length > 2 ? centers[2].dy : 0.0;
      final z = centers.isNotEmpty ? centers[0].dy : 0.0;
      final outlines = <List<List<Offset>>>[
        for (final v in r['outlines'] as List)
          [
            for (final poly in v as List)
              [
                for (final pt in poly as List)
                  Offset((pt[0] as num).toDouble(), (pt[1] as num).toDouble()),
              ],
          ],
      ];
      regions.add(
        GlassBrainRegion(
          name: r['name'] as String,
          centers2d: centers,
          pos3d: [x, y, z],
          outlines: outlines,
        ),
      );
    }
    _cached = GlassBrainAtlas._(views, shells, regions);
    return _cached!;
  }

  final List<String> views;
  final List<List<Offset>> shells;
  final List<GlassBrainRegion> regions;
  final Map<String, GlassBrainRegion> byUpper;

  /// Builds k-nearest-neighbor adjacency (k=6 within same hemisphere) for e-TFCE.
  List<List<int>> adjacencyFor(List<String> labels, {int k = 6}) {
    final n = labels.length;
    if (n <= 1) return List.generate(n, (_) => <int>[]);
    final coords = [for (final l in labels) byUpper[l.trim().toUpperCase()]?.pos3d];
    final adj = List.generate(n, (_) => <int>{});
    for (var i = 0; i < n; i++) {
      final ci = coords[i];
      final li = labels[i].toLowerCase();
      final hemiI = li.endsWith('-lh') ? 'lh' : (li.endsWith('-rh') ? 'rh' : '');
      final dists = <(int, double)>[];
      for (var j = 0; j < n; j++) {
        if (i == j) continue;
        final lj = labels[j].toLowerCase();
        final hemiJ = lj.endsWith('-lh') ? 'lh' : (lj.endsWith('-rh') ? 'rh' : '');
        if (hemiI.isNotEmpty && hemiJ.isNotEmpty && hemiI != hemiJ) continue;
        final cj = coords[j];
        final d = (ci != null && cj != null)
            ? math.sqrt(
                (ci[0] - cj[0]) * (ci[0] - cj[0]) +
                    (ci[1] - cj[1]) * (ci[1] - cj[1]) +
                    (ci[2] - cj[2]) * (ci[2] - cj[2]),
              )
            : (i - j).abs().toDouble();
        dists.add((j, d));
      }
      dists.sort((a, b) => a.$2.compareTo(b.$2));
      for (final (j, _) in dists.take(math.min(k, dists.length))) {
        adj[i].add(j);
        adj[j].add(i);
      }
    }
    return [for (final s in adj) s.toList()..sort()];
  }
}

/// Computes the 3 view sub-rectangles inside [cell] (Sagittal, Coronal, Axial).
List<Rect> glassBrainViewRects(Rect cell) {
  // Use 2+1 layout when cell is nearly square or tall, 3-across when wide.
  if (cell.width >= cell.height * 1.45) {
    final w = cell.width / 3;
    return [
      for (var v = 0; v < 3; v++)
        Rect.fromLTWH(cell.left + v * w, cell.top, w, cell.height),
    ];
  }
  final topH = cell.height * 0.50;
  final botH = cell.height * 0.50;
  final halfW = cell.width * 0.50;
  return [
    Rect.fromLTWH(cell.left, cell.top, halfW, topH), // Sagittal
    Rect.fromLTWH(cell.left + halfW, cell.top, halfW, topH), // Coronal
    Rect.fromLTWH(cell.left + cell.width * 0.25, cell.top + topH, halfW, botH), // Axial
  ];
}

Offset _projectGlassPoint(Offset p, Rect r) {
  final scale = math.min((r.width - 4) / 210.0, (r.height - 4) / 200.0);
  return Offset(r.center.dx + p.dx * scale, r.center.dy - p.dy * scale);
}

int? hitTestGlassBrainCell({
  required Offset pPx,
  required Rect cellPx,
  required List<String> labels,
}) {
  final atlas = GlassBrainAtlas.cached;
  if (atlas == null) return null;
  final rects = glassBrainViewRects(cellPx);
  int? best;
  var bestDist = double.infinity;
  for (var v = 0; v < 3; v++) {
    if (!rects[v].contains(pPx)) continue;
    for (var i = 0; i < labels.length; i++) {
      final reg = atlas.byUpper[labels[i].trim().toUpperCase()];
      if (reg == null || v >= reg.centers2d.length) continue;
      final pt = _projectGlassPoint(reg.centers2d[v], rects[v]);
      final d = (pt - pPx).distance;
      if (d < bestDist) {
        bestDist = d;
        best = i;
      }
    }
  }
  return best != null && bestDist < math.max(8.0, cellPx.width * 0.14) ? best : null;
}

Offset? glassBrainChannelPoint({
  required Rect cellPx,
  required String label,
  int view = 2,
}) {
  final atlas = GlassBrainAtlas.cached;
  if (atlas == null) return null;
  final reg = atlas.byUpper[label.trim().toUpperCase()];
  if (reg == null || view >= reg.centers2d.length) return null;
  final rects = glassBrainViewRects(cellPx);
  return _projectGlassPoint(reg.centers2d[view], rects[view]);
}

void paintGlassBrainCell(
  Canvas canvas,
  Rect cellPx, {
  required List<String> labels,
  required Float64List? values,
  required List<bool>? significant,
  required double vmax,
  required List<int> lut,
  required double pt,
  bool baseline = false,
}) {
  final atlas = GlassBrainAtlas.cached;
  if (atlas == null) {
    drawMplText(
      canvas,
      baseline ? 'baseline' : 'source',
      cellPx.center,
      6 * pt,
      ha: HAlign.center,
      va: VAlign.center,
    );
    return;
  }

  final rects = glassBrainViewRects(cellPx);
  final shellPaint = Paint()
    ..style = PaintingStyle.stroke
    ..color = baseline ? const Color(0xFF94A3B8) : const Color(0xFF475569)
    ..strokeWidth = math.max(0.6, 0.75 * pt);
  final outlinePaint = Paint()
    ..style = PaintingStyle.stroke
    ..color = const Color(0xFF94A3B8).withValues(alpha: baseline ? 0.16 : 0.22)
    ..strokeWidth = math.max(0.25, 0.3 * pt);

  final labelIndex = {
    for (var i = 0; i < labels.length; i++) labels[i].trim().toUpperCase(): i,
  };

  for (var v = 0; v < 3; v++) {
    final r = rects[v];
    if (v < atlas.shells.length && atlas.shells[v].isNotEmpty) {
      final path = Path();
      final shell = atlas.shells[v];
      for (var i = 0; i < shell.length; i++) {
        final p = _projectGlassPoint(shell[i], r);
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      canvas.drawPath(path, shellPaint);
    }

    if (baseline) continue;

    // Subtle anatomical region outlines
    for (final reg in atlas.regions) {
      if (v >= reg.outlines.length) continue;
      for (final poly in reg.outlines[v]) {
        if (poly.isEmpty) continue;
        final p = Path();
        for (var i = 0; i < poly.length; i++) {
          final ptPx = _projectGlassPoint(poly[i], r);
          if (i == 0) {
            p.moveTo(ptPx.dx, ptPx.dy);
          } else {
            p.lineTo(ptPx.dx, ptPx.dy);
          }
        }
        canvas.drawPath(p, outlinePaint);
      }
    }

    if (values == null) continue;
    final vmin = -vmax;
    final baseR = math.max(1.2, math.min(3.2, r.width * 0.042));
    for (final reg in atlas.regions) {
      final idx = labelIndex[reg.name.toUpperCase()];
      if (idx == null || idx >= values.length || v >= reg.centers2d.length) continue;
      final val = values[idx];
      if (!val.isFinite) continue;
      final norm = ((val - vmin) / (vmax - vmin)).clamp(0.0, 1.0);
      final lutIdx = (norm * 255).floor().clamp(0, 255);
      final color = Color(lut[lutIdx]);
      final frac = (val.abs() / math.max(vmax, 1e-6)).clamp(0.0, 1.0);
      final sig = significant != null && idx < significant.length && significant[idx];
      final center = _projectGlassPoint(reg.centers2d[v], r);
      final radius = baseR * (0.55 + 0.75 * frac);
      canvas.drawCircle(
        center,
        radius,
        Paint()..color = color.withValues(alpha: sig ? 0.96 : 0.72),
      );
      if (sig) {
        canvas.drawCircle(
          center,
          radius + 0.5 * pt,
          Paint()
            ..color = const Color(0xFF000000)
            ..style = PaintingStyle.stroke
            ..strokeWidth = math.max(0.5, 0.55 * pt),
        );
      }
    }
  }

  if (baseline) {
    drawMplText(
      canvas,
      'baseline',
      cellPx.center,
      5.5 * pt,
      ha: HAlign.center,
      va: VAlign.center,
      color: const Color(0xFF475569),
    );
  }
}
