import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/group_statistics.dart';
import 'package:ccs_eeg_app/src/group_statistics_engine.dart';
import 'package:ccs_eeg_app/src/erp/grouped_grand_average_plot.dart';

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

  test('combines filename crop Session, folder Site, and external Group sheet simultaneously', () async {
    final dir = await Directory.systemTemp.createTemp('composable_factors_');
    try {
      final csv = File('${dir.path}/measurements.csv');
      final sheet = File('${dir.path}/groups.csv');
      await csv.writeAsString(
        'filename,subjid,Condition,mean_amplitude_ERP\n'
        '/study/BLR/SKYMED013SESSION03-epo_clean.edf,SKYMED013,Freq,1.2\n'
        '/study/BLR/SKYMED013SESSION05-epo_clean.edf,SKYMED013,Rare,3.4\n'
        '/study/DEL/SKYMED014SESSION03-epo_clean.edf,SKYMED014,Freq,2.1\n'
        '/study/DEL/SKYMED014SESSION05-epo_clean.edf,SKYMED014,Rare,4.2\n',
      );
      await sheet.writeAsString(
        'subject,Group\n'
        'SKYMED013,CON\n'
        'SKYMED014,ADV\n',
      );

      final data = await ErpGroupStatsEngine.inspectDataset(
        csvPath: csv.path,
        factorRules: [
          {
            'mode': 'crop',
            'factorName': 'Session',
            'sourceCol': 'filename',
            'label': 'Keyword + digits (SESSION\\d+)',
            'pattern': r'(SESSION\d+)',
            'isFixedSlice': false,
            'start': 9,
            'end': 18,
          },
          {
            'mode': 'folder',
            'factorName': 'Site',
            'sourceCol': 'filename',
            'folderLevel': 1,
          },
        ],
        externalSheets: [
          {
            'path': sheet.path,
            'sheetJoinCol': 'subject',
            'tableJoinCol': 'subjid',
            'selectedColumns': ['Group'],
          },
        ],
      );

      final headers = (data['headers'] as List).cast<String>();
      final rows = data['rows'] as List;
      final levels = data['factor_levels'] as Map;
      final sources = data['column_sources'] as Map;

      expect(headers, containsAll(['Session', 'Site', 'Group', 'Condition']));
      expect(levels['Session'], ['SESSION03', 'SESSION05']);
      expect(levels['Site'], ['BLR', 'DEL']);
      expect(levels['Group'], ['ADV', 'CON']);
      expect('${sources['Session']}', contains('Filename crop'));
      expect('${sources['Site']}', contains('Folder level 1'));
      expect('${sources['Group']}', contains('groups.csv'));
      expect(rows[0][headers.indexOf('Group')], 'CON');
      expect(rows[2][headers.indexOf('Site')], 'DEL');
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('auto-detects Session from filename when subjid lacks session suffix and joins Group sheet', () async {
    final dir = await Directory.systemTemp.createTemp('auto_fn_session_');
    try {
      final csv = File('${dir.path}/measurements.csv');
      final sheet = File('${dir.path}/groups.csv');
      await csv.writeAsString(
        'filename,subjid,Condition,mean_amplitude_ERP\n'
        'Y:\\AOBD\\SKYMED013SESSION03-epo_clean.edf,SKYMED013,Freq,1.2\n'
        'Y:\\AOBD\\SKYMED013SESSION05-epo_clean.edf,SKYMED013,Rare,3.4\n'
        'Y:\\AOBD\\SKYMED014SESSION06-epo_clean.edf,SKYMED014,Freq,2.1\n',
      );
      await sheet.writeAsString(
        'subject,Group\n'
        'SKYMED013,CON\n'
        'SKYMED014,NOV\n',
      );

      final data = await ErpGroupStatsEngine.inspectDataset(
        csvPath: csv.path,
        externalSheets: [{'path': sheet.path}],
      );
      final headers = (data['headers'] as List).cast<String>();
      final levels = data['factor_levels'] as Map;
      expect(headers, containsAll(['Session', 'Group']));
      expect(levels['Session'], ['03', '05', '06']);
      expect(levels['Group'], ['CON', 'NOV']);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  testWidgets('GroupedGrandAveragePlot renders panels by factor and condition', (tester) async {
    final files = [
      {
        'path': '/tmp/S01SESSION03.edf',
        'subject': 'S01',
        'group': 'CON',
        'times': [-0.1, 0.0, 0.1, 0.2, 0.3],
        'labels': ['Pz'],
        'channel_conditions': {
          'Freq': [
            [0.0, 0.2, 0.5, 0.8, 0.4],
          ],
          'Rare': [
            [0.1, 0.3, 1.2, 2.4, 1.1],
          ],
        },
        'profile': {'a_name': 'Freq', 'b_name': 'Rare'},
      },
      {
        'path': '/tmp/S02SESSION03.edf',
        'subject': 'S02',
        'group': 'ADV',
        'times': [-0.1, 0.0, 0.1, 0.2, 0.3],
        'labels': ['Pz'],
        'channel_conditions': {
          'Freq': [
            [0.0, 0.1, 0.4, 0.6, 0.3],
          ],
          'Rare': [
            [0.2, 0.5, 1.8, 3.2, 1.5],
          ],
        },
        'profile': {'a_name': 'Freq', 'b_name': 'Rare'},
      },
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: GroupedGrandAveragePlot(
              files: files,
              splitFactor: 'Group',
              fileFactors: const {
                '/tmp/S01SESSION03.edf': {'Group': 'CON'},
                '/tmp/S02SESSION03.edf': {'Group': 'ADV'},
              },
              participantGroups: const {'S01': 'CON', 'S02': 'ADV'},
              roiLabels: const ['Pz'],
              windowStartMs: 100,
              windowEndMs: 250,
            ),
          ),
        ),
      ),
    );
    expect(find.textContaining('Grouped Grand Average by Group'), findsOneWidget);
    expect(find.text('Freq'), findsOneWidget);
    expect(find.text('Rare'), findsOneWidget);
    expect(find.text('CON (n=1)'), findsOneWidget);
    expect(find.text('ADV (n=1)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('buildErpDifferenceDataset supports single and multiple difference pairs', () {
    const headers = ['filename', 'subjid', 'group', 'Condition', 'mean_amplitude_ERP'];
    final rows = <List<String>>[
      ['f1', 'S01', 'CON', 'Freq', '1.0'],
      ['f1', 'S01', 'CON', 'Rare', '3.5'],
      ['f1', 'S01', 'CON', 'Distr', '5.0'],
      ['f2', 'S02', 'CON', 'Freq', '2.0'],
      ['f2', 'S02', 'CON', 'Rare', '4.0'],
      ['f2', 'S02', 'CON', 'Distr', '6.0'],
      ['f3', 'S03', 'ADV', 'Freq', '0.5'],
      ['f3', 'S03', 'ADV', 'Rare', '2.0'],
      ['f3', 'S03', 'ADV', 'Distr', '3.0'],
    ];

    // (a) Single pair drops Condition and produces one difference metric column.
    final single = ErpGroupStatsEngine.buildErpDifferenceDataset(
      headers: headers,
      rows: rows,
      condCol: 'Condition',
      pairs: const [(condB: 'Rare', condA: 'Freq')],
      factors: const ['group', 'Condition'],
      metrics: const ['mean_amplitude_ERP'],
      subjectCol: 'subjid',
    );
    expect(single['factors'], ['group']);
    expect(single['metrics'], ['mean_amplitude_ERP (Rare − Freq)']);
    final singleRows = (single['rows'] as List).cast<List<String>>();
    expect(singleRows, hasLength(3));
    expect(double.parse(singleRows.first[4]), closeTo(2.5, 1e-9));

    // (b) Two pairs with Condition kept emits 2 rows per recording & unified metric.
    final unified = ErpGroupStatsEngine.buildErpDifferenceDataset(
      headers: headers,
      rows: rows,
      condCol: 'Condition',
      pairs: const [
        (condB: 'Rare', condA: 'Freq'),
        (condB: 'Distr', condA: 'Freq'),
      ],
      factors: const ['group', 'Condition'],
      metrics: const ['mean_amplitude_ERP'],
      subjectCol: 'subjid',
    );
    expect(unified['factors'], ['group', 'Condition']);
    expect(unified['metrics'], ['mean_amplitude_ERP (Difference)']);
    expect(unified['diff_labels'], ['Rare − Freq', 'Distr − Freq']);
    final unifiedRows = (unified['rows'] as List).cast<List<String>>();
    expect(unifiedRows, hasLength(6));
    expect(unifiedRows[0][3], 'Rare − Freq');
    expect(double.parse(unifiedRows[0][4]), closeTo(2.5, 1e-9));
    expect(unifiedRows[1][3], 'Distr − Freq');
    expect(double.parse(unifiedRows[1][4]), closeTo(4.0, 1e-9));

    // (c) Two pairs with Condition excluded emits separate difference metric columns.
    final separate = ErpGroupStatsEngine.buildErpDifferenceDataset(
      headers: headers,
      rows: rows,
      condCol: 'Condition',
      pairs: const [
        (condB: 'Rare', condA: 'Freq'),
        (condB: 'Distr', condA: 'Freq'),
      ],
      factors: const ['group'],
      metrics: const ['mean_amplitude_ERP'],
      subjectCol: 'subjid',
    );
    expect(separate['factors'], ['group']);
    expect(separate['metrics'], [
      'mean_amplitude_ERP (Rare − Freq)',
      'mean_amplitude_ERP (Distr − Freq)',
    ]);
    final separateRows = (separate['rows'] as List).cast<List<String>>();
    expect(separateRows, hasLength(3));
    expect(double.parse(separateRows[0][4]), closeTo(2.5, 1e-9));
    expect(double.parse(separateRows[0][5]), closeTo(4.0, 1e-9));
  });

  test('ErpGroupStatsEngine.runAnalysis respects contrastFactors while preserving model effects', () {
    const headers = ['subjid', 'group', 'Session', 'mean_amplitude_ERP'];
    final rows = <List<String>>[];
    for (var i = 0; i < 8; i++) {
      final grp = i < 4 ? 'CON' : 'ADV';
      final gEff = grp == 'ADV' ? 2.0 : 0.0;
      rows.add(['S$i', grp, '03', '${1.0 + gEff + (i % 4) * 0.2}']);
      rows.add(['S$i', grp, '05', '${2.5 + gEff + (i % 4) * 0.2}']);
    }

    final res = ErpGroupStatsEngine.runAnalysis(
      headers: headers,
      rows: rows,
      factors: const ['group', 'Session'],
      metrics: const ['mean_amplitude_ERP'],
      subjectCol: 'subjid',
      nPermutations: 10,
      contrastFactors: const ['group'],
    );
    expect(res['error'], isNull);
    final first = (res['results'] as List).first as Map<String, dynamic>;
    final effects = (first['model_effects'] as List)
        .cast<Map<String, dynamic>>()
        .map((e) => e['term'])
        .toList();
    expect(effects, containsAll(['group', 'Session', 'group × Session']));
    final posthoc = (first['posthoc'] as List).cast<Map<String, dynamic>>();
    expect(posthoc, isNotEmpty);
    expect(posthoc.every((c) => c['factor'] == 'group'), isTrue);
    expect('${first['posthoc_family']}', contains('group'));
  });
}
