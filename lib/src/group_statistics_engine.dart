import 'dart:io';
import 'dart:math' as math;

import 'erp/factor_grouping_designer.dart';

/// Pure-Dart statistical distributions and multiple-testing helpers.
class StatMath {
  static const double epsilon = 1e-14;
  static const double tiny = 1e-30;

  static double logGamma(double x) {
    const p = [
      0.99999999999980993,
      676.52093408287859,
      -1259.1392167224028,
      771.32342877765313,
      -176.61502916214059,
      12.507343278686905,
      -0.13857109583115912,
      9.9843695780195716e-6,
      1.5056327351493116e-7,
    ];
    if (x < 0.5) {
      return math.log(math.pi / math.sin(math.pi * x)) - logGamma(1.0 - x);
    }
    x -= 1.0;
    var a = p[0];
    final t = x + 7.5;
    for (var i = 1; i < p.length; i++) {
      a += p[i] / (x + i);
    }
    return 0.5 * math.log(2.0 * math.pi) +
        (x + 0.5) * math.log(t) -
        t +
        math.log(a);
  }

  static double _betacf(double a, double b, double x) {
    const maxIterations = 200;
    final qab = a + b;
    final qap = a + 1.0;
    final qam = a - 1.0;
    var c = 1.0;
    var d = 1.0 - qab * x / qap;
    if (d.abs() < tiny) d = tiny;
    d = 1.0 / d;
    var h = d;

    for (var m = 1; m <= maxIterations; m++) {
      final m2 = 2 * m;
      var aa = m * (b - m) * x / ((qam + m2) * (a + m2));
      d = 1.0 + aa * d;
      if (d.abs() < tiny) d = tiny;
      c = 1.0 + aa / c;
      if (c.abs() < tiny) c = tiny;
      d = 1.0 / d;
      h *= d * c;

      aa = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2));
      d = 1.0 + aa * d;
      if (d.abs() < tiny) d = tiny;
      c = 1.0 + aa / c;
      if (c.abs() < tiny) c = tiny;
      d = 1.0 / d;
      final del = d * c;
      h *= del;
      if ((del - 1.0).abs() < epsilon) break;
    }
    return h;
  }

  static double regularizedIncompleteBeta(double a, double b, double x) {
    if (x <= 0.0) return 0.0;
    if (x >= 1.0) return 1.0;
    final bt = math.exp(
      logGamma(a + b) -
          logGamma(a) -
          logGamma(b) +
          a * math.log(x) +
          b * math.log(1.0 - x),
    );
    if (x < (a + 1.0) / (a + b + 2.0)) {
      return bt * _betacf(a, b, x) / a;
    }
    return 1.0 - bt * _betacf(b, a, 1.0 - x) / b;
  }

  static double studentTPValue(double t, double df) {
    if (df <= 0 || !t.isFinite) return 1.0;
    final x = df / (df + t * t);
    return regularizedIncompleteBeta(df / 2.0, 0.5, x).clamp(0.0, 1.0);
  }

  static double fDistributionPValue(double f, double df1, double df2) {
    if (f <= 0.0 || df1 <= 0 || df2 <= 0 || !f.isFinite) return 1.0;
    final x = df2 / (df2 + df1 * f);
    return regularizedIncompleteBeta(df2 / 2.0, df1 / 2.0, x).clamp(0.0, 1.0);
  }

  static List<double> adjustFDR(List<double> rawPValues) {
    final n = rawPValues.length;
    if (n == 0) return [];
    if (n == 1) return [rawPValues.first];
    final indices = List<int>.generate(n, (i) => i)
      ..sort((a, b) => rawPValues[a].compareTo(rawPValues[b]));
    final adjusted = List<double>.filled(n, 1.0);
    var runningMin = 1.0;
    for (var rank = n; rank >= 1; rank--) {
      final idx = indices[rank - 1];
      final adj = (rawPValues[idx] * n / rank).clamp(0.0, 1.0);
      if (adj < runningMin) runningMin = adj;
      adjusted[idx] = runningMin;
    }
    return adjusted;
  }
}

