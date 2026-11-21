import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

/// Scratch is placed alongside the output by default, rather than silently on C:.
class ProcessingWorkspace {
  static int requiredBytes(int channels, int samples) =>
      math.max(512 * 1024 * 1024, channels * samples * 48);

  static Future<int?> availableBytes(Directory directory) async {
    Process? process;
    try {
      if (Platform.isWindows) {
        final path = directory.absolute.path.replaceAll("'", "''");
        process = await Process.start('powershell.exe', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          "\$ErrorActionPreference='Stop'; \$r=[System.IO.Path]::GetPathRoot('$path'); ([System.IO.DriveInfo]::new(\$r)).AvailableFreeSpace",
        ]);
      } else {
        process = await Process.start('df', ['-Pk', directory.absolute.path]);
      }
      final running = process;
      final stdout = running.stdout
          .transform(const SystemEncoding().decoder)
          .join();
      final stderr = running.stderr.drain<void>();
      final code = await running.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          running.kill();
          return -1;
        },
      );
      final text = await stdout;
      await stderr;
      if (code != 0) return null;
      if (Platform.isWindows) return int.tryParse(text.trim());
      final fields = text.trim().split('\n').last.trim().split(RegExp(r'\s+'));
      return fields.length >= 4 ? int.tryParse(fields[3])! * 1024 : null;
    } catch (_) {
      process?.kill();
      return null;
    }
  }

  static Future<Directory> create({
    required String outputPath,
    required int channels,
    required int samples,
    String? preferredDirectory,
    Future<int?> Function(Directory)? freeBytes,
    required void Function(String) report,
  }) async {
    final output = File(outputPath).absolute.parent;
    final root = Directory(
      preferredDirectory ??
          Platform.environment['CCS_EEG_WORK_DIR'] ??
          output.path,
    );
    await root.create(recursive: true);
    await output.create(recursive: true);
    final probe = freeBytes ?? availableBytes;
    for (final directory in {
      root.absolute.path: root,
      output.path: output,
    }.values) {
      final free = await probe(directory);
      final required = requiredBytes(channels, samples);
      if (free != null && free < required) {
        throw FileSystemException(
          'Insufficient free disk space: ${(free / (1024 * 1024 * 1024)).toStringAsFixed(2)} GiB available; '
          'allow at least ${(required / (1024 * 1024 * 1024)).toStringAsFixed(2)} GiB for staging. '
          'Choose a working folder and output folder on a drive with more space, or free space before retrying.',
          directory.path,
        );
      }
      report(
        free == null
            ? 'Could not query free space: ${directory.path}'
            : 'Disk space: ${(free / (1024 * 1024 * 1024)).toStringAsFixed(1)} GiB available at ${directory.path}',
      );
    }
    final temp = await root.createTemp('ccs_eeg_work_');
    report('Temporary working folder: ${temp.path}');
    return temp;
  }
}
