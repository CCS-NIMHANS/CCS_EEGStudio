import 'dart:io';
import 'package:ccs_eeg_app/src/topostats/topostats_engine.dart';
// test/topostats_multi_group_test.dart

import 'package:ccs_eeg_app/src/topostats/topostats_batch.dart';
import 'package:ccs_eeg_app/src/topostats/topostats_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('sessions can be disabled in the second group independently', (tester) async {
    tester.view.physicalSize=const Size(1500,1000);tester.view.devicePixelRatio=1;
    addTearDown(tester.view.resetPhysicalSize);addTearDown(tester.view.resetDevicePixelRatio);
    final dir=Directory.systemTemp.createTempSync('group-session-ui-');
    addTearDown(()=>dir.deleteSync(recursive:true));
    final files=<String>[];
    for(final subject in ['Sub01_TKG01','Sub02_TKG02']) {for(final session in ['1_Rest','2_Task']) {
      final file='${dir.path}${Platform.pathSeparator}${subject}_${session}.features.csv';
      File(file).writeAsStringSync('Epoch,Channel,Alpha\n0,Fz,1\n1,Fz,2\n');files.add(file);
    }}
    await tester.runAsync(() async {
      await tester.pumpWidget(MaterialApp(home:Scaffold(body:TopoStatsView(featureFilePaths:files, initialSettings: const TopoStatsSettings(nPermutations: 1)))));
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Manage sessions in all groups'));
    await tester.tap(find.text('Manage sessions in all groups'));await tester.pumpAndSettle();
    await tester.tap(find.text('Sub02_TKG02_2_Task.features.csv'));await tester.pumpAndSettle();
    expect(find.text('Sub01_TKG01 · 2/2 selected'), findsOneWidget);
    expect(find.text('Sub02_TKG02 · 1/2 selected'), findsOneWidget);
    await tester.runAsync(() async {await tester.tap(find.text('Apply selection'));await tester.pump(const Duration(milliseconds: 300));await Future<void>.delayed(const Duration(milliseconds: 400));});await tester.pumpAndSettle();
    await tester.tap(find.text('Manage sessions in all groups'));await tester.pumpAndSettle();
    expect(find.text('Sub01_TKG01 · 2/2 selected'), findsOneWidget);
    expect(find.text('Sub02_TKG02 · 1/2 selected'), findsOneWidget);
    expect(tester.takeException(),isNull);
  });
  test('TopoPlotGroup manages files and session names', () {
    final group = TopoPlotGroup(
      id: 'group_1',
      recId: 'Pilot_Day1',
      files: [
        '/data/1_Pilot_Day1_Baseline.features.csv',
        '/data/2_Pilot_Day1_Task.features.csv',
      ],
    );

    expect(group.activeFiles.length, 2);
    expect(group.sessionNames, ['Baseline', 'Task']);

    group.disabled.add('/data/2_Pilot_Day1_Task.features.csv');
    expect(group.activeFiles.length, 1);
    expect(group.sessionNames, ['Baseline']);
  });

  test('groupByRecording partitions files across distinct days/recordings', () {
    final files = [
      '/data/1_Pilot_Day1_Baseline.features.csv',
      '/data/2_Pilot_Day1_Meditation.features.csv',
      '/data/1_Pilot_Day2_Baseline.features.csv',
      '/data/2_Pilot_Day2_Meditation.features.csv',
    ];

    final groups = groupByRecording(files);
    expect(groups.length, 2);
    expect(groups.keys, contains('Pilot_Day1'));
    expect(groups.keys, contains('Pilot_Day2'));
  });

  testWidgets('TopoStatsView renders multi-group controls when seeded with files', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final files = [
      '/data/1_Pilot_Day1_Baseline.features.csv',
      '/data/2_Pilot_Day1_Meditation.features.csv',
      '/data/1_Pilot_Day2_Baseline.features.csv',
      '/data/2_Pilot_Day2_Meditation.features.csv',
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TopoStatsView(
            featureFilePaths: files,
            title: 'Plots & Report',
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Verify Title and Settings appear
    expect(find.text('Plots & Report'), findsOneWidget);
    expect(find.text('RECORDINGS'), findsOneWidget);
    expect(find.text('Open folder'), findsOneWidget);
    expect(find.text('Add group'), findsOneWidget);
  });
}
