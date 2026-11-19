import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:xml/xml.dart';

import 'workbench_service.dart';

/// Reads `.xlsx`, `.csv`, and `.tsv` sheets in pure Dart.
class TabularSheetReader {
  static Future<({List<String> headers, List<List<String>> rows})> read(
    String path,
  ) async {
    final lower = path.toLowerCase();
    if (lower.endsWith('.xlsx')) {
      return _readXlsx(path);
    }
    final content = await File(path).readAsString();
    final delim = lower.endsWith('.tsv') ? '\t' : ',';
    final lines = const LineSplitter()
        .convert(content)
        .where((l) => l.trim().isNotEmpty)
        .toList();
    if (lines.isEmpty) return (headers: <String>[], rows: <List<String>>[]);
    final parsed = lines.map((l) => _splitDelimitedLine(l, delim)).toList();
    final headers = parsed.first.map((h) => h.trim()).toList();
    final rows = parsed.skip(1).toList();
    return (headers: headers, rows: rows);
  }

  static List<String> _splitDelimitedLine(String line, String delim) {
    if (delim == '\t') return line.split('\t').map((e) => e.trim()).toList();
    final out = <String>[];
    final buf = StringBuffer();
    var inQuotes = false;
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (ch == '"') {
        if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
          buf.write('"');
          i++;
        } else {
          inQuotes = !inQuotes;
        }
      } else if (ch == ',' && !inQuotes) {
        out.add(buf.toString().trim());
        buf.clear();
      } else {
        buf.write(ch);
      }
    }
    out.add(buf.toString().trim());
    return out;
  }

  static Future<({List<String> headers, List<List<String>> rows})> _readXlsx(
    String path,
  ) async {
    final bytes = await File(path).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    final sharedStrings = <String>[];
    final ssEntry = archive.files
        .where((f) => f.name == 'xl/sharedStrings.xml')
        .firstOrNull;
    if (ssEntry != null) {
      final doc = XmlDocument.parse(utf8.decode(ssEntry.content as List<int>));
      for (final si in doc.findAllElements('si')) {
        final buf = StringBuffer();
        for (final t in si.findAllElements('t')) {
          buf.write(t.innerText);
        }
        sharedStrings.add(buf.toString());
      }
    }

    final sheetEntry = archive.files
        .where(
          (f) =>
              f.name.startsWith('xl/worksheets/sheet') &&
              f.name.endsWith('.xml'),
        )
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    if (sheetEntry.isEmpty) {
      return (headers: <String>[], rows: <List<String>>[]);
    }

    final doc = XmlDocument.parse(
      utf8.decode(sheetEntry.first.content as List<int>),
    );
    final rawRows = <List<String>>[];
    var maxCols = 0;

    for (final rowEl in doc.findAllElements('row')) {
      final rowMap = <int, String>{};
      var fallbackCol = 0;
      for (final cEl in rowEl.findElements('c')) {
        final ref = cEl.getAttribute('r') ?? '';
        final colIdx = ref.isNotEmpty ? _colRefToIndex(ref) : fallbackCol;
        fallbackCol = colIdx + 1;
        final type = cEl.getAttribute('t') ?? '';
        var val = '';
        if (type == 'inlineStr') {
          val = cEl.findAllElements('t').map((e) => e.innerText).join();
        } else {
          final vEl = cEl.findElements('v').firstOrNull;
          final rawVal = vEl?.innerText ?? '';
          if (type == 's') {
            final idx = int.tryParse(rawVal);
            val = (idx != null && idx >= 0 && idx < sharedStrings.length)
                ? sharedStrings[idx]
                : rawVal;
          } else {
            val = rawVal;
          }
        }
        rowMap[colIdx] = val.trim();
        if (colIdx + 1 > maxCols) maxCols = colIdx + 1;
      }
      if (rowMap.isNotEmpty) {
        rawRows.add(List.generate(maxCols, (i) => rowMap[i] ?? ''));
      }
    }

    if (rawRows.isEmpty) return (headers: <String>[], rows: <List<String>>[]);
    final headers = rawRows.first
        .map((h) => h.trim())
        .toList();
    final rows = rawRows
        .skip(1)
        .where((r) => r.any((c) => c.trim().isNotEmpty))
        .map((r) => List.generate(headers.length, (i) => i < r.length ? r[i] : ''))
        .toList();
    return (headers: headers, rows: rows);
  }

  static int _colRefToIndex(String ref) {
    var col = 0;
    for (var i = 0; i < ref.length; i++) {
      final code = ref.codeUnitAt(i);
      if (code >= 65 && code <= 90) {
        col = col * 26 + (code - 64);
      } else if (code >= 97 && code <= 122) {
        col = col * 26 + (code - 96);
      } else {
        break;
      }
    }
    return math.max(0, col - 1);
  }
}

/// Rule inferred from an interactive filename crop.
class FilenameCropRule {
  const FilenameCropRule({
    required this.label,
    required this.pattern,
    required this.isFixedSlice,
    required this.start,
    required this.end,
  });

