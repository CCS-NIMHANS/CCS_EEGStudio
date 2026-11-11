import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/rendering.dart';
import '../topostats/topo_interp.dart';
import '../topostats/topo_paint.dart';
import '../topostats/mne_constants.dart';

List<double> erpNumbers(dynamic value) => value is List
    ? value.map((v) => v is num ? v.toDouble() : double.nan).toList()
    : [];
Map<String, dynamic> erpMap(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};
void erpText(
  Canvas c,
  String text,
  Offset at, {
  double size = 12,
  Color color = const Color(0xFF334155),
  double maxWidth = 1000,
}) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(color: color, fontSize: size, fontFamily: 'DejaVuSans'),
    ),
    textDirection: TextDirection.ltr,
    maxLines: 2,
    ellipsis: '…',
  )..layout(maxWidth: maxWidth);
  painter.paint(c, at);
}

class ErpWorkbenchWavePainter extends CustomPainter {
  ErpWorkbenchWavePainter(
    this.data, {
    this.negativeUp = true,
    this.hoverX,
    this.decode = false,
  });
  final Map<String, dynamic> data;
  final bool negativeUp, decode;
  final double? hoverX;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFFFFFFF),
    );
    final times = erpNumbers(data['times']);
    if (times.length < 2) return;
    final modelPlot = data['model_plot'] == true;
    final condWaves = data['condition_waves'] is Map ? (data['condition_waves'] as Map) : null;
    final condNames = (data['condition_names'] as List?)?.map((e) => e.toString()).toList();
    final condSems = data['condition_sems'] is Map ? (data['condition_sems'] as Map) : null;
    final profile = erpMap(data['profile']);
    final lateral = profile['lateralized'] == true;

    const defaultColors = [
      Color(0xFF2563EB), // Blue
      Color(0xFFDC2626), // Red
      Color(0xFF16A34A), // Green
      Color(0xFF9333EA), // Purple
      Color(0xFFEA580C), // Orange
      Color(0xFF0891B2), // Cyan
      Color(0xFFD97706), // Amber
      Color(0xFFDB2777), // Pink
      Color(0xFF475569), // Slate
    ];

    List<List<double>> arrays;
    List<String> names;
    List<List<double>> bands = [];
    List<Color> colors;

    if (decode) {
      arrays = [erpNumbers(data['auc']), erpNumbers(data['balanced_accuracy'])];
      names = ['AUC', 'Balanced accuracy'];
      colors = [const Color(0xFF2563EB), const Color(0xFFDC2626)];
    } else if (condWaves != null && condNames != null && condNames.length > 2) {
      names = condNames;
      arrays = [for (final n in condNames) erpNumbers(condWaves[n])];
      if (condSems != null) {
        bands = [for (final n in condNames) erpNumbers(condSems[n])];
      }
      colors = [for (var i = 0; i < names.length; i++) defaultColors[i % defaultColors.length]];
    } else if (condWaves != null && condNames != null && condNames.length == 2 && !modelPlot) {
      final nameA = condNames[0];
      final nameB = condNames[1];
      final diffName = '$nameB - $nameA';
      names = [nameA, nameB, diffName];
      arrays = [
        erpNumbers(condWaves[nameA]),
        erpNumbers(condWaves[nameB]),
        erpNumbers(data['difference']),
      ];
      bands = [
        condSems != null ? erpNumbers(condSems[nameA]) : erpNumbers(data['sem_a']),
        condSems != null ? erpNumbers(condSems[nameB]) : erpNumbers(data['sem_b']),
        erpNumbers(data['sem_difference']),
      ];
      colors = [
        const Color(0xFF2563EB),
        const Color(0xFFDC2626),
        const Color(0xFF475569),
      ];
    } else {
      final nameA = lateral ? 'Ipsilateral' : (profile['a_name'] ?? 'A');
      final nameB = lateral ? 'Contralateral' : (profile['b_name'] ?? 'B');
      names = [
        nameA,
        nameB,
        if (!modelPlot) '$nameB - $nameA',
      ];
      arrays = [
        erpNumbers(data['a']),
        erpNumbers(data['b']),
        if (!modelPlot) erpNumbers(data['difference']),
      ];
      bands = [
        for (final key in ['a', 'b', if (!modelPlot) 'difference'])
          erpNumbers(data['sem_$key']),
      ];
      colors = [
        const Color(0xFF2563EB),
        const Color(0xFFDC2626),
        if (!modelPlot) const Color(0xFF475569),
      ];
    }
    final ax = Rect.fromLTRB(62, 48, size.width - 20, size.height - 46);
    if (ax.width <= 0 || ax.height <= 0) return;
    var min = decode
            ? 0.0
            : arrays
                  .expand((x) => x)
                  .where((x) => x.isFinite)
                  .fold(0.0, math.min),
        max = decode
            ? 1.0
            : arrays
                  .expand((x) => x)
                  .where((x) => x.isFinite)
                  .fold(0.0, math.max);
    for (var k = 0; k < arrays.length && k < bands.length; k++) {
      if (!decode &&
          bands[k].length == times.length &&
          arrays[k].length == times.length) {
        for (var i = 0; i < times.length; i++) {
          min = math.min(min, arrays[k][i] - bands[k][i]);
          max = math.max(max, arrays[k][i] + bands[k][i]);
        }
      }
    }
    if (!decode) {
      for (final row in data['overlays'] as List? ?? []) {
        for (final value in erpNumbers(row).where((v) => v.isFinite)) {
          min = math.min(min, value);
          max = math.max(max, value);
        }
      }
    }
    final pad = decode ? 0.0 : math.max((max - min) * .1, .1);
    min -= pad;
    max += pad;
    if (max == min) max = min + 1;
    final xl = erpNumbers(data['x_limits']);
    final yl = erpNumbers(data['y_limits']);
    final xMin = xl.length == 2 && xl[1] > xl[0] ? xl[0] : times.first;
    final xMax = xl.length == 2 && xl[1] > xl[0] ? xl[1] : times.last;
    if (yl.length == 2 && yl[1] > yl[0]) {
      min = yl[0];
      max = yl[1];
    }
    double x(double t) => ax.left + (t - xMin) / (xMax - xMin) * ax.width;
    double y(double v) => negativeUp && !decode
        ? ax.top + (v - min) / (max - min) * ax.height
        : ax.bottom - (v - min) / (max - min) * ax.height;
    final grid = Paint()
      ..color = const Color(0xFFE2E8F0)
      ..strokeWidth = 1;
    for (var k = 0; k <= 5; k++) {
      final t = xMin + (xMax - xMin) * k / 5;
      canvas.drawLine(Offset(x(t), ax.top), Offset(x(t), ax.bottom), grid);
      erpText(
        canvas,
        '${(t * 1000).round()}',
        Offset(x(t) - 14, ax.bottom + 8),
        size: 10,
      );
      final v = min + (max - min) * k / 5;
      canvas.drawLine(Offset(ax.left, y(v)), Offset(ax.right, y(v)), grid);
      erpText(
        canvas,
        v.toStringAsFixed(decode ? 1 : 2),
        Offset(4, y(v) - 6),
        size: 10,
      );
    }
    if (xMin <= 0 && xMax >= 0) {
      erpText(
        canvas,
        '0 ms · event',
        Offset(x(0) + 4, ax.top - 16),
        size: 11,
        color: const Color(0xFF0F172A),
      );
    }
    if (!decode) {
      erpText(
        canvas,
        '0 µV',
        Offset(ax.right - 35, y(0) - 16),
        size: 10,
        color: const Color(0xFF0F172A),
      );
    }
    canvas.save();
    canvas.clipRect(ax);
    if (!decode && profile['window'] is List) {
      final w = erpNumbers(profile['window']);
      canvas.drawRect(
        Rect.fromLTRB(x(w[0]), ax.top, x(w[1]), ax.bottom),
        Paint()..color = const Color(0x147C3AED),
      );
    }
    if (xMin <= 0 && xMax >= 0)
      canvas.drawLine(
        Offset(x(0), ax.top),
        Offset(x(0), ax.bottom),
        Paint()
          ..color = const Color(0xFF334155)
          ..strokeWidth = 1.8,
      );
    canvas.drawLine(
      Offset(ax.left, y(decode ? 0.5 : 0)),
      Offset(ax.right, y(decode ? 0.5 : 0)),
      Paint()
        ..color = const Color(0xFF334155)
        ..strokeWidth = 1.8,
    );
    if (!decode) {
      for (var k = 0; k < arrays.length && k < bands.length; k++) {
        final band = bands[k];
        if (band.length != times.length || arrays[k].length != times.length)
          continue;
        final path = Path()
          ..moveTo(x(times.first), y(arrays[k].first - band.first));
        for (var i = 1; i < times.length; i++) {
          path.lineTo(x(times[i]), y(arrays[k][i] - band[i]));
        }
        for (var i = times.length - 1; i >= 0; i--) {
          path.lineTo(x(times[i]), y(arrays[k][i] + band[i]));
        }
        canvas.drawPath(
          path..close(),
          Paint()..color = colors[k].withValues(alpha: .13),
        );
      }
      for (final row in data['overlays'] as List? ?? []) {
        final values = erpNumbers(row);
        final path = Path();
        for (var i = 0; i < times.length && i < values.length; i++) {
          if (i == 0) {
            path.moveTo(x(times[i]), y(values[i]));
          } else {
            path.lineTo(x(times[i]), y(values[i]));
          }
        }
        canvas.drawPath(
          path,
          Paint()
            ..color = const Color(0x447C3AED)
            ..style = PaintingStyle.stroke
            ..strokeWidth = .8,
        );
      }
    }
    for (var k = 0; k < arrays.length; k++) {
      final path = Path();
      var started = false;
      for (var i = 0; i < math.min(times.length, arrays[k].length); i++) {
        final v = arrays[k][i];
        if (!v.isFinite) {
          started = false;
          continue;
        }
        if (started) {
          path.lineTo(x(times[i]), y(v));
        } else {
          path.moveTo(x(times[i]), y(v));
          started = true;
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = colors[k % colors.length]
          ..strokeWidth = (!decode && k == arrays.length - 1 && names.last.contains(' - ') ? 1.3 : 1.8)
          ..style = PaintingStyle.stroke,
      );
    }
    if (hoverX != null) {
      final t =
          xMin +
          ((hoverX! - ax.left) / ax.width).clamp(0.0, 1.0) * (xMax - xMin);
      canvas.drawLine(
        Offset(x(t), ax.top),
        Offset(x(t), ax.bottom),
        Paint()..color = const Color(0xFF7C3AED),
      );
      final i = times.indexWhere((v) => v >= t);
      if (i >= 0) {
        final values = [
          for (var k = 0; k < arrays.length; k++)
            if (k < names.length && i < arrays[k].length)
              '${names[k]}: ${arrays[k][i].toStringAsFixed(2)}',
        ];
        erpText(
          canvas,
          '${(t * 1000).round()} ms  ${values.join(' · ')}',
          Offset(ax.left + 8, ax.top + 6),
          size: 11,
          maxWidth: ax.width - 16,
        );
      }
    }
    canvas.restore();
    final itemWidth = math.max(80.0, (size.width - 80) / math.max(1, names.length));
    for (var k = 0; k < names.length; k++) {
      if (k < arrays.length && arrays[k].length == times.length) {
        erpText(
          canvas,
          names[k],
          Offset(65 + k * itemWidth, 10),
          size: 11,
          color: colors[k % colors.length],
          maxWidth: itemWidth - 6,
        );
      }
    }
    erpText(
      canvas,
      'Time (ms)',
      Offset(ax.center.dx - 30, size.height - 16),
      size: 11,
    );
    erpText(canvas, decode ? 'Score' : 'µV', const Offset(6, 27), size: 11);
  }

  @override
  bool shouldRepaint(covariant ErpWorkbenchWavePainter old) => true;
}