/// Pure-Dart N-way Factorial GLM & LMM engine with restricted/exchangeable
/// permutation testing (inspired by CCS_SleepStudio's GroupStatsEngine).
class ErpGroupStatsEngine {
  /// Inspects a CSV (plus optional composable filename/folder rules and
  /// multiple CSV/XLSX sheets) and returns detected factors, levels, counts,
  /// column sources, and numeric metrics.
  static Future<Map<String, dynamic>> inspectDataset({
    required String csvPath,
    String? metadataPath,
    String? metadataKey,
    List<Map<String, dynamic>> factorRules = const [],
    List<Map<String, dynamic>> externalSheets = const [],
  }) async {
    final parsed = await TabularSheetReader.read(csvPath);
    var headers = List<String>.from(parsed.headers);
    var rows = List<List<String>>.from(parsed.rows);
    final columnSources = <String, String>{
      for (final h in headers) h: 'Measurement table · $h',
    };

    // 1. Apply composable factor rules (filename crop, delimiter, folder, regex, manual_map)
    for (final rule in factorRules) {
      final mode = '${rule['mode'] ?? ''}'.trim();
      if (mode == 'manual_map') {
        final rawMap = rule['rows'] as Map? ?? const {};
        if (rawMap.isEmpty) continue;
        final fnIdx = _findFilenameColIndex(headers);
        if (fnIdx < 0) continue;
        // Collect all column names present with at least one non-empty value
        final colsToMerge = <String>{};
        final normalizedMap = <String, Map<String, String>>{};
        for (final entry in rawMap.entries) {
          final key = '${entry.key}'.trim();
          final fields = (entry.value as Map? ?? const {});
          final cleaned = <String, String>{};
          for (final fe in fields.entries) {
            final colName = '${fe.key}' == 'Subject'
                ? 'participant_id'
                : '${fe.key}'.trim();
            final val = '${fe.value}'.trim();
            if (colName.isNotEmpty && colName != 'filename' && val.isNotEmpty) {
              cleaned[colName] = val;
              colsToMerge.add(colName);
            }
          }
          if (cleaned.isNotEmpty) {
            normalizedMap[key] = cleaned;
            normalizedMap[_basename(key)] = cleaned;
          }
        }
        for (final col in colsToMerge) {
          final values = <String>[];
          final existingIdx = headers.indexWhere(
            (h) => h.toLowerCase() == col.toLowerCase(),
          );
          for (var r = 0; r < rows.length; r++) {
            final rawFn = fnIdx < rows[r].length ? rows[r][fnIdx].trim() : '';
            final hit = normalizedMap[rawFn] ?? normalizedMap[_basename(rawFn)];
            final newVal = hit?[col];
            if (newVal != null && newVal.isNotEmpty) {
              values.add(newVal);
            } else if (existingIdx >= 0 && existingIdx < rows[r].length) {
              values.add(rows[r][existingIdx]);
            } else {
              values.add('');
            }
          }
          final actualName = existingIdx >= 0 ? headers[existingIdx] : col;
          _upsertColumn(headers, rows, actualName, values);
          columnSources[actualName] = 'Reviewed filename labels · $actualName';
        }
        continue;
      }

      final factorName = '${rule['factorName'] ?? ''}'.trim();
      if (factorName.isEmpty) continue;
      final sourceCol = '${rule['sourceCol'] ?? 'filename'}'.trim();
      final srcIdx = _resolveSourceColIndex(headers, sourceCol);
      if (srcIdx < 0) continue;
      final isFileSource = const {
        'filename',
        'file',
        'source_file',
        'source_path',
        'path',
      }.contains(headers[srcIdx].toLowerCase());

      final extracted = <String>[];
      var sourceLabel = 'Custom rule';

      if (mode == 'crop') {
        final cropRule = FilenameCropRule(
          label: '${rule['label'] ?? 'Crop'}',
          pattern: '${rule['pattern'] ?? ''}',
          isFixedSlice: rule['isFixedSlice'] == true,
          start: (rule['start'] as num?)?.toInt() ?? 0,
          end: (rule['end'] as num?)?.toInt() ?? 0,
        );
        sourceLabel = 'Filename crop · ${cropRule.label}';
        for (final r in rows) {
          final raw = srcIdx < r.length ? r[srcIdx].trim() : '';
          final input = isFileSource ? _basename(raw) : raw;
          final val = cropRule.apply(input).trim();
          extracted.add(val.isEmpty ? 'Unknown' : val);
        }
      } else if (mode == 'delimiter') {
        final sep = '${rule['separator'] ?? '_'}';
        final partIndex = (rule['partIndex'] as num?)?.toInt() ?? 0;
        sourceLabel = 'Filename part ${partIndex + 1} (sep "$sep")';
        for (final r in rows) {
          final raw = srcIdx < r.length ? r[srcIdx].trim() : '';
          final stem = (isFileSource ? _basename(raw) : raw)
              .replaceFirst(RegExp(r'\.[^.]+$'), '');
          final parts = sep.isEmpty
              ? [stem]
              : stem.split(sep).where((p) => p.isNotEmpty).toList();
          final val = (partIndex >= 0 && partIndex < parts.length)
              ? parts[partIndex].trim()
              : '';
          extracted.add(val.isEmpty ? 'Unknown' : val);
        }
      } else if (mode == 'folder') {
        final level = ((rule['folderLevel'] as num?)?.toInt() ?? 1).clamp(1, 10);
        sourceLabel = 'Folder level $level';
        for (final r in rows) {
          final raw = srcIdx < r.length ? r[srcIdx].trim() : '';
          final segs = raw
              .split(RegExp(r'[/\\]'))
              .where((s) => s.isNotEmpty)
              .toList();
          // Last segment is the file itself; parent is segs.length - 1 - level
          final targetIdx = segs.length - 1 - level;
          final val = (targetIdx >= 0 && targetIdx < segs.length)
              ? segs[targetIdx].trim()
              : '';
          extracted.add(val.isEmpty ? 'Unknown' : val);
        }
      } else if (mode == 'regex') {
        final pat = '${rule['pattern'] ?? ''}'.trim();
        sourceLabel = 'Filename regex · $pat';
        RegExp? re;
        try {
          if (pat.isNotEmpty) re = RegExp(pat);
        } catch (_) {}
        for (final r in rows) {
          final raw = srcIdx < r.length ? r[srcIdx].trim() : '';
          final input = isFileSource ? _basename(raw) : raw;
          final m = re?.firstMatch(input);
          final val = m == null
              ? ''
              : (m.groupCount >= 1 ? (m.group(1) ?? '') : (m.group(0) ?? ''));
          extracted.add(val.trim().isEmpty ? 'Unknown' : val.trim());
        }
      }

      if (extracted.isNotEmpty) {
        _upsertColumn(headers, rows, factorName, extracted);
        columnSources[factorName] = sourceLabel;
      }
    }

    // 2. Auto-detect participant_id and Session if not already explicitly defined
    final subjectIndex = headers.indexWhere(
      (h) => const {
        'subjid',
        'subject',
        'subject_id',
        'participant_id',
      }.contains(h.toLowerCase()),
    );
    if (subjectIndex >= 0 && !headers.contains('participant_id')) {
      final sessionPattern = RegExp(
        r'^(.+?)[_-]?(?:session|ses|visit)[_-]?(\d+)(?:[-_].*)?$',
        caseSensitive: false,
      );
      final matches = rows
          .map(
            (r) => subjectIndex < r.length
                ? sessionPattern.firstMatch(r[subjectIndex])
                : null,
          )
          .toList();
      if (matches.any((m) => m != null)) {
        final addSession = !headers.any(
          (h) => const {'session', 'sessn'}.contains(h.toLowerCase()),
        );
        headers.add('participant_id');
        columnSources['participant_id'] =
            'Separated from ${headers[subjectIndex]} in the measurement table';
        if (addSession)
          columnSources['Session'] =
              'Session suffix in ${headers[subjectIndex]} (for example SESSION03 → 03)';
        if (addSession) headers.add('Session');
        rows = [
          for (var i = 0; i < rows.length; i++)
            [
              ...List.generate(
                headers.length - (addSession ? 2 : 1),
                (c) => c < rows[i].length ? rows[i][c] : '',
              ),
              matches[i]?.group(1) ?? rows[i][subjectIndex],
              if (addSession) matches[i]?.group(2) ?? 'Unknown',
            ],
        ];
      }
    }

    // Also auto-detect Session from recording filename when no Session column exists yet
    final hasSessionCol = headers.any(
      (h) => const {'session', 'sessn'}.contains(h.toLowerCase()),
    );
    final fnColIdx = _findFilenameColIndex(headers);
    if (!hasSessionCol && fnColIdx >= 0) {
      final fnSessionRe = RegExp(
        r'(?:session|ses|visit)[_-]?([A-Za-z0-9]+)',
        caseSensitive: false,
      );
      final fnMatches = <String>[];
      final distinctSessions = <String>{};
      for (final r in rows) {
        final rawFn = fnColIdx < r.length ? r[fnColIdx] : '';
        final stem = _basename(rawFn).replaceFirst(RegExp(r'\.[^.]+$'), '');
        final m = fnSessionRe.firstMatch(stem);
        // Strip trailing hyphen/extension token like "-epo" if attached
        final rawSess = (m?.group(1) ?? '').split('-').first.trim();
        if (rawSess.isNotEmpty) {
          distinctSessions.add(rawSess);
          fnMatches.add(rawSess);
        } else {
          fnMatches.add('Unknown');
        }
      }
      if (distinctSessions.length >= 2) {
        _upsertColumn(headers, rows, 'Session', fnMatches);
        columnSources['Session'] = 'Auto-detected from recording filename';
      }
    }

    // 3. Apply external Excel/CSV sheets (composable; legacy metadataPath supported too)
    final allSheets = <Map<String, dynamic>>[
      ...externalSheets,
      if (metadataPath != null &&
          metadataPath.trim().isNotEmpty &&
          !externalSheets.any(
            (s) => '${s['path'] ?? ''}'.trim() == metadataPath.trim(),
          ))
        {
          'path': metadataPath.trim(),
          if (metadataKey != null && metadataKey.trim().isNotEmpty)
            'sheetJoinCol': metadataKey.trim(),
        },
    ];

    for (final sheet in allSheets) {
      final path = '${sheet['path'] ?? ''}'.trim();
      if (path.isEmpty || !await File(path).exists()) continue;
      final meta = await TabularSheetReader.read(path);
      if (meta.headers.isEmpty) continue;
      final tableJoinCol = '${sheet['tableJoinCol'] ?? ''}'.trim();
      final sheetJoinCol = '${sheet['sheetJoinCol'] ?? ''}'.trim();
      final selectedCols = (sheet['selectedColumns'] as List?)
          ?.map((e) => '$e')
          .toList();
      final merged = _mergeMetadata(
        headers: headers,
        rows: rows,
        metaHeaders: meta.headers,
        metaRows: meta.rows,
        explicitKey: sheetJoinCol.isNotEmpty ? sheetJoinCol : null,
        explicitTableKey: tableJoinCol.isNotEmpty ? tableJoinCol : null,
        selectedColumns: selectedCols,
      );
      headers = merged.headers;
      rows = merged.rows;
      final fileName = _basename(path);
      final importedNames = selectedCols != null && selectedCols.isNotEmpty
          ? selectedCols
          : meta.headers;
      for (final h in importedNames) {
        if (h == sheetJoinCol) continue;
        final actual = headers
            .where((c) => c.toLowerCase() == h.toLowerCase())
            .firstOrNull;
        if (actual != null) {
          columnSources[actual] =
              'Participant file $fileName · $h (fills missing labels)';
        }
      }
    }

    final factorCols = <String>[];
    final metricCols = <String>[];
    final factorLevels = <String, List<String>>{};
    final factorCounts = <String, Map<String, int>>{};
    String? detectedSubjectCol = headers.contains('participant_id')
        ? 'participant_id'
        : null;

    for (var c = 0; c < headers.length; c++) {
      final h = headers[c];
      final hl = h.toLowerCase();
      if (detectedSubjectCol == null &&
          (hl == 'subjid' ||
              hl == 'subject' ||
              hl == 'participant_id' ||
              hl == 'subject_id' ||
              hl == 'id')) {
        detectedSubjectCol = h;
      }

      var numCount = 0;
      var hasDecimal = false;
      var nonEmpty = 0;
      final counts = <String, int>{};
      for (final r in rows) {
        if (c >= r.length) continue;
        final v = r[c].trim();
        if (v.isEmpty) continue;
        nonEmpty++;
        if (double.tryParse(v) != null) {
          numCount++;
          if (v.contains('.') || v.toLowerCase().contains('e')) {
            hasDecimal = true;
          }
        }
        counts[v] = (counts[v] ?? 0) + 1;
      }

      const idOrMetaNumeric = {
        'sl.no.',
        'sl.no',
        'session',
        'sessn',
        'sno',
        'index',
        'epoch',
        'bin',
        'bin_idx',
        'polarity',
        'window_start_ms',
        'window_end_ms',
        'n_trials',
      };
      final looksMetricCol =
          hl.endsWith('_erp') ||
          hl.endsWith('_uv') ||
          hl.endsWith('_uv_s') ||
          hl.endsWith('_s') ||
          hl.endsWith('_ms') ||
          hl.endsWith('_psd') ||
          hl.endsWith('_fooof') ||
          hl.endsWith('_irasa') ||
          hl.contains('amplitude') ||
          hl.contains('latency') ||
          hl.contains('auc');
      if (nonEmpty > 0 &&
          numCount == nonEmpty &&
          !idOrMetaNumeric.contains(hl) &&
          (counts.length > 6 || hasDecimal || looksMetricCol)) {
        metricCols.add(h);
      } else if (counts.isNotEmpty) {
        factorCols.add(h);
        final levels = counts.keys.toList()..sort();
        factorLevels[h] = levels;
        factorCounts[h] = counts;
      }
    }

    return {
      'column_sources': columnSources,
      'headers': headers,
      'rows': rows,
      'row_count': rows.length,
      'factor_columns': factorCols,
      'metric_columns': metricCols,
      'factor_levels': factorLevels,
      'factor_counts': factorCounts,
      'detected_subject_col': detectedSubjectCol,
    };
  }

