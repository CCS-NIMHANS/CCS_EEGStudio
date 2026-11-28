import 'erp/group_figure_studio.dart';
import 'extraction_service.dart';
import 'topostats/topostats_batch.dart' show preferSessionFeatureCsvs;
import 'filename_metadata.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'filtered_file_picker.dart';
import 'group_statistics_engine.dart';
import 'erp/factor_grouping_designer.dart'
    show
        TabularSheetReader,
        FilenameCropRule,
        FactorGroupingDesignerDialog;
import 'group_statistics_plots.dart';
import 'theme.dart';

/// Top-level entry point for running N-way permutation GLM/LMM models inside
/// [Isolate.run] without capturing any UI [State] or [BuildContext].
Map<String, dynamic> runDartPermutationsInIsolate(Map<String, dynamic> args) {
  final headers = (args['headers'] as List).cast<String>();
  final rows = (args['rows'] as List)
      .map((r) => (r as List).map((e) => '$e').toList())
      .toList();
  final factors = (args['factors'] as List).cast<String>();
  final metrics = (args['metrics'] as List).cast<String>();
  final subjectCol = args['subjectCol'] as String?;
  final preferredModel = args['preferredModel'] as String? ?? 'auto';
  final posthocMethod = args['posthocMethod'] as String? ?? 'fdr';
  final includeInteractions = args['includeInteractions'] as bool? ?? true;
  final nPermutations = (args['nPermutations'] as num?)?.toInt() ?? 1000;
  final rawExcluded = args['excludedLevels'] as Map? ?? const {};
  final excludedLevels = <String, Set<String>>{
    for (final entry in rawExcluded.entries)
      '${entry.key}': (entry.value as Iterable).map((e) => '$e').toSet(),
  };
  final rawOrder = args['customLevelOrder'] as Map? ?? const {};
  final customLevelOrder = <String, List<String>>{
    for (final entry in rawOrder.entries)
      '${entry.key}': (entry.value as Iterable).map((e) => '$e').toList(),
  };
  final contrastFactors = (args['contrastFactors'] as List? ?? const [])
      .map((e) => '$e')
      .toList();

  return ErpGroupStatsEngine.runAnalysis(
    headers: headers,
    rows: rows,
    factors: factors,
    metrics: metrics,
    subjectCol: subjectCol,
    preferredModel: preferredModel,
    posthocMethod: posthocMethod,
    includeInteractions: includeInteractions,
    nPermutations: nPermutations,
    excludedLevels: excludedLevels,
    customLevelOrder: customLevelOrder,
    contrastFactors: contrastFactors,
  );
}

/// Top-level `Isolate.run` boundary prevents Dart shared closures in Stateful
/// callbacks from retaining UI `State` / `BuildContext` / `WidgetsFlutterBinding`.
Future<Map<String, dynamic>> runDartPermutationsInWorker(
  Map<String, dynamic> payload,
) => Isolate.run(() => runDartPermutationsInIsolate(payload));

Future<Map<String, dynamic>> inspectGroupDatasetInWorker(
  String csv,
  String metadata,
  String key, {
  List<Map<String, dynamic>> factorRules = const [],
  List<Map<String, dynamic>> externalSheets = const [],
}) => Isolate.run(
  () => ErpGroupStatsEngine.inspectDataset(
    csvPath: csv,
    metadataPath: metadata,
    metadataKey: key,
    factorRules: factorRules,
    externalSheets: externalSheets,
  ),
);

/// Read Excel with the app's bundled reader so Python needs no Excel plugin.
Future<String> prepareGroupMetadataForPython(
  String path,
  Directory runtime,
) async {
  if (!path.toLowerCase().endsWith('.xlsx')) return path;
  final table = await TabularSheetReader.read(path);
  String cell(String value) => '"${value.replaceAll('"', '""')}"';
  final csv = [
    table.headers,
    ...table.rows,
  ].map((row) => row.map(cell).join(',')).join('\n');
  final file = File('${runtime.path}/participant_groups.csv');
  await file.writeAsString(csv);
  return file.path;
}

String groupMetricLabel(String name) {
  const labels = {
    'mean_amplitude_ERP': 'Mean amplitude (µV)',
    'signed_auc_ERP': 'Signed area under the curve (µV·s)',
    'peak_amplitude_ERP': 'Peak amplitude (µV)',
    'peak_latency_ms_ERP': 'Peak latency (ms)',
    'fractional_area_latency_ms_ERP': 'Fractional-area latency (ms)',
  };
  final direct = labels[name];
  if (direct != null) return direct;
  final m = RegExp(r'^(.+?)\s*(\([^()]+\))$').firstMatch(name.trim());
  if (m != null) {
    final base = labels[m.group(1)!.trim()] ?? m.group(1)!.trim();
    return '$base ${m.group(2)!}';
  }
  return name;
}

class GroupStatisticsWorkbench extends StatefulWidget {
  const GroupStatisticsWorkbench({
    super.key,
    this.initialCsvPath,
    this.initialMetadataPath,
  });

  final String? initialCsvPath;
  final String? initialMetadataPath;

  @override
  State<GroupStatisticsWorkbench> createState() =>
      _GroupStatisticsWorkbenchState();
}

class _GroupStatisticsWorkbenchState extends State<GroupStatisticsWorkbench> {
  final TextEditingController _csvPathController = TextEditingController();
  final TextEditingController _metadataPathController = TextEditingController();
  final TextEditingController _metadataKeyController = TextEditingController();

  bool _isInspecting = false;
  final List<Map<String, dynamic>> _factorRules = [];
  final List<Map<String, dynamic>> _externalSheets = [];

  String? get _participantGroupColumn {
    final counts = _dartInspection?['factor_counts'] as Map? ?? {};
    for (final column in counts.keys) {
      if (!const {
        'group',
        'cohort',
        'arm',
        'groupid',
        'group_id',
      }.contains('$column'.toLowerCase()))
        continue;
      final values = (counts[column] as Map).keys.map(
        (k) => '$k'.trim().toLowerCase(),
      );
      if (values.any(
        (v) => !const {'', 'unknown', 'unassigned', 'nan', 'none'}.contains(v),
      ))
        return '$column';
    }
    return null;
  }

  Set<String> get _unassignedGroupLabels {
    final counts =
        (_dartInspection?['factor_counts'] as Map?)?[_participantGroupColumn]
            as Map? ??
        {};
    return counts.keys
        .map((k) => '$k')
        .where(
          (k) => const {
            '',
            'unknown',
            'unassigned',
            'nan',
            'none',
          }.contains(k.toLowerCase().trim()),
        )
        .toSet();
  }

  bool get _groupsReady => _unassignedGroupLabels.every(
    (label) =>
        (_dartExcludedLevels[_participantGroupColumn] ?? {}).contains(label),
  );

  void _setExcludeUnassigned(bool exclude) {
    setState(() {
      final group = _participantGroupColumn;
      if (group != null) {
        final levels = _dartExcludedLevels.putIfAbsent(group, () => {});
        if (exclude) {
          levels.addAll(_unassignedGroupLabels);
        } else {
          levels.removeAll(_unassignedGroupLabels);
        }
      }
    });
  }

  int _workflowStep = 0;

  void _invalidateInspection() {
    setState(() {
      _inspectionData = null;
      _dartInspection = null;
      _analysisResults = null;
      _dartAnalysisResults = null;
      _workflowStep = 0;
      _statusMessage =
          'Data changed. Click Review data to refresh.';
    });
  }

  bool _isAnalyzing = false;
  final double _analysisProgress = 0.0;
  String _progressStatus = '';
  String _statusMessage = '';
  final List<String> _consoleLogs = [];

  // Inspected Metadata
  Map<String, dynamic>? _inspectionData;
  String? _selectedSubjectIdCol;
  final Set<String> _selectedMetrics = {};

  // Modelling preferences
  String _preferredModel = 'auto'; // 'auto', 'lmm', 'glm'
  String _posthocMethod = 'fdr'; // 'fdr', 'bonferroni'

  // Analysis Results
  Map<String, dynamic>? _analysisResults;
  String? _selectedResultMetric;
  int _activeResultTabIndex =
      0; // 0: Plot, 1: Model Effects, 2: Post-Hoc, 3: Descriptives
  int _activePlotView = 0; // 0: Box & Post-Hoc Plot, 1: Scalp Topoplot

