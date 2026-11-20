import 'extraction_service.dart';
import 'topostats/topostats_batch.dart' show preferSessionFeatureCsvs;
import 'filename_metadata.dart';
import 'filename_metadata_dialog.dart';
import 'topostats/topostats_engine.dart' show splitFeatureCsvLine;
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:file_picker/file_picker.dart';
import 'filtered_file_picker.dart';
import 'group_statistics_engine.dart';
import 'erp/factor_grouping_designer.dart' show TabularSheetReader;
import 'group_statistics_plots.dart';

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
  );
}

/// Top-level `Isolate.run` boundary prevents Dart shared closures in Stateful
/// callbacks from retaining UI `State` / `BuildContext` / `WidgetsFlutterBinding`.
Future<Map<String, dynamic>> runDartPermutationsInWorker(
  Map<String, dynamic> payload,
) => Isolate.run(() => runDartPermutationsInIsolate(payload));

Future<Map<String, dynamic>> inspectGroupDatasetInWorker(
  String csv, String metadata, String key,
) => Isolate.run(() => ErpGroupStatsEngine.inspectDataset(
  csvPath: csv, metadataPath: metadata, metadataKey: key,
));

/// Read Excel with the app's bundled reader so Python needs no Excel plugin.
Future<String> prepareGroupMetadataForPython(String path, Directory runtime) async {
  if (!path.toLowerCase().endsWith('.xlsx')) return path;
  final table = await TabularSheetReader.read(path);
  String cell(String value) => '"${value.replaceAll('"', '""')}"';
  final csv = [table.headers, ...table.rows]
      .map((row) => row.map(cell).join(',')).join('\n');
  final file = File('${runtime.path}/participant_groups.csv');
  await file.writeAsString(csv);
  return file.path;
}