  static String _basename(String path) => path.split(RegExp(r'[/\\]')).last;

  static int _findFilenameColIndex(List<String> headers) {
    for (final cand in const ['filename', 'file', 'source_file', 'source_path', 'path']) {
      final idx = headers.indexWhere((h) => h.toLowerCase() == cand);
      if (idx >= 0) return idx;
    }
    return -1;
  }

  static int _resolveSourceColIndex(List<String> headers, String sourceCol) {
    final exact = headers.indexWhere(
      (h) => h.toLowerCase() == sourceCol.toLowerCase(),
    );
    if (exact >= 0) return exact;
    return _findFilenameColIndex(headers);
  }

  static void _upsertColumn(
    List<String> headers,
    List<List<String>> rows,
    String colName,
    List<String> values,
  ) {
    final existingIdx = headers.indexWhere(
      (h) => h.toLowerCase() == colName.toLowerCase(),
    );
    if (existingIdx >= 0) {
      for (var i = 0; i < rows.length; i++) {
        while (rows[i].length <= existingIdx) {
          rows[i].add('');
        }
        rows[i][existingIdx] = i < values.length ? values[i] : '';
      }
    } else {
      final colIdx = headers.length;
      headers.add(colName);
      for (var i = 0; i < rows.length; i++) {
        while (rows[i].length < colIdx) {
          rows[i].add('');
        }
        rows[i].add(i < values.length ? values[i] : '');
      }
    }
  }