  final String label;
  final String pattern;
  final bool isFixedSlice;
  final int start;
  final int end;

  String apply(String filename) {
    if (isFixedSlice) {
      if (start >= filename.length) return '';
      return filename.substring(start, math.min(end, filename.length));
    }
    final m = RegExp(pattern).firstMatch(filename);
    if (m == null) return '';
    return m.groupCount >= 1 ? (m.group(1) ?? m.group(0) ?? '') : (m.group(0) ?? '');
  }

  /// Automatically infers candidate extraction rules from [sampleName]
  /// and the user-cropped range `[start, end)`.
  static List<FilenameCropRule> inferCandidates(
    String sampleName,
    int start,
    int end,
  ) {
    if (start < 0 || end <= start || end > sampleName.length) return const [];
    final cropped = sampleName.substring(start, end);
    final before = sampleName.substring(0, start);
    final after = sampleName.substring(end);

    final out = <FilenameCropRule>[];

    // 1. Alpha-prefix + digits pattern (e.g., SESSION03 -> SESSION\d+, SKYMED013 -> SKYMED\d+)
    final alphaNum = RegExp(r'^([A-Za-z]+)(\d+)$').firstMatch(cropped);
    if (alphaNum != null) {
      final prefix = alphaNum.group(1)!;
      final digits = alphaNum.group(2)!;
      out.add(
        FilenameCropRule(
          label: 'Keyword + digits ($prefix\\d+)',
          pattern: '(${RegExp.escape(prefix)}\\d+)',
          isFixedSlice: false,
          start: start,
          end: end,
        ),
      );
      out.add(
        FilenameCropRule(
          label: 'Alpha(${prefix.length})+Digits(${digits.length})',
          pattern: '([A-Za-z]{${prefix.length}}\\d{${digits.length}})',
          isFixedSlice: false,
          start: start,
          end: end,
        ),
      );
    }

    // 2. Delimiter-bounded token if surrounded by _ or - or start/end
    final leftDelim = before.isEmpty ? '^' : (before.endsWith('_') || before.endsWith('-') ? RegExp.escape(before[before.length - 1]) : null);
    final rightDelim = after.isEmpty ? r'$' : (after.startsWith('_') || after.startsWith('-') || after.startsWith('.') ? RegExp.escape(after[0]) : null);
    if (leftDelim != null && rightDelim != null) {
      out.add(
        FilenameCropRule(
          label: 'Delimiter-bounded token',
          pattern: '$leftDelim([^_\\-.]+)$rightDelim',
          isFixedSlice: false,
          start: start,
          end: end,
        ),
      );
    }

    // 3. Context-anchored pattern (prefix/suffix literal)
    final preCtx = before.length >= 3 ? before.substring(before.length - 3) : before;
    final postCtx = after.length >= 3 ? after.substring(0, 3) : after;
    if (preCtx.isNotEmpty || postCtx.isNotEmpty) {
      final prePat = preCtx.isEmpty
          ? '^'
          : RegExp.escape(preCtx).replaceAll(RegExp(r'\d'), r'\d');
      final postPat = postCtx.isEmpty
          ? r'$'
          : RegExp.escape(postCtx).replaceAll(RegExp(r'\d'), r'\d');
      out.add(
        FilenameCropRule(
          label: 'Context-anchored (${preCtx.isEmpty ? "^" : preCtx} … ${postCtx.isEmpty ? "\$" : postCtx})',
          pattern: '$prePat(.{${cropped.length}})$postPat',
          isFixedSlice: false,
          start: start,
          end: end,
        ),
      );
    }

    // 4. Fixed character position slice
    out.add(
      FilenameCropRule(
        label: 'Fixed position [$start:$end]',
        pattern: 'slice:$start:$end',
        isFixedSlice: true,
        start: start,
        end: end,
      ),
    );

    return out;
  }
}

class FactorGroupingResult {
  const FactorGroupingResult({
    required this.fileFactors,
    required this.participantGroups,
    required this.excludedFiles,
    required this.factorNames,
    this.primaryGroupFactor,
    this.excludedLevelsByFactor = const {},
  });

  final Map<String, Map<String, String>> fileFactors;
  final Map<String, String> participantGroups;
  final Set<String> excludedFiles;
  final List<String> factorNames;
  final String? primaryGroupFactor;
  final Map<String, Set<String>> excludedLevelsByFactor;
}

/// Interactive Factor & Grouping Designer:
/// - Auto-detects factors from folder/BIDS structure, CSV/Excel sheets, and filenames.
/// - Interactive filename cropper to infer factor extraction rules automatically.
/// - Interactive grouping tree and per-factor level chips to include/reject levels or files.
class FactorGroupingDesignerDialog extends StatefulWidget {
  const FactorGroupingDesignerDialog({
    super.key,
    required this.filePaths,
    this.initialFileFactors = const {},
    this.initialParticipantGroups = const {},
    this.initialExcludedFiles = const {},
    this.initialPrimaryGroupFactor,
  });

