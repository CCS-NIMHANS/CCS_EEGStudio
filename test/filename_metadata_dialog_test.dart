import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/filename_metadata.dart';
import 'package:ccs_eeg_app/src/filename_metadata_dialog.dart';

void main() {
  test(
    'detects participant/session in full recording paths without guessing cohorts',
    () {
      const name = '/Volumes/Study/SKYMED013SESSION03-epo_clean.edf';
      final row = inferFilenameMetadata([name]).single;
      expect(row['Subject'], 'SKYMED013');
      expect(row['Session'], '03');
      expect(row, isNot(contains('Group')));
      expect(row['filename'], name);
    },
  );

  test('visible parts map to chosen roles and keep full join paths', () {
    const names = ['/data/S01_03_Rare.edf', '/data/S02_05_Freq.edf'];
    final rows = mapFilenameParts(
      names,
      separator: '_',
      roles: {0: 'Subject', 1: 'Session', 2: 'Condition'},
    );
    expect(rows.last['Subject'], 'S02');
    expect(rows.last['Condition'], 'Freq');
    expect(rows.last['filename'], names.last);
    expect(filenameBasename(names.first), 'S01_03_Rare.edf');
  });

  testWidgets('offers a preview and clickable parts without a regex field', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: FilenameMetadataDialog(
            names: ['/data/SKYMED013SESSION03-epo_clean.edf'],
          ),
        ),
      ),
    );
    expect(find.text('Optional regex with named groups'), findsNothing);
    expect(find.text('Use these reviewed labels'), findsOneWidget);
    expect(find.text('SKYMED013SESSION03-epo_clean.edf'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (w) => w is TextFormField && w.initialValue == 'SKYMED013',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Choose filename parts'));
    await tester.pumpAndSettle();
    expect(find.text('Separate filename parts at'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