  static ({List<String> headers, List<List<String>> rows}) _mergeMetadata({
    required List<String> headers,
    required List<List<String>> rows,
    required List<String> metaHeaders,
    required List<List<String>> metaRows,
    String? explicitKey,
    String? explicitTableKey,
    List<String>? selectedColumns,
  }) {
    String? csvKey;
    String? metaKey;
    if (explicitTableKey != null &&
        explicitTableKey.trim().isNotEmpty &&
        headers.contains(explicitTableKey.trim())) {
      csvKey = explicitTableKey.trim();
    }
    if (explicitKey != null &&
        explicitKey.trim().isNotEmpty &&
        metaHeaders.contains(explicitKey.trim())) {
      csvKey ??= headers.contains(explicitKey.trim())
          ? explicitKey.trim()
          : headers
                .where(
                  (h) => const {
                    'subjid',
                    'subject',
                    'subject_id',
                    'participant_id',
                  }.contains(h.toLowerCase()),
                )
                .firstOrNull;
      metaKey = explicitKey.trim();
    }
    if (csvKey == null || metaKey == null) {
      const candidates = [
        'subjid',
        'subject',
        'participant_id',
        'subject_id',
        'id',
        'filename',
      ];
      for (final cand in candidates) {
        csvKey ??= headers.where((h) => h.toLowerCase() == cand).firstOrNull;
        metaKey ??= metaHeaders
            .where((h) => h.toLowerCase() == cand)
            .firstOrNull;
      }
      csvKey ??= headers.firstOrNull;
      metaKey ??= metaHeaders.firstOrNull;
    }
    if (csvKey == null || metaKey == null) {
      return (headers: headers, rows: rows);
    }

    final csvKeyIdx = headers.indexOf(csvKey);
    final metaKeyIdx = metaHeaders.indexOf(metaKey);
    final lowerHeaders = {
      for (var i = 0; i < headers.length; i++) headers[i].toLowerCase(): i,
    };
    final allowedCols = selectedColumns == null || selectedColumns.isEmpty
        ? null
        : selectedColumns.map((c) => c.toLowerCase()).toSet();
    final replaceCols = <({int csvIdx, int metaIdx})>[];
    final newCols = <String>[];
    for (var mi = 0; mi < metaHeaders.length; mi++) {
      final h = metaHeaders[mi];
      if (h == metaKey) continue;
      if (allowedCols != null && !allowedCols.contains(h.toLowerCase())) {
        continue;
      }
      final existingIdx = lowerHeaders[h.toLowerCase()];
      if (existingIdx != null) {
        replaceCols.add((csvIdx: existingIdx, metaIdx: mi));
      } else {
        newCols.add(h);
      }
    }
    if (newCols.isEmpty && replaceCols.isEmpty) {
      return (headers: headers, rows: rows);
    }

    final subjectJoin = const {
      'subjid',
      'subject',
      'subject_id',
      'participant_id',
      'id',
      'participant',
    }.contains(csvKey.toLowerCase());
    String normKey(String raw) {
      var s = raw.trim().toLowerCase();
      s = s.replaceFirst(RegExp(r'^sub-'), '');
      if (subjectJoin)
        s = s.replaceFirst(
          RegExp(r'(?:[-_]?|(?<=\d))(?:session|ses|visit)[-_]?\d+.*$'),
          '',
        );
      return s;
    }

    final lookup = <String, List<String>>{};
    final replaceLookup = <String, List<String>>{};
    for (final mr in metaRows) {
      if (metaKeyIdx >= mr.length) continue;
      final k = normKey(mr[metaKeyIdx]);
      if (k.isEmpty) continue;
      if (lookup.containsKey(k)) {
        throw FormatException(
          'Metadata has more than one row for "$k". Choose a unique subject or recording column.',
        );
      }
      lookup[k] = [
        for (final col in newCols)
          metaHeaders.indexOf(col) < mr.length
              ? mr[metaHeaders.indexOf(col)].trim()
              : '',
      ];
      replaceLookup[k] = [
        for (final pair in replaceCols)
          pair.metaIdx < mr.length ? mr[pair.metaIdx].trim() : '',
      ];
    }

    final sortedKeys = lookup.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    String? findMatchKey(String k) {
      if (k.isEmpty) return null;
      final probes = <String>[
        k,
        if (_basename(k) != k) _basename(k),
      ];
      for (final probe in probes) {
        if (lookup.containsKey(probe)) return probe;
      }
      for (final probe in probes) {
        for (final cand in sortedKeys) {
          if (cand.length < 3) continue;
          if (probe.startsWith(cand)) {
            if (probe.length == cand.length ||
                !RegExp(r'[0-9]').hasMatch(probe[cand.length])) {
              return cand;
            }
          }
          final idx = probe.indexOf(cand);
          if (idx > 0) {
            final leftOk = !RegExp(r'[a-z0-9]').hasMatch(probe[idx - 1]);
            final end = idx + cand.length;
            final rightOk =
                end == probe.length || !RegExp(r'[0-9]').hasMatch(probe[end]);
            if (leftOk && rightOk) return cand;
          }
        }
      }
      return null;
    }

    final mergedHeaders = [...headers, ...newCols];
    final mergedRows = <List<String>>[];
    for (final r in rows) {
      final rawK = csvKeyIdx < r.length ? r[csvKeyIdx] : '';
      final k = normKey(rawK);
      final matchKey = findMatchKey(k);
      final rowBase = List<String>.generate(
        headers.length,
        (i) => i < r.length ? r[i] : '',
      );
      if (matchKey != null) {
        final repl = replaceLookup[matchKey]!;
        final allowOverride =
            csvKey.toLowerCase() == 'filename' ||
            (selectedColumns != null && selectedColumns.isNotEmpty);
        for (var j = 0; j < replaceCols.length; j++) {
          final ci = replaceCols[j].csvIdx;
          final cur = rowBase[ci].trim().toLowerCase();
          final nextVal = repl[j];
          if (nextVal.isNotEmpty &&
              (allowOverride ||
                  cur.isEmpty ||
                  cur == 'unknown' ||
                  cur == 'unassigned')) {
            rowBase[ci] = nextVal;
          }
        }
      }
      final hit = matchKey != null ? lookup[matchKey] : null;
      mergedRows.add([
        ...rowBase,
        ...(hit ?? List.filled(newCols.length, 'Unknown')),
      ]);
    }
    return (headers: mergedHeaders, rows: mergedRows);
  }

