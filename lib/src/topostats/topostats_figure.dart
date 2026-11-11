// lib/src/topostats/topostats_figure.dart
//
// Renders a TopoStatsResult exactly like PlotFeaturesTopoStats_20260801.py
// (matplotlib 3.10 + mne.viz.plot_topomap), resolution-independently:
// all geometry is computed in inches/points from the script's layout
// constants and painted at any pixels-per-inch -- 200 for the PNG export
// (the script's savefig dpi), the zoom level on screen.
//
// Row 1: one line-plot Axes per session (mean across channels, smoothed,
//        grey dispersion band, red markers, dashed representative channel,
//        dotted window boundaries).
// Row 2: one topomap per equal-length window, same column grid as row 1,
//        coloured by the e-TFCE statistic, BH-FDR-significant channels
//        ringed, 'baseline' placeholders, colourbar on the right.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'mne_constants.dart';
import 'mpl_colormaps.dart';
import 'mpl_text.dart';
import 'mpl_ticker.dart';
import 'topo_interp.dart';
import 'topostats_engine.dart';
import '../state_dynamics/state_dynamics_view.dart';

// matplotlib named colours used by the script
const Color _tabRed = Color(0xFFD62728);
const Color _steelBlue = Color(0xFF4682B4);
const Color _lightGray = Color(0xFFD3D3D3);
const Color _gray = Color(0xFF808080);
const Color _black = Color(0xFF000000);
const Color _baselineGray = Color(0xFFE5E5E5);

/// Layout constants of the script (inches).
class _K {
  static const lineAxesIn = 3.5;
  static const xlabelSpaceIn = 0.55;
  static const rowGapIn = 0.15;
  static const topMarginIn = 0.5;
  static const bottomMarginIn = 0.35;
  static const marginLIn = 0.75;
  static const marginRIn = 1.15;
}

/// Hover / hit information.
class TopoHit {
  TopoHit.line(this.session, this.sampleIndex, {this.stateLabel})
    : window = -1,
      channel = -1,
      isColorbar = false;
  TopoHit.topo(this.session, this.window, this.channel)
    : sampleIndex = -1,
      isColorbar = false,
      stateLabel = null;
  TopoHit.colorbar()
    : session = -1,
      window = -1,
      channel = -1,
      sampleIndex = -1,
      isColorbar = true,
      stateLabel = null;
  TopoHit.state(this.stateLabel, [this.session = -1])
    : window = -1,
      channel = -1,
      sampleIndex = -1,
      isColorbar = false;

  final int session;
  final int window;
  final int channel; // -1 => no channel under pointer
  final int sampleIndex;
  final bool isColorbar;
  final String? stateLabel;

  bool get isLine => sampleIndex >= 0;
  bool get isTopo => window >= 0;
  bool get isState => stateLabel != null && !isLine && !isTopo;

  @override
  bool operator ==(Object other) =>
      other is TopoHit &&
      other.session == session &&
      other.window == window &&
      other.channel == channel &&
      other.sampleIndex == sampleIndex &&
      other.isColorbar == isColorbar &&
      other.stateLabel == stateLabel;

  @override
  int get hashCode =>
      Object.hash(session, window, channel, sampleIndex, isColorbar, stateLabel);
}

class _TopoCellCache {
  _TopoCellCache(this.vertices, this.contours);
  final ui.Vertices? vertices;
  final Path? contours;
}

/// Precomputed, reusable figure (layout + interpolated topomaps).
class TopoFigure {
  TopoFigure(
    this.result, {
    this.stateDynamicsResult,
    this.selectedStateLabel,
  }) {
    final s = result.settings;
    interp = TopoInterpolator.forChannels(s.channels);
    _computeLayout();
    _lut = kMplColormaps[s.topoCmap] ?? kMplColormaps['RdBu_r']!;
    _buildTopoCaches();
  }

  final TopoStatsResult result;
  final StateDynamicsResult? stateDynamicsResult;
  final String? selectedStateLabel;
  late final TopoInterpolator interp;
  late final List<int> _lut;

  // ---- layout (inches, origin top-left) ---------------------------------
  late final double widthIn, heightIn;
  late final List<Rect> lineAxes; // per session
  late final List<Rect> stateStripAxes; // per session (when stateDynamicsResult != null)
  late final List<Rect> rasterAxes; // per session (when stateDynamicsResult != null)
  late final List<List<Rect>> topoCells; // per session per column
  late final List<Rect> sessionSpan; // topo block span per session (cells)
  late final Rect colorbarAxes;
  late final double topoRowTopIn, topoRowBottomIn;
  late final ({double x0, double x1, double y0, double y1}) topoLim;
  late final List<List<Float64List?>> zGrids;
  late final List<List<_TopoCellCache?>> _cells;

  double get vmax => result.vmax;

