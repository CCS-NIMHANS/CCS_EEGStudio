import '../models.dart';
import 'erp_core_presets.dart';

/// Carry actual accepted epoch labels, never rematch named groups to raw codes.
Map<String, dynamic> linkedReviewInspection(
  EegRecording epochs,
  String task,
  AnalysisConfig config,
) {
  final counts = <String, int>{};
  for (final name
      in epochs.epochLabels ?? List.filled(epochs.epochCount, 'Trials')) {
    counts[name] = (counts[name] ?? 0) + 1;
  }
  final base = Map<String, dynamic>.from(erpCorePresets[task] ?? {});
  final preferred = [
    if (base['a_name'] != null) '${base['a_name']}',
    if (base['b_name'] != null) '${base['b_name']}',
    ...config.stimMarkerGroups.keys,
  ];
  final names = <String>{
    ...preferred.where(counts.containsKey),
    ...counts.keys,
  }.toList();
  final start = epochs.epochTmin ?? 0;
  final end = start + (epochs.pointsPerEpoch! - 1) / epochs.sampleRate;
  final roi = (base['roi'] as List? ?? [epochs.labels.first])
      .where(epochs.labels.contains)
      .toList();
  final window = (base['window'] as List? ?? [start, end]).cast<num>();
  final a = window[0].toDouble().clamp(start, end),
      b = window[1].toDouble().clamp(start, end);
  final profile = <String, dynamic>{
    ...base,
    'task': base['task'] ?? 'Custom',
    'component_name': base['component_name'] ?? 'ERP',
    'a_name': names.first,
    'a_codes': [names.first],
    'saved_a_groups': [names.first],
    'b_name': names.length > 1 ? names[1] : '',
    'b_codes': names.length > 1 ? [names[1]] : <String>[],
    'saved_b_groups': names.length > 1 ? [names[1]] : <String>[],
    'conditions': [
      for (final name in names)
        {
          'name': name,
          'codes': [name],
        },
    ],
    'roi': roi.isEmpty ? [epochs.labels.first] : roi,
    'epoch': [start, end],
    'baseline': [
      config.stimBaselineStart.clamp(start, end),
      config.stimBaselineEnd.clamp(start, end),
    ],
    'window': b > a ? [a, b] : [start, end],
    'polarity': base['polarity'] ?? 1.0,
    'lateralized': base['lateralized'] ?? false,
  };
  final baseline = profile['baseline'] as List;
  if ((baseline[1] as num) <= (baseline[0] as num))
    profile['baseline'] = [start, start + (end - start) * .2];
  return {
    'files': [
      {
        'path': epochs.path,
        'subject': 'Reviewed recording',
        'is_epoched': true,
        'marker_counts': counts,
        'profile': profile,
      },
    ],
  };
}