  /// Transforms measurement [rows] into paired ERP difference scores (`B - A`).
  ///
  /// Supports both:
  /// - Unified comparison mode ([pairs.length >= 2] and [condCol] in [factors]):
  ///   emits one row per `(recording, pair)` with `condCol` set to `'B − A'` and
  ///   each metric renamed to `'<metric> (Difference)'`.
  /// - Separate-metric mode (single pair, or [condCol] omitted from [factors]):
  ///   drops [condCol] and writes one column `'<metric> (B − A)'` per pair.
  static Map<String, dynamic> buildErpDifferenceDataset({
    required List<String> headers,
    required List<List<String>> rows,
    required String condCol,
    required List<({String condB, String condA})> pairs,
    required List<String> factors,
    required List<String> metrics,
    required String? subjectCol,
    Map<String, List<String>> excludedLevels = const {},
  }) {
    final seenPairs = <String>{};
    final validPairs = <({String condB, String condA, String label})>[];
    for (final p in pairs) {
      if (p.condB.isEmpty || p.condA.isEmpty || p.condB == p.condA) continue;
      final label = '${p.condB} − ${p.condA}';
      if (seenPairs.add(label)) {
        validPairs.add((condB: p.condB, condA: p.condA, label: label));
      }
    }
    if (validPairs.isEmpty) {
      return {
        'error':
            'Choose two distinct conditions (B and A) for ERP Difference.',
      };
    }

    final headerIdx = <String, int>{
      for (var i = 0; i < headers.length; i++) headers[i]: i,
    };
    final condIdx = headerIdx[condCol];
    if (condIdx == null) {
      return {'error': 'Condition column "$condCol" was not found.'};
    }

    final useUnifiedDiffFactor =
        validPairs.length >= 2 && factors.contains(condCol);
    final nonCondFactors = factors
        .where((f) => f != condCol && f.toLowerCase() != 'epoch_label')
        .toList();
    if (!useUnifiedDiffFactor && nonCondFactors.isEmpty) {
      return {
        'error':
            'Keep at least one non-condition factor (e.g. group or session) selected to model ${validPairs.first.label}.',
      };
    }

    final nonCondFactorCols = <int>[];
    for (final f in nonCondFactors) {
      final idx = headerIdx[f];
      if (idx == null) {
        return {'error': 'Factor column "$f" was not found.'};
      }
      nonCondFactorCols.add(idx);
    }

    final fileIdx = [
      for (final k in const ['filename', 'file', 'source_file', 'source_path', 'path'])
        headerIdx[k],
    ].whereType<int>().firstOrNull;
    final subjIdx = subjectCol != null ? headerIdx[subjectCol] : null;

    final neededConds = <String>{
      for (final p in validPairs) ...[p.condB, p.condA],
    };
    final grouped = <String, Map<String, List<List<String>>>>{};
    for (final row in rows) {
      if (row.length < headers.length) continue;
      final cVal = row[condIdx];
      if (!neededConds.contains(cVal)) continue;
      var skip = false;
      for (var i = 0; i < nonCondFactors.length; i++) {
        final fName = nonCondFactors[i];
        final fVal = row[nonCondFactorCols[i]];
        if (fVal.isEmpty || (excludedLevels[fName]?.contains(fVal) ?? false)) {
          skip = true;
          break;
        }
      }
      if (skip) continue;
      final recKey = fileIdx != null && row[fileIdx].isNotEmpty
          ? row[fileIdx]
          : '${subjIdx != null ? row[subjIdx] : ''}|${[for (final ci in nonCondFactorCols) row[ci]].join('|')}';
      grouped
          .putIfAbsent(recKey, () => <String, List<List<String>>>{})
          .putIfAbsent(cVal, () => <List<String>>[])
          .add(row);
    }

    String computeDiff(
      int mIdx,
      List<List<String>> rowsB,
      List<List<String>> rowsA,
    ) {
      var sumB = 0.0;
      var sumA = 0.0;
      var nB = 0;
      var nA = 0;
      for (final r in rowsB) {
        final v = double.tryParse(r[mIdx].trim());
        if (v != null && v.isFinite) {
          sumB += v;
          nB++;
        }
      }
      for (final r in rowsA) {
        final v = double.tryParse(r[mIdx].trim());
        if (v != null && v.isFinite) {
          sumA += v;
          nA++;
        }
      }
      return (nB > 0 && nA > 0) ? '${(sumB / nB) - (sumA / nA)}' : 'NaN';
    }

    final diffLabels = [for (final p in validPairs) p.label];
    final newHeaders = List<String>.from(headers);
    final diffRows = <List<String>>[];

    if (useUnifiedDiffFactor) {
      final metricPairs = <(int idx, String diffMetric)>[];
      for (final m in metrics) {
        final mIdx = headerIdx[m];
        if (mIdx == null) continue;
        final newName = '$m (Difference)';
        newHeaders[mIdx] = newName;
        metricPairs.add((mIdx, newName));
      }
      for (final buckets in grouped.values) {
        for (final p in validPairs) {
          final rowsB = buckets[p.condB];
          final rowsA = buckets[p.condA];
          if (rowsB == null || rowsB.isEmpty || rowsA == null || rowsA.isEmpty) {
            continue;
          }
          final outRow = List<String>.from(rowsB.first);
          outRow[condIdx] = p.label;
          for (final (mIdx, _) in metricPairs) {
            outRow[mIdx] = computeDiff(mIdx, rowsB, rowsA);
          }
          diffRows.add(outRow);
        }
      }
      if (diffRows.length < 3) {
        return {
          'error':
              'Not enough paired ${diffLabels.join(', ')} recordings found (need >= 3).',
        };
      }
      return {
        'headers': newHeaders,
        'rows': diffRows,
        'factors': List<String>.from(factors),
        'metrics': [for (final (_, n) in metricPairs) n],
        'diff_labels': diffLabels,
      };
    } else {
      final outMetrics = <String>[];
      final slots =
          <({int srcIdx, int dstIdx, String condB, String condA})>[];
      for (final m in metrics) {
        final mIdx = headerIdx[m];
        if (mIdx == null) continue;
        for (var pi = 0; pi < validPairs.length; pi++) {
          final p = validPairs[pi];
          final newName = '$m (${p.label})';
          int dstIdx;
          if (pi == 0) {
            newHeaders[mIdx] = newName;
            dstIdx = mIdx;
          } else {
            dstIdx = newHeaders.length;
            newHeaders.add(newName);
          }
          outMetrics.add(newName);
          slots.add((srcIdx: mIdx, dstIdx: dstIdx, condB: p.condB, condA: p.condA));
        }
      }
      final extraCols = newHeaders.length - headers.length;
      for (final buckets in grouped.values) {
        List<String>? templateRow;
        for (final p in validPairs) {
          final rb = buckets[p.condB];
          final ra = buckets[p.condA];
          if (rb != null && rb.isNotEmpty && ra != null && ra.isNotEmpty) {
            templateRow = rb.first;
            break;
          }
        }
        if (templateRow == null) continue;
        final outRow = [
          ...templateRow,
          if (extraCols > 0) ...List.filled(extraCols, 'NaN'),
        ];
        outRow[condIdx] = diffLabels.join(' | ');
        var anyFinite = false;
        for (final slot in slots) {
          final rb = buckets[slot.condB];
          final ra = buckets[slot.condA];
          if (rb != null && rb.isNotEmpty && ra != null && ra.isNotEmpty) {
            final val = computeDiff(slot.srcIdx, rb, ra);
            outRow[slot.dstIdx] = val;
            if (val != 'NaN') anyFinite = true;
          } else {
            outRow[slot.dstIdx] = 'NaN';
          }
        }
        if (anyFinite) diffRows.add(outRow);
      }
      if (diffRows.length < 3) {
        return {
          'error':
              'Not enough paired ${diffLabels.join(', ')} recordings found (need >= 3).',
        };
      }
      return {
        'headers': newHeaders,
        'rows': diffRows,
        'factors': nonCondFactors,
        'metrics': outMetrics,
        'diff_labels': diffLabels,
      };
    }
  }

