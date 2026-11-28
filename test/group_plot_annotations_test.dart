import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/group_statistics.dart';
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
  test(
    'cross-series brackets show both series levels and sort by ascending adjusted p',
    () {
      const multiConfig = StatsPlotLayoutConfig(
        xFactor: 'Condition',
        seriesFactor: 'group',
        facetColFactor: 'Session',
        levelLabels: {
          'group': {'ADV': 'Advanced', 'CON': 'Control', 'NOV': 'Novice'},
        },
      );
      final multiLevels = {
        'Condition': ['Distr', 'Freq', 'Rare'],
        'group': ['ADV', 'CON', 'NOV'],
        'Session': ['03', '06'],
      };
      final mixedContrasts = <Map<String, dynamic>>[
        {
          'factor': 'group',
          'group_a': 'ADV',
          'group_b': 'CON',
          'p_adj': 0.03,
          'stratum': {'Condition': 'Distr', 'Session': '03'},
        },
        {
          'factor': 'Condition',
          'group_a': 'Distr',
          'group_b': 'Rare',
          'p_adj': 0.0002,
          'stratum': {'group': 'ADV', 'Session': '03'},
        },
      ];
      final selected = statsPlotBrackets(
        config: multiConfig,
        contrasts: mixedContrasts,
        factors: multiLevels.keys.toList(),
        levels: multiLevels,
        column: '03',
      );
      expect(selected, hasLength(2));
      expect(selected.first.label, 'Advanced ***');
      expect(selected.last.label, 'Advanced–Control *');
    },
  );
  testWidgets(
    'uneven facet columns with 10 contrasts render without overflow and toggle brackets',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final multiLevels = {
        'Condition': ['Distr', 'Freq', 'Rare'],
        'group': ['ADV', 'CON', 'INT', 'NOV'],
        'Session': ['03', '05', '06'],
      };
      final manyContrasts = <Map<String, dynamic>>[
        for (var i = 0; i < 8; i++)
          {
            'factor': 'Condition',
            'group_a': i.isEven ? 'Distr' : 'Freq',
            'group_b': 'Rare',
            'p_adj': 0.0001 * (i + 1),
            'stratum': {
              'group': multiLevels['group']![i % 4],
              'Session': '03',
            },
          },
        {
          'factor': 'group',
          'group_a': 'ADV',
          'group_b': 'CON',
          'p_adj': 0.015,
          'stratum': {'Condition': 'Distr', 'Session': '03'},
        },
        {
          'factor': 'Condition',
          'group_a': 'Distr',
          'group_b': 'Freq',
          'p_adj': 0.004,
          'stratum': {'group': 'ADV', 'Session': '06'},
        },
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ConfigurableStatsPlotWidget(
                config: config,
                factorLevels: multiLevels,
                activeFactors: multiLevels.keys.toList(),
                posthocs: manyContrasts,
                cellDescriptives: const {
                  'Condition=Distr|group=ADV|Session=03': {
                    'values': [1.0, 2.5],
                  },
                  'Condition=Freq|group=ADV|Session=03': {
                    'values': [-0.4, 0.2],
                  },
                  'Condition=Rare|group=ADV|Session=03': {
                    'values': [0.8, 1.4],
                  },
                  'Condition=Distr|group=ADV|Session=06': {
                    'values': [0.5, 1.5],
                  },
                },
              ),
            ),
          ),
        ),
      );

      expect(find.text('Off'), findsOneWidget);
      expect(find.text('Top 4'), findsOneWidget);
      expect(find.text('All'), findsOneWidget);
      expect(
        find.textContaining('Markers show up to 4 most significant contrasts'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('All'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Markers show up to 8 matching cell contrasts'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Off'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Significance brackets hidden on plot'),
        findsOneWidget,
      );

      await tester.tap(find.textContaining('Corrected contrast details'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
  test('groupMetricLabel preserves ERP difference suffixes cleanly', () {
    expect(
      groupMetricLabel('mean_amplitude_ERP (Rare − Freq)'),
      'Mean amplitude (µV) (Rare − Freq)',
    );
    expect(
      groupMetricLabel('peak_latency_ms_ERP (Rare − Freq)'),
      'Peak latency (ms) (Rare − Freq)',
    );
    expect(groupMetricLabel('mean_amplitude_ERP'), 'Mean amplitude (µV)');
  });
  testWidgets(
    'boxplot renders Tukey whiskers and subtle data points cleanly in both preview and results mode',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1100, 750));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final boxConfig = config.copyWith(plotType: StatsPlotType.boxplot);
      final levels = {
        'Condition': ['Freq', 'Rare'],
        'group': ['ADV', 'CON'],
        'Session': ['03'],
      };
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  ConfigurableStatsPlotWidget(
                    config: boxConfig,
                    factorLevels: levels,
                    activeFactors: levels.keys.toList(),
                    isDummyPreview: true,
                    height: 290,
                  ),
                  ConfigurableStatsPlotWidget(
                    config: boxConfig,
                    factorLevels: levels,
                    activeFactors: levels.keys.toList(),
                    cellDescriptives: const {
                      'Condition=Freq|group=ADV|Session=03': {
                        'values': [-0.5, 0.2, 0.4, 0.8, 1.1, 1.3, 1.9, 2.8],
                      },
                      'Condition=Rare|group=ADV|Session=03': {
                        'values': [0.5, 1.0, 1.2, 1.5, 1.8, 2.2, 2.5, 3.6],
                      },
                      'Condition=Freq|group=CON|Session=03': {
                        'values': [0.1, 0.4, 0.6, 0.9, 1.0, 1.2, 1.4],
                      },
                      'Condition=Rare|group=CON|Session=03': {
                        'values': [1.0, 1.3, 1.7, 2.0, 2.3, 2.7, 3.1],
                      },
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      expect(find.text('SAMPLE DUMMY PREVIEW'), findsOneWidget);
      expect(find.text('Visit: Baseline'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'statsPlotBrackets filters by bracketFactorFilter to isolate between-group contrasts',
    () {
      const multiConfig = StatsPlotLayoutConfig(
        xFactor: 'Condition',
        seriesFactor: 'group',
        facetColFactor: 'Session',
      );
      final multiLevels = {
        'Condition': ['Distr', 'Freq', 'Rare'],
        'group': ['ADV', 'CON'],
        'Session': ['03'],
      };
      final mixedContrasts = <Map<String, dynamic>>[
        {
          'factor': 'group',
          'group_a': 'ADV',
          'group_b': 'CON',
          'p_adj': 0.03,
          'stratum': {'Condition': 'Distr', 'Session': '03'},
        },
        {
          'factor': 'Condition',
          'group_a': 'Distr',
          'group_b': 'Freq',
          'p_adj': 0.0001,
          'stratum': {'group': 'ADV', 'Session': '03'},
        },
      ];
      final onlyGroup = statsPlotBrackets(
        config: multiConfig,
        contrasts: mixedContrasts,
        factors: multiLevels.keys.toList(),
        levels: multiLevels,
        column: '03',
        bracketFactorFilter: 'group',
      );
      expect(onlyGroup, hasLength(1));
      expect(onlyGroup.first.label, 'ADV–CON *');

      final onlyCond = statsPlotBrackets(
        config: multiConfig,
        contrasts: mixedContrasts,
        factors: multiLevels.keys.toList(),
        levels: multiLevels,
        column: '03',
        bracketFactorFilter: 'Condition',
      );
      expect(onlyCond, hasLength(1));
      expect(onlyCond.first.label, 'ADV ***');
    },
  );
  test(
    'ErpGroupStatsEngine.applyComparisonSelection filters factors, scope, and specific pairs with exact p-value adjustment',
    () {
      final allContrasts = <Map<String, dynamic>>[
        {
          'factor': 'group',
          'group_a': 'CON',
          'group_b': 'ADV',
          'stratum': {'Session': '03'},
          'p_raw': 0.01,
        },
        {
          'factor': 'group',
          'group_a': 'CON',
          'group_b': 'NOV',
          'stratum': {'Session': '03'},
          'p_raw': 0.20,
        },
        {
          'factor': 'group',
          'group_a': 'NOV',
          'group_b': 'ADV',
          'stratum': <String, dynamic>{},
          'p_raw': 0.40,
        },
        {
          'factor': 'Session',
          'group_a': '03',
          'group_b': '05',
          'stratum': {'group': 'CON'},
          'p_raw': 0.001,
        },
      ];

      // 1. Multi-factor (group + Session) + simple effects only + CON vs ADV pair only
      final subset = ErpGroupStatsEngine.applyComparisonSelection(
        allPosthocs: allContrasts,
        selectedFactors: {'group', 'Session'},
        scope: 'simple',
        selectedPairsByFactor: {
          'group': {ErpGroupStatsEngine.canonicalPairKey('ADV', 'CON')},
        },
        posthocMethod: 'bonferroni',
      );
      expect(subset, hasLength(2));
      expect(subset[0]['p_adj'], closeTo(0.02, 1e-9));
      expect(subset[0]['significant'], isTrue);
      expect(subset[1]['p_adj'], closeTo(0.002, 1e-9));

      // 2. Marginal only across group
      final marginalOnly = ErpGroupStatsEngine.applyComparisonSelection(
        allPosthocs: allContrasts,
        selectedFactors: {'group'},
        scope: 'marginal',
        posthocMethod: 'fdr',
      );
      expect(marginalOnly, hasLength(1));
      expect(marginalOnly.first['group_a'], 'NOV');
      expect(marginalOnly.first['p_adj'], closeTo(0.40, 1e-9));
    },
  );
}
