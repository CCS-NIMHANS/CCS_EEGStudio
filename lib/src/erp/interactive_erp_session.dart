import 'dart:typed_data';
import '../models.dart';

/// A trial is retained in memory when excluded. Updating sums only touches that
/// trial, so rejection/reinstatement never repeats preprocessing or epoching.
class InteractiveErpSession {
  InteractiveErpSession(this.epochs) {
    if (!epochs.isEpoched ||
        epochs.pointsPerEpoch == null ||
        epochs.pointsPerEpoch! <= 0 ||
        epochs.sampleCount != epochs.epochCount * epochs.pointsPerEpoch! ||
        epochs.preview.any((ch) => ch.length != epochs.sampleCount)) {
      throw ArgumentError('Full-resolution saved trials are required');
    }
    for (var i = 0; i < epochs.epochCount; i++) {
      _add(i, 1);
    }
    for (var c = 0; c < epochs.labels.length; c++) {
      var limit = 1.0;
      for (final name in conditions) {
        final average = mean(name, c);
        if (average != null)
          for (final v in average) {
            if (v.abs() > limit) limit = v.abs();
          }
      }
      _limits[c] = limit * 1.15;
    }
  }
  final EegRecording epochs;
  final Set<int> rejected = {};
  final Map<int, double> _limits = {};

  /// A fixed bound from the initial condition averages: inclusion changes cannot hide
  /// amplitude changes by silently rescaling the ERP plot.
  double displayLimit(int channel) => _limits.putIfAbsent(
    channel,
    () => epochs.preview[channel].fold<double>(
      1,
      (m, v) => v.abs() > m ? v.abs() : m,
    ),
  );
  final Map<String, List<Float64List>> _sums = {};
  final Map<String, int> counts = {};
  int revision = 0;
  int get points => epochs.pointsPerEpoch!;
  String condition(int index) =>
      epochs.epochLabels != null && index < epochs.epochLabels!.length
      ? epochs.epochLabels![index]
      : 'Trials';
  List<String> get conditions => _sums.keys.toList();
  int get acceptedCount => epochs.epochCount - rejected.length;
  void _add(int index, int sign) {
    final name = condition(index);
    final sums = _sums.putIfAbsent(
      name,
      () => [for (final _ in epochs.labels) Float64List(points)],
    );
    counts[name] = (counts[name] ?? 0) + sign;
    for (var c = 0; c < sums.length; c++) {
      for (var s = 0; s < points; s++) {
        sums[c][s] += sign * epochs.preview[c][index * points + s];
      }
    }
  }

  void setRejected(int index, bool value) {
    if (index < 0 || index >= epochs.epochCount)
      throw RangeError.index(
        index,
        epochs.epochLabels ?? List.filled(epochs.epochCount, ''),
      );
    if (rejected.contains(index) == value) return;
    if (value) {
      rejected.add(index);
      _add(index, -1);
    } else {
      rejected.remove(index);
      _add(index, 1);
    }
    revision++;
  }

  Float64List? mean(String name, int channel) {
    final n = counts[name] ?? 0;
    if (n == 0) return null;
    return Float64List.fromList([
      for (final value in _sums[name]![channel]) value / n,
    ]);
  }

  EegRecording trial(int index) => _copy(
    [
      for (final ch in epochs.preview)
        Float32List.fromList(ch.sublist(index * points, (index + 1) * points)),
    ],
    [index],
  );
  EegRecording accepted() {
    final indices = [
      for (var i = 0; i < epochs.epochCount; i++)
        if (!rejected.contains(i)) i,
    ];
    if (indices.isEmpty)
      throw StateError(
        'Include at least one epoch before saving or analysing.',
      );
    return _copy([
      for (final ch in epochs.preview)
        Float32List.fromList([
          for (final i in indices) ...ch.sublist(i * points, (i + 1) * points),
        ]),
    ], indices);
  }

  EegRecording _copy(List<Float32List> channels, List<int> indices) {
    final map = {for (var i = 0; i < indices.length; i++) indices[i]: i};
    return EegRecording(
      path: '${epochs.path}-reviewed',
      format: 'ccseeg',
      sampleRate: epochs.sampleRate,
      labels: epochs.labels,
      preview: channels,
      sampleCount: channels.first.length,
      pointsPerEpoch: points,
      epochCount: indices.length,
      epochLabels: [for (final i in indices) condition(i)],
      epochTmin: epochs.epochTmin,
      completedStages: epochs.completedStages,
      sourceDurationSeconds: epochs.sourceDurationSeconds,
      epochStartSeconds: [
        for (final i in indices)
          if (i < epochs.epochStartSeconds.length) epochs.epochStartSeconds[i],
      ],
      provenance: {
        ...epochs.provenance,
        'erp_review': {
          'total_trials': epochs.epochCount,
          'accepted_trial_indices': indices,
          'rejected_trial_indices': rejected.toList()..sort(),
        },
      },
      markers: [
        for (final m in epochs.markers)
          if (map.containsKey(m.epochIndex ?? 0))
            EegMarker(
              type: m.type,
              description: m.description,
              startSeconds: m.startSeconds,
              durationSeconds: m.durationSeconds,
              channelIndex: m.channelIndex,
              epochIndex: map[m.epochIndex ?? 0],
            ),
      ],
    );
  }
}