  // Pure-Dart Permutation GLM/LMM & Configurable Plot State
  Map<String, dynamic>? _dartInspection;
  final List<String> _dartFactors = [];
  final Map<String, Set<String>> _dartExcludedLevels = {};
  final Map<String, List<String>> _dartLevelOrder = {};
  final TextEditingController _permCountCtrl = TextEditingController(
    text: '1000',
  );
  bool _includeInteractions = true;
  bool _fittedFactorial = true;
  final Set<String> _selectedContrastFactors = {};
  String _contrastScopeMode = 'both'; // 'simple', 'marginal', 'both'
  final Map<String, Set<String>> _selectedContrastPairs = {};
  bool _erpDiffMode = false;
  final List<({String condB, String condA})> _erpDiffPairs = [];
  String? _erpDiffCondB;
  String? _erpDiffCondA;
  StatsPlotLayoutConfig _plotConfig = const StatsPlotLayoutConfig();
  Map<String, dynamic>? _dartAnalysisResults;
  String? _selectedDartMetric;
  int _dartResultTab = 0;
  String? _plotBracketFactorFilter;
  String? _posthocTableFactorFilter;
  bool _posthocTableSigOnly = false;
  String _posthocTableScope = 'all'; // 'all', 'simple', 'marginal'
  bool _isExportingStatsPlot = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialMetadataPath != null &&
        widget.initialMetadataPath!.isNotEmpty) {
      _metadataPathController.text = widget.initialMetadataPath!;
      _externalSheets.add({'path': widget.initialMetadataPath!});
    }
    if (widget.initialCsvPath != null && widget.initialCsvPath!.isNotEmpty) {
      _csvPathController.text = widget.initialCsvPath!;
      WidgetsBinding.instance.addPostFrameCallback((_) => _inspectCsv());
    }
  }

  @override
  void dispose() {
    _csvPathController.dispose();
    _metadataPathController.dispose();
    _metadataKeyController.dispose();
    _permCountCtrl.dispose();
    super.dispose();
  }

  static final Future<Directory> _runtimeDirectory = Directory.systemTemp
      .createTemp('ccs-stats-$pid-');

  static Future<String?> _findPythonExecutable() async {
    final candidates = [
      if (Platform.environment['CCS_EEG_PYTHON'] != null)
        Platform.environment['CCS_EEG_PYTHON']!,
      if (Platform.isWindows) 'python.exe',
      if (Platform.isWindows) r'C:\Python312\python.exe',
      if (Platform.isWindows) r'C:\Python311\python.exe',
      if (Platform.isMacOS) '/opt/homebrew/bin/python3',
      if (Platform.isMacOS) '/usr/local/bin/python3',
      if (Platform.isLinux) '/usr/bin/python3',
      'python3',
      'python',
    ];
    for (final cand in candidates) {
      try {
        final res = await Process.run(
          cand,
          [
            '-c',
            'import numpy, pandas, scipy, statsmodels, matplotlib; print("ready")',
          ],
          environment: {
            'MPLCONFIGDIR': '${(await _runtimeDirectory).path}/mpl',
          },
        );
        if (res.exitCode == 0) return cand;
      } catch (_) {}
    }
    return null;
  }

  Future<void> _pickCsvFile() async {
    final result = await pickFilteredFiles(
      context,
      type: FileType.custom,
      allowedExtensions: ['csv'],
      allowMultiple: true,
      dialogTitle: 'Choose feature CSV files',
    );
    if (result != null) {
      final files = preferSessionFeatureCsvs(
        result.files.map((f) => f.path).whereType<String>().toList(),
      );
      if (files.isEmpty) return;
      String path = files.first;
      if (files.length > 1) {
        final dir = Directory(
          '${File(files.first).parent.path}/Group_Statistics',
        );
        await dir.create(recursive: true);
        path = '${dir.path}/group_input.features.csv';
        await ExtractionService().compileCsvFiles(files, path);
      }
      setState(() {
        _csvPathController.text = path;
      });
      await _inspectCsv();
    }
  }

  Future<void> _pickFeatureFolder() async {
    final path = await FilePicker.getDirectoryPath(
      dialogTitle: 'Choose a feature-results folder',
    );
    if (path == null) return;
    final erpDir = Directory('$path/Group_Statistics');
    final erpTables = <String>[];
    for (final dir in [Directory(path), erpDir]) {
      if (!await dir.exists()) continue;
      await for (final entry in dir.list(followLinks: false)) {
        if (entry is File && entry.path.endsWith('_conditions_group_input.csv'))
          erpTables.add(entry.path);
      }
    }
    if (erpTables.isNotEmpty) {
      String? selected = erpTables.first;
      if (erpTables.length > 1 && mounted) {
        selected = await showDialog<String>(
          context: context,
          builder: (ctx) => SimpleDialog(
            title: const Text('Choose an ERP measurement table'),
            children: [
              for (final table in erpTables)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, table),
                  child: Text(File(table).uri.pathSegments.last),
                ),
            ],
          ),
        );
      }
      if (selected == null || !mounted) return;
      setState(() => _csvPathController.text = selected!);
      await _inspectCsv();
      return;
    }
    final files = <String>[];
    await for (final entry in Directory(path).list(followLinks: false)) {
      if (entry is File && entry.path.endsWith('.features.csv'))
        files.add(entry.path);
    }
    files.sort();
    if (files.isEmpty) {
      _showSnack(
        'No ERP measurement tables or recording feature CSVs found. Choose the saved analysis folder, or select a measurement CSV directly.',
      );
      return;
    }
    final dir = Directory('$path/Group_Statistics');
    await dir.create(recursive: true);
    final pooled = '${dir.path}/group_input.features.csv';
    await ExtractionService().compileCsvFiles(files, pooled);
    if (!mounted) return;
    setState(() => _csvPathController.text = pooled);
    await _inspectCsv();
  }

  Future<void> _openFactorDesignerInGroupStats() async {
    final insp = _dartInspection;
    if (insp == null) {
      _showSnack('Load a measurement CSV first.');
      return;
    }
    final headers = (insp['headers'] as List).cast<String>();
    final rows = (insp['rows'] as List).cast<List>();
    final fnIdx = headers.indexWhere(
      (h) => const {
        'filename',
        'file',
        'source_file',
        'source_path',
        'path',
      }.contains(h.toLowerCase()),
    );
    final keyIdx = fnIdx >= 0
        ? fnIdx
        : headers.indexWhere(
            (h) => const {
              'subjid',
              'subject',
              'participant_id',
              'subject_id',
            }.contains(h.toLowerCase()),
          );
    if (keyIdx < 0) {
      _showSnack('No filename or participant column found.');
      return;
    }

    final filePaths = <String>[];
    final initialFileFactors = <String, Map<String, String>>{};
    final factorCols = (insp['factor_columns'] as List? ?? []).cast<String>();
    final subjIdx = _selectedSubjectIdCol != null
        ? headers.indexOf(_selectedSubjectIdCol!)
        : -1;

    for (final r in rows) {
      if (keyIdx >= r.length) continue;
      final path = '${r[keyIdx]}'.trim();
      if (path.isEmpty) continue;
      if (!initialFileFactors.containsKey(path)) {
        filePaths.add(path);
        final map = <String, String>{};
        if (subjIdx >= 0 && subjIdx < r.length && '${r[subjIdx]}'.trim().isNotEmpty) {
          map['Subject'] = '${r[subjIdx]}'.trim();
        }
        for (final fc in factorCols) {
          if (const {
            'filename',
            'file',
            'source_file',
            'source_path',
            'path',
            'sl.no.',
            'sl.no',
            'sno',
            'index',
            'condn',
            'condition',
            'epoch_label',
            'chan',
            'epoch',
            'component',
          }.contains(fc.toLowerCase())) {
            continue;
          }
          final ci = headers.indexOf(fc);
          if (ci >= 0 && ci < r.length) {
            final v = '${r[ci]}'.trim();
            if (v.isNotEmpty && v != 'Unknown') {
              map[fc] = v;
            }
          }
        }
        initialFileFactors[path] = map;
      }
    }

    if (filePaths.isEmpty) {
      _showSnack('No recording entries found in measurement table.');
      return;
    }

    final res = await FactorGroupingDesignerDialog.show(
      context,
      filePaths: filePaths,
      initialFileFactors: initialFileFactors,
    );
    if (res == null || !mounted) return;

    final rowMap = <String, Map<String, String>>{};
    for (final entry in res.fileFactors.entries) {
      final cleaned = <String, String>{};
      for (final fe in entry.value.entries) {
        final v = fe.value.trim();
        if (v.isNotEmpty) cleaned[fe.key] = v;
      }
      if (cleaned.isNotEmpty) rowMap[entry.key] = cleaned;
    }

    setState(() {
      _factorRules.removeWhere((r) => r['mode'] == 'manual_map');
      if (rowMap.isNotEmpty) {
        _factorRules.add({
          'mode': 'manual_map',
          'label': 'Factor & Grouping Designer (${res.factorNames.length} factor(s))',
          'rows': rowMap,
        });
      }
      for (final e in res.excludedLevelsByFactor.entries) {
        if (e.value.isNotEmpty) {
          _dartExcludedLevels[e.key] = Set<String>.from(e.value);
        }
      }
    });
    await _inspectCsv();
  }

  Future<void> _pickMetadataFile() async {
    final result = await pickFilteredFiles(
      context,
      type: FileType.custom,
      allowedExtensions: ['csv', 'xlsx', 'tsv'],
      dialogTitle: 'Attach Excel / CSV Factor Sheet',
    );
    if (result == null || result.files.single.path == null || !mounted) return;
    final path = result.files.single.path!;
    await _showAttachSheetDialog(path);
  }

  Future<void> _showAttachSheetDialog(String path) async {
    try {
      final parsed = await TabularSheetReader.read(path);
      if (!mounted) return;
      if (parsed.headers.isEmpty) {
        _showSnack('The selected sheet has no headers.');
        return;
      }
      final tableHeaders =
          (_dartInspection?['headers'] as List? ?? const []).cast<String>();
      final sheetHeaders = parsed.headers;
      var sheetKey = sheetHeaders.firstWhere(
        (h) {
          final l = h.toLowerCase();
          return l == 'subject' ||
              l == 'subjid' ||
              l == 'participant_id' ||
              l == 'subject_id' ||
              l == 'id' ||
              l == 'filename';
        },
        orElse: () => sheetHeaders.first,
      );
      var tableKey = 'Auto';
      final selectedCols = sheetHeaders
          .where((h) {
            final l = h.toLowerCase();
            return h != sheetKey &&
                l != 'sl.no.' &&
                l != 'sl.no' &&
                l != 'sno' &&
                l != 'index';
          })
          .toSet();

      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDlg) => AlertDialog(
            title: Text(
              'Attach Sheet: ${filenameBasename(path)}',
            ),
            content: SizedBox(
              width: 560,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${parsed.rows.length} rows detected. Choose which column identifies each participant/recording and which factor columns to import.',
                      style: const TextStyle(fontSize: 12),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: sheetKey,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'ID column in this sheet',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: [
                        for (final h in sheetHeaders)
                          DropdownMenuItem(value: h, child: Text(h)),
                      ],
                      onChanged: (v) {
                        if (v != null) {
                          setDlg(() {
                            sheetKey = v;
                            selectedCols.remove(v);
                          });
                        }
                      },
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      initialValue: tableKey,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Match against measurement table column',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: [
                        const DropdownMenuItem(
                          value: 'Auto',
                          child: Text('Auto-detect (Subject ID or Filename)'),
                        ),
                        for (final h in tableHeaders)
                          DropdownMenuItem(value: h, child: Text(h)),
                      ],
                      onChanged: (v) => setDlg(() => tableKey = v ?? 'Auto'),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Factor columns to import:',
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final h in sheetHeaders)
                          if (h != sheetKey)
                            FilterChip(
                              label: Text(h),
                              selected: selectedCols.contains(h),
                              onSelected: (sel) => setDlg(() {
                                if (sel) {
                                  selectedCols.add(h);
                                } else {
                                  selectedCols.remove(h);
                                }
                              }),
                            ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: selectedCols.isEmpty
                    ? null
                    : () => Navigator.pop(ctx, true),
                child: const Text('Attach Sheet'),
              ),
            ],
          ),
        ),
      );
      if (confirmed != true || !mounted) return;
      setState(() {
        _externalSheets.removeWhere((s) => s['path'] == path);
        _externalSheets.add({
          'path': path,
          'sheetJoinCol': sheetKey,
          if (tableKey != 'Auto') 'tableJoinCol': tableKey,
          'selectedColumns': selectedCols.toList(),
        });
        _metadataPathController.text = path;
      });
      if (_csvPathController.text.trim().isNotEmpty &&
          File(_csvPathController.text.trim()).existsSync()) {
        await _inspectCsv();
      }
    } catch (e) {
      if (mounted) _showSnack('Could not read sheet: $e');
    }
  }

  Future<void> _openAddFilenameFactorDialog() async {
    final insp = _dartInspection;
    if (insp == null) {
      _showSnack('Load a measurement CSV first.');
      return;
    }
    final headers = (insp['headers'] as List).cast<String>();
    final rows = (insp['rows'] as List).cast<List>();
    final fnIdx = headers.indexWhere(
      (h) => const {
        'filename',
        'file',
        'source_file',
        'source_path',
        'path',
      }.contains(h.toLowerCase()),
    );
    var sourceCol = fnIdx >= 0 ? headers[fnIdx] : headers.first;
    List<String> samplesForCol(String col) {
      final ci = headers.indexOf(col);
      if (ci < 0) return const [];
      final seen = <String>{};
      final out = <String>[];
      for (final r in rows) {
        if (ci >= r.length) continue;
        final raw = '${r[ci]}'.trim();
        if (raw.isEmpty) continue;
        if (seen.add(raw)) {
          out.add(raw);
          if (out.length >= 25) break;
        }
      }
      return out;
    }

    var modeTab = 0; // 0: Crop, 1: Delimiter, 2: Folder
    final factorCtrl = TextEditingController(text: 'Session');
    var sampleIdx = 0;
    var cropStart = 0;
    var cropEnd = 6;
    var selectedCandidateIdx = 0;
    var delimiter = '_';
    var selectedPartIdx = 0;
    var folderLevel = 1;

    final initSamples = samplesForCol(sourceCol);
    if (initSamples.isNotEmpty) {
      final base = filenameBasename(initSamples.first);
      cropStart = 0;
      cropEnd = math.min<int>(9, math.max<int>(1, base.length));
    }

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) {
          final rawSamples = samplesForCol(sourceCol);
          final isFileCol = const {
            'filename',
            'file',
            'source_file',
            'source_path',
            'path',
          }.contains(sourceCol.toLowerCase());
          final currentRaw = rawSamples.isEmpty
              ? 'SKYMED013SESSION03-epo_clean.edf'
              : rawSamples[sampleIdx % rawSamples.length];
          final sampleName = isFileCol ? filenameBasename(currentRaw) : currentRaw;
          final safeStart = cropStart.clamp(0, math.max<int>(0, sampleName.length - 1));
          final safeEnd = cropEnd.clamp(safeStart + 1, math.max<int>(1, sampleName.length));
          final candidates = FilenameCropRule.inferCandidates(
            sampleName,
            safeStart,
            safeEnd,
          );
          final activeCand = candidates.isNotEmpty
              ? candidates[selectedCandidateIdx.clamp(0, candidates.length - 1)]
              : null;

          final stem = sampleName.replaceFirst(RegExp(r'\.[^.]+$'), '');
          final delimParts = delimiter.isEmpty
              ? [stem]
              : stem.split(delimiter).where((p) => p.isNotEmpty).toList();
          final pathSegs = currentRaw
              .split(RegExp(r'[/\\]'))
              .where((s) => s.isNotEmpty)
              .toList();

          String previewFor(String raw) {
            if (modeTab == 0) {
              if (activeCand == null) return '';
              return activeCand.apply(isFileCol ? filenameBasename(raw) : raw);
            } else if (modeTab == 1) {
              final s = (isFileCol ? filenameBasename(raw) : raw)
                  .replaceFirst(RegExp(r'\.[^.]+$'), '');
              final p = delimiter.isEmpty
                  ? [s]
                  : s.split(delimiter).where((x) => x.isNotEmpty).toList();
              return selectedPartIdx < p.length ? p[selectedPartIdx] : '';
            } else {
              final segs = raw
                  .split(RegExp(r'[/\\]'))
                  .where((s) => s.isNotEmpty)
                  .toList();
              final ti = segs.length - 1 - folderLevel;
              return (ti >= 0 && ti < segs.length) ? segs[ti] : '';
            }
          }

          return AlertDialog(
            title: const Text('Add Factor from Filename or Folder Path'),
            content: SizedBox(
              width: 720,
              height: 520,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: factorCtrl,
                          decoration: const InputDecoration(
                            labelText: 'New Factor Name (e.g. Session, Site, Drug)',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: sourceCol,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Extract from column',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          items: [
                            for (final h in headers)
                              DropdownMenuItem(value: h, child: Text(h)),
                          ],
                          onChanged: (v) {
                            if (v != null) {
                              setDlg(() {
                                sourceCol = v;
                                sampleIdx = 0;
                              });
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton(
                        onPressed: rawSamples.isEmpty
                            ? null
                            : () => setDlg(() => sampleIdx++),
                        child: const Text('Next Sample'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(value: 0, label: Text('Crop from Filename')),
                      ButtonSegment(value: 1, label: Text('Split by Delimiter')),
                      ButtonSegment(value: 2, label: Text('From Folder Path')),
                    ],
                    selected: {modeTab},
                    onSelectionChanged: (s) => setDlg(() => modeTab = s.first),
                  ),
                  const SizedBox(height: 10),
                  if (modeTab == 0) ...[
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8F9FB),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFCBD5E1)),
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
                                  style: const TextStyle(color: Color(0xFF64748B)),
                                ),
                                TextSpan(
                                  text: sampleName.substring(safeStart, safeEnd),
                                  style: const TextStyle(
                                    color: Colors.black,
                                    backgroundColor: Color(0xFFFBBF24),
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                TextSpan(
                                  text: sampleName.substring(safeEnd),
                                  style: const TextStyle(color: Color(0xFF64748B)),
                                ),
                              ],
                            ),
                          ),
                          RangeSlider(
                            min: 0,
                            max: math.max<int>(1, sampleName.length).toDouble(),
                            divisions: math.max<int>(1, sampleName.length),
                            values: RangeValues(
                              safeStart.toDouble(),
                              safeEnd.toDouble(),
                            ),
                            onChanged: (rv) => setDlg(() {
                              cropStart = rv.start.round();
                              cropEnd = math.max<int>(
                                cropStart + 1,
                                rv.end.round(),
                              );
                              selectedCandidateIdx = 0;
                            }),
                          ),
                          if (candidates.isNotEmpty)
                            DropdownButtonFormField<int>(
                              initialValue: selectedCandidateIdx.clamp(
                                0,
                                candidates.length - 1,
                              ),
                              decoration: const InputDecoration(
                                labelText: 'Auto-inferred extraction rule',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              items: [
                                for (var i = 0; i < candidates.length; i++)
                                  DropdownMenuItem(
                                    value: i,
                                    child: Text(candidates[i].label),
                                  ),
                              ],
                              onChanged: (v) {
                                if (v != null) {
                                  setDlg(() => selectedCandidateIdx = v);
                                }
                              },
                            ),
                        ],
                      ),
                    ),
                  ] else if (modeTab == 1) ...[
                    Row(
                      children: [
                        SizedBox(
                          width: 180,
                          child: DropdownButtonFormField<String>(
                            initialValue: delimiter,
                            decoration: const InputDecoration(
                              labelText: 'Separator',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                            items: const [
                              DropdownMenuItem(value: '_', child: Text('Underscore (_)')),
                              DropdownMenuItem(value: '-', child: Text('Hyphen (-)')),
                              DropdownMenuItem(value: ' ', child: Text('Space')),
                              DropdownMenuItem(value: '.', child: Text('Dot (.)')),
                            ],
                            onChanged: (v) => setDlg(() {
                              delimiter = v ?? '_';
                              selectedPartIdx = 0;
                            }),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (var i = 0; i < delimParts.length; i++)
                                ChoiceChip(
                                  label: Text('${i + 1}: ${delimParts[i]}'),
                                  selected: selectedPartIdx == i,
                                  onSelected: (_) =>
                                      setDlg(() => selectedPartIdx = i),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ] else ...[
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        for (var lvl = 1; lvl <= 4; lvl++)
                          ChoiceChip(
                            label: Text(
                              'Parent $lvl: ${pathSegs.length - 1 - lvl >= 0 ? pathSegs[pathSegs.length - 1 - lvl] : "(none)"}',
                            ),
                            selected: folderLevel == lvl,
                            onSelected: (_) => setDlg(() => folderLevel = lvl),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 10),
                  const Text(
                    'Live preview across recordings:',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: const Color(0xFFCBD5E1)),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: ListView.builder(
                        itemCount: rawSamples.length,
                        itemExtent: 28,
                        itemBuilder: (_, i) {
                          final raw = rawSamples[i];
                          final val = previewFor(raw);
                          return Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    isFileCol ? filenameBasename(raw) : raw,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 11.5),
                                  ),
                                ),
                                const Icon(Icons.arrow_forward, size: 13),
                                const SizedBox(width: 6),
                                Text(
                                  val.isEmpty ? '(no match)' : val,
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.bold,
                                    color: val.isEmpty
                                        ? const Color(0xFFDC2626)
                                        : const Color(0xFF16A34A),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  final fName = factorCtrl.text.trim();
                  if (fName.isEmpty) return;
                  if (modeTab == 0 && activeCand != null) {
                    Navigator.pop(ctx, {
                      'mode': 'crop',
                      'factorName': fName,
                      'sourceCol': sourceCol,
                      'label': activeCand.label,
                      'pattern': activeCand.pattern,
                      'isFixedSlice': activeCand.isFixedSlice,
                      'start': activeCand.start,
                      'end': activeCand.end,
                    });
                  } else if (modeTab == 1) {
                    Navigator.pop(ctx, {
                      'mode': 'delimiter',
                      'factorName': fName,
                      'sourceCol': sourceCol,
                      'separator': delimiter,
                      'partIndex': selectedPartIdx,
                    });
                  } else {
                    Navigator.pop(ctx, {
                      'mode': 'folder',
                      'factorName': fName,
                      'sourceCol': sourceCol,
                      'folderLevel': folderLevel,
                    });
                  }
                },
                child: const Text('Add Factor'),
              ),
            ],
          );
        },
      ),
    );
    factorCtrl.dispose();
    if (result == null || !mounted) return;
    setState(() {
      final fName = '${result['factorName']}'.toLowerCase();
      _factorRules.removeWhere(
        (r) =>
            r['mode'] != 'manual_map' &&
            '${r['factorName'] ?? ''}'.toLowerCase() == fName,
      );
      _factorRules.add(result);
    });
    await _inspectCsv();
  }

  Future<void> _inspectCsv() async {
    final csvPath = _csvPathController.text.trim();
    if (csvPath.isEmpty || !File(csvPath).existsSync()) {
      _showSnack('Please select a valid CSV file first.');
      return;
    }

    setState(() {
      _isInspecting = true;
      _statusMessage = 'Loading measurements and factor sources…';
      _inspectionData = null;
      _dartInspection = null;
      _analysisResults = null;
      _dartAnalysisResults = null;
      _selectedMetrics.clear();
      _selectedSubjectIdCol = null;
    });

    try {
      final dartInsp = await inspectGroupDatasetInWorker(
        csvPath,
        _metadataPathController.text.trim(),
        _metadataKeyController.text.trim(),
        factorRules: _factorRules,
        externalSheets: _externalSheets,
      );
      if (!mounted) return;
      _applyDartInspection(dartInsp);
      setState(() {
        _statusMessage =
            'Ready: ${dartInsp['row_count']} rows · ${_inspectionData?['unique_subjects'] ?? 0} participants · ${_dartFactors.length} factor(s) active.';
      });
    } catch (e) {
      if (!mounted) return;
      _showSnack('Error inspecting file: $e');
      setState(() {
        _consoleLogs.add('$e');
        _statusMessage = 'Data could not be loaded: $e';
      });
    } finally {
      if (mounted)
        setState(() {
          _isInspecting = false;
        });
    }
  }

  void _applyDartInspection(Map<String, dynamic> insp) {
    final factorCols = (insp['factor_columns'] as List? ?? []).cast<String>();
    final metricCols = (insp['metric_columns'] as List? ?? []).cast<String>();
    final subjCol = insp['detected_subject_col'] as String?;
    final rawLevels = (insp['factor_levels'] as Map<String, dynamic>? ?? {});

    final nonSubjFactors = factorCols.where((f) {
      if (f == subjCol ||
          const {
            'subjid',
            'subject',
            'subject_id',
            'participant_id',
            'sl.no.',
            'sno',
            'index',
            'epoch',
            'epoch_label',
            'bin',
            'bin_idx',
          }.contains(f.toLowerCase()))
        return false;
      final fl = f.toLowerCase();
      if (const {
        'filename',
        'file',
        'source_file',
        'source_path',
        'path',
      }.contains(fl)) {
        return false;
      }
      final lvls = rawLevels[f] as List? ?? const [];
      return lvls.length >= 2;
    }).toList();

    final customRuleFactorNames = <String>{
      for (final r in _factorRules)
        if (r['mode'] != 'manual_map' &&
            '${r['factorName'] ?? ''}'.trim().isNotEmpty)
          '${r['factorName']}'.trim().toLowerCase(),
      for (final s in _externalSheets)
        for (final c in (s['selectedColumns'] as List? ?? const []))
          '$c'.trim().toLowerCase(),
    };

    setState(() {
      _dartInspection = insp;
      _dartFactors
        ..clear()
        ..addAll(
          nonSubjFactors.where((f) {
            final fl = f.toLowerCase();
            return const {
                  'group',
                  'cohort',
                  'arm',
                  'condition',
                  'session',
                  'sessn',
                }.contains(fl) ||
                customRuleFactorNames.contains(fl);
          }),
        );
      if (_dartFactors.isEmpty && nonSubjFactors.isNotEmpty) {
        _dartFactors.addAll(nonSubjFactors.take(4));
      }
      _dartExcludedLevels.clear();
      _dartLevelOrder.clear();
      _selectedContrastFactors.clear();
      _contrastScopeMode = 'both';
      _selectedContrastPairs.clear();
      _plotBracketFactorFilter = null;
      _posthocTableFactorFilter = null;
      _posthocTableSigOnly = false;
      _posthocTableScope = 'all';
      _erpDiffMode = false;
      _erpDiffPairs.clear();
      _erpDiffCondB = null;
      _erpDiffCondA = null;
      _selectedSubjectIdCol = subjCol;
      if (_selectedMetrics.isEmpty && metricCols.isNotEmpty) {
        _selectedMetrics.add(metricCols.first);
      }
      _inspectionData = {
        'total_rows': insp['row_count'],
        'unique_subjects':
            ((insp['factor_levels'] as Map?)?[subjCol] as List?)?.length ?? 0,
        'categorical_columns': nonSubjFactors,
        'subject_candidates': factorCols,
        'metric_columns': metricCols,
        'covariates': <String>[],
        'channel_count':
            ((insp['factor_levels'] as Map?)?['Chan'] as List?)?.length ?? 0,
        'recording_count':
            ((insp['factor_levels'] as Map?)?['filename'] as List?)?.length ??
            0,
      };

      // Smart default plot role assignment:
      // e.g. X: condition/electrode, Lines: group, Facet Col: condition/event
      String? pick(List<String> candidates) => nonSubjFactors
          .where((f) => candidates.any((c) => f.toLowerCase().contains(c)))
          .firstOrNull;
      final seriesF = pick(['group', 'arm']) ?? nonSubjFactors.firstOrNull;
      final xF =
          pick(['electrode', 'channel', 'roi', 'condition', 'session']) ??
          (nonSubjFactors.length > 1 ? nonSubjFactors[1] : seriesF);
      final colF = nonSubjFactors
          .where((f) => f != seriesF && f != xF)
          .firstOrNull;
      _plotConfig = StatsPlotLayoutConfig(
        xFactor: xF,
        seriesFactor: seriesF,
        facetColFactor: colF,
        plotType: StatsPlotType.line,
      );
    });
  }

  Future<void> _openGroupedFigures({bool difference = false}) async {
    final inspection = _dartInspection;
    if (inspection == null) return;
    final condCol = _detectConditionFactorCol(inspection);
    final activePairs = condCol == null
        ? const <({String condB, String condA})>[]
        : _effectiveErpDiffPairs(inspection, condCol);
    final csv = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => ErpGroupFigureStudio(
          inspection: inspection,
          csvPath: _csvPathController.text,
          config: _plotConfig,
          levelOrder: _dartLevelOrder,
          excludedLevels: _dartExcludedLevels,
          findPython: _findPythonExecutable,
          differenceOnly: difference,
          initialPlotDifferences: !difference && _erpDiffMode,
          initialDifferencePairs: [
            for (final p in activePairs) [p.condB, p.condA],
          ],
        ),
      ),
    );
    if (difference && csv != null && mounted) {
      _csvPathController.text = csv;
      await _inspectCsv();
      if (mounted)
        setState(() {
          _dartFactors.removeWhere(
            (f) =>
                ((_dartInspection?['factor_levels'] as Map?)?[f] as List? ?? [])
                    .length <
                2,
          );
          _workflowStep = 1;
        });
    }
  }

  void _assignPlotRole(String role, String? rawNext) {
    final next = (rawNext == null || rawNext == 'None') ? null : rawNext;
    var cfg = _plotConfig;
    final oldVal = switch (role) {
      'x' => cfg.xFactor,
      'series' => cfg.seriesFactor,
      'col' => cfg.facetColFactor,
      'row' => cfg.facetRowFactor,
      _ => null,
    };
    if (next != null) {
      if (role != 'x' && cfg.xFactor == next) {
        cfg = cfg.copyWith(xFactor: oldVal, clearX: oldVal == null);
      }
      if (role != 'series' && cfg.seriesFactor == next) {
        cfg = cfg.copyWith(seriesFactor: oldVal, clearSeries: oldVal == null);
      }
      if (role != 'col' && cfg.facetColFactor == next) {
        cfg = cfg.copyWith(
          facetColFactor: oldVal,
          clearFacetCol: oldVal == null,
        );
      }
      if (role != 'row' && cfg.facetRowFactor == next) {
        cfg = cfg.copyWith(
          facetRowFactor: oldVal,
          clearFacetRow: oldVal == null,
        );
      }
    }
    cfg = switch (role) {
      'x' => cfg.copyWith(xFactor: next, clearX: next == null),
      'series' => cfg.copyWith(seriesFactor: next, clearSeries: next == null),
      'col' => cfg.copyWith(facetColFactor: next, clearFacetCol: next == null),
      'row' => cfg.copyWith(facetRowFactor: next, clearFacetRow: next == null),
      _ => cfg,
    };
    setState(() => _plotConfig = cfg);
  }

  String? _findGroupFactor(List<String> factors) {
    for (final f in factors) {
      final fl = f.toLowerCase();
      if (fl == 'group' || fl.contains('cohort') || fl.contains('arm')) {
        return f;
      }
    }
    return factors.firstOrNull;
  }

  Set<String> _effectiveContrastFactors(List<String> availableFactors) {
    final valid = _selectedContrastFactors
        .where(availableFactors.contains)
        .toSet();
    return valid.isEmpty ? availableFactors.toSet() : valid;
  }

  String _describeContrastSelection(List<String> availableFactors) {
    final sel = _effectiveContrastFactors(availableFactors);
    final parts = <String>[];
    for (final f in availableFactors) {
      if (!sel.contains(f)) continue;
      final pairs = _selectedContrastPairs[f];
      if (pairs != null && pairs.isNotEmpty) {
        final pairLabels = pairs
            .map((k) {
              final sp = k.split('\u0000');
              return sp.length == 2
                  ? '${_plotConfig.levelLabel(f, sp[0])} vs ${_plotConfig.levelLabel(f, sp[1])}'
                  : k;
            })
            .take(3)
            .join(', ');
        final more = pairs.length > 3 ? ' +${pairs.length - 3}' : '';
        parts.add('${_plotConfig.factorLabel(f)} ($pairLabels$more)');
      } else {
        parts.add('${_plotConfig.factorLabel(f)} (all pairs)');
      }
    }
    final scopeText = switch (_contrastScopeMode) {
      'simple' => 'Simple effects only',
      'marginal' => 'Marginal only',
      _ => 'Simple + Marginal',
    };
    return '${parts.join(' · ')} · $scopeText';
  }

  void _applyContrastSelectionToResults(Map<String, dynamic>? res) {
    if (res == null) return;
    final resultsList = (res['results'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    for (final r in resultsList) {
      final allRaw = (r['all_posthoc'] as List? ?? r['posthoc'] as List? ?? [])
          .cast<Map<String, dynamic>>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      r['all_posthoc'] = allRaw;
      final factors = (r['factors'] as List? ?? []).cast<String>();
      final selFactors = _effectiveContrastFactors(factors);
      r['posthoc'] = ErpGroupStatsEngine.applyComparisonSelection(
        allPosthocs: allRaw,
        selectedFactors: selFactors,
        scope: _contrastScopeMode,
        selectedPairsByFactor: _selectedContrastPairs,
        posthocMethod: _posthocMethod,
      );
      r['posthoc_family'] = _describeContrastSelection(factors);
    }
  }

  Future<void> _openChoosePairsDialog(
    List<String> availableFactors,
    Map<String, List<String>> levelsByFactor, {
    required bool liveUpdate,
  }) async {
    final selFactors = _effectiveContrastFactors(availableFactors);
    final working = <String, Set<String>>{
      for (final f in availableFactors)
        if (_selectedContrastPairs[f]?.isNotEmpty ?? false)
          f: Set<String>.from(_selectedContrastPairs[f]!),
    };
    final applied = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          title: const Text('Choose specific pairwise comparisons'),
          content: SizedBox(
            width: 640,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Select specific level pairs to test (or click a "vs Level" button to compare one reference level against all others). Leaving all unchecked includes every pair for that factor.',
                    style: TextStyle(
                      fontSize: 12,
                      color: CcsTheme.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  for (final f in availableFactors)
                    if (selFactors.contains(f)) ...[
                      Builder(
                        builder: (_) {
                          final lvls = levelsByFactor[f] ?? const <String>[];
                          final allPairs = <(String, String)>[
                            for (var i = 0; i < lvls.length; i++)
                              for (var j = i + 1; j < lvls.length; j++)
                                (lvls[i], lvls[j]),
                          ];
                          final chosen = working[f] ?? <String>{};
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    Text(
                                      _plotConfig.factorLabel(f),
                                      style: const TextStyle(
                                        fontSize: 13.5,
                                        fontWeight: FontWeight.bold,
                                        color: CcsTheme.text,
                                      ),
                                    ),
                                    ActionChip(
                                      visualDensity: VisualDensity.compact,
                                      label: const Text(
                                        'All pairs',
                                        style: TextStyle(fontSize: 11),
                                      ),
                                      onPressed: () => setDlgState(
                                        () => working.remove(f),
                                      ),
                                    ),
                                    for (final ref in lvls)
                                      if (lvls.length >= 3)
                                        ActionChip(
                                          visualDensity: VisualDensity.compact,
                                          label: Text(
                                            'vs ${_plotConfig.levelLabel(f, ref)}',
                                            style: const TextStyle(fontSize: 11),
                                          ),
                                          onPressed: () => setDlgState(() {
                                            working[f] = {
                                              for (final other in lvls)
                                                if (other != ref)
                                                  ErpGroupStatsEngine.canonicalPairKey(
                                                    ref,
                                                    other,
                                                  ),
                                            };
                                          }),
                                        ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: [
                                    for (final (a, b) in allPairs)
                                      () {
                                        final key = ErpGroupStatsEngine
                                            .canonicalPairKey(a, b);
                                        final isSelected =
                                            chosen.isEmpty ||
                                            chosen.contains(key);
                                        return FilterChip(
                                          visualDensity: VisualDensity.compact,
                                          label: Text(
                                            '${_plotConfig.levelLabel(f, a)} vs ${_plotConfig.levelLabel(f, b)}',
                                            style: const TextStyle(fontSize: 11.5),
                                          ),
                                          selected: isSelected,
                                          onSelected: (sel) => setDlgState(() {
                                            final set = working.putIfAbsent(
                                              f,
                                              () => {
                                                for (final (x, y) in allPairs)
                                                  ErpGroupStatsEngine
                                                      .canonicalPairKey(x, y),
                                              },
                                            );
                                            if (sel) {
                                              set.add(key);
                                              if (set.length ==
                                                  allPairs.length) {
                                                working.remove(f);
                                              }
                                            } else {
                                              if (set.length > 1) {
                                                set.remove(key);
                                              }
                                            }
                                          }),
                                        );
                                      }(),
                                  ],
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Apply comparisons'),
            ),
          ],
        ),
      ),
    );
    if (applied != true || !mounted) return;
    setState(() {
      _selectedContrastPairs
        ..clear()
        ..addAll(working);
      if (liveUpdate) {
        _applyContrastSelectionToResults(_dartAnalysisResults);
      }
    });
  }

  Widget _buildComparisonSelector({
    required List<String> availableFactors,
    required Map<String, List<String>> levelsByFactor,
    required bool liveUpdate,
  }) {
    if (availableFactors.isEmpty) return const SizedBox.shrink();
    final selFactors = _effectiveContrastFactors(availableFactors);
    final customPairCount = _selectedContrastPairs.entries
        .where((e) => selFactors.contains(e.key) && e.value.isNotEmpty)
        .fold<int>(0, (sum, e) => sum + e.value.length);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 6,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text(
              'Comparisons:',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: CcsTheme.text,
              ),
            ),
            for (final f in availableFactors)
              FilterChip(
                visualDensity: VisualDensity.compact,
                label: Text(
                  _plotConfig.factorLabel(f),
                  style: const TextStyle(fontSize: 11),
                ),
                selected: selFactors.contains(f),
                onSelected: _isAnalyzing
                    ? null
                    : (sel) {
                        setState(() {
                          if (_selectedContrastFactors.isEmpty) {
                            _selectedContrastFactors.addAll(availableFactors);
                          }
                          if (sel) {
                            _selectedContrastFactors.add(f);
                          } else if (_selectedContrastFactors.length > 1) {
                            _selectedContrastFactors.remove(f);
                          }
                          final nextSel = _effectiveContrastFactors(
                            availableFactors,
                          );
                          if (nextSel.length == 1) {
                            _plotBracketFactorFilter = nextSel.first;
                            _posthocTableFactorFilter = nextSel.first;
                          } else {
                            _plotBracketFactorFilter = null;
                            _posthocTableFactorFilter = null;
                          }
                          if (liveUpdate) {
                            _applyContrastSelectionToResults(
                              _dartAnalysisResults,
                            );
                          }
                        });
                      },
              ),
            SegmentedButton<String>(
              showSelectedIcon: false,
              style: SegmentedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                textStyle: const TextStyle(fontSize: 11),
              ),
              segments: const [
                ButtonSegment(value: 'simple', label: Text('Simple')),
                ButtonSegment(value: 'marginal', label: Text('Marginal')),
                ButtonSegment(value: 'both', label: Text('Both')),
              ],
              selected: {_contrastScopeMode},
              onSelectionChanged: _isAnalyzing
                  ? null
                  : (s) => setState(() {
                      _contrastScopeMode = s.first;
                      if (liveUpdate) {
                        _applyContrastSelectionToResults(_dartAnalysisResults);
                      }
                    }),
            ),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
              ),
              onPressed: _isAnalyzing
                  ? null
                  : () => _openChoosePairsDialog(
                      availableFactors,
                      levelsByFactor,
                      liveUpdate: liveUpdate,
                    ),
              icon: const Icon(Icons.tune, size: 14),
              label: Text(
                customPairCount > 0
                    ? 'Pairs ($customPairCount chosen)…'
                    : 'Choose pairs…',
                style: const TextStyle(fontSize: 11),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Active comparison family (${_posthocMethod.toUpperCase()}): ${_describeContrastSelection(availableFactors)}',
          style: const TextStyle(fontSize: 11, color: CcsTheme.textSecondary),
        ),
      ],
    );
  }

  Future<void> _applyCompareGroupsPreset({bool rerun = true}) async {
    final activeFactors = List<String>.from(_dartFactors);
    final groupF = _findGroupFactor(activeFactors);
    if (groupF == null) return;
    final others = activeFactors.where((f) => f != groupF).toList();
    final sessionF = others
        .where((f) => f.toLowerCase().contains('sess'))
        .firstOrNull;
    final condF = others
        .where((f) => f.toLowerCase().contains('cond'))
        .firstOrNull;
    final xF = sessionF ?? condF ?? others.firstOrNull;
    final colF = others.where((f) => f != xF).firstOrNull;
    final rowF = others.where((f) => f != xF && f != colF).firstOrNull;
    setState(() {
      _plotConfig = _plotConfig.copyWith(
        seriesFactor: groupF,
        xFactor: xF,
        clearX: xF == null,
        facetColFactor: colF,
        clearFacetCol: colF == null,
        facetRowFactor: rowF,
        clearFacetRow: rowF == null,
      );
      _selectedContrastFactors
        ..clear()
        ..add(groupF);
      _contrastScopeMode = 'simple';
      _plotBracketFactorFilter = groupF;
      _posthocTableFactorFilter = groupF;
      if (_dartAnalysisResults != null) {
        _applyContrastSelectionToResults(_dartAnalysisResults);
      }
    });
    if (rerun &&
        _dartAnalysisResults == null &&
        _dartInspection != null &&
        _selectedMetrics.isNotEmpty) {
      await _runDartPermutationAnalysis();
    }
  }

  Future<void> _toggleResultsDifferenceMode(bool enableDiff) async {
    final insp = _dartInspection;
    if (insp == null) return;
    final condCol = _detectConditionFactorCol(insp);
    if (condCol == null) return;
    final condLevels = _conditionLevelsForCol(insp, condCol);
    if (condLevels.length < 2) return;
    setState(() {
      _erpDiffMode = enableDiff;
      _selectedContrastPairs.remove(condCol);
      if (enableDiff) {
        if (_erpDiffPairs.isEmpty) {
          final base = condLevels.contains('Freq')
              ? 'Freq'
              : condLevels.first;
          for (final lvl in condLevels) {
            if (lvl != base) {
              _erpDiffPairs.add((condB: lvl, condA: base));
            }
          }
          if (_erpDiffPairs.isNotEmpty) {
            _erpDiffCondA = _erpDiffPairs.first.condA;
            _erpDiffCondB = _erpDiffPairs.first.condB;
          }
        }
        if (_erpDiffPairs.length >= 2 && !_dartFactors.contains(condCol)) {
          _dartFactors.add(condCol);
        } else if (_erpDiffPairs.length <= 1) {
          _dropCondFactorFromRoles(condCol);
        }
      } else {
        if (!_dartFactors.contains(condCol)) {
          _dartFactors.add(condCol);
        }
      }
    });
    await _runDartPermutationAnalysis();
  }

  Future<void> _exportPublicationStatsFigure(
    Map<String, dynamic> active,
    Map<String, List<String>> levelsMap,
    List<Map<String, dynamic>> posthocs,
  ) async {
    if (_isExportingStatsPlot) return;
    final metric = '${active['metric'] ?? 'erp_metric'}';
    final safeMetric = metric.replaceAll(RegExp(r'[^A-Za-z0-9_\-]+'), '_');
    final bundle = DefaultAssetBundle.of(context);
    final savePath = await FilePicker.saveFile(
      dialogTitle: 'Save publication-ready statistical figure (PNG, SVG, PDF)',
      fileName: '${safeMetric}_group_stats.png',
      type: FileType.custom,
      allowedExtensions: ['png'],
    );
    if (savePath == null || !mounted) return;
    setState(() => _isExportingStatsPlot = true);
    Directory? runtime;
    try {
      final python = await _findPythonExecutable();
      if (python == null) {
        throw StateError(
          'Python with numpy, pandas, scipy, statsmodels and matplotlib is required.',
        );
      }
      runtime = await Directory.systemTemp.createTemp('ccs-stats-pubfig-');
      for (final name in ['erp_group_figures.py', 'group_stats.py']) {
        await File(
          '${runtime.path}${Platform.pathSeparator}$name',
        ).writeAsString(await bundle.loadString('assets/$name'));
      }
      final outFile = File(savePath);
      final stem = savePath.replaceFirst(RegExp(r'\.(png|svg|pdf)$', caseSensitive: false), '');
      final rowLevels = _plotConfig.facetRowFactor == null
          ? const ['All']
          : (levelsMap[_plotConfig.facetRowFactor!] ?? const ['All']);
      final colLevels = _plotConfig.facetColFactor == null
          ? const ['All']
          : (levelsMap[_plotConfig.facetColFactor!] ?? const ['All']);
      final activeFactors = (active['factors'] as List? ?? []).cast<String>();
      final bracketsByPanel = <String, List<Map<String, dynamic>>>{};
      for (final r in rowLevels) {
        for (final c in colLevels) {
          final bList = statsPlotBrackets(
            config: _plotConfig,
            contrasts: posthocs,
            factors: activeFactors,
            levels: levelsMap,
            row: _plotConfig.facetRowFactor == null ? null : r,
            column: _plotConfig.facetColFactor == null ? null : c,
            bracketFactorFilter: _plotBracketFactorFilter,
          ).take(8).toList();
          bracketsByPanel['$r|$c'] = [
            for (final b in bList)
              {
                'x_a': b.xA,
                'x_b': b.xB,
                'series_a': b.seriesA,
                'series_b': b.seriesB,
                'label': b.label,
              },
          ];
        }
      }
      final payload = <String, dynamic>{
        'mode': 'stats_plot',
        'folder': outFile.parent.path,
        'output_dir': outFile.parent.path,
        'output_stem': stem,
        'dpi': 300,
        'font_size': 10,
        'stats_payload': {
          'metric_label': groupMetricLabel(metric),
          'model_summary':
              '${active['model_type']} · N=${active['n_obs']}, participants=${active['n_subjects']}',
          'contrast_summary':
              '${active['posthoc_family'] ?? 'Adjusted pairwise contrasts'} (${_posthocMethod.toUpperCase()})',
          'plot_type': _plotConfig.plotType.name,
          'use_sem': _plotConfig.useSem,
          'x_factor': _plotConfig.xFactor,
          'series_factor': _plotConfig.seriesFactor,
          'facet_col_factor': _plotConfig.facetColFactor,
          'facet_row_factor': _plotConfig.facetRowFactor,
          'factor_labels': _plotConfig.factorLabels,
          'level_labels': _plotConfig.levelLabels,
          'series_colors': _plotConfig.seriesColors,
          'factor_levels': levelsMap,
          'cell_descriptives': active['cell_descriptives'] ?? {},
          'brackets_by_panel': bracketsByPanel,
          'bracket_factor_filter': _plotBracketFactorFilter,
        },
      };
      final inFile = File('${runtime.path}${Platform.pathSeparator}input.json');
      final resFile = File('${runtime.path}${Platform.pathSeparator}result.json');
      await inFile.writeAsString(jsonEncode(payload));
      final proc = await Process.run(
        python,
        [
          '${runtime.path}${Platform.pathSeparator}erp_group_figures.py',
          inFile.path,
          resFile.path,
        ],
        environment: {
          'MPLCONFIGDIR': '${runtime.path}${Platform.pathSeparator}mpl',
          'OPENBLAS_NUM_THREADS': '1',
        },
      );
      if (proc.exitCode != 0) {
        throw StateError('${proc.stderr}'.trim());
      }
      if (mounted) {
        _showSnack('Saved publication figure PNG, SVG & PDF at $stem.*');
      }
    } catch (e) {
      if (mounted) _showSnack('Export failed: $e');
    } finally {
      if (runtime != null) await runtime.delete(recursive: true);
      if (mounted) setState(() => _isExportingStatsPlot = false);
    }
  }

  Future<void> _exportFactorialResults() async {
    if (_dartAnalysisResults == null) return;
    final path = await FilePicker.saveFile(
      dialogTitle: 'Save fitted effects, contrasts & plot labels',
      fileName: 'erp_factorial_results.json',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (path == null) return;
    final value = {
      ..._dartAnalysisResults!,
      'display_labels': {
        'factors': _plotConfig.factorLabels,
        'levels': _plotConfig.levelLabels,
        'series_colors': _plotConfig.seriesColors,
      },
      'level_order': _dartLevelOrder,
    };
    await File(
      path,
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(value));
    final contrasts = StringBuffer(
      'metric,factor,stratum,group_a,group_b,mean_diff,t_stat,p_raw,p_adj,test\n',
    );
    String cell(Object? v) => '"${'$v'.replaceAll('"', '""')}"';
    for (final r in value['results'] as List)
      for (final c in r['posthoc'] as List) {
        contrasts.writeln(
          [
            r['metric'],
            c['factor'],
            jsonEncode(c['stratum'] ?? {}),
            c['group_a'],
            c['group_b'],
            c['mean_diff'],
            c['t_stat'],
            c['p_raw'],
            c['p_adj'],
            c['test'],
          ].map(cell).join(','),
        );
      }
    await File('$path.contrasts.csv').writeAsString('$contrasts');
    if (mounted)
      _showSnack('Saved results, labels and corrected contrast CSV.');
  }

  Future<Map<String, dynamic>> _fitFactorialModel(
    Map<String, dynamic> payload,
  ) async {
    final engine = ExtractionService.findEngine();
    final runtime = await _runtimeDirectory;
    final sep = Platform.pathSeparator;
    final input = File('${runtime.path}${sep}factorial_input.json');
    final output = File('${runtime.path}${sep}factorial_output.json');
    if (await output.exists()) {
      await output.delete();
    }
    final enginePayload = <String, dynamic>{
      ...payload,
      'job_type': 'factorial_lmm',
      'output_path': output.path,
    };
    await input.writeAsString(jsonEncode(enginePayload));
    final process = await Process.run(engine, [input.path]);
    if (process.exitCode != 0) {
      final errText = '${process.stderr}'.trim().isNotEmpty
          ? '${process.stderr}'.trim()
          : '${process.stdout}'.trim();
      throw StateError(errText.isEmpty ? 'Native GLM/LMM engine failed.' : errText);
    }
    return Map<String, dynamic>.from(
      jsonDecode(await output.readAsString()) as Map,
    );
  }

  Future<void> _editPlotLabels() async {
    final raw = Map<String, dynamic>.from(
      _dartInspection?['factor_levels'] as Map? ?? {},
    );
    final factors = Map<String, String>.from(_plotConfig.factorLabels);
    final levels = {
      for (final e in _plotConfig.levelLabels.entries)
        e.key: Map<String, String>.from(e.value),
    };
    final colors = Map<String, int>.from(_plotConfig.seriesColors);
    final apply = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Factor labels, level labels & colours'),
        content: SizedBox(
          width: 650,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Display labels leave source codes and statistical identities unchanged. Example: Session 03 → Baseline.',
                ),
                for (final factor in raw.keys.where(_dartFactors.contains)) ...[
                  TextFormField(
                    initialValue: factors[factor] ?? factor,
                    decoration: InputDecoration(labelText: 'Factor: $factor'),
                    onChanged: (v) => factors[factor] = v.isEmpty ? factor : v,
                  ),
                  for (final value in (raw[factor] as List).map((v) => '$v'))
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            initialValue: levels[factor]?[value] ?? value,
                            decoration: InputDecoration(
                              labelText: '$factor · $value',
                            ),
                            onChanged: (v) =>
                                levels.putIfAbsent(factor, () => {})[value] =
                                    v.isEmpty ? value : v,
                          ),
                        ),
                        if (factor == _plotConfig.seriesFactor)
                          SizedBox(
                            width: 125,
                            child: TextFormField(
                              initialValue: colors[value] == null
                                  ? ''
                                  : (colors[value]! & 0xffffff)
                                        .toRadixString(16)
                                        .padLeft(6, '0'),
                              decoration: const InputDecoration(
                                labelText: 'Colour RRGGBB',
                              ),
                              onChanged: (v) {
                                final c = int.tryParse(
                                  v.replaceFirst('#', ''),
                                  radix: 16,
                                );
                                if (c != null &&
                                    v.replaceFirst('#', '').length == 6)
                                  colors[value] = 0xff000000 | c;
                              },
                            ),
                          ),
                      ],
                    ),
                  const Divider(),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Apply labels & colours'),
          ),
        ],
      ),
    );
    if (apply == true && mounted)
      setState(
        () => _plotConfig = _plotConfig.copyWith(
          factorLabels: factors,
          levelLabels: levels,
          seriesColors: colors,
        ),
      );
  }

  String? _detectConditionFactorCol(Map<String, dynamic>? insp) {
    if (insp == null) return null;
    final rawLevels = insp['factor_levels'] as Map? ?? const {};
    final candidates = [
      for (final c in const ['Condition', 'condition', 'epoch_label'])
        if (rawLevels.containsKey(c)) c,
    ];
    if (candidates.isEmpty) return null;
    for (final c in candidates) {
      if (_dartFactors.contains(c)) return c;
    }
    return candidates.first;
  }

  List<String> _conditionLevelsForCol(
    Map<String, dynamic>? insp,
    String condCol,
  ) {
    final rawLevels = insp?['factor_levels'] as Map? ?? const {};
    final excl = _dartExcludedLevels[condCol] ?? const <String>{};
    return [
      for (final v in (rawLevels[condCol] as List? ?? const []))
        if ('$v'.isNotEmpty && !excl.contains('$v')) '$v',
    ];
  }

  List<({String condB, String condA})> _effectiveErpDiffPairs(
    Map<String, dynamic>? insp,
    String condCol,
  ) {
    final rawLevels =
        (insp?['factor_levels'] as Map? ?? const {})[condCol] as List? ??
        const [];
    final available = {for (final v in rawLevels) '$v'};
    final valid = <({String condB, String condA})>[];
    final seen = <String>{};
    for (final p in _erpDiffPairs) {
      if (p.condB != p.condA &&
          available.contains(p.condB) &&
          available.contains(p.condA)) {
        final key = '${p.condB} − ${p.condA}';
        if (seen.add(key)) valid.add(p);
      }
    }
    if (valid.isNotEmpty) return valid;
    final condLevels = _conditionLevelsForCol(insp, condCol);
    if (condLevels.length < 2) return const [];
    final cA = (_erpDiffCondA != null && condLevels.contains(_erpDiffCondA))
        ? _erpDiffCondA!
        : (condLevels.contains('Freq') ? 'Freq' : condLevels.first);
    final cB =
        (_erpDiffCondB != null &&
            condLevels.contains(_erpDiffCondB) &&
            _erpDiffCondB != cA)
        ? _erpDiffCondB!
        : (condLevels.contains('Rare') && 'Rare' != cA
              ? 'Rare'
              : condLevels.firstWhere((c) => c != cA));
    return [(condB: cB, condA: cA)];
  }

  List<String> _activeErpDiffLabels(
    Map<String, dynamic>? insp,
    String? condCol,
  ) {
    if (!_erpDiffMode || condCol == null) return const [];
    return [
      for (final p in _effectiveErpDiffPairs(insp, condCol))
        '${p.condB} − ${p.condA}',
    ];
  }

  void _dropCondFactorFromRoles(String condCol) {
    final remaining = _dartFactors.where((f) => f != condCol).toList();
    if (!_dartFactors.contains(condCol) || remaining.isEmpty) return;
    _dartFactors
      ..clear()
      ..addAll(remaining);
    var cfg = _plotConfig;
    if (cfg.xFactor == condCol) {
      final nextX =
          remaining.where((f) => f != cfg.seriesFactor).firstOrNull ??
          remaining.firstOrNull;
      cfg = cfg.copyWith(xFactor: nextX, clearX: nextX == null);
    }
    if (cfg.seriesFactor == condCol) {
      final nextS = remaining.where((f) => f != cfg.xFactor).firstOrNull;
      cfg = cfg.copyWith(seriesFactor: nextS, clearSeries: nextS == null);
    }
    if (cfg.facetColFactor == condCol) {
      cfg = cfg.copyWith(clearFacetCol: true);
    }
    if (cfg.facetRowFactor == condCol) {
      cfg = cfg.copyWith(clearFacetRow: true);
    }
    _plotConfig = cfg;
  }

  Future<void> _runDartPermutationAnalysis() async {
    final insp = _dartInspection;
    if (!_groupsReady) {
      _showSnack('Review missing group labels in Data & groups first.');
      return;
    }
    if (insp == null) {
      _showSnack('Inspect a CSV dataset first.');
      return;
    }
    if (_dartFactors.isEmpty) {
      _showSnack('Select at least one statistical factor.');
      return;
    }
    if (_selectedMetrics.isEmpty) {
      _showSnack('Select at least one metric to analyze.');
      return;
    }
    setState(() {
      _isAnalyzing = true;
      _progressStatus = _fittedFactorial
          ? 'Fitting GLM / LMM…'
          : 'Running factorial permutations…';
      _statusMessage = _fittedFactorial
          ? 'Fitting models and corrected contrasts natively…'
          : 'Running N-way factorial permutations in isolate…';
    });
    try {
      var headers = List<String>.from((insp['headers'] as List).cast<String>());
      var rows = (insp['rows'] as List)
          .map((r) => (r as List).map((e) => '$e').toList())
          .toList();
      var factors = List<String>.from(_dartFactors);
      var metrics = _selectedMetrics.toList();
      final subjCol = _selectedSubjectIdCol;
      final modelPref = _preferredModel;
      final posthoc = _posthocMethod;
      final interactions = _includeInteractions;
      final nPerm = int.tryParse(_permCountCtrl.text.trim()) ?? 1000;
      final excluded = <String, List<String>>{
        for (final e in _dartExcludedLevels.entries)
          if (e.value.isNotEmpty) e.key: List<String>.from(e.value),
      };
      final order = <String, List<String>>{
        for (final e in _dartLevelOrder.entries)
          e.key: List<String>.from(e.value),
      };

      final condCol = _detectConditionFactorCol(insp);
      if (_erpDiffMode && condCol != null) {
        final pairs = _effectiveErpDiffPairs(insp, condCol);
        final diffRes = ErpGroupStatsEngine.buildErpDifferenceDataset(
          headers: headers,
          rows: rows,
          condCol: condCol,
          pairs: pairs,
          factors: factors,
          metrics: metrics,
          subjectCol: subjCol,
          excludedLevels: excluded,
        );
        if (diffRes.containsKey('error')) {
          _showSnack('${diffRes['error']}');
          return;
        }
        headers = (diffRes['headers'] as List).cast<String>();
        rows = (diffRes['rows'] as List)
            .map((r) => (r as List).map((e) => '$e').toList())
            .toList();
        factors = (diffRes['factors'] as List).cast<String>();
        metrics = (diffRes['metrics'] as List).cast<String>();
        final diffLabels = (diffRes['diff_labels'] as List).cast<String>();
        if (factors.contains(condCol)) {
          final validDiffSet = diffLabels.toSet();
          final condExcl = excluded[condCol];
          if (condExcl != null) {
            condExcl.retainWhere(validDiffSet.contains);
            if (condExcl.isEmpty) excluded.remove(condCol);
          }
          final existingOrder = _dartLevelOrder[condCol];
          order[condCol] = existingOrder != null && existingOrder.isNotEmpty
              ? [
                  for (final l in existingOrder)
                    if (validDiffSet.contains(l)) l,
                  for (final l in diffLabels)
                    if (!existingOrder.contains(l)) l,
                ]
              : diffLabels;
        } else {
          excluded.remove(condCol);
          order.remove(condCol);
        }
      }

      var cfg = _plotConfig;
      if (cfg.xFactor != null && !factors.contains(cfg.xFactor)) {
        final nextX =
            factors.where((f) => f != cfg.seriesFactor).firstOrNull ??
            factors.firstOrNull;
        cfg = cfg.copyWith(xFactor: nextX, clearX: nextX == null);
      }
      if (cfg.seriesFactor != null && !factors.contains(cfg.seriesFactor)) {
        final nextS = factors.where((f) => f != cfg.xFactor).firstOrNull;
        cfg = cfg.copyWith(seriesFactor: nextS, clearSeries: nextS == null);
      }
      if (cfg.facetColFactor != null && !factors.contains(cfg.facetColFactor)) {
        cfg = cfg.copyWith(clearFacetCol: true);
      }
      if (cfg.facetRowFactor != null && !factors.contains(cfg.facetRowFactor)) {
        cfg = cfg.copyWith(clearFacetRow: true);
      }
      _plotConfig = cfg;

      final payload = <String, dynamic>{
        'headers': headers,
        'rows': rows,
        'factors': factors,
        'metrics': metrics,
        'subjectCol': subjCol,
        'preferredModel': modelPref,
        'posthocMethod': posthoc,
        'includeInteractions': interactions,
        'nPermutations': nPerm,
        'excludedLevels': excluded,
        'customLevelOrder': order,
        'contrastFactors': <String>[],
      };

      final res = _fittedFactorial
          ? await _fitFactorialModel(payload)
          : await runDartPermutationsInWorker(payload);
      res['display_labels'] = {
        'factors': _plotConfig.factorLabels,
        'levels': _plotConfig.levelLabels,
        'series_colors': _plotConfig.seriesColors,
      };
      if (!mounted) return;
      if (res.containsKey('error')) {
        _showSnack('${res['error']}');
        return;
      }
      _applyContrastSelectionToResults(res);
      final resultsList = (res['results'] as List? ?? [])
          .cast<Map<String, dynamic>>();
      setState(() {
        _dartAnalysisResults = res;
        _workflowStep = 2;
        _selectedDartMetric = resultsList.isNotEmpty
            ? resultsList.first['metric'] as String?
            : null;
        _dartResultTab = 0;
        _statusMessage =
            '${_fittedFactorial ? 'Fitted GLM/LMM' : 'Factorial permutation'} complete (${resultsList.length} metric(s)).';
      });
    } catch (e) {
      _showSnack('Analysis failed: $e');
    } finally {
      if (mounted) setState(() => _isAnalyzing = false);
    }
  }

  Future<void> _openPath(String path) async {
    try {
      if (Platform.isMacOS) {
        await Process.run('open', [path]);
      } else if (Platform.isWindows) {
        await Process.run('explorer.exe', [path]);
      } else {
        await Process.run('xdg-open', [path]);
      }
    } catch (e) {
      _showSnack('Unable to open path: $e');
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: buildCcsLightTheme(),
      child: Container(
        color: CcsTheme.panel,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeaderCard(),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  for (var step = 0; step < 3; step++)
                    ChoiceChip(
                      label: Text(
                        const [
                          '1. Data & groups',
                          '2. Design & run',
                          '3. Results',
                        ][step],
                      ),
                      selected: _workflowStep == step,
                      onSelected:
                          _isInspecting ||
                              _isAnalyzing ||
                              (step > 0 && _inspectionData == null)
                          ? null
                          : (_) => setState(() => _workflowStep = step),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              if (_workflowStep == 0) ...[
                _buildDataSourceCard(),
                if (_dartInspection != null) _buildDataReview(),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    onPressed: _inspectionData == null || _isInspecting
                        ? null
                        : () => setState(() => _workflowStep = 1),
                    icon: const Icon(Icons.arrow_forward),
                    label: const Text('Continue to analysis design'),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              if (_inspectionData != null && _workflowStep == 1) ...[
                if (!_groupsReady)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      'Some participants have no group label. Return to 1. Data & groups to assign or exclude them before running.',
                    ),
                  ),
                _buildMetricsSelectionCard(),
                const SizedBox(height: 12),
                if (_dartInspection != null) ...[
                  _buildConfigurablePlotAndPreviewCard(),
                  const SizedBox(height: 12),
                ],
                if (_selectedMetrics.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 6),
                    child: Text(
                      'Select at least one measurement above to enable Run.',
                      style: TextStyle(color: CcsTheme.textSecondary),
                    ),
                  ),
                _buildActionRunCard(),
                const SizedBox(height: 12),
              ],
              if (_workflowStep == 2 &&
                  _dartAnalysisResults == null &&
                  _analysisResults == null)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'No results yet. Go to Design & run to choose a comparison and run the analysis.',
                  ),
                ),
              if (_workflowStep == 2 && _dartAnalysisResults != null) ...[
                _buildDartResultsCard(),
                const SizedBox(height: 12),
              ],
              if (_workflowStep == 2 && _analysisResults != null) ...[
                _buildResultsCard(),
                const SizedBox(height: 12),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDataReview() {
    final insp = _dartInspection!;
    final levels = (insp['factor_levels'] as Map).cast<String, dynamic>();
    final sources = (insp['column_sources'] as Map? ?? {});
    final headers = (insp['headers'] as List).cast<String>();
    final rows = (insp['rows'] as List).cast<List>();
    final factorCols = (insp['factor_columns'] as List? ?? []).cast<String>();
    final participant = _selectedSubjectIdCol;
    final group = _participantGroupColumn;
    final subjectIndex = headers.indexOf(participant ?? '');
    final groupIndex = headers.indexOf(group ?? '');
    final participantsByGroup = <String, Set<String>>{};
    if (subjectIndex >= 0 && groupIndex >= 0) {
      for (final row in rows) {
        final label = '${row[groupIndex]}'.trim();
        participantsByGroup
            .putIfAbsent(label.isEmpty ? 'Unassigned' : label, () => {})
            .add('${row[subjectIndex]}');
      }
    }

    const skipReviewCols = {
      'filename',
      'file',
      'source_file',
      'source_path',
      'path',
      'sl.no.',
      'sl.no',
      'sno',
      'index',
    };
    final reviewFactors = <String>[
      ?participant,
      for (final f in factorCols)
        if (f != participant &&
            !skipReviewCols.contains(f.toLowerCase()) &&
            !const {'subjid', 'subject', 'subject_id', 'participant_id'}
                .contains(f.toLowerCase()) &&
            ((levels[f] as List? ?? const []).length >= 2 ||
                f.toLowerCase() == 'group'))
          f,
    ];
    final tablePreviewFactors = reviewFactors
        .where((f) => f != participant)
        .toList();

    String roleLabel(String f) {
      final fl = f.toLowerCase();
      if (f == participant) return '$f · Participant ID (Random Effect)';
      if (fl == 'group' || fl == 'cohort' || fl == 'arm') {
        return '$f · Participant Group';
      }
      if (fl == 'session' || fl == 'sessn') return '$f · Session / Visit';
      if (fl == 'condition' || fl == 'epoch_condition') {
        return '$f · Condition';
      }
      return f;
    }

    String value(List row, String? col) {
      final i = headers.indexOf(col ?? '');
      return i >= 0 && i < row.length ? '${row[i]}' : '—';
    }

    return Card(
      color: const Color(0xFFFFFFFF),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFFCBD5E1)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'What the app found — and where it came from',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              '${(levels[participant] as List? ?? []).length} participants · ${insp['row_count']} measurement rows · ${tablePreviewFactors.length} active factor(s).',
            ),
            const SizedBox(height: 12),
            for (final f in reviewFactors)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      roleLabel(f),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      'Values (${(levels[f] as List? ?? []).length}): ${(levels[f] as List? ?? []).take(8).join(", ")}${(levels[f] as List? ?? []).length > 8 ? " …" : ""}',
                    ),
                    Text(
                      'Source: ${sources[f] ?? "Measurement table · $f"}',
                      style: const TextStyle(fontSize: 12, color: Color(0xFF475569)),
                    ),
                  ],
                ),
              ),
            if (group == null) ...[
              const Text(
                'No participant cohort/group sheet attached yet (optional if comparing within-subject factors like Session or Condition).',
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _pickMetadataFile,
                    icon: const Icon(Icons.table_chart_outlined),
                    label: const Text('+ Attach Excel / CSV Sheet…'),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _workflowStep = 1),
                    child: const Text(
                      'Continue with current factors',
                    ),
                  ),
                ],
              ),
            ] else
              Text(
                'Participants per group: ${participantsByGroup.entries.map((e) => "${e.key}: ${e.value.length}").join(" · ")}',
              ),
            if (_unassignedGroupLabels.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                'No group label for: ${participantsByGroup.entries.where((e) => _unassignedGroupLabels.contains(e.key)).expand((e) => e.value).join(", ")}. Add these people to your sheet or exclude them.',
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'Exclude participants without group labels from this analysis',
                ),
                value: _groupsReady,
                onChanged: (v) => _setExcludeUnassigned(v ?? false),
              ),
            ],
            ExpansionTile(
              initiallyExpanded: true,
              title: Text(
                'Preview: Recording → ${[?participant, ...tablePreviewFactors].join(" → ")}',
              ),
              children: [
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    columns: [
                      const DataColumn(label: Text('Recording')),
                      if (participant != null)
                        DataColumn(label: Text(participant)),
                      for (final f in tablePreviewFactors)
                        DataColumn(label: Text(f)),
                    ],
                    rows: [
                      for (final row in rows.take(12))
                        DataRow(
                          cells: [
                            DataCell(
                              Tooltip(
                                message: value(row, 'filename'),
                                child: Text(
                                  filenameBasename(value(row, 'filename')),
                                ),
                              ),
                            ),
                            if (participant != null)
                              DataCell(Text(value(row, participant))),
                            for (final f in tablePreviewFactors)
                              DataCell(Text(value(row, f))),
                          ],
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeaderCard() {
    return Card(
      elevation: 0,
      color: const Color(0xFFFFFFFF),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: const Color(0xFFCBD5E1)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: const Color(0xFF38BDF8).withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(
                Icons.analytics_outlined,
                color: Color(0xFF38BDF8),
                size: 26,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Group analysis · choose data, define groups, run',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF38BDF8),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '1. Check recordings, participants and group labels. 2. Choose your comparison and measurements, then run. 3. Read results and open saved reports.',
                    style: TextStyle(fontSize: 12, color: Color(0xFF475569)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDataSourceCard() {
    return Card(
      elevation: 0,
      color: const Color(0xFFFFFFFF),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: const Color(0xFFCBD5E1)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.table_chart_outlined,
                  size: 20,
                  color: Color(0xFF38BDF8),
                ),
                const SizedBox(width: 8),
                const Text(
                  'Measurements and participant groups',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
                const Spacer(),
                if (_inspectionData != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.green.shade50,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.green.shade200),
                    ),
                    child: Text(
                      '${_inspectionData!['recording_count'] ?? _inspectionData!['total_rows']} recordings · ${_inspectionData!['unique_subjects']} participants',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.green.shade800,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _isInspecting || _isAnalyzing
                      ? null
                      : _pickCsvFile,
                  icon: const Icon(Icons.file_open),
                  label: const Text('Choose feature files'),
                ),
                OutlinedButton.icon(
                  onPressed: _isInspecting || _isAnalyzing
                      ? null
                      : _pickFeatureFolder,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Load results folder'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            const Text(
              'Choose a saved analysis folder or a measurement CSV. For ERP statistics, the measurement table is enough; waveform files do not need to be loaded. Add a group file with one row per participant when group labels are missing.',
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _csvPathController,
                    enabled: !_isInspecting && !_isAnalyzing,
                    onChanged: (_) => _invalidateInspection(),
                    decoration: InputDecoration(
                      labelText: 'Measurement table (CSV)',
                      hintText:
                          'Select master sheet CSV (e.g., Batch_features.csv)',
                      border: const OutlineInputBorder(),
                      isDense: true,
                      prefixIcon: const Icon(Icons.file_present_outlined),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.folder_open),
                        onPressed: _pickCsvFile,
                        tooltip: 'Browse CSV',
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _isInspecting ? null : _inspectCsv,
                  icon: _isInspecting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Color(0xFF1E293B),
                          ),
                        )
                      : const Icon(Icons.sync, size: 18),
                  label: Text(_isInspecting ? 'Loading…' : 'Review data'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF1F4E79),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Divider(),
            const SizedBox(height: 8),
            const Text(
              'Define Factors (Combine Any Sources — Filename, Folder, Excel/CSV Sheets)',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            const SizedBox(height: 4),
            const Text(
              'Combine any number of factor sources without overwriting each other: crop factors from filenames (e.g. Session), extract from folder hierarchy, or attach one or more Excel/CSV sheets (e.g. Groups.xlsx).',
              style: TextStyle(fontSize: 11.5, color: Color(0xFF475569)),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _isAnalyzing || _isInspecting || _dartInspection == null
                      ? null
                      : _openFactorDesignerInGroupStats,
                  icon: const Icon(Icons.account_tree_outlined, size: 16),
                  label: const Text('Factor & Grouping Designer…'),
                ),
                FilledButton.tonalIcon(
                  onPressed: _isAnalyzing || _isInspecting || _dartInspection == null
                      ? null
                      : _openAddFilenameFactorDialog,
                  icon: const Icon(Icons.content_cut, size: 16),
                  label: const Text('+ Factor from Filename / Folder'),
                ),
                FilledButton.tonalIcon(
                  onPressed: _isAnalyzing || _isInspecting
                      ? null
                      : _pickMetadataFile,
                  icon: const Icon(Icons.table_chart_outlined, size: 16),
                  label: const Text('+ Attach Excel / CSV Sheet'),
                ),
              ],
            ),
            if (_factorRules.isNotEmpty || _externalSheets.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (var i = 0; i < _factorRules.length; i++)
                    InputChip(
                      avatar: const Icon(Icons.label_outline, size: 15),
                      label: Text(
                        _factorRules[i]['mode'] == 'manual_map'
                            ? '${_factorRules[i]['label']}'
                            : '${_factorRules[i]['factorName']} (${_factorRules[i]['mode']})',
                        style: const TextStyle(fontSize: 11.5),
                      ),
                      onDeleted: _isInspecting || _isAnalyzing
                          ? null
                          : () async {
                              setState(() => _factorRules.removeAt(i));
                              if (File(_csvPathController.text.trim()).existsSync()) {
                                await _inspectCsv();
                              }
                            },
                    ),
                  for (var i = 0; i < _externalSheets.length; i++)
                    InputChip(
                      avatar: const Icon(Icons.grid_on, size: 15),
                      label: Text(
                        'Sheet: ${filenameBasename("${_externalSheets[i]['path']}")}'
                        '${(_externalSheets[i]['selectedColumns'] as List?)?.isNotEmpty == true ? " (${(_externalSheets[i]['selectedColumns'] as List).join(', ')})" : ""}',
                        style: const TextStyle(fontSize: 11.5),
                      ),
                      onDeleted: _isInspecting || _isAnalyzing
                          ? null
                          : () async {
                              setState(() {
                                _externalSheets.removeAt(i);
                                if (_externalSheets.isEmpty) {
                                  _metadataPathController.clear();
                                }
                              });
                              if (File(_csvPathController.text.trim()).existsSync()) {
                                await _inspectCsv();
                              }
                            },
                    ),
                ],
              ),
            ],
            if (_dartInspection != null) ...[
              const SizedBox(height: 12),
              Builder(
                builder: (context) {
                  final candidateSubj =
                      (_dartInspection!['factor_columns'] as List? ?? [])
                          .cast<String>();
                  final curSubj = candidateSubj.contains(_selectedSubjectIdCol)
                      ? _selectedSubjectIdCol
                      : candidateSubj.firstOrNull;
                  return SizedBox(
                    width: 340,
                    child: DropdownButtonFormField<String>(
                      initialValue: curSubj,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Participant ID (Random Effect / Person)',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: [
                        for (final c in candidateSubj)
                          DropdownMenuItem(value: c, child: Text(c)),
                      ],
                      onChanged: (v) =>
                          setState(() => _selectedSubjectIdCol = v),
                    ),
                  );
                },
              ),
            ],
            if ((_inspectionData?['excluded_unqualified_fei'] as num? ?? 0) > 0)
              Text(
                '${_inspectionData!['excluded_unqualified_fei']} stored fE:I values lacked qualifying DFA and were excluded. Re-extract old short-window files for corrected/context-aware estimates.',
                style: const TextStyle(color: Color(0xFF9A3412)),
              ),
            if (_statusMessage.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                _statusMessage,
                style: TextStyle(
                  fontSize: 12,
                  color: Color(0xFF475569),
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMetricsSelectionCard() {
    final catMap =
        (_inspectionData?['categorized_metrics'] as Map<String, dynamic>? ?? {})
            .map((k, v) => MapEntry(k, (v as List<dynamic>).cast<String>()));

    return Card(
      elevation: 0,
      color: const Color(0xFFFFFFFF),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: const Color(0xFFCBD5E1)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.check_box_outlined,
                  size: 20,
                  color: Color(0xFF38BDF8),
                ),
                const SizedBox(width: 8),
                Text(
                  'Measurements to analyse (${_selectedMetrics.length} selected)',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () {
                    setState(() {
                      _selectedMetrics.clear();
                    });
                  },
                  child: const Text('Clear All'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final entry in catMap.entries)
                  ActionChip(
                    avatar: Icon(
                      entry.value.every((m) => _selectedMetrics.contains(m))
                          ? Icons.check_circle
                          : Icons.add_circle_outline,
                      size: 16,
                      color: const Color(0xFF38BDF8),
                    ),
                    label: Text('${entry.key} (${entry.value.length})'),
                    onPressed: () {
                      setState(() {
                        final allSelected = entry.value.every(
                          (m) => _selectedMetrics.contains(m),
                        );
                        if (allSelected) {
                          _selectedMetrics.removeAll(entry.value);
                        } else {
                          _selectedMetrics.addAll(entry.value);
                        }
                      });
                    },
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              height: 150,
              decoration: BoxDecoration(
                border: Border.all(color: const Color(0xFF334155)),
                borderRadius: BorderRadius.circular(8),
                color: const Color(0xFFF8F9FB),
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(8),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final m
                        in (_inspectionData?['metric_columns']
                                    as List<dynamic>? ??
                                [])
                            .cast<String>())
                      FilterChip(
                        label: Text(
                          groupMetricLabel(m),
                          style: const TextStyle(fontSize: 11),
                        ),
                        selected: _selectedMetrics.contains(m),
                        onSelected: (sel) {
                          setState(() {
                            if (sel) {
                              _selectedMetrics.add(m);
                            } else {
                              _selectedMetrics.remove(m);
                            }
                          });
                        },
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConfigurablePlotAndPreviewCard() {
    final insp = _dartInspection!;
    final allFactorCols = (insp['factor_columns'] as List? ?? [])
        .cast<String>()
        .where((f) {
          if (const {
            'filename',
            'file',
            'path',
            'subjid',
            'subject',
            'subject_id',
            'participant_id',
            'sl.no.',
            'epoch',
            'epoch_label',
          }.contains(f.toLowerCase()))
            return false;
          return ((insp['factor_levels'] as Map)[f] as List? ?? []).length >= 2;
        })
        .toList();
    final rawLevels = (insp['factor_levels'] as Map<String, dynamic>? ?? {});
    final condCol = _detectConditionFactorCol(insp);
    final activeDiffLabels = _activeErpDiffLabels(insp, condCol);
    List<String> displayedRawLevels(String f) {
      if (_erpDiffMode &&
          condCol != null &&
          f == condCol &&
          activeDiffLabels.length >= 2) {
        return activeDiffLabels;
      }
      return (rawLevels[f] as List? ?? []).map((e) => '$e').toList();
    }

    final effectiveLevelsMap = <String, List<String>>{};
    for (final f in _dartFactors) {
      final raw = displayedRawLevels(f);
      final custom = _dartLevelOrder[f];
      final ordered = custom != null && custom.isNotEmpty
          ? [
              for (final l in custom)
                if (raw.contains(l)) l,
              for (final l in raw)
                if (!custom.contains(l)) l,
            ]
          : raw;
      final excl = _dartExcludedLevels[f] ?? const <String>{};
      effectiveLevelsMap[f] = ordered.where((l) => !excl.contains(l)).toList();
    }

    final factorChoices = ['None', ..._dartFactors];

    Widget roleDropdown(
      String label,
      String? value,
      ValueChanged<String?> onChanged,
    ) {
      final cur = (value != null && factorChoices.contains(value))
          ? value
          : 'None';
      return Expanded(
        child: DropdownButtonFormField<String>(
          key: ValueKey('role-$label-$cur'),
          initialValue: cur,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          items: [
            for (final f in factorChoices)
              DropdownMenuItem(
                value: f,
                child: Text(
                  _plotConfig.factorLabel(f),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: onChanged,
        ),
      );
    }

    return Card(
      elevation: 0,
      color: const Color(0xFFFFFFFF),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: const Color(0xFFCBD5E1)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.tune, size: 20, color: Color(0xFF0D9488)),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Statistical Model & Factors',
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1E293B),
                    ),
                  ),
                ),
                FilterChip(
                  label: const Text(
                    'Include interactions',
                    style: TextStyle(fontSize: 11.5),
                  ),
                  selected: _includeInteractions,
                  onSelected: (v) => setState(() => _includeInteractions = v),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: _isAnalyzing ? null : _editPlotLabels,
                  icon: const Icon(Icons.edit, size: 15),
                  label: const Text('Rename labels & colours…'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              _fittedFactorial
                  ? 'Uses Linear Mixed Model (with subject random intercepts for repeated measures) or General Linear Model across the selected factors.'
                  : 'Runs permutation testing (${_permCountCtrl.text} permutations) across the selected factors.',
              style: const TextStyle(fontSize: 11.5, color: Color(0xFF475569)),
            ),
            const SizedBox(height: 10),
            const Text(
              'Select factors to include in the model:',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final f in allFactorCols)
                  if (f != _selectedSubjectIdCol)
                    FilterChip(
                      label: Text(
                        '${_plotConfig.factorLabel(f)}: ${displayedRawLevels(f).take(4).map((v) => _plotConfig.levelLabel(f, v)).join(", ")}',
                        style: const TextStyle(fontSize: 11.5),
                      ),
                      selected: _dartFactors.contains(f),
                      onSelected: (sel) => setState(() {
                        if (sel) {
                          _dartFactors.add(f);
                        } else {
                          _dartFactors.remove(f);
                        }
                      }),
                    ),
              ],
            ),
            const SizedBox(height: 6),
            for (final f in _dartFactors)
              Text(
                '$f ← ${(_dartInspection?['column_sources'] as Map? ?? {})[f] ?? "measurement table"}',
                style: const TextStyle(fontSize: 11.5, color: Color(0xFF475569)),
              ),
            if (_dartFactors.isNotEmpty) ...[
              const SizedBox(height: 10),
              _buildComparisonSelector(
                availableFactors: _dartFactors,
                levelsByFactor: effectiveLevelsMap,
                liveUpdate: false,
              ),
            ],
            const SizedBox(height: 10),
            ExpansionTile(
              title: const Text('Optional: Advanced model & ERP difference'),
              subtitle: const Text(
                'Switch to permutation test, subtract Condition B − A, or open grand averages',
                style: TextStyle(fontSize: 11.5),
              ),
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 10,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          ChoiceChip(
                            label: const Text('Linear Mixed Model / GLM (Default)'),
                            selected: _fittedFactorial,
                            onSelected: _isAnalyzing
                                ? null
                                : (_) => setState(() => _fittedFactorial = true),
                          ),
                          ChoiceChip(
                            label: const Text('Permutation Test'),
                            selected: !_fittedFactorial,
                            onSelected: _isAnalyzing
                                ? null
                                : (_) => setState(() => _fittedFactorial = false),
                          ),
                          if (!_fittedFactorial)
                            SizedBox(
                              width: 120,
                              child: TextField(
                                controller: _permCountCtrl,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  labelText: 'Permutations',
                                  isDense: true,
                                  border: OutlineInputBorder(),
                                ),
                              ),
                            ),
                          if ((_dartInspection?['metric_columns'] as List? ?? [])
                              .any((m) => '$m'.endsWith('_ERP')))
                            OutlinedButton.icon(
                              onPressed: _isAnalyzing
                                  ? null
                                  : () => _openGroupedFigures(),
                              icon: const Icon(Icons.image, size: 16),
                              label: const Text('Group Grand Averages & Topomaps…'),
                            ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              initialValue: _preferredModel,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                labelText: 'Model Approach',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              items: const [
                                DropdownMenuItem(
                                  value: 'auto',
                                  child: Text('Auto (LMM for repeated, GLM otherwise)'),
                                ),
                                DropdownMenuItem(
                                  value: 'lmm',
                                  child: Text('Linear Mixed Model (Random Intercept)'),
                                ),
                                DropdownMenuItem(
                                  value: 'glm',
                                  child: Text('General Linear Model (GLM / ANOVA)'),
                                ),
                              ],
                              onChanged: (v) => setState(
                                () => _preferredModel = v ?? 'auto',
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              initialValue: _posthocMethod,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                labelText: 'Multiple Comparisons Correction',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                              items: const [
                                DropdownMenuItem(
                                  value: 'fdr',
                                  child: Text('Benjamini-Hochberg FDR'),
                                ),
                                DropdownMenuItem(
                                  value: 'bonferroni',
                                  child: Text('Bonferroni'),
                                ),
                              ],
                              onChanged: (v) => setState(() {
                                _posthocMethod = v ?? 'fdr';
                                _applyContrastSelectionToResults(
                                  _dartAnalysisResults,
                                );
                              }),
                            ),
                          ),
                        ],
                      ),
                      Builder(
                        builder: (context) {
                          final cc = condCol;
                          final condLevels = cc == null
                              ? const <String>[]
                              : _conditionLevelsForCol(_dartInspection, cc);
                          if (cc == null || condLevels.length < 2) {
                            return const SizedBox.shrink();
                          }
                          final pairs = _effectiveErpDiffPairs(
                            _dartInspection,
                            cc,
                          );
                          final selA =
                              (_erpDiffCondA != null &&
                                  condLevels.contains(_erpDiffCondA))
                              ? _erpDiffCondA!
                              : (pairs.isNotEmpty
                                    ? pairs.first.condA
                                    : (condLevels.contains('Freq')
                                          ? 'Freq'
                                          : condLevels.first));
                          final selB =
                              (_erpDiffCondB != null &&
                                  condLevels.contains(_erpDiffCondB))
                              ? _erpDiffCondB!
                              : (pairs.isNotEmpty
                                    ? pairs.first.condB
                                    : (condLevels.contains('Rare') &&
                                              'Rare' != selA
                                          ? 'Rare'
                                          : condLevels.firstWhere(
                                              (c) => c != selA,
                                            )));
                          final pairKeys = {
                            for (final p in pairs) '${p.condB} − ${p.condA}',
                          };
                          final nextToAdd = () {
                            if (selB != selA &&
                                !pairKeys.contains('$selB − $selA')) {
                              return (condB: selB, condA: selA);
                            }
                            for (final c in condLevels) {
                              if (c != selA &&
                                  !pairKeys.contains('$c − $selA')) {
                                return (condB: c, condA: selA);
                              }
                            }
                            for (final b in condLevels) {
                              for (final a in condLevels) {
                                if (b != a && !pairKeys.contains('$b − $a')) {
                                  return (condB: b, condA: a);
                                }
                              }
                            }
                            return null;
                          }();
                          return Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Wrap(
                                  spacing: 10,
                                  runSpacing: 6,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    const Text(
                                      'Condition mode:',
                                      style: TextStyle(
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    ChoiceChip(
                                      label: const Text(
                                        'All conditions',
                                        style: TextStyle(fontSize: 11),
                                      ),
                                      selected: !_erpDiffMode,
                                      onSelected: _isAnalyzing
                                          ? null
                                          : (_) => setState(
                                              () => _erpDiffMode = false,
                                            ),
                                    ),
                                    ChoiceChip(
                                      label: const Text(
                                        'Difference (B − A)',
                                        style: TextStyle(fontSize: 11),
                                      ),
                                      selected: _erpDiffMode,
                                      onSelected: _isAnalyzing
                                          ? null
                                          : (_) => setState(() {
                                              _erpDiffMode = true;
                                              _erpDiffCondB ??= selB;
                                              _erpDiffCondA ??= selA;
                                              if (_erpDiffPairs.isEmpty &&
                                                  pairs.isNotEmpty) {
                                                _erpDiffPairs.addAll(pairs);
                                              }
                                              if (_erpDiffPairs.length <= 1) {
                                                _dropCondFactorFromRoles(cc);
                                              }
                                            }),
                                    ),
                                    if (_erpDiffMode) ...[
                                      SizedBox(
                                        width: 120,
                                        child: DropdownButtonFormField<String>(
                                          key: ValueKey('erp-diff-b-$selB'),
                                          initialValue: selB,
                                          isDense: true,
                                          decoration: const InputDecoration(
                                            labelText: 'Condition B',
                                            border: OutlineInputBorder(),
                                          ),
                                          items: [
                                            for (final lv in condLevels)
                                              DropdownMenuItem(
                                                value: lv,
                                                child: Text(
                                                  _plotConfig.levelLabel(cc, lv),
                                                  style: const TextStyle(
                                                    fontSize: 11.5,
                                                  ),
                                                ),
                                              ),
                                          ],
                                          onChanged: (v) {
                                            if (v == null) return;
                                            setState(() {
                                              _erpDiffCondB = v;
                                              if (_erpDiffPairs.length <= 1 &&
                                                  v != selA) {
                                                _erpDiffPairs
                                                  ..clear()
                                                  ..add((condB: v, condA: selA));
                                              }
                                            });
                                          },
                                        ),
                                      ),
                                      const Text(
                                        '−',
                                        style: TextStyle(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      SizedBox(
                                        width: 120,
                                        child: DropdownButtonFormField<String>(
                                          key: ValueKey('erp-diff-a-$selA'),
                                          initialValue: selA,
                                          isDense: true,
                                          decoration: const InputDecoration(
                                            labelText: 'Condition A',
                                            border: OutlineInputBorder(),
                                          ),
                                          items: [
                                            for (final lv in condLevels)
                                              DropdownMenuItem(
                                                value: lv,
                                                child: Text(
                                                  _plotConfig.levelLabel(cc, lv),
                                                  style: const TextStyle(
                                                    fontSize: 11.5,
                                                  ),
                                                ),
                                              ),
                                          ],
                                          onChanged: (v) {
                                            if (v == null) return;
                                            setState(() {
                                              _erpDiffCondA = v;
                                              if (_erpDiffPairs.length <= 1 &&
                                                  selB != v) {
                                                _erpDiffPairs
                                                  ..clear()
                                                  ..add((condB: selB, condA: v));
                                              }
                                            });
                                          },
                                        ),
                                      ),
                                      OutlinedButton.icon(
                                        onPressed:
                                            (!_isAnalyzing && nextToAdd != null)
                                            ? () => setState(() {
                                                if (_erpDiffPairs.isEmpty) {
                                                  _erpDiffPairs.addAll(pairs);
                                                }
                                                _erpDiffPairs.add(nextToAdd);
                                                _erpDiffCondB = nextToAdd.condB;
                                                _erpDiffCondA = nextToAdd.condA;
                                                if (_erpDiffPairs.length >= 2) {
                                                  if (!_dartFactors.contains(
                                                    cc,
                                                  )) {
                                                    _dartFactors.add(cc);
                                                  }
                                                  if (_plotConfig
                                                              .facetColFactor ==
                                                          null &&
                                                      _plotConfig.xFactor !=
                                                          cc &&
                                                      _plotConfig
                                                              .seriesFactor !=
                                                          cc) {
                                                    _plotConfig = _plotConfig
                                                        .copyWith(
                                                          facetColFactor: cc,
                                                        );
                                                  }
                                                }
                                              })
                                            : null,
                                        icon: const Icon(Icons.add, size: 14),
                                        label: const Text(
                                          'Add difference',
                                          style: TextStyle(fontSize: 11),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                if (_erpDiffMode && pairs.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  Wrap(
                                    spacing: 6,
                                    runSpacing: 6,
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    children: [
                                      const Text(
                                        'Active differences:',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: Color(0xFF475569),
                                        ),
                                      ),
                                      for (final p in pairs)
                                        InputChip(
                                          label: Text(
                                            '${_plotConfig.levelLabel(cc, p.condB)} − ${_plotConfig.levelLabel(cc, p.condA)}',
                                            style: const TextStyle(
                                              fontSize: 11,
                                            ),
                                          ),
                                          selected: true,
                                          onDeleted: pairs.length > 1
                                              ? () => setState(() {
                                                  _erpDiffPairs
                                                    ..clear()
                                                    ..addAll(
                                                      pairs.where(
                                                        (x) =>
                                                            !(x.condB ==
                                                                    p.condB &&
                                                                x.condA ==
                                                                    p.condA),
                                                      ),
                                                    );
                                                  if (_erpDiffPairs.length ==
                                                      1) {
                                                    _erpDiffCondB =
                                                        _erpDiffPairs
                                                            .first
                                                            .condB;
                                                    _erpDiffCondA =
                                                        _erpDiffPairs
                                                            .first
                                                            .condA;
                                                    _dropCondFactorFromRoles(
                                                      cc,
                                                    );
                                                  }
                                                })
                                              : null,
                                        ),
                                    ],
                                  ),
                                ],
                                if (_erpDiffMode && pairs.length >= 2)
                                  const Padding(
                                    padding: EdgeInsets.only(top: 4),
                                    child: Text(
                                      'Keep Condition selected above to compare differences in one model & plot, or uncheck it to fit separate models per difference.',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: Color(0xFF64748B),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ExpansionTile(
              initiallyExpanded: true,
              title: const Text('Plot layout, level order & live preview'),
              subtitle: const Text(
                'Arrange which factor goes on X-axis, lines, and subplot columns/rows',
                style: TextStyle(fontSize: 11.5),
              ),
              children: [
                const SizedBox(height: 10),
                Row(
                  children: [
                    roleDropdown(
                      'X-Axis (Points)',
                      _plotConfig.xFactor,
                      (v) => _assignPlotRole('x', v),
                    ),
                    const SizedBox(width: 8),
                    roleDropdown(
                      'Lines / Hue (Series)',
                      _plotConfig.seriesFactor,
                      (v) => _assignPlotRole('series', v),
                    ),
                    const SizedBox(width: 8),
                    roleDropdown(
                      'Subplot Columns',
                      _plotConfig.facetColFactor,
                      (v) => _assignPlotRole('col', v),
                    ),
                    const SizedBox(width: 8),
                    roleDropdown(
                      'Subplot Rows',
                      _plotConfig.facetRowFactor,
                      (v) => _assignPlotRole('row', v),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 10,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SegmentedButton<StatsPlotType>(
                      segments: const [
                        ButtonSegment(
                          value: StatsPlotType.line,
                          label: Text(
                            'Line + Error',
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                        ButtonSegment(
                          value: StatsPlotType.bar,
                          label: Text(
                            'Bar + Error',
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                        ButtonSegment(
                          value: StatsPlotType.boxplot,
                          label: Text(
                            'Box Plot',
                            style: TextStyle(fontSize: 11),
                          ),
                        ),
                      ],
                      selected: {_plotConfig.plotType},
                      onSelectionChanged: (s) => setState(
                        () => _plotConfig = _plotConfig.copyWith(
                          plotType: s.first,
                        ),
                      ),
                    ),
                    FilterChip(
                      label: Text(
                        _plotConfig.useSem ? 'Error: SEM' : 'Error: SD',
                        style: const TextStyle(fontSize: 11),
                      ),
                      selected: _plotConfig.useSem,
                      onSelected: (v) => setState(
                        () => _plotConfig = _plotConfig.copyWith(useSem: v),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                for (final f in _dartFactors) ...[
                  Builder(
                    builder: (context) {
                      final raw = displayedRawLevels(f);
                      final custom = _dartLevelOrder[f];
                      final ordered = custom != null && custom.isNotEmpty
                          ? [
                              for (final l in custom)
                                if (raw.contains(l)) l,
                              for (final l in raw)
                                if (!custom.contains(l)) l,
                            ]
                          : raw;
                      final excl = _dartExcludedLevels[f] ?? <String>{};
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              '${_plotConfig.factorLabel(f)} order/filter:',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (raw.any((l) => l.toLowerCase() == 'unknown'))
                              ActionChip(
                                avatar: const Icon(
                                  Icons.filter_alt_off,
                                  size: 14,
                                ),
                                label: Text(
                                  raw
                                          .where(
                                            (l) => l.toLowerCase() == 'unknown',
                                          )
                                          .every((u) => excl.contains(u))
                                      ? 'Include "Unknown"'
                                      : 'Exclude "Unknown"',
                                  style: const TextStyle(fontSize: 11),
                                ),
                                onPressed: () => setState(() {
                                  final set = _dartExcludedLevels.putIfAbsent(
                                    f,
                                    () => <String>{},
                                  );
                                  final unknowns = raw
                                      .where(
                                        (l) => l.toLowerCase() == 'unknown',
                                      )
                                      .toList();
                                  final allExcl = unknowns.every(
                                    (u) => set.contains(u),
                                  );
                                  if (allExcl) {
                                    set.removeAll(unknowns);
                                  } else {
                                    set.addAll(unknowns);
                                  }
                                }),
                              ),
                            for (var i = 0; i < ordered.length; i++)
                              InputChip(
                                label: Text(
                                  _plotConfig.levelLabel(f, ordered[i]),
                                  style: TextStyle(
                                    fontSize: 11,
                                    decoration: excl.contains(ordered[i])
                                        ? TextDecoration.lineThrough
                                        : null,
                                  ),
                                ),
                                selected: !excl.contains(ordered[i]),
                                onSelected: (sel) => setState(() {
                                  final set = _dartExcludedLevels.putIfAbsent(
                                    f,
                                    () => <String>{},
                                  );
                                  if (sel) {
                                    set.remove(ordered[i]);
                                  } else {
                                    set.add(ordered[i]);
                                  }
                                }),
                                onDeleted: i == ordered.length - 1
                                    ? null
                                    : () => setState(() {
                                        final list = List<String>.from(ordered);
                                        final item = list.removeAt(i);
                                        list.insert(i + 1, item);
                                        _dartLevelOrder[f] = list;
                                      }),
                                deleteIcon: const Icon(
                                  Icons.arrow_forward,
                                  size: 13,
                                ),
                                deleteButtonTooltipMessage: 'Move level right',
                              ),
                          ],
                        ),
                      );
                    },
                  ),
                ],
                const SizedBox(height: 8),
                ConfigurableStatsPlotWidget(
                  config: _plotConfig,
                  factorLevels: effectiveLevelsMap,
                  metricName: _selectedMetrics.isNotEmpty
                      ? (_erpDiffMode && activeDiffLabels.isNotEmpty
                            ? '${groupMetricLabel(_selectedMetrics.first)} (${activeDiffLabels.length >= 2 && _dartFactors.contains(condCol) ? 'Difference' : activeDiffLabels.first})'
                            : groupMetricLabel(_selectedMetrics.first))
                      : 'ERP Metric',
                  activeFactors: _dartFactors,
                  isDummyPreview: true,
                  height: 290,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDartResultsCard() {
    final resList = (_dartAnalysisResults?['results'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    if (resList.isEmpty) return const SizedBox.shrink();
    final active = resList.firstWhere(
      (r) => r['metric'] == _selectedDartMetric,
      orElse: () => resList.first,
    );
    final activeFactors = (active['factors'] as List? ?? []).cast<String>();
    final levelsMap = <String, List<String>>{};
    final rawLevels = (active['factor_levels'] as Map<String, dynamic>? ?? {});
    for (final e in rawLevels.entries) {
      final raw = (e.value as List).map((x) => '$x').toList();
      final custom = _dartLevelOrder[e.key];
      levelsMap[e.key] = custom != null && custom.isNotEmpty
          ? [
              for (final l in custom)
                if (raw.contains(l)) l,
              for (final l in raw)
                if (!custom.contains(l)) l,
            ]
          : raw;
    }
    final effects = (active['model_effects'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    final posthocs = (active['posthoc'] as List? ?? [])
        .cast<Map<String, dynamic>>();

    final condCol = _detectConditionFactorCol(_dartInspection);
    final condLevels = condCol == null
        ? const <String>[]
        : _conditionLevelsForCol(_dartInspection, condCol);
    final canToggleDiff = condCol != null && condLevels.length >= 2;
    final hasErpMetrics = (_dartInspection?['metric_columns'] as List? ?? [])
        .any((m) => '$m'.endsWith('_ERP'));
    final groupFactor = _findGroupFactor(_dartFactors);
    final roleChoices = ['None', ...activeFactors];

    Widget compactRolePicker(String label, String? value, String role) {
      final cur = (value != null && roleChoices.contains(value))
          ? value
          : 'None';
      return SizedBox(
        width: 148,
        child: DropdownButtonFormField<String>(
          key: ValueKey('res-role-$role-$cur'),
          initialValue: cur,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: label,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 8,
            ),
            border: const OutlineInputBorder(),
          ),
          items: [
            for (final f in roleChoices)
              DropdownMenuItem(
                value: f,
                child: Text(
                  _plotConfig.factorLabel(f),
                  style: const TextStyle(fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: (v) => _assignPlotRole(role, v),
        ),
      );
    }

    final contrastSummary =
        '${active['posthoc_family'] ?? _describeContrastSelection(activeFactors)} (${_posthocMethod.toUpperCase()})';

    final filteredPosthocs = posthocs.where((c) {
      if (_posthocTableSigOnly && c['significant'] != true) return false;
      if (_posthocTableFactorFilter != null &&
          activeFactors.contains(_posthocTableFactorFilter) &&
          '${c['factor']}' != _posthocTableFactorFilter) {
        return false;
      }
      final stratum = c['stratum'] as Map? ?? const {};
      if (_posthocTableScope == 'simple' && stratum.isEmpty) return false;
      if (_posthocTableScope == 'marginal' && stratum.isNotEmpty) return false;
      return true;
    }).toList();

    return Card(
      elevation: 0,
      color: CcsTheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.teal.shade300),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.auto_graph,
                  size: 20,
                  color: Color(0xFF0D9488),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${active['model_type']} · N=${active['n_obs']}, participants=${active['n_subjects']}',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: CcsTheme.text,
                    ),
                  ),
                ),
                SizedBox(
                  width: 310,
                  child: DropdownButtonFormField<String>(
                    key: ValueKey('res-metric-${active['metric']}'),
                    initialValue: active['metric'] as String?,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Metric',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      for (final r in resList)
                        DropdownMenuItem(
                          value: r['metric'] as String,
                          child: Text(
                            groupMetricLabel(r['metric'] as String),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (v) => setState(() => _selectedDartMetric = v),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            // Quick-Control Bar: switch Raw vs Difference, Contrast Scope, Layout, and Export in 1 click
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: CcsTheme.panel,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: CcsTheme.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (canToggleDiff) ...[
                        const Text(
                          'Data:',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: CcsTheme.text,
                          ),
                        ),
                        SegmentedButton<bool>(
                          showSelectedIcon: false,
                          style: SegmentedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            textStyle: const TextStyle(fontSize: 11.5),
                          ),
                          segments: const [
                            ButtonSegment(
                              value: false,
                              label: Text('Raw ERPs'),
                            ),
                            ButtonSegment(
                              value: true,
                              label: Text('ERP Differences'),
                            ),
                          ],
                          selected: {_erpDiffMode},
                          onSelectionChanged: _isAnalyzing
                              ? null
                              : (s) => _toggleResultsDifferenceMode(s.first),
                        ),
                      ],
                      if (groupFactor != null && _dartFactors.length >= 2)
                        FilledButton.tonalIcon(
                          onPressed: _isAnalyzing
                              ? null
                              : () => _applyCompareGroupsPreset(rerun: true),
                          icon: const Icon(Icons.groups, size: 16),
                          label: Text(
                            'Compare ${_plotConfig.factorLabel(groupFactor)}s',
                            style: const TextStyle(fontSize: 11.5),
                          ),
                        ),
                      OutlinedButton.icon(
                        onPressed: _isAnalyzing || _isExportingStatsPlot
                            ? null
                            : () => _exportPublicationStatsFigure(
                                active,
                                levelsMap,
                                posthocs,
                              ),
                        icon: _isExportingStatsPlot
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.publish, size: 16),
                        label: const Text(
                          'Export Stats Figure (PNG/SVG/PDF)…',
                          style: TextStyle(fontSize: 11.5),
                        ),
                      ),
                      if (hasErpMetrics)
                        OutlinedButton.icon(
                          onPressed: _isAnalyzing
                              ? null
                              : () => _openGroupedFigures(),
                          icon: const Icon(Icons.waves, size: 16),
                          label: const Text(
                            'ERP Waveforms & Topomaps…',
                            style: TextStyle(fontSize: 11.5),
                          ),
                        ),
                      TextButton.icon(
                        onPressed: _exportFactorialResults,
                        icon: const Icon(Icons.save_alt, size: 16),
                        label: const Text(
                          'Export JSON & CSV…',
                          style: TextStyle(fontSize: 11.5),
                        ),
                      ),
                    ],
                  ),
                  if (activeFactors.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    _buildComparisonSelector(
                      availableFactors: activeFactors,
                      levelsByFactor: levelsMap,
                      liveUpdate: true,
                    ),
                  ],
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      compactRolePicker('X-Axis', _plotConfig.xFactor, 'x'),
                      compactRolePicker(
                        'Lines / Hue',
                        _plotConfig.seriesFactor,
                        'series',
                      ),
                      compactRolePicker(
                        'Columns',
                        _plotConfig.facetColFactor,
                        'col',
                      ),
                      compactRolePicker(
                        'Rows',
                        _plotConfig.facetRowFactor,
                        'row',
                      ),
                      SegmentedButton<StatsPlotType>(
                        showSelectedIcon: false,
                        style: SegmentedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          textStyle: const TextStyle(fontSize: 11),
                        ),
                        segments: const [
                          ButtonSegment(
                            value: StatsPlotType.line,
                            label: Text('Line'),
                          ),
                          ButtonSegment(
                            value: StatsPlotType.bar,
                            label: Text('Bar'),
                          ),
                          ButtonSegment(
                            value: StatsPlotType.boxplot,
                            label: Text('Box'),
                          ),
                        ],
                        selected: {_plotConfig.plotType},
                        onSelectionChanged: (s) => setState(
                          () => _plotConfig = _plotConfig.copyWith(
                            plotType: s.first,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '${groupMetricLabel("${active['metric']}")} · ${active['n_subjects']} participants · ${active['n_obs']} measurement rows',
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: CcsTheme.text,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'Test statistic: ${active['test_statistic'] ?? 'F'}. $contrastSummary.',
              style: const TextStyle(
                fontSize: 12,
                color: CcsTheme.textSecondary,
              ),
            ),
            if (active['inference_note'] != null)
              Text(
                '${active['inference_note']}',
                style: const TextStyle(
                  fontSize: 11,
                  color: CcsTheme.textSecondary,
                ),
              ),
            for (final warning in (active['warnings'] as List? ?? []))
              Text(
                'Model warning: $warning',
                style: const TextStyle(color: Color(0xFFB45309), fontSize: 11),
              ),
            const SizedBox(height: 6),
            const Text(
              'Plot shows the included groups. Effects tested asks whether each factor or interaction differs; Pairwise comparisons shows which levels differ.',
              style: TextStyle(fontSize: 12, color: CcsTheme.textSecondary),
            ),
            const SizedBox(height: 10),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('Plot')),
                ButtonSegment(value: 1, label: Text('Effects tested')),
                ButtonSegment(value: 2, label: Text('Pairwise comparisons')),
              ],
              selected: {_dartResultTab},
              onSelectionChanged: (s) =>
                  setState(() => _dartResultTab = s.first),
            ),
            const SizedBox(height: 12),
            if (_dartResultTab == 0)
              ConfigurableStatsPlotWidget(
                config: _plotConfig,
                factorLevels: levelsMap,
                metricName: groupMetricLabel('${active['metric']}'),
                cellDescriptives:
                    (active['cell_descriptives'] as Map<String, dynamic>? ??
                    {}),
                activeFactors: activeFactors,
                isDummyPreview: false,
                height: 380,
                posthocs: posthocs,
                initialBracketFactor: _plotBracketFactorFilter,
                contrastSummary: contrastSummary,
                onBracketFactorChanged: (v) =>
                    setState(() => _plotBracketFactorFilter = v),
              )
            else if (_dartResultTab == 1)
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columns: const [
                    DataColumn(label: Text('Term')),
                    DataColumn(label: Text('Statistic (see method)')),
                    DataColumn(label: Text('df')),
                    DataColumn(label: Text('p (param)')),
                    DataColumn(label: Text('p (perm)')),
                    DataColumn(label: Text('η²')),
                  ],
                  rows: [
                    for (final eff in effects)
                      DataRow(
                        cells: [
                          DataCell(
                            Text(
                              '${eff['term']}'
                                  .split(RegExp(r'\s*[×:]\s*'))
                                  .map(_plotConfig.factorLabel)
                                  .join(' × '),
                            ),
                          ),
                          DataCell(
                            Text((eff['f_stat'] as num).toStringAsFixed(3)),
                          ),
                          DataCell(
                            Text(
                              '${eff['df_num']}${eff['df_denom'] == null ? '' : ', ${eff['df_denom']}'}',
                            ),
                          ),
                          DataCell(Text(_formatP(eff['p_value'] as num?))),
                          DataCell(
                            Text(
                              _formatP(eff['p_perm'] as num?),
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: ((eff['p_perm'] as num?) ?? 1.0) < 0.05
                                    ? Colors.teal.shade700
                                    : null,
                              ),
                            ),
                          ),
                          DataCell(
                            Text(
                              (eff['eta_sq'] as num?)?.toStringAsFixed(3) ??
                                  '—',
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              )
            else ...[
              Container(
                padding: const EdgeInsets.all(10),
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  color: CcsTheme.panel,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: CcsTheme.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Showing ${filteredPosthocs.length} of ${posthocs.length} contrasts (${posthocs.where((c) => c['significant'] == true).length} significant at adjusted p < .05) · Correction: ${_posthocMethod.toUpperCase()} · Diff = level B − level A',
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: CcsTheme.text,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        FilterChip(
                          label: const Text(
                            'Significant only',
                            style: TextStyle(fontSize: 11),
                          ),
                          selected: _posthocTableSigOnly,
                          onSelected: (v) =>
                              setState(() => _posthocTableSigOnly = v),
                        ),
                        ChoiceChip(
                          label: const Text(
                            'All factors',
                            style: TextStyle(fontSize: 11),
                          ),
                          selected: _posthocTableFactorFilter == null,
                          onSelected: (_) =>
                              setState(() => _posthocTableFactorFilter = null),
                        ),
                        for (final f in activeFactors)
                          ChoiceChip(
                            label: Text(
                              _plotConfig.factorLabel(f),
                              style: const TextStyle(fontSize: 11),
                            ),
                            selected: _posthocTableFactorFilter == f,
                            onSelected: (_) =>
                                setState(() => _posthocTableFactorFilter = f),
                          ),
                        const SizedBox(width: 8),
                        SegmentedButton<String>(
                          showSelectedIcon: false,
                          style: SegmentedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            textStyle: const TextStyle(fontSize: 11),
                          ),
                          segments: const [
                            ButtonSegment(
                              value: 'all',
                              label: Text('All scopes'),
                            ),
                            ButtonSegment(
                              value: 'simple',
                              label: Text('Simple effects'),
                            ),
                            ButtonSegment(
                              value: 'marginal',
                              label: Text('Marginal'),
                            ),
                          ],
                          selected: {_posthocTableScope},
                          onSelectionChanged: (s) =>
                              setState(() => _posthocTableScope = s.first),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (filteredPosthocs.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    'No contrasts match the current filter. Clear "Significant only" or switch factor scope above.',
                    style: TextStyle(color: CcsTheme.textSecondary),
                  ),
                )
              else
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    columns: const [
                      DataColumn(label: Text('Factor')),
                      DataColumn(label: Text('Within (Stratum)')),
                      DataColumn(label: Text('Comparison (A vs B)')),
                      DataColumn(label: Text('Diff (B−A)')),
                      DataColumn(label: Text('t / z')),
                      DataColumn(label: Text('p (raw)')),
                      DataColumn(label: Text('p (adj)')),
                    ],
                    rows: [
                      for (final c in filteredPosthocs)
                        DataRow(
                          cells: [
                            DataCell(
                              Text(_plotConfig.factorLabel('${c['factor']}')),
                            ),
                            DataCell(
                              Text(() {
                                final stratum = c['stratum'] as Map? ?? {};
                                if (stratum.isEmpty) return 'Marginal (overall)';
                                return stratum.entries
                                    .map(
                                      (e) =>
                                          '${_plotConfig.factorLabel("${e.key}")}=${_plotConfig.levelLabel("${e.key}", "${e.value}")}',
                                    )
                                    .join(', ');
                              }()),
                            ),
                            DataCell(
                              Text(
                                '${_plotConfig.levelLabel("${c['factor']}", "${c['group_a']}")} vs ${_plotConfig.levelLabel("${c['factor']}", "${c['group_b']}")}',
                              ),
                            ),
                            DataCell(
                              Text((c['mean_diff'] as num).toStringAsFixed(3)),
                            ),
                            DataCell(
                              Text((c['t_stat'] as num).toStringAsFixed(3)),
                            ),
                            DataCell(Text(_formatP(c['p_raw'] as num?))),
                            DataCell(
                              Text(
                                _formatP(c['p_adj'] as num?),
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: c['significant'] == true
                                      ? Colors.teal.shade700
                                      : null,
                                ),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildActionRunCard() {
    return Card(
      elevation: 0,
      color: const Color(0xFFFFFFFF),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: const Color(0xFFCBD5E1)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed:
                        _isAnalyzing ||
                            _isInspecting ||
                            !_groupsReady ||
                            _selectedMetrics.isEmpty ||
                            _dartInspection == null
                        ? null
                        : _runDartPermutationAnalysis,
                    icon: _isAnalyzing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Color(0xFF1E293B),
                            ),
                          )
                        : const Icon(Icons.auto_graph),
                    label: Text(
                      _isAnalyzing ? 'Running Analysis…' : 'Run Analysis',
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF0D9488),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      textStyle: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (_isAnalyzing) ...[
              const SizedBox(height: 14),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: _analysisProgress > 0 ? _analysisProgress : null,
                  minHeight: 8,
                  backgroundColor: const Color(0xFFF0F4F8),
                  valueColor: const AlwaysStoppedAnimation<Color>(
                    Color(0xFF1F4E79),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      _progressStatus.isNotEmpty
                          ? _progressStatus
                          : 'Running group analysis models…',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.blueGrey.shade800,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (_analysisProgress > 0)
                    Text(
                      '${(_analysisProgress * 100).toInt()}%',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Colors.blueGrey.shade800,
                      ),
                    ),
                ],
              ),
            ],
            if (_isAnalyzing || _consoleLogs.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                height: 110,
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFF0F4F8),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ListView.builder(
                  itemCount: _consoleLogs.length,
                  itemBuilder: (ctx, i) => Text(
                    _consoleLogs[i],
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: Color(0xFF4AF626),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildResultsCard() {
    final outputDir = _analysisResults!['output_dir'] as String? ?? '';
    final docxPath = _analysisResults!['docx_path'] as String?;
    final pdfPath = _analysisResults!['pdf_path'] as String?;
    final resList = (_analysisResults!['results'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();

    final activeResult = resList.firstWhere(
      (r) => r['metric'] == _selectedResultMetric,
      orElse: () => resList.isNotEmpty ? resList.first : {},
    );

    return Card(
      elevation: 0,
      color: const Color(0xFFFFFFFF),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: const Color(0xFFCBD5E1)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if ((_analysisResults!['report_warnings'] as List? ?? [])
                .isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  'Plots and tables were saved, but some report files could not be created. ${(_analysisResults!['report_warnings'] as List).join(" ")}',
                ),
              ),
            // Top action bar
            Row(
              children: [
                const Icon(
                  Icons.folder_special_outlined,
                  color: Color(0xFF38BDF8),
                  size: 24,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Analysis Results & Publications',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                      Text(
                        'Saved to: $outputDir',
                        style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: () => _openPath(outputDir),
                  icon: const Icon(Icons.folder_open, size: 16),
                  label: const Text('Open Folder'),
                ),
                const SizedBox(width: 8),
                if (docxPath != null)
                  FilledButton.icon(
                    onPressed: () => _openPath(docxPath),
                    icon: const Icon(Icons.description, size: 16),
                    label: const Text('Word (.docx)'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF1F4E79),
                    ),
                  ),
                const SizedBox(width: 8),
                if (pdfPath != null)
                  FilledButton.icon(
                    onPressed: () => _openPath(pdfPath),
                    icon: const Icon(Icons.picture_as_pdf, size: 16),
                    label: const Text('PDF Report'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFD32F2F),
                    ),
                  ),
              ],
            ),
            const Divider(height: 24),
            // Metric selector pills
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final r in resList)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(r['metric'] as String),
                        selected: _selectedResultMetric == r['metric'],
                        onSelected: (sel) {
                          if (sel) {
                            setState(
                              () =>
                                  _selectedResultMetric = r['metric'] as String,
                            );
                          }
                        },
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            // Tabs: Plot, Model Effects, Post-Hoc, Descriptives
            Row(
              children: [
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(
                      value: 0,
                      icon: Icon(Icons.image_outlined, size: 16),
                      label: Text('Publication Plot'),
                    ),
                    ButtonSegment(
                      value: 1,
                      icon: Icon(Icons.table_chart_outlined, size: 16),
                      label: Text('Model Effects'),
                    ),
                    ButtonSegment(
                      value: 2,
                      icon: Icon(Icons.compare_arrows_outlined, size: 16),
                      label: Text('Pairwise comparisons'),
                    ),
                    ButtonSegment(
                      value: 3,
                      icon: Icon(Icons.summarize_outlined, size: 16),
                      label: Text('Descriptive Stats'),
                    ),
                  ],
                  selected: {_activeResultTabIndex},
                  onSelectionChanged: (s) =>
                      setState(() => _activeResultTabIndex = s.first),
                ),
              ],
            ),
            const SizedBox(height: 14),
            // Active Tab Content
            if (activeResult.isNotEmpty) ...[
              if (_activeResultTabIndex == 0) _buildPlotTab(activeResult),
              if (_activeResultTabIndex == 1)
                _buildModelEffectsTab(activeResult),
              if (_activeResultTabIndex == 2) _buildPostHocTab(activeResult),
              if (_activeResultTabIndex == 3)
                _buildDescriptivesTab(activeResult),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildPlotTab(Map<String, dynamic> res) {
    final plotPath = res['plot_path'] as String? ?? '';
    final topoPath = res['topoplot_path'] as String? ?? '';
    final isMacro = res['is_macroarchitecture'] == true;

    final hasTopo = topoPath.isNotEmpty && File(topoPath).existsSync();
    final currentPath = (_activePlotView == 1 && hasTopo) ? topoPath : plotPath;
    final file = File(currentPath);

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFCBD5E1)),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      '${res['metric']} · Model: ${res['model_type']} · N=${res['n_obs']}',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                        color: Color(0xFF38BDF8),
                      ),
                    ),
                    if (isMacro)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.amber.shade100,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.amber.shade400),
                        ),
                        child: Text(
                          'Macroarchitecture (Subject-Level; Channel-Invariant)',
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.bold,
                            color: Colors.amber.shade900,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (hasTopo)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(
                        value: 0,
                        icon: Icon(Icons.bar_chart, size: 14),
                        label: Text('Boxplot & Post-hoc'),
                      ),
                      ButtonSegment(
                        value: 1,
                        icon: Icon(Icons.pie_chart, size: 14),
                        label: Text('Scalp Topoplot'),
                      ),
                    ],
                    selected: {_activePlotView},
                    onSelectionChanged: (s) =>
                        setState(() => _activePlotView = s.first),
                  ),
                ),
              TextButton.icon(
                onPressed: file.existsSync()
                    ? () => _openPath(currentPath)
                    : null,
                icon: const Icon(Icons.zoom_in, size: 16),
                label: const Text('View Full Image'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (file.existsSync())
            Center(
              child: InkWell(
                onTap: () => _openPath(currentPath),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Image.file(file, height: 420, fit: BoxFit.contain),
                ),
              ),
            )
          else
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: Text('Plot image not found.')),
            ),
        ],
      ),
    );
  }

  Widget _buildModelEffectsTab(Map<String, dynamic> res) {
    final effects = (res['model_effects'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();

    if (effects.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: Text('No model effects recorded.')),
      );
    }

    return DataTable(
      columns: const [
        DataColumn(
          label: Text(
            'Factor / Term',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        DataColumn(
          label: Text(
            'Statistic Type',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        DataColumn(
          label: Text('Value', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        DataColumn(
          label: Text('df', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        DataColumn(
          label: Text('p (raw)', style: TextStyle(fontWeight: FontWeight.bold)),
        ),
        DataColumn(
          label: Text(
            'q (adjusted)',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        DataColumn(
          label: Text(
            'Significance',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
      ],
      rows: [
        for (final eff in effects)
          DataRow(
            cells: [
              DataCell(Text(eff['term'] as String? ?? '')),
              DataCell(Text(eff['stat_type'] as String? ?? '')),
              DataCell(
                Text((eff['statistic'] as num?)?.toStringAsFixed(3) ?? '-'),
              ),
              DataCell(
                Text(
                  '${eff['df'] ?? 1}${eff['df_resid'] != null ? ', ${eff['df_resid']}' : ''}',
                ),
              ),
              DataCell(Text(_formatP(eff['p_value'] as num?))),
              DataCell(Text(_formatP(eff['q_value'] as num?))),
              DataCell(_buildSigBadge(eff['significance'] as String? ?? 'ns')),
            ],
          ),
      ],
    );
  }

  Widget _buildPostHocTab(Map<String, dynamic> res) {
    final contrasts = (res['posthoc_contrasts'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();

    if (contrasts.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: Text('No post-hoc contrasts available.')),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columns: const [
          DataColumn(
            label: Text(
              'Factor Level',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          DataColumn(
            label: Text(
              'Comparison',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          DataColumn(
            label: Text(
              'Mean Diff',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          DataColumn(
            label: Text(
              't-stat',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          DataColumn(
            label: Text(
              'p (raw)',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          DataColumn(
            label: Text(
              'p (adjusted)',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          DataColumn(
            label: Text(
              'Cohen’s d',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          DataColumn(
            label: Text('Sig.', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
        rows: [
          for (final c in contrasts)
            DataRow(
              cells: [
                DataCell(Text(c['level'] as String? ?? 'Overall')),
                DataCell(Text('${c['group1']} vs ${c['group2']}')),
                DataCell(Text((c['diff'] as num?)?.toStringAsFixed(3) ?? '-')),
                DataCell(
                  Text((c['t_stat'] as num?)?.toStringAsFixed(3) ?? '-'),
                ),
                DataCell(Text(_formatP(c['p_raw'] as num?))),
                DataCell(Text(_formatP(c['p_adj'] as num?))),
                DataCell(
                  Text((c['cohen_d'] as num?)?.toStringAsFixed(2) ?? '-'),
                ),
                DataCell(_buildSigBadge(c['significance'] as String? ?? 'ns')),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildDescriptivesTab(Map<String, dynamic> res) {
    final stats = (res['descriptive_stats'] as List<dynamic>? ?? [])
        .cast<Map<String, dynamic>>();

    if (stats.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: Text('No descriptive statistics available.')),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columns: const [
          DataColumn(
            label: Text('Group', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          DataColumn(
            label: Text(
              'Subgroup',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          DataColumn(
            label: Text('N', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          DataColumn(
            label: Text(
              'Mean ± SD',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          DataColumn(
            label: Text(
              'Median (IQR)',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          DataColumn(
            label: Text('Min', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          DataColumn(
            label: Text('Max', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
        rows: [
          for (final s in stats)
            DataRow(
              cells: [
                DataCell(Text(s['group'] as String? ?? '-')),
                DataCell(Text(s['subgroup'] as String? ?? '-')),
                DataCell(Text('${s['n'] ?? 0}')),
                DataCell(
                  Text(
                    '${(s['mean'] as num?)?.toStringAsFixed(2)} ± ${(s['std'] as num?)?.toStringAsFixed(2)}',
                  ),
                ),
                DataCell(
                  Text(
                    '${(s['median'] as num?)?.toStringAsFixed(2)} (${(s['iqr'] as num?)?.toStringAsFixed(2)})',
                  ),
                ),
                DataCell(Text((s['min'] as num?)?.toStringAsFixed(2) ?? '-')),
                DataCell(Text((s['max'] as num?)?.toStringAsFixed(2) ?? '-')),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildSigBadge(String sig) {
    final isSig = sig != 'ns' && sig != 'n/a';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: isSig ? Colors.green.shade50 : const Color(0xFFF8F9FB),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isSig ? Colors.green.shade400 : const Color(0xFF334155),
        ),
      ),
      child: Text(
        sig,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.bold,
          color: isSig ? Colors.green.shade800 : const Color(0xFF64748B),
        ),
      ),
    );
  }

  String _formatP(num? p) {
    if (p == null) return 'n/a';
    if (p < 0.0001) return '< 0.0001';
    if (p < 0.001) return p.toStringAsFixed(4);
    return p.toStringAsFixed(3);
  }
}
