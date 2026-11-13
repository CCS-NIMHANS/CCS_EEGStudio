import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'models.dart';
import 'topostats/topo_interp.dart';
import 'topostats/topo_paint.dart';

Map<String, dynamic> _map(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : {};
Map<String, dynamic> icaReviewReport(EegRecording rec) =>
    _map(_map(_map(rec.provenance['summary'])['ica'])['ica']);

String icaOcularOutcome(EegRecording rec) {
  final report = icaReviewReport(rec);
  final stage = _map(report['blink_stage']);
  if (stage['ran'] != true) return 'Eye / ECG ICA did not run';
  final removed = stage['removed'] as List? ?? [];
  return '${report['blink_events'] ?? 0} blink events · ${removed.length} ocular components removed';
}

Widget icaOcularDiagnostic(EegRecording rec) {
  final report = icaReviewReport(rec),
      stage = _map(icaReviewReport(rec)['blink_stage']);
  if (stage['ran'] != true) return const SizedBox.shrink();
  final review = _map(stage['review']),
      criteria = _map(_map(stage['review'])['criteria']);
  final classes = (review['class_names'] as List? ?? []).cast<String>();
  final eye = classes.indexOf('Eye');
  var best = 0.0;
  if (eye >= 0)
    for (final row in review['probabilities'] as List? ?? []) {
      best = math.max(best, ((row as List)[eye] as num).toDouble());
    }
  final cutoff = (criteria['applied_threshold'] as num?)?.toDouble();
  final none = (stage['removed'] as List? ?? []).isEmpty;
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Text(
      '${icaOcularOutcome(rec)}. Strongest Eye score ${(100 * best).toStringAsFixed(1)}%${cutoff == null ? '' : '; tested threshold ${(100 * cutoff).toStringAsFixed(1)}%'}.${none && (report['blink_events'] as num? ?? 0) > 0 ? ' Blink detection does not mean removal: review the candidate component and threshold.' : ''}',
      style: TextStyle(fontSize: 12, color: none ? Colors.orange : null),
    ),
  );
}

Future<void> showIcaReview(BuildContext context, EegRecording rec) =>
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        child: SizedBox(
          width: 940,
          height: 700,
          child: _IcaReview(recording: rec),
        ),
      ),
    );

class _IcaReview extends StatefulWidget {
  const _IcaReview({required this.recording});
  final EegRecording recording;
  @override
  State<_IcaReview> createState() => _IcaReviewState();
}

