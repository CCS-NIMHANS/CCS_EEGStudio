import 'dart:io';
import 'dart:isolate';

import 'package:ccs_eeg_app/src/group_statistics.dart';
import 'package:ccs_eeg_app/src/group_statistics_engine.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'runDartPermutationsInIsolate executes safely in Isolate.run and excludes Unknown levels',
    () async {
      final headers = ['subjid', 'group', 'condition', 'mean_uv'];
      final rows = <List<String>>[
        ['S01', 'ADV', 'Freq', '1.2'],
        ['S01', 'ADV', 'Rare', '4.8'],
        ['S02', 'ADV', 'Freq', '1.5'],
        ['S02', 'ADV', 'Rare', '5.1'],
        ['S03', 'ADV', 'Freq', '1.1'],
        ['S03', 'ADV', 'Rare', '4.6'],
        ['S04', 'CON', 'Freq', '0.9'],
        ['S04', 'CON', 'Rare', '2.3'],
        ['S05', 'CON', 'Freq', '1.0'],
        ['S05', 'CON', 'Rare', '2.5'],
        ['S06', 'CON', 'Freq', '0.8'],
        ['S06', 'CON', 'Rare', '2.1'],
        ['S99', 'Unknown', 'Freq', '99.0'],
        ['S99', 'Unknown', 'Rare', '99.0'],
      ];

      final payload = <String, dynamic>{
        'headers': headers,
        'rows': rows,
        'factors': ['group', 'condition'],
        'metrics': ['mean_uv'],
        'subjectCol': 'subjid',
        'preferredModel': 'lmm',
        'posthocMethod': 'fdr',
        'includeInteractions': true,
        'nPermutations': 200,
        'excludedLevels': {
          'group': ['Unknown'],
        },
        'customLevelOrder': {
          'group': ['CON', 'ADV'],
        },
      };

      final res = await Isolate.run(() => runDartPermutationsInIsolate(payload));
      expect(res.containsKey('error'), isFalse);

      final results = (res['results'] as List).cast<Map<String, dynamic>>();
      expect(results, hasLength(1));
      final first = results.first;
      expect(first['metric'], 'mean_uv');
      expect(first['n_subjects'], 6);
      expect(first['n_obs'], 12);

      final factorLevels = first['factor_levels'] as Map<String, dynamic>;
      expect(factorLevels['group'], ['CON', 'ADV']);
    },
  );

  test(
    'ErpGroupStatsEngine.inspectDataset joins concatenated sessions without SKYMED01/SKYMED013 collisions',
    () async {
      final tmp = await Directory.systemTemp.createTemp('ccs_grp_stats_test_');
      try {
        final csvFile = File('${tmp.path}/erp_components.csv');
        await csvFile.writeAsString(
          'subject,group,component,condition,Chan,mean_uv\n'
          'SKYMED013SESSION03,Unknown,P3b,Rare,Pz Cz,5.2\n'
          'SKYMED01SESSION01,Unknown,P3b,Rare,Pz Cz,2.4\n'
          'SKYMED02,Unknown,P3b,Rare,Pz Cz,3.8\n'
          'EXTRA999,Unknown,P3b,Rare,Pz Cz,0.5\n',
        );

        final metaFile = File('${tmp.path}/groups.csv');
        await metaFile.writeAsString(
          'subject,Group\n'
          'SKYMED01,CON\n'
          'SKYMED013,ADV\n'
          'SKYMED02,INT\n',
        );

        final insp = await ErpGroupStatsEngine.inspectDataset(
          csvPath: csvFile.path,
          metadataPath: metaFile.path,
        );

        final metricCols = (insp['metric_columns'] as List).cast<String>();
        expect(metricCols, contains('mean_uv'));

        final headers = (insp['headers'] as List).cast<String>();
        final groupIdx = headers.indexOf('group');
        expect(groupIdx, isNonNegative);

        final rows = (insp['rows'] as List)
            .map((r) => (r as List).map((e) => '$e').toList())
            .toList();
        expect(rows[0][groupIdx], 'ADV');
        expect(rows[1][groupIdx], 'CON');
        expect(rows[2][groupIdx], 'INT');
        expect(rows[3][groupIdx], 'Unknown');
      } finally {
        if (await tmp.exists()) {
          await tmp.delete(recursive: true);
        }
      }
    },
  );
}
