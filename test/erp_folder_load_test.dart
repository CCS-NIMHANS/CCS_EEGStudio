import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/erp/erp_workbench_view.dart';

void main() {
  test('loadErpFolderInWorker merges multiple ccserp files off UI isolate', () async {
    final dir = await Directory.systemTemp.createTemp('ccs_erp_folder_');
    try {
      for (final subj in ['S01', 'S02']) {
        final f = File('${dir.path}${Platform.pathSeparator}${subj}_erp_results.ccserp');
        await f.writeAsString(jsonEncode({
          'schema': 'ccs-erp-workbench-v1',
          'files': [
            {
              'path': '/tmp/$subj.edf',
              'subject': subj,
              'task': 'Custom',
              'times': [-0.2, 0.0, 0.2],
              'labels': ['Fz', 'Cz', 'Pz'],
              'condition_names': ['Freq', 'Rare'],
              'condition_waves': {
                'Freq': [0.0, 1.0, 0.5],
                'Rare': [0.0, 3.0, 1.5],
              },
              'a': [0.0, 1.0, 0.5],
              'b': [0.0, 3.0, 1.5],
              'difference': [0.0, 2.0, 1.0],
              'roi': 'Pz',
              'a_label': 'Freq',
              'b_label': 'Rare',
              'n_a': 50,
              'n_b': 20,
              'window_ms': [200.0, 400.0],
            }
          ],
          'groups': [
            {'task': 'Custom'}
          ],
        }));
      }

      final paths = dir
          .listSync()
          .whereType<File>()
          .map((f) => f.path)
          .toList()
        ..sort();
      final res = await Isolate.run(() => loadErpFolderInWorker(paths));
      expect(res.loadedFiles, 2);
      final files = res.merged['files'] as List;
      expect(files.length, 2);
      final groups = res.merged['groups'] as List;
      expect(groups.length, 1);
      final grp = groups.first as Map;
      expect(grp['task'], 'Custom');
      expect((grp['a'] as List)[1], closeTo(1.0, 1e-6));
      expect((grp['b'] as List)[1], closeTo(3.0, 1e-6));
    } finally {
      await dir.delete(recursive: true);
    }
  });

  testWidgets('Batch ERP header exposes Load Saved ERP Folder button', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ErpWorkbenchView(batchMode: true),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('erp-stage-3')));
    await tester.pumpAndSettle();
    expect(find.text('Load Saved ERP Folder…'), findsOneWidget);
    expect(find.text('Group Statistics'), findsOneWidget);
  });

  test('loads a bounded real TestBin_20261119 sample via loadErpFolderInWorker', () async {
    const dirPath = '/Volumes/CCS Storage/CCS_UserFolders/neethi/SKYMeditation_2026/AOBD_Analysis/TestBin_20261119';
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return;
    final entries = await dir
        .list(recursive: false, followLinks: false)
        .where((e) => e is File)
        .cast<File>()
        .toList();
    final candidates = entries
        .where((f) {
          final lower = f.path.toLowerCase();
          return lower.endsWith('.ccserp') ||
              (lower.endsWith('.json') && lower.contains('erp_results'));
        })
        .map((f) => f.path)
        .toList()
      ..sort();
    // ignore: avoid_print
    print('Found ${candidates.length} candidates');
    final sw = Stopwatch()..start();
    final res = await Isolate.run(() => loadErpFolderInWorker(candidates.take(3).toList()));
    sw.stop();
    // ignore: avoid_print
    print('Loaded ${res.loadedFiles} files in ${sw.elapsedMilliseconds} ms');
    expect(res.loadedFiles, greaterThan(0));
    expect((res.merged['files'] as List).length, greaterThan(0));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