  void _computeLayout() {
    final s = result.settings;
    final sessions = result.sessions;
    final nSeg = sessions.length;
    final ratios = <double>[];
    final ranges = <(int, int)>[];
    for (var i = 0; i < nSeg; i++) {
      if (i > 0) ratios.add(s.sessionGapFrac);
      final start = ratios.length;
      final n = math.max(sessions[i].windows.length, 1);
      for (var k = 0; k < n; k++) {
        ratios.add(1.0);
      }
      ranges.add((start, ratios.length));
    }
    final totalUnits = ratios.fold<double>(0, (a, b) => a + b);
    widthIn = math.max(totalUnits * s.targetTopoWidthIn, 6.0);
    final topoRowIn = s.targetTopoWidthIn + 0.35;
    final hasDynamics = stateDynamicsResult != null;
    final stateStripIn = hasDynamics ? 0.28 : 0.0;
    final rasterIn = hasDynamics ? 0.34 : 0.0;
    final dynamicsGapIn = hasDynamics ? 0.08 : 0.0;

    heightIn =
        _K.topMarginIn +
        _K.lineAxesIn +
        _K.xlabelSpaceIn +
        stateStripIn +
        rasterIn +
        dynamicsGapIn +
        _K.rowGapIn +
        topoRowIn +
        _K.bottomMarginIn;

    final fw = widthIn;
    final leftFrac = _K.marginLIn / fw, rightFrac = 1 - _K.marginRIn / fw;

    // GridSpec(width_ratios, wspace=0) column edges, figure fraction.
    final lefts = <double>[], rights = <double>[];
    var cur = leftFrac;
    final tot = rightFrac - leftFrac;
    for (final r in ratios) {
      final w = tot * r / totalUnits;
      lefts.add(cur);
      rights.add(cur + w);
      cur += w;
    }

    final lineTopIn = _K.topMarginIn;
    final lineBottomIn = lineTopIn + _K.lineAxesIn;
    final stateStripTopIn = lineBottomIn + _K.xlabelSpaceIn;
    final stateStripBottomIn = stateStripTopIn + stateStripIn;
    final rasterTopIn = stateStripBottomIn + 0.03;
    final rasterBottomIn = rasterTopIn + rasterIn;
    topoRowTopIn = hasDynamics
        ? (rasterBottomIn + dynamicsGapIn + _K.rowGapIn)
        : (lineBottomIn + _K.xlabelSpaceIn + _K.rowGapIn);
    topoRowBottomIn = topoRowTopIn + topoRowIn;

    lineAxes = [
      for (final (a, b) in ranges)
        Rect.fromLTRB(
          lefts[a] * fw,
          lineTopIn,
          rights[b - 1] * fw,
          lineBottomIn,
        ),
    ];
    stateStripAxes = hasDynamics
        ? [
            for (final (a, b) in ranges)
              Rect.fromLTRB(
                lefts[a] * fw,
                stateStripTopIn,
                rights[b - 1] * fw,
                stateStripBottomIn,
              ),
          ]
        : const [];
    rasterAxes = hasDynamics
        ? [
            for (final (a, b) in ranges)
              Rect.fromLTRB(
                lefts[a] * fw,
                rasterTopIn,
                rights[b - 1] * fw,
                rasterBottomIn,
              ),
          ]
        : const [];
    topoCells = [
      for (final (a, b) in ranges)
        [
          for (var k = a; k < b; k++)
            Rect.fromLTRB(
              lefts[k] * fw,
              topoRowTopIn,
              rights[k] * fw,
              topoRowBottomIn,
            ),
        ],
    ];
    sessionSpan = [
      for (final (a, b) in ranges)
        Rect.fromLTRB(
          lefts[a] * fw,
          topoRowTopIn,
          rights[b - 1] * fw,
          topoRowBottomIn,
        ),
    ];
    colorbarAxes = Rect.fromLTWH(
      (rightFrac + 0.15 / fw) * fw,
      topoRowTopIn,
      0.12,
      topoRowBottomIn - topoRowTopIn,
    );
    topoLim = interp.outlines.axesLimits;
  }

  /// Aspect-equal ('box', anchor C) Axes rect inside a grid cell.
  Rect topoAxesRect(Rect cell) {
    final dw = topoLim.x1 - topoLim.x0, dh = topoLim.y1 - topoLim.y0;
    final aspect = dh / dw;
    if (cell.width * aspect <= cell.height) {
      final h = cell.width * aspect;
      return Rect.fromLTWH(cell.left, cell.center.dy - h / 2, cell.width, h);
    }
    final w = cell.height / aspect;
    return Rect.fromLTWH(cell.center.dx - w / 2, cell.top, w, cell.height);
  }

  Float64List? _values(TopoWindow w) =>
      result.settings.topoValue == TopoValue.rawT ? w.rawT : w.tObs;

  void _buildTopoCaches() {
    final res = interp.res;
    zGrids = [];
    _cells = [];
    for (final sess in result.sessions) {
      final zs = <Float64List?>[];
      final cs = <_TopoCellCache?>[];
      for (final w in sess.windows) {
        final v = _values(w);
        if (w.isBaseline || v == null || !v.every((x) => x.isFinite)) {
          zs.add(null);
          cs.add(null);
          continue;
        }
        final z = interp.grid(v);
        zs.add(z);
        // contours=3 -> matplotlib auto levels
        final path = Path();
        for (final lev in contourLevels(z, 3)) {
          for (final sgm in contourSegments(z, interp.xs, interp.ys, lev)) {
            path.moveTo(sgm[0], sgm[1]);
            path.lineTo(sgm[2], sgm[3]);
          }
        }
        cs.add(_TopoCellCache(_mesh(z, res), path));
      }
      zGrids.add(zs);
      _cells.add(cs);
    }
  }

  int _colorFor(double z) {
    if (z.isNaN) return 0x00000000;
    final vmin = -vmax;
    final norm = (z - vmin) / (vmax - vmin);
    var idx = (norm * 256).floor();
    if (idx < 0) idx = 0;
    if (idx > 255) idx = 255;
    return _lut[idx];
  }

  /// imshow(Zi, extent, origin='lower') as a Gouraud mesh in data coords:
  /// nodes at pixel centres, with an edge ring so the image reaches the
  /// extent borders (matplotlib clamps at edges).
  ui.Vertices _mesh(Float64List z, int res) {
    final cr = interp.outlines.clipRadius;
    final dx = 2 * cr / res;
    final n = res + 2;
    final coords = Float64List(n);
    for (var k = 0; k < n; k++) {
      if (k == 0) {
        coords[k] = -cr;
      } else if (k == n - 1) {
        coords[k] = cr;
      } else {
        coords[k] = -cr + (k - 0.5) * dx;
      }
    }
    final pos = Float32List(n * n * 2);
    final col = Int32List(n * n);
    for (var j = 0; j < n; j++) {
      final zj = (j - 1).clamp(0, res - 1);
      for (var i = 0; i < n; i++) {
        final zi = (i - 1).clamp(0, res - 1);
        final p = j * n + i;
        pos[2 * p] = coords[i];
        pos[2 * p + 1] = coords[j];
        col[p] = _colorFor(z[zj * res + zi]).toSigned(32);
      }
    }
    final idx = Uint16List((n - 1) * (n - 1) * 6);
    var q = 0;
    for (var j = 0; j < n - 1; j++) {
      for (var i = 0; i < n - 1; i++) {
        final a = j * n + i, b = a + 1, c = a + n, d = c + 1;
        idx[q++] = a;
        idx[q++] = b;
        idx[q++] = d;
        idx[q++] = a;
        idx[q++] = d;
        idx[q++] = c;
      }
    }
    return ui.Vertices.raw(
      ui.VertexMode.triangles,
      pos,
      colors: col,
      indices: idx,
    );
  }

  // ───────────────────────────────────────────────────────────────────────
  //  Painting
  // ───────────────────────────────────────────────────────────────────────