class _IcaReviewState extends State<_IcaReview> {
  String stage = 'blink_stage';
  int component = 0;
  @override
  Widget build(BuildContext context) {
    final report = icaReviewReport(widget.recording);
    final s = _map(report[stage]);
    final review = _map(s['review']);
    final probabilities = review['probabilities'] as List? ?? [];
    final traces = review['traces'] as List? ?? [];
    final classes = (review['class_names'] as List? ?? []).cast<String>();
    final labels = (report['channels_used'] as List? ?? []).cast<String>();
    final mixing = review['mixing'] as List? ?? [];
    final removed = s['removed'] as List? ?? [];
    final count = probabilities.length;
    final ic = component.clamp(0, math.max(0, count - 1)).toInt();
    final scores = count == 0
        ? <double>[]
        : (probabilities[ic] as List)
              .map((v) => (v as num).toDouble())
              .toList();
    final values = [
      for (final row in mixing) ((row as List)[ic] as num).toDouble(),
    ];
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'ICA component review',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
              ),
              IconButton(
                tooltip: 'Close',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
          const Text(
            'Inspect retained and removed components. ICLabel scores are model estimates; review the map and trace together.',
          ),
          icaOcularDiagnostic(widget.recording),
          const SizedBox(height: 12),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                value: 'blink_stage',
                label: Text('Eye / ECG stage'),
              ),
              ButtonSegment(
                value: 'other_stage',
                label: Text('General artifact stage'),
              ),
            ],
            selected: {stage},
            onSelectionChanged: (v) => setState(() {
              stage = v.single;
              component = 0;
            }),
          ),
          const SizedBox(height: 12),
          if (count == 0)
            Expanded(
              child: Center(
                child: Text(
                  s['ran'] == true
                      ? 'Component details were not retained in this older recording. Run ICA again to enable review.'
                      : 'This stage did not run. ${s['note'] ?? ''}',
                ),
              ),
            )
          else
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: 160,
                    child: ListView.builder(
                      itemCount: count,
                      itemBuilder: (_, i) => ListTile(
                        selected: i == ic,
                        title: Text('IC ${i + 1}'),
                        subtitle: Text(
                          removed.contains(i + 1) ? 'Removed' : 'Retained',
                        ),
                        leading: Icon(
                          removed.contains(i + 1)
                              ? Icons.remove_circle_outline
                              : Icons.check_circle_outline,
                          size: 18,
                        ),
                        onTap: () => setState(() => component = i),
                      ),
                    ),
                  ),
                  const VerticalDivider(),
                  Expanded(
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            'IC ${ic + 1} · ${removed.contains(ic + 1) ? 'Removed from output' : 'Retained in output'}',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 18,
                            ),
                          ),
                          _RemovalCriterion(
                            criteria: _map(review['criteria']),
                            classes: classes,
                            scores: scores,
                            removed: removed.contains(ic + 1),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SizedBox(
                                width: 230,
                                height: 240,
                                child: _ComponentMap(
                                  labels: labels,
                                  values: values,
                                ),
                              ),
                              const SizedBox(width: 18),
                              Expanded(
                                child: Column(
                                  children: [
                                    for (var i = 0; i < scores.length; i++)
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 4,
                                        ),
                                        child: Column(
                                          children: [
                                            Row(
                                              children: [
                                                Expanded(
                                                  child: Text(classes[i]),
                                                ),
                                                Text(
                                                  '${(scores[i] * 100).toStringAsFixed(1)}%',
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 3),
                                            LinearProgressIndicator(
                                              value: scores[i].clamp(0, 1),
                                            ),
                                          ],
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          const Text('Component activation · arbitrary units'),
                          if (ic < traces.length)
                            _ComponentTimeline(
                              key: ValueKey('$stage-$ic'),
                              values: (traces[ic] as List).cast<num>(),
                              rate:
                                  ((review['trace_sample_rate'] as num?)
                                      ?.toDouble() ??
                                  1),
                              epochDuration:
                                  (review['epoch_duration_seconds'] as num?)
                                      ?.toDouble(),
                              tracePointsPerEpoch:
                                  (review['trace_points_per_epoch'] as num?)
                                      ?.toInt(),
                              fullDuration:
                                  (review['trace_duration_seconds'] as num?)
                                      ?.toDouble(),
                            ),
                          Text(
                            '${review['trace_note'] ?? ''}',
                            style: Theme.of(context).textTheme.bodySmall,
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
    );
  }
}

class _RemovalCriterion extends StatelessWidget {
  const _RemovalCriterion({
    required this.criteria,
    required this.classes,
    required this.scores,
    required this.removed,
  });
  final Map<String, dynamic> criteria;
  final List<String> classes;
  final List<double> scores;
  final bool removed;
  @override
  Widget build(BuildContext context) {
    if (criteria.isEmpty)
      return const Text(
        'Removal criteria were not retained in this older result. Recompute ICA to record the actual thresholds.',
      );
    final threshold = (criteria['applied_threshold'] as num).toDouble();
    final targets = (criteria['target_classes'] as List).cast<String>();
    final matches = <String>[];
    for (var i = 0; i < classes.length && i < scores.length; i++) {
      if (targets.contains(classes[i]) && scores[i] >= threshold)
        matches.add(
          '${classes[i]} ${(scores[i] * 100).toStringAsFixed(2)}% ≥ ${(threshold * 100).toStringAsFixed(2)}%',
        );
    }
    final reason = removed
        ? 'Removed: ${matches.isEmpty ? 'selected by recorded stage criteria' : matches.join(' or ')}.'
        : 'Retained: no targeted class score meets the ${(threshold * 100).toStringAsFixed(2)}% removal threshold.';
    String pct(String name) =>
        (((criteria[name] as num?)?.toDouble() ?? 0) * 100).toStringAsFixed(2);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(reason, style: const TextStyle(fontWeight: FontWeight.w600)),
            Text(
              'Target classes: ${targets.join(', ')} · threshold ${pct('initial_threshold')}% → ${pct('applied_threshold')}% (floor ${pct('floor_threshold')}%).',
            ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              dense: true,
              title: const Text(
                'How this threshold was chosen',
                style: TextStyle(fontSize: 12),
              ),
              children: [
                Text('${criteria['explanation']}'),
                Text(
                  'Search stop limits: ${(100 * (criteria['max_component_fraction'] as num)).toStringAsFixed(0)}% of components; cumulative Brain probability ${criteria['max_brain_probability_sum']}. ${criteria['iterations']} threshold tests.',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ComponentTimeline extends StatefulWidget {
  const _ComponentTimeline({
    super.key,
    required this.values,
    required this.rate,
    this.epochDuration,
    this.fullDuration,
    this.tracePointsPerEpoch,
  });
  final List<num> values;
  final double rate;
  final double? epochDuration, fullDuration;
  final int? tracePointsPerEpoch;
  @override
  State<_ComponentTimeline> createState() => _ComponentTimelineState();
}

class _ComponentTimelineState extends State<_ComponentTimeline> {
  double start = 0, window = 10;
  int trial = 0;
  @override
  Widget build(BuildContext context) {
    final duration = widget.fullDuration ?? widget.values.length / widget.rate;
    final trialDuration = widget.epochDuration ?? duration;
    final trials = widget.epochDuration == null
        ? 1
        : (duration / trialDuration).round().clamp(1, 1000000);
    final span = math.min(window, trialDuration);
    final maxStart = math.max(0.0, trialDuration - span);
    final localStart = start.clamp(0.0, maxStart);
    final trialFirst =
        trial *
        (widget.tracePointsPerEpoch ?? (trialDuration * widget.rate).ceil());
    final trialLast = math.min(
      widget.values.length,
      trialFirst +
          (widget.tracePointsPerEpoch ?? (trialDuration * widget.rate).ceil()),
    );
    final first = (trialFirst + (localStart * widget.rate).floor()).clamp(
      0,
      trialLast,
    );
    final last = (trialFirst + ((localStart + span) * widget.rate).ceil())
        .clamp(first, trialLast);
    final values = [
      for (var i = first; i < last; i++) widget.values[i].toDouble(),
    ];
    void move(double next) => setState(() => start = next.clamp(0.0, maxStart));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          children: [
            const Text('Window'),
            DropdownButton<double>(
              value: window,
              items: [
                for (final n in [5.0, 10.0, 20.0, 30.0])
                  DropdownMenuItem(value: n, child: Text('${n.toInt()} s')),
              ],
              onChanged: (v) => setState(() {
                window = v!;
                start = 0;
              }),
            ),
            if (widget.epochDuration != null) ...[
              IconButton(
                tooltip: 'Previous trial',
                onPressed: trial > 0
                    ? () => setState(() {
                        trial--;
                        start = 0;
                      })
                    : null,
                icon: const Icon(Icons.skip_previous),
              ),
              Text('Trial ${trial + 1} / $trials'),
              IconButton(
                tooltip: 'Next trial',
                onPressed: trial + 1 < trials
                    ? () => setState(() {
                        trial++;
                        start = 0;
                      })
                    : null,
                icon: const Icon(Icons.skip_next),
              ),
            ],
          ],
        ),
        Listener(
          onPointerSignal: (event) {
            if (event is PointerScrollEvent &&
                event.scrollDelta.dx != 0 &&
                maxStart > 0) {
              GestureBinding.instance.pointerSignalResolver.register(
                event,
                (_) => move(
                  localStart +
                      event.scrollDelta.dx /
                          math.max(1, context.size?.width ?? 500) *
                          span,
                ),
              );
            }
          },
          child: GestureDetector(
            onHorizontalDragUpdate: maxStart > 0
                ? (d) => move(
                    localStart -
                        d.delta.dx /
                            math.max(1, context.size?.width ?? 500) *
                            span,
                  )
                : null,
            child: SizedBox(
              height: 150,
              child: CustomPaint(painter: _TracePainter(values)),
            ),
          ),
        ),
        Row(
          children: [
            IconButton(
              tooltip: 'Previous time window',
              onPressed: localStart > 0 ? () => move(localStart - span) : null,
              icon: const Icon(Icons.chevron_left),
            ),
            Expanded(
              child: Text(
                '${localStart.toStringAsFixed(1)} – ${(localStart + span).toStringAsFixed(1)} s / ${trialDuration.toStringAsFixed(1)} s${widget.epochDuration != null ? ' in trial' : ''}',
                textAlign: TextAlign.center,
              ),
            ),
            IconButton(
              tooltip: 'Next time window',
              onPressed: localStart < maxStart
                  ? () => move(localStart + span)
                  : null,
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        Slider(
          key: const ValueKey('ica-time-slider'),
          label: '${localStart.toStringAsFixed(1)} s',
          min: 0,
          max: math.max(maxStart, 0.001),
          value: localStart,
          onChanged: maxStart > 0 ? move : null,
        ),
        if (widget.fullDuration == null)
          const Text(
            'Legacy result: only the retained trace interval is available. Recompute ICA once to browse the full recording.',
            style: TextStyle(fontSize: 11),
          ),
      ],
    );
  }
}

class _ComponentMap extends StatelessWidget {
  const _ComponentMap({required this.labels, required this.values});
  final List<String> labels;
  final List<double> values;
  @override
  Widget build(BuildContext context) {
    try {
      final indices = [
        for (var i = 0; i < labels.length; i++)
          if (isStandard1020Channel(labels[i])) i,
      ];
      if (indices.length < 4)
        return const Center(child: Text('Scalp positions unavailable'));
      return CustomPaint(
        painter: _MapPainter(
          TopoInterpolator.forChannels([for (final i in indices) labels[i]]),
          [for (final i in indices) values[i]],
        ),
      );
    } catch (_) {
      return const Center(
        child: Text('Scalp map unavailable for this montage'),
      );
    }
  }
}

class _MapPainter extends CustomPainter {
  _MapPainter(this.interp, this.values);
  final TopoInterpolator interp;
  final List<double> values;
  @override
  void paint(Canvas canvas, Size size) {
    final limit = values.fold<double>(0, (a, v) => math.max(a, v.abs()));
    paintTopomap(
      canvas,
      Offset.zero & size,
      interp,
      values,
      vmin: -math.max(limit, 1e-12),
      vmax: math.max(limit, 1e-12),
      cmap: 'RdBu_r',
    );
  }

  @override
  bool shouldRepaint(_MapPainter old) => true;
}

class _TracePainter extends CustomPainter {
  _TracePainter(this.values);
  final List<double> values;
  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final lo = values.reduce(math.min), hi = values.reduce(math.max);
    final span = math.max(hi - lo, 1e-12);
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = i * size.width / (values.length - 1),
          y = 10 + (hi - values[i]) / span * (size.height - 20);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.lightBlueAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_TracePainter old) => old.values != values;
}