  /// Runs N-way Permutation-based GLM / LMM analysis on [rows].
  static Map<String, dynamic> runAnalysis({
    required List<String> headers,
    required List<List<String>> rows,
    required List<String> factors,
    required List<String> metrics,
    String? subjectCol,
    String preferredModel = 'auto', // 'auto', 'lmm', 'glm'
    String posthocMethod = 'fdr', // 'fdr', 'bonferroni'
    bool includeInteractions = true,
    int nPermutations = 1000,
    int seed = 42,
    Map<String, Set<String>> excludedLevels = const {},
    Map<String, List<String>> customLevelOrder = const {},
    List<String> contrastFactors = const [],
  }) {
    final colIdx = {for (var i = 0; i < headers.length; i++) headers[i]: i};
    final subjIdx = subjectCol != null ? colIdx[subjectCol] : null;
    final activeFactors = factors.where(colIdx.containsKey).toList();
    if (activeFactors.isEmpty || metrics.isEmpty) {
      return {'error': 'Select at least one factor and one metric.'};
    }

    // Filter rows by excluded factor levels
    final filteredRows = rows.where((r) {
      for (final f in activeFactors) {
        final idx = colIdx[f]!;
        if (idx >= r.length) return false;
        final val = r[idx].trim();
        if (val.isEmpty) return false;
        if ((excludedLevels[f] ?? const <String>{}).contains(val)) {
          return false;
        }
      }
      return true;
    }).toList();

    if (filteredRows.isEmpty) {
      return {'error': 'No rows remain after filtering factor levels.'};
    }

    // Determine ordered levels per factor
    final factorLevels = <String, List<String>>{};
    for (final f in activeFactors) {
      final idx = colIdx[f]!;
      final raw = filteredRows.map((r) => r[idx].trim()).toSet().toList()
        ..sort();
      final custom = customLevelOrder[f];
      if (custom != null && custom.isNotEmpty) {
        factorLevels[f] = [
          for (final l in custom)
            if (raw.contains(l)) l,
          for (final l in raw)
            if (!custom.contains(l)) l,
        ];
      } else {
        factorLevels[f] = raw;
      }
    }

    final metricResults = <Map<String, dynamic>>[];
    final rng = math.Random(seed);

    for (final metric in metrics) {
      final mIdx = colIdx[metric];
      if (mIdx == null) continue;

      final obs = <_Obs>[];
      for (final r in filteredRows) {
        if (mIdx >= r.length) continue;
        final y = double.tryParse(r[mIdx].trim());
        if (y == null || !y.isFinite) continue;
        final subj = (subjIdx != null && subjIdx < r.length)
            ? r[subjIdx].trim()
            : 'obs_${obs.length}';
        final levels = {for (final f in activeFactors) f: r[colIdx[f]!].trim()};
        obs.add(_Obs(subject: subj, y: y, levels: levels));
      }
      if (obs.length < 3) continue;

      final byParticipantCell = <String, List<_Obs>>{};
      for (final o in obs) {
        final key = [
          o.subject,
          ...activeFactors.map((f) => o.levels[f]!),
        ].join('\u0000');
        byParticipantCell.putIfAbsent(key, () => []).add(o);
      }
      final collapsed = byParticipantCell.values
          .map(
            (v) => _Obs(
              subject: v.first.subject,
              levels: v.first.levels,
              y: v.map((o) => o.y).reduce((a, b) => a + b) / v.length,
            ),
          )
          .toList();
      obs
        ..clear()
        ..addAll(collapsed);
      final subjects = obs.map((o) => o.subject).toSet();
      final isRepeated =
          subjIdx != null &&
          subjects.length >= 2 &&
          obs.length > subjects.length;
      final useLmm =
          (preferredModel == 'lmm' && isRepeated) ||
          (preferredModel == 'auto' && isRepeated);

      // Identify which factors are between-subject vs within-subject
      final isBetweenFactor = <String, bool>{};
      for (final f in activeFactors) {
        if (!isRepeated) {
          isBetweenFactor[f] = true;
        } else {
          final subjLvls = <String, Set<String>>{};
          for (final o in obs) {
            subjLvls.putIfAbsent(o.subject, () => {}).add(o.levels[f]!);
          }
          isBetweenFactor[f] = subjLvls.values.every((s) => s.length <= 1);
        }
      }

      if (isRepeated && !useLmm)
        return {
          'error':
              'Repeated participant observations require participant blocking. Choose Auto / LMM approximation, or use a fitted GLM with participant-cluster covariance.',
        };
      final cellCounts = <String, int>{};
      for (final o in obs) {
        final key = activeFactors.map((f) => o.levels[f]!).join('\u0000');
        cellCounts[key] = (cellCounts[key] ?? 0) + 1;
      }
      final expectedCells = activeFactors.fold(
        1,
        (n, f) => n * factorLevels[f]!.length,
      );
      final within = activeFactors
          .where((f) => isBetweenFactor[f] != true)
          .toList();
      final expectedWithin = within.fold(
        1,
        (n, f) => n * factorLevels[f]!.length,
      );
      final perPerson = <String, int>{};
      for (final o in obs) {
        perPerson[o.subject] = (perPerson[o.subject] ?? 0) + 1;
      }
      if (cellCounts.length != expectedCells ||
          cellCounts.values.toSet().length > 1 ||
          (isRepeated && perPerson.values.any((n) => n != expectedWithin))) {
        return {
          'error':
              'The native factorial approximation requires complete balanced cells and visits. Use Fitted GLM / LMM (Native) for unequal cohort sizes or missing visits.',
        };
      }
      // Compute observed ANOVA/LMM effects (Type-I/II sequential cell-mean SS)
      final terms = _buildTerms(activeFactors, includeInteractions);
      final obsStats = _computeFactorialStats(
        obs: obs,
        factors: activeFactors,
        terms: terms,
        useLmm: useLmm,
        isBetweenFactor: isBetweenFactor,
      );

      // Permutation testing
      final exceedCounts = {for (final t in terms) t.label: 0};
      final effectivePerms = nPermutations.clamp(1, 5000);
      for (var p = 0; p < effectivePerms; p++) {
        final permObs = _permuteObs(
          obs: obs,
          factors: activeFactors,
          isBetweenFactor: isBetweenFactor,
          useLmm: useLmm,
          rng: rng,
        );
        final permStats = _computeFactorialStats(
          obs: permObs,
          factors: activeFactors,
          terms: terms,
          useLmm: useLmm,
          isBetweenFactor: isBetweenFactor,
        );
        for (final t in terms) {
          final fObs = obsStats[t.label]?.fStat ?? 0.0;
          final fPerm = permStats[t.label]?.fStat ?? 0.0;
          if (fPerm >= fObs - 1e-12) {
            exceedCounts[t.label] = exceedCounts[t.label]! + 1;
          }
        }
      }

      final modelEffects = <Map<String, dynamic>>[
        for (final t in terms)
          if (obsStats.containsKey(t.label))
            {
              'term': t.label,
              'f_stat': obsStats[t.label]!.fStat,
              'p_value': obsStats[t.label]!.pValue,
              'p_perm': (1.0 + exceedCounts[t.label]!) / (1.0 + effectivePerms),
              'df_num': obsStats[t.label]!.dfNum,
              'df_denom': obsStats[t.label]!.dfDenom,
              'eta_sq': obsStats[t.label]!.etaSq,
              'n_obs': obs.length,
              'n_perm': effectivePerms,
            },
      ];

      // Cell descriptives keyed by "f1=v1|f2=v2|..."
      final cellMap = <String, List<double>>{};
      for (final o in obs) {
        final key = activeFactors.map((f) => '$f=${o.levels[f]}').join('|');
        cellMap.putIfAbsent(key, () => []).add(o.y);
      }
      final cellDescriptives = <String, Map<String, dynamic>>{};
      for (final e in cellMap.entries) {
        cellDescriptives[e.key] = _descriptiveStats(e.value);
      }

      // Collapse duplicate rows within participant/cell before any pairwise test.
      final posthocs = <Map<String, dynamic>>[];
      for (final f in activeFactors) {
        if (contrastFactors.isNotEmpty && !contrastFactors.contains(f)) {
          continue;
        }
        final others = activeFactors.where((v) => v != f).toList();
        final strata = <String, Map<String, String>>{'': {}};
        if (others.isNotEmpty)
          for (final o in obs) {
            final values = {
              for (final other in others) other: o.levels[other]!,
            };
            strata[others.map((x) => '${o.levels[x]}').join('\u0000')] = values;
          }
        for (final stratum in strata.values) {
          final selected = obs
              .where(
                (o) => stratum.entries.every((e) => o.levels[e.key] == e.value),
              )
              .toList();
          final lvls = factorLevels[f] ?? [];
          for (var i = 0; i < lvls.length; i++)
            for (var j = i + 1; j < lvls.length; j++) {
              Map<String, double> means(String level) {
                final grouped = <String, List<double>>{};
                for (final o in selected.where((o) => o.levels[f] == level)) {
                  grouped.putIfAbsent(o.subject, () => []).add(o.y);
                }
                return grouped.map(
                  (k, v) => MapEntry(k, v.reduce((a, b) => a + b) / v.length),
                );
              }

              final a = means(lvls[i]), b = means(lvls[j]);
              final paired = isRepeated && isBetweenFactor[f] != true;
              final common = a.keys.where(b.containsKey).toList();
              if (paired ? common.length < 2 : a.length < 2 || b.length < 2)
                continue;
              final tRes = paired
                  ? _pairedT([for (final key in common) b[key]! - a[key]!])
                  : _welchT(a.values.toList(), b.values.toList());
              posthocs.add({
                'factor': f,
                'group_a': lvls[i],
                'group_b': lvls[j],
                'stratum': stratum,
                'contrast_scope': stratum.isEmpty
                    ? 'marginal'
                    : 'simple effect',
                'test': paired
                    ? 'paired participant means'
                    : 'Welch participant means',
                'n_a': paired ? common.length : a.length,
                'n_b': paired ? common.length : b.length,
                'mean_diff': tRes.meanDiff,
                't_stat': tRes.t,
                'df': tRes.df,
                'p_raw': tRes.p,
              });
            }
        }
      }
      final rawPs = posthocs.map((p) => p['p_raw'] as double).toList();
      final adjPs = posthocMethod == 'bonferroni'
          ? rawPs.map((p) => (p * rawPs.length).clamp(0.0, 1.0)).toList()
          : StatMath.adjustFDR(rawPs);
      for (var i = 0; i < posthocs.length; i++) {
        posthocs[i]['p_adj'] = adjPs[i];
        posthocs[i]['significant'] = adjPs[i] < 0.05;
      }

      final activeContrastFactors = [
        for (final f in activeFactors)
          if (contrastFactors.isEmpty || contrastFactors.contains(f)) f,
      ];
      metricResults.add({
        'metric': metric,
        'model_type': useLmm
            ? '${activeFactors.length}-Factor split-plot ANOVA approximation (participant blocks, $effectivePerms permutations; not a fitted LMM)'
            : '${activeFactors.length}-Factor Permutation GLM / ANOVA ($effectivePerms perms)',
        'factors': activeFactors,
        'factor_levels': factorLevels,
        'model_effects': modelEffects,
        'posthoc': posthocs,
        'posthoc_family': contrastFactors.isEmpty
            ? 'All marginal and simple-effect contrasts within this metric'
            : 'Marginal and simple-effect contrasts for ${activeContrastFactors.join(', ')} within this metric',
        'mean_difference_direction': 'group_b minus group_a',
        'cell_descriptives': cellDescriptives,
        'n_obs': obs.length,
        'n_subjects': subjects.length,
      });
    }

    return {
      'factors': activeFactors,
      'factor_levels': factorLevels,
      'results': metricResults,
    };
  }

