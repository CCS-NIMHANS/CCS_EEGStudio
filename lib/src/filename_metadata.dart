String filenameBasename(String path) => path.split(RegExp(r'[/\\]')).last;

List<String> filenameParts(String path, {String separator = '_'}) {
  final stem = filenameBasename(path).replaceFirst(RegExp(r'\.[^.]+$'), '');
  return stem.split(separator).where((p) => p.isNotEmpty).toList();
}

List<Map<String, String>> mapFilenameParts(
  Iterable<String> names, {
  required String separator,
  required Map<int, String> roles,
}) => names.toSet().map((name) {
  final parts = filenameParts(name, separator: separator);
  return <String, String>{
    'filename': name,
    for (final entry in roles.entries)
      if (entry.value != 'Ignore' && entry.key < parts.length)
        entry.value: parts[entry.key],
  };
}).toList();

/// Filename metadata is descriptive: no demographic/clinical fields are guessed.
List<Map<String, String>> inferFilenameMetadata(
  Iterable<String> names, {
  String? pattern,
}) {
  final custom = pattern == null || pattern.trim().isEmpty
      ? null
      : RegExp(pattern);
  const fields = {
    'sub': 'Subject',
    'ses': 'Session',
    'task': 'Task',
    'run': 'Run',
    'acq': 'Acquisition',
  };
  return names.toSet().map((name) {
    final row = <String, String>{'filename': name};
    final stem = filenameBasename(name).replaceFirst(RegExp(r'\.[^.]+$'), '');
    if (custom != null) {
      final match = custom.firstMatch(name);
      if (match != null) {
        for (final key in match.groupNames) {
          final value = match.namedGroup(key);
          if (value != null && value.isNotEmpty && key != 'filename')
            row[key] = value;
        }
      }
    } else {
      for (final match in RegExp(
        r'(?:^|_)(sub|ses|task|run|acq)-([^_]+)',
      ).allMatches(stem)) {
        row[fields[match[1]]!] = match[2]!;
      }
      final legacy = RegExp(
        r'^(Sub\d+)_',
        caseSensitive: false,
      ).firstMatch(stem);
      if (!row.containsKey('Subject') && legacy != null)
        row['Subject'] = legacy[1]!;
      final concatenated = RegExp(
        r'^([A-Za-z]+[-_]?\d+)[-_]?(?:session|ses|visit)[-_]?(\d+)',
        caseSensitive: false,
      ).firstMatch(stem);
      if (concatenated != null) {
        row.putIfAbsent('Subject', () => concatenated[1]!);
        row.putIfAbsent('Session', () => concatenated[2]!);
      }
    }
    return row;
  }).toList();
}

String filenameMetadataCsv(List<Map<String, String>> rows) {
  final cols = <String>{
    'filename',
    for (final row in rows) ...row.keys,
  }.toList();
  String quote(String value) => '"${value.replaceAll('"', '""')}"';
  return '${cols.map(quote).join(',')}\n${rows.map((row) => cols.map((col) => quote(row[col] ?? '')).join(',')).join('\n')}\n';
}
