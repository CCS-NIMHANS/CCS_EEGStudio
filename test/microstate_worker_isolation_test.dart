import 'dart:io';

import 'package:ccs_eeg_app/src/filtered_file_picker.dart';
import 'package:ccs_eeg_app/src/group_statistics.dart';
import 'package:ccs_eeg_app/src/microstate_analysis.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _LiveWorkerCallerHost extends StatefulWidget {
  const _LiveWorkerCallerHost({required this.tempPath});
  final String tempPath;

  @override
  State<_LiveWorkerCallerHost> createState() => _LiveWorkerCallerHostState();
}

class _LiveWorkerCallerHostState extends State<_LiveWorkerCallerHost> {
  String _status = 'idle';

  Future<void> triggerAllWorkers() async {
    // Intentionally capture `context`, `setState`, and `this` in the async State
    // closure to reproduce the exact Dart shared-closure-context failure mode
    // that triggered `Illegal argument in isolate message: object is unsendable`
    // when Isolate.run was invoked inside instance methods.
    final title = Theme.of(context).platform.name;
    final outPath = '${widget.tempPath}/signal.ccseeg.json';
    await writeMicrostateSignalInWorker(outPath, {
      'format': 'ccseeg-v1',
      'platform': title,
      'sample_rate': 250.0,
      'labels': ['Cz', 'Pz'],
      'channels': [
        [0.1, -0.1, 0.2],
        [0.0, 0.2, -0.2],
      ],
    });
    final decoded = await decodeMicrostateJsonInWorker(
      await File(outPath).readAsString(),
    );
    final permRes = await runDartPermutationsInWorker({
      'headers': ['subjid', 'group', 'mean_uv'],
      'rows': [
        ['S1', 'A', '1.0'],
        ['S2', 'A', '1.2'],
        ['S3', 'B', '3.0'],
        ['S4', 'B', '3.2'],
      ],
      'factors': ['group'],
      'metrics': ['mean_uv'],
      'subjectCol': 'subjid',
      'preferredModel': 'glm',
      'posthocMethod': 'fdr',
      'includeInteractions': false,
      'nPermutations': 50,
      'excludedLevels': <String, List<String>>{},
      'customLevelOrder': <String, List<String>>{},
    });
    if (!mounted) return;
    setState(() {
      _status =
          'ok:${decoded['format']}:${(permRes['results'] as List).length}';
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(body: Text(_status));
}

void main() {
  testWidgets(
    'top-level microstate & permutation workers never capture State or WidgetsFlutterBinding',
    (tester) async {
      final tmp = Directory.systemTemp.createTempSync('ccs_ms_worker_test_');
      try {
        await tester.pumpWidget(
          MaterialApp(home: _LiveWorkerCallerHost(tempPath: tmp.path)),
        );
        final state = tester.state<_LiveWorkerCallerHostState>(
          find.byType(_LiveWorkerCallerHost),
        );
        await tester.runAsync(
          () => state.triggerAllWorkers().timeout(const Duration(seconds: 15)),
        );
        await tester.pump();
        expect(find.text('ok:ccseeg-v1:1'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        if (tmp.existsSync()) {
          tmp.deleteSync(recursive: true);
        }
      }
    },
  );

  test('resolveSafeInitialDirectory picks reachable local directory and skips slow mounts', () async {
    final tmp = await Directory.systemTemp.createTemp('ccs_picker_dir_test_');
    try {
      // 1. Existing local current directory is preserved
      final cur = await resolveSafeInitialDirectory(currentDirectory: tmp.path);
      expect(cur, tmp.path);

      // 2. Non-existent current directory falls back to local file's parent directory
      final testFile = File('${tmp.path}/sample.edf');
      await testFile.writeAsString('stub');
      final fromFile = await resolveSafeInitialDirectory(
        currentDirectory: '${tmp.path}/missing_subdir',
        fallbackFilePath: testFile.path,
      );
      expect(fromFile, tmp.path);

      // 3. Network mount (/Volumes/...) fallback is skipped in favor of local HOME
      final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
      if (home != null && Directory(home).existsSync()) {
        final fromNetwork = await resolveSafeInitialDirectory(
          currentDirectory: '/Volumes/DoesNotExist_Mount_XYZ/missing',
          fallbackFilePath: '/Volumes/RemoteShare/study/subject01.edf',
        );
        expect(fromNetwork, home);
      }
    } finally {
      if (await tmp.exists()) {
        await tmp.delete(recursive: true);
      }
    }
  });
}
