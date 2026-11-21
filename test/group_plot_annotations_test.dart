import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/group_statistics_plots.dart';
import 'package:ccs_eeg_app/src/group_statistics_engine.dart';

void main() {
  const config = StatsPlotLayoutConfig(
    xFactor: 'Condition',
    seriesFactor: 'group',
    facetColFactor: 'Session',
    factorLabels: {'Session': 'Visit'},
    levelLabels: {
      'Session': {'03': 'Baseline'},
      'group': {'ADV': 'Advanced'},
    },
  );
  final levels = {
    'Condition': ['Freq', 'Rare'],
    'group': ['ADV'],
    'Session': ['03', '05'],
  };
  final contrasts = <Map<String, dynamic>>[
    {
      'factor': 'Condition',
      'group_a': 'Freq',
      'group_b': 'Rare',
      'p_adj': .001,
      'stratum': {'group': 'ADV', 'Session': '03'},
    },
    {
      'factor': 'Condition',
      'group_a': 'Freq',
      'group_b': 'Rare',
      'p_adj': .001,
      'stratum': {'group': 'ADV', 'Session': '05'},
    },
    {
      'factor': 'Condition',
      'group_a': 'Freq',
      'group_b': 'Rare',
      'p_adj': .001,
      'stratum': {},
    },
  ];
  test(
    'brackets select exact facet/simple-effect cells and never reuse marginal significance',
    () {
      final selected = statsPlotBrackets(
        config: config,
        contrasts: contrasts,
        factors: levels.keys.toList(),
        levels: levels,
        column: '03',
      );
      expect(selected, hasLength(1));
      expect(selected.first.xA, 0);
      expect(selected.first.xB, 1);
      expect(selected.first.label, contains('Advanced'));
      expect(levels['Session'], ['03', '05']);
    },
  );
  test(
    'native approximation rejects missing visits and unequal cell counts',
    () {
      final result = ErpGroupStatsEngine.runAnalysis(
        headers: ['subject', 'Session', 'metric'],
        rows: [
          ['S1', '03', '1'],
          ['S1', '05', '2'],
          ['S2', '03', '3'],
        ],
        factors: ['Session'],
        metrics: ['metric'],
        subjectCol: 'subject',
        nPermutations: 5,
      );
      expect(result['error'], contains('balanced'));
    },
  );
  testWidgets(
    'plot uses renamed factors and levels with corrected annotations',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ConfigurableStatsPlotWidget(
                config: config,
                factorLevels: levels,
                activeFactors: levels.keys.toList(),
                posthocs: contrasts,
                cellDescriptives: const {
                  'Condition=Freq|group=ADV|Session=03': {
                    'values': [1.0, 2.0],
                  },
                  'Condition=Rare|group=ADV|Session=03': {
                    'values': [3.0, 4.0],
                  },
                },
              ),
            ),
          ),
        ),
      );
      expect(find.text('Visit: Baseline'), findsOneWidget);
      expect(find.text('Advanced'), findsOneWidget);
      expect(find.textContaining('Corrected contrast details'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