  final List<String> filePaths;
  final Map<String, Map<String, String>> initialFileFactors;
  final Map<String, String> initialParticipantGroups;
  final Set<String> initialExcludedFiles;
  final String? initialPrimaryGroupFactor;

  static Future<FactorGroupingResult?> show(
    BuildContext context, {
    required List<String> filePaths,
    Map<String, Map<String, String>> initialFileFactors = const {},
    Map<String, String> initialParticipantGroups = const {},
    Set<String> initialExcludedFiles = const {},
    String? initialPrimaryGroupFactor,
  }) {
    return showDialog<FactorGroupingResult>(
      context: context,
      builder: (_) => FactorGroupingDesignerDialog(
        filePaths: filePaths,
        initialFileFactors: initialFileFactors,
        initialParticipantGroups: initialParticipantGroups,
        initialExcludedFiles: initialExcludedFiles,
        initialPrimaryGroupFactor: initialPrimaryGroupFactor,
      ),
    );
  }

  /// Extracts a session token from BIDS (`ses-02`) or concatenated IDs (`SKYMED013SESSION03`).
  static String? extractSessionToken(String stem) {
    final bids = RegExp(
      r'(?:^|_)ses-([A-Za-z0-9]+)',
      caseSensitive: false,
    ).firstMatch(stem);
    if (bids != null) return bids.group(1);

    final concat = RegExp(
      r'(?:^|_|(?<=\d))(?:(session[-_]?\d+)|(visit[-_]?\d+))',
      caseSensitive: false,
    ).firstMatch(stem);
    if (concat != null) {
      return (concat.group(1) ?? concat.group(2))?.toUpperCase();
    }
    return null;
  }

  /// Boundary-safe longest-key match between a metadata lookup and a recording file.
  static Map<String, String>? matchSheetRow(
    String filePath,
    String extractedSubject,
    Map<String, Map<String, String>> lookup,
  ) {
    final subj = extractedSubject.trim().toLowerCase();
    final subjNoPrefix = subj.replaceFirst(RegExp(r'^sub-'), '');
    final base = filePath.split(RegExp(r'[/\\]')).last;
    final stem = base.replaceFirst(RegExp(r'\.[^.]+$'), '').toLowerCase();

    final exact = lookup[subj] ?? lookup[subjNoPrefix] ?? lookup[stem];
    if (exact != null) return exact;

    final sortedEntries = lookup.entries.toList()
      ..sort((a, b) => b.key.length.compareTo(a.key.length));
    for (final entry in sortedEntries) {
      final key = entry.key.trim().toLowerCase();
      if (key.length < 3) continue;
      final candidateTargets = [subj, stem];
      for (final target in candidateTargets) {
        final idx = target.indexOf(key);
        if (idx < 0) continue;
        final afterIdx = idx + key.length;
        final keyEndsDigit = RegExp(r'\d$').hasMatch(key);
        final nextCharIsDigit =
            afterIdx < target.length &&
            RegExp(r'^\d').hasMatch(target.substring(afterIdx, afterIdx + 1));
        if (keyEndsDigit && nextCharIsDigit) continue;
        final prevOk =
            idx == 0 ||
            !RegExp(r'[A-Za-z0-9]$').hasMatch(target.substring(idx - 1, idx));
        if (prevOk || target == subj) {
          return entry.value;
        }
      }
    }
    return null;
  }

  @override
  State<FactorGroupingDesignerDialog> createState() =>
      _FactorGroupingDesignerDialogState();
}