  static List<_Term> _buildTerms(List<String> factors, bool interactions) {
    final terms = <_Term>[
      for (final f in factors) _Term([f]),
    ];
    if (interactions && factors.length >= 2) {
      for (var i = 0; i < factors.length; i++) {
        for (var j = i + 1; j < factors.length; j++) {
          terms.add(_Term([factors[i], factors[j]]));
        }
      }
      if (factors.length == 3) {
        terms.add(_Term(List<String>.from(factors)));
      }
    }
    return terms;
  }

  static Map<String, _TermStat> _computeFactorialStats({
    required List<_Obs> obs,
    required List<String> factors,
    required List<_Term> terms,
    required bool useLmm,
    required Map<String, bool> isBetweenFactor,
  }) {
    final n = obs.length;
    if (n == 0) return {};
    final grandMean = obs.map((o) => o.y).reduce((a, b) => a + b) / n;

    // Total & full-cell residual SS
    final fullCells = <String, List<double>>{};
    for (final o in obs) {
      final k = factors.map((f) => o.levels[f]!).join('\u0000');
      fullCells.putIfAbsent(k, () => []).add(o.y);
    }
    var ssWithin = 0.0;
    for (final vals in fullCells.values) {
      final m = vals.reduce((a, b) => a + b) / vals.length;
      for (final v in vals) {
        ssWithin += (v - m) * (v - m);
      }
    }
    final dfWithin = math.max(1, n - fullCells.length).toDouble();
    final msWithin = ssWithin / dfWithin;

    // Subject random intercept error term for mixed-design split-plot F-tests
    var msBetweenErr = msWithin;
    var dfBetweenErr = dfWithin;
    var ssBetweenErr = ssWithin;
    var msWithinErr = msWithin;
    var dfWithinErr = dfWithin;
    var ssWithinErr = ssWithin;
    if (useLmm) {
      final betweenFactors = factors
          .where((f) => isBetweenFactor[f] == true)
          .toList();
      final subjObs = <String, List<double>>{};
      final subjCellKey = <String, String>{};
      for (final o in obs) {
        subjObs.putIfAbsent(o.subject, () => []).add(o.y);
        subjCellKey[o.subject] = betweenFactors
            .map((f) => o.levels[f]!)
            .join('\u0000');
      }
      final cellSum = <String, double>{};
      final cellCnt = <String, int>{};
      final cellSubjSet = <String, Set<String>>{};
      for (final o in obs) {
        final ck = subjCellKey[o.subject]!;
        cellSum[ck] = (cellSum[ck] ?? 0.0) + o.y;
        cellCnt[ck] = (cellCnt[ck] ?? 0) + 1;
        cellSubjSet.putIfAbsent(ck, () => <String>{}).add(o.subject);
      }
      var ssSubj = 0.0;
      for (final e in subjObs.entries) {
        final mSubj = e.value.reduce((a, b) => a + b) / e.value.length;
        final ck = subjCellKey[e.key]!;
        final cMean = cellSum[ck]! / math.max(1, cellCnt[ck]!);
        ssSubj += e.value.length * (mSubj - cMean) * (mSubj - cMean);
      }
      final dfS = math.max(1, subjObs.length - cellSubjSet.length).toDouble();
      // Partition within-cell residual SS into between-subject intercept variance
      // (SS_subj) and within-subject residual error (SS_within - SS_subj).
      ssBetweenErr = math.max(ssSubj, ssWithin > ssSubj ? ssSubj : ssWithin);
      msBetweenErr = math.max(msWithin, ssSubj / dfS);
      dfBetweenErr = dfS;
      if (dfWithin > dfS && ssWithin >= ssSubj) {
        ssWithinErr = math.max(0.0, ssWithin - ssSubj);
        dfWithinErr = math.max(1.0, dfWithin - dfS);
        msWithinErr = ssWithinErr / dfWithinErr;
        ssBetweenErr = ssSubj;
        msBetweenErr = ssSubj / dfS;
      }
    }

    final ssByTerm = <String, double>{};
    final dfByTerm = <String, double>{};
    final out = <String, _TermStat>{};

    for (final term in terms) {
      final groups = <String, List<double>>{};
      for (final o in obs) {
        final k = term.factors.map((f) => o.levels[f]!).join('\u0000');
        groups.putIfAbsent(k, () => []).add(o.y);
      }
      var ssMarginal = 0.0;
      for (final vals in groups.values) {
        final m = vals.reduce((a, b) => a + b) / vals.length;
        ssMarginal += vals.length * (m - grandMean) * (m - grandMean);
      }

      // Subtract lower-order terms for interactions
      var ssLower = 0.0;
      if (term.factors.length == 2) {
        ssLower =
            (ssByTerm[term.factors[0]] ?? 0.0) +
            (ssByTerm[term.factors[1]] ?? 0.0);
      } else if (term.factors.length == 3) {
        for (final f in term.factors) {
          ssLower += ssByTerm[f] ?? 0.0;
        }
        ssLower += ssByTerm['${term.factors[0]} × ${term.factors[1]}'] ?? 0.0;
        ssLower += ssByTerm['${term.factors[0]} × ${term.factors[2]}'] ?? 0.0;
        ssLower += ssByTerm['${term.factors[1]} × ${term.factors[2]}'] ?? 0.0;
      }

      final ssTerm = math.max(0.0, ssMarginal - ssLower);
      var dfNum = 1.0;
      for (final f in term.factors) {
        final kLvl = obs.map((o) => o.levels[f]!).toSet().length;
        dfNum *= math.max(1, kLvl - 1);
      }
      ssByTerm[term.label] = ssTerm;
      dfByTerm[term.label] = dfNum;

      final isPureBetween = term.factors.every(
        (f) => isBetweenFactor[f] == true,
      );
      final msErr = (useLmm && isPureBetween)
          ? msBetweenErr
          : (useLmm ? msWithinErr : msWithin);
      final dfDen = (useLmm && isPureBetween)
          ? dfBetweenErr
          : (useLmm ? dfWithinErr : dfWithin);
      final ssErr = (useLmm && isPureBetween)
          ? ssBetweenErr
          : (useLmm ? ssWithinErr : ssWithin);
      final msTerm = ssTerm / dfNum;
      final fStat = msTerm > 1e-18 ? msTerm / math.max(msErr, 1e-12) : 0.0;
      final pVal = StatMath.fDistributionPValue(fStat, dfNum, dfDen);
      final etaSq = (ssTerm + ssErr) > 0 ? ssTerm / (ssTerm + ssErr) : 0.0;

      out[term.label] = _TermStat(
        fStat: fStat,
        pValue: pVal,
        dfNum: dfNum.round(),
        dfDenom: dfDen.round(),
        etaSq: etaSq,
      );
    }
    return out;
  }