  /// Paints the whole figure at [ppi] pixels per inch onto [canvas]
  /// (origin = figure top-left).
  void paint(Canvas canvas, double ppi) {
    final pt = ppi / 72.0;
    Rect px(Rect inches) => Rect.fromLTRB(
      inches.left * ppi,
      inches.top * ppi,
      inches.right * ppi,
      inches.bottom * ppi,
    );

    canvas.drawRect(
      Rect.fromLTWH(0, 0, widthIn * ppi, heightIn * ppi),
      Paint()..color = const Color(0xFFFFFFFF),
    );

    // suptitle(fontsize=9) at (0.5, 0.98), va='top'
    drawMplText(
      canvas,
      result.suptitle,
      Offset(widthIn * ppi / 2, 0.02 * heightIn * ppi),
      9 * pt,
      ha: HAlign.center,
      va: VAlign.top,
    );

    for (var i = 0; i < result.sessions.length; i++) {
      _paintLineAxes(canvas, i, px(lineAxes[i]), pt);
    }
    if (stateDynamicsResult != null && stateStripAxes.isNotEmpty) {
      _paintStateDynamicsRow(canvas, ppi, pt, px);
    }
    _paintTopoRow(canvas, ppi, pt, px);
    _paintColorbar(canvas, px(colorbarAxes), pt);
  }

  Path _polyline(List<Offset?> pts) {
    final p = Path();
    var pen = false;
    for (final o in pts) {
      if (o == null) {
        pen = false;
        continue;
      }
      if (!pen) {
        p.moveTo(o.dx, o.dy);
        pen = true;
      } else {
        p.lineTo(o.dx, o.dy);
      }
    }
    return p;
  }

  void _dashed(Canvas canvas, Path path, Paint paint, double on, double off) {
    for (final m in path.computeMetrics()) {
      var d = 0.0;
      while (d < m.length) {
        final e = math.min(d + on, m.length);
        canvas.drawPath(m.extractPath(d, e), paint);
        d = e + off;
      }
    }
  }

