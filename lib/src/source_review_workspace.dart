import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'models.dart';
import 'recording_loader.dart';
import 'eeg_viewer.dart';
import 'topostats/topo_interp.dart';
import 'topostats/topo_paint.dart';
import 'topostats/mpl_colormaps.dart';

/// Summarize a point or a half-open time window without crossing trial boundaries.
List<double> spatialValues(
  EegRecording rec,
  double time,
  double span,
  String statistic,
  int trial, {
  List<TraceStandardization>? standardization,
}) {
  final points = rec.isEpoched ? rec.pointsPerEpoch! : rec.sampleCount;
  final base = rec.isEpoched ? trial.clamp(0, rec.epochCount - 1) * points : 0;
  final first = (time * rec.sampleRate).floor().clamp(0, points - 1);
  final end = statistic == 'point'
      ? first + 1
      : ((time + span) * rec.sampleRate).ceil().clamp(first + 1, points);
  return [
    for (var channel = 0; channel < rec.preview.length; channel++)
      () {
        final ch = rec.preview[channel];
        final scale = standardization?[channel];
        double value(int i) => (ch[i] - (scale?.mean ?? 0)) / (scale?.sd ?? 1);
        if (ch.length < base + end) return double.nan;
        if (statistic == 'point') return value(base + first);
        var sum = 0.0;
        for (var i = base + first; i < base + end; i++) {
          final v = value(i);
          sum += statistic == 'rms' ? v * v : v;
        }
        final mean = sum / (end - first);
        return statistic == 'rms' ? math.sqrt(mean) : mean;
      }(),
  ];
}

class TraceStandardization {
  const TraceStandardization(this.mean, this.sd);
  final double mean, sd;
}

List<TraceStandardization> traceStandardization(EegRecording rec, int trial) {
  final points = rec.isEpoched ? rec.pointsPerEpoch! : rec.sampleCount;
  final base = rec.isEpoched ? trial * points : 0;
  return [
    for (final ch in rec.preview)
      () {
        var mean = 0.0, m2 = 0.0;
        var count = 0;
        for (var i = base; i < base + points; i++) {
          count++;
          final delta = ch[i] - mean;
          mean += delta / count;
          m2 += delta * (ch[i] - mean);
        }
        final sd = math.sqrt(m2 / math.max(1, count));
        return TraceStandardization(mean, sd > 1e-12 ? sd : 1);
      }(),
  ];
}

Color sourceLabelColor(String label) {
  final hash = label.codeUnits.fold<int>(
    0,
    (a, b) => (a * 31 + b) & 0x7fffffff,
  );
  return HSLColor.fromAHSL(1, (hash % 360).toDouble(), .65, .40).toColor();
}

class SourceReviewWorkspace extends StatefulWidget {
  const SourceReviewWorkspace({
    super.key,
    required this.channels,
    required this.sources,
    this.customAtlas = false,
    this.atlasGeometry,
    this.controls,
    this.showSidePanel = true,
  });
  final EegRecording? channels, sources;
  final bool customAtlas;
  final Widget? controls;
  final bool showSidePanel;
  final Future<Map<String, dynamic>>? atlasGeometry;
  @override
  State<SourceReviewWorkspace> createState() => _SourceReviewWorkspaceState();
}

class _SourceReviewWorkspaceState extends State<SourceReviewWorkspace> {
  bool sourceMode = false, headExpanded = true;
  String statistic = 'point';
  double time = 0, span = 1;
  int trial = 0;
  bool normalized = false;
  final Map<String, List<TraceStandardization>> scales = {};
  final Map<String, double> limits = {};
  final Set<String> chosen = {};
  late final Future<Map<String, dynamic>> geometry =
      widget.atlasGeometry ??
      rootBundle
          .loadString('assets/source_review_geometry.json')
          .then((v) => jsonDecode(v) as Map<String, dynamic>);
  final Map<String, Future<EegRecording>> full = {};
  @override
  void initState() {
    super.initState();
    sourceMode = widget.sources != null;
  }

