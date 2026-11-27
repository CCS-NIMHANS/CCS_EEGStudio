import 'package:ccs_eeg_app/src/models.dart';
import 'package:ccs_eeg_app/src/physio_events.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('mergePhysioMarkers preserves stimulus markers and replaces selected physio types', () {
    final existing = [
      const EegMarker(type: 'Stim', description: 'S 11', startSeconds: 1.5),
      const EegMarker(type: 'Physio/Blink', description: 'Blink', startSeconds: 2.0),
      const EegMarker(type: 'Physio/ECG', description: 'ECG_R', startSeconds: 3.0),
    ];
    final fresh = [
      const EegMarker(
        type: 'Physio/Blink',
        description: 'Blink',
        startSeconds: 0.8,
        durationSeconds: 0.25,
      ),
      const EegMarker(
        type: 'Physio/EMG',
        description: 'EMG_Surge',
        startSeconds: 4.2,
        durationSeconds: 0.6,
      ),
    ];

    final merged = mergePhysioMarkers(
      existing,
      fresh,
      replacedTypes: {'Physio/Blink', 'Physio/EMG'},
    );

    expect(merged.map((m) => m.description).toList(), [
      'Blink',
      'S 11',
      'ECG_R',
      'EMG_Surge',
    ]);
    expect(merged.first.startSeconds, 0.8);
  });

  test('formatEeglabEvtSidecar and formatBidsEventsTsv format sorted tables', () {
    final markers = [
      const EegMarker(
        type: 'Physio/ECG',
        description: 'ECG_R',
        startSeconds: 2.5,
      ),
      const EegMarker(
        type: 'Physio/Blink',
        description: 'Blink',
        startSeconds: 1.0,
        durationSeconds: 0.3,
      ),
    ];
    final evt = formatEeglabEvtSidecar(markers);
    final evtLines = evt.trim().split('\n');
    expect(evtLines[0], 'type\tlatency\tduration');
    expect(evtLines[1], 'Blink\t1.0000\t0.3000');
    expect(evtLines[2], 'ECG_R\t2.5000\t0.0000');

    final tsv = formatBidsEventsTsv([
      {
        'type': 'Physio/ECG',
        'description': 'ECG_R',
        'start_seconds': 2.5,
        'duration_seconds': 0.0,
        'channel': 'ECG',
        'score': 8.4,
      },
      {
        'type': 'Physio/Blink',
        'description': 'Blink',
        'start_seconds': 1.0,
        'duration_seconds': 0.3,
        'channel': 'Fp1',
        'score': 5.2,
      },
    ]);
    final tsvLines = tsv.trim().split('\n');
    expect(tsvLines[0], 'onset\tduration\ttrial_type\tevent_group\tchannel\tscore');
    expect(tsvLines[1], '1.0000\t0.3000\tBlink\tPhysio/Blink\tFp1\t5.20');
  });
}