class _FactorGroupingDesignerDialogState
    extends State<FactorGroupingDesignerDialog> {
  final List<String> _factorNames = [];
  // filePath -> {factorName: value}
  final Map<String, Map<String, String>> _fileFactors = {};
  final Set<String> _excludedFiles = {};
  String _primaryGroupFactor = 'Group';
  String _sheetStatus = '';

  // Filename cropper state
  int _cropSampleIndex = 0;
  int _cropStart = 0;
  int _cropEnd = 9;
  final TextEditingController _cropFactorCtrl = TextEditingController(
    text: 'Session',
  );
  int _selectedRuleIdx = 0;

  // Sheet mapping state
  final TextEditingController _sheetPathCtrl = TextEditingController();
  List<String> _sheetHeaders = [];
  List<List<String>> _sheetRows = [];
  String? _sheetKeyCol;
  final Set<String> _sheetImportCols = {};

  @override
  void initState() {
    super.initState();
    _excludedFiles.addAll(widget.initialExcludedFiles);
    for (final p in widget.filePaths) {
      _fileFactors[p] = Map<String, String>.from(
        widget.initialFileFactors[p] ?? {},
      );
    }
    _autoDetectFactors(initial: true);
    if (widget.filePaths.isNotEmpty) {
      final firstStem = _stem(widget.filePaths.first);
      _cropStart = 0;
      _cropEnd = math.min(9, firstStem.length);
    }
  }

  @override
  void dispose() {
    _cropFactorCtrl.dispose();
    _sheetPathCtrl.dispose();
    super.dispose();
  }

  String _filename(String path) => path.split(RegExp(r'[/\\]')).last;
  String _stem(String path) =>
      _filename(path).replaceFirst(RegExp(r'\.[^.]+$'), '');

  void _ensureFactor(String name) {
    if (!_factorNames.contains(name)) _factorNames.add(name);
  }

  void _autoDetectFactors({bool initial = false}) {
    if (widget.filePaths.isEmpty) return;

    // 1. Subject ID
    _ensureFactor('Subject');
    for (final p in widget.filePaths) {
      final parsedSubj = extractRecordingSubject(p);
      if (!initial || (_fileFactors[p]!['Subject'] ?? '').isEmpty) {
        _fileFactors[p]!['Subject'] = parsedSubj;
      }
    }

    // 2. Session & BIDS entities from filename / path
    final sessionVals = <String, String>{};
    for (final p in widget.filePaths) {
      final ses = FactorGroupingDesignerDialog.extractSessionToken(_stem(p));
      if (ses != null && ses.isNotEmpty) {
        sessionVals[p] = ses;
      }
    }
    if (sessionVals.values.toSet().length >= 2) {
      _ensureFactor('Session');
      for (final p in widget.filePaths) {
        _fileFactors[p]!['Session'] = sessionVals[p] ?? 'Unknown';
      }
    }

    final bidsEntities = <String, RegExp>{
      'Task': RegExp(r'(?:^|_)task-([^_]+)', caseSensitive: false),
      'Run': RegExp(r'(?:^|_)run-([^_]+)', caseSensitive: false),
    };
    for (final entry in bidsEntities.entries) {
      final vals = <String, String>{};
      for (final p in widget.filePaths) {
        final m = entry.value.firstMatch(_stem(p));
        if (m != null) vals[p] = m.group(1)!;
      }
      if (vals.values.toSet().length >= 2) {
        _ensureFactor(entry.key);
        for (final p in widget.filePaths) {
          _fileFactors[p]![entry.key] = vals[p] ?? 'Unknown';
        }
      }
    }

    // 3. Folder structure levels (parent, grandparent) if they vary meaningfully
    final parentVals = <String, String>{};
    final grandVals = <String, String>{};
    for (final p in widget.filePaths) {
      final segs = File(p).uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (segs.length >= 2) parentVals[p] = segs[segs.length - 2];
      if (segs.length >= 3) grandVals[p] = segs[segs.length - 3];
    }
    if (parentVals.values.toSet().length >= 2 &&
        parentVals.values.toSet().length < widget.filePaths.length) {
      final subjVals = widget.filePaths
          .map((p) => _fileFactors[p]!['Subject'] ?? '')
          .toSet();
      if (!parentVals.values.toSet().every((v) => subjVals.contains(v))) {
        _ensureFactor('Folder_L1');
        for (final p in widget.filePaths) {
          _fileFactors[p]!['Folder_L1'] = parentVals[p] ?? 'Unknown';
        }
      }
    }
    if (grandVals.values.toSet().length >= 2 &&
        grandVals.values.toSet().length <= 12) {
      _ensureFactor('Folder_L2');
      for (final p in widget.filePaths) {
        _fileFactors[p]!['Folder_L2'] = grandVals[p] ?? 'Unknown';
      }
    }

    // 4. Initial participant groups if provided
    if (initial && widget.initialParticipantGroups.isNotEmpty) {
      _ensureFactor('Group');
      for (final p in widget.filePaths) {
        final subj = _fileFactors[p]!['Subject'] ?? extractRecordingSubject(p);
        final g = widget.initialParticipantGroups[subj];
        if (g != null && g.isNotEmpty) {
          _fileFactors[p]!['Group'] = g;
        } else {
          _fileFactors[p]!['Group'] ??= 'Unknown';
        }
      }
    }

    // Collect any pre-existing factors from initialFileFactors
    for (final map in _fileFactors.values) {
      for (final k in map.keys) {
        _ensureFactor(k);
      }
    }
    final preferred = widget.initialPrimaryGroupFactor;
    if (preferred != null && _factorNames.contains(preferred)) {
      _primaryGroupFactor = preferred;
    } else if (_factorNames.contains('Group')) {
      _primaryGroupFactor = 'Group';
    } else if (_factorNames.isNotEmpty) {
      _primaryGroupFactor = _factorNames.first;
    }
    if (mounted && !initial) setState(() {});
  }

  Future<void> _pickAndLoadSheet() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['xlsx', 'csv', 'tsv'],
      dialogTitle: 'Select Group / Factor Mapping Sheet (.xlsx, .csv, .tsv)',
    );
    if (picked == null || picked.files.single.path == null || !mounted) return;
    final path = picked.files.single.path!;
    try {
      final parsed = await TabularSheetReader.read(path);
      if (parsed.headers.isEmpty) {
        setState(() => _sheetStatus = 'Sheet is empty: $path');
        return;
      }
      final keyCol = parsed.headers.firstWhere(
        (h) {
          final l = h.toLowerCase();
          return l.contains('subj') ||
              l == 'id' ||
              l.contains('participant') ||
              l.contains('file');
        },
        orElse: () => parsed.headers.first,
      );
      final importCols = parsed.headers
          .where((h) {
            final l = h.toLowerCase();
            return h != keyCol && l != 'sl.no.' && l != 'sno' && l != 'index';
          })
          .toSet();
      setState(() {
        _sheetPathCtrl.text = path;
        _sheetHeaders = parsed.headers;
        _sheetRows = parsed.rows;
        _sheetKeyCol = keyCol;
        _sheetImportCols
          ..clear()
          ..addAll(importCols);
        _sheetStatus =
            'Loaded ${parsed.rows.length} rows, ${parsed.headers.length} columns.';
      });
    } catch (e) {
      setState(() => _sheetStatus = 'Failed to read sheet: $e');
    }
  }

  void _applySheetMapping() {
    if (_sheetKeyCol == null || _sheetImportCols.isEmpty) return;
    final keyIdx = _sheetHeaders.indexOf(_sheetKeyCol!);
    if (keyIdx < 0) return;

    final lookup = <String, Map<String, String>>{};
    for (final row in _sheetRows) {
      if (keyIdx >= row.length) continue;
      final key = row[keyIdx].trim();
      if (key.isEmpty) continue;
      final map = <String, String>{};
      for (final col in _sheetImportCols) {
        final cIdx = _sheetHeaders.indexOf(col);
        if (cIdx >= 0 && cIdx < row.length) {
          map[col] = row[cIdx].trim();
        }
      }
      lookup[key.toLowerCase()] = map;
    }

    var matched = 0;
    for (final col in _sheetImportCols) {
      _ensureFactor(col);
    }
    for (final p in widget.filePaths) {
      final subj = _fileFactors[p]?['Subject'] ?? extractRecordingSubject(p);
      final hit = FactorGroupingDesignerDialog.matchSheetRow(p, subj, lookup);
      if (hit != null) {
        matched++;
        for (final col in _sheetImportCols) {
          final v = (hit[col] ?? '').trim();
          _fileFactors[p]![col] = v.isEmpty ? 'Unknown' : v;
        }
      } else {
        for (final col in _sheetImportCols) {
          final cur = _fileFactors[p]![col];
          _fileFactors[p]![col] = (cur == null || cur.isEmpty) ? 'Unknown' : cur;
        }
      }
    }
    if (_sheetImportCols.contains('Group')) {
      _primaryGroupFactor = 'Group';
    }
    setState(() {
      _sheetStatus =
          'Mapped ${_sheetImportCols.join(", ")} to $matched / ${widget.filePaths.length} files.';
    });
  }

  void _applyCropRule(FilenameCropRule rule) {
    final name = _cropFactorCtrl.text.trim();
    if (name.isEmpty) return;
    _ensureFactor(name);
    for (final p in widget.filePaths) {
      final val = rule.apply(_filename(p));
      _fileFactors[p]![name] = val.isEmpty ? 'Unknown' : val;
    }
    setState(() {});
  }

  void _removeFactor(String name) {
    setState(() {
      _factorNames.remove(name);
      for (final m in _fileFactors.values) {
        m.remove(name);
      }
      if (_primaryGroupFactor == name) {
        _primaryGroupFactor =
            _factorNames.isNotEmpty ? _factorNames.first : '';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final sampleName = widget.filePaths.isNotEmpty
        ? _filename(widget.filePaths[_cropSampleIndex % widget.filePaths.length])
        : 'SKYMED013SESSION03.edf';
    final safeStart = _cropStart.clamp(0, math.max<int>(0, sampleName.length - 1));
    final safeEnd = _cropEnd.clamp(safeStart + 1, sampleName.length);
    final rules = FilenameCropRule.inferCandidates(
      sampleName,
      safeStart,
      safeEnd,
    );
    final activeRule = rules.isNotEmpty
        ? rules[_selectedRuleIdx.clamp(0, rules.length - 1)]
        : null;

    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.account_tree_outlined, size: 20),
          const SizedBox(width: 8),
          const Expanded(
            child: Text('Factor & Grouping Designer (Folder / Sheet / Filename)'),
          ),
          Text(
            '${widget.filePaths.length - _excludedFiles.length} / ${widget.filePaths.length} files active',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      content: SizedBox(
        width: 1040,
        height: 620,
        child: Row(
          children: [
            // Left: Sources (Auto, Sheet, Interactive Filename Cropper)
            Expanded(
              flex: 5,
              child: DefaultTabController(
                length: 3,
                child: Column(
                  children: [
                    const TabBar(
                      tabs: [
                        Tab(text: '1. Filename Cropper'),
                        Tab(text: '2. CSV / Excel Sheet'),
                        Tab(text: '3. Factors & Auto'),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: TabBarView(
                        children: [
                          _buildCropperTab(
                            sampleName,
                            safeStart,
                            safeEnd,
                            rules,
                            activeRule,
                          ),
                          _buildSheetTab(),
                          _buildFactorsTab(),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const VerticalDivider(width: 20),
            // Right: Interactive Grouping Tree
            Expanded(
              flex: 4,
              child: _buildGroupingTree(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: () {
            final groups = <String, String>{};
            final excludedLevels = <String, Set<String>>{};
            for (final factor in _factorNames) {
              final filesByLevel = <String, List<String>>{};
              for (final p in widget.filePaths) {
                final v = (_fileFactors[p]?[factor] ?? '').trim();
                final val = v.isEmpty ? 'Unknown' : v;
                filesByLevel.putIfAbsent(val, () => []).add(p);
              }
              final excludedForFactor = <String>{};
              for (final e in filesByLevel.entries) {
                if (e.value.isNotEmpty &&
                    e.value.every(_excludedFiles.contains)) {
                  excludedForFactor.add(e.key);
                }
              }
              if (excludedForFactor.isNotEmpty) {
                excludedLevels[factor] = excludedForFactor;
              }
            }
            for (final p in widget.filePaths) {
              if (_excludedFiles.contains(p)) continue;
              final subj =
                  _fileFactors[p]?['Subject'] ?? extractRecordingSubject(p);
              final grp = _fileFactors[p]?[_primaryGroupFactor] ?? '';
              if (subj.isNotEmpty && grp.isNotEmpty) {
                groups[subj] = grp;
              }
            }
            Navigator.pop(
              context,
              FactorGroupingResult(
                fileFactors: _fileFactors,
                participantGroups: groups,
                excludedFiles: _excludedFiles,
                factorNames: List<String>.from(_factorNames),
                primaryGroupFactor: _primaryGroupFactor,
                excludedLevelsByFactor: excludedLevels,
              ),
            );
          },
          icon: const Icon(Icons.check, size: 16),
          label: const Text('Apply Factors & Grouping'),
        ),
      ],
    );
  }

  Widget _buildCropperTab(
    String sampleName,
    int safeStart,
    int safeEnd,
    List<FilenameCropRule> rules,
    FilenameCropRule? activeRule,
  ) {
    final cropped = sampleName.substring(safeStart, safeEnd);
    return ListView(
      children: [
        const Text(
          'Highlight/crop the part of a sample filename representing a factor (e.g., Subject or Session). Logic is inferred automatically for all files.',
          style: TextStyle(fontSize: 11.5, color: Colors.white70),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _cropFactorCtrl,
                decoration: const InputDecoration(
                  labelText: 'Factor Name (e.g. Session, Subject, Condition)',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: widget.filePaths.isEmpty
                  ? null
                  : () => setState(() {
                      _cropSampleIndex =
                          (_cropSampleIndex + 1) % widget.filePaths.length;
                    }),
              child: const Text('Next Sample'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFF0F172A),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RichText(
                text: TextSpan(
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 15,
                  ),
                  children: [
                    TextSpan(
                      text: sampleName.substring(0, safeStart),
                      style: const TextStyle(color: Colors.white54),
                    ),
                    TextSpan(
                      text: cropped,
                      style: const TextStyle(
                        color: Colors.black,
                        backgroundColor: Color(0xFFFBBF24),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    TextSpan(
                      text: sampleName.substring(safeEnd),
                      style: const TextStyle(color: Colors.white54),
                    ),
                  ],
                ),
              ),
              RangeSlider(
                min: 0,
                max: math.max<int>(1, sampleName.length).toDouble(),
                divisions: math.max<int>(1, sampleName.length),
                values: RangeValues(safeStart.toDouble(), safeEnd.toDouble()),
                onChanged: (rv) {
                  setState(() {
                    _cropStart = rv.start.round();
                    _cropEnd = math.max(_cropStart + 1, rv.end.round());
                    _selectedRuleIdx = 0;
                  });
                },
              ),
              Text(
                'Cropped: "$cropped" (chars $safeStart..$safeEnd)',
                style: const TextStyle(fontSize: 11.5, color: Colors.amberAccent),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        if (rules.isNotEmpty) ...[
          DropdownButtonFormField<int>(
            initialValue: _selectedRuleIdx.clamp(0, rules.length - 1),
            decoration: const InputDecoration(
              labelText: 'Auto-Inferred Extraction Logic',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            items: [
              for (var i = 0; i < rules.length; i++)
                DropdownMenuItem(value: i, child: Text(rules[i].label)),
            ],
            onChanged: (v) {
              if (v != null) setState(() => _selectedRuleIdx = v);
            },
          ),
          const SizedBox(height: 8),
          if (activeRule != null) ...[
            Text(
              'Live preview across ${widget.filePaths.length} files (${widget.filePaths.map((p) => activeRule.apply(_filename(p))).toSet().length} unique values):',
              style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Container(
              height: 150,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white12),
                borderRadius: BorderRadius.circular(6),
              ),
              child: ListView.builder(
                itemCount: math.min(30, widget.filePaths.length),
                itemExtent: 28,
                itemBuilder: (_, i) {
                  final fn = _filename(widget.filePaths[i]);
                  final val = activeRule.apply(fn);
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            fn,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                        const Icon(Icons.arrow_forward, size: 12),
                        const SizedBox(width: 6),
                        Text(
                          val.isEmpty ? '(no match)' : val,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: val.isEmpty
                                ? Colors.redAccent
                                : Colors.greenAccent,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: () => _applyCropRule(activeRule),
              icon: const Icon(Icons.add_circle_outline, size: 16),
              label: Text('Extract Factor "${_cropFactorCtrl.text.trim()}"'),
            ),
          ],
        ],
      ],
    );
  }

  Widget _buildSheetTab() {
    return ListView(
      children: [
        const Text(
          'Load an Excel (.xlsx) or CSV/TSV mapping sheet (e.g. Groups.xlsx) and map columns onto recordings.',
          style: TextStyle(fontSize: 11.5, color: Colors.white70),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _sheetPathCtrl,
                readOnly: true,
                decoration: const InputDecoration(
                  labelText: 'Mapping Sheet Path',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonalIcon(
              onPressed: _pickAndLoadSheet,
              icon: const Icon(Icons.upload_file, size: 16),
              label: const Text('Browse…'),
            ),
          ],
        ),
        if (_sheetStatus.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            _sheetStatus,
            style: const TextStyle(fontSize: 11.5, color: Colors.lightBlueAccent),
          ),
        ],
        if (_sheetHeaders.isNotEmpty) ...[
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: _sheetKeyCol,
            decoration: const InputDecoration(
              labelText: 'Join Key Column (matches Subject ID or Filename)',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            items: [
              for (final h in _sheetHeaders)
                DropdownMenuItem(value: h, child: Text(h)),
            ],
            onChanged: (v) => setState(() => _sheetKeyCol = v),
          ),
          const SizedBox(height: 10),
          const Text(
            'Columns to import as Factors:',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final h in _sheetHeaders)
                if (h != _sheetKeyCol)
                  FilterChip(
                    label: Text(h),
                    selected: _sheetImportCols.contains(h),
                    onSelected: (sel) => setState(() {
                      if (sel) {
                        _sheetImportCols.add(h);
                      } else {
                        _sheetImportCols.remove(h);
                      }
                    }),
                  ),
            ],
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _sheetImportCols.isEmpty ? null : _applySheetMapping,
            icon: const Icon(Icons.merge_type, size: 16),
            label: const Text('Map Sheet Columns to Files'),
          ),
        ],
      ],
    );
  }

  Map<String, List<String>> _filesByLevelForFactor(String factor) {
    final grouped = <String, List<String>>{};
    for (final p in widget.filePaths) {
      final raw = (_fileFactors[p]?[factor] ?? '').trim();
      final val = raw.isEmpty ? 'Unknown' : raw;
      grouped.putIfAbsent(val, () => []).add(p);
    }
    return grouped;
  }

  List<String> _activeUnknownFiles() {
    final out = <String>[];
    for (final p in widget.filePaths) {
      if (_excludedFiles.contains(p)) continue;
      final isUnknownPrimary =
          (_fileFactors[p]?[_primaryGroupFactor] ?? '').trim().toLowerCase() ==
          'unknown';
      final isUnknownAny = _factorNames.any(
        (f) => (_fileFactors[p]?[f] ?? '').trim().toLowerCase() == 'unknown',
      );
      if (isUnknownPrimary || isUnknownAny) {
        out.add(p);
      }
    }
    return out;
  }

  void _excludeAllUnknown() {
    final unknownFiles = _activeUnknownFiles();
    if (unknownFiles.isEmpty) return;
    setState(() => _excludedFiles.addAll(unknownFiles));
  }

  Widget _buildFactorsTab() {
    final activeUnknown = _activeUnknownFiles();
    return ListView(
      padding: const EdgeInsets.only(top: 12, right: 6, bottom: 8),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            FilledButton.tonalIcon(
              onPressed: () => _autoDetectFactors(initial: false),
              icon: const Icon(Icons.auto_fix_high, size: 16),
              label: const Text('Auto-Detect BIDS & Folders'),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: _factorNames.contains(_primaryGroupFactor)
                    ? _primaryGroupFactor
                    : null,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Primary Group Factor',
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final f in _factorNames)
                    DropdownMenuItem(
                      value: f,
                      child: Text(f, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _primaryGroupFactor = v);
                },
              ),
            ),
          ],
        ),
        if (activeUnknown.isNotEmpty) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.amber.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.amber.withValues(alpha: 0.35)),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.filter_alt_outlined,
                  size: 16,
                  color: Colors.amber,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${activeUnknown.length} active recording(s) currently tagged "Unknown".',
                    style: const TextStyle(fontSize: 11.5),
                  ),
                ),
                FilledButton.tonal(
                  onPressed: _excludeAllUnknown,
                  child: const Text(
                    'Exclude "Unknown"',
                    style: TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 12),
        const Text(
          'Defined Factors (click level chips to include / deselect, or reorder hierarchy):',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        for (var i = 0; i < _factorNames.length; i++)
          Builder(
            builder: (context) {
              final factor = _factorNames[i];
              final byLevel = _filesByLevelForFactor(factor);
              final sortedLevels = byLevel.keys.toList()..sort();
              return Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 8, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '$factor (${sortedLevels.length} level${sortedLevels.length == 1 ? "" : "s"})',
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.arrow_upward, size: 16),
                            onPressed: i == 0
                                ? null
                                : () => setState(() {
                                    final item = _factorNames.removeAt(i);
                                    _factorNames.insert(i - 1, item);
                                  }),
                          ),
                          IconButton(
                            icon: const Icon(Icons.arrow_downward, size: 16),
                            onPressed: i == _factorNames.length - 1
                                ? null
                                : () => setState(() {
                                    final item = _factorNames.removeAt(i);
                                    _factorNames.insert(i + 1, item);
                                  }),
                          ),
                          if (factor != 'Subject')
                            IconButton(
                              icon: const Icon(Icons.delete_outline, size: 16),
                              onPressed: () => _removeFactor(factor),
                            ),
                        ],
                      ),
                      if (sortedLevels.length <= 40) ...[
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final lvl in sortedLevels)
                              Builder(
                                builder: (context) {
                                  final lvlFiles = byLevel[lvl]!;
                                  final activeCount = lvlFiles
                                      .where((p) => !_excludedFiles.contains(p))
                                      .length;
                                  final isIncluded = activeCount > 0;
                                  final isUnknown =
                                      lvl.toLowerCase() == 'unknown';
                                  return FilterChip(
                                    selected: isIncluded,
                                    visualDensity: VisualDensity.compact,
                                    label: Text(
                                      '$lvl ($activeCount/${lvlFiles.length})',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: isUnknown && isIncluded
                                            ? Colors.amber.shade200
                                            : null,
                                      ),
                                    ),
                                    onSelected: (selected) => setState(() {
                                      if (selected) {
                                        _excludedFiles.removeAll(lvlFiles);
                                      } else {
                                        _excludedFiles.addAll(lvlFiles);
                                      }
                                    }),
                                  );
                                },
                              ),
                          ],
                        ),
                      ] else
                        Text(
                          '${sortedLevels.length} unique values (use Grouping Tree to toggle individually)',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
      ],
    );
  }

  Widget _buildGroupingTree() {
    // Build hierarchical tree using _factorNames (excluding Subject at top if others exist)
    final treeFactors = _factorNames.where((f) => f != 'Subject').toList();
    if (treeFactors.isEmpty) treeFactors.addAll(_factorNames);
    final activeUnknown = _activeUnknownFiles();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 6,
          runSpacing: 2,
          children: [
            const Text(
              'Grouping Tree (Check to Include)',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold),
            ),
            if (activeUnknown.isNotEmpty)
              TextButton(
                onPressed: _excludeAllUnknown,
                child: Text(
                  'Exclude Unknown (${activeUnknown.length})',
                  style: const TextStyle(fontSize: 11, color: Colors.amber),
                ),
              ),
            TextButton(
              onPressed: () => setState(() => _excludedFiles.clear()),
              child: const Text(
                'Include All',
                style: TextStyle(fontSize: 11),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ListView(
              children: _buildTreeLevel(widget.filePaths, treeFactors, 0),
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildTreeLevel(
    List<String> files,
    List<String> factors,
    int depth,
  ) {
    if (depth >= factors.length) {
      return [
        for (final p in files)
          CheckboxListTile(
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            value: !_excludedFiles.contains(p),
            onChanged: (v) => setState(() {
              if (v == true) {
                _excludedFiles.remove(p);
              } else {
                _excludedFiles.add(p);
              }
            }),
            title: Text(
              _filename(p),
              style: const TextStyle(fontSize: 11.5),
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              'Subject: ${_fileFactors[p]?["Subject"] ?? ""}',
              style: const TextStyle(fontSize: 10),
            ),
          ),
      ];
    }

    final factor = factors[depth];
    final grouped = <String, List<String>>{};
    for (final p in files) {
      final val = _fileFactors[p]?[factor] ?? 'Unknown';
      grouped.putIfAbsent(val, () => []).add(p);
    }
    final keys = grouped.keys.toList()..sort();

    return [
      for (final k in keys)
        Builder(
          builder: (context) {
            final branchFiles = grouped[k]!;
            final activeCount =
                branchFiles.where((p) => !_excludedFiles.contains(p)).length;
            final allChecked = activeCount == branchFiles.length;
            final noneChecked = activeCount == 0;
            return ExpansionTile(
              initiallyExpanded: depth == 0 && keys.length <= 6,
              leading: Checkbox(
                tristate: true,
                value: allChecked ? true : (noneChecked ? false : null),
                onChanged: (v) => setState(() {
                  if (v == true) {
                    _excludedFiles.removeAll(branchFiles);
                  } else {
                    _excludedFiles.addAll(branchFiles);
                  }
                }),
              ),
              title: Text(
                '$factor: $k ($activeCount/${branchFiles.length})',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              childrenPadding: const EdgeInsets.only(left: 16),
              children: _buildTreeLevel(branchFiles, factors, depth + 1),
            );
          },
        ),
    ];
  }
}
