import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/erp/factor_grouping_designer.dart';
import 'package:ccs_eeg_app/src/erp/workbench_service.dart';

void main() {
  test(
    'extractRecordingSubject and extractSessionToken parse concatenated SKYMED+SESSION IDs',
    () {
      expect(
        extractRecordingSubject('/data/SKYMED013SESSION03-epo_clean.edf'),
        'SKYMED013',
      );
      expect(
        extractRecordingSubject('/data/SKYMED104SESSION06_clean.edf'),
        'SKYMED104',
      );
      expect(
        FactorGroupingDesignerDialog.extractSessionToken(
          'SKYMED013SESSION03-epo_clean',
        ),
        'SESSION03',
      );
      expect(
        FactorGroupingDesignerDialog.extractSessionToken(
          'sub-01_ses-02_task-oddball_eeg',
        ),
        '02',
      );
    },
  );

  test(
    'matchSheetRow performs longest boundary-safe match without prefix collision',
    () {
      final lookup = {
        'skymed01': {'Group': 'OLD'},
        'skymed013': {'Group': 'ADV'},
      };
      final hit13 = FactorGroupingDesignerDialog.matchSheetRow(
        '/data/SKYMED013SESSION03-epo_clean.edf',
        'SKYMED013',
        lookup,
      );
      expect(hit13?['Group'], 'ADV');

      final lookupPrefixOnly = {
        'skymed01': {'Group': 'OLD'},
      };
      final noFalseHit = FactorGroupingDesignerDialog.matchSheetRow(
        '/data/SKYMED013SESSION03-epo_clean.edf',
        'SKYMED013SESSION03',
        lookupPrefixOnly,
      );
      expect(noFalseHit, isNull);
    },
  );

  testWidgets(
    'FactorGroupingDesignerDialog allows excluding "Unknown" group level',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 960);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      FactorGroupingResult? captured;
      final files = [
        '/tmp/study/SKYMED013SESSION03-epo_clean.edf',
        '/tmp/study/SKYMED014SESSION03-epo_clean.edf',
        '/tmp/study/SKYMED046SESSION03-epo_clean.edf',
      ];
      final initialGroups = {
        'SKYMED013': 'ADV',
        'SKYMED014': 'CON',
      };

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () async {
                  captured = await FactorGroupingDesignerDialog.show(
                    context,
                    filePaths: files,
                    initialParticipantGroups: initialGroups,
                  );
                },
                child: const Text('Open Designer'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Designer'));
      await tester.pumpAndSettle();

      expect(find.text('3 / 3 files active'), findsOneWidget);
      expect(find.text('Exclude Unknown (1)'), findsOneWidget);

      await tester.tap(find.text('Exclude Unknown (1)'));
      await tester.pumpAndSettle();

      expect(find.text('2 / 3 files active'), findsOneWidget);

      await tester.tap(find.text('Apply Factors & Grouping'));
      await tester.pumpAndSettle();

      expect(captured, isNotNull);
      expect(captured!.excludedFiles, {files[2]});
      expect(captured!.excludedLevelsByFactor['Group'], {'Unknown'});
      expect(captured!.participantGroups, {'SKYMED013': 'ADV', 'SKYMED014': 'CON'});
    },
  );
}