  @override
  void didUpdateWidget(covariant SourceReviewWorkspace old) {
    super.didUpdateWidget(old);
    if (widget.sources?.path != old.sources?.path) {
      if (old.sources != null) full.remove(old.sources!.path);
      sourceMode = widget.sources != null;
      chosen.clear();
    }
    if (widget.channels?.path != old.channels?.path) {
      time = 0;
      trial = 0;
      chosen.clear();
      full.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final recording = sourceMode ? widget.sources : widget.channels;
    if (recording == null)
      return Row(
        children: [
          if (widget.controls != null)
            SizedBox(
              width: 320,
              child: SingleChildScrollView(child: widget.controls!),
            ),
          const Expanded(
            child: Center(
              child: Text('Open channel EEG, then apply a source projection.'),
            ),
          ),
        ],
      );
    final duration = recording.isEpoched
        ? recording.epochDurationSeconds
        : recording.durationSeconds;
    final maxTime = math.max(0.0, duration - 1 / recording.sampleRate);
    final t = time.clamp(0.0, maxTime),
        epoch = trial.clamp(0, recording.epochCount - 1);
    final unit = normalized
        ? 'z'
        : sourceMode
        ? 'ROI model units'
        : 'µV';
    return FutureBuilder<Map<String, dynamic>>(
      future: geometry,
      builder: (context, atlasSnap) {
        final atlas = atlasSnap.data;
        final colors = <String, Color>{
          for (final label in recording.labels) label: sourceLabelColor(label),
        };
        if (sourceMode && !widget.customAtlas)
          for (final r in atlas?['regions'] as List? ?? []) {
            final c = (r['color'] as List).cast<int>();
            final base = HSLColor.fromColor(
              Color.fromARGB(255, c[0], c[1], c[2]),
            );
            colors[r['name'] as String] = base
                .withLightness((base.lightness + .12).clamp(.45, .65))
                .toColor();
          }
        Widget spatialPanel = FutureBuilder<EegRecording>(
          future: full.putIfAbsent(
            recording.path,
            () => RecordingLoader().loadFull(recording),
          ),
          builder: (context, snapshot) {
            if (snapshot.hasError)
              return Text('Head plot unavailable: ${snapshot.error}');
            if (!snapshot.hasData)
              return const Padding(
                padding: EdgeInsets.all(20),
                child: Center(child: CircularProgressIndicator()),
              );
            final data = snapshot.data!;
            final standard = normalized
                ? scales.putIfAbsent(
                    '${data.path}:$epoch',
                    () => traceStandardization(data, epoch),
                  )
                : null;
            final values = spatialValues(
              data,
              t,
              span,
              statistic,
              epoch,
              standardization: standard,
            );
            final limit = normalized
                ? 3.0
                : limits.putIfAbsent('${data.path}:$epoch', () {
                    final sampled = <double>[];
                    final points = data.isEpoched
                        ? data.pointsPerEpoch!
                        : data.sampleCount;
                    final base = data.isEpoched ? epoch * points : 0;
                    final stride = math.max(1, (points / 2000).ceil());
                    for (final ch in data.preview)
                      for (var i = base; i < base + points; i += stride)
                        sampled.add(ch[i].abs());
                    sampled.sort();
                    return math.max(
                      1e-12,
                      sampled[(sampled.length * .99).floor().clamp(
                        0,
                        sampled.length - 1,
                      )],
                    );
                  });
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height: sourceMode ? 330 : 260,
                  child: sourceMode
                      ? widget.customAtlas
                            ? const Center(
                                child: Text(
                                  'Custom atlas geometry was not supplied. ROI waveforms are available.',
                                ),
                              )
                            : atlas == null
                            ? Center(
                                child: atlasSnap.hasError
                                    ? const Text('Atlas geometry unavailable')
                                    : const CircularProgressIndicator(),
                              )
                            : _GlassBrain(
                                atlas: atlas,
                                labels: data.labels,
                                values: values,
                                colors: colors,
                                chosen: chosen,
                                limit: limit,
                                rms: statistic == 'rms',
                                compact: true,
                                onSelect: (name) => setState(() {
                                  if (!chosen.add(name)) chosen.remove(name);
                                }),
                              )
                      : _ScalpMap(
                          labels: data.labels,
                          values: values,
                          rms: statistic == 'rms',
                          limit: limit,
                          unit: unit,
                        ),
                ),
                _AmplitudeLegend(
                  limit: limit,
                  rms: statistic == 'rms',
                  unit: unit,
                ),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text(
                    sourceMode ? 'ROI values & selection' : 'Channel values',
                    style: const TextStyle(fontSize: 12),
                  ),
                  children: [
                    if (sourceMode)
                      TextButton(
                        onPressed: () => setState(chosen.clear),
                        child: const Text('Show all ROIs'),
                      ),
                    SizedBox(
                      height: 220,
                      child: ListView.builder(
                        itemCount: data.labels.length,
                        itemBuilder: (_, i) => sourceMode
                            ? CheckboxListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                value:
                                    chosen.isEmpty ||
                                    chosen.contains(data.labels[i]),
                                activeColor: colors[data.labels[i]],
                                title: Text(
                                  data.labels[i],
                                  style: TextStyle(
                                    color: colors[data.labels[i]],
                                    fontSize: 11,
                                  ),
                                ),
                                subtitle: Text(
                                  '${values[i].toStringAsPrecision(4)} $unit',
                                  style: const TextStyle(fontSize: 11),
                                ),
                                onChanged: (_) => setState(() {
                                  if (chosen.isEmpty) {
                                    chosen.add(data.labels[i]);
                                  } else if (!chosen.add(data.labels[i])) {
                                    chosen.remove(data.labels[i]);
                                  }
                                }),
                              )
                            : ListTile(
                                dense: true,
                                title: Text(
                                  data.labels[i],
                                  style: TextStyle(
                                    color: colors[data.labels[i]],
                                    fontSize: 11,
                                  ),
                                ),
                                trailing: Text(
                                  '${values[i].toStringAsPrecision(4)} $unit',
                                  style: const TextStyle(fontSize: 11),
                                ),
                              ),
                      ),
                    ),
                  ],
                ),
                Text(
                  normalized
                      ? 'Fixed ±3 z scale for channel/source pattern comparison; standardized against each trace over this recording or trial. Waveforms retain their original units.'
                      : sourceMode
                      ? 'Source values are inverse-model amplitudes, not scalp voltages. Use standardized patterns to compare channel/source distributions.'
                      : 'Scalp amplitudes in µV. The colour range stays fixed while navigating this recording/trial.',
                  style: const TextStyle(
                    fontSize: 10,
                    color: Color(0xFF94A3B8),
                  ),
                ),
                if (sourceMode)
                  const Padding(
                    padding: EdgeInsets.only(top: 6),
                    child: Text(
                      'fsaverage/aparc template. Orthogonal projected ROI boundaries; outline/trace = ROI identity, fill = amplitude. Not an individual MRI.',
                      style: TextStyle(fontSize: 10, color: Color(0xFF94A3B8)),
                    ),
                  ),
              ],
            );
          },
        );
        final waveform = EegViewer(
          recording: recording,
          selection: ViewerSelection(
            selectedChannels: sourceMode ? chosen.toList() : const [],
            acceptedIntervals: const [],
            rejectedIntervals: const [],
          ),
          onSelectionChanged: (v) {
            if (sourceMode &&
                (chosen.isNotEmpty || v.selectedChannels.isNotEmpty))
              setState(() {
                chosen
                  ..clear()
                  ..addAll(v.selectedChannels);
              });
          },
          autoscaleByDefault: sourceMode,
          traceColors: colors,
          cursorSeconds: epoch * duration + t,
          highlightWindowSeconds: statistic == 'point'
              ? 0
              : math.min(span, duration - t),
          onTimeSelected: (absolute) => setState(() {
            trial = recording.isEpoched
                ? (absolute / duration).floor().clamp(
                    0,
                    recording.epochCount - 1,
                  )
                : 0;
            time = recording.isEpoched ? absolute - trial * duration : absolute;
          }),
        );
        return Row(
          children: [
            if (widget.showSidePanel) ...[
              SizedBox(
                key: const ValueKey('source-spatial-side-panel'),
                width: 320,
                child: Material(
                  color: const Color(0xFF0A1628),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(10, 6, 10, 12),
                    children: [
                      if (widget.controls != null) widget.controls!,
                      const Divider(),
                      SegmentedButton<bool>(
                        segments: [
                          const ButtonSegment(
                            value: false,
                            label: Text('Channels'),
                          ),
                          ButtonSegment(
                            value: true,
                            label: const Text('Source / ROIs'),
                            enabled: widget.sources != null,
                          ),
                        ],
                        selected: {sourceMode},
                        onSelectionChanged: (v) => setState(() {
                          sourceMode = v.single;
                          chosen.clear();
                        }),
                      ),
                      const SizedBox(height: 8),
                      SwitchListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                          'Standardized patterns (z)',
                          style: TextStyle(fontSize: 12),
                        ),
                        value: normalized,
                        onChanged: (v) => setState(() => normalized = v),
                      ),
                      DropdownButtonFormField<String>(
                        initialValue: statistic,
                        decoration: const InputDecoration(
                          labelText: 'Head-plot statistic',
                          isDense: true,
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'point',
                            child: Text('Time point'),
                          ),
                          DropdownMenuItem(
                            value: 'mean',
                            child: Text('Window mean'),
                          ),
                          DropdownMenuItem(
                            value: 'rms',
                            child: Text('Window RMS'),
                          ),
                        ],
                        onChanged: (v) => setState(() => statistic = v!),
                      ),
                      if (statistic != 'point')
                        DropdownButtonFormField<double>(
                          initialValue: span,
                          decoration: const InputDecoration(
                            labelText: 'Window duration',
                            isDense: true,
                          ),
                          items: [
                            for (final v in [
                              .1,
                              .5,
                              1.0,
                              2.0,
                              5.0,
                              10.0,
                              20.0,
                              30.0,
                            ])
                              DropdownMenuItem(value: v, child: Text('$v s')),
                          ],
                          onChanged: (v) => setState(() => span = v!),
                        ),
                      const SizedBox(height: 8),
                      TextFormField(
                        key: ValueKey(
                          'source-clock-${t.toStringAsFixed(3)}-$epoch',
                        ),
                        initialValue: (t + (recording.epochTmin ?? 0))
                            .toStringAsFixed(3),
                        decoration: const InputDecoration(
                          labelText: 'Linked waveform cursor (s)',
                          isDense: true,
                        ),
                        onFieldSubmitted: (v) {
                          final next = double.tryParse(v);
                          if (next != null)
                            setState(
                              () => time = (next - (recording.epochTmin ?? 0))
                                  .clamp(0.0, maxTime),
                            );
                        },
                      ),
                      if (statistic != 'point')
                        Text(
                          'Interval: ${(t + (recording.epochTmin ?? 0)).toStringAsFixed(3)} – ${(math.min(duration, t + span) + (recording.epochTmin ?? 0)).toStringAsFixed(3)} s',
                          style: const TextStyle(fontSize: 11),
                        ),
                      if (recording.isEpoched)
                        Row(
                          children: [
                            IconButton(
                              tooltip: 'Previous review trial',
                              onPressed: epoch > 0
                                  ? () => setState(() {
                                      trial--;
                                      time = 0;
                                    })
                                  : null,
                              icon: const Icon(Icons.skip_previous),
                            ),
                            Expanded(
                              child: Text(
                                'Trial ${epoch + 1} / ${recording.epochCount}',
                                textAlign: TextAlign.center,
                              ),
                            ),
                            IconButton(
                              tooltip: 'Next review trial',
                              onPressed: epoch + 1 < recording.epochCount
                                  ? () => setState(() {
                                      trial++;
                                      time = 0;
                                    })
                                  : null,
                              icon: const Icon(Icons.skip_next),
                            ),
                          ],
                        ),
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 6),
                        child: Text(
                          'Use the waveform overview to navigate; click a trace to set the cursor.',
                          style: TextStyle(
                            fontSize: 10,
                            color: Color(0xFF94A3B8),
                          ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () =>
                            setState(() => headExpanded = !headExpanded),
                        icon: Icon(
                          headExpanded ? Icons.expand_less : Icons.expand_more,
                        ),
                        label: Text(
                          sourceMode ? 'Glass brain' : 'Scalp topoplot',
                        ),
                      ),
                      if (headExpanded) spatialPanel,
                    ],
                  ),
                ),
              ),
              const VerticalDivider(width: 1, color: Color(0x1FFFFFFF)),
            ],
            Expanded(
              key: const ValueKey('source-full-height-waveform'),
              child: waveform,
            ),
          ],
        );
      },
    );
  }
}