List<Map<String, dynamic>> extractErpConditionTopos(
  Map<String, dynamic> data, {
  List<Map<String, dynamic>>? files,
}) {
  final labels = (data['labels'] as List? ?? []).cast<String>();
  if (labels.isEmpty) return [];
  final profile = erpMap(data['profile']);
  final lateral = profile['lateralized'] == true;
  final condNames = (data['condition_names'] as List?)
          ?.map((e) => e.toString())
          .toList() ??
      [];
  final nameA = lateral
      ? 'Ipsilateral'
      : (condNames.isNotEmpty
          ? condNames.first
          : (profile['a_name']?.toString() ?? 'Condition A'));
  final nameB = lateral
      ? 'Contralateral'
      : (condNames.length > 1
          ? condNames[1]
          : (profile['b_name']?.toString() ?? 'Condition B'));

  List<double> windowMeanFromMatrix(dynamic matrix, List<double> times, List<double> win) {
    if (matrix is! List || times.isEmpty || win.length < 2) return [];
    final idx = <int>[
      for (var t = 0; t < times.length; t++)
        if (times[t] >= win[0] - 1e-9 && times[t] <= win[1] + 1e-9) t,
    ];
    if (idx.isEmpty) return [];
    final out = <double>[];
    for (final row in matrix) {
      final nums = erpNumbers(row);
      var sum = 0.0;
      var count = 0;
      for (final i in idx) {
        if (i < nums.length && nums[i].isFinite) {
          sum += nums[i];
          count++;
        }
      }
      out.add(count > 0 ? sum / count : 0.0);
    }
    return out;
  }

  List<double> resolveTopo(String key, String condName) {
    final direct = erpNumbers(data[key]);
    if (direct.length == labels.length) return direct;

    final times = erpNumbers(data['times']);
    final win = erpNumbers(profile['window']);
    final cc = data['channel_conditions'];
    if (cc is Map && cc[condName] is List) {
      final fromCc = windowMeanFromMatrix(cc[condName], times, win);
      if (fromCc.length == labels.length) return fromCc;
    }
    if (key == 'topo_a' && data['channel_a'] is List) {
      final fromA = windowMeanFromMatrix(data['channel_a'], times, win);
      if (fromA.length == labels.length) return fromA;
    }
    if (key == 'topo_b' && data['channel_b'] is List) {
      final fromB = windowMeanFromMatrix(data['channel_b'], times, win);
      if (fromB.length == labels.length) return fromB;
    }

    if (files != null && files.isNotEmpty) {
      final fileTopos = <List<double>>[];
      for (final f in files) {
        final fLabels = (f['labels'] as List? ?? []).cast<String>();
        final fVals = erpNumbers(f[key]);
        if (fVals.length == fLabels.length && fVals.isNotEmpty) {
          final aligned = <double>[];
          for (final l in labels) {
            final idx = fLabels.indexWhere(
              (fl) => fl.toUpperCase() == l.toUpperCase(),
            );
            aligned.add(idx >= 0 ? fVals[idx] : 0.0);
          }
          fileTopos.add(aligned);
        }
      }
      if (fileTopos.isNotEmpty) {
        return List<double>.generate(labels.length, (c) {
          var s = 0.0;
          for (final ft in fileTopos) {
            s += ft[c];
          }
          return s / fileTopos.length;
        });
      }
    }
    return [];
  }

  final topoA = resolveTopo('topo_a', nameA);
  final topoB = resolveTopo('topo_b', nameB);
  var topoDiff = erpNumbers(data['topo_difference']);
  if (topoDiff.length != labels.length &&
      topoA.length == labels.length &&
      topoB.length == labels.length) {
    topoDiff = [
      for (var i = 0; i < labels.length; i++) topoB[i] - topoA[i],
    ];
  }
  final pFwer = erpNumbers(data['topo_p_fwer']);

  double maxAbs(List<double> v) =>
      v.where((x) => x.isFinite).fold(0.01, (a, b) => math.max(a, b.abs()));
  final sharedCondScale = math.max(maxAbs(topoA), maxAbs(topoB));
  final diffScale = maxAbs(topoDiff);

  final out = <Map<String, dynamic>>[];
  if (topoA.length == labels.length) {
    out.add({
      'key': 'topo_a',
      'title': '$nameA (µV)',
      'values': topoA,
      'scale': sharedCondScale,
      'p_fwer': const <double>[],
      'is_diff': false,
    });
  }
  if (topoB.length == labels.length) {
    out.add({
      'key': 'topo_b',
      'title': '$nameB (µV)',
      'values': topoB,
      'scale': sharedCondScale,
      'p_fwer': const <double>[],
      'is_diff': false,
    });
  }
  // Additional conditions beyond A and B if present
  if (condNames.length > 2 && data['channel_conditions'] is Map) {
    final times = erpNumbers(data['times']);
    final win = erpNumbers(profile['window']);
    final cc = data['channel_conditions'] as Map;
    for (var i = 2; i < condNames.length; i++) {
      final cName = condNames[i];
      final vals = windowMeanFromMatrix(cc[cName], times, win);
      if (vals.length == labels.length) {
        out.add({
          'key': 'cond_$i',
          'title': '$cName (µV)',
          'values': vals,
          'scale': math.max(sharedCondScale, maxAbs(vals)),
          'p_fwer': const <double>[],
          'is_diff': false,
        });
      }
    }
  }
  if (topoDiff.length == labels.length) {
    out.add({
      'key': 'topo_difference',
      'title': '$nameB − $nameA (µV)',
      'values': topoDiff,
      'scale': diffScale,
      'p_fwer': pFwer,
      'is_diff': true,
    });
  }
  return out;
}

