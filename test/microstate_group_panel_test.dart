import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/microstate_analysis.dart';

MicrostateRecordingResult recording(
  String name,
  double coverage, {
  int windows = 4,
}) => MicrostateRecordingResult(
  filename: name,
  sampleRate: 250,
  gevTotal: .7,
  states: [
    {
      'coverage': coverage,
      'mean_duration_ms': 100,
      'occurrence_hz': 2,
      'gev': .3,
    },
  ],
  transitions: [
    [1],
  ],
  sequence: [1],
  stateProbabilities: [
    [1],
  ],
  sequenceMetrics: {'normalized_lz': .9},
  syntax: {
    'windows': windows,
    'classes': [
      {'entropy_bits': 1.0, 'empirical': .25, 'ratio_theoretical': .5},
    ],
  },
);
void main() {
  testWidgets(
    'group comparison averages recordings by subject and excludes missing syntax',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1300, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final result = MicrostateResult(
        outputDirectory: 'output',
        selectedStates: 1,
        stateLabels: ['A'],
        channelLabels: [],
        channelPositions: [],
        prototypes: [],
        canonicalCorrelations: [],
        modelFits: [],
        recordings: [
          recording('186142024_paradigm_P005_MW_1', .2),
          recording('186142024_paradigm_P005_MW_2', .5),
          recording('186142024_paradigm_P006_MW_1', .8, windows: 0),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MicrostateGroupPanel(result: result),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Recording'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Subject mean').last);
      await tester.pumpAndSettle();
      expect(find.text('P005'), findsOneWidget);
      expect(find.textContaining('35.000 (n=2)'), findsOneWidget);
      await tester.tap(find.text('Coverage (%)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Syntax observed share (%)').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('25.000 (n=2)'), findsOneWidget);
      expect(find.text('P006'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
