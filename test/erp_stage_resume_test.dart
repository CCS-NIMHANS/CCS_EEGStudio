import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/erp/erp_workbench_view.dart';

void main() {
  testWidgets(
    'one navigator exposes a usable entry point for each later stage',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: ErpWorkbenchView(batchMode: true)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Columns'), findsNothing);
      expect(find.text('Tabs'), findsNothing);
      expect(
        find.text('Use Stage 1 outputs (or choose recordings directly)'),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('erp-stage-1')));
      await tester.pumpAndSettle();
      expect(find.text('Load cleaned EEG…'), findsOneWidget);
      expect(find.text('Load saved epochs…'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('erp-stage-2')));
      await tester.pumpAndSettle();
      expect(find.text('Load saved epochs…'), findsOneWidget);
      expect(find.text('Load cleaned EEG…'), findsNothing);
      expect(find.text('Measure ERP for 0 recording(s)'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('erp-stage-3')));
      await tester.pumpAndSettle();
      expect(find.text('Group Statistics'), findsOneWidget);
      expect(find.text('Load Saved ERP Folder…'), findsOneWidget);
      expect(find.text('Measure ERP for 0 recording(s)'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'embedded preprocessing uses the ERP handoff callback, not a separate run',
    (tester) async {
      var runs = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ErpWorkbenchView(
              batchMode: true,
              onRunPreprocessing: () async {
                runs++;
                return [];
              },
              stage1Builder:
                  ({VoidCallback? onNext, Future<void> Function()? onRun}) =>
                      Center(
                        child: FilledButton(
                          onPressed: onRun,
                          child: const Text('Clean selected recordings'),
                        ),
                      ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final run = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Clean selected recordings'),
      );
      expect(run.onPressed, isNotNull);
      await tester.tap(find.text('Clean selected recordings'));
      await tester.pumpAndSettle();
      expect(runs, 1);
      expect(
        find.text('Clean selected recordings'),
        findsOneWidget,
      ); // no output: do not advance
      expect(tester.takeException(), isNull);
    },
  );
}