String groupMetricLabel(String name) => const {
  'mean_amplitude_ERP': 'Mean amplitude (µV)',
  'signed_auc_ERP': 'Signed area under the curve (µV·s)',
  'peak_amplitude_ERP': 'Peak amplitude (µV)',
  'peak_latency_ms_ERP': 'Peak latency (ms)',
  'fractional_area_latency_ms_ERP': 'Fractional-area latency (ms)',
}[name] ?? name;

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
  bool _pythonReady = false;
  bool _usePermutation = false;

  String? get _participantGroupColumn {
    final counts = _dartInspection?['factor_counts'] as Map? ?? {};
    for (final column in counts.keys) {
      if (!const {'group', 'cohort', 'arm', 'groupid', 'group_id'}.contains('$column'.toLowerCase())) continue;
      final values = (counts[column] as Map).keys.map((k) => '$k'.trim().toLowerCase());
      if (values.any((v) => !const {'', 'unknown', 'unassigned', 'nan', 'none'}.contains(v))) return '$column';
    }
    return null;
  }

  Set<String> get _unassignedGroupLabels {
    final counts = (_dartInspection?['factor_counts'] as Map?)?[_participantGroupColumn] as Map? ?? {};
    return counts.keys.map((k) => '$k').where((k) => const {'', 'unknown', 'unassigned', 'nan', 'none'}.contains(k.toLowerCase().trim())).toSet();
  }

  bool get _groupsReady => _unassignedGroupLabels.every((label) => (_dartExcludedLevels[_participantGroupColumn] ?? {}).contains(label));

  void _setExcludeUnassigned(bool exclude) {
    setState(() {
      final group = _participantGroupColumn;
      if (group != null) {
        final levels = _dartExcludedLevels.putIfAbsent(group, () => {});
        if (exclude) { levels.addAll(_unassignedGroupLabels); }
        else { levels.removeAll(_unassignedGroupLabels); }
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
      _pythonReady = false;
      _workflowStep = 0;
      _statusMessage = 'Data changed. Review data again before running an analysis.';
    });
  }

  bool _isAnalyzing = false;
  double _analysisProgress = 0.0;
  String _progressStatus = '';
  String _statusMessage = '';
  final List<String> _consoleLogs = [];

  // Inspected Metadata
  Map<String, dynamic>? _inspectionData;
  String? _selectedGroupCol;
  String? _selectedSubgroupCol;
  String? _selectedSubjectIdCol;
  final Set<String> _selectedCovariates = {};
  final Set<String> _selectedMetrics = {};

  // Modelling preferences
  String _channelScope = 'roi';
  String _preferredModel = 'auto'; // 'auto', 'lmm', 'glm'
  String _posthocMethod = 'fdr'; // 'fdr', 'tukey', 'bonferroni'
  String _reportFormat = 'both'; // 'both', 'docx', 'pdf'
  final TextEditingController _excludeChannelsController =
      TextEditingController();
  final TextEditingController _includeChannelsController =
      TextEditingController();

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
  final TextEditingController _permCountCtrl = TextEditingController(text: '1000');
  bool _includeInteractions = true;
  StatsPlotLayoutConfig _plotConfig = const StatsPlotLayoutConfig();
  Map<String, dynamic>? _dartAnalysisResults;
  String? _selectedDartMetric;
  int _dartResultTab = 0;

  @override
  void initState() {
    super.initState();
    if (widget.initialCsvPath != null && widget.initialCsvPath!.isNotEmpty) {
      _csvPathController.text = widget.initialCsvPath!;
      WidgetsBinding.instance.addPostFrameCallback((_) => _inspectCsv());
    }
    if (widget.initialMetadataPath != null) {
      _metadataPathController.text = widget.initialMetadataPath!;
    }
  }

  @override
  void dispose() {
    _csvPathController.dispose();
    _metadataPathController.dispose();
    _metadataKeyController.dispose();
    _excludeChannelsController.dispose();
    _includeChannelsController.dispose();
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

  static Future<String> _resolveGroupStatsScript() async {
    final currentDir = Directory.current.path;
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final sep = Platform.pathSeparator;
    final candidates = [
      '$exeDir/../Frameworks/App.framework/Resources/flutter_assets/assets/group_stats.py',
      '$exeDir/data/flutter_assets/assets/group_stats.py',
      '$currentDir${sep}assets${sep}group_stats.py',
      '$currentDir${sep}backend${sep}group_stats.py',
      '$currentDir$sep..${sep}backend${sep}group_stats.py',
      '$exeDir${sep}backend${sep}group_stats.py',
      '$exeDir$sep..${sep}Resources${sep}backend${sep}group_stats.py',
      '$exeDir$sep..${sep}Resources${sep}group_stats.py',
      '$exeDir$sep..${sep}lib${sep}ccseegstudio${sep}backend${sep}group_stats.py',
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }

    try {
      final data = await rootBundle.load('assets/group_stats.py');
      final tempFile = File(
        '${(await _runtimeDirectory).path}${Platform.pathSeparator}group_stats.py',
      );
      await tempFile.writeAsBytes(data.buffer.asUint8List());
      return tempFile.path;
    } catch (_) {}

    throw StateError('group_stats.py not found in app bundle or workspace');
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
        if (entry is File && entry.path.endsWith('_conditions_group_input.csv')) erpTables.add(entry.path);
      }
    }
    if (erpTables.isNotEmpty) {
      String? selected = erpTables.first;
      if (erpTables.length > 1 && mounted) {
        selected = await showDialog<String>(context: context, builder: (ctx) => SimpleDialog(
          title: const Text('Choose an ERP measurement table'),
          children: [for (final table in erpTables) SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, table),
            child: Text(File(table).uri.pathSegments.last),
          )],
        ));
      }
      if (selected == null || !mounted) return;
      setState(() => _csvPathController.text = selected!);
      await _inspectCsv();
      return;
    }
    final files = <String>[];
    await for (final entry in Directory(path).list(followLinks: false)) {
      if (entry is File && entry.path.endsWith('.features.csv')) files.add(entry.path);
    }
    files.sort();
    if (files.isEmpty) {
      _showSnack('No ERP measurement tables or recording feature CSVs found. Choose the saved analysis folder, or select a measurement CSV directly.');
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

  Future<void> _inferMetadata() async {
    final file = File(_csvPathController.text.trim());
    if (!file.existsSync()) {
      _showSnack('Select a feature CSV first.');
      return;
    }
    final names = <String>{};
    var index = -1;
    await for (final line
        in file
            .openRead()
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
      final fields = splitFeatureCsvLine(line);
      if (index < 0) {
        index = fields.indexOf('filename');
        if (index < 0) {
          _showSnack('This CSV needs a filename column.');
          return;
        }
      } else if (fields.length > index && fields[index].isNotEmpty) {
        names.add(fields[index]);
      }
    }
    if (!mounted) return;
    final rows = await showDialog<List<Map<String, String>>>(context: context,
      builder: (_) => FilenameMetadataDialog(names: names.toList()));
    if (rows == null || !mounted) return;
    final runtime = await _runtimeDirectory;
    final path = '${runtime.path}/reviewed_filename_labels.csv';
    final reviewed = [for (final row in rows) <String, String>{
      for (final entry in row.entries) if (entry.key != 'Subject') entry.key: entry.value,
      'participant_id': row['Subject'] ?? '',
    }];
    await File(path).writeAsString(filenameMetadataCsv(reviewed));
    if (!mounted) return;
    setState(() {
      _metadataPathController.text = path;
      _metadataKeyController.text = 'filename';
    });
    await _inspectCsv();
  }

  Future<void> _pickMetadataFile() async {
    final result = await pickFilteredFiles(
      context,
      type: FileType.custom,
      allowedExtensions: ['csv', 'xlsx'],
      dialogTitle: 'Select Metadata Table (Optional)',
    );
    if (result != null && result.files.single.path != null) {
      setState(() {
        _metadataPathController.text = result.files.single.path!;
      });
      await _inspectCsv();
    }
  }

  Future<void> _inspectCsv() async {
    final csvPath = _csvPathController.text.trim();
    if (csvPath.isEmpty || !File(csvPath).existsSync()) {
      _showSnack('Please select a valid CSV file first.');
      return;
    }

    setState(() {
      _isInspecting = true;
      _statusMessage = 'Checking participants, groups and measurements…';
      _inspectionData = null;
      _dartInspection = null;
      _analysisResults = null;
      _dartAnalysisResults = null;
      _pythonReady = false;
      _selectedMetrics.clear();
      _selectedGroupCol = null;
      _selectedSubgroupCol = 'None';
      _selectedSubjectIdCol = null;
    });

    try {
      final dartInsp = await inspectGroupDatasetInWorker(
        csvPath, _metadataPathController.text.trim(), _metadataKeyController.text.trim(),
      );
      if (!mounted) return;
      _applyDartInspection(dartInsp);

      final python = await _findPythonExecutable();
      if (python == null) {
        setState(() {
          _statusMessage =
              'Dataset loaded (Pure-Dart engine): ${dartInsp['row_count']} rows, ${(dartInsp['factor_columns'] as List).length} factor(s).';
        });
        return;
      }
      final script = await _resolveGroupStatsScript();

      final args = [script, '--csv', csvPath, '--inspect-only'];
      if (_metadataPathController.text.trim().isNotEmpty) {
        args.addAll(['--metadata-csv', await prepareGroupMetadataForPython(_metadataPathController.text.trim(), await _runtimeDirectory)]);
      }
      if (_metadataKeyController.text.trim().isNotEmpty) {
        args.addAll(['--metadata-key', _metadataKeyController.text.trim()]);
      }

      final res = await Process.run(
        python,
        args,
        environment: {'MPLCONFIGDIR': '${(await _runtimeDirectory).path}/mpl'},
      );
      if (!mounted) return;
      if (res.exitCode != 0) {
        throw StateError('Inspection failed: ${res.stderr}');
      }

      final jsonMap = jsonDecode(res.stdout as String) as Map<String, dynamic>;
      setState(() {
        _pythonReady = true;
        _inspectionData = jsonMap;
        _selectedGroupCol = jsonMap['group_col'] as String?;
        _selectedSubgroupCol = jsonMap['subgroup_col'] as String? ?? 'None';
        _selectedSubjectIdCol = jsonMap['subject_id'] as String?;
        _selectedCovariates.clear();
        if (jsonMap['has_composite_roi'] == true ||
            (jsonMap['channel_count'] as num? ?? 0) <= 1) {
          _channelScope = 'all';
        }
        // Covariates are an explicit design choice, not an automatic default.

        _selectedMetrics.clear();
        // Default selection: priority metrics
        final prioritized = ['Alpha_PSD', 'Alpha_Irasa', 'Alpha_FOOOF'];
        final availMetrics = (jsonMap['metric_columns'] as List<dynamic>? ?? [])
            .cast<String>();
        for (final m in prioritized) {
          if (availMetrics.contains(m)) {
            _selectedMetrics.add(m);
            break;
          }
        }
        if (_selectedMetrics.isEmpty) {
          _selectedMetrics.addAll(availMetrics.take(1));
        }

        _statusMessage =
            'Ready: ${jsonMap['recording_count']} recordings from ${jsonMap['unique_subjects']} participants. Review the group counts below.';
      });
    } catch (e) {
      if (!mounted) return;
      if (_dartInspection == null) _showSnack('Error inspecting file: $e');
      setState(() {
        _consoleLogs.add('$e');
        _statusMessage = _dartInspection != null
            ? 'Data loaded. Standard reports are unavailable in this Python environment. Choose permutation analysis, or see the activity log for details.'
            : 'Data could not be loaded: $e';
      });
    } finally {
      if (mounted) setState(() { _isInspecting = false; });
    }
  }

  void _applyDartInspection(Map<String, dynamic> insp) {
    final factorCols = (insp['factor_columns'] as List? ?? []).cast<String>();
    final metricCols = (insp['metric_columns'] as List? ?? []).cast<String>();
    final subjCol = insp['detected_subject_col'] as String?;
    final rawLevels = (insp['factor_levels'] as Map<String, dynamic>? ?? {});

    final nonSubjFactors = factorCols.where((f) {
      if (f == subjCol || const {'subjid', 'subject', 'subject_id', 'participant_id', 'sl.no.', 'sno', 'index', 'epoch', 'epoch_label', 'bin', 'bin_idx'}.contains(f.toLowerCase())) return false;
      final fl = f.toLowerCase();
      if (const {'filename', 'file', 'source_file', 'source_path', 'path'}
          .contains(fl)) {
        return false;
      }
      final lvls = rawLevels[f] as List? ?? const [];
      return lvls.length >= 2;
    }).toList();

    setState(() {
      _dartInspection = insp;
      _dartFactors
        ..clear()
        ..addAll(nonSubjFactors.where((f) => const {'group', 'condition', 'session', 'sessn'}.contains(f.toLowerCase())));
      if (nonSubjFactors.any((f) => f.toLowerCase() == 'session') && nonSubjFactors.any((f) => f.toLowerCase() == 'condition')) _usePermutation = true;
      _dartExcludedLevels.clear();
      _dartLevelOrder.clear();
      _selectedSubjectIdCol = subjCol;
      _selectedSubgroupCol = nonSubjFactors.where((f) => const {'condition', 'epoch_condition', 'session'}.contains(f.toLowerCase())).firstOrNull ?? 'None';
      if (_selectedGroupCol == null && nonSubjFactors.isNotEmpty) {
        _selectedGroupCol = nonSubjFactors.where((f) => const {'group', 'cohort', 'arm'}.contains(f.toLowerCase())).firstOrNull ?? nonSubjFactors.first;
      }
      if (_selectedMetrics.isEmpty && metricCols.isNotEmpty) {
        _selectedMetrics.add(metricCols.first);
      }
      _inspectionData = {
        'total_rows': insp['row_count'],
        'unique_subjects': ((insp['factor_levels'] as Map?)?[subjCol] as List?)?.length ?? 0,
        'categorical_columns': nonSubjFactors,
        'subject_candidates': factorCols,
        'metric_columns': metricCols,
        'covariates': <String>[],
        'channel_count': ((insp['factor_levels'] as Map?)?['Chan'] as List?)?.length ?? 0,
        'recording_count': ((insp['factor_levels'] as Map?)?['filename'] as List?)?.length ?? 0,
      };

      // Smart default plot role assignment:
      // e.g. X: condition/electrode, Lines: group, Facet Col: condition/event
      String? pick(List<String> candidates) => nonSubjFactors
          .where((f) => candidates.any((c) => f.toLowerCase().contains(c)))
          .firstOrNull;
      final seriesF = pick(['group', 'arm']) ?? nonSubjFactors.firstOrNull;
      final xF = pick(['electrode', 'channel', 'roi', 'condition', 'session']) ??
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

  Future<void> _runDartPermutationAnalysis() async {
    final insp = _dartInspection;
    if (!_groupsReady) { _showSnack('Review missing group labels in Data & groups first.'); return; }
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
      _progressStatus = 'Running Permutation GLM / LMM…';
      _statusMessage = 'Running N-way permutation models in isolate…';
    });
    try {
      final headers = (insp['headers'] as List).cast<String>();
      final rows = (insp['rows'] as List)
          .map((r) => (r as List).map((e) => '$e').toList())
          .toList();
      final factors = List<String>.from(_dartFactors);
      final metrics = _selectedMetrics.toList();
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
        for (final e in _dartLevelOrder.entries) e.key: List<String>.from(e.value),
      };
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
      };

      final res = await runDartPermutationsInWorker(payload);
      if (!mounted) return;
      if (res.containsKey('error')) {
        _showSnack('${res['error']}');
        return;
      }
      final resultsList = (res['results'] as List? ?? []).cast<Map<String, dynamic>>();
      setState(() {
        _dartAnalysisResults = res;
        _workflowStep = 2;
        _selectedDartMetric = resultsList.isNotEmpty
            ? resultsList.first['metric'] as String?
            : null;
        _dartResultTab = 0;
        _statusMessage =
            'Permutation GLM / LMM complete (${resultsList.length} metric(s), $nPerm permutations).';
      });
    } catch (e) {
      _showSnack('Permutation analysis failed: $e');
    } finally {
      if (mounted) setState(() => _isAnalyzing = false);
    }
  }

  Future<void> _runAnalysis() async {
    if (!_groupsReady || !_pythonReady) { _showSnack('Review data and missing group labels before running.'); return; }
    final csvPath = _csvPathController.text.trim();
    if (csvPath.isEmpty || !File(csvPath).existsSync()) {
      _showSnack('Please select a valid CSV file.');
      return;
    }
    if (_selectedGroupCol == null || _selectedGroupCol!.isEmpty) {
      _showSnack('Please select a primary grouping factor.');
      return;
    }
    if (_selectedMetrics.isEmpty) {
      _showSnack('Please select at least one sleep metric to analyze.');
      return;
    }

    setState(() {
      _isAnalyzing = true;
      _analysisProgress = 0.0;
      _progressStatus = 'Initializing statistical models…';
      _statusMessage = 'Running group statistical analysis…';
      _consoleLogs.clear();
    });

    try {
      final python = await _findPythonExecutable();
      if (python == null) {
        throw StateError('Python 3 environment not found.');
      }
      final script = await _resolveGroupStatsScript();

      final args = [
        script,
        '--csv',
        csvPath,
        '--group',
        _selectedGroupCol!,
        if (_selectedSubgroupCol != null && _selectedSubgroupCol != 'None') ...[
          '--subgroup',
          _selectedSubgroupCol!,
        ],
        if (_selectedSubjectIdCol != null) ...[
          '--subject-id',
          _selectedSubjectIdCol!,
        ],
        if (_selectedCovariates.isNotEmpty) ...[
          '--covariates',
          _selectedCovariates.join(','),
        ],
        '--channel',
        _channelScope,
        if (_excludeChannelsController.text.trim().isNotEmpty) ...[
          '--exclude-channels',
          _excludeChannelsController.text.trim(),
        ],
        if (_includeChannelsController.text.trim().isNotEmpty) ...[
          '--include-channels',
          _includeChannelsController.text.trim(),
        ],
        '--metrics',
        _selectedMetrics.join(','),
        '--model',
        _preferredModel,
        '--posthoc',
        _posthocMethod,
        '--report-format',
        _reportFormat,
      ];
      if (_metadataPathController.text.trim().isNotEmpty) {
        args.addAll(['--metadata-csv', await prepareGroupMetadataForPython(_metadataPathController.text.trim(), await _runtimeDirectory)]);
      }
      if (_metadataKeyController.text.trim().isNotEmpty) {
        args.addAll(['--metadata-key', _metadataKeyController.text.trim()]);
      }
      final exclMap = <String, List<String>>{
        for (final e in _dartExcludedLevels.entries)
          if (e.value.isNotEmpty) e.key: e.value.toList(),
      };
      if (exclMap.isNotEmpty) {
        args.addAll(['--exclude-levels', jsonEncode(exclMap)]);
      }

      final process = await Process.start(
        python,
        args,
        environment: {'MPLCONFIGDIR': '${(await _runtimeDirectory).path}/mpl'},
      );

      final stdoutBuffer = StringBuffer();
      final stderrBuffer = StringBuffer();

      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            stdoutBuffer.writeln(line);
            setState(() {
              _consoleLogs.add(line);
              if (_consoleLogs.length > 50) _consoleLogs.removeAt(0);
            });
          });

      process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            stderrBuffer.writeln(line);
            if (line.startsWith('PROGRESS ')) {
              final rest = line.substring(9).trim();
              final spIdx = rest.indexOf(' ');
              if (spIdx > 0) {
                final frac = double.tryParse(rest.substring(0, spIdx));
                final msg = rest.substring(spIdx + 1).trim();
                if (frac != null) {
                  setState(() {
                    _analysisProgress = frac.clamp(0.0, 1.0);
                    _progressStatus = msg;
                  });
                }
              }
            }
            setState(() {
              _consoleLogs.add('[stderr] $line');
              if (_consoleLogs.length > 50) _consoleLogs.removeAt(0);
            });
          });

      final exitCode = await process.exitCode;
      if (exitCode != 0) {
        throw StateError(
          'Analysis returned exit code $exitCode:\n${stderrBuffer.toString()}',
        );
      }

      final outStr = stdoutBuffer.toString();
      final jsonMap = jsonDecode(outStr) as Map<String, dynamic>;

      setState(() {
        _analysisResults = jsonMap;
        _workflowStep = 2;
        final resList = jsonMap['results'] as List<dynamic>? ?? [];
        if (resList.isNotEmpty) {
          _selectedResultMetric =
              (resList.first as Map<String, dynamic>)['metric'] as String?;
        }
        _statusMessage =
            'Analysis complete. Open Results to see plots, tables and available reports.';
      });
    } catch (e) {
      _showSnack('Analysis failed: $e');
      setState(() {
        _statusMessage = 'Analysis failed: $e';
      });
    } finally {
      setState(() {
        _isAnalyzing = false;
      });
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
      data: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFF0B1120),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF38BDF8),
          brightness: Brightness.dark,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF0F172A),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF334155)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFF334155)),
          ),
        ),
      ),
      child: Container(
        color: const Color(0xFF0B1120),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
          _buildHeaderCard(),
          const SizedBox(height: 12),
          Wrap(spacing: 8, children: [
            for (var step = 0; step < 3; step++) ChoiceChip(
              label: Text(const ['1. Data & groups', '2. Design & run', '3. Results'][step]),
              selected: _workflowStep == step,
              onSelected: _isInspecting || _isAnalyzing || (step > 0 && _inspectionData == null) ? null
                  : (_) => setState(() => _workflowStep = step),
            ),
          ]),
          const SizedBox(height: 12),
          if (_workflowStep == 0) ...[
            _buildDataSourceCard(),
            if (_dartInspection != null) _buildDataReview(),
            const SizedBox(height: 12),
            Align(alignment: Alignment.centerRight, child: FilledButton.icon(
              onPressed: _inspectionData == null || _isInspecting ? null : () => setState(() => _workflowStep = 1),
              icon: const Icon(Icons.arrow_forward), label: const Text('Continue to analysis design'),
            )),
          ],
          const SizedBox(height: 12),
          if (_inspectionData != null && _workflowStep == 1) ...[
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Standard comparison + report')),
                ButtonSegment(value: true, label: Text('Several labels + interactive results')),
              ],
              selected: {_usePermutation},
              onSelectionChanged: _isAnalyzing ? null : (v) => setState(() => _usePermutation = v.first),
            ),
            const SizedBox(height: 12),
            Padding(padding: const EdgeInsets.all(12), child: Text(
              _usePermutation
                ? 'Compare ${_dartFactors.join(", ")} together. Measurements with the same $_selectedSubjectIdCol belong to the same person.'
                : 'Compare values of $_selectedGroupCol${_selectedSubgroupCol == "None" ? "" : " and $_selectedSubgroupCol"}. Rows with the same $_selectedSubjectIdCol belong to the same person.',
            )),
            if (!_groupsReady) const Padding(padding: EdgeInsets.all(12), child: Text('Some participants have no group label. Return to Data & groups to assign or exclude them before running.')),
            if (!_usePermutation) _buildConfigurationCard(),
            if (_usePermutation) Padding(
              padding: const EdgeInsets.all(12),
              child: Text('For this analysis, each participant can have multiple sessions and stimulus conditions.'),
            ),
            const SizedBox(height: 12),
            _buildMetricsSelectionCard(),
            const SizedBox(height: 12),
            if (!_usePermutation) Card(
              elevation: 0,
              color: const Color(0xFF111827),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: const Color(0xFF334155)),
              ),
              child: ExpansionTile(
                tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                initiallyExpanded:
                    !((_inspectionData?['has_composite_roi'] == true) ||
                        ((_inspectionData?['channel_count'] as num? ?? 0) <= 1)),
                leading: const Icon(Icons.sensors, size: 20, color: Color(0xFF38BDF8)),
                title: const Text(
                  'Advanced: EEG Channel Scope & Filtering',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5, color: Colors.white),
                ),
                subtitle: Text(
                  _inspectionData?['has_composite_roi'] == true
                      ? 'Composite ERP ROIs detected — keeping CSV ROI rows intact (scope: $_channelScope)'
                      : 'Channel aggregation scope: $_channelScope',
                  style: TextStyle(fontSize: 11.5, color: Colors.white70),
                ),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        DropdownButtonFormField<String>(
                          key: ValueKey('ch_scope_$_channelScope'),
                          initialValue: _channelScope,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Channel Scope & Grouping',
                            border: OutlineInputBorder(),
                            isDense: true,
                            helperMaxLines: 2,
                            helperText:
                                'ROIs groups standard 10-20 electrodes into 5 regions. All keeps derivations / composite ROIs intact. Mean averages whole scalp.',
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: 'roi',
                              child: Text(
                                'Neurophysiological ROIs (Frontal, Central, Temporal, Parietal, Occipital)',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            DropdownMenuItem(
                              value: 'mean',
                              child: Text(
                                'Global Scalp Average (1 observation per recording)',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            DropdownMenuItem(
                              value: 'all',
                              child: Text(
                                'Analyze all channels / composite ROIs as-is',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                          onChanged: (v) => setState(() => _channelScope = v ?? 'roi'),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _excludeChannelsController,
                                decoration: const InputDecoration(
                                  labelText: 'Exclude channels (optional)',
                                  hintText: 'e.g. Cz, Pz, POL \$A1 (comma separated)',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                controller: _includeChannelsController,
                                decoration: const InputDecoration(
                                  labelText: 'Include only channels (optional)',
                                  hintText: 'e.g. F3, F4, C3, C4 (comma separated)',
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (_dartInspection != null && _usePermutation) ...[
              _buildConfigurablePlotAndPreviewCard(),
              const SizedBox(height: 12),
            ],
            if (_selectedMetrics.isEmpty)
              const Padding(
                padding: EdgeInsets.only(bottom: 6),
                child: Text(
                  'Choose the subject/group fields and select outcomes above to enable Run.',
                  style: TextStyle(color: Color(0xFF475569)),
                ),
              ),
            _buildActionRunCard(),
            const SizedBox(height: 12),
          ],
          if (_workflowStep == 2 && _dartAnalysisResults == null && _analysisResults == null)
            const Padding(padding: EdgeInsets.all(16), child: Text('No results yet. Go to Design & run to choose a comparison and run the analysis.')),
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
    final participant = _selectedSubjectIdCol;
    final group = _participantGroupColumn;
    final subjectIndex = headers.indexOf(participant ?? '');
    final groupIndex = headers.indexOf(group ?? '');
    final participantsByGroup = <String, Set<String>>{};
    if (subjectIndex >= 0 && groupIndex >= 0) {
      for (final row in rows) {
        final label = '${row[groupIndex]}'.trim();
        participantsByGroup.putIfAbsent(label.isEmpty ? 'Unassigned' : label, () => {}).add('${row[subjectIndex]}');
      }
    }
    String? field(List<String> names) => headers.where((h) => names.contains(h.toLowerCase())).firstOrNull;
    final condition = field(['condition', 'epoch_condition']);
    final session = field(['session', 'sessn']);
    final fields = [if (participant != null) (participant, 'Participant (person)'), if (group != null) (group, 'Participant group (cohort)'), if (session != null) (session, 'Session (visit)'), if (condition != null) (condition, 'Condition (stimulus / task)')];
    String value(List row, String? col) { final i = headers.indexOf(col ?? ''); return i >= 0 && i < row.length ? '${row[i]}' : '—'; }
    return Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(
      crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('What the app found — and where it came from', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text('${(levels[participant] as List? ?? []).length} people · ${insp['row_count']} measurement rows. Each person can have several sessions and conditions.'),
        const SizedBox(height: 12),
        for (final entry in fields) Padding(padding: const EdgeInsets.only(bottom: 10), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(entry.$2, style: const TextStyle(fontWeight: FontWeight.w600)),
          Text('Values: ${(levels[entry.$1] as List? ?? []).take(8).join(", ")}${(levels[entry.$1] as List? ?? []).length > 8 ? " …" : ""}'),
          Text('Source: ${sources[entry.$1] ?? "Measurement table · ${entry.$1}"}', style: const TextStyle(fontSize: 12)),
        ])),
        if (group == null) ...[
          const Text('No participant cohorts have been assigned. Freq, Rare and Distr are stimulus conditions — they are not groups of people.'),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            OutlinedButton.icon(onPressed: _pickMetadataFile, icon: const Icon(Icons.table_chart_outlined), label: const Text('Add participant group file…')),
            TextButton(onPressed: () => setState(() => _workflowStep = 1), child: const Text('Continue with conditions / sessions only')),
          ]),
        ] else Text('People per group: ${participantsByGroup.entries.map((e) => "${e.key}: ${e.value.length}").join(" · ")}'),
        if (_unassignedGroupLabels.isNotEmpty) ...[
          Text('No group label for: ${participantsByGroup.entries.where((e) => _unassignedGroupLabels.contains(e.key)).expand((e) => e.value).join(", ")}. Add these people to your group file or exclude them.'),
          CheckboxListTile(contentPadding: EdgeInsets.zero,
            title: const Text('Exclude participants without group labels from this analysis'),
            value: _groupsReady, onChanged: (v) => _setExcludeUnassigned(v ?? false)),
        ],
        ExpansionTile(title: const Text('Preview recording → person → session → condition → group'), children: [
          SingleChildScrollView(scrollDirection: Axis.horizontal, child: DataTable(
            columns: const [DataColumn(label: Text('Recording')), DataColumn(label: Text('Person')), DataColumn(label: Text('Session')), DataColumn(label: Text('Condition')), DataColumn(label: Text('Group'))],
            rows: [for (final row in rows.take(12)) DataRow(cells: [
              DataCell(Tooltip(message: value(row, 'filename'), child: Text(filenameBasename(value(row, 'filename'))))),
              DataCell(Text(value(row, participant))), DataCell(Text(value(row, session))), DataCell(Text(value(row, condition))), DataCell(Text(value(row, group))),
            ])],
          )),
        ]),
      ],
    )));
  }

  Widget _buildHeaderCard() {
    return Card(
      elevation: 0,
      color: const Color(0xFF111827),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: const Color(0xFF334155)),
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
                    style: TextStyle(fontSize: 12, color: Colors.white70),
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
      color: const Color(0xFF111827),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: const Color(0xFF334155)),
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
            const Text('Choose a saved analysis folder or a measurement CSV. For ERP statistics, the measurement table is enough; waveform files do not need to be loaded. Add a group file with one row per participant when group labels are missing.'),
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
                            color: Colors.white,
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
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _isAnalyzing || _isInspecting
                    ? null
                    : _inferMetadata,
                icon: const Icon(Icons.auto_fix_high),
                label: const Text('Identify participants & sessions from filenames…'),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _metadataPathController,
                    enabled: !_isInspecting && !_isAnalyzing,
                    onChanged: (_) => _invalidateInspection(),
                    decoration: InputDecoration(
                      labelText: 'Participant groups (Excel or CSV, optional)',
                      hintText:
                          'Select optional metadata (.csv, .xlsx) to merge demographic/group factors',
                      border: const OutlineInputBorder(),
                      isDense: true,
                      prefixIcon: const Icon(Icons.badge_outlined),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.folder_open),
                        onPressed: _pickMetadataFile,
                        tooltip: 'Browse Metadata',
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (_metadataPathController.text.isNotEmpty) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _metadataKeyController,
                    enabled: !_isInspecting && !_isAnalyzing,
                    onChanged: (_) => _invalidateInspection(),
                decoration: const InputDecoration(
                  labelText: 'Participant ID column in group file (optional)',
                  hintText: 'filename or Subject',
                  helperText:
                      'Leave blank to detect subject / participant_id automatically. Then press Review data.',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
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
                  color: Colors.white70,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildConfigurationCard() {
    final catCols =
        (_inspectionData?['categorical_columns'] as List<dynamic>? ?? [])
            .cast<String>().where((c) => (_dartInspection?['factor_levels']?[c] as List? ?? []).length >= 2 && !const {'filename', 'file', 'subjid', 'subject', 'subject_id', 'participant_id', 'sl.no.', 'epoch', 'epoch_label'}.contains(c.toLowerCase())).toList();
    final allCols = [
      ?_selectedGroupCol,
      ...catCols.where((c) => c != _selectedGroupCol),
    ];
    final subgrpOptions = {'None', ?_selectedSubgroupCol, ...catCols}.toList();
    final candidateSubj =
        (_inspectionData?['categorical_columns'] as List<dynamic>? ?? [])
            .cast<String>();

    return Card(
      elevation: 0,
      color: const Color(0xFF111827),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: const Color(0xFF334155)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.tune, size: 20, color: Color(0xFF38BDF8)),
                SizedBox(width: 8),
                Text(
                  'What do you want to compare?',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                // Primary Grouping Factor
                Expanded(
                  child: DropdownButtonFormField<String>(
                    key: ValueKey('grp_col_$_selectedGroupCol'),
                    initialValue: _selectedGroupCol,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Main comparison',
                      border: OutlineInputBorder(),
                      isDense: true,
                      helperText: 'Choose a cohort, condition or session to compare',
                    ),
                    items: [
                      for (final col in allCols)
                        DropdownMenuItem(
                          value: col,
                          child: Text(col, overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: (val) => setState(() => _selectedGroupCol = val),
                  ),
                ),
                const SizedBox(width: 14),
                // Subgroup / Within-Subject Factor
                Expanded(
                  child: DropdownButtonFormField<String>(
                    key: ValueKey('subgrp_col_$_selectedSubgroupCol'),
                    initialValue: _selectedSubgroupCol ?? 'None',
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Compare repeated measurements',
                      border: OutlineInputBorder(),
                      isDense: true,
                      helperText: 'For example: stimulus Condition or Session',
                    ),
                    items: [
                      for (final col in subgrpOptions)
                        DropdownMenuItem(
                          value: col,
                          child: Text(col, overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: (val) =>
                        setState(() => _selectedSubgroupCol = val),
                  ),
                ),
                const SizedBox(width: 14),
                // Subject ID Column
                Expanded(
                  child: DropdownButtonFormField<String>(
                    key: ValueKey('subj_col_$_selectedSubjectIdCol'),
                    initialValue: _selectedSubjectIdCol,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Participant ID',
                      border: OutlineInputBorder(),
                      isDense: true,
                      helperText: 'The same participant keeps the same ID across sessions',
                    ),
                    items: [
                      if (_selectedSubjectIdCol != null &&
                          !candidateSubj.contains(_selectedSubjectIdCol))
                        DropdownMenuItem(
                          value: _selectedSubjectIdCol,
                          child: Text(_selectedSubjectIdCol!, overflow: TextOverflow.ellipsis),
                        ),
                      for (final col in candidateSubj)
                        DropdownMenuItem(
                          value: col,
                          child: Text(col, overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: (val) =>
                        setState(() => _selectedSubjectIdCol = val),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            // Covariates selection
            const Text(
              'Adjust for other variables (optional):',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final cov
                    in (_inspectionData?['covariates'] as List<dynamic>? ?? [])
                        .cast<String>())
                  FilterChip(
                    label: Text(cov),
                    selected: _selectedCovariates.contains(cov),
                    onSelected: (sel) {
                      setState(() {
                        if (sel) {
                          _selectedCovariates.add(cov);
                        } else {
                          _selectedCovariates.remove(cov);
                        }
                      });
                    },
                  ),
              ],
            ),
            const SizedBox(height: 14),
            // Model Approach & Report Preferences
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _preferredModel,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Model (Auto is a starting point)',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'auto',
                        child: Text(
                          'Auto: choose from the data',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'lmm',
                        child: Text(
                          'Mixed-Design ANOVA / LMM (Subject Random Intercept)',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'glm',
                        child: Text(
                          'General Linear Model (GLM / ANOVA Type II)',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                    onChanged: (v) =>
                        setState(() => _preferredModel = v ?? 'auto'),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _posthocMethod,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Correction for multiple comparisons',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'fdr',
                        child: Text('Benjamini-Hochberg FDR (Recommended)', overflow: TextOverflow.ellipsis),
                      ),

                      DropdownMenuItem(
                        value: 'bonferroni',
                        child: Text('Bonferroni (Strict)', overflow: TextOverflow.ellipsis),
                      ),
                    ],
                    onChanged: (v) =>
                        setState(() => _posthocMethod = v ?? 'fdr'),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _reportFormat,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Report format',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'both',
                        child: Text('Both Word (.docx) & PDF (.pdf)', overflow: TextOverflow.ellipsis),
                      ),
                      DropdownMenuItem(
                        value: 'docx',
                        child: Text('Microsoft Word Document (.docx)', overflow: TextOverflow.ellipsis),
                      ),
                      DropdownMenuItem(
                        value: 'pdf',
                        child: Text('Portable Document Format (.pdf)', overflow: TextOverflow.ellipsis),
                      ),
                    ],
                    onChanged: (v) =>
                        setState(() => _reportFormat = v ?? 'both'),
                  ),
                ),
              ],
            ),
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
      color: const Color(0xFF111827),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: const Color(0xFF334155)),
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
                color: const Color(0xFF0F172A),
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
                        label: Text(groupMetricLabel(m), style: const TextStyle(fontSize: 11)),
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
    final allFactorCols = (insp['factor_columns'] as List? ?? []).cast<String>().where((f) {
      if (const {'filename', 'file', 'path', 'subjid', 'subject', 'subject_id', 'participant_id', 'sl.no.', 'epoch', 'epoch_label'}.contains(f.toLowerCase())) return false;
      return ((insp['factor_levels'] as Map)[f] as List? ?? []).length >= 2;
    }).toList();
    final rawLevels =
        (insp['factor_levels'] as Map<String, dynamic>? ?? {});

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
                child: Text(f, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: onChanged,
        ),
      );
    }

    return Card(
      elevation: 0,
      color: const Color(0xFF111827),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: const Color(0xFF334155)),
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
                    'Choose what to compare',
                    style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
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
                const SizedBox(width: 10),
                FilterChip(
                  label: const Text('Interactions', style: TextStyle(fontSize: 11.5)),
                  selected: _includeInteractions,
                  onSelected: (v) => setState(() => _includeInteractions = v),
                ),
              ],
            ),
            const SizedBox(height: 10),
            const Text(
              'What should the analysis compare? A factor is one label that can change: cohort between people, or session / condition within the same person.',
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
                        '$f: ${(rawLevels[f] as List? ?? []).take(4).join(", ")}',
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
            const SizedBox(height: 8),
            for (final f in _dartFactors) Text('$f ← ${(_dartInspection?['column_sources'] as Map? ?? {})[f] ?? "measurement table"}', style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 12),
            ExpansionTile(
              title: const Text('Optional: plot layout and level filters'),
              subtitle: const Text('Change axes, panels, level order or exclusions'),
              children: [
            const Text(
              'Plot Role Configuration (Lines, X-Axis Points, Subplot Columns/Rows):',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                roleDropdown(
                  'X-Axis (Points)',
                  _plotConfig.xFactor,
                  (v) => setState(
                    () => _plotConfig = v == null || v == 'None'
                        ? _plotConfig.copyWith(clearX: true)
                        : _plotConfig.copyWith(xFactor: v),
                  ),
                ),
                const SizedBox(width: 8),
                roleDropdown(
                  'Lines / Hue (Series)',
                  _plotConfig.seriesFactor,
                  (v) => setState(
                    () => _plotConfig = v == null || v == 'None'
                        ? _plotConfig.copyWith(clearSeries: true)
                        : _plotConfig.copyWith(seriesFactor: v),
                  ),
                ),
                const SizedBox(width: 8),
                roleDropdown(
                  'Subplot Columns',
                  _plotConfig.facetColFactor,
                  (v) => setState(
                    () => _plotConfig = v == null || v == 'None'
                        ? _plotConfig.copyWith(clearFacetCol: true)
                        : _plotConfig.copyWith(facetColFactor: v),
                  ),
                ),
                const SizedBox(width: 8),
                roleDropdown(
                  'Subplot Rows',
                  _plotConfig.facetRowFactor,
                  (v) => setState(
                    () => _plotConfig = v == null || v == 'None'
                        ? _plotConfig.copyWith(clearFacetRow: true)
                        : _plotConfig.copyWith(facetRowFactor: v),
                  ),
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
                      label: Text('Line + Error', style: TextStyle(fontSize: 11)),
                    ),
                    ButtonSegment(
                      value: StatsPlotType.bar,
                      label: Text('Bar + Error', style: TextStyle(fontSize: 11)),
                    ),
                    ButtonSegment(
                      value: StatsPlotType.boxplot,
                      label: Text('Box Plot', style: TextStyle(fontSize: 11)),
                    ),
                  ],
                  selected: {_plotConfig.plotType},
                  onSelectionChanged: (s) => setState(
                    () => _plotConfig = _plotConfig.copyWith(plotType: s.first),
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
            // Level Order & Exclusion Chips for active factors
            for (final f in _dartFactors) ...[
              Builder(
                builder: (context) {
                  final raw = (rawLevels[f] as List? ?? []).map((e) => '$e').toList();
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
                          '$f order/filter:',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (raw.any((l) => l.toLowerCase() == 'unknown'))
                          ActionChip(
                            avatar: const Icon(Icons.filter_alt_off, size: 14),
                            label: Text(
                              raw
                                      .where((l) => l.toLowerCase() == 'unknown')
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
                                  .where((l) => l.toLowerCase() == 'unknown')
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
                              ordered[i],
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
                            deleteIcon: const Icon(Icons.arrow_forward, size: 13),
                            deleteButtonTooltipMessage: 'Move level right',
                          ),
                      ],
                    ),
                  );
                },
              ),
            ],
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
    final levelsMap = <String, List<String>>{};
    final rawLevels =
        (active['factor_levels'] as Map<String, dynamic>? ?? {});
    for (final e in rawLevels.entries) {
      levelsMap[e.key] = (e.value as List).map((x) => '$x').toList();
    }
    final effects = (active['model_effects'] as List? ?? [])
        .cast<Map<String, dynamic>>();
    final posthocs = (active['posthoc'] as List? ?? [])
        .cast<Map<String, dynamic>>();

    return Card(
      elevation: 0,
      color: const Color(0xFF111827),
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
                const Icon(Icons.auto_graph, size: 20, color: Color(0xFF0D9488)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Permutation GLM / LMM Results · ${active['model_type']} (N=${active['n_obs']}, Subjects=${active['n_subjects']})',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
                SizedBox(
                  width: 220,
                  child: DropdownButtonFormField<String>(
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
                          child: Text(r['metric'] as String),
                        ),
                    ],
                    onChanged: (v) => setState(() => _selectedDartMetric = v),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text('${groupMetricLabel("${active['metric']}")} · ${active['n_subjects']} participants · ${active['n_obs']} measurement rows'),
            const SizedBox(height: 6),
            const Text('Plot shows the included groups. Effects tested asks whether each factor or interaction differs; Pairwise comparisons shows which levels differ. Read the corrected p-values when comparing several levels.'),
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
                metricName: '${active['metric']}',
                cellDescriptives:
                    (active['cell_descriptives'] as Map<String, dynamic>? ??
                        {}),
                activeFactors: (active['factors'] as List? ?? []).cast<String>(),
                isDummyPreview: false,
                height: 380,
              )
            else if (_dartResultTab == 1)
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columns: const [
                    DataColumn(label: Text('Term')),
                    DataColumn(label: Text('F')),
                    DataColumn(label: Text('df')),
                    DataColumn(label: Text('p (param)')),
                    DataColumn(label: Text('p (perm)')),
                    DataColumn(label: Text('η²')),
                  ],
                  rows: [
                    for (final eff in effects)
                      DataRow(
                        cells: [
                          DataCell(Text('${eff['term']}')),
                          DataCell(
                            Text(
                              (eff['f_stat'] as num).toStringAsFixed(3),
                            ),
                          ),
                          DataCell(
                            Text('${eff['df_num']}, ${eff['df_denom']}'),
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
                              (eff['eta_sq'] as num).toStringAsFixed(3),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              )
            else
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columns: const [
                    DataColumn(label: Text('Factor')),
                    DataColumn(label: Text('Comparison')),
                    DataColumn(label: Text('Diff')),
                    DataColumn(label: Text('t')),
                    DataColumn(label: Text('p (raw)')),
                    DataColumn(label: Text('p (adj)')),
                  ],
                  rows: [
                    for (final c in posthocs)
                      DataRow(
                        cells: [
                          DataCell(Text('${c['factor']}')),
                          DataCell(
                            Text('${c['group_a']} vs ${c['group_b']}'),
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
        ),
      ),
    );
  }

  Widget _buildActionRunCard() {
    return Card(
      elevation: 0,
      color: const Color(0xFF111827),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: const Color(0xFF334155)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Row(
              children: [
                if (_usePermutation) Expanded(
                  child: FilledButton.icon(
                    onPressed: _isAnalyzing || _isInspecting || !_groupsReady || _selectedMetrics.isEmpty || _dartInspection == null
                        ? null
                        : _runDartPermutationAnalysis,
                    icon: _isAnalyzing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.auto_graph),
                    label: Text(
                      _isAnalyzing
                          ? 'Running Permutation GLM/LMM…'
                          : 'Run comparison',
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
                const SizedBox(width: 12),
                if (!_usePermutation) Expanded(
                  child: FilledButton.icon(
                    onPressed: _isAnalyzing || _isInspecting || !_pythonReady || !_groupsReady || _selectedMetrics.isEmpty ? null : _runAnalysis,
                    icon: const Icon(Icons.play_arrow),
                    label: Text(
                      _isAnalyzing
                          ? 'Running Models & Generating Report…'
                          : 'Run analysis & create report (${_selectedMetrics.length} measurements)',
                    ),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
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
                  backgroundColor: const Color(0xFF1E293B),
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
                  color: const Color(0xFF1E1E1E),
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
      color: const Color(0xFF111827),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: const Color(0xFF334155)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if ((_analysisResults!['report_warnings'] as List? ?? []).isNotEmpty) Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text('Plots and tables were saved, but some report files could not be created. ${(_analysisResults!['report_warnings'] as List).join(" ")}'),
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
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.white60,
                        ),
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
        border: Border.all(color: const Color(0xFF334155)),
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
        color: isSig ? Colors.green.shade50 : const Color(0xFF0F172A),
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
          color: isSig ? Colors.green.shade800 : Colors.white60,
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