class ErpWorkbenchTopoPainter extends CustomPainter {
  ErpWorkbenchTopoPainter(
    this.data, {
    this.valueKey = 'topo_difference',
    this.customTitle,
    this.valuesOverride,
    this.scaleOverride,
    this.showPValues = true,
    this.selectedChannels = const {},
  });
  final Map<String, dynamic> data;
  final String valueKey;
  final String? customTitle;
  final List<double>? valuesOverride;
  final double? scaleOverride;
  final bool showPValues;
  final Set<String> selectedChannels;

  @override
  void paint(Canvas c, Size size) {
    c.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFFFFFFF));
    final labels = (data['labels'] as List? ?? []).cast<String>();
    final values = valuesOverride ?? erpNumbers(data[valueKey]);
    final p = showPValues ? erpNumbers(data['topo_p_fwer']) : const <double>[];
    final known = {
      for (final name in kStandard1020Topo.keys) name.toUpperCase(): name,
    };
    final indices = [
      for (var i = 0; i < labels.length; i++)
        if (known.containsKey(labels[i].toUpperCase()) && i < values.length) i,
    ];
    if (indices.length < 4) {
      erpText(
        c,
        'Topography needs at least four channels with known positions.',
        const Offset(12, 20),
        maxWidth: size.width - 24,
      );
      return;
    }
    final ch = [for (final i in indices) known[labels[i].toUpperCase()]!];
    final v = [for (final i in indices) values[i]];
    final double scale = scaleOverride ??
        v.where((x) => x.isFinite).fold<double>(.01, (a, b) => math.max(a, b.abs()));
    final selUpper = selectedChannels.map((s) => s.toUpperCase()).toSet();
    final highlightList = p.length == labels.length
        ? [for (final i in indices) p[i] <= .05]
        : (selUpper.isNotEmpty
            ? [for (final i in indices) selUpper.contains(labels[i].toUpperCase())]
            : null);

    paintTopomap(
      c,
      Rect.fromLTWH(4, 22, size.width - 68, size.height - 38),
      TopoInterpolator.forChannels(ch),
      v,
      vmin: -scale,
      vmax: scale,
      cmap: 'RdBu_r',
      highlight: highlightList,
      fittedHead: true,
      contours: true,
    );
    final profile = erpMap(data['profile']);
    final defaultTitle = customTitle ??
        (valueKey == 'topo_a'
            ? '${profile['a_name'] ?? 'Condition A'} (µV)'
            : valueKey == 'topo_b'
                ? '${profile['b_name'] ?? 'Condition B'} (µV)'
                : '${profile['b_name'] ?? 'B'} − ${profile['a_name'] ?? 'A'} (µV)');
    erpText(
      c,
      defaultTitle,
      const Offset(10, 4),
      size: 11.5,
      color: const Color(0xFF0F172A),
      maxWidth: size.width - 20,
    );
    final bar = Rect.fromLTWH(
      size.width - 54,
      size.height * .24,
      9,
      size.height * .52,
    );
    paintColorbar(c, bar, cmap: 'RdBu_r');
    erpText(
      c,
      scale.toStringAsFixed(2),
      Offset(bar.right + 4, bar.top - 5),
      size: 9,
      maxWidth: 44,
    );
    erpText(
      c,
      '0',
      Offset(bar.right + 4, bar.center.dy - 5),
      size: 9,
      maxWidth: 44,
    );
    erpText(
      c,
      (-scale).toStringAsFixed(2),
      Offset(bar.right + 4, bar.bottom - 5),
      size: 9,
      maxWidth: 44,
    );
    if (p.isNotEmpty) {
      erpText(
        c,
        'Rings: pFWER ≤ .05',
        Offset(10, size.height - 16),
        size: 9.5,
      );
    }
  }

  @override
  bool shouldRepaint(covariant ErpWorkbenchTopoPainter old) =>
      old.data != data ||
      old.valueKey != valueKey ||
      old.customTitle != customTitle ||
      old.scaleOverride != scaleOverride ||
      old.selectedChannels != selectedChannels;
}