  void _paintLineAxes(Canvas canvas, int i, Rect ax, double pt) {
    final s = result.settings;
    final sess = result.sessions[i];
    final dur = sess.durationMin;
    final yMin = result.yMin, yMax = result.yMax;
    double xOf(double t) => ax.left + t / dur * ax.width;
    double yOf(double v) => ax.bottom - (v - yMin) / (yMax - yMin) * ax.height;
    final x = sess.tMin;
    final n = x.length;

    canvas.save();
    canvas.clipRect(ax);

    // State Dynamics background tinting (if active) - merge contiguous state spans
    if (stateDynamicsResult != null && i < stateDynamicsResult!.recordings.length) {
      final rec = stateDynamicsResult!.recordings[i];
      var wIdx = 0;
      while (wIdx < rec.windows.length) {
        final wStart = rec.windows[wIdx];
        final label = wStart.stateLabel;
        final colorHex = wStart.stateColor;
        final t1Min = wStart.tStart / 60.0;
        var endIdx = wIdx + 1;
        while (endIdx < rec.windows.length && rec.windows[endIdx].stateLabel == label) {
          endIdx++;
        }
        final t2Min = (endIdx < rec.windows.length)
            ? rec.windows[endIdx].tStart / 60.0
            : dur;
        final xx1 = xOf(t1Min);
        final xx2 = xOf(t2Min);
        final isSelected = label == selectedStateLabel;
        final color = _parseColor(colorHex).withValues(
          alpha: isSelected ? 0.24 : 0.10,
        );
        canvas.drawRect(
          Rect.fromLTRB(xx1, ax.top, xx2, ax.bottom),
          Paint()..color = color,
        );
        if (isSelected) {
          canvas.drawLine(
            Offset(xx1, ax.top),
            Offset(xx2, ax.top),
            Paint()
              ..color = _parseColor(colorHex)
              ..strokeWidth = 2.0 * pt,
          );
        }
        wIdx = endIdx;
      }
    }

    // window boundaries: axvline(t_start, lightgray, lw=.5, ls=':'), zorder 1
    final vl = Paint()
      ..color = _lightGray
      ..strokeWidth = 0.5 * pt
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.butt;
    for (final w in sess.windows) {
      if (w.tStart > 0) {
        final xx = xOf(w.tStart);
        _dashed(
          canvas,
          Path()
            ..moveTo(xx, ax.bottom)
            ..lineTo(xx, ax.top),
          vl,
          1.0 * 0.5 * pt,
          1.65 * 0.5 * pt,
        );
      }
    }

    if (s.eventMarkerOpacity > 0 && sess.events.isNotEmpty) {
      final markerAlpha = s.eventMarkerOpacity.clamp(0.0, 1.0);
      final ink = Paint()
        ..color = const Color(0xFF7B1FA2).withValues(alpha: markerAlpha)
        ..strokeWidth = 0.7 * pt;
      var lastLineX = -1e9;
      final lastLabelRight = <double>[-1e9, -1e9, -1e9];
      var labelRow = 0;
      for (var eventIndex = 0; eventIndex < sess.events.length; eventIndex++) {
        final event = sess.events[eventIndex];
        final onset = (event['onset_s'] as num).toDouble() / 60;
        final duration = (event['duration_s'] as num).toDouble() / 60;
        final xx = xOf(onset);
        if (duration > 0) {
          canvas.drawRect(
            Rect.fromLTRB(xx, ax.top, xOf(onset + duration), ax.bottom),
            Paint()
              ..color = const Color(0xFF7B1FA2).withValues(
                alpha: (markerAlpha * 0.25).clamp(0.01, 0.25),
              ),
          );
        }
        if (xx - lastLineX >= 0.85 * pt) {
          canvas.drawLine(Offset(xx, ax.top), Offset(xx, ax.bottom), ink);
          lastLineX = xx;
        }
        if (s.showEventLabels) {
          final row = labelRow % 3;
          if (xx >= lastLabelRight[row] + 4 * pt) {
            final label = TextPainter(
              text: TextSpan(
                text: event['label'] as String,
                style: TextStyle(
                  color: const Color(0xFF7B1FA2).withValues(
                    alpha: (markerAlpha * 1.4).clamp(0.15, 1.0),
                  ),
                  fontSize: 7 * pt,
                ),
              ),
              textDirection: TextDirection.ltr,
              maxLines: 1,
              ellipsis: '…',
            )..layout(maxWidth: 80 * pt);
            label.paint(
              canvas,
              Offset(xx + 2 * pt, ax.top + row * 9 * pt),
            );
            lastLabelRight[row] = xx + 2 * pt + label.width;
            labelRow++;
          }
        }
      }
    }

    // fill_between(mean - band, mean + band, gray, alpha .3), zorder 2
    final fill = Paint()..color = _gray.withValues(alpha: 0.3);
    var r = 0;
    while (r < n) {
      while (r < n && (sess.mean[r].isNaN || sess.band[r].isNaN)) {
        r++;
      }
      final a = r;
      while (r < n && !(sess.mean[r].isNaN || sess.band[r].isNaN)) {
        r++;
      }
      if (r - a >= 1) {
        final p = Path()..moveTo(xOf(x[a]), yOf(sess.mean[a] + sess.band[a]));
        for (var k = a + 1; k < r; k++) {
          p.lineTo(xOf(x[k]), yOf(sess.mean[k] + sess.band[k]));
        }
        for (var k = r - 1; k >= a; k--) {
          p.lineTo(xOf(x[k]), yOf(sess.mean[k] - sess.band[k]));
        }
        p.close();
        canvas.drawPath(p, fill);
      }
    }

    // mean line (tab:red, lw 1.3), zorder 3
    final meanPts = [
      for (var k = 0; k < n; k++)
        sess.mean[k].isNaN ? null : Offset(xOf(x[k]), yOf(sess.mean[k])),
    ];
    canvas.drawPath(
      _polyline(meanPts),
      Paint()
        ..color = Color(
          result.settings.sessionColors[sess.path] ??
              result.settings.sessionColors[sess.name] ??
              _tabRed.toARGB32(),
        )
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3 * pt
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.square,
    );

    // representative channel (steelblue, lw .8, '--', alpha .8), zorder 3
    if (sess.repr != null) {
      final rp = sess.repr!;
      final pts = [
        for (var k = 0; k < n; k++)
          rp[k].isNaN ? null : Offset(xOf(x[k]), yOf(rp[k])),
      ];
      _dashed(
        canvas,
        _polyline(pts),
        Paint()
          ..color = _steelBlue.withValues(alpha: 0.8)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.8 * pt
          ..strokeJoin = StrokeJoin.round,
        3.7 * 0.8 * pt,
        1.6 * 0.8 * pt,
      );
    }

    // scatter(x[::step], mean[::step], s=8, tab:red), zorder 4.
    // s is the marker area in pt^2; the edge (collection default lw 1.0,
    // edgecolor='face') adds half a linewidth to the radius.
    final step = math.max(n ~/ 60, 1);
    final rad = (math.sqrt(8.0) / 2 + 0.5) * pt;
    final dot = Paint()
      ..color = Color(
        result.settings.sessionColors[sess.path] ??
            result.settings.sessionColors[sess.name] ??
            _tabRed.toARGB32(),
      );
    for (var k = 0; k < n; k += step) {
      final v = sess.mean[k];
      if (v.isNaN) continue;
      canvas.drawCircle(Offset(xOf(x[k]), yOf(v)), rad, dot);
    }
    canvas.restore();

    // spines (lw .8)
    canvas.drawRect(
      ax,
      Paint()
        ..color = _black
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8 * pt,
    );

    // legend(fontsize=6, loc='upper right', frameon=False)
    if (sess.repr != null && s.reprChan != null) {
      const fs = 6.0;
      final label = s.reprChan!;
      final tb = MplTextBlock(label, fs * pt, _black, HAlign.left);
      final right = ax.right - (0.5 + 0.4) * fs * pt;
      final baseline = ax.top + (0.5 + 0.4) * fs * pt + tb.ascent;
      final textLeft = right - tb.width;
      drawMplTextBlock(canvas, tb, Offset(textLeft, baseline));
      final hx1 = textLeft - 0.8 * fs * pt, hx0 = hx1 - 2.0 * fs * pt;
      final hy = baseline - 0.35 * fs * pt;
      _dashed(
        canvas,
        Path()
          ..moveTo(hx0, hy)
          ..lineTo(hx1, hy),
        Paint()
          ..color = _steelBlue.withValues(alpha: 0.8)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.8 * pt,
        3.7 * 0.8 * pt,
        1.6 * 0.8 * pt,
      );
    }

    final tick = Paint()
      ..color = _black
      ..strokeWidth = 0.8 * pt
      ..style = PaintingStyle.stroke;

    // x axis
    final xt = AxisTicks.compute(
      MaxNLocator.auto(xTickSpace(ax.width / pt, 7)),
      0,
      dur,
    );
    var labelsBottom = ax.bottom + 3.5 * pt;
    for (var k = 0; k < xt.locs.length; k++) {
      final xx = xOf(xt.locs[k]);
      canvas.drawLine(
        Offset(xx, ax.bottom),
        Offset(xx, ax.bottom + 3.5 * pt),
        tick,
      );
      final bb = drawMplText(
        canvas,
        xt.labels[k],
        Offset(xx, ax.bottom + 7 * pt),
        7 * pt,
        ha: HAlign.center,
        va: VAlign.top,
      );
      labelsBottom = math.max(labelsBottom, bb.bottom);
    }
    drawMplText(
      canvas,
      'Time (mins)',
      Offset(ax.center.dx, labelsBottom + 4 * pt),
      8 * pt,
      ha: HAlign.center,
      va: VAlign.top,
    );

    // y axis
    final yt = AxisTicks.compute(
      MaxNLocator.auto(yTickSpace(ax.height / pt, 7)),
      yMin,
      yMax,
    );
    var labelsLeft = ax.left - 3.5 * pt;
    for (var k = 0; k < yt.locs.length; k++) {
      final yy = yOf(yt.locs[k]);
      canvas.drawLine(
        Offset(ax.left - 3.5 * pt, yy),
        Offset(ax.left, yy),
        tick,
      );
      if (i == 0) {
        final bb = drawMplText(
          canvas,
          yt.labels[k],
          Offset(ax.left - 7 * pt, yy),
          7 * pt,
          ha: HAlign.right,
          va: VAlign.centerBaseline,
        );
        labelsLeft = math.min(labelsLeft, bb.left);
      }
    }
    if (i == 0) {
      if (yt.offsetText.isNotEmpty) {
        drawMplText(
          canvas,
          yt.offsetText,
          Offset(ax.left, ax.top - 3 * pt),
          7 * pt,
          ha: HAlign.left,
          va: VAlign.baseline,
        );
      }
      drawMplText(
        canvas,
        '${s.feature}\n(mean ± ${s.shadeMetric} across ch.)',
        Offset(labelsLeft - 4 * pt, ax.center.dy),
        8 * pt,
        ha: HAlign.center,
        va: VAlign.bottom,
        rotationDeg: 90,
        rotationModeAnchor: true,
      );
    }

    // title(name, fontsize=9), pad 6pt, va baseline
    var title = sess.name;
    title = title.replaceAll(RegExp(r'(-epo)?_clean$'), '');
    title = title.replaceAll(RegExp(r'-epo$'), '');
    final maxTitleW = ax.width - 2.0 * pt;
    if (maxTitleW > 0) {
      while (title.length > 4 &&
          measureMplText(title, Offset.zero, 9 * pt).width > maxTitleW) {
        title = title.substring(0, title.length - 1);
      }
      if (title.length < sess.name.length && !title.endsWith('…')) {
        title = '$title…';
      }
    }

    drawMplText(
      canvas,
      title,
      Offset(ax.center.dx, ax.top - 6 * pt),
      9 * pt,
      ha: HAlign.center,
      va: VAlign.baseline,
    );
  }

