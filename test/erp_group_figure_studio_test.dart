import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/erp/group_figure_studio.dart';
import 'package:ccs_eeg_app/src/group_statistics_plots.dart';

void main() {
  testWidgets(
    'publication studio offers regrouping, model modes and time-frequency parameters',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: ErpGroupFigureStudio(
            inspection: const {
              'headers': ['participant_id', 'group', 'Session', 'Condition'],
              'rows': [],
              'factor_levels': {
                'group': ['ADV', 'CON'],
                'Session': ['03', '05'],
                'Condition': ['Freq', 'Rare'],
              },
            },
            csvPath:
                '${Directory.systemTemp.path}${Platform.pathSeparator}measurements.csv',
            config: const StatsPlotLayoutConfig(
              seriesFactor: 'group',
              facetColFactor: 'Session',
            ),
            levelOrder: const {},
            excludedLevels: const {},
            findPython: () async => null,
          ),
        ),
      );
      expect(find.text('Grouped ERP publication studio'), findsOneWidget);
      expect(find.text('Lines / cohorts'), findsOneWidget);
      await tester.tap(find.text('ERP grand averages'));
      await tester.pumpAndSettle();
      expect(find.text('rERP coefficients'), findsOneWidget);
      expect(find.text('ML decoding AUC'), findsOneWidget);
      await tester.tap(find.text('ITC (recompute epochs)').last);
      await tester.pumpAndSettle();
      expect(find.text('Minimum Hz'), findsOneWidget);
      expect(find.text('Baseline start ms'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