class _AmplitudeLegend extends StatelessWidget {
  const _AmplitudeLegend({
    required this.limit,
    required this.rms,
    required this.unit,
  });
  final double limit;
  final bool rms;
  final String unit;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Container(
        height: 9,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              for (var i = 0; i <= 8; i++)
                _amplitudeColor(
                  rms ? limit * i / 8 : -limit + 2 * limit * i / 8,
                  limit,
                  rms,
                ),
            ],
          ),
        ),
      ),
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            '${rms ? '0' : (-limit).toStringAsPrecision(3)} $unit',
            style: const TextStyle(fontSize: 10),
          ),
          Text(
            '${limit.toStringAsPrecision(3)} $unit',
            style: const TextStyle(fontSize: 10),
          ),
        ],
      ),
    ],
  );
}

class _ScalpMap extends StatelessWidget {
  const _ScalpMap({
    required this.labels,
    required this.values,
    required this.rms,
    required this.limit,
    required this.unit,
  });
  final List<String> labels;
  final List<double> values;
  final bool rms;
  final double limit;
  final String unit;
  @override
  Widget build(BuildContext context) {
    final ids = [
      for (var i = 0; i < labels.length; i++)
        if (isStandard1020Channel(labels[i])) i,
    ];
    if (ids.length < 4)
      return const Center(
        child: Text(
          'At least four channels with standard scalp positions are needed.',
        ),
      );
    try {
      return CustomPaint(
        painter: _ScalpPainter(
          TopoInterpolator.forChannels([for (final i in ids) labels[i]]),
          [for (final i in ids) values[i]],
          rms,
          limit,
          unit,
        ),
        child: const SizedBox.expand(),
      );
    } catch (e) {
      return Center(child: Text('Scalp geometry unavailable: $e'));
    }
  }
}