  void _paintStateDynamicsRow(
    Canvas canvas,
    double ppi,
    double pt,
    Rect Function(Rect) px,
  ) {
    if (stateDynamicsResult == null) return;
    final res = stateDynamicsResult!;

    for (var i = 0; i < result.sessions.length; i++) {
      if (i >= res.recordings.length || i >= stateStripAxes.length) continue;
      final sess = result.sessions[i];
      final rec = res.recordings[i];
      final dur = sess.durationMin;
      final strip = px(stateStripAxes[i]);
      final raster = px(rasterAxes[i]);

      double xOf(double tMin) => strip.left + tMin / dur * strip.width;

      // 1. State Categorical Bar (merged contiguous state spans)
      canvas.save();
      canvas.clipRect(strip);
      var wIdx = 0;
      while (wIdx < rec.windows.length) {
        final wStart = rec.windows[wIdx];
        final label = wStart.stateLabel;
        final colorHex = wStart.stateColor;
        final t1Min = wStart.tStart / 60.0;
        var endIdx = wIdx + 1;
        while (endIdx < rec.windows.length && rec.windows[endIdx].stateLabel == label) {
          endIdx++;
        }
        final t2Min = (endIdx < rec.windows.length)
            ? rec.windows[endIdx].tStart / 60.0
            : dur;
        final xx1 = xOf(t1Min);
        final xx2 = xOf(t2Min);
        final isSelected = label == selectedStateLabel;
        final baseColor = _parseColor(colorHex);
        final fillColor = (selectedStateLabel != null && !isSelected)
            ? baseColor.withValues(alpha: 0.45)
            : baseColor;

        canvas.drawRect(
          Rect.fromLTRB(xx1, strip.top, xx2, strip.bottom),
          Paint()..color = fillColor,
        );

        if (isSelected) {
          canvas.drawRect(
            Rect.fromLTRB(
              xx1 + 0.5 * pt,
              strip.top + 0.5 * pt,
              math.max(xx1 + 1.0 * pt, xx2 - 0.5 * pt),
              strip.bottom - 0.5 * pt,
            ),
            Paint()
              ..color = const Color(0xFF0F172A)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.3 * pt,
          );
        }

        // Draw state letter if wide enough
        if (xx2 - xx1 > 10 * pt) {
          final tp = TextPainter(
            text: TextSpan(
              text: label,
              style: TextStyle(
                color: const Color(0xFFFFFFFF),
                fontWeight: FontWeight.bold,
                fontSize: 8.5 * pt,
              ),
            ),
            textDirection: TextDirection.ltr,
          )..layout();
          tp.paint(
            canvas,
            Offset((xx1 + xx2) / 2 - tp.width / 2, strip.center.dy - tp.height / 2),
          );
        }
        wIdx = endIdx;
      }
      canvas.restore();

      // Border around strip
      canvas.drawRect(
        strip,
        Paint()
          ..color = const Color(0x33000000)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.5 * pt,
      );

      // Label on the left for session 0
      if (i == 0) {
        drawMplText(
          canvas,
          'state (${res.scale})',
          Offset(strip.left - 6 * pt, strip.center.dy),
          7.5 * pt,
          ha: HAlign.right,
          va: VAlign.center,
          color: const Color(0xFF555555),
        );
      }

      // 2. Multi-scale boundary rasters (auto, 60s, 30s, 15s)
      canvas.save();
      canvas.clipRect(raster);
      final scales = const ['auto', '60s', '30s', '15s'];
      final tickH = raster.height / scales.length;
      final tickPaint = Paint()
        ..color = const Color(0x99000000)
        ..strokeWidth = 0.8 * pt;

      for (var sIdx = 0; sIdx < scales.length; sIdx++) {
        final sc = scales[sIdx];
        final cuts = rec.cutPoints[sc] ?? [];
        final yBase = raster.top + sIdx * tickH;

        for (var c = 1; c < cuts.length - 1; c++) {
          final winIdx = cuts[c];
          if (winIdx < rec.windows.length) {
            final tx = xOf(rec.windows[winIdx].tStart / 60.0);
            canvas.drawLine(
              Offset(tx, yBase + 1.0 * pt),
              Offset(tx, yBase + tickH - 1.0 * pt),
              tickPaint,
            );
          }
        }

        if (i == 0) {
          drawMplText(
            canvas,
            sc,
            Offset(raster.left - 6 * pt, yBase + tickH / 2),
            6.5 * pt,
            ha: HAlign.right,
            va: VAlign.center,
            color: const Color(0xFF777777),
          );
        }
      }
      canvas.restore();

      // Border around raster
      canvas.drawRect(
        raster,
        Paint()
          ..color = const Color(0x22000000)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.5 * pt,
      );
    }
  }

  static Color _parseColor(String hex) {
    var c = hex.replaceAll('#', '');
    if (c.length == 6) c = 'FF$c';
    return Color(int.tryParse(c, radix: 16) ?? 0xFF0072B2);
  }

