import 'models.dart';

String suggestedEegName(String input) => input
    .trim()
    .replaceFirst(RegExp(r'^EEG\s+', caseSensitive: false), '')
    .replaceFirst(RegExp(r'[-\s]+Ref$', caseSensitive: false), '')
    .trim();

class BatchChannels {
  final Map<String, String> names;
  BatchChannels(this.names);
  EegRecording apply(EegRecording r) {
    final selected = <int>[];
    final labels = <String>[];
    for (var i = 0; i < r.labels.length; i++) {
      final name =
          names[r.labels[i]] ??
          (names.containsValue(r.labels[i]) ? r.labels[i] : null);
      if (name == null || name.trim().isEmpty) continue;
      if (labels.any((x) => x.toLowerCase() == name.trim().toLowerCase()))
        throw StateError('Duplicate mapped channel: $name');
      selected.add(i);
      labels.add(name.trim());
    }
    if (labels.length < 4)
      throw StateError(
        'Fewer than four selected EEG channels in ${r.path}. Review the batch channel mapping.',
      );
    return EegRecording(
      path: r.path,
      format: 'ccseeg',
      sampleRate: r.sampleRate,
      labels: labels,
      preview: [for (final i in selected) r.preview[i]],
      sampleCount: r.sampleCount,
      epochCount: r.epochCount,
      pointsPerEpoch: r.pointsPerEpoch,
      epochLabels: r.epochLabels,
      epochTmin: r.epochTmin,
      epochStartSeconds: r.epochStartSeconds,
      sourceDurationSeconds: r.sourceDurationSeconds,
      completedStages: r.completedStages,
      markers: [
        for (final m in r.markers)
          if (m.channelIndex == null || selected.contains(m.channelIndex))
            EegMarker(
              type: m.type,
              description: m.description,
              startSeconds: m.startSeconds,
              durationSeconds: m.durationSeconds,
              epochIndex: m.epochIndex,
              channelIndex: m.channelIndex == null
                  ? null
                  : selected.indexOf(m.channelIndex!),
            ),
      ],
      provenance: {
        ...r.provenance,
        'original_source': r.path,
        'batch_channel_mapping': names,
      },
    );
  }
}