class _ScalpPainter extends CustomPainter {
  _ScalpPainter(this.interp, this.values, this.rms, this.limit, this.unit);
  final TopoInterpolator interp;
  final List<double> values;
  final bool rms;
  final double limit;
  final String unit;
  @override
  void paint(Canvas canvas, Size size) {
    paintTopomap(
      canvas,
      Rect.fromLTWH(0, 0, size.width, size.height - 22),
      interp,
      values,
      vmin: rms ? 0 : -limit,
      vmax: limit,
      cmap: rms ? 'viridis' : 'RdBu_r',
    );
    _text(
      canvas,
      '${rms ? '0' : (-limit).toStringAsPrecision(3)} … ${limit.toStringAsPrecision(3)} $unit',
      Offset(10, size.height - 20),
      Colors.white70,
      11,
    );
  }

  @override
  bool shouldRepaint(_ScalpPainter old) => true;
}

class _GlassBrain extends StatelessWidget {
  const _GlassBrain({
    required this.atlas,
    required this.labels,
    required this.values,
    required this.colors,
    required this.chosen,
    required this.onSelect,
    required this.limit,
    this.compact = false,
    this.rms = false,
  });
  final Map<String, dynamic> atlas;
  final List<String> labels;
  final List<double> values;
  final Map<String, Color> colors;
  final Set<String> chosen;
  final ValueChanged<String> onSelect;
  final double limit;
  final bool compact;
  final bool rms;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final width = compact ? box.maxWidth / 2 : box.maxWidth / 3,
          height = compact ? box.maxHeight / 2 : box.maxHeight;
      return Wrap(
        children: [
          for (var view = 0; view < 3; view++)
            SizedBox(
              width: width,
              height: height,
              child: GestureDetector(
                onTapDown: (d) {
                  String? nearest;
                  double distance = double.infinity;
                  for (final region in (atlas['regions'] as List).cast<Map>()) {
                    final name = region['name'] as String;
                    if (!labels.contains(name)) continue;
                    final point = _project(
                      (region['centers'] as List)[view] as List,
                      Size(width, height),
                    );
                    final delta = (point - d.localPosition).distance;
                    if (delta < distance) {
                      distance = delta;
                      nearest = name;
                    }
                  }
                  if (nearest != null && distance < 25) onSelect(nearest);
                },
                child: CustomPaint(
                  painter: _BrainPainter(
                    atlas,
                    view,
                    labels,
                    values,
                    colors,
                    chosen,
                    limit,
                    rms,
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
        ],
      );
    },
  );
}

Offset _project(List p, Size size) {
  final scale = math.min((size.width - 20) / 220, (size.height - 50) / 220);
  return Offset(
    size.width / 2 + (p[0] as num) * scale,
    size.height / 2 + 10 - (p[1] as num) * scale,
  );
}

class _BrainPainter extends CustomPainter {
  _BrainPainter(
    this.atlas,
    this.view,
    this.labels,
    this.values,
    this.colors,
    this.chosen,
    this.limit,
    this.rms,
  );
  final Map<String, dynamic> atlas;
  final int view;
  final List<String> labels;
  final List<double> values;
  final Map<String, Color> colors;
  final Set<String> chosen;
  final double limit;
  final bool rms;
  @override
  void paint(Canvas canvas, Size size) {
    void line(List points, Paint paint) {
      if (points.isEmpty) return;
      final path = Path();
      for (var i = 0; i < points.length; i++) {
        final p = _project(points[i] as List, size);
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      canvas.drawPath(path, paint);
    }

    _text(
      canvas,
      (atlas['views'] as List)[view] as String,
      const Offset(8, 0),
      Colors.white,
      12,
    );
    line(
      (atlas['shells'] as List)[view] as List,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = Colors.white54
        ..strokeWidth = 1.2,
    );
    for (final r in (atlas['regions'] as List).cast<Map>()) {
      final name = r['name'] as String, idx = labels.indexOf(name);
      if (idx < 0) continue;
      final selected = chosen.isEmpty || chosen.contains(name),
          color = colors[name] ?? Colors.grey;
      for (final points in (r['outlines'] as List)[view] as List) {
        line(
          points as List,
          Paint()
            ..style = PaintingStyle.stroke
            ..color = color.withValues(alpha: selected ? 0.65 : 0.08)
            ..strokeWidth = chosen.contains(name) ? 1.7 : .6,
        );
      }
      if (selected) {
        final amount = (values[idx] / limit).clamp(-1.0, 1.0);
        final activity = _amplitudeColor(values[idx], limit, rms);
        canvas.drawCircle(
          _project((r['centers'] as List)[view] as List, size),
          3 + amount.abs() * 4,
          Paint()..color = activity.withValues(alpha: .75),
        );
      }
    }
    _text(
      canvas,
      view == 0 ? 'A ← → P' : 'L ← → R',
      Offset(8, size.height - 30),
      Colors.white54,
      10,
    );
    if (view == 2)
      _text(canvas, 'A ↑', const Offset(8, 17), Colors.white54, 10);
    _text(
      canvas,
      '± ${limit.toStringAsPrecision(3)}',
      Offset(8, size.height - 16),
      Colors.white54,
      10,
    );
  }

  @override
  bool shouldRepaint(_BrainPainter old) => true;
}

void _text(
  Canvas canvas,
  String text,
  Offset position,
  Color color,
  double size,
) {
  final p = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(color: color, fontSize: size, fontFamily: 'DejaVuSans'),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  p.paint(canvas, position);
}

Color _amplitudeColor(double value, double limit, bool rms) {
  final lut = kMplColormaps[rms ? 'viridis' : 'RdBu_r']!;
  final fraction = rms
      ? (value / limit).clamp(0.0, 1.0)
      : ((value / limit + 1) / 2).clamp(0.0, 1.0);
  return Color(lut[(fraction * 255).round().clamp(0, 255)]);
}
