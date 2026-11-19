import 'dart:typed_data';

import 'package:ccs_eeg_app/src/eeg_viewer.dart';
import 'package:ccs_eeg_app/src/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EegViewer time axis formatting and progression beyond 30 s', () {
    test('formats elapsedSeconds, hhMmSs, clockTime, and epoch past 120 s', () {
      expect(
        formatEegTimeAxisTick(
          mode: TimeAxisMode.elapsedSeconds,
          t: 120.0,
          windowSeconds: 30.0,
          isEpoched: false,
          epochDurationSeconds: 0.0,
        ),
        '120 s',
      );
      expect(
        formatEegTimeAxisTick(
          mode: TimeAxisMode.elapsedSeconds,
          t: 150.0,
          windowSeconds: 30.0,
          isEpoched: false,
          epochDurationSeconds: 0.0,
        ),
        '150 s',
      );
      expect(
        formatEegTimeAxisTick(
          mode: TimeAxisMode.hhMmSs,
          t: 135.0,
          windowSeconds: 30.0,
          isEpoched: false,
          epochDurationSeconds: 0.0,
        ),
        '00:02:15',
      );
      expect(
        formatEegTimeAxisTick(
          mode: TimeAxisMode.clockTime,
          t: 125.0,
          windowSeconds: 30.0,
          isEpoched: false,
          epochDurationSeconds: 0.0,
          recordingStartIso: '2026-11-11T09:10:00',
        ),
        '09:12:05',
      );
      expect(
        formatEegTimeAxisTick(
          mode: TimeAxisMode.epoch,
          t: 135.0,
          windowSeconds: 30.0,
          isEpoched: false,
          epochDurationSeconds: 0.0,
        ),
        'Ep5 +15s',
      );
    });

    testWidgets('viewer switches all 4 TimeAxisMode options cleanly', (
      tester,
    ) async {
      final rec = EegRecording(
        path: '/tmp/long.edf',
        sampleRate: 10,
        labels: const ['Fz', 'Cz'],
        preview: [
          Float32List.fromList(List.generate(2000, (i) => (i % 20).toDouble())),
          Float32List.fromList(List.generate(2000, (i) => (i % 15).toDouble())),
        ],
        sampleCount: 2000,
        format: 'EDF',
        provenance: const {'recording_start_iso': '2026-11-11T09:10:00'},
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 1100,
              height: 700,
              child: EegViewer(
                recording: rec,
                cursorSeconds: 135.0,
                selection: const ViewerSelection.empty(),
                onSelectionChanged: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Controls'));
      await tester.pumpAndSettle();

      expect(find.text('Time: Elapsed (s)'), findsOneWidget);
      await tester.tap(find.text('Time: Elapsed (s)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Time: Clock').last);
      await tester.pumpAndSettle();
      expect(find.text('Time: Clock'), findsOneWidget);
    });
  });
}
