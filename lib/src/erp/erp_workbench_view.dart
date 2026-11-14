import 'erp_core_presets.dart';
import 'axis_controls.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../models.dart';
import '../recording_details.dart';
import '../group_statistics.dart';
import '../filtered_file_picker.dart';
import 'workbench_service.dart';
import 'workbench_figures.dart';
import 'workbench_report.dart';
import 'stim_epochs.dart' show markerListContains;
import 'task_guides.dart';
import 'protocol_tools.dart';
import 'review_workspace.dart';
import 'review_math.dart';
import 'channel_grid.dart';
import 'publication_plots.dart';

class ErpConditionConfig {
  ErpConditionConfig({
    required this.name,
    List<String>? codes,
    List<String>? savedGroups,
  }) : codes = codes != null ? List<String>.from(codes) : [],
       savedGroups = savedGroups != null ? List<String>.from(savedGroups) : [],
       nameController = TextEditingController(text: name),
       codesController = TextEditingController(text: (codes ?? []).join(', '));

  String name;
  List<String> codes;
  List<String> savedGroups;
  final TextEditingController nameController;
  final TextEditingController codesController;

  void dispose() {
    nameController.dispose();
    codesController.dispose();
  }
}

class ErpWorkbenchView extends StatefulWidget {
  const ErpWorkbenchView({
    super.key,
    this.activeRecording,
    this.config,
    this.extraFiles = const [],
    this.initialResultPath,
    this.batchMode = true,
    this.onPrepare,
    this.onOpenRecording,
    this.onOpenBatch,
    this.initialInspection,
    this.linkedReview = false,
    this.linkedOutputDirectory,
    this.stage1Builder,
    this.onRunPreprocessing,
    this.onCloseBatch,
  });
  final EegRecording? activeRecording;
  final AnalysisConfig? config;
  final List<String> extraFiles;
  final String? initialResultPath;
  final bool batchMode;
  final bool linkedReview;
  final String? linkedOutputDirectory;
  final Map<String, dynamic>? initialInspection;
  final VoidCallback? onOpenRecording;
  final VoidCallback? onPrepare, onOpenBatch;
  final Widget Function({VoidCallback? onNext})? stage1Builder;
  final Future<List<String>> Function()? onRunPreprocessing;
  final VoidCallback? onCloseBatch;
  @override
  State<ErpWorkbenchView> createState() => _ErpWorkbenchViewState();
}

