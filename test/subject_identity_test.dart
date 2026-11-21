import 'dart:io';
import 'package:ccs_eeg_app/src/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/recording_subject.dart';
import 'package:ccs_eeg_app/src/topostats/topostats_batch.dart';
import 'package:ccs_eeg_app/src/erp/batch_file_selector.dart';
void main() {
  test('new configurations do not stack GEDAI; explicit saved choices survive', () {
    final config = AnalysisConfig();
    expect(config.gedai, isFalse);
    config.applyPreprocessingJson({'gedai': true, 'gedai_threshold': 'auto-'});
    expect(config.gedai, isTrue);
    expect(config.gedaiThreshold, 'auto-');
    config.applyPreprocessingJson({'filter': true});
    expect(config.gedai, isTrue);
  });
  test('flat exports retain separate subjects and gather all sessions without sidecars', () {
    final dir = Directory.systemTemp.createTempSync('subject-groups-');
    addTearDown(() => dir.deleteSync(recursive:true));
    final paths = <String>[];
    for (final subject in ['Sub01_TKG01','Sub02_TKG02']) {
      for (final session in ['1_Rest','2_Meditation']) {
        final path = '${dir.path}${Platform.pathSeparator}${subject}_${session}.features.csv';
        File(path).writeAsStringSync('fixture'); paths.add(path);
      }
    }
    final groups = groupByRecording([paths.first, paths.last]);
    expect(groups.keys.toSet(), {'Sub01_TKG01','Sub02_TKG02'});
    expect(groups.values.map((v) => v.length), everyElement(2));
    saveRecordingSubject(paths.first, 'CustomA', 'source');
    expect(recordingSubject(paths.first), 'CustomA');
    expect(groupByRecording([paths.first])['CustomA'], [paths.first]);
  });
  testWidgets('batch tags are editable before queue confirmation', (tester) async {
    tester.view.physicalSize = const Size(1600,1100); tester.view.devicePixelRatio=1;
    addTearDown(tester.view.resetPhysicalSize); addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: BatchFileSelectionDialog(initialFiles: ['/data/Sub06_TKG06_1_Rest.vhdr']))));
    await tester.tap(find.text('Sub06_TKG06 ✎')); await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'Participant6');
    await tester.tap(find.text('Apply')); await tester.pumpAndSettle();
    expect(find.text('Participant6 ✎'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