  void _paintTopoRow(
    Canvas canvas,
    double ppi,
    double pt,
    Rect Function(Rect) px,
  ) {
    final s = result.settings;
    final markerScale = math.max(0.5, s.targetTopoWidthIn / 0.9);
    final mew = s.sigMarkerEdgeWidth * markerScale; // pt
    final ms = s.sigMarkerSize * markerScale; // pt (diameter)
    final o = interp.outlines;

    for (var si = 0; si < result.sessions.length; si++) {
      final sess = result.sessions[si];
      final cells = topoCells[si];
      if (sess.windows.isEmpty) {
        final c = px(sessionSpan[si]);
        drawMplText(
          canvas,
          'too little\ndata',
          c.center,
          7 * pt,
          ha: HAlign.center,
          va: VAlign.center,
        );
      } else {
        final nCols = cells.length;
        final labelStep = math.max(1, nCols ~/ 6);
        for (var j = 0; j < sess.windows.length; j++) {
          final w = sess.windows[j];
          final cellPx = px(cells[j]);
          final cache = _cells[si][j];
          Rect? axPx;
          if (w.isBaseline) {
            axPx = px(topoAxesRect(cells[j]));
            _paintHead(
              canvas,
              axPx,
              pt,
              null,
              null,
              null,
              0,
              0,
              baseline: true,
            );
            drawMplText(
              canvas,
              'baseline',
              axPx.center,
              6 * pt,
              ha: HAlign.center,
              va: VAlign.center,
              rotationDeg: 90,
            );
          } else if (cache == null) {
            drawMplText(
              canvas,
              'n/a',
              cellPx.center,
              7 * pt,
              ha: HAlign.center,
              va: VAlign.center,
            );
          } else {
            axPx = px(topoAxesRect(cells[j]));
            _paintHead(canvas, axPx, pt, cache, w.significant, o, mew, ms);
          }
          if (j % labelStep == 0) {
            final top = axPx?.top ?? cellPx.top;
            drawMplText(
              canvas,
              w.tStart.toStringAsFixed(0),
              Offset(cellPx.center.dx, top - 1 * pt),
              6.5 * pt,
              ha: HAlign.center,
              va: VAlign.baseline,
            );
          }
        }
      }
      // session name under its block: fig.text(xc, topo_bottom - 0.012, va='top')
      final span = px(sessionSpan[si]);
      final y = (heightIn - (_K.bottomMarginIn - 0.012 * heightIn)) * ppi;
      drawMplText(
        canvas,
        sess.name,
        Offset(span.center.dx, y),
        6.5 * pt,
        ha: HAlign.center,
        va: VAlign.top,
      );
    }
  }

  /// Draws one plot_topomap Axes into [ax] (px).
  void _paintHead(
    Canvas canvas,
    Rect ax,
    double pt,
    _TopoCellCache? cache,
    List<bool>? sig,
    HeadOutlines? o,
    double mew,
    double ms, {
    bool baseline = false,
  }) {
    final outlines = interp.outlines;
    final lim = topoLim;
    final k = ax.width / (lim.x1 - lim.x0);
    canvas.save();
    canvas.translate(ax.left - lim.x0 * k, ax.top + lim.y1 * k);
    canvas.scale(k, -k);
    final cr = outlines.clipRadius;
    canvas.save();
    canvas.clipPath(
      Path()..addOval(Rect.fromCircle(center: Offset.zero, radius: cr)),
    );
    if (baseline) {
      canvas.drawRect(
        Rect.fromLTRB(-cr, -cr, cr, cr),
        Paint()..color = _baselineGray,
      );
    } else if (cache != null) {
      if (cache.vertices != null) {
        canvas.drawVertices(cache.vertices!, BlendMode.dst, Paint());
      }
      if (cache.contours != null) {
        canvas.drawPath(
          cache.contours!,
          Paint()
            ..color = _black
            ..style = PaintingStyle.stroke
            ..strokeWidth = (mew / 2) * pt / k,
        );
      }
    }
    canvas.restore();

    // significant channels: marker 'o', facecolor none, edgecolor k
    if (sig != null) {
      final ring = Paint()
        ..color = _black
        ..style = PaintingStyle.stroke
        ..strokeWidth = mew * pt / k;
      for (var c = 0; c < sig.length && c < interp.pos.length; c++) {
        if (!sig[c]) continue;
        final p = interp.pos[c];
        canvas.drawCircle(Offset(p.x, p.y), ms / 2 * pt / k, ring);
      }
    }

    // head, nose, ears (lw 1, clip_on=False)
    final ol = Paint()
      ..color = _black
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0 * pt / k
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.square;
    for (final line in [
      outlines.head,
      outlines.nose,
      outlines.earLeft,
      outlines.earRight,
    ]) {
      final p = Path()..moveTo(line.first.x, line.first.y);
      for (final q in line.skip(1)) {
        p.lineTo(q.x, q.y);
      }
      canvas.drawPath(p, ol);
    }
    canvas.restore();
  }

  void _paintColorbar(Canvas canvas, Rect cb, double pt) {
    bool anyTopo = false;
    for (final cs in _cells) {
      if (cs.any((c) => c != null)) anyTopo = true;
    }
    if (!anyTopo) return;
    // 256 colour bands from -vmax (bottom) to +vmax (top)
    for (var i = 0; i < 256; i++) {
      final y0 = cb.bottom - cb.height * i / 256;
      final y1 = cb.bottom - cb.height * (i + 1) / 256;
      canvas.drawRect(
        Rect.fromLTRB(cb.left, y1 - 0.25, cb.right, y0 + 0.25),
        Paint()..color = Color(_lut[i]),
      );
    }
    final line = Paint()
      ..color = _black
      ..strokeWidth = 0.8 * pt
      ..style = PaintingStyle.stroke;
    canvas.drawRect(cb, line);
    final ticks = AxisTicks.compute(
      MaxNLocator.auto(yTickSpace(cb.height / pt, 6)),
      -vmax,
      vmax,
    );
    var right = cb.right + 3.5 * pt;
    for (var i = 0; i < ticks.locs.length; i++) {
      final y = cb.bottom - (ticks.locs[i] + vmax) / (2 * vmax) * cb.height;
      canvas.drawLine(
        Offset(cb.right, y),
        Offset(cb.right + 3.5 * pt, y),
        line,
      );
      final bb = drawMplText(
        canvas,
        ticks.labels[i],
        Offset(cb.right + 7 * pt, y),
        6 * pt,
        ha: HAlign.left,
        va: VAlign.centerBaseline,
      );
      right = math.max(right, bb.right);
    }
    drawMplText(
      canvas,
      't-value vs. baseline',
      Offset(right + 4 * pt, cb.center.dy),
      7 * pt,
      ha: HAlign.center,
      va: VAlign.top,
      rotationDeg: 90,
      rotationModeAnchor: true,
    );
  }

