import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/recording_save_dialog.dart';
import 'package:ccs_eeg_app/src/recording_storage.dart';
import 'package:ccs_eeg_app/src/topostats/topostats_batch.dart';
import 'package:ccs_eeg_app/src/topostats/topostats_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      'DejaVuSans',
    )..addFont(rootBundle.load('assets/fonts/DejaVuSans.ttf'))).load();
  });
  test(
    'source atlas features generate PNG and PDF without electrode positions',
    () async {
      final dir = await Directory.systemTemp.createTemp('source_plot_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final csv = File('${dir.path}/source.features.csv');
      await csv.writeAsString(
        'Chan,Epoch,Alpha_PSD,epoch_start_s,epoch_end_s\n'
        'bankssts-lh,1,0.2,0,2\nbankssts-rh,1,0.3,0,2\n'
        'bankssts-lh,2,0.4,2,4\nbankssts-rh,2,0.5,2,4\n',
      );
      final outputs = await generateTopoStatsFigures(
        csvPaths: [csv.path],
        outputDir: dir.path,
        base: const TopoStatsSettings(epochSize: 2),
        features: ['Alpha_PSD'],
      );
      expect(outputs, hasLength(1));
      expect(await File(outputs.single.path).length(), greaterThan(1000));
      expect(
        await File(outputs.single.path.replaceFirst('.png', '.pdf')).exists(),
        isTrue,
      );
    },
  );
  testWidgets(
    'save form validates and returns a canonical path without a native save sheet',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('recording_save_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final old = RecordingStorage.preferredFormat;
      addTearDown(() => RecordingStorage.preferredFormat = old);
      RecordingStorage.preferredFormat = RecordingFileFormat.edf;
      String? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  selected = await showDialog<String>(
                    context: context,
                    builder: (_) => RecordingSavePathDialog(
                      title: 'Save EEG',
                      filename: 'clean.edf',
                      initialDirectory: dir.path,
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '../bad.edf');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(
        find.text('Enter a filename without folder separators.'),
        findsOneWidget,
      );
      await tester.enterText(find.byType(TextField).first, 'clean.edf');
      await tester.runAsync(() async {
        await tester.tap(find.text('Save'));
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await tester.pumpAndSettle();
      expect(selected, '${dir.path}${Platform.pathSeparator}clean.edf');
    },
  );
  test('local reported source CSV renders', () async {
    final file = File(Platform.environment['CCS_SOURCE_FEATURE_CSV'] ?? '');
    if (file.path.isEmpty || !file.existsSync()) return;
    final results = await generateTopoStatsFigures(
      csvPaths: [file.path],
      outputDir: '/private/tmp/ccs-source-feature-verification',
      features: ['Alpha_PSD'],
      writePdf: true,
    );
    expect(results, hasLength(1));
  });
}
