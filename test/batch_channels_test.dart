import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/batch_channels.dart';
import 'package:ccs_eeg_app/src/models.dart';

void main() {
  test('batch mapping renames and selects matching samples', () {
    final labels = [
      'EEG Fp1-Ref',
      'EEG Fp2-Ref',
      'EEG C3-Ref',
      'EEG C4-Ref',
      'POL SpO2',
    ];
    final rec = EegRecording(
      path: 'input.edf',
      format: 'edf',
      sampleRate: 200,
      labels: labels,
      preview: [
        for (var i = 0; i < 5; i++)
          Float32List.fromList([i.toDouble(), i + 1.0]),
      ],
      sampleCount: 2,
    );
    final mapping = BatchChannels({
      for (final l in labels)
        l: l.startsWith('EEG ') ? suggestedEegName(l) : '',
    });
    final result = mapping.apply(rec);
    expect(result.labels, ['Fp1', 'Fp2', 'C3', 'C4']);
    expect(result.preview[2], [2, 3]);
    expect(result.format, 'ccseeg');
    expect(result.path, rec.path);
    expect(result.provenance['original_source'], 'input.edf');
    expect(
      () => BatchChannels({labels.first: 'Fp1'}).apply(rec),
      throwsStateError,
    );
    expect(
      () => BatchChannels({for (final l in labels) l: 'Fp1'}).apply(rec),
      throwsStateError,
    );
  });
}