  /// One enlarged topomap (with channel names) for the inspector dialog.
  void paintSingleTopo(Canvas canvas, Rect area, int si, int j) {
    canvas.drawRect(area, Paint()..color = const Color(0xFFFFFFFF));
    final w = result.sessions[si].windows[j];
    final lim = topoLim;
    final aspect = (lim.y1 - lim.y0) / (lim.x1 - lim.x0);
    final box = area.deflate(24);
    Rect ax;
    if (box.width * aspect <= box.height) {
      final h = box.width * aspect;
      ax = Rect.fromLTWH(box.left, box.center.dy - h / 2, box.width, h);
    } else {
      final ww = box.height / aspect;
      ax = Rect.fromLTWH(box.center.dx - ww / 2, box.top, ww, box.height);
    }
    // scale point sizes with the enlargement relative to the figure
    final pt = ax.width / (topoAxesRect(topoCells[si][j]).width * 72);
    final s = result.settings;
    final markerScale = math.max(0.5, s.targetTopoWidthIn / 0.9);
    if (w.isBaseline) {
      _paintHead(canvas, ax, pt, null, null, null, 0, 0, baseline: true);
    } else {
      _paintHead(
        canvas,
        ax,
        pt,
        _cells[si][j],
        w.significant,
        interp.outlines,
        s.sigMarkerEdgeWidth * markerScale,
        s.sigMarkerSize * markerScale,
      );
    }
    final k = ax.width / (lim.x1 - lim.x0);
    for (var c = 0; c < interp.pos.length; c++) {
      final p = interp.pos[c];
      final o = Offset(
        ax.left + (p.x - lim.x0) * k,
        ax.top + (lim.y1 - p.y) * k,
      );
      canvas.drawCircle(o, 1.6, Paint()..color = const Color(0xFF000000));
      final sig = w.significant != null && w.significant![c];
      drawMplText(
        canvas,
        s.channels[c],
        o + const Offset(0, -3),
        10,
        ha: HAlign.center,
        va: VAlign.bottom,
        color: sig ? const Color(0xFF000000) : const Color(0xFF333333),
      );
    }
  }

  // ───────────────────────────────────────────────────────────────────────
  //  Interaction
  // ───────────────────────────────────────────────────────────────────────

  /// Hit-test at a position in figure inches.
  TopoHit? hitTest(Offset pIn) {
    // Check state strip first
    if (stateDynamicsResult != null && stateStripAxes.isNotEmpty) {
      for (var i = 0; i < stateStripAxes.length; i++) {
        final strip = stateStripAxes[i];
        if (strip.contains(pIn) && i < stateDynamicsResult!.recordings.length) {
          final rec = stateDynamicsResult!.recordings[i];
          final durMin = result.sessions[i].durationMin;
          if (durMin > 0) {
            final tSec = (pIn.dx - strip.left) / strip.width * durMin * 60.0;
            for (var wIdx = 0; wIdx < rec.windows.length; wIdx++) {
              final w = rec.windows[wIdx];
              final nextT = (wIdx + 1 < rec.windows.length)
                  ? rec.windows[wIdx + 1].tStart
                  : rec.durationS;
              if (tSec >= w.tStart && tSec <= nextT) {
                return TopoHit.state(w.stateLabel, i);
              }
            }
          }
        }
      }
    }

    for (var i = 0; i < lineAxes.length; i++) {
      final ax = lineAxes[i];
      if (ax.contains(pIn)) {
        final sess = result.sessions[i];
        if (sess.tMin.isEmpty) return null;
        final t = (pIn.dx - ax.left) / ax.width * sess.durationMin;
        var best = 0;
        var bd = double.infinity;
        for (var k = 0; k < sess.tMin.length; k++) {
          final d = (sess.tMin[k] - t).abs();
          if (d < bd) {
            bd = d;
            best = k;
          }
        }

        String? hitState;
        if (stateDynamicsResult != null && i < stateDynamicsResult!.recordings.length) {
          final rec = stateDynamicsResult!.recordings[i];
          final tSec = t * 60.0;
          for (var wIdx = 0; wIdx < rec.windows.length; wIdx++) {
            final w = rec.windows[wIdx];
            final nextT = (wIdx + 1 < rec.windows.length)
                ? rec.windows[wIdx + 1].tStart
                : rec.durationS;
            if (tSec >= w.tStart && tSec <= nextT) {
              hitState = w.stateLabel;
              break;
            }
          }
        }

        return TopoHit.line(i, best, stateLabel: hitState);
      }
    }
    for (var i = 0; i < topoCells.length; i++) {
      final cells = topoCells[i];
      for (
        var j = 0;
        j < cells.length && j < result.sessions[i].windows.length;
        j++
      ) {
        if (!cells[j].contains(pIn)) continue;
        final ax = topoAxesRect(cells[j]);
        final lim = topoLim;
        final k = ax.width / (lim.x1 - lim.x0);
        final dx = lim.x0 + (pIn.dx - ax.left) / k;
        final dy = lim.y1 - (pIn.dy - ax.top) / k;
        var best = -1;
        var bd = double.infinity;
        for (var c = 0; c < interp.pos.length; c++) {
          final p = interp.pos[c];
          final d = (p.x - dx) * (p.x - dx) + (p.y - dy) * (p.y - dy);
          if (d < bd) {
            bd = d;
            best = c;
          }
        }
        final inside =
            dx * dx + dy * dy <=
            interp.outlines.clipRadius * interp.outlines.clipRadius;
        return TopoHit.topo(i, j, inside ? best : -1);
      }
    }
    if (colorbarAxes.inflate(0.05).contains(pIn)) return TopoHit.colorbar();
    return null;
  }

