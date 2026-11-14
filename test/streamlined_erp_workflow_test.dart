import 'package:ccs_eeg_app/src/app.dart';
import 'package:ccs_eeg_app/src/filtered_file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  testWidgets(
    'ERP has one epoch and averaging workspace with optional cleaning',
    (tester) async {
      PackageInfo.setMockInitialValues(
        appName: 'CCS EEG Studio',
        packageName: 'ccs',
        version: '1.2.23',
        buildNumber: '24',
        buildSignature: '',
      );
      tester.view.physicalSize = const Size(1800, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(const CcsEegApp());
      await tester.pumpAndSettle();
      expect(find.text('v1.2.23'), findsOneWidget);
      await tester.tap(find.text('Continuous EEG').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('ERP Analysis').last);
      await tester.pumpAndSettle();
      expect(find.text('Epochs'), findsNothing);
      expect(find.text('Epochs & ERP'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('erp-order-false')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Epoch → Clean').last);
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('Epochs & ERP')).dx,
        lessThan(tester.getTopLeft(find.text('Preprocess')).dx),
      );
      await tester.tap(find.byKey(const ValueKey('erp-order-true')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clean → Epoch').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Preprocess'));
      await tester.pumpAndSettle();
      expect(find.text('Next: Epochs & ERP'), findsOneWidget);
      await tester.tap(find.text('Next: Epochs & ERP'));
      await tester.pumpAndSettle();
      expect(find.text('Open EEG / epochs'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  test('picker explains the correct input role', () {
    expect(
      recordingFileDescription('P300-epo_clean.edf'),
      contains('Saved epochs'),
    );
    expect(
      recordingFileDescription('P300_clean.edf'),
      contains('Preprocessed EEG'),
    );
    expect(recordingFileDescription('P300.xdf'), contains('XDF container'));
    expect(isEegRecordingFile('protocol.ccsprotocol'), isFalse);
    expect(isEegRecordingFile('summary.csv'), isFalse);
    expect(isEegRecordingFile('raw.xdf'), isTrue);
  });
}
