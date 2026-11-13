import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'recording_storage.dart';

String recordingDialogStem(String filename) => filename.replaceFirst(
  RegExp(
    r'(?:\.(?:edf|fif|ccseeg|json|vhdr|set|mat|orb|xdf))+$',
    caseSensitive: false,
  ),
  '',
);

/// Native save panels append their selected type. Do not supply it twice.
Future<String?> saveRecordingDialog(
  BuildContext context, {
  required String dialogTitle,
  required String fileName,
  String? initialDirectory,
  FileType? type,
  List<String>? allowedExtensions,
}) async {
  if (!context.mounted) return null;
  final String? picked;
  if (Platform.isMacOS) {
    picked = await showDialog<String>(
      context: context,
      builder: (_) => RecordingSavePathDialog(
        title: dialogTitle,
        filename:
            '${recordingDialogStem(fileName)}.${RecordingStorage.extension}',
        initialDirectory:
            initialDirectory ??
            Platform.environment['HOME'] ??
            Directory.current.path,
      ),
    );
  } else {
    picked = await FilePicker.saveFile(
      dialogTitle: dialogTitle,
      fileName: recordingDialogStem(fileName),
      type: FileType.custom,
      allowedExtensions: [RecordingStorage.extension],
    );
  }
  if (picked == null) return null;
  final canonical = RecordingStorage.withExtension(picked);
  if (canonical != picked && File(canonical).existsSync()) {
    if (!context.mounted) return null;
    final replace = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Replace existing recording?'),
        content: Text(canonical),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Replace'),
          ),
        ],
      ),
    );
    if (replace != true) return null;
  }
  return canonical;
}

/// A Flutter save form avoids a stalled macOS NSSavePanel sheet while keeping
/// folder browsing available. No signal work runs until the form is dismissed.
class RecordingSavePathDialog extends StatefulWidget {
  const RecordingSavePathDialog({
    super.key,
    required this.title,
    required this.filename,
    required this.initialDirectory,
  });
  final String title, filename, initialDirectory;
  @override
  State<RecordingSavePathDialog> createState() =>
      _RecordingSavePathDialogState();
}

class _RecordingSavePathDialogState extends State<RecordingSavePathDialog> {
  late final folder = TextEditingController(text: widget.initialDirectory);
  late final name = TextEditingController(text: widget.filename);
  String? error;
  bool browsing = false;
  @override
  void dispose() {
    folder.dispose();
    name.dispose();
    super.dispose();
  }

  Future<void> save() async {
    final directory = folder.text.trim();
    final filename = name.text.trim();
    if (filename.isEmpty ||
        filename == '.' ||
        filename == '..' ||
        filename.contains(RegExp(r'[\\/]'))) {
      setState(() => error = 'Enter a filename without folder separators.');
      return;
    }
    if (!await Directory(directory).exists()) {
      if (mounted) setState(() => error = 'Choose an existing output folder.');
      return;
    }
    final path = RecordingStorage.withExtension(
      '$directory${Platform.pathSeparator}$filename',
    );
    if (!mounted) return;
    if (await File(path).exists()) {
      if (!mounted) return;
      final replace = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Replace existing recording?'),
          content: Text(path),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Replace'),
            ),
          ],
        ),
      );
      if (replace != true || !mounted) return;
    }
    if (mounted) Navigator.pop(context, path);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 560,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: name,
            decoration: const InputDecoration(labelText: 'File name'),
            onSubmitted: (_) => save(),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: folder,
            decoration: const InputDecoration(labelText: 'Output folder'),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: browsing
                  ? null
                  : () async {
                      setState(() => browsing = true);
                      try {
                        final picked = await FilePicker.getDirectoryPath(
                          initialDirectory: folder.text,
                        );
                        if (picked != null && mounted) folder.text = picked;
                      } finally {
                        if (mounted) setState(() => browsing = false);
                      }
                    },
              icon: const Icon(Icons.folder_open),
              label: const Text('Browse folders…'),
            ),
          ),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: browsing ? null : save,
        child: const Text('Save'),
      ),
    ],
  );
}