  /// Overlay for hover feedback (not part of exports).
  void paintHover(Canvas canvas, double ppi, TopoHit hit) {
    final pt = ppi / 72;
    Rect px(Rect r) =>
        Rect.fromLTRB(r.left * ppi, r.top * ppi, r.right * ppi, r.bottom * ppi);
    final accent = const Color(0xFFF59E0B);
    if (hit.isLine) {
      final ax = px(lineAxes[hit.session]);
      final sess = result.sessions[hit.session];
      final t = sess.tMin[hit.sampleIndex];
      final xx = ax.left + t / sess.durationMin * ax.width;
      canvas.drawLine(
        Offset(xx, ax.top),
        Offset(xx, ax.bottom),
        Paint()
          ..color = accent
          ..strokeWidth = 1.0 * pt,
      );
      // matching window
      for (var j = 0; j < sess.windows.length; j++) {
        final w = sess.windows[j];
        if (t >= w.tStart && t < w.tEnd) {
          _outlineCell(canvas, px(topoCells[hit.session][j]), accent, pt);
          final x0 = ax.left + w.tStart / sess.durationMin * ax.width;
          final x1 = ax.left + w.tEnd / sess.durationMin * ax.width;
          canvas.drawRect(
            Rect.fromLTRB(x0, ax.top, math.min(x1, ax.right), ax.bottom),
            Paint()..color = accent.withValues(alpha: 0.08),
          );
        }
      }
    } else if (hit.isTopo) {
      final sess = result.sessions[hit.session];
      final w = sess.windows[hit.window];
      _outlineCell(canvas, px(topoCells[hit.session][hit.window]), accent, pt);
      final ax = px(lineAxes[hit.session]);
      final x0 = ax.left + w.tStart / sess.durationMin * ax.width;
      final x1 = ax.left + w.tEnd / sess.durationMin * ax.width;
      canvas.drawRect(
        Rect.fromLTRB(x0, ax.top, math.min(x1, ax.right), ax.bottom),
        Paint()..color = accent.withValues(alpha: 0.12),
      );
      if (hit.channel >= 0) {
        final axT = px(topoAxesRect(topoCells[hit.session][hit.window]));
        final lim = topoLim;
        final k = axT.width / (lim.x1 - lim.x0);
        final p = interp.pos[hit.channel];
        final c = Offset(
          axT.left + (p.x - lim.x0) * k,
          axT.top + (lim.y1 - p.y) * k,
        );
        canvas.drawCircle(
          c,
          2.2 * pt,
          Paint()
            ..color = accent
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.9 * pt,
        );
      }
    } else if (hit.isState) {
      if (hit.session >= 0 && hit.session < stateStripAxes.length) {
        final strip = px(stateStripAxes[hit.session]);
        _outlineCell(canvas, strip, accent, pt);
      }
    }
  }

  void _outlineCell(Canvas canvas, Rect r, Color c, double pt) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(r.deflate(0.5 * pt), Radius.circular(2 * pt)),
      Paint()
        ..color = c
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.9 * pt,
    );
  }

  // ───────────────────────────────────────────────────────────────────────
  //  Export
  // ───────────────────────────────────────────────────────────────────────

  /// Rasterises the figure at [dpi] (the script saves at 200).
  Future<ui.Image> toImage({double dpi = 200}) async {
    final w = (widthIn * dpi).round(), h = (heightIn * dpi).round();
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec, Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()));
    paint(canvas, dpi);
    final pic = rec.endRecording();
    try {
      return await pic.toImage(w, h);
    } finally {
      pic.dispose();
    }
  }

  Future<Uint8List> toPng({double dpi = 200}) async {
    final img = await toImage(dpi: dpi);
    try {
      final bd = await img.toByteData(format: ui.ImageByteFormat.png);
      return bd!.buffer.asUint8List();
    } finally {
      img.dispose();
    }
  }

  /// Human-readable description of a hit (tooltip text).
  String describe(TopoHit hit) {
    final s = result.settings;
    String f(double v, [int d = 4]) => v.isNaN ? 'NaN' : v.toStringAsFixed(d);
    if (hit.isLine) {
      final sess = result.sessions[hit.session];
      final k = hit.sampleIndex;
      final b = StringBuffer()
        ..writeln(sess.name)
        ..writeln(
          't = ${f(sess.tMin[k], 2)} min (epoch ${(sess.tMin[k] * 60 / s.epochSize).round()})',
        )
        ..writeln(
          'mean = ${f(sess.mean[k])}  ± ${f(sess.band[k])} (${s.shadeMetric})',
        );
      if (sess.repr != null) b.writeln('${s.reprChan} = ${f(sess.repr![k])}');
      if (hit.stateLabel != null) {
        b.writeln('State ${hit.stateLabel} (click to view feature map)');
      }
      return b.toString().trimRight();
    }
    if (hit.isState) {
      final sess = hit.session >= 0 && hit.session < result.sessions.length
          ? result.sessions[hit.session]
          : null;
      return '${sess != null ? "${sess.name}\n" : ""}State ${hit.stateLabel} (click to view feature map)';
    }
    if (hit.isTopo) {
      final sess = result.sessions[hit.session];
      final w = sess.windows[hit.window];
      final b = StringBuffer()
        ..writeln(
          '${sess.name}  ${w.tStart.toStringAsFixed(0)}–${w.tEnd.toStringAsFixed(0)} min',
        );
      if (w.isBaseline) {
        b.writeln('baseline window');
      } else if (!w.hasStats) {
        b.writeln('n/a (fewer than 3 complete epochs)');
      } else if (hit.channel >= 0) {
        final c = hit.channel;
        b
          ..writeln(s.channels[c])
          ..writeln('e-TFCE stat = ${f(w.tObs![c], 3)}')
          ..writeln('Welch t = ${w.rawT == null ? '–' : f(w.rawT![c], 3)}')
          ..writeln(
            'p = ${w.pValues == null ? '–' : f(w.pValues![c], 3)}'
            '   q = ${w.qValues == null ? '–' : f(w.qValues![c], 3)}',
          )
          ..writeln(
            w.significant != null && w.significant![c]
                ? 'significant (q ≤ ${s.alpha})'
                : 'not significant',
          );
      } else {
        final nSig = w.significant?.where((x) => x).length ?? 0;
        b.writeln('$nSig / ${s.channels.length} channels significant');
      }
      return b.toString().trimRight();
    }
    return 'Colour scale ±${vmax.toStringAsFixed(2)} '
        '(${s.topoValue == TopoValue.rawT ? 'Welch t' : 'e-TFCE statistic'})';
  }
}

/// Ensures the default 32 constants are referenced (tree-shaking guard for
/// tests that import only the figure).
List<String> get defaultTopoChannels => kDefault32Channels;
