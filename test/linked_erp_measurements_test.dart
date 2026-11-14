import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/models.dart';
import 'package:ccs_eeg_app/src/erp/linked_review_profile.dart';
import 'package:ccs_eeg_app/src/erp/erp_workbench_view.dart';
import 'package:ccs_eeg_app/src/recording_storage.dart';
import 'package:ccs_eeg_app/src/erp/workbench_service.dart';

EegRecording epochs(String path) => EegRecording(
  path: path,
  sampleRate: 100,
  labels: const ['Pz', 'Cz'],
  preview: [
    Float32List.fromList(List.generate(404, (i) => (i % 101) * .1)),
    Float32List.fromList(List.generate(404, (i) => (i % 101) * .05 + (i % 7))),
  ],
  sampleCount: 404,
  format: 'ccseeg',
  pointsPerEpoch: 101,
  epochCount: 4,
  epochTmin: -.2,
  epochLabels: const ['Non-target', 'Target', 'Non-target', 'Target'],
);
void main() {
  test('named accepted conditions override raw ERP-CORE event codes', () {
    final scan = linkedReviewInspection(
      epochs('accepted.ccseeg'),
      'P3',
      AnalysisConfig(),
    );
    final f = (scan['files'] as List).single as Map;
    expect(f['marker_counts'], {'Non-target': 2, 'Target': 2});
    expect(f['profile']['conditions'], [
      {
        'name': 'Non-target',
        'codes': ['Non-target'],
      },
      {
        'name': 'Target',
        'codes': ['Target'],
      },
    ]);
    expect(f['profile']['roi'], ['Pz']);
    expect(f['profile']['saved_a_groups'], ['Non-target']);
    expect(f['profile']['saved_b_groups'], ['Target']);
    final reversed = linkedReviewInspection(
      EegRecording(
        path: 'P3',
        sampleRate: 100,
        labels: const ['Pz', 'Cz'],
        preview: epochs('P3').preview,
        sampleCount: 404,
        format: 'ccseeg',
        pointsPerEpoch: 101,
        epochCount: 4,
        epochTmin: -.2,
        epochLabels: const ['Target', 'Non-target', 'Target', 'Non-target'],
      ),
      'P3',
      AnalysisConfig(),
    );
    expect(reversed['files'][0]['profile']['a_name'], 'Non-target');
    expect(reversed['files'][0]['profile']['b_name'], 'Target');
  });
  testWidgets(
    'linked measurements show trial counts without file or condition reselection',
    (tester) async {
      tester.view.physicalSize = const Size(1700, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final dir = Directory.systemTemp.createTempSync('linked-erp');
      final recording = epochs('${dir.path}/accepted.ccseeg');
      File(recording.path).writeAsStringSync('fixture');
      final result = File('${dir.path}/erp_results.ccserp')
        ..writeAsStringSync(jsonEncode({'files': [], 'groups': []}));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ErpWorkbenchView(
              activeRecording: recording,
              config: AnalysisConfig(),
              batchMode: false,
              linkedReview: true,
              initialInspection: linkedReviewInspection(
                recording,
                'P3',
                AnalysisConfig(),
              ),
              linkedOutputDirectory: dir.path,
              initialResultPath: result.path,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Non-target: 2 trials'), findsOneWidget);
      expect(find.text('Target: 2 trials'), findsOneWidget);
      expect(find.text('Add EEG Files / Epochs'), findsNothing);
      expect(find.text('Open EEG / epochs'), findsNothing);
      expect(find.textContaining('0 matching epochs'), findsNothing);
      expect(find.text('Regroup using task event codes'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      dir.deleteSync(recursive: true);
    },
  );
  test('native linked measurements retain named accepted groups', () async {
    if (Platform.environment['CCS_TEST_LINKED_ENGINE'] != '1') return;
    final dir = await Directory.systemTemp.createTemp('linked-native-erp');
    addTearDown(() => dir.delete(recursive: true));
    final rec = epochs('${dir.path}/accepted.ccseeg');
    await RecordingStorage.save(rec, rec.path);
    final scan = linkedReviewInspection(rec, 'P3', AnalysisConfig());
    final profile = (scan['files'] as List).single['profile'];
    final result = await ErpWorkbenchService().execute(
      [
        {'path': rec.path, 'subject': 'Test'},
      ],
      {
        'task': 'P3',
        'profile_override': profile,
        'regroup_epochs': false,
        'reject_uv': 0,
        'permutations': 16,
      },
      dir.path,
    );
    expect(result['failures'], isEmpty);
    expect(result['files'], hasLength(1));
    expect(jsonEncode(result), contains('Non-target'));
    expect(jsonEncode(result), contains('Target'));
  });
}
