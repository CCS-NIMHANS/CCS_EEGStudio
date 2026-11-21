import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/processing_workspace.dart';

void main() {
  test('low disk aborts before staging and explains recovery', () async {
    final root = await Directory.systemTemp.createTemp('space-check-');
    addTearDown(() => root.delete(recursive: true));
    await expectLater(
      ProcessingWorkspace.create(
        outputPath: '${root.path}${Platform.pathSeparator}clean.edf',
        channels: 32,
        samples: 1000000,
        freeBytes: (_) async => 100 * 1024 * 1024,
        report: (_) {},
      ),
      throwsA(
        isA<FileSystemException>().having(
          (e) => e.message,
          'message',
          contains('Choose a working folder'),
        ),
      ),
    );
    expect(root.listSync(), isEmpty);
  });
  test(
    'chosen drive holds staging; unknown free space does not prevent processing',
    () async {
      final root = await Directory.systemTemp.createTemp('workspace-test-');
      addTearDown(() => root.delete(recursive: true));
      final chosen = Directory('${root.path}${Platform.pathSeparator}scratch');
      final output =
          '${root.path}${Platform.pathSeparator}output${Platform.pathSeparator}clean.edf';
      final queried = <String>[];
      final temp = await ProcessingWorkspace.create(
        outputPath: output,
        channels: 8,
        samples: 1000,
        preferredDirectory: chosen.path,
        freeBytes: (directory) async {
          queried.add(directory.path);
          return null;
        },
        report: (_) {},
      );
      expect(temp.parent.path, chosen.absolute.path);
      expect(queried, hasLength(2));
      await temp.delete();
      final free = await ProcessingWorkspace.availableBytes(root);
      expect(free, greaterThan(0));
    },
  );
}