class _ErpWorkbenchViewState extends State<ErpWorkbenchView>
    with SingleTickerProviderStateMixin {
  Map<String, dynamic> _axisLimits = {};

  final _service = ErpWorkbenchService();
  final _paths = <String>[];
  final _subjects = <String, String>{};
  final _profiles = <String, Map<String, dynamic>>{};
  final _limit = TextEditingController(text: '2'),
      _output = TextEditingController(),
      _bin = TextEditingController(text: '20'),
      _reject = TextEditingController(text: '0'),
      _permutations = TextEditingController(text: '1000'),
      _metadata = TextEditingController(),
      _rtMin = TextEditingController(text: '200'),
      _rtMax = TextEditingController(text: '1000'),
      _folds = TextEditingController(text: '5'),
      _shrinkage = TextEditingController(text: '0.1'),
      _lsqrTolerance = TextEditingController(text: '1e-12'),
      _lsqrIterations = TextEditingController(text: '1000');
  final _a = TextEditingController(),
      _b = TextEditingController(),
      _roi = TextEditingController(),
      _epoch0 = TextEditingController(),
      _epoch1 = TextEditingController(),
      _base0 = TextEditingController(),
      _base1 = TextEditingController(),
      _window0 = TextEditingController(),
      _window1 = TextEditingController(),
      _markerSearch = TextEditingController(),
      _componentLabel = TextEditingController();
  late final TabController _tabs;
  String
  _task = 'Auto',
  _eventSource = 'auto',
  _status =
      'Choose recordings, inspect the markers, then review the proposed analysis.',
  _component = '';
  bool _busy = false,
      _correct = true,
      _regression = false,
      _deconvolution = false,
      _decoding = false,
      _generalization = false,
      _exportTrials = false,
      _negativeUp = true,
      _significantOnly = true;
  double _progress = 0;
  double _displaySmoothing = 0;
  final _hover = ValueNotifier<double?>(null);
  final Map<String, String> _modelChannels = {}, _modelPredictors = {};
  Map<String, dynamic>? _inspection, _result, _profile;
  bool _regroupEpochs = false;
  final List<ErpConditionConfig> _conditions = [];
  final Map<String, String> _participantGroups = {};
  String _gallerySearch = '';
  final int _activeStage = 0; // 0 = All stages, 1..4 = focused modular stage
  String? _primaryPlotChannel; // null = Task ROI average, or specific channel name
  bool _showAxisLimits = false;

  // Uniform 4-Stage Batch Workspace state
  bool _batchPreprocessedInput = false;
  bool _batchSkipExisting = false;
  bool _batchTabbedView = false;
  int _batchActiveStage = 0;
  bool _batchStage1Enabled = true;
  bool _batchStage2Enabled = true;
  bool _batchStage3Enabled = true;
  bool _batchUseStage1Outputs = true;
  bool _batchShowResults = false;
  final List<String> _prepFiles = [];
  bool _erpPrepFilter = true;
  bool _erpPrepBadChannels = true;
  bool _erpPrepRereference = true;
  bool _erpPrepGedai = true;



  List<String> get _savedA =>
      _conditions.isNotEmpty ? _conditions[0].savedGroups : [];
  List<String> get _savedB =>
      _conditions.length > 1 ? _conditions[1].savedGroups : [];

  bool get _isPrepared =>
      !widget.batchMode && (widget.activeRecording?.isEpoched ?? false) ||
      _scanFiles.isNotEmpty && _scanFiles.every((f) => f['is_epoched'] == true);

  int _conditionTrialCount(ErpConditionConfig c) {
    if (_isPrepared) {
      return _scanFiles.fold<int>(
        0,
        (n, f) =>
            n +
            c.savedGroups.fold<int>(
              0,
              (sum, g) =>
                  sum + (erpMap(f['marker_counts'])[g] as num? ?? 0).toInt(),
            ),
      );
    } else {
      final codes = c.codesController.text
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      return _scanFiles.fold<int>(
        0,
        (n, f) =>
            n +
            codes.fold<int>(
              0,
              (sum, code) =>
                  sum + (erpMap(f['marker_counts'])[code] as num? ?? 0).toInt(),
            ),
      );
    }
  }

  int _savedGroupTrialCount(String group) => _scanFiles.fold<int>(
        0,
        (n, f) => n + (erpMap(f['marker_counts'])[group] as num? ?? 0).toInt(),
      );

  bool _isConditionEmpty(ErpConditionConfig c) =>
      _isPrepared
          ? (c.savedGroups.isEmpty || _conditionTrialCount(c) == 0)
          : (c.codesController.text.trim().isEmpty || _conditionTrialCount(c) == 0);

  List<ErpConditionConfig> get _emptyConditions =>
      _conditions.where(_isConditionEmpty).toList();

  List<ErpConditionConfig> get _validConditions =>
      _conditions.where((c) => !_isConditionEmpty(c)).toList();

  bool get _canRun =>
      !_busy &&
      _selectedPaths.isNotEmpty &&
      _inspection != null &&
      (widget.batchMode || _isPrepared) &&
      (!_isPrepared || _profile != null) &&
      _validConditions.isNotEmpty &&
      _timingIssue == null;
  String? get _timingIssue {
    if (!_isPrepared || _profile == null) return null;
    final lo = double.tryParse(_epoch0.text),
        hi = double.tryParse(_epoch1.text);
    final a = double.tryParse(_base0.text),
        b = double.tryParse(_base1.text),
        x = double.tryParse(_window0.text),
        y = double.tryParse(_window1.text);
    if ([lo, hi, a, b, x, y].contains(null))
      return 'Enter valid baseline and measurement times.';
    if (a! < lo! || b! > hi! || x! < lo || y! > hi || a >= b || x >= y)
      return 'Baseline or measurement window exceeds the saved trials. Adjust the window or return to Preprocess for wider epochs.';
    return null;
  }

  List<String> get _savedGroups =>
      {for (final f in _scanFiles) ...erpMap(f['marker_counts']).keys}.toList()
        ..sort();
  String? _file;
  List<Map<String, dynamic>> get _scanFiles =>
      ((_inspection?['files'] as List?) ?? []).map(erpMap).toList();
  List<Map<String, dynamic>> get _groups =>
      ((_result?['groups'] as List?) ?? []).map(erpMap).toList();
  List<Map<String, dynamic>> get _results =>
      ((_result?['files'] as List?) ?? []).map(erpMap).toList();
  String? _taskFromPath(String path) {
    for (final part in path.split(RegExp(r'[/\\]')).reversed) {
      for (final token in part.toUpperCase().split(RegExp(r'[^A-Z0-9]+'))) {
        if ([
          'N170',
          'N2PC',
          'N400',
          'MMN',
          'ERN',
          'LRP',
          'P3',
          'P300',
        ].contains(token))
          return token == 'P300'
              ? 'P3'
              : token == 'N2PC'
              ? 'N2pc'
              : token;
      }
    }
    return null;
  }

  Map<String, String> _describeRecording(Map<String, dynamic> f) {
    final path = (f['path'] as String?) ?? '';
    final fileName = path.split(RegExp(r'[/\\]')).last;
    var stem = fileName.replaceAll(
      RegExp(r'\.(edf|bdf|set|vhdr|ccserp|json|csv)$', caseSensitive: false),
      '',
    );
    stem = stem.replaceAll(
      RegExp(r'-epo_clean$|_cleaned$|_clean$', caseSensitive: false),
      '',
    );

    bool isMetaToken(String tok) {
      final lower = tok.toLowerCase();
      final isDate =
          RegExp(r'\d{2}\.\d{2}\.\d{4}|\d{4}-\d{2}-\d{2}|\d{8}').hasMatch(tok);
      final isTaskOrSession = lower.startsWith('ses') ||
          lower.startsWith('task') ||
          lower.startsWith('run') ||
          lower.startsWith('clean') ||
          lower.startsWith('raw') ||
          lower.startsWith('epo') ||
          const {
            'ern',
            'lrp',
            'mmn',
            'n170',
            'n2pc',
            'n400',
            'p3',
            'p300',
          }.contains(lower);
      return isDate || isTaskOrSession;
    }

    var subject = (f['subject'] as String?)?.trim() ?? '';
    final parts = stem.split('_').where((s) => s.isNotEmpty).toList();
    if (subject.isEmpty ||
        subject == 'unknown' ||
        RegExp(r'^\d+$').hasMatch(subject)) {
      if (parts.isNotEmpty &&
          RegExp(r'^\d+$').hasMatch(parts.first) &&
          parts.length > 1) {
        final hasNamedSubjectAfter = parts.skip(1).any((t) => !isMetaToken(t));
        if (hasNamedSubjectAfter) {
          final namedTokens = <String>[];
          for (final p in parts.skip(1)) {
            if (isMetaToken(p) && namedTokens.isNotEmpty) break;
            if (!isMetaToken(p)) {
              namedTokens.add(p);
              if (namedTokens.length >= 2) break;
            }
          }
          if (namedTokens.isNotEmpty) {
            subject = namedTokens.join('_');
          }
        } else {
          subject = 'Subj ${parts.first}';
        }
      } else if (parts.isNotEmpty) {
        final subTokens = <String>[];
        for (final p in parts) {
          if (isMetaToken(p) && subTokens.isNotEmpty) break;
          if (!isMetaToken(p)) {
            subTokens.add(p);
            if (subTokens.length >= 2) break;
          }
        }
        if (subTokens.isNotEmpty) subject = subTokens.join('_');
      }
    } else if (RegExp(r'^\d+$').hasMatch(subject)) {
      subject = 'Subj $subject';
    }
    if (subject.isEmpty) subject = 'Unknown';

    final rawSubj = subject.replaceFirst(RegExp(r'^Subj\s+'), '');
    var sessionPart = stem;
    if (sessionPart.startsWith('${rawSubj}_')) {
      sessionPart = sessionPart.substring(rawSubj.length + 1);
    } else if (sessionPart.startsWith(RegExp(r'^\d+_'))) {
      sessionPart = sessionPart.replaceFirst(RegExp(r'^\d+_'), '');
    }
    if (sessionPart.startsWith('${subject}_')) {
      sessionPart = sessionPart.substring(subject.length + 1);
    } else if (sessionPart == subject || sessionPart == rawSubj) {
      sessionPart = (f['task'] as String?) ?? 'Session 1';
    }
    sessionPart = sessionPart.replaceAll('_', ' ').replaceAll('-', ' ').trim();
    if (sessionPart.isEmpty) {
      sessionPart = (f['task'] as String?) ?? 'Session 1';
    }

    return {
      'path': path,
      'fileName': fileName,
      'stem': stem,
      'subject': subject,
      'session': sessionPart,
      'label': '$subject · $sessionPart',
    };
  }

  Widget _buildActiveRecordingIdentityCard(
    Map<String, dynamic> d,
    List<Map<String, dynamic>> current,
  ) {
    if (_file == null) {
      return Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.cyan.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            const Icon(Icons.groups, size: 18, color: Colors.cyanAccent),
            const SizedBox(width: 8),
            const Text(
              'Grand Average',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 13,
                color: Colors.cyanAccent,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              '${d['n_files'] ?? current.length} recording(s) across ${d['n_subjects'] ?? current.length} subject(s)',
              style: const TextStyle(fontSize: 12, color: Colors.white70),
            ),
            if (current.isNotEmpty) ...[
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Select any recording above to inspect individual traces.',
                  textAlign: TextAlign.right,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
                ),
              ),
            ],
          ],
        ),
      );
    }

    final activeFile = current.firstWhere(
      (f) => f['path'] == _file,
      orElse: () => current.first,
    );
    final info = _describeRecording(activeFile);
    final idx = current.indexWhere((f) => f['path'] == _file);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF131D2E),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.cyanAccent.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.cyan.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'Recording ${idx + 1} of ${current.length}',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Colors.cyanAccent,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.amber.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'Subject: ${info['subject']}',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Colors.amberAccent,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.blue.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'Session: ${info['session']}',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Colors.lightBlueAccent,
                  ),
                ),
              ),
              const Spacer(),
              FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                ),
                onPressed: () => setState(() => _file = null),
                icon: const Icon(Icons.arrow_back, size: 14),
                label: const Text('Back to Grand Average', style: TextStyle(fontSize: 11)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              const Icon(Icons.description_outlined, size: 14, color: Colors.grey),
              const SizedBox(width: 6),
              Expanded(
                child: Tooltip(
                  message: info['path'] ?? '',
                  child: Text(
                    '${info['fileName']}  ·  ${activeFile['n_a'] ?? 0} trials (${erpMap(d['profile'])['a_name'] ?? 'A'}), ${activeFile['n_b'] ?? 0} trials (${erpMap(d['profile'])['b_name'] ?? 'B'})',
                    style: const TextStyle(fontSize: 11, color: Colors.white70),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  List<String> get _selectedPaths => _paths
      .where(
        (p) =>
            !widget.batchMode ||
            _task == 'Auto' ||
            _task == 'Custom' ||
            _taskFromPath(p) == null ||
            _taskFromPath(p) == _task,
      )
      .toList();
  List<Map<String, dynamic>> get _inputs => [
    for (final p in _selectedPaths) {
      'path': p,
      'subject': _subjects[p] ?? '',
      'group': _participantGroups[_subjects[p] ?? ''] ?? '',
    },
  ];
  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 8, vsync: this);
    _restoreProtocol();
    if (widget.initialResultPath != null) {
      final result = Map<String, dynamic>.from(
        jsonDecode(File(widget.initialResultPath!).readAsStringSync()) as Map,
      );
      _result = result;
      _batchShowResults = true;
      _component = _groups.isEmpty ? '' : _groups.first['task'] as String;
      _output.text = File(widget.initialResultPath!).parent.path;
    }
    final active = widget.activeRecording;
    if (active != null && File(active.path).existsSync())
      _paths.add(active.path);
    for (final path in (widget.batchMode ? widget.extraFiles : <String>[])) {
      if ((path.toLowerCase().endsWith('.edf') ||
              path.toLowerCase().endsWith('.fif') ||
              path.toLowerCase().endsWith('.xdf') ||
              (path.toLowerCase().endsWith('.ccseeg.json') ||
                  path.toLowerCase().endsWith('.ccseeg'))) &&
          File(path).existsSync() &&
          !_paths.contains(path))
        _paths.add(path);
    }
    if (widget.initialInspection != null) {
      _inspection = widget.initialInspection;
      final profiles = _scanFiles
          .map((f) => erpMap(f['profile']))
          .where((p) => p.isNotEmpty)
          .toList();
      if (profiles.isNotEmpty) _fillProfile(profiles.first);
      _restoreProtocol();
      if (!widget.batchMode)
        _status = 'Choose saved groups A/B and review the ROI/window.';
    }
    if (_paths.isNotEmpty && widget.initialInspection == null)
      WidgetsBinding.instance.addPostFrameCallback((_) => _inspect());
    if (widget.linkedReview && widget.initialInspection != null) {
      _output.text = widget.linkedOutputDirectory ?? '';
      _inspection = widget.initialInspection;
      final p = erpMap(_scanFiles.first['profile']);
      _task = p['task'] as String? ?? 'Custom';
      _fillProfile(p);
      _regroupEpochs = false;
      _reject.text = '0';
      _status = 'Using the accepted trials and condition groups from your review.';
      if (widget.initialResultPath == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted && _canRun) _run(); });
      }
    }

  }

  @override
  void didUpdateWidget(covariant ErpWorkbenchView old) {
    super.didUpdateWidget(old);
    if (!widget.batchMode &&
        old.activeRecording?.path != widget.activeRecording?.path) {
      _paths.clear();
      _task = 'Auto';
      _regroupEpochs = false;
      _savedA.clear();
      _savedB.clear();
      _inspection = null;
      _result = null;
      _fillProfile(null);
      final active = widget.activeRecording;
      if (active != null && File(active.path).existsSync()) {
        _paths.add(active.path);
        WidgetsBinding.instance.addPostFrameCallback((_) => _inspect());
      }
    }
  }

  @override
  void dispose() {
    _service.cancel();
    for (final c in _conditions) {
      c.dispose();
    }
    for (final c in [
      _limit,
      _output,
      _bin,
      _reject,
      _permutations,
      _metadata,
      _rtMin,
      _rtMax,
      _folds,
      _shrinkage,
      _lsqrTolerance,
      _lsqrIterations,
      _a,
      _b,
      _roi,
      _epoch0,
      _epoch1,
      _base0,
      _base1,
      _window0,
      _window1,
      _markerSearch,
      _componentLabel,
    ]) {
      c.dispose();
    }
    _hover.dispose();
    _tabs.dispose();
    super.dispose();
  }

  Map<String, dynamic> _options({bool inspection = false}) {
    final options = <String, dynamic>{
      'task': _task,
      'regroup_epochs': _regroupEpochs,
      'event_source': _eventSource,
      'correct_only': _correct,
      'bin_ms': double.tryParse(_bin.text) ?? 20,
      'reject_uv': double.tryParse(_reject.text) ?? 0,
      'permutations': int.tryParse(_permutations.text) ?? 1000,
      'regression': _regression,
      'deconvolution': _deconvolution,
      'decoding': _decoding,
      'temporal_generalization': _generalization,
      'export_trial_measurements': _exportTrials,
      'trial_metadata_path': _metadata.text.trim(),
      'profile_overrides': _profiles,
      'response_min': (double.tryParse(_rtMin.text) ?? 200) / 1000,
      'response_max': (double.tryParse(_rtMax.text) ?? 1000) / 1000,
      'folds': int.tryParse(_folds.text) ?? 5,
      'decode_shrinkage': double.tryParse(_shrinkage.text) ?? 0.1,
      'lsqr_tolerance': double.tryParse(_lsqrTolerance.text) ?? 1e-12,
      'lsqr_iterations': int.tryParse(_lsqrIterations.text) ?? 1000,
    };
    if (!inspection && _profile != null) {
      final p = Map<String, dynamic>.from(_profile!);
      List<String> list(TextEditingController c) => c.text
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      double number(TextEditingController c) => double.parse(c.text) / 1000;
      p['component_name'] = _componentLabel.text.trim();
      final valid = _validConditions;
      p['conditions'] = [
        for (final c in (valid.isNotEmpty ? valid : _conditions))
          {
            'name': c.nameController.text.trim().isNotEmpty
                ? c.nameController.text.trim()
                : c.name,
            'codes': _isPrepared
                ? c.savedGroups
                : c.codesController.text
                      .split(',')
                      .map((s) => s.trim())
                      .where((s) => s.isNotEmpty)
                      .toList(),
          },
      ];
      if (valid.isNotEmpty) {
        final c0 = valid[0];
        p['a_name'] = c0.nameController.text.trim().isNotEmpty
            ? c0.nameController.text.trim()
            : c0.name;
        p['a_codes'] = _isPrepared ? c0.savedGroups : list(c0.codesController);
        p['saved_a_groups'] = p['a_codes'];
      } else {
        p['a_codes'] = _isPrepared ? _savedA : list(_a);
        p['saved_a_groups'] = p['a_codes'];
        if (_isPrepared) p['a_name'] = _savedA.join(' + ');
      }
      if (valid.length > 1) {
        final c1 = valid[1];
        p['b_name'] = c1.nameController.text.trim().isNotEmpty
            ? c1.nameController.text.trim()
            : c1.name;
        p['b_codes'] = _isPrepared ? c1.savedGroups : list(c1.codesController);
        p['saved_b_groups'] = p['b_codes'];
      } else {
        p['b_codes'] = _isPrepared ? _savedB : list(_b);
        p['saved_b_groups'] = p['b_codes'];
        if (_isPrepared) p['b_name'] = _savedB.join(' + ');
      }
      p['roi'] = list(_roi);
      p['epoch'] = [number(_epoch0), number(_epoch1)];
      p['baseline'] = [number(_base0), number(_base1)];
      p['window'] = [number(_window0), number(_window1)];
      final epoching = widget.config?.stimEpochSpec;
      if (!_isPrepared &&
          !widget.batchMode &&
          epoching != null &&
          (p['task'] == 'Custom' || p['task'] == null)) {
        List<String> expand(String key) => [
          for (final code in (p[key] as List).cast<String>())
            ...epoching.markerGroups[code] ?? [code],
        ];
        p['saved_a_groups'] = p['a_codes'];
        p['saved_b_groups'] = p['b_codes'];
        p['a_codes'] = expand('a_codes');
        p['b_codes'] = expand('b_codes');
      }
      options['profile_override'] = p;
    }
    if (!inspection && widget.config != null) {
      widget.config!.erpAnalysisProtocol = Map<String, dynamic>.from(options)
        ..remove('trial_metadata_path');
    }
    return options;
  }

  void _restoreProtocol() {
    final options = widget.config?.erpAnalysisProtocol;
    if (options == null || options.isEmpty) return;
    _task = options['task'] as String? ?? 'Auto';
    _eventSource = options['event_source'] as String? ?? 'auto';
    _regroupEpochs = options['regroup_epochs'] == true;
    _correct = options['correct_only'] != false;
    _regression = options['regression'] == true;
    _deconvolution = options['deconvolution'] == true;
    _decoding = options['decoding'] == true;
    _generalization = options['temporal_generalization'] == true;
    _exportTrials = options['export_trial_measurements'] == true;
    for (final pair in <String, TextEditingController>{
      'bin_ms': _bin,
      'reject_uv': _reject,
      'permutations': _permutations,
      'folds': _folds,
      'decode_shrinkage': _shrinkage,
      'lsqr_tolerance': _lsqrTolerance,
      'lsqr_iterations': _lsqrIterations,
    }.entries) {
      if (options[pair.key] != null) pair.value.text = '${options[pair.key]}';
    }
    if (options['response_min'] is num)
      _rtMin.text = '${(options['response_min'] as num) * 1000}';
    if (options['response_max'] is num)
      _rtMax.text = '${(options['response_max'] as num) * 1000}';
    _profiles
      ..clear()
      ..addAll({
        for (final e in (options['profile_overrides'] as Map? ?? {}).entries)
          e.key.toString(): Map<String, dynamic>.from(e.value as Map),
      });
    final profile = options['profile_override'];
    if (profile is Map) _fillProfile(Map<String, dynamic>.from(profile));
  }

  void _fillProfile(Map<String, dynamic>? p) {
    _profile = p;
    if (p == null) return;
    for (final c in _conditions) {
      c.dispose();
    }
    _conditions.clear();
    final condList = p['conditions'] as List?;
    if (condList != null && condList.isNotEmpty) {
      for (final item in condList) {
        final m = erpMap(item);
        final name = m['name']?.toString() ?? 'Condition';
        final cds = (m['codes'] as List? ?? []).cast<String>();
        final sg = _isPrepared
            ? _savedGroups.where((g) => markerListContains(cds, g)).toList()
            : <String>[];
        _conditions.add(
          ErpConditionConfig(name: name, codes: cds, savedGroups: sg),
        );
      }
    } else {
      final aName = p['a_name']?.toString() ?? 'Class A';
      final bName = p['b_name']?.toString() ?? 'Class B';
      final aCodes = (p['a_codes'] as List? ?? []).cast<String>();
      final bCodes = (p['b_codes'] as List? ?? []).cast<String>();
      final aSaved = _isPrepared
          ? _savedGroups
                .where(
                  (g) => markerListContains(
                    ((p['saved_a_groups'] ?? aCodes) as List).cast<String>(),
                    g,
                  ),
                )
                .toList()
          : <String>[];
      final bSaved = _isPrepared
          ? _savedGroups
                .where(
                  (g) => markerListContains(
                    ((p['saved_b_groups'] ?? bCodes) as List).cast<String>(),
                    g,
                  ),
                )
                .toList()
          : <String>[];
      _conditions.add(
        ErpConditionConfig(name: aName, codes: aCodes, savedGroups: aSaved),
      );
      _conditions.add(
        ErpConditionConfig(name: bName, codes: bCodes, savedGroups: bSaved),
      );

      if (_isPrepared && _savedGroups.length > 2) {
        final assigned = {...aSaved, ...bSaved};
        for (final g in _savedGroups) {
          if (!assigned.contains(g)) {
            _conditions.add(
              ErpConditionConfig(name: g, codes: [g], savedGroups: [g]),
            );
          }
        }
      }
    }
    _componentLabel.text =
        p['component_name'] as String? ?? p['task'] as String;
    if (_conditions.isNotEmpty) _a.text = _conditions[0].codes.join(', ');
    if (_conditions.length > 1) _b.text = _conditions[1].codes.join(', ');
    _roi.text = (p['roi'] as List).join(', ');
    void pair(String key, TextEditingController a, TextEditingController b) {
      final v = erpNumbers(p[key]);
      a.text = (v[0] * 1000).toStringAsFixed(0);
      b.text = (v[1] * 1000).toStringAsFixed(0);
    }

    pair('epoch', _epoch0, _epoch1);
    pair('baseline', _base0, _base1);
    pair('window', _window0, _window1);
  }

  Future<void> _inspect() async {
    if (_inputs.isEmpty) return;
    setState(() {
      _busy = true;
      _status = 'Reading markers and task suggestions…';
    });
    try {
      final scan = await _service.execute(
        _inputs,
        _options(inspection: true),
        _output.text,
        inspect: true,
      );
      if (!mounted) return;
      setState(() {
        _inspection = scan;
        for (final f in _scanFiles) {
          if (f['subject'] != null)
            _subjects[f['path'] as String] = f['subject'] as String;
          if (f['group'] != null && (f['group'] as String).isNotEmpty) {
            final s = f['subject'] as String;
            if (!_participantGroups.containsKey(s)) {
              _participantGroups[s] = f['group'] as String;
            }
          }
        }
        final profiles = _scanFiles
            .map((f) => erpMap(f['profile']))
            .where((p) => p.isNotEmpty)
            .toList();
        final tasks = profiles.map((p) => p['task']).toSet();
        if (tasks.length == 1) {
          _fillProfile(profiles.first);
        } else if (_task != 'Auto' && erpCorePresets.containsKey(_task)) {
          _fillProfile(Map<String, dynamic>.from(erpCorePresets[_task]!));
        } else {
          _fillProfile(null);
        }
        if (!widget.batchMode &&
            (tasks.isEmpty || (tasks.length == 1 && tasks.first == 'Custom'))) {
          _restoreProtocol();
        }
        _status = _isPrepared
            ? (_profile == null
                  ? 'Saved trial metadata needs attention. Open Recording history or choose a complete signal/metadata pair.'
                  : 'Ready: ${_conditions.length} conditions · ${_roi.text} · ${_window0.text}–${_window1.text} ms')
            : 'Review suggested classes and timing before running. ${_scanFiles.where((f) => f['error'] != null).length} input(s) need attention.';
      });
    } catch (e) {
      if (mounted) setState(() => _status = 'Marker inspection failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static Map<String, dynamic> mergeErpResults(
    List<Map<String, dynamic>> resultsList,
  ) {
    if (resultsList.isEmpty) return {};
    if (resultsList.length == 1) return resultsList.first;

    final allFiles = <Map<String, dynamic>>[];
    final seenPaths = <String>{};
    final allFailures = <Map<String, dynamic>>[];

    for (final res in resultsList) {
      final files = ((res['files'] as List?) ?? []).map(erpMap);
      for (final f in files) {
        final p = f['path']?.toString() ?? '';
        if (p.isNotEmpty && !seenPaths.contains(p)) {
          seenPaths.add(p);
          allFiles.add(f);
        } else if (p.isEmpty) {
          allFiles.add(f);
        }
      }
      final fails = ((res['failures'] as List?) ?? []).map(erpMap);
      allFailures.addAll(fails);
    }

    final tasks =
        allFiles.map((f) => f['task']?.toString() ?? 'Custom').toSet();
    final mergedGroups = <Map<String, dynamic>>[];

    for (final task in tasks) {
      final taskFiles = allFiles
          .where((f) => (f['task']?.toString() ?? 'Custom') == task)
          .toList();
      if (taskFiles.isEmpty) continue;

      final first = taskFiles.first;
      final times = erpNumbers(first['times']);
      final nTimes = times.length;
      final labels = (first['labels'] as List? ?? []).cast<String>();
      final conditionNames =
          (first['condition_names'] as List? ?? []).cast<String>();

      final subjects = taskFiles
          .map((f) => f['subject']?.toString() ?? 'subj')
          .toSet()
          .toList();

      final condWaves = <String, List<double>>{};
      final condSems = <String, List<double>>{};
      for (final cond in conditionNames) {
        final subWaves = <List<double>>[];
        for (final f in taskFiles) {
          final cw = f['condition_waves'];
          if (cw is Map && cw[cond] != null) {
            subWaves.add(erpNumbers(cw[cond]));
          }
        }
        if (subWaves.isNotEmpty) {
          final avgWave = List<double>.filled(nTimes, 0.0);
          for (var t = 0; t < nTimes; t++) {
            var sum = 0.0;
            var count = 0;
            for (final w in subWaves) {
              if (t < w.length) {
                sum += w[t];
                count++;
              }
            }
            avgWave[t] = count > 0 ? sum / count : 0.0;
          }
          condWaves[cond] = avgWave;

          final semWave = List<double>.filled(nTimes, 0.0);
          if (subWaves.length > 1) {
            for (var t = 0; t < nTimes; t++) {
              var sumSq = 0.0;
              var count = 0;
              for (final w in subWaves) {
                if (t < w.length) {
                  final diff = w[t] - avgWave[t];
                  sumSq += diff * diff;
                  count++;
                }
              }
              if (count > 1) {
                final variance = sumSq / (count - 1);
                semWave[t] = math.sqrt(variance / count);
              }
            }
          }
          condSems[cond] = semWave;
        }
      }

      final aWaves = taskFiles
          .map((f) => erpNumbers(f['a']))
          .where((w) => w.length == nTimes)
          .toList();
      final bWaves = taskFiles
          .map((f) => erpNumbers(f['b']))
          .where((w) => w.length == nTimes)
          .toList();
      final diffWaves = taskFiles
          .map((f) => erpNumbers(f['difference']))
          .where((w) => w.length == nTimes)
          .toList();

      List<double> avgA = List<double>.filled(nTimes, 0.0);
      List<double> avgB = List<double>.filled(nTimes, 0.0);
      List<double> avgDiff = List<double>.filled(nTimes, 0.0);
      List<double> semDiff = List<double>.filled(nTimes, 0.0);

      if (aWaves.isNotEmpty) {
        for (var t = 0; t < nTimes; t++) {
          avgA[t] =
              aWaves.map((w) => w[t]).reduce((x, y) => x + y) / aWaves.length;
        }
      }
      if (bWaves.isNotEmpty) {
        for (var t = 0; t < nTimes; t++) {
          avgB[t] =
              bWaves.map((w) => w[t]).reduce((x, y) => x + y) / bWaves.length;
        }
      }
      if (diffWaves.isNotEmpty) {
        for (var t = 0; t < nTimes; t++) {
          avgDiff[t] =
              diffWaves.map((w) => w[t]).reduce((x, y) => x + y) /
              diffWaves.length;
        }
        if (diffWaves.length > 1) {
          for (var t = 0; t < nTimes; t++) {
            final m = avgDiff[t];
            final sumSq = diffWaves
                .map((w) => (w[t] - m) * (w[t] - m))
                .reduce((x, y) => x + y);
            semDiff[t] = math.sqrt(
              sumSq / ((diffWaves.length - 1) * diffWaves.length),
            );
          }
        }
      }

      final channelConds = <String, List<List<double>>>{};
      for (final cond in conditionNames) {
        final chGrids = <List<List<double>>>[];
        for (final f in taskFiles) {
          final cc = f['channel_conditions'];
          if (cc is Map && cc[cond] is List) {
            final list2d = (cc[cond] as List).map(erpNumbers).toList();
            if (list2d.isNotEmpty) chGrids.add(list2d);
          }
        }
        if (chGrids.isNotEmpty) {
          final nCh = chGrids.first.length;
          final avgGrid = List.generate(nCh, (ch) {
            return List.generate(nTimes, (t) {
              var sum = 0.0;
              var cnt = 0;
              for (final g in chGrids) {
                if (ch < g.length && t < g[ch].length) {
                  sum += g[ch][t];
                  cnt++;
                }
              }
              return cnt > 0 ? sum / cnt : 0.0;
            });
          });
          channelConds[cond] = avgGrid;
        }
      }

      List<double> avgTopoForKey(String key) {
        final topos = taskFiles
            .map((f) => erpNumbers(f[key]))
            .where((v) => v.isNotEmpty)
            .toList();
        if (topos.isEmpty) return [];
        final nCh = topos.first.length;
        return List.generate(nCh, (ch) {
          var sum = 0.0;
          var cnt = 0;
          for (final td in topos) {
            if (ch < td.length) {
              sum += td[ch];
              cnt++;
            }
          }
          return cnt > 0 ? sum / cnt : 0.0;
        });
      }

      final avgTopoA = avgTopoForKey('topo_a');
      final avgTopoB = avgTopoForKey('topo_b');
      final avgTopoDiff = avgTopoForKey('topo_difference');

      final profile = erpMap(first['profile']);
      final win = erpNumbers(profile['window']);
      final pol = (profile['polarity'] as num?)?.toDouble() ?? 1.0;
      final grandDiffMeas = win.length == 2
          ? reviewMeasures(times, avgDiff, win[0], win[1], pol)
          : <String, double?>{};

      final grandCondMeas = <String, Map<String, double?>>{};
      for (final cond in conditionNames) {
        if (condWaves[cond] != null && win.length == 2) {
          grandCondMeas[cond] = reviewMeasures(
            times,
            condWaves[cond]!,
            win[0],
            win[1],
            pol,
          );
        }
      }

      mergedGroups.add({
        'task': task,
        'component_name': task,
        'times': times,
        'bin_times': first['bin_times'] ?? [],
        'n_files': taskFiles.length,
        'n_subjects': subjects.length,
        'subjects': subjects,
        'labels': labels,
        'a': avgA,
        'b': avgB,
        'difference': avgDiff,
        'sem_difference': semDiff,
        'condition_names': conditionNames,
        'condition_waves': condWaves,
        'condition_sems': condSems,
        'channel_conditions': channelConds,
        'gfp_a': first['gfp_a'] ?? [],
        'gfp_b': first['gfp_b'] ?? [],
        'topo_a': avgTopoA,
        'topo_b': avgTopoB,
        'topo_difference': avgTopoDiff,
        'topo_p_fwer': [],
        'topo_t': [],
        'spatiotemporal_p_fwer': [],
        'spatiotemporal_t': [],
        'statistics': first['statistics'] ?? [],
        'profile': profile,
        'grand_difference_measurements': grandDiffMeas,
        'grand_condition_measurements': grandCondMeas,
        'warning': '',
      });
    }

    return {
      'schema': 'ccs-erp-workbench-v1',
      'output': resultsList.first['output'] ?? '',
      'options': resultsList.first['options'] ?? {},
      'files': allFiles,
      'groups': mergedGroups,
      'failures': allFailures,
    };
  }

  Future<void> _openResult() async {
    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['ccserp', 'json'],
      allowMultiple: true,
    );
    if (picked == null || picked.files.isEmpty || !mounted) return;
    try {
      final validFiles = picked.files
          .where((f) => f.path != null)
          .map((f) => f.path!)
          .toList();
      if (validFiles.isEmpty) return;

      final resultsList = <Map<String, dynamic>>[];
      for (final path in validFiles) {
        final content = await File(path).readAsString();
        final val = Map<String, dynamic>.from(jsonDecode(content) as Map);
        if (val['schema'] == 'ccs-erp-workbench-v1') {
          resultsList.add(val);
        }
      }

      if (resultsList.isEmpty) {
        throw const FormatException(
          'No valid ccs-erp-workbench-v1 ERP results found in selected file(s).',
        );
      }

      final merged = mergeErpResults(resultsList);
      if (!mounted) return;
      setState(() {
        _result = merged;
        _batchShowResults = true;
        _component = _groups.isEmpty ? '' : _groups.first['task'] as String;
        _file = null;
        _output.text = File(validFiles.first).parent.path;
        final nF = (merged['files'] as List? ?? []).length;
        _status =
            'Loaded $nF recording(s) across ${resultsList.length} ERP result file(s).';
      });
    } catch (e) {
      if (mounted) setState(() => _status = '$e');
    }
  }

  Future<void> _openResultFolder() async {
    final dirPath = await FilePicker.getDirectoryPath();
    if (dirPath == null || !mounted) return;
    try {
      final dir = Directory(dirPath);
      final entries = dir.listSync(recursive: false).whereType<File>().toList();
      final candidates = entries.where((f) {
        final lower = f.path.toLowerCase();
        return lower.endsWith('.ccserp') ||
            (lower.endsWith('.json') && lower.contains('erp_results'));
      }).toList();

      if (candidates.isEmpty) {
        if (mounted) {
          setState(
            () => _status =
                'No .ccserp or erp_results.json files found in $dirPath',
          );
        }
        return;
      }

      final resultsList = <Map<String, dynamic>>[];
      for (final f in candidates) {
        try {
          final content = await f.readAsString();
          final val = Map<String, dynamic>.from(jsonDecode(content) as Map);
          if (val['schema'] == 'ccs-erp-workbench-v1') {
            resultsList.add(val);
          }
        } catch (_) {}
      }

      if (resultsList.isEmpty) {
        if (mounted) {
          setState(
            () => _status = 'No valid ccs-erp-workbench-v1 files in $dirPath',
          );
        }
        return;
      }

      final merged = mergeErpResults(resultsList);
      if (!mounted) return;
      setState(() {
        _result = merged;
        _batchShowResults = true;
        _component = _groups.isEmpty ? '' : _groups.first['task'] as String;
        _file = null;
        _output.text = dirPath;
        final nF = (merged['files'] as List? ?? []).length;
        _status =
            'Loaded $nF recording(s) from ${resultsList.length} ERP file(s) in $dirPath.';
      });
    } catch (e) {
      if (mounted) setState(() => _status = '$e');
    }
  }

  Future<void> _addFolder() async {
    final directory = await FilePicker.getDirectoryPath();
    if (directory == null || !mounted) return;
    try {
      final files = discoverErpRecordings(
        directory,
        firstSubjects: int.tryParse(_limit.text) ?? 2,
      );
      setState(() {
        _paths
          ..clear()
          ..addAll(files);
        _result = null;
      });
      await _inspect();
    } catch (e) {
      if (mounted) setState(() => _status = '$e');
    }
  }

  Future<void> _addFiles() async {
    final picked = await pickFilteredFiles(
      context,
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: ['edf', 'fif', 'ccseeg', 'json'],
      recordingsOnly: true,
    );
    if (picked == null || !mounted) return;
    setState(() {
      for (final f in picked.files) {
        if (f.path != null && !_paths.contains(f.path)) _paths.add(f.path!);
      }
      _result = null;
    });
    await _inspect();
  }

  Future<void> _exportLinkedResults() async {
    final destination = await FilePicker.getDirectoryPath(dialogTitle: 'Export ERP measurements and report');
    if (destination == null) return;
    var count = 0;
    await for (final file in Directory(_output.text).list()) {
      if (file is! File || !['.csv', '.pdf', '.ccserp', '.png', '.svg'].any(file.path.endsWith)) continue;
      final target = '$destination${Platform.pathSeparator}${file.uri.pathSegments.last}';
      if (File(target).absolute.path != file.absolute.path) await file.copy(target);
      count++;
    }
    if (mounted) setState(() => _status = 'Exported $count ERP result files to $destination');
  }

  Future<void> _run() async {
    final empty = _emptyConditions;
    if (empty.isNotEmpty) {
      final valid = _validConditions;
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Missing epochs in protocol'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'The following ${empty.length} condition(s) have 0 matching epochs in this recording:',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              for (final ec in empty)
                Padding(
                  padding: const EdgeInsets.only(left: 8, bottom: 4),
                  child: Text(
                    '• ${ec.name.isNotEmpty ? ec.name : "Condition"} (0 trials; expected: ${ec.codes.isNotEmpty ? ec.codes.join(", ") : "no groups assigned"})',
                    style: const TextStyle(color: Colors.amber),
                  ),
                ),
              const SizedBox(height: 12),
              Text(
                'Analysis will proceed with the available ${valid.length} condition(s):\n'
                '${valid.map((v) => "• ${v.name} (${_conditionTrialCount(v)} trials)").join("\n")}',
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Review Conditions'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Skip & Run'),
            ),
          ],
        ),
      );
      if (proceed != true || !mounted) return;
      setState(() {
        for (final ec in empty) {
          _conditions.remove(ec);
          ec.dispose();
        }
      });
    }
    if (_output.text.trim().isEmpty) {
      final path = await FilePicker.getDirectoryPath(
        dialogTitle: 'Choose ERP results folder',
      );
      if (path == null || !mounted) return;
      _output.text = path;
    }
    Map<String, dynamic> options;
    try {
      options = _options();
    } catch (e) {
      setState(() => _status = 'Check timing values: $e');
      return;
    }
    setState(() {
      _busy = true;
      _progress = 0;
      _status = 'Running ERP analysis…';
    });
    try {
      final result = await _service.execute(
        _inputs,
        options,
        _output.text.trim(),
        progress: (p, message) {
          if (mounted)
            setState(() {
              _progress = p;
              _status = message;
            });
        },
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _batchShowResults = true;
        _file = null;
        _component = _groups.isEmpty ? '' : _groups.first['task'] as String;
        _status = 'Writing the compact report…';
      });
      await writeErpWorkbenchReport(result, _output.text.trim());
      if (mounted)
        setState(
          () => _status =
              'Finished: ${_results.length} recordings; ${(result['failures'] as List).length} need attention. Report and tables saved.',
        );
    } catch (e) {
      if (mounted) setState(() => _status = 'Analysis stopped: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _field(TextEditingController c, String label, {String? helper}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 9),
        child: TextField(
          controller: c,
          enabled: !_busy,
          decoration: InputDecoration(
            labelText: label,
            helperText: helper,
            helperMaxLines: 3,
            isDense: true,
            border: const OutlineInputBorder(),
          ),
        ),
      );
  Widget _pair(
    String label,
    TextEditingController a,
    TextEditingController b,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label),
      const SizedBox(height: 5),
      Row(
        children: [
          Expanded(child: _field(a, 'Start (ms)')),
          const SizedBox(width: 8),
          Expanded(child: _field(b, 'End (ms)')),
        ],
      ),
    ],
  );
  Widget _card(String title, List<Widget> children) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    child: title == '3  Analyses' && !widget.batchMode
        ? ExpansionTile(
            title: const Text(
              'Advanced analyses (optional)',
              style: TextStyle(fontSize: 14),
            ),
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: children,
                ),
              ),
            ],
          )
        : Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 10),
                ...children,
              ],
            ),
          ),
  );
  Widget _buildErpCorePresetBar() {
    const tasks = [
      'Auto',
      'P3',
      'MMN',
      'N170',
      'N2pc',
      'N400',
      'ERN',
      'LRP',
      'Custom',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'ERP-CORE Paradigm Presets',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.bold,
            color: Colors.cyanAccent,
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 5,
          runSpacing: 5,
          children: [
            for (final t in tasks)
              ChoiceChip(
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                label: Text(
                  t == 'Auto' ? 'Auto-detect' : t,
                  style: const TextStyle(fontSize: 11),
                ),
                selected: _task == t,
                onSelected: _busy
                    ? null
                    : (sel) {
                        if (!sel) return;
                        setState(() {
                          _task = t;
                          if (t == 'Custom') {
                            _regroupEpochs = false;
                          } else if (erpCorePresets.containsKey(t)) {
                            _fillProfile(
                              Map<String, dynamic>.from(erpCorePresets[t]!),
                            );
                          }
                        });
                        _inspect();
                      },
              ),
          ],
        ),
        if (_profile != null &&
            erpCorePresets.containsKey(_profile!['task'])) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.cyan.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.cyan.withValues(alpha: 0.25)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_profile!['task']} Preset · ROI: ${(_profile!['roi'] as List).join(', ')} · Window: ${_window0.text} to ${_window1.text} ms · Epoch: ${_epoch0.text} to ${_epoch1.text} ms',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: Colors.cyanAccent,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${_profile!['a_name']}: ${(_profile!['a_codes'] as List).take(6).join(', ')}${(_profile!['a_codes'] as List).length > 6 ? '…' : ''}   vs   ${_profile!['b_name']}: ${(_profile!['b_codes'] as List).take(6).join(', ')}${(_profile!['b_codes'] as List).length > 6 ? '…' : ''}',
                  style: const TextStyle(fontSize: 10, color: Colors.white70),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildMultiConditionTopoSection(
    Map<String, dynamic> d,
    List<Map<String, dynamic>> current,
    Set<String> highlightChannels,
  ) {
    final activeFiles = current
        .where((f) => _file == null || f['path'] == _file)
        .toList();
    final topoItems = extractErpConditionTopos(d, files: activeFiles);
    final profile = erpMap(d['profile']);
    final win = erpNumbers(profile['window']);
    final winLabel = win.length == 2
        ? '${(win[0] * 1000).round()}–${(win[1] * 1000).round()} ms'
        : 'component window';

    if (topoItems.isEmpty) {
      return Card(
        margin: const EdgeInsets.only(top: 10),
        elevation: 0,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Component-Window Topographies ($winLabel)',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 240,
                width: 320,
                child: CustomPaint(
                  painter: ErpWorkbenchTopoPainter(
                    d,
                    selectedChannels: highlightChannels,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Card(
      margin: const EdgeInsets.only(top: 10),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.blur_circular,
                  size: 16,
                  color: Colors.cyanAccent,
                ),
                const SizedBox(width: 8),
                Text(
                  'Component-Window Scalp Topographies ($winLabel)',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Conditions share amplitude scale; difference map shows B − A contrast',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            LayoutBuilder(
              builder: (context, constraints) {
                final count = topoItems.length;
                final panelWidth = math.max(
                  220.0,
                  math.min(
                    310.0,
                    (constraints.maxWidth - (count - 1) * 10) / count,
                  ),
                );
                return Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (final item in topoItems)
                      Container(
                        width: panelWidth,
                        height: 235,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: item['is_diff'] == true
                                ? const Color(0xFF64748B)
                                : const Color(0xFFCBD5E1),
                            width: item['is_diff'] == true ? 1.5 : 1.0,
                          ),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(5),
                          child: CustomPaint(
                            painter: ErpWorkbenchTopoPainter(
                              d,
                              valueKey: item['key'] as String,
                              customTitle: item['title'] as String,
                              valuesOverride:
                                  (item['values'] as List).cast<double>(),
                              scaleOverride: (item['scale'] as num).toDouble(),
                              showPValues: item['is_diff'] == true,
                              selectedChannels: highlightChannels,
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
  Widget _check(String text, bool value, void Function(bool) set) =>
      CheckboxListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text(text),
        value: value,
        onChanged: _busy ? null : (v) => setState(() => set(v ?? false)),
      );
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final showStage1 = !widget.batchMode || _activeStage == 0 || _activeStage == 1;
      final showStage2 = !widget.batchMode || _activeStage == 0 || _activeStage == 2;
      final showStage3 = !widget.batchMode || _activeStage == 0 || _activeStage == 3;
      final showStage4 = !widget.batchMode || _activeStage == 0 || _activeStage == 4;
      final settings = SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            if (widget.config != null && !widget.linkedReview)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('Protocol', style: TextStyle(fontSize: 13)),
                children: [
                  ProtocolTools(
                    config: widget.config!,
                    beforeSave: () {
                      _options();
                    },
                    onChanged: () => setState(_restoreProtocol),
                  ),
                ],
              ),
            if (!widget.batchMode && showStage1 && !widget.linkedReview)
              _card('1  Recording', [
                Text(
                  widget.activeRecording?.path.split(RegExp(r'[/\\]')).last ??
                      'Open a recording',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  _isPrepared
                      ? '${widget.activeRecording?.epochCount ?? 0} trials ready · use saved conditions below'
                      : 'Create event trials in Epochs first',
                  style: const TextStyle(fontSize: 11),
                ),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    TextButton.icon(
                      onPressed: _busy ? null : widget.onOpenRecording,
                      icon: const Icon(Icons.folder_open, size: 16),
                      label: const Text('Open EEG / epochs'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _openResult,
                      icon: const Icon(Icons.history, size: 16),
                      label: const Text('Load ERP (.ccserp)'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _openResultFolder,
                      icon: const Icon(Icons.folder_open, size: 16),
                      label: const Text('Load ERP Folder'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _addFiles,
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('Add EEG Files / Epochs'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _addFolder,
                      icon: const Icon(Icons.folder_open, size: 16),
                      label: const Text('Add Folder'),
                    ),
                    if (widget.activeRecording != null)
                      IconButton(
                        tooltip: 'Recording history',
                        icon: const Icon(Icons.history, size: 18),
                        onPressed: () => showRecordingDetails(
                          context,
                          widget.activeRecording!,
                        ),
                      ),
                    IconButton(
                      tooltip: 'Edit trial groups and windows in Epochs',
                      onPressed: widget.onPrepare,
                      icon: const Icon(Icons.content_cut, size: 18),
                    ),
                  ],
                ),
                if (_paths.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    '${_paths.length} recording(s) queued for ERP analysis',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: Colors.cyanAccent,
                    ),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                            _paths.clear();
                            _inspection = null;
                            _fillProfile(null);
                          }),
                    child: const Text(
                      'Clear queued files',
                      style: TextStyle(fontSize: 11),
                    ),
                  ),
                ],
                if (_results.isNotEmpty) ...[
                  const Divider(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '${_results.length} loaded recording(s)',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Colors.cyanAccent,
                        ),
                      ),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => setState(() {
                                _result = null;
                                _file = null;
                              }),
                        child: const Text(
                          'Clear all ERP files',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.redAccent,
                          ),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(
                    height: math.min(180, _results.length * 44.0),
                    child: ListView.builder(
                      itemCount: _results.length,
                      itemBuilder: (context, idx) {
                        final rf = _results[idx];
                        final info = _describeRecording(rf);
                        final isSel = rf['path'] == _file;
                        return InkWell(
                          onTap: () => setState(() => _file = rf['path'] as String),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                            margin: const EdgeInsets.only(bottom: 2),
                            decoration: BoxDecoration(
                              color: isSel ? Colors.cyan.withValues(alpha: 0.15) : Colors.transparent,
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: isSel ? Colors.cyanAccent : Colors.white10,
                                width: isSel ? 1 : 0.5,
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  isSel ? Icons.radio_button_checked : Icons.radio_button_off,
                                  size: 14,
                                  color: isSel ? Colors.cyanAccent : Colors.grey,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '#${idx + 1}: ${info['subject']} · ${info['session']}',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                                          color: isSel ? Colors.white : Colors.white70,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      Text(
                                        info['fileName'] ?? '',
                                        style: const TextStyle(fontSize: 9, color: Colors.grey),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ])
            else if (showStage1)
              _card(widget.batchMode ? '1  Batch inputs' : '1  Active recording', [
                TextButton.icon(
                  onPressed: _busy ? null : _openResult,
                  icon: const Icon(Icons.history),
                  label: const Text('Open saved ERP results…'),
                ),
                if (widget.batchMode) ...[
                  const Text(
                    'Start from continuous recordings with events, or reuse saved epoched condition files.',
                  ),
                  const SizedBox(height: 10),
                  _field(
                    _limit,
                    'First N participants on folder import (0 = all)',
                    helper:
                        'Cleaned EDF counterparts are preferred; raw and cleaned copies are not counted twice.',
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _addFiles,
                        icon: const Icon(Icons.add),
                        label: const Text('Files'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _addFolder,
                        icon: const Icon(Icons.folder_open),
                        label: const Text('Folder'),
                      ),
                      if (_paths.isNotEmpty)
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => setState(() {
                                  _paths.clear();
                                  _inspection = null;
                                  _fillProfile(null);
                                }),
                          child: const Text('Clear'),
                        ),
                    ],
                  ),
                ] else ...[
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _openResult,
                        icon: const Icon(Icons.history, size: 16),
                        label: const Text('Open saved ERP (.ccserp)…'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _openResultFolder,
                        icon: const Icon(Icons.folder_open, size: 16),
                        label: const Text('Open ERP folder…'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _addFiles,
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('Open epoched EEG files…'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _addFolder,
                        icon: const Icon(Icons.folder_open, size: 16),
                        label: const Text('Open recordings folder…'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  TextButton.icon(
                    onPressed: _busy ? null : widget.onOpenRecording,
                    icon: const Icon(Icons.folder_open),
                    label: const Text('Open continuous recording…'),
                  ),
                  Text(
                    widget.activeRecording?.path.split(RegExp(r'[/\\]')).last ??
                        'No recording selected',
                  ),
                  Text(
                    _isPrepared
                        ? 'Saved trials are reused. Select condition groups below; no marker selection or epoching is repeated.'
                        : 'Create event-based trials in Epochs before comparing ERP groups here.',
                  ),
                  if (!_isPrepared)
                    OutlinedButton.icon(
                      onPressed: widget.onPrepare,
                      icon: const Icon(Icons.cut),
                      label: const Text('Go to event epoching'),
                    ),
                  if (_isPrepared)
                    TextButton(
                      onPressed: widget.onPrepare,
                      child: const Text(
                        'Change event groups / trial window in Epochs',
                      ),
                    ),
                  TextButton(
                    onPressed: widget.onOpenBatch,
                    child: const Text('Multiple recordings → Batch Workspace'),
                  ),
                ],
                if (widget.batchMode)
                  Text('${_selectedPaths.length} recordings selected'),
                if (widget.batchMode && _paths.isNotEmpty)
                  TextButton(
                    onPressed: _busy ? null : _reviewInputs,
                    child: const Text('Review files and participant IDs…'),
                  ),
              ]),
            if (showStage2 && widget.linkedReview)
              _card('ERP measurements', [
                const Text('Uses the accepted trials from Epochs & ERP. Return to trial review to change inclusion.'),
                const SizedBox(height: 8),
                for (final c in _validConditions) Text('${c.name}: ${_conditionTrialCount(c)} trials'),
                const Divider(),
                _field(_roi, 'Measurement channels / ROI'),
                _pair('Measurement window', _window0, _window1),
                TextButton.icon(onPressed: _busy || _result == null ? null : _exportLinkedResults,
                  icon: const Icon(Icons.save_alt), label: const Text('Export results…')),
                Text('Trial window: ${_epoch0.text} to ${_epoch1.text} ms'),
              ]),
            if (showStage2 && !widget.linkedReview)
              _card(_isPrepared ? '2  Compare conditions' : '2  Task and event markers', [
                if (!_isPrepared) ...[
                  _buildErpCorePresetBar(),
                  const SizedBox(height: 10),
                ],
                if (!_isPrepared)
                  DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: _eventSource,
                  decoration: const InputDecoration(
                    labelText: 'Event timing source',
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'auto',
                      child: Text('Sidecar preferred, otherwise native events'),
                    ),
                    DropdownMenuItem(
                      value: 'sidecar',
                      child: Text('EEGLAB .evt sidecar only'),
                    ),
                    DropdownMenuItem(
                      value: 'native',
                      child: Text('EDF annotations / Status only'),
                    ),
                  ],
                  onChanged: _busy
                      ? null
                      : (v) {
                          setState(() => _eventSource = v!);
                          _inspect();
                        },
                ),

              DropdownButtonFormField<String>(
                initialValue: _task,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Component'),
                items:
                    [
                          'Auto',
                          'MMN',
                          'N170',
                          'N2pc',
                          'N400',
                          'P3',
                          'LRP',
                          'ERN',
                          'Custom',
                        ]
                        .map(
                          (v) => DropdownMenuItem(
                            value: v,
                            child: Text(
                              v == 'Auto'
                                  ? (widget.batchMode
                                        ? 'Suggest per file (all ERP CORE tasks)'
                                        : 'Suggest from active recording')
                                  : v,
                            ),
                          ),
                        )
                        .toList(),
                onChanged: _busy
                    ? null
                    : (v) {
                        setState(() {
                          _task = v!;
                          if (v == 'Custom') _regroupEpochs = false;
                        });
                        _inspect();
                      },
              ),
              const SizedBox(height: 10),
              if (_profile != null)
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: const Text(
                    'Component guide',
                    style: TextStyle(fontSize: 12),
                  ),
                  children: [
                    Text(
                      erpTaskGuides[_profile!['task']] ??
                          erpTaskGuides['Custom']!,
                    ),
                  ],
                ),
              if (!_isPrepared)
                const Text(
                  'Continuous-input marker definitions are configured here because no saved trial groups exist yet.',
                ),
              if (widget.batchMode && _scanFiles.isNotEmpty) ...[
                const SizedBox(height: 8),
                for (final task
                    in _scanFiles
                        .map((f) => erpMap(f['profile'])['task'])
                        .whereType<String>()
                        .toSet())
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      '$task · ${_scanFiles.where((f) => erpMap(f['profile'])['task'] == task).length} recordings',
                    ),
                    subtitle: Text(() {
                      final p = erpMap(
                        _scanFiles.firstWhere(
                          (f) => erpMap(f['profile'])['task'] == task,
                        )['profile'],
                      );
                      final w = erpNumbers(p['window']);
                      return '${(p['roi'] as List).join(', ')} · ${(w.first * 1000).round()}–${(w.last * 1000).round()} ms';
                    }()),
                    trailing: TextButton(
                      onPressed: _busy
                          ? null
                          : () {
                              setState(() => _task = task);
                              _inspect();
                            },
                      child: const Text('Review'),
                    ),
                  ),
              ],
              if (_isPrepared && _profile == null)
                _check('Use task presets', _regroupEpochs, (v) {
                  _regroupEpochs = v;
                  _inspect();
                }),
              if (_profile != null) ...[
                const SizedBox(height: 8),
                _field(_componentLabel, 'Component name'),
                if (_isPrepared) ...[
                  if (_scanFiles.any((f) => f['can_regroup'] == true) &&
                      _profile!['task'] != 'Custom')
                    _check('Regroup using task event codes', _regroupEpochs, (
                      v,
                    ) {
                      _regroupEpochs = v;
                      _inspect();
                    }),
                  if (_regroupEpochs)
                    const Text(
                      'Suggested groups are reconstructed from the original saved locking event of each existing trial. No re-epoching is performed.',
                      style: TextStyle(fontSize: 11),
                    ),
                  _buildConditionEditor(),
                ] else ...[
                  _buildConditionEditor(),
                ],
                _field(
                  _roi,
                  _profile!['lateralized'] == true
                      ? 'Left ROI, right ROI'
                      : 'Electrodes / ROI',
                ),
                if (_profile!['lateralized'] == true)
                  const Text(
                    'Conventional traces: ipsilateral vs contralateral. Original side classes are used for models/decoding.',
                  ),
                if (widget.batchMode)
                  TextButton.icon(
                    onPressed: _busy
                        ? null
                        : () {
                            try {
                              final p = erpMap(_options()['profile_override']);
                              setState(() {
                                _profiles[p['task'] as String] = p;
                                _status =
                                    'Saved ${p['task']} settings for mixed-task batches.';
                              });
                            } catch (e) {
                              setState(() => _status = 'Check settings: $e');
                            }
                          },
                    icon: const Icon(Icons.save),
                    label: const Text('Keep task settings for mixed batches'),
                  ),
                if (!_isPrepared)
                  _pair('Epoch', _epoch0, _epoch1)
                else
                  Text(
                    'Saved trial window: ${_epoch0.text} to ${_epoch1.text} ms (preserved)',
                  ),
                _pair('Baseline', _base0, _base1),
                _pair('Measurement window', _window0, _window1),
                DropdownButtonFormField<double>(
                  initialValue: (_profile!['polarity'] as num).toDouble(),
                  decoration: const InputDecoration(
                    labelText: 'Component polarity',
                  ),
                  items: const [
                    DropdownMenuItem(value: -1, child: Text('Negative')),
                    DropdownMenuItem(value: 1, child: Text('Positive')),
                  ],
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _profile!['polarity'] = v!),
                ),
              ] else if (_scanFiles.isNotEmpty && widget.batchMode)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'Mixed-task batch uses each reviewed task preset. Select a task above to edit its event/timing rules.',
                  ),
                ),
              if (!_isPrepared)
                _check(
                  'Require correct stimulus responses (where applicable)',
                  _correct,
                  (v) => _correct = v,
                ),
              if (!_isPrepared)
                ExpansionTile(
                  title: const Text('Behavior and timing notes'),
                  children: const [
                    Text(
                      'ERP CORE stimulus tasks default to correct responses 200–1000 ms after the event (editable under solver/response parameters). MMN has no response filter. ERN includes correct and error responses; LRP uses correct left/right responses. No LCD-delay adjustment or extra filtering is applied automatically.',
                    ),
                  ],
                ),
            ]),
            if (showStage3)
              _card('3  Analyses', [
              ExpansionTile(
                title: const Text('Solver, decoding and response parameters'),
                children: [
                  if (!_isPrepared)
                    _pair('Response association window', _rtMin, _rtMax),
                  _field(_folds, 'Blocked decoding folds (2–20)'),
                  _field(_shrinkage, 'LDA shrinkage (0–1)'),
                  if (!_isPrepared)
                    _field(_lsqrTolerance, 'Overlap solver tolerance'),
                  if (!_isPrepared)
                    _field(
                      _lsqrIterations,
                      'Overlap solver maximum iterations',
                    ),
                ],
              ),

              const Text(
                'Always: mean, peak amplitude/latency, signed and positive/negative AUC, fractional-area/peak latency, GFP, paired subject statistics, corrected topography and TANOVA.',
              ),
              _check(
                'Export individual-trial measurements (advanced)',
                _exportTrials,
                (v) => _exportTrials = v,
              ),
              const Text(
                'Standard ERP measurements use participant/condition averages (erp_measurements.csv). Trial exports are optional for trial-level models; individual-trial peaks are noise-sensitive.',
              ),
              const SizedBox(height: 9),
              _field(
                _reject,
                'Amplitude rejection threshold (µV; 0 = off)',
                helper:
                    'Use preprocessed inputs or clean recordings in the Preprocess module first.',
              ),
              _field(_bin, 'Model / statistical time-bin width (ms)'),
              if (widget.batchMode)
                _field(_permutations, 'Group sign-flip permutations'),
              _check(
                'Regression ERP (multichannel OLS)',
                _regression,
                (v) => _regression = v,
              ),
              if (_regression)
                _field(
                  _metadata,
                  'Optional trial predictor CSV path',
                  helper:
                      'file,event_index followed by numeric predictors. Intercept, class and complete RT are included automatically.',
                ),
              if (!_isPrepared)
                _check(
                  'Overlap correction (Unfold-style FIR / LSQR)',
                  _deconvolution,
                  (v) => _deconvolution = v,
                ),
              if (_deconvolution)
                const Text(
                  'Continuous-data model with class and nuisance stimulus/response events. This is the stick-basis subset, not the entire Unfold toolbox; inspect convergence and exclusions separately.',
                ),
              _check(
                'Time-resolved neural decoding (shrinkage LDA)',
                _decoding,
                (v) => _decoding = v,
              ),
              if (_decoding) ...[
                _check(
                  'Temporal generalization (train time × test time)',
                  _generalization,
                  (v) => _generalization = v,
                ),
                const Text(
                  'Contiguous test folds; overlapping epoch samples are purged from training. Scaling is fitted on training data. Descriptive scores are not a significance test.',
                ),
              ],
            ]),
            if (widget.batchMode && showStage4)
              _card('4  Run and export', [
                if (_timingIssue != null)
                  Text(
                    _timingIssue!,
                    style: const TextStyle(color: Colors.orangeAccent),
                  ),
                _field(_output, 'Output folder'),
                OutlinedButton.icon(
                  onPressed: _busy
                      ? null
                      : () async {
                          final path = await FilePicker.getDirectoryPath();
                          if (path != null && mounted)
                            setState(() => _output.text = path);
                        },
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Choose output folder'),
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: _canRun ? _run : null,
                  icon: const Icon(Icons.play_arrow),
                  label: Text('Analyse ${_selectedPaths.length} recording(s)'),
                ),
                if (_busy) ...[
                  const SizedBox(height: 10),
                  LinearProgressIndicator(
                    value: _progress > 0 ? _progress : null,
                  ),
                  TextButton(
                    onPressed: () => _service.cancel(),
                    child: const Text('Cancel'),
                  ),
                ],
                const SizedBox(height: 8),
                SelectableText(
                  _busy || !_isPrepared
                      ? _status
                      : (_canRun
                            ? 'Ready: ${_conditions.length} conditions · ${_roi.text} · ${_window0.text}–${_window1.text} ms'
                            : 'Choose saved groups for each condition before averaging.'),
                ),
                if (_result != null)
                  TextButton.icon(
                    onPressed: () => Process.run(
                      Platform.isMacOS
                          ? 'open'
                          : Platform.isWindows
                          ? 'explorer'
                          : 'xdg-open',
                      [_output.text],
                    ),
                    icon: const Icon(Icons.folder),
                    label: const Text('Open results folder'),
                  ),
              ]),
          ],
        ),
      );
      final panel = widget.batchMode
          ? settings
          : Column(
              children: [
                Expanded(child: settings),
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_timingIssue != null)
                        Text(
                          _timingIssue!,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.orangeAccent,
                          ),
                        ),
                      Row(
                        children: [
                          IconButton(
                            tooltip: _output.text.isEmpty
                                ? 'Choose results folder'
                                : _output.text,
                            icon: const Icon(Icons.folder_open),
                            onPressed: _busy
                                ? null
                                : () async {
                                    final path =
                                        await FilePicker.getDirectoryPath();
                                    if (path != null && mounted)
                                      setState(() => _output.text = path);
                                  },
                          ),
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: _busy
                                  ? () => _service.cancel()
                                  : _canRun
                                  ? _run
                                  : null,
                              icon: Icon(
                                _busy ? Icons.stop : Icons.play_arrow,
                                size: 17,
                              ),
                              label: Text(
                                _busy ? 'Cancel' : widget.linkedReview ? 'Update measurements' : 'Average & analyse ERP',
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (_busy) LinearProgressIndicator(value: _progress),
                      Text(
                        _busy
                            ? _status
                            : (_emptyConditions.isNotEmpty
                                ? 'Ready: ${_validConditions.length} active condition(s) (${_emptyConditions.length} empty condition(s) can be skipped).'
                                : _status),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10,
                          color: _emptyConditions.isNotEmpty && !_busy
                              ? Colors.amber.shade300
                              : null,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
      final results = _resultsPane();
      final body = constraints.maxWidth < 850
          ? Column(
              children: [
                Expanded(child: panel),
                SizedBox(height: constraints.maxHeight * .45, child: results),
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 375, child: panel),
                const VerticalDivider(width: 1),
                Expanded(child: results),
              ],
            );
      if (widget.batchMode) {
        return _buildUniformErpBatchWorkspace(constraints, results, body);
      }
      return body;
    },
  );

  Future<void> _runErpStage1Only() async {
    if (widget.onRunPreprocessing != null) {
      setState(() {
        _busy = true;
        _status = 'Running Stage 1 Preprocessing…';
      });
      try {
        final written = await widget.onRunPreprocessing!();
        if (written.isNotEmpty && mounted) {
          setState(() {
            _paths
              ..clear()
              ..addAll(written);
            _result = null;
          });
          await _inspect();
        }
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      return;
    }
    if (_prepFiles.isNotEmpty) {
      setState(() {
        _paths
          ..clear()
          ..addAll(_prepFiles);
        _result = null;
      });
      await _inspect();
    }
  }

  Future<void> _runFullErpPipeline() async {
    if (_batchStage1Enabled && !_batchPreprocessedInput) {
      await _runErpStage1Only();
    }
    if (_canRun) {
      await _run();
    }
  }

  Widget _buildUniformErpBatchWorkspace(
    BoxConstraints constraints,
    Widget resultsPane,
    Widget splitBody,
  ) {
    const bgColor = Color(0xFF060D1A);
    const cardColor = Color(0xFF0F1D32);
    const borderColor = Color(0xFF1E293B);
    const textMuted = Color(0xFF94A3B8);
    const accentBlue = Color(0xFF3B82F6);
    const accentGreen = Color(0xFF10B981);

    return Container(
      decoration: const BoxDecoration(
        color: bgColor,
        border: Border(top: BorderSide(color: borderColor)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 1. Uniform BATCH QUEUE Header Bar
          SizedBox(
            height: 36,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  const Icon(
                    Icons.queue_play_next,
                    size: 13,
                    color: accentBlue,
                  ),
                  const SizedBox(width: 6),
                  const Text(
                    'BATCH QUEUE',
                    style: TextStyle(
                      color: accentBlue,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.8,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '${_selectedPaths.length} files queued',
                    style: const TextStyle(color: textMuted, fontSize: 11),
                  ),
                  const Spacer(),
                  if (_result != null) ...[
                    OutlinedButton.icon(
                      onPressed: () =>
                          setState(() => _batchShowResults = !_batchShowResults),
                      icon: Icon(
                        _batchShowResults
                            ? Icons.view_column_outlined
                            : Icons.analytics_outlined,
                        size: 15,
                      ),
                      label: Text(
                        _batchShowResults
                            ? 'Pipeline Stages'
                            : 'View ERP Results',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  TextButton.icon(
                    onPressed: _busy || _result == null || _component.isEmpty
                        ? null
                        : () => _groupModels(difference: false),
                    icon: const Icon(Icons.groups, size: 16),
                    label: const Text('Group Statistics'),
                  ),
                  const SizedBox(width: 4),
                  if (_busy)
                    TextButton.icon(
                      onPressed: () => _service.cancel(),
                      icon: const Icon(Icons.stop_circle, size: 14),
                      label: const Text('Cancel', style: TextStyle(fontSize: 11)),
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.redAccent,
                      ),
                    )
                  else
                    FilledButton.icon(
                      onPressed: _canRun ||
                              (_batchStage1Enabled &&
                                  !_batchPreprocessedInput &&
                                  _prepFiles.isNotEmpty)
                          ? _runFullErpPipeline
                          : null,
                      icon: const Icon(Icons.play_circle_filled, size: 14),
                      label: Text(
                        _batchStage1Enabled && !_batchPreprocessedInput
                            ? 'Run Full Pipeline'
                            : 'Analyse ${_selectedPaths.length} recording(s)',
                        style: const TextStyle(fontSize: 11),
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: accentGreen,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: cardColor,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                      ),
                    ),
                  if (widget.onCloseBatch != null) ...[
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: 'Close batch workspace',
                      icon: const Icon(Icons.close, size: 17, color: textMuted),
                      onPressed: widget.onCloseBatch,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 28,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const Divider(color: borderColor, height: 1),

          if (_batchShowResults && _result != null)
            Expanded(child: splitBody)
          else ...[
            // 2. Info Banner
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: accentBlue.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: accentBlue.withValues(alpha: 0.3)),
                ),
                child: const Text(
                  'Batch parameters are configured inside each stage below. Preprocess raw recordings in Stage 1, configure ERP-CORE or custom task markers in Stage 2, set ERP windows & models in Stage 3, and inspect/export group statistics in Stage 4.',
                  style: TextStyle(color: Colors.white70, fontSize: 11),
                ),
              ),
            ),

            // 3. Global Batch Output Directory Bar
            Container(
              margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: cardColor,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: borderColor),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.folder_shared_outlined,
                    size: 18,
                    color: accentBlue,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'BATCH OUTPUT DIRECTORY (ALL STAGES)',
                          style: TextStyle(
                            color: accentBlue,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.6,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _output.text.trim().isEmpty
                              ? 'Next to source files (default for each recording)'
                              : _output.text.trim(),
                          style: TextStyle(
                            color: _output.text.trim().isEmpty
                                ? textMuted
                                : Colors.white,
                            fontSize: 12,
                            fontWeight: _output.text.trim().isEmpty
                                ? FontWeight.normal
                                : FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () async {
                            final path = await FilePicker.getDirectoryPath(
                              dialogTitle:
                                  'Select ERP batch output directory for all stages',
                            );
                            if (path != null && mounted) {
                              setState(() => _output.text = path);
                            }
                          },
                    icon: const Icon(Icons.folder_open, size: 14),
                    label: const Text('Browse…'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                    ),
                  ),
                  if (_output.text.trim().isNotEmpty) ...[
                    const SizedBox(width: 6),
                    IconButton(
                      tooltip: 'Reset to default output location',
                      icon: const Icon(Icons.clear, size: 16, color: textMuted),
                      onPressed: _busy
                          ? null
                          : () => setState(() => _output.clear()),
                    ),
                  ],
                ],
              ),
            ),

            // 4. Batch Workspace Toolbar Row
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Expanded(
                          child: SwitchListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: const Text(
                              'Already preprocessed: start with task markers',
                              style: TextStyle(fontSize: 12),
                            ),
                            value: _batchPreprocessedInput,
                            onChanged: _busy
                                ? null
                                : (v) => setState(() {
                                    _batchPreprocessedInput = v;
                                    _batchUseStage1Outputs = !v;
                                    if (v && _batchActiveStage == 0) {
                                      _batchActiveStage = 1;
                                    }
                                  }),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: SwitchListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: const Text(
                              'Skip already processed files (resume batch)',
                              style: TextStyle(fontSize: 12),
                            ),
                            value: _batchSkipExisting,
                            onChanged: _busy
                                ? null
                                : (v) => setState(() => _batchSkipExisting = v),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  SizedBox(
                    width: 260,
                    child: _field(
                      _limit,
                      'First N participants on folder import (0 = all)',
                    ),
                  ),
                  const SizedBox(width: 16),
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(
                        value: true,
                        icon: Icon(Icons.tab, size: 14),
                        label: Text('Tabs', style: TextStyle(fontSize: 11)),
                      ),
                      ButtonSegment(
                        value: false,
                        icon: Icon(Icons.view_column, size: 14),
                        label: Text('Columns', style: TextStyle(fontSize: 11)),
                      ),
                    ],
                    selected: {_batchTabbedView},
                    onSelectionChanged: (set) =>
                        setState(() => _batchTabbedView = set.first),
                  ),
                ],
              ),
            ),

            // 5. 4-Stage Pipeline Step Tabs
            _buildErpBatchStageTabs(),

            // 6. 4 Stage Cards (Columns or Tabs)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                child: _batchTabbedView
                    ? switch (_batchActiveStage) {
                        0 => _buildErpStage1Card(
                            onNext: () => setState(() => _batchActiveStage = 1),
                          ),
                        1 => _buildErpStage2Card(
                            onPrevious: _batchPreprocessedInput
                                ? null
                                : () => setState(() => _batchActiveStage = 0),
                            onNext: () => setState(() => _batchActiveStage = 2),
                          ),
                        2 => _buildErpStage3Card(
                            onPrevious: () =>
                                setState(() => _batchActiveStage = 1),
                            onNext: () => setState(() => _batchActiveStage = 3),
                          ),
                        _ => _buildErpStage4Card(
                            onPrevious: () =>
                                setState(() => _batchActiveStage = 2),
                          ),
                      }
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (!_batchPreprocessedInput) ...[
                            Expanded(child: _buildErpStage1Card()),
                            const SizedBox(width: 10),
                          ],
                          Expanded(child: _buildErpStage2Card()),
                          const SizedBox(width: 10),
                          Expanded(child: _buildErpStage3Card()),
                          const SizedBox(width: 10),
                          Expanded(child: _buildErpStage4Card()),
                        ],
                      ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildErpBatchStageTabs() {
    const borderColor = Color(0xFF1E293B);
    const textMuted = Color(0xFF94A3B8);
    final stages = [
      (
        index: 0,
        title: 'Stage 1: Preprocessing',
        color: const Color(0xFF8B5CF6),
        icon: Icons.cleaning_services,
        badge: !_batchStage1Enabled || _batchPreprocessedInput
            ? 'Skipped'
            : '${_prepFiles.length} files',
        enabled: !_batchPreprocessedInput,
        stageActive: _batchStage1Enabled && !_batchPreprocessedInput,
      ),
      (
        index: 1,
        title: 'Stage 2: Task & Event Markers',
        color: const Color(0xFF10B981),
        icon: Icons.flag_outlined,
        badge: !_batchStage2Enabled
            ? 'Skipped'
            : (_batchUseStage1Outputs && _paths.isEmpty
                ? 'Stage 1 output'
                : '${_selectedPaths.length} files'),
        enabled: true,
        stageActive: _batchStage2Enabled,
      ),
      (
        index: 2,
        title: 'Stage 3: Windows & ERP Models',
        color: const Color(0xFFF59E0B),
        icon: Icons.analytics_outlined,
        badge: !_batchStage3Enabled ? 'Skipped' : 'ERP / Decode',
        enabled: true,
        stageActive: _batchStage3Enabled,
      ),
      (
        index: 3,
        title: 'Stage 4: ERP Plots & Group Stats',
        color: const Color(0xFF3B82F6),
        icon: Icons.groups,
        badge: _result != null ? '${_results.length} results' : 'Waveforms / LMM',
        enabled: true,
        stageActive: true,
      ),
    ];

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 6),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFF0A1628),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        children: [
          for (var i = 0; i < stages.length; i++) ...[
            if (i > 0)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 2),
                child: Icon(Icons.chevron_right, size: 16, color: borderColor),
              ),
            Expanded(
              child: InkWell(
                onTap: !stages[i].enabled
                    ? null
                    : () => setState(() => _batchActiveStage = stages[i].index),
                borderRadius: BorderRadius.circular(8),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                  decoration: BoxDecoration(
                    color: _batchActiveStage == stages[i].index
                        ? stages[i].color.withValues(alpha: 0.18)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _batchActiveStage == stages[i].index
                          ? stages[i].color
                          : Colors.transparent,
                      width: 1.5,
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        stages[i].icon,
                        size: 14,
                        color: stages[i].enabled
                            ? (_batchActiveStage == stages[i].index
                                ? stages[i].color
                                : textMuted)
                            : borderColor,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          stages[i].title,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: stages[i].enabled
                                ? (_batchActiveStage == stages[i].index
                                    ? Colors.white
                                    : textMuted)
                                : borderColor,
                            fontWeight: _batchActiveStage == stages[i].index
                                ? FontWeight.bold
                                : FontWeight.normal,
                            fontSize: 11.5,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                        decoration: BoxDecoration(
                          color: !stages[i].stageActive
                              ? Colors.orange.withValues(alpha: 0.18)
                              : stages[i].color.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          stages[i].badge,
                          style: TextStyle(
                            color: !stages[i].stageActive
                                ? Colors.orangeAccent
                                : stages[i].color,
                            fontSize: 9.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _erpBatchCardShell({
    required String title,
    required IconData icon,
    required Color color,
    required List<Widget> children,
    required String runLabel,
    required VoidCallback? onRun,
    bool stageEnabled = true,
    ValueChanged<bool>? onStageEnabledChanged,
    VoidCallback? onPrevious,
    VoidCallback? onNext,
  }) {
    const cardColor = Color(0xFF0F1D32);
    const borderColor = Color(0xFF1E293B);
    const textMuted = Color(0xFF94A3B8);

    return Material(
      color: cardColor,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: borderColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.08),
                border: const Border(bottom: BorderSide(color: borderColor)),
              ),
              child: Row(
                children: [
                  Icon(icon, size: 16, color: stageEnabled ? color : textMuted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: stageEnabled ? color : textMuted,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  if (onStageEnabledChanged != null)
                    InkWell(
                      onTap: _busy ? null : () => onStageEnabledChanged(!stageEnabled),
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: stageEnabled
                              ? color.withValues(alpha: 0.18)
                              : Colors.white.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: stageEnabled
                                ? color.withValues(alpha: 0.7)
                                : borderColor,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              stageEnabled ? Icons.check_circle : Icons.do_not_disturb_on,
                              size: 13,
                              color: stageEnabled ? color : textMuted,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              stageEnabled ? 'Enabled' : 'Skip Stage',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w600,
                                color: stageEnabled ? color : textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: children,
              ),
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: borderColor)),
              ),
              child: Row(
                children: [
                  if (onPrevious != null) ...[
                    OutlinedButton.icon(
                      onPressed: onPrevious,
                      icon: const Icon(Icons.arrow_back, size: 14),
                      label: const Text('Previous', style: TextStyle(fontSize: 11)),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: onRun,
                      icon: const Icon(Icons.play_arrow, size: 15),
                      label: Text(
                        runLabel,
                        style: const TextStyle(fontSize: 11.5),
                        overflow: TextOverflow.ellipsis,
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: color,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: const Color(0xFF1E293B),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                    ),
                  ),
                  if (onNext != null) ...[
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: onNext,
                      icon: const Icon(Icons.arrow_forward, size: 14),
                      label: const Text('Next', style: TextStyle(fontSize: 11)),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErpStage1Card({VoidCallback? onNext}) {
    if (widget.stage1Builder != null) {
      return widget.stage1Builder!(onNext: onNext);
    }
    const accentPurple = Color(0xFF8B5CF6);
    const borderColor = Color(0xFF1E293B);
    const textMuted = Color(0xFF94A3B8);

    return _erpBatchCardShell(
      title: 'Stage 1: Preprocessing',
      icon: Icons.cleaning_services,
      color: accentPurple,
      stageEnabled: _batchStage1Enabled,
      onStageEnabledChanged: (v) => setState(() => _batchStage1Enabled = v),
      onNext: onNext,
      runLabel: 'Run Preprocessing Only',
      onRun: !_busy && _prepFiles.isNotEmpty ? _runErpStage1Only : null,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Files (${_prepFiles.length})',
              style: const TextStyle(
                color: textMuted,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
            Row(
              children: [
                TextButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          final directory = await FilePicker.getDirectoryPath();
                          if (directory == null || !mounted) return;
                          final files = discoverErpRecordings(
                            directory,
                            firstSubjects: int.tryParse(_limit.text) ?? 2,
                          );
                          setState(() {
                            _prepFiles
                              ..clear()
                              ..addAll(files);
                          });
                        },
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(64, 24),
                  ),
                  child: const Text('Add Folder', style: TextStyle(fontSize: 11)),
                ),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          final picked = await pickFilteredFiles(
                            context,
                            allowMultiple: true,
                            type: FileType.custom,
                            allowedExtensions: ['edf', 'fif', 'ccseeg', 'json'],
                            recordingsOnly: true,
                          );
                          if (picked == null || !mounted) return;
                          setState(() {
                            for (final f in picked.files) {
                              if (f.path != null && !_prepFiles.contains(f.path)) {
                                _prepFiles.add(f.path!);
                              }
                            }
                          });
                        },
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(40, 24),
                  ),
                  child: const Text('Add', style: TextStyle(fontSize: 11)),
                ),
                TextButton(
                  onPressed: _busy || _prepFiles.isEmpty
                      ? null
                      : () => setState(() => _prepFiles.clear()),
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(40, 24),
                  ),
                  child: const Text(
                    'Clear',
                    style: TextStyle(color: Colors.red, fontSize: 11),
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 4),
        Container(
          height: 110,
          decoration: BoxDecoration(
            color: const Color(0xFF0A1628),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: borderColor),
          ),
          child: _prepFiles.isEmpty
              ? const Center(
                  child: Text(
                    'No raw files queued for preprocessing',
                    style: TextStyle(color: textMuted, fontSize: 11),
                  ),
                )
              : ListView.builder(
                  itemCount: _prepFiles.length,
                  itemBuilder: (context, idx) => ListTile(
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    title: Text(
                      _prepFiles[idx].split(Platform.pathSeparator).last,
                      style: const TextStyle(fontSize: 11),
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.close, size: 13),
                      onPressed: _busy
                          ? null
                          : () => setState(() => _prepFiles.removeAt(idx)),
                    ),
                  ),
                ),
        ),
        const SizedBox(height: 10),
        const Text(
          'BATCH PARAMETERS · SHARED WITH SINGLE RECORDING',
          style: TextStyle(
            color: textMuted,
            fontSize: 9.5,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.6,
          ),
        ),
        const SizedBox(height: 6),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          initiallyExpanded: true,
          title: const Text(
            '1. Channel setup & montage',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          subtitle: const Text(
            'Standard 10-20 / ERP-CORE montage & non-EEG channel exclusion',
            style: TextStyle(fontSize: 10.5, color: textMuted),
          ),
          children: [
            _check(
              'Interpolate bad channels automatically',
              _erpPrepBadChannels,
              (v) => _erpPrepBadChannels = v,
            ),
            _check(
              'Re-reference to Average / Linked Mastoids',
              _erpPrepRereference,
              (v) => _erpPrepRereference = v,
            ),
          ],
        ),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          initiallyExpanded: true,
          title: const Text(
            '2. Filtering & signal preparation',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          subtitle: const Text(
            'ERP bandpass 0.1–30.0 Hz · Line noise notch · GEDAI cleaning',
            style: TextStyle(fontSize: 10.5, color: textMuted),
          ),
          children: [
            _check(
              'ERP bandpass filter (0.1–30.0 Hz, zero-phase)',
              _erpPrepFilter,
              (v) => _erpPrepFilter = v,
            ),
            _check(
              'GEDAI / ocular & muscle artifact removal',
              _erpPrepGedai,
              (v) => _erpPrepGedai = v,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildErpStage2Card({VoidCallback? onPrevious, VoidCallback? onNext}) {
    const accentGreen = Color(0xFF10B981);

    return _erpBatchCardShell(
      title: 'Stage 2: Task & Event Markers',
      icon: Icons.flag_outlined,
      color: accentGreen,
      stageEnabled: _batchStage2Enabled,
      onStageEnabledChanged: (v) => setState(() => _batchStage2Enabled = v),
      onPrevious: onPrevious,
      onNext: onNext,
      runLabel: 'Inspect & Verify Markers',
      onRun: !_busy && _paths.isNotEmpty ? _inspect : null,
      children: [
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text(
            'Use Stage 1 outputs (or choose recordings directly)',
            style: TextStyle(fontSize: 11, color: Colors.white),
          ),
          value: _batchUseStage1Outputs,
          onChanged: _busy
              ? null
              : (v) => setState(() => _batchUseStage1Outputs = v ?? true),
        ),
        _card('1  Batch inputs', [
          TextButton.icon(
            onPressed: _busy ? null : _openResult,
            icon: const Icon(Icons.history),
            label: const Text('Open saved ERP results…'),
          ),
          const Text(
            'Start from continuous recordings with events, or reuse saved epoched condition files.',
            style: TextStyle(fontSize: 11),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _busy ? null : _addFiles,
                icon: const Icon(Icons.add),
                label: const Text('Files'),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : _addFolder,
                icon: const Icon(Icons.folder_open),
                label: const Text('Folder'),
              ),
              if (_paths.isNotEmpty)
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                          _paths.clear();
                          _inspection = null;
                          _fillProfile(null);
                        }),
                  child: const Text('Clear'),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text('${_selectedPaths.length} recordings selected'),
          if (_paths.isNotEmpty)
            TextButton(
              onPressed: _busy ? null : _reviewInputs,
              child: const Text('Review files and participant IDs…'),
            ),
        ]),
        _card('2  Task and event markers', [
          if (!_isPrepared) ...[
            _buildErpCorePresetBar(),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: _eventSource,
              decoration: const InputDecoration(
                labelText: 'Event timing source',
              ),
              items: const [
                DropdownMenuItem(
                  value: 'auto',
                  child: Text('Sidecar preferred, otherwise native events'),
                ),
                DropdownMenuItem(
                  value: 'sidecar',
                  child: Text('EEGLAB .evt sidecar only'),
                ),
                DropdownMenuItem(
                  value: 'native',
                  child: Text('EDF annotations / Status only'),
                ),
              ],
              onChanged: _busy
                  ? null
                  : (v) {
                      setState(() => _eventSource = v!);
                      _inspect();
                    },
            ),
          ],
          DropdownButtonFormField<String>(
            initialValue: _task,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Component'),
            items: [
              'Auto',
              'MMN',
              'N170',
              'N2pc',
              'N400',
              'P3',
              'LRP',
              'ERN',
              'Custom',
            ]
                .map(
                  (v) => DropdownMenuItem(
                    value: v,
                    child: Text(
                      v == 'Auto'
                          ? 'Suggest per file (all ERP CORE tasks)'
                          : v,
                    ),
                  ),
                )
                .toList(),
            onChanged: _busy
                ? null
                : (v) {
                    setState(() {
                      _task = v!;
                      if (v == 'Custom') _regroupEpochs = false;
                    });
                    _inspect();
                  },
          ),
          const SizedBox(height: 8),
          if (_profile != null)
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text(
                'Component guide',
                style: TextStyle(fontSize: 12),
              ),
              children: [
                Text(
                  erpTaskGuides[_profile!['task']] ?? erpTaskGuides['Custom']!,
                ),
              ],
            ),
          if (_scanFiles.isNotEmpty) ...[
            const SizedBox(height: 6),
            for (final task in _scanFiles
                .map((f) => erpMap(f['profile'])['task'])
                .whereType<String>()
                .toSet())
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(
                  '$task · ${_scanFiles.where((f) => erpMap(f['profile'])['task'] == task).length} recordings',
                ),
                subtitle: Text(() {
                  final p = erpMap(
                    _scanFiles.firstWhere(
                      (f) => erpMap(f['profile'])['task'] == task,
                    )['profile'],
                  );
                  final w = erpNumbers(p['window']);
                  return '${(p['roi'] as List).join(', ')} · ${(w.first * 1000).round()}–${(w.last * 1000).round()} ms';
                }()),
                trailing: TextButton(
                  onPressed: _busy
                      ? null
                      : () {
                          setState(() => _task = task);
                          _inspect();
                        },
                  child: const Text('Review'),
                ),
              ),
          ],
          if (_profile != null) ...[
            const SizedBox(height: 8),
            _field(_componentLabel, 'Component name'),
            _buildConditionEditor(),
          ],
          if (!_isPrepared)
            _check(
              'Require correct stimulus responses (where applicable)',
              _correct,
              (v) => _correct = v,
            ),
        ]),
      ],
    );
  }

  Widget _buildErpStage3Card({VoidCallback? onPrevious, VoidCallback? onNext}) {
    const accentAmber = Color(0xFFF59E0B);

    return _erpBatchCardShell(
      title: 'Stage 3: Windows & ERP Models',
      icon: Icons.analytics_outlined,
      color: accentAmber,
      stageEnabled: _batchStage3Enabled,
      onStageEnabledChanged: (v) => setState(() => _batchStage3Enabled = v),
      onPrevious: onPrevious,
      onNext: onNext,
      runLabel: 'Analyse ${_selectedPaths.length} recording(s)',
      onRun: _canRun ? _run : null,
      children: [
        if (_profile != null)
          _card('Time windows & ROI', [
            _field(
              _roi,
              _profile!['lateralized'] == true
                  ? 'Left ROI, right ROI'
                  : 'Electrodes / ROI',
            ),
            if (!_isPrepared)
              _pair('Epoch', _epoch0, _epoch1)
            else
              Text(
                'Saved trial window: ${_epoch0.text} to ${_epoch1.text} ms (preserved)',
              ),
            _pair('Baseline', _base0, _base1),
            _pair('Measurement window', _window0, _window1),
            DropdownButtonFormField<double>(
              initialValue: (_profile!['polarity'] as num).toDouble(),
              decoration: const InputDecoration(
                labelText: 'Component polarity',
              ),
              items: const [
                DropdownMenuItem(value: -1, child: Text('Negative')),
                DropdownMenuItem(value: 1, child: Text('Positive')),
              ],
              onChanged: _busy
                  ? null
                  : (v) => setState(() => _profile!['polarity'] = v!),
            ),
          ]),
        _card('3  Analyses', [
          const Text(
            'Always: mean, peak amplitude/latency, signed and positive/negative AUC, fractional-area/peak latency, GFP, paired subject statistics, corrected topography and TANOVA.',
            style: TextStyle(fontSize: 11),
          ),
          const SizedBox(height: 8),
          _field(
            _reject,
            'Amplitude rejection threshold (µV; 0 = off)',
            helper: 'Use Stage 1 Preprocessing or amplitude rejection.',
          ),
          _field(_bin, 'Model / statistical time-bin width (ms)'),
          _field(_permutations, 'Group sign-flip permutations'),
          _check(
            'Regression ERP (multichannel OLS)',
            _regression,
            (v) => _regression = v,
          ),
          if (_regression)
            _field(
              _metadata,
              'Optional trial predictor CSV path',
            ),
          if (!_isPrepared)
            _check(
              'Overlap correction (Unfold-style FIR / LSQR)',
              _deconvolution,
              (v) => _deconvolution = v,
            ),
          _check(
            'Time-resolved neural decoding (shrinkage LDA)',
            _decoding,
            (v) => _decoding = v,
          ),
          if (_decoding)
            _check(
              'Temporal generalization (train time × test time)',
              _generalization,
              (v) => _generalization = v,
            ),
          _check(
            'Export individual-trial measurements (advanced)',
            _exportTrials,
            (v) => _exportTrials = v,
          ),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text(
              'Solver, decoding and response parameters',
              style: TextStyle(fontSize: 12),
            ),
            children: [
              if (!_isPrepared)
                _pair('Response association window', _rtMin, _rtMax),
              _field(_folds, 'Blocked decoding folds (2–20)'),
              _field(_shrinkage, 'LDA shrinkage (0–1)'),
              if (!_isPrepared) ...[
                _field(_lsqrTolerance, 'Overlap solver tolerance'),
                _field(_lsqrIterations, 'Overlap solver maximum iterations'),
              ],
            ],
          ),
        ]),
      ],
    );
  }

  Widget _buildErpStage4Card({VoidCallback? onPrevious}) {
    const accentBlue = Color(0xFF3B82F6);

    return _erpBatchCardShell(
      title: 'Stage 4: ERP Plots & Group Statistics',
      icon: Icons.groups,
      color: accentBlue,
      onPrevious: onPrevious,
      runLabel: _result != null
          ? 'Open ERP Results & Plots Workbench'
          : 'Open ERP Results Workbench',
      onRun: _result != null
          ? () => setState(() => _batchShowResults = true)
          : (_canRun ? _run : null),
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: accentBlue.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: accentBlue.withValues(alpha: 0.3)),
          ),
          child: const Text(
            'Batch ERP waveforms, multi-condition topographies, latency/amplitude tables, LMM/GLM group models, and publication PDF reports.',
            style: TextStyle(fontSize: 11, color: Colors.white70),
          ),
        ),
        const SizedBox(height: 12),
        if (widget.config != null)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('Protocol', style: TextStyle(fontSize: 13)),
            children: [
              ProtocolTools(
                config: widget.config!,
                beforeSave: () {
                  _options();
                },
                onChanged: () => setState(_restoreProtocol),
              ),
            ],
          ),
        _card('4  Run and export', [
          if (_timingIssue != null)
            Text(
              _timingIssue!,
              style: const TextStyle(color: Colors.orangeAccent),
            ),
          _field(_output, 'Output folder'),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () async {
                        final path = await FilePicker.getDirectoryPath();
                        if (path != null && mounted) {
                          setState(() => _output.text = path);
                        }
                      },
                icon: const Icon(Icons.folder_open, size: 15),
                label: const Text('Choose output folder'),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : _openResultFolder,
                icon: const Icon(Icons.analytics_outlined, size: 15),
                label: const Text('Load ERP Folder'),
              ),
            ],
          ),
          if (_busy) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(value: _progress > 0 ? _progress : null),
          ],
          const SizedBox(height: 8),
          SelectableText(
            _busy || !_isPrepared
                ? _status
                : (_canRun
                      ? 'Ready: ${_conditions.length} conditions · ${_roi.text} · ${_window0.text}–${_window1.text} ms'
                      : 'Choose saved groups for each condition before averaging.'),
            style: const TextStyle(fontSize: 11),
          ),
          if (_result != null) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                OutlinedButton.icon(
                  onPressed: () => _groupModels(difference: false),
                  icon: const Icon(Icons.groups, size: 15),
                  label: const Text('Condition group models'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _groupModels(difference: true),
                  icon: const Icon(Icons.compare_arrows, size: 15),
                  label: const Text('Difference-wave group models'),
                ),
                TextButton.icon(
                  onPressed: () => Process.run(
                    Platform.isMacOS
                        ? 'open'
                        : Platform.isWindows
                            ? 'explorer'
                            : 'xdg-open',
                    [_output.text],
                  ),
                  icon: const Icon(Icons.folder, size: 15),
                  label: const Text('Open results folder'),
                ),
              ],
            ),
          ],
        ]),
      ],
    );
  }
  Future<void> _reviewInputs() async {
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Recordings and participant IDs'),
        content: SizedBox(
          width: 780,
          height: 450,
          child: ListView.builder(
            itemCount: _paths.length,
            itemBuilder: (context, i) {
              final path = _paths[i];
              final scan = _scanFiles
                  .where((f) => f['path'] == path)
                  .firstOrNull;
              return ListTile(
                title: Text(path.split(Platform.pathSeparator).last),
                subtitle: Text(
                  scan?['error']?.toString() ??
                      '${scan?['marker_source'] ?? 'Inspect to read markers'} · ${scan?['event_count'] ?? 0} events\nTiming comparison: ${_timingSummary(scan?['timing_audit'])}',
                ),
                trailing: SizedBox(
                  width: 150,
                  child: TextFormField(
                    initialValue: _subjects[path] ?? '',
                    decoration: const InputDecoration(
                      labelText: 'Participant ID',
                    ),
                    onChanged: (v) => _subjects[path] = v.trim(),
                  ),
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
        ],
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _reviewMarkers() async {
    final counts = <String, int>{};
    for (final f in _scanFiles) {
      erpMap(
        f['marker_counts'],
      ).forEach((k, v) => counts[k] = (counts[k] ?? 0) + (v as num).toInt());
    }
    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Detected marker assignments'),
          content: SizedBox(
            width: 650,
            height: 470,
            child: Column(
              children: [
                TextField(
                  controller: _markerSearch,
                  decoration: const InputDecoration(labelText: 'Find marker'),
                  onChanged: (_) => update(() {}),
                ),
                Expanded(
                  child: ListView(
                    children: [
                      for (final key in counts.keys.where(
                        (k) => k.toLowerCase().contains(
                          _markerSearch.text.toLowerCase(),
                        ),
                      ))
                        ListTile(
                          title: Text('$key · ${counts[key]} events'),
                          trailing: SegmentedButton<String>(
                            segments: [
                              for (final c in _conditions)
                                ButtonSegment(
                                  value: c.name,
                                  label: Text(
                                    c.name.length > 8
                                        ? '${c.name.substring(0, 7)}…'
                                        : c.name,
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                ),
                              const ButtonSegment(
                                value: '-',
                                label: Text(
                                  'Ignore',
                                  style: TextStyle(fontSize: 11),
                                ),
                              ),
                            ],
                            selected: {
                              () {
                                for (final c in _conditions) {
                                  final list = c.codesController.text
                                      .split(',')
                                      .map((s) => s.trim());
                                  if (list.contains(key)) return c.name;
                                }
                                return '-';
                              }(),
                            },
                            onSelectionChanged: (v) {
                              final sel = v.first;
                              for (final c in _conditions) {
                                final list = c.codesController.text
                                    .split(',')
                                    .map((s) => s.trim())
                                    .where((s) => s != key && s.isNotEmpty)
                                    .toList();
                                if (c.name == sel) {
                                  list.add(key);
                                }
                                c.codesController.text = list.join(', ');
                              }
                              update(() {});
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Use these assignments'),
            ),
          ],
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Map<String, dynamic> get _display {
    if (_file != null) {
      return _results.firstWhere((f) => f['path'] == _file, orElse: () => {});
    }
    return _groups.firstWhere((g) => g['task'] == _component, orElse: () => {});
  }

  Future<void> _groupModels({bool difference = false}) async {
    if (_result == null || _component.isEmpty) return;
    final path =
        '${_output.text}/Group_Statistics/ERP_${_component}_${difference ? 'difference' : 'conditions'}_group_input.csv';
    final dir = Directory(File(path).parent.path);
    await dir.create(recursive: true);
    String quote(dynamic v) => '"${v.toString().replaceAll('"', '""')}"';
    final lines = <String>[
      'filename,subjid,group,condn,Chan,Epoch,epoch_label,Condition,mean_amplitude_ERP,signed_auc_ERP,peak_amplitude_ERP,peak_latency_ms_ERP,fractional_area_latency_ms_ERP',
    ];
    for (final file in _results.where((f) => f['task'] == _component)) {
      final profile = erpMap(file['profile']);
      final subjid = file['subject'].toString();
      final groupVal = _participantGroups[subjid] ?? 'Unknown';
      final condNames =
          (file['condition_names'] as List?)?.cast<String>() ?? [];
      final keys = difference
          ? ['B_minus_A']
          : (condNames.isNotEmpty ? condNames : ['A', 'B']);

      for (final key in keys) {
        final m = erpMap(erpMap(file['measurements'])[key]);
        final label = difference
            ? 'B - A'
            : (condNames.contains(key)
                  ? key
                  : (profile['lateralized'] == true
                        ? (key == 'A' ? 'Ipsilateral' : 'Contralateral')
                        : profile[key == 'A' ? 'a_name' : 'b_name']));
        lines.add(
          [
            quote(file['path']),
            quote(file['subject']),
            quote(groupVal),
            quote(file['task']),
            quote((profile['roi'] as List).join('+')),
            '1',
            quote(label),
            quote(label),
            m['mean'] ?? '',
            m['signed_auc'] ?? '',
            m['peak_amplitude'] ?? '',
            m['peak_latency'] is num ? (m['peak_latency'] as num) * 1000 : '',
            m['fractional_area_latency'] is num
                ? (m['fractional_area_latency'] as num) * 1000
                : '',
          ].join(','),
        );
      }
    }
    await File(path).writeAsString('${lines.join('\n')}\n');
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => Scaffold(
          appBar: AppBar(
            title: Text('$_component · metadata and group models'),
          ),
          body: GroupStatisticsWorkbench(initialCsvPath: path),
        ),
      ),
    );
  }

  Widget _buildConditionEditor() {
    final emptyConditions = _emptyConditions;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Conditions (${_conditions.length})',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            TextButton.icon(
              onPressed: _busy
                  ? null
                  : () {
                      setState(() {
                        final nextIdx = _conditions.length + 1;
                        _conditions.add(
                          ErpConditionConfig(
                            name: 'Condition $nextIdx',
                            codes: [],
                            savedGroups: [],
                          ),
                        );
                      });
                    },
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add Condition'),
            ),
          ],
        ),
        if (emptyConditions.isNotEmpty) ...[
          Container(
            margin: const EdgeInsets.only(top: 4, bottom: 8),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.amber.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.amber.shade700.withValues(alpha: 0.5)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.warning_amber_rounded, size: 18, color: Colors.amber.shade400),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${emptyConditions.length} condition(s) have 0 matching epochs in this recording:',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Colors.amber.shade300,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                for (final ec in emptyConditions)
                  Padding(
                    padding: const EdgeInsets.only(left: 24, bottom: 2),
                    child: Text(
                      '• ${ec.name.isNotEmpty ? ec.name : "Condition"} (0 epochs)',
                      style: const TextStyle(fontSize: 11, color: Colors.white70),
                    ),
                  ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      ),
                      onPressed: _busy
                          ? null
                          : () {
                              setState(() {
                                for (final ec in emptyConditions) {
                                  _conditions.remove(ec);
                                  ec.dispose();
                                }
                              });
                            },
                      icon: const Icon(Icons.playlist_remove, size: 14),
                      label: Text(
                        'Skip empty (${emptyConditions.length}) & proceed',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                    if (_savedGroups.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          'Available in recording: ${_savedGroups.map((g) => "$g (×${_savedGroupTrialCount(g)})").join(", ")}',
                          style: const TextStyle(fontSize: 10, color: Colors.white60),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
        for (var i = 0; i < _conditions.length; i++) _buildConditionCard(i),
        if (!_isPrepared)
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 8),
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _reviewMarkers,
              icon: const Icon(Icons.flag),
              label: const Text('Assign from detected markers…'),
            ),
          ),
        if (_conditions.isEmpty || _validConditions.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text(
              'Add at least one condition with epochs to run analysis.',
              style: TextStyle(color: Colors.orangeAccent, fontSize: 11),
            ),
          ),
      ],
    );
  }

  Widget _buildConditionCard(int index) {
    final c = _conditions[index];
    final count = _conditionTrialCount(c);
    final isEmpty = _isConditionEmpty(c);
    return Card(
      key: ValueKey(c),
      margin: const EdgeInsets.symmetric(vertical: 4),
      elevation: 0,
      color: isEmpty
          ? Colors.amber.withValues(alpha: 0.05)
          : Theme.of(context).colorScheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: BorderSide(
          color: isEmpty
              ? Colors.amber.shade700
              : Theme.of(context).colorScheme.outlineVariant,
          width: isEmpty ? 1.5 : 1.0,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isEmpty)
              Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.amber.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  children: [
                    Icon(Icons.warning_amber_rounded, size: 14, color: Colors.amber.shade300),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        '0 matching epochs in recording',
                        style: TextStyle(fontSize: 10, color: Colors.amber.shade200, fontWeight: FontWeight.bold),
                      ),
                    ),
                    if (_conditions.length > 1)
                      InkWell(
                        onTap: _busy
                            ? null
                            : () {
                                setState(() {
                                  _conditions.removeAt(index).dispose();
                                });
                              },
                        child: const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 4),
                          child: Text(
                            'Skip condition',
                            style: TextStyle(fontSize: 10, color: Colors.amber, decoration: TextDecoration.underline),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: c.nameController,
                    decoration: InputDecoration(
                      labelText: 'Condition ${index + 1} Name',
                      isDense: true,
                    ),
                    onChanged: (v) {
                      c.name = v.trim();
                      setState(() {});
                    },
                  ),
                ),
                if (index > 0)
                  IconButton(
                    tooltip:
                        'Move condition earlier; first condition is the difference reference',
                    icon: const Icon(Icons.arrow_upward, size: 17),
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                            _conditions.insert(
                              index - 1,
                              _conditions.removeAt(index),
                            );
                          }),
                  ),
                if (_conditions.length > 1)
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: 'Remove condition',
                    onPressed: _busy
                        ? null
                        : () {
                            setState(() {
                              _conditions.removeAt(index).dispose();
                            });
                          },
                  ),
              ],
            ),
            const SizedBox(height: 6),
            if (_isPrepared) ...[
              Text(
                c.savedGroups.isEmpty
                    ? (c.name.isNotEmpty ? c.name : 'not selected')
                    : c.savedGroups.join(' + '),
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 4),
              ExpansionTile(
                key: ValueKey('groups-${identityHashCode(c)}'),
                initiallyExpanded: c.savedGroups.isEmpty,
                tilePadding: EdgeInsets.zero,
                title: Text(
                  c.savedGroups.isEmpty
                      ? 'Choose saved groups (0 epochs)'
                      : '$count trials · edit groups',
                  style: TextStyle(
                    fontSize: 11,
                    color: isEmpty ? Colors.amber.shade300 : null,
                  ),
                ),
                children: [
                  if (_savedGroups.isNotEmpty)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          'Available epoch groups in recording:',
                          style: TextStyle(fontSize: 10, color: Colors.grey.shade400),
                        ),
                      ),
                    ),
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      for (final g in _savedGroups)
                        FilterChip(
                          label: Text(
                            '$g ×${_savedGroupTrialCount(g)}',
                          ),
                          selected: c.savedGroups.contains(g),
                          onSelected: _busy
                              ? null
                              : (sel) {
                                  setState(() {
                                    if (sel) {
                                      c.savedGroups.add(g);
                                      for (
                                        var other = 0;
                                        other < _conditions.length;
                                        other++
                                      ) {
                                        if (other != index) {
                                          _conditions[other].savedGroups.remove(
                                            g,
                                          );
                                        }
                                      }
                                      if (c.name.startsWith('Condition ') ||
                                          c.name.isEmpty) {
                                        c.name = c.savedGroups.join(' + ');
                                        c.nameController.text = c.name;
                                      }
                                    } else {
                                      c.savedGroups.remove(g);
                                      if (c.savedGroups.isNotEmpty) {
                                        c.name = c.savedGroups.join(' + ');
                                        c.nameController.text = c.name;
                                      }
                                    }
                                  });
                                },
                        ),
                    ],
                  ),
                ],
              ),
            ] else ...[
              TextField(
                controller: c.codesController,
                decoration: InputDecoration(
                  labelText:
                      '${c.name.isEmpty ? "Condition ${index + 1}" : c.name} Event Codes (comma-separated)',
                  isDense: true,
                ),
                onChanged: (_) => setState(() {}),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildIndividualErpGallery(
    List<Map<String, dynamic>> current,
    Map<String, dynamic> d,
  ) {
    final filter = _gallerySearch.trim().toLowerCase();
    final visible = filter.isEmpty
        ? current
        : current
              .where(
                (f) =>
                    f['subject'].toString().toLowerCase().contains(filter) ||
                    (_participantGroups[f['subject'].toString()] ?? '')
                        .toLowerCase()
                        .contains(filter),
              )
              .toList();

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: const InputDecoration(
                    hintText: 'Search participants by ID or Group…',
                    prefixIcon: Icon(Icons.search, size: 18),
                    isDense: true,
                  ),
                  onChanged: (v) => setState(() => _gallerySearch = v),
                ),
              ),
              const SizedBox(width: 16),
              Text(
                'Showing ${visible.length} of ${current.length} participants',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (ctx) => ErpGroupLabelDialog(
                      files: current,
                      initialGroups: _participantGroups,
                      onSaved: (newGroups) {
                        setState(() {
                          _participantGroups.addAll(newGroups);
                        });
                      },
                    ),
                  );
                },
                icon: const Icon(Icons.group, size: 16),
                label: const Text('Manage Groups'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: GridView.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 380,
                mainAxisExtent: 210,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemCount: visible.length,
              itemBuilder: (ctx, i) {
                final f = visible[i];
                final subjid = f['subject'].toString();
                final grp = _participantGroups[subjid] ?? 'Unassigned';
                final isSelected = _file == f['path'];

                final measurements = erpMap(f['measurements']);
                final condNames =
                    (f['condition_names'] as List?)?.cast<String>() ?? [];
                final primaryCond = condNames.isNotEmpty
                    ? condNames.first
                    : 'A';
                final m = erpMap(
                  measurements[primaryCond] ??
                      (measurements.isNotEmpty
                          ? measurements.values.first
                          : null),
                );

                return Card(
                  elevation: isSelected ? 4 : 1,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(
                      color: isSelected
                          ? const Color(0xFF2563EB)
                          : Colors.grey.shade300,
                      width: isSelected ? 2 : 1,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              subjid,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: grp.toLowerCase().contains('med')
                                    ? Colors.purple.shade50
                                    : (grp.toLowerCase().contains('con')
                                          ? Colors.blue.shade50
                                          : Colors.grey.shade100),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: grp.toLowerCase().contains('med')
                                      ? Colors.purple.shade300
                                      : (grp.toLowerCase().contains('con')
                                            ? Colors.blue.shade300
                                            : Colors.grey.shade400),
                                ),
                              ),
                              child: Text(
                                grp,
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: grp.toLowerCase().contains('med')
                                      ? Colors.purple.shade800
                                      : (grp.toLowerCase().contains('con')
                                            ? Colors.blue.shade800
                                            : Colors.grey.shade800),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Expanded(
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: Colors.grey.shade200),
                            ),
                            child: CustomPaint(
                              size: Size.infinite,
                              painter: ErpWorkbenchWavePainter({
                                ...f,
                                'times': f['times'],
                                'condition_names': f['condition_names'],
                                'condition_waves': f['condition_waves'],
                                'profile': f['profile'],
                              }, negativeUp: _negativeUp),
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Peak: ${m['peak_amplitude'] != null ? (m['peak_amplitude'] as num).toStringAsFixed(1) : "—"} µV @ ${m['peak_latency'] != null ? ((m['peak_latency'] as num) * 1000).toStringAsFixed(0) : "—"} ms',
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.black87,
                              ),
                            ),
                            TextButton(
                              style: TextButton.styleFrom(
                                padding: EdgeInsets.zero,
                                visualDensity: VisualDensity.compact,
                              ),
                              onPressed: () {
                                setState(() {
                                  _file = f['path'] as String;
                                  _tabs.animateTo(0);
                                });
                              },
                              child: const Text(
                                'Inspect →',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _resultsPane() {
    if (_groups.isEmpty)
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(30),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.show_chart, size: 64),
              const SizedBox(height: 16),
              const Text(
                'ERP results',
                style: TextStyle(fontSize: 25, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Text(
                widget.batchMode
                    ? 'Choose a task folder, review the input type and task definitions, then run the batch.'
                    : _isPrepared
                    ? widget.linkedReview ? 'Using the accepted trials and conditions from your review. Measurements are being prepared.' : '${widget.activeRecording?.epochCount ?? 0} trials ready.\nChoose conditions and a measurement window at left, then Average & analyse ERP.'
                    : '1. Define locking events and named groups in the Epochs step.\n2. Save event epochs (with cleaning if needed).\n3. Select saved groups A/B here, review the task and window, then average.',
                textAlign: TextAlign.center,
              ),
              if ((_result?['failures'] as List? ?? []).isNotEmpty)
                SelectableText(
                  const JsonEncoder.withIndent(
                    '  ',
                  ).convert(_result!['failures']),
                ),
            ],
          ),
        ),
      );
    final d = _display;
    final current = _results.where((f) => f['task'] == _component).toList();
    final modelFile = _file == null
        ? (current.isEmpty ? <String, dynamic>{} : current.first)
        : d;
    final activeFiles = current
        .where((f) => _file == null || f['path'] == _file)
        .toList();
    final allLabels = activeFiles.isNotEmpty
        ? (activeFiles.first['labels'] as List? ?? []).cast<String>()
        : (d['labels'] as List? ?? []).cast<String>();
    final roiLabels = (erpMap(d['profile'])['roi'] as List? ?? [])
        .cast<String>();
    final effectivePlotChannel =
        _primaryPlotChannel != null &&
                allLabels.any(
                  (l) =>
                      l.toUpperCase() == _primaryPlotChannel!.toUpperCase(),
                )
            ? _primaryPlotChannel
            : null;
    final primaryWaveSource = effectivePlotChannel != null && activeFiles.isNotEmpty
        ? buildErpChannelSelectionWaveData(
            files: activeFiles,
            profile: erpMap(d['profile']),
            targetChannels: [effectivePlotChannel],
            smoothingMs: _displaySmoothing,
            axisLimits: _axisLimits,
          )
        : smoothedErpDisplay({
            ...d,
            ..._axisLimits,
          }, _displaySmoothing);
    final highlightedOnTopo = effectivePlotChannel != null
        ? {effectivePlotChannel}
        : roiLabels.toSet();

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF131D2E),
            border: Border(
              bottom: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
            ),
          ),
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 108,
                child: DropdownButtonFormField<String>(
                  initialValue: _component,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Task',
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 7,
                    ),
                    border: OutlineInputBorder(),
                  ),
                  items: _groups
                      .map(
                        (g) => DropdownMenuItem(
                          value: g['task'] as String,
                          child: Text(
                            '${g['task']}',
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => setState(() {
                    _component = v!;
                    _file = null;
                  }),
                ),
              ),
              SizedBox(
                width: 280,
                child: DropdownButtonFormField<String>(
                  key: ValueKey('$_component/$_file'),
                  initialValue: _file ?? 'group',
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Active Recording / Subject / Session',
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 7,
                    ),
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    DropdownMenuItem(
                      value: 'group',
                      child: Text(
                        '★ Grand Average (${d['n_subjects'] ?? current.length} subj · ${current.length} files)',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    for (var i = 0; i < current.length; i++)
                      DropdownMenuItem(
                        value: current[i]['path'] as String,
                        child: Builder(
                          builder: (_) {
                            final info = _describeRecording(current[i]);
                            return Text(
                              '#${i + 1}: ${info['subject']} · ${info['session']} — ${info['fileName']}',
                              style: const TextStyle(fontSize: 12),
                              overflow: TextOverflow.ellipsis,
                            );
                          },
                        ),
                      ),
                  ],
                  onChanged: (v) =>
                      setState(() => _file = v == 'group' ? null : v),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.white12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.chevron_left, size: 18),
                      tooltip: 'Previous recording',
                      onPressed: current.isEmpty
                          ? null
                          : () {
                              if (_file == null) {
                                setState(
                                  () => _file = current.last['path'] as String,
                                );
                              } else {
                                final idx = current.indexWhere(
                                  (f) => f['path'] == _file,
                                );
                                if (idx <= 0) {
                                  setState(() => _file = null);
                                } else {
                                  setState(
                                    () => _file =
                                        current[idx - 1]['path'] as String,
                                  );
                                }
                              }
                            },
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Text(
                        _file == null
                            ? 'Grand Avg (${current.length})'
                            : () {
                                final idx = current.indexWhere(
                                  (f) => f['path'] == _file,
                                );
                                return 'File ${idx + 1} of ${current.length}';
                              }(),
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.chevron_right, size: 18),
                      tooltip: 'Next recording',
                      onPressed: current.isEmpty
                          ? null
                          : () {
                              if (_file == null) {
                                setState(
                                  () => _file = current.first['path'] as String,
                                );
                              } else {
                                final idx = current.indexWhere(
                                  (f) => f['path'] == _file,
                                );
                                if (idx >= current.length - 1) {
                                  setState(() => _file = null);
                                } else {
                                  setState(
                                    () => _file =
                                        current[idx + 1]['path'] as String,
                                  );
                                }
                              }
                            },
                    ),
                  ],
                ),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: current.isEmpty
                    ? null
                    : () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ErpReviewWorkspace(
                            files: current,
                            task: _component,
                            output: _output.text,
                          ),
                        ),
                      ),
                icon: const Icon(Icons.tune, size: 15),
                label: const Text(
                  'Interactive batch review',
                  style: TextStyle(fontSize: 12),
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'Group statistics, participant labels & LMM/GLM models',
                onSelected: (action) {
                  if (action == 'label_groups') {
                    showDialog(
                      context: context,
                      builder: (ctx) => ErpGroupLabelDialog(
                        files: current,
                        initialGroups: _participantGroups,
                        onSaved: (newGroups) {
                          setState(() {
                            _participantGroups.clear();
                            _participantGroups.addAll(newGroups);
                          });
                        },
                      ),
                    );
                  } else if (action == 'cond_models') {
                    _groupModels();
                  } else if (action == 'diff_models') {
                    _groupModels(difference: true);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'label_groups',
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.label_outlined, size: 18),
                      title: Text('Label Participant Groups…'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'cond_models',
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.groups, size: 18),
                      title: Text('Condition Group Models (LMM/GLM)'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'diff_models',
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.compare_arrows, size: 18),
                      title: Text('Difference-Wave Group Models'),
                    ),
                  ),
                ],
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.groups_outlined, size: 15),
                      SizedBox(width: 6),
                      Text('Groups & Models', style: TextStyle(fontSize: 12)),
                      SizedBox(width: 4),
                      Icon(Icons.arrow_drop_down, size: 16),
                    ],
                  ),
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'Load or add ERP recordings and results',
                enabled: !_busy,
                onSelected: (action) {
                  if (action == 'load_ccserp') {
                    _openResult();
                  } else if (action == 'load_folder') {
                    _openResultFolder();
                  } else if (action == 'add_files') {
                    _addFiles();
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'load_ccserp',
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.file_open, size: 18),
                      title: Text('Load ERP (.ccserp)…'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'load_folder',
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.folder_open, size: 18),
                      title: Text('Load ERP Folder…'),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'add_files',
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.add_to_photos, size: 18),
                      title: Text('Add EEG Files…'),
                    ),
                  ),
                ],
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.folder_open_outlined, size: 15),
                      SizedBox(width: 6),
                      Text('Load / Add', style: TextStyle(fontSize: 12)),
                      SizedBox(width: 4),
                      Icon(Icons.arrow_drop_down, size: 16),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        TabBar(
          controller: _tabs,
          isScrollable: true,
          tabs: const [
            Tab(text: 'Waveforms'),
            Tab(text: 'Measurements'),
            Tab(text: 'Group / topography'),
            Tab(text: 'Models'),
            Tab(text: 'Decoding'),
            Tab(text: 'Quality'),
            Tab(text: 'Individual ERPs'),
            Tab(text: 'Publication plots'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: [
              SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildActiveRecordingIdentityCard(d, current),
                    // Compact single-row Channel Selector & Display Controls Bar
                    Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E293B),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.white10),
                      ),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          const Icon(
                            Icons.sensors,
                            size: 15,
                            color: Colors.cyanAccent,
                          ),
                          const Text(
                            'Primary Plot Channel:',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: Colors.cyanAccent,
                            ),
                          ),
                          ChoiceChip(
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            label: Text(
                              'Task ROI (${roiLabels.isEmpty ? "All" : roiLabels.join(", ")})',
                              style: const TextStyle(fontSize: 11),
                            ),
                            selected: effectivePlotChannel == null,
                            onSelected: (_) =>
                                setState(() => _primaryPlotChannel = null),
                          ),
                          for (final ch in <String>{
                            ...roiLabels,
                            for (final std in [
                              'Fz',
                              'FCz',
                              'Cz',
                              'CPz',
                              'Pz',
                              'Oz',
                              'PO7',
                              'PO8',
                              'C3',
                              'C4',
                            ])
                              if (allLabels.any(
                                (l) => l.toUpperCase() == std.toUpperCase(),
                              ))
                                allLabels.firstWhere(
                                  (l) => l.toUpperCase() == std.toUpperCase(),
                                ),
                          })
                            ChoiceChip(
                              visualDensity: VisualDensity.compact,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              label: Text(
                                ch,
                                style: const TextStyle(fontSize: 11),
                              ),
                              selected: effectivePlotChannel?.toUpperCase() ==
                                  ch.toUpperCase(),
                              onSelected: (sel) => setState(
                                () => _primaryPlotChannel = sel ? ch : null,
                              ),
                            ),
                          if (allLabels.isNotEmpty)
                            SizedBox(
                              height: 28,
                              child: DropdownButton<String?>(
                                value: effectivePlotChannel,
                                hint: const Text(
                                  'All channels…',
                                  style: TextStyle(fontSize: 11),
                                ),
                                underline: const SizedBox.shrink(),
                                items: [
                                  DropdownMenuItem<String?>(
                                    value: null,
                                    child: Text(
                                      'ROI (${roiLabels.join(", ")})',
                                      style: const TextStyle(fontSize: 11),
                                    ),
                                  ),
                                  for (final l in allLabels)
                                    DropdownMenuItem<String?>(
                                      value: l,
                                      child: Text(
                                        l,
                                        style: const TextStyle(fontSize: 11),
                                      ),
                                    ),
                                ],
                                onChanged: (v) =>
                                    setState(() => _primaryPlotChannel = v),
                              ),
                            ),
                          const SizedBox(width: 8),
                          FilterChip(
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            label: const Text(
                              'Negative up',
                              style: TextStyle(fontSize: 11),
                            ),
                            selected: _negativeUp,
                            onSelected: (v) => setState(() => _negativeUp = v),
                          ),
                          SizedBox(
                            height: 28,
                            child: DropdownButton<double>(
                              value: _displaySmoothing,
                              underline: const SizedBox.shrink(),
                              items: [
                                for (final ms in [0.0, 8.0, 16.0, 24.0, 40.0])
                                  DropdownMenuItem(
                                    value: ms,
                                    child: Text(
                                      ms == 0
                                          ? 'Smoothing off'
                                          : 'Smooth ${ms.round()} ms',
                                      style: const TextStyle(fontSize: 11),
                                    ),
                                  ),
                              ],
                              onChanged: (v) =>
                                  setState(() => _displaySmoothing = v!),
                            ),
                          ),
                          ActionChip(
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            avatar: Icon(
                              _showAxisLimits
                                  ? Icons.expand_less
                                  : Icons.straighten,
                              size: 14,
                            ),
                            label: const Text(
                              'Axis limits',
                              style: TextStyle(fontSize: 11),
                            ),
                            onPressed: () => setState(
                              () => _showAxisLimits = !_showAxisLimits,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_showAxisLimits)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: ErpAxisControls(
                          onChanged: (v) => setState(() => _axisLimits = v),
                        ),
                      ),
                    // Primary ERP Waveform Card
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFCBD5E1)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: const BoxDecoration(
                              color: Color(0xFFF1F5F9),
                              borderRadius: BorderRadius.vertical(
                                top: Radius.circular(7),
                              ),
                            ),
                            child: Row(
                              children: [
                                Text(
                                  effectivePlotChannel != null
                                      ? 'Electrode: $effectivePlotChannel'
                                      : 'ROI Average: ${roiLabels.join(", ")}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12,
                                    color: Color(0xFF0F172A),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    'Comparison: ${erpMap(d['profile'])['b_name']} − ${erpMap(d['profile'])['a_name']} · Measurement window: ${() {
                                      final w = erpNumbers(erpMap(d['profile'])['window']);
                                      return w.length == 2 ? '${(w[0] * 1000).round()} to ${(w[1] * 1000).round()} ms' : '';
                                    }()}',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: Color(0xFF475569),
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          SizedBox(
                            height: 295,
                            width: double.infinity,
                            child: ClipRRect(
                              borderRadius: const BorderRadius.vertical(
                                bottom: Radius.circular(7),
                              ),
                              child: MouseRegion(
                                onHover: (e) =>
                                    _hover.value = e.localPosition.dx,
                                onExit: (_) => _hover.value = null,
                                child: ValueListenableBuilder<double?>(
                                  valueListenable: _hover,
                                  builder: (context, hover, child) =>
                                      CustomPaint(
                                        painter: ErpWorkbenchWavePainter(
                                          primaryWaveSource,
                                          negativeUp: _negativeUp,
                                          hoverX: hover,
                                        ),
                                      ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Side-by-Side Condition A, Condition B, and Difference (B - A) Topographies
                    _buildMultiConditionTopoSection(
                      d,
                      current,
                      highlightedOnTopo,
                    ),
                    // Multi-Channel Waveform Grid with Region Presets & Electrode Selector Chips
                    ErpChannelGrid(
                      files: activeFiles,
                      profile: erpMap(d['profile']),
                      negativeUp: _negativeUp,
                      smoothingMs: _displaySmoothing,
                      axisLimits: _axisLimits,
                    ),
                  ],
                ),
              ),
              _table(
                [
                  'Participant',
                  'Condition',
                  'Mean µV',
                  'AUC µV s',
                  'Peak µV',
                  'Peak ms',
                  '50% area ms',
                ],
                [
                  for (final f in current)
                    for (final item in erpMap(f['measurements']).entries.where(
                      (e) =>
                          f['condition_names'] is! List ||
                          !(const ['A', 'B'].contains(e.key)),
                    ))
                      [
                        f['subject'],
                        item.key == 'B_minus_A'
                            ? '${erpMap(f['profile'])['b_name']} − ${erpMap(f['profile'])['a_name']}'
                            : item.key,
                        erpMap(item.value)['mean'],
                        erpMap(item.value)['signed_auc'],
                        erpMap(item.value)['peak_amplitude'],
                        (erpMap(item.value)['peak_latency'] as num?)
                            ?.toDouble()
                            .times1000,
                        (erpMap(item.value)['fractional_area_latency'] as num?)
                            ?.toDouble()
                            .times1000,
                      ],
                ],
              ),
              SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildMultiConditionTopoSection(
                      d,
                      current,
                      highlightedOnTopo,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '${d['warning'] ?? 'Participant-level descriptive map; select Group for population statistics.'}',
                    ),
                    if (d['statistics'] is List)
                      _table(
                        ['Measure', 'N', 'Difference', 'p', 'q (FDR)'],
                        [
                          for (final s in (d['statistics'] as List).map(erpMap))
                            [
                              s['metric'],
                              s['n_subjects'],
                              s['mean_difference'],
                              s['p'],
                              s['q_fdr'],
                            ],
                        ],
                        shrink: true,
                      ),
                    Text(
                      'TANOVA GMD ${d['tanova_gmd'] ?? '—'} · p ${d['tanova_p'] ?? '—'}',
                    ),
                    const SizedBox(height: 12),
                    SwitchListTile(
                      title: const Text(
                        'Mask channel-time maps at corrected p ≤ .05',
                      ),
                      value: _significantOnly,
                      onChanged: (v) => setState(() => _significantOnly = v),
                    ),
                    const Text(
                      'Channel × time t statistic. Red = positive, blue = negative; masked points are white.',
                    ),
                    if (erpNumbers(d['spatiotemporal_t']).isNotEmpty)
                      SizedBox(
                        height: 300,
                        width: double.infinity,
                        child: CustomPaint(
                          painter: ErpWorkbenchHeatPainter(
                            _statValues(
                              d,
                              'spatiotemporal_t',
                              'spatiotemporal_p_fwer',
                            ),
                            (d['labels'] as List).length,
                            (d['bin_times'] as List).length,
                          ),
                        ),
                      ),
                    if (d['labels'] is List)
                      Text('Rows: ${(d['labels'] as List).join(', ')}'),
                    if (d['regression_inference'] is Map) ...[
                      const SizedBox(height: 20),
                      const Text(
                        'rERP class beta: participant-level channel × time max-|t| inference',
                      ),
                      SizedBox(
                        height: 300,
                        width: double.infinity,
                        child: CustomPaint(
                          painter: ErpWorkbenchHeatPainter(
                            _statValues(
                              erpMap(d['regression_inference']),
                              't',
                              'p_fwer',
                            ),
                            (erpMap(d['regression_inference'])['channels']
                                    as List)
                                .length,
                            (erpMap(d['regression_inference'])['times'] as List)
                                .length,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              _models(modelFile),
              SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Participant ${modelFile['subject'] ?? ''}. ${erpMap(modelFile['decoding'])['method'] ?? 'Enable decoding before running.'}',
                    ),
                    if (modelFile['decoding'] is Map) ...[
                      Text(
                        '${erpMap(modelFile['decoding'])['folds_used']} usable folds; physical event classes. Scores do not establish significance.',
                      ),
                      SizedBox(
                        height: 330,
                        width: double.infinity,
                        child: CustomPaint(
                          painter: ErpWorkbenchWavePainter(
                            erpMap(modelFile['decoding']),
                            decode: true,
                          ),
                        ),
                      ),
                      if (erpMap(modelFile['decoding'])['generalization_auc']
                          is List) ...[
                        const Text(
                          'Temporal generalization: rows=train time, columns=test time; blue < .5, white=.5, red > .5.',
                        ),
                        SizedBox(
                          height: 320,
                          width: double.infinity,
                          child: CustomPaint(
                            painter: ErpWorkbenchHeatPainter(
                              erpNumbers(
                                erpMap(
                                  modelFile['decoding'],
                                )['generalization_auc'],
                              ),
                              (erpMap(modelFile['decoding'])['times'] as List)
                                  .length,
                              (erpMap(modelFile['decoding'])['times'] as List)
                                  .length,
                              probability: true,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
              SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final f in current) ...[
                      Text(
                        'Participant ${f['subject']} · ${f['n_a']}/${f['n_b']} accepted',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      Text(
                        'Source: ${f['marker_source']}\nExcluded: behavior ${f['rejected_behavior']}, edge ${f['rejected_boundary']}, amplitude ${f['rejected_amplitude']}',
                      ),
                      if (f['timing_audit'] is Map)
                        Text(
                          'Timing comparison: ${_timingSummary(f['timing_audit'])}',
                        ),
                      for (final w in (f['warnings'] as List? ?? []))
                        Text('• $w'),
                      const Divider(),
                    ],
                    for (final fail
                        in (_result?['failures'] as List? ?? []).map(erpMap))
                      Text('${fail['path']}: ${fail['error']}'),
                  ],
                ),
              ),
              _buildIndividualErpGallery(current, d),
              ErpPublicationPlotsView(
                files: current,
                groupData: d,
                profile: erpMap(d['profile']),
                participantGroups: _participantGroups,
                onGroupsChanged: (newGroups) {
                  setState(() {
                    _participantGroups.clear();
                    _participantGroups.addAll(newGroups);
                  });
                },
                outputDir: _output.text,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _table(
    List<String> headings,
    List<List<dynamic>> rows, {
    bool shrink = false,
  }) {
    final table = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columns: headings.map((h) => DataColumn(label: Text(h))).toList(),
        rows: rows
            .take(150)
            .map(
              (r) => DataRow(
                cells: r
                    .map(
                      (v) => DataCell(
                        Text(
                          v is num
                              ? v.toStringAsFixed(4)
                              : v?.toString() ?? '—',
                        ),
                      ),
                    )
                    .toList(),
              ),
            )
            .toList(),
      ),
    );
    return shrink
        ? table
        : SingleChildScrollView(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (rows.length > 150)
                  const Text(
                    'Showing 150 rows; all measurements are exported.',
                  ),
                table,
              ],
            ),
          );
  }

  String _timingSummary(dynamic audit) {
    final m = erpMap(audit);
    if (m.isEmpty) return 'not available';
    return m.entries.map((e) => '${e.key}: ${e.value}').join(' · ');
  }

  List<double> _statValues(Map<String, dynamic> d, String tKey, String pKey) {
    final t = erpNumbers(d[tKey]), p = erpNumbers(d[pKey]);
    if (!_significantOnly) return t;
    return [
      for (var i = 0; i < t.length; i++)
        i < p.length && p[i] <= .05 ? t[i] : 0.0,
    ];
  }

  Widget _models(Map<String, dynamic> file) => SingleChildScrollView(
    padding: const EdgeInsets.all(14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Participant ${file['subject'] ?? ''}; all channel/time coefficients are in JSON.',
        ),
        for (final key in ['regression', 'deconvolution'])
          if (file[key] is Map) ...[
            const SizedBox(height: 18),
            Text(
              key == 'regression' ? 'Regression ERP' : 'Overlap correction',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            Text('${erpMap(file[key])['method']}'),
            Text(
              'Predictors: ${(erpMap(file[key])['predictors'] as List).join(' | ')}',
            ),
            if (key == 'deconvolution')
              Text(
                'Events per category: ${erpMap(file[key])['event_counts']}. Solver converged for ${(erpMap(file[key])['solver'] as List).where((s) => erpMap(s)['converged'] == true).length}/${(erpMap(file[key])['solver'] as List).length} channels.',
              ),
            const SizedBox(height: 8),
            Builder(
              builder: (context) {
                final m = erpMap(file[key]);
                final coefficients = m['coefficients'] as List;
                final channels = (m['channels'] as List).cast<String>();
                final predictors = (m['predictors'] as List).cast<String>();
                final preferred = (erpMap(file['profile'])['roi'] as List).first
                    .toString();
                final selectedChannel = channels.contains(_modelChannels[key])
                    ? _modelChannels[key]!
                    : channels.firstWhere(
                        (l) => l.toUpperCase() == preferred.toUpperCase(),
                        orElse: () => channels.first,
                      );
                final selectedPredictor =
                    predictors.contains(_modelPredictors[key])
                    ? _modelPredictors[key]!
                    : predictors[1];
                final c = channels.indexOf(selectedChannel);
                final beta = erpNumbers(
                  (coefficients[predictors.indexOf(selectedPredictor)]
                      as List)[c],
                );
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 12,
                      children: [
                        DropdownButton<String>(
                          value: selectedChannel,
                          items: [
                            for (final l in channels)
                              DropdownMenuItem(value: l, child: Text(l)),
                          ],
                          onChanged: (v) =>
                              setState(() => _modelChannels[key] = v!),
                        ),
                        DropdownButton<String>(
                          value: selectedPredictor,
                          items: [
                            for (final p in predictors)
                              DropdownMenuItem(value: p, child: Text(p)),
                          ],
                          onChanged: (v) =>
                              setState(() => _modelPredictors[key] = v!),
                        ),
                      ],
                    ),
                    const Text(
                      'Model coefficient in µV per predictor unit; all channels and predictors are exported.',
                    ),
                    SizedBox(
                      height: 300,
                      width: double.infinity,
                      child: CustomPaint(
                        painter: ErpWorkbenchWavePainter({
                          'times': m['times'],
                          'a': beta,
                          'b': <double>[],
                          'model_plot': true,
                          'profile': {
                            'a_name': selectedPredictor,
                            'b_name': '',
                          },
                        }),
                      ),
                    ),
                  ],
                );
              },
            ),
            if (key == 'deconvolution') Text('${erpMap(file[key])['scope']}'),
          ],
        if (file['regression'] == null && file['deconvolution'] == null)
          const Text(
            'Enable regression ERP or overlap correction before running.',
          ),
      ],
    ),
  );
}

extension on double {
  double get times1000 => this * 1000;
}