  static List<_Obs> _permuteObs({
    required List<_Obs> obs,
    required List<String> factors,
    required Map<String, bool> isBetweenFactor,
    required bool useLmm,
    required math.Random rng,
  }) {
    if (!useLmm) {
      final ys = obs.map((o) => o.y).toList()..shuffle(rng);
      return [
        for (var i = 0; i < obs.length; i++)
          _Obs(subject: obs[i].subject, y: ys[i], levels: obs[i].levels),
      ];
    }

    // Exchangeable permutation for LMM:
    // 1. Permute between-subject factor labels across subjects
    // 2. Permute y within each subject
    final subjList = obs.map((o) => o.subject).toSet().toList();
    final shuffledSubj = List<String>.from(subjList)..shuffle(rng);
    final subjMap = {
      for (var i = 0; i < subjList.length; i++) subjList[i]: shuffledSubj[i],
    };

    final bySubjIndices = <String, List<int>>{};
    for (var i = 0; i < obs.length; i++) {
      bySubjIndices.putIfAbsent(obs[i].subject, () => []).add(i);
    }
    final permutedY = List<double>.filled(obs.length, 0.0);
    for (final idxs in bySubjIndices.values) {
      final vals = [for (final i in idxs) obs[i].y]..shuffle(rng);
      for (var k = 0; k < idxs.length; k++) {
        permutedY[idxs[k]] = vals[k];
      }
    }

    // Map between-subject factors from permuted subject
    final subjBetween = <String, Map<String, String>>{};
    for (final o in obs) {
      subjBetween.putIfAbsent(
        o.subject,
        () => {
          for (final f in factors)
            if (isBetweenFactor[f] == true) f: o.levels[f]!,
        },
      );
    }

    return [
      for (var i = 0; i < obs.length; i++)
        _Obs(
          subject: obs[i].subject,
          y: permutedY[i],
          levels: {
            for (final f in factors)
              f: isBetweenFactor[f] == true
                  ? (subjBetween[subjMap[obs[i].subject]!]?[f] ??
                        obs[i].levels[f]!)
                  : obs[i].levels[f]!,
          },
        ),
    ];
  }

  static Map<String, dynamic> _descriptiveStats(List<double> vals) {
    final sorted = List<double>.from(vals)..sort();
    final n = sorted.length;
    final mean = sorted.reduce((a, b) => a + b) / n;
    var ss = 0.0;
    for (final v in sorted) {
      ss += (v - mean) * (v - mean);
    }
    final sd = n > 1 ? math.sqrt(ss / (n - 1)) : 0.0;
    final sem = n > 0 ? sd / math.sqrt(n) : 0.0;
    return {
      'n': n,
      'mean': mean,
      'sd': sd,
      'sem': sem,
      'median': _pct(sorted, 0.5),
      'q1': _pct(sorted, 0.25),
      'q3': _pct(sorted, 0.75),
      'min': sorted.first,
      'max': sorted.last,
      'values': sorted,
    };
  }

  static double _pct(List<double> s, double p) {
    if (s.isEmpty) return 0.0;
    if (s.length == 1) return s.first;
    final idx = p * (s.length - 1);
    final lo = idx.floor();
    final hi = idx.ceil();
    return s[lo] + (s[hi] - s[lo]) * (idx - lo);
  }

  static ({double meanDiff, double t, double df, double p}) _pairedT(
    List<double> differences,
  ) {
    final n = differences.length;
    final mean = differences.reduce((a, b) => a + b) / n;
    final variance =
        differences
            .map((v) => (v - mean) * (v - mean))
            .reduce((a, b) => a + b) /
        (n - 1);
    final se = math.sqrt(variance / n);
    final t = se > 1e-12
        ? mean / se
        : mean.abs() > 1e-12
        ? mean.sign * 1e12
        : 0.0;
    return (
      meanDiff: mean,
      t: t,
      df: (n - 1).toDouble(),
      p: StatMath.studentTPValue(t, (n - 1).toDouble()),
    );
  }

  static ({double meanDiff, double t, double df, double p}) _welchT(
    List<double> a,
    List<double> b,
  ) {
    final ma = a.reduce((x, y) => x + y) / a.length;
    final mb = b.reduce((x, y) => x + y) / b.length;
    var va = 0.0;
    for (final x in a) {
      va += (x - ma) * (x - ma);
    }
    va /= math.max(1, a.length - 1);
    var vb = 0.0;
    for (final x in b) {
      vb += (x - mb) * (x - mb);
    }
    vb /= math.max(1, b.length - 1);
    final se = math.sqrt(va / a.length + vb / b.length);
    final t = se > 1e-12 ? (mb - ma) / se : 0.0;
    final num = math.pow(va / a.length + vb / b.length, 2);
    final den =
        math.pow(va / a.length, 2) / math.max(1, a.length - 1) +
        math.pow(vb / b.length, 2) / math.max(1, b.length - 1);
    final df = den > 1e-12
        ? (num / den).toDouble()
        : (a.length + b.length - 2).toDouble();
    return (meanDiff: mb - ma, t: t, df: df, p: StatMath.studentTPValue(t, df));
  }
}

class _Obs {
  const _Obs({required this.subject, required this.y, required this.levels});
  final String subject;
  final double y;
  final Map<String, String> levels;
}

class _Term {
  const _Term(this.factors);
  final List<String> factors;
  String get label => factors.join(' × ');
}

class _TermStat {
  const _TermStat({
    required this.fStat,
    required this.pValue,
    required this.dfNum,
    required this.dfDenom,
    required this.etaSq,
  });
  final double fStat;
  final double pValue;
  final int dfNum;
  final int dfDenom;
  final double etaSq;
}
