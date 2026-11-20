import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/group_statistics.dart';
import 'package:ccs_eeg_app/src/group_statistics_engine.dart';

void main() {
  test('auto joins a subject column after a serial number and separates sessions', () async {
    final dir = await Directory.systemTemp.createTemp('group_flow_');
    try {
      final csv = File('${dir.path}/measurements.csv');
      final meta = File('${dir.path}/groups.csv');
      await csv.writeAsString('filename,subjid,group,Condition,mean_amplitude_ERP\na,S01SESSION01,Unknown,Freq,1.2\nb,S01SESSION02,Unknown,Rare,2.3\nc,S02SESSION01,Unknown,Freq,3.1\n');
      await meta.writeAsString('Sl.No.,subject,Group\n1,S01,CON\n2,S02,NOV\n');
      final data = await ErpGroupStatsEngine.inspectDataset(csvPath: csv.path, metadataPath: meta.path);
      final headers = (data['headers'] as List).cast<String>();
      final rows = data['rows'] as List;
      expect(data['detected_subject_col'], 'participant_id');
      expect((data['factor_levels'] as Map)['participant_id'], ['S01', 'S02']);
      expect(rows[0][headers.indexOf('group')], 'CON');
      expect(rows[1][headers.indexOf('group')], 'CON');
      expect((data['metric_columns'] as List), isNot(contains('Sl.No.')));
      expect(headers, contains('Session'));
      expect(rows[1][headers.indexOf('Session')], '02');
    } finally { await dir.delete(recursive: true); }
  });

  test('reviewed filename labels preserve distinct visits and override person IDs', () async {
    final dir = await Directory.systemTemp.createTemp('reviewed_names_');
    try {
      final csv = File('${dir.path}/measurements.csv');
      final meta = File('${dir.path}/reviewed.csv');
      await csv.writeAsString('filename,subjid,Condition,mean_amplitude_ERP\n/data/S01SESSION01.edf,S01SESSION01,Freq,1.2\n/data/S01SESSION02.edf,S01SESSION02,Rare,2.3\n');
      await meta.writeAsString('filename,participant_id,Session,Group\n/data/S01SESSION01.edf,Reviewed01,Visit1,CON\n/data/S01SESSION02.edf,Reviewed01,Visit2,CON\n');
      final data = await ErpGroupStatsEngine.inspectDataset(csvPath: csv.path, metadataPath: meta.path, metadataKey: 'filename');
      final headers = (data['headers'] as List).cast<String>();
      final rows = data['rows'] as List;
      expect(data['detected_subject_col'], 'participant_id');
      expect(rows[0][headers.indexOf('participant_id')], 'Reviewed01');
      expect(rows[1][headers.indexOf('Session')], 'Visit2');
      expect('${(data['column_sources'] as Map)['Group']}', contains('reviewed.csv'));
    } finally { await dir.delete(recursive: true); }
  });

  testWidgets('guides users from data to design and hides unavailable steps', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: GroupStatisticsWorkbench())));
    expect(find.text('1. Data & groups'), findsOneWidget);
    expect(find.text('2. Design & run'), findsOneWidget);
    expect(find.text('3. Results'), findsOneWidget);
    expect(find.text('What do you want to compare?'), findsNothing);
    final next = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Continue to analysis design'));
    expect(next.onPressed, isNull);
  });

  test('reads real Groups.xlsx without a Python Excel dependency', () async {
    const base = '/Volumes/CCS Storage/CCS_UserFolders/neethi/SKYMeditation_2026/AOBD_Analysis';
    if (!await File('$base/Groups.xlsx').exists()) return;
    final dir = await Directory.systemTemp.createTemp('real_groups_');
    try {
      final path = await prepareGroupMetadataForPython('$base/Groups.xlsx', dir);
      final result = await ErpGroupStatsEngine.inspectDataset(
        csvPath: '$base/TestBin_20261119/Group_Statistics/ERP_Custom_conditions_group_input.csv',
        metadataPath: path,
      );
      expect(result['detected_subject_col'], 'participant_id');
      final levels = result['factor_levels'] as Map;
      expect((levels['participant_id'] as List).length, lessThan(362));
      final headers = (result['headers'] as List).cast<String>();
      final groupIndex = headers.indexOf('group');
      final groups = (result['rows'] as List).map((r) => r[groupIndex]).toSet();
      expect(groups, containsAll(['CON', 'NOV', 'ADV', 'INT']));
      await File('/tmp/ccs_participant_groups.csv').writeAsString(await File(path).readAsString());
      // ignore: avoid_print
      print('Real group import: ${(levels['participant_id'] as List).length} participants; groups $groups');
    } finally { await dir.delete(recursive: true); }
  });
}
