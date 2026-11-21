import 'dart:convert';
import 'dart:io';

/// Explicit identity survives flat batch output folders without renaming signals.
String? recordingSubject(String path) {
  try {
    final sidecar = File('$path.subject.json');
    if (sidecar.existsSync()) {
      final id = (jsonDecode(sidecar.readAsStringSync()) as Map)['subject_id'];
      if (id is String && id.trim().isNotEmpty) return id.trim();
    }
  } catch (_) { /* Ignore malformed optional metadata; infer from the name. */ }
  final name = path.split(RegExp(r'[/\\]')).last;
  final match = RegExp(r'^(Sub\d+_TKG\d+)(?:_|\.)', caseSensitive: false).firstMatch(name);
  return match?.group(1);
}

void saveRecordingSubject(String output, String subject, String source) {
  File('$output.subject.json').writeAsStringSync(jsonEncode({
    'subject_id': subject, 'source_path': source,
  }), flush: true);
}
