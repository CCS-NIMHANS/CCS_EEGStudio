import 'models.dart';

String suggestedEegName(String input) => input
    .trim()
    .replaceFirst(RegExp(r'^EEG\s+', caseSensitive: false), '')
    .replaceFirst(RegExp(r'[-\s]+Ref$', caseSensitive: false), '')
    .trim();

/// Standard LiveAmp 32 / ActiCAP 32-channel montage layout.
const List<String> kLiveAmp32ActiCapLabels = [
  'Fp1', 'Fz', 'F3', 'F7', 'FT9', 'FC5', 'FC1', 'C3', 'T7', 'TP9',
  'CP5', 'CP1', 'Pz', 'P3', 'P7', 'O1', 'Oz', 'O2', 'P4', 'P8',
  'TP10', 'CP6', 'CP2', 'Cz', 'C4', 'T8', 'FT10', 'FC6', 'FC2', 'F4',
  'F8', 'Fp2',
];

/// Standard 10-20 32-channel layout.
const List<String> kStandard32Labels = [
  'Fp1', 'Fp2', 'F7', 'F3', 'Fz', 'F4', 'F8', 'FC5',
  'FC1', 'FC2', 'FC6', 'T7', 'C3', 'Cz', 'C4', 'T8',
  'TP9', 'CP5', 'CP1', 'CP2', 'CP6', 'TP10', 'P7', 'P3',
  'Pz', 'P4', 'P8', 'PO9', 'O1', 'Oz', 'O2', 'PO10',
];

/// Standard 10-20 19-channel clinical layout.
const List<String> kStandard19Labels = [
  'Fp1', 'Fp2', 'F7', 'F3', 'Fz', 'F4', 'F8', 'T7',
  'C3', 'Cz', 'C4', 'T8', 'P7', 'P3', 'Pz', 'P4',
  'P8', 'O1', 'O2',
];

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