class ErpWorkbenchHeatPainter extends CustomPainter {
  ErpWorkbenchHeatPainter(
    this.values,
    this.rows,
    this.columns, {
    this.probability = false,
  });
  final List<double> values;
  final int rows, columns;
  final bool probability;
  @override
  void paint(Canvas c, Size size) {
    c.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFFFFFFF));
    if (rows <= 0 || columns <= 0) return;
    final scale = values
        .where((v) => v.isFinite)
        .fold(.01, (a, b) => math.max(a, b.abs()));
    for (var i = 0; i < rows; i++) {
      for (var j = 0; j < columns; j++) {
        final k = i * columns + j;
        if (k >= values.length) continue;
        final v = values[k];
        final q = probability ? (v - .5) * 2 : v / scale;
        final color = !v.isFinite
            ? const Color(0xFFE2E8F0)
            : q >= 0
            ? Color.lerp(
                const Color(0xFFFFFFFF),
                const Color(0xFFDC2626),
                q.abs().clamp(0.0, 1.0),
              )!
            : Color.lerp(
                const Color(0xFFFFFFFF),
                const Color(0xFF2563EB),
                q.abs().clamp(0.0, 1.0),
              )!;
        c.drawRect(
          Rect.fromLTWH(
            j * size.width / columns,
            i * size.height / rows,
            size.width / columns + .5,
            size.height / rows + .5,
          ),
          Paint()..color = color,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant ErpWorkbenchHeatPainter old) => true;
}

Future<Uint8List> erpPainterPng(
  CustomPainter painter, {
  int width = 1200,
  int height = 450,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  painter.paint(canvas, Size(width.toDouble(), height.toDouble()));
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return bytes!.buffer.asUint8List();
}
