import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'processing_progress.dart';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'filtered_file_picker.dart';
import 'package:flutter/material.dart';

import 'extraction_service.dart';
import 'models.dart';
import 'recording_loader.dart';

typedef MicrostateProgress = void Function(double value, String message);

class MicrostateOptions {
  const MicrostateOptions({
    this.minStates = 3,
    this.maxStates = 8,
    this.selectedStates = 8,
    this.repetitions = 10,
    this.maxIterations = 1000,
    this.convergence = 1e-6,
    this.minPeakDistanceMs = 10,
    this.peaksPerRecording = 300,
    this.gfpThresholdSd = 1.5,
    this.minSegmentMs = 30,
    this.seed = 12345,
    this.syntaxWordLength = 6,
    this.removeEpochDc = true,
    this.syntaxLegacyWindows = false,
  });

  final int minStates;
  final int maxStates;
  final int selectedStates;
  final int repetitions;
  final int maxIterations;
  final double convergence;
  final double minPeakDistanceMs;
  final int peaksPerRecording;
  final double gfpThresholdSd;
  final double minSegmentMs;
  final int seed;
  final int syntaxWordLength;
  final bool removeEpochDc;
  final bool syntaxLegacyWindows;

  Map<String, Object> toJson() => {
    'min_states': minStates,
    'max_states': maxStates,
    'selected_states': selectedStates,
    'repetitions': repetitions,
    'max_iterations': maxIterations,
    'convergence': convergence,
    'min_peak_distance_ms': minPeakDistanceMs,
    'peaks_per_recording': peaksPerRecording,
    'gfp_threshold_sd': gfpThresholdSd,
    'min_segment_ms': minSegmentMs,
    'seed': seed,
    'syntax_word_length': syntaxWordLength,
    'remove_epoch_dc': removeEpochDc,
    'syntax_legacy_windows': syntaxLegacyWindows,
  };
}

class MicrostateResult {
  const MicrostateResult({
    required this.outputDirectory,
    this.removeEpochDc = false,
    required this.selectedStates,
    required this.stateLabels,
    required this.channelLabels,
    required this.channelPositions,
    required this.prototypes,
    required this.canonicalCorrelations,
    required this.modelFits,
    required this.recordings,
  });

  final String outputDirectory;
  final bool removeEpochDc;
  final int selectedStates;
  final List<String> stateLabels;
  final List<String> channelLabels;
  final List<MicrostateScalpPosition> channelPositions;
  final List<List<double>> prototypes;
  final List<double?> canonicalCorrelations;
  final List<Map<String, num>> modelFits;
  final List<MicrostateRecordingResult> recordings;

  factory MicrostateResult.fromJson(
    String outputDirectory,
    Map<String, dynamic> json,
  ) => MicrostateResult(
    outputDirectory: outputDirectory,
    removeEpochDc: json['remove_epoch_dc'] == true,
    selectedStates: (json['selected_states'] as num).toInt(),
    stateLabels: json['state_labels'] is List
        ? [for (final x in json['state_labels'] as List) x as String]
        : [
            for (var i = 0; i < (json['selected_states'] as num).toInt(); i++)
              String.fromCharCode(65 + i),
          ],
    channelLabels: [
      for (final x in json['channel_labels'] as List) x as String,
    ],
    channelPositions: [
      for (final x in json['channel_positions'] as List)
        MicrostateScalpPosition.fromJson(x as Map<String, dynamic>, legacyOrientation: json['scalp_orientation'] == null),
    ],
    prototypes: [
      for (final row in json['prototypes'] as List)
        [for (final x in row as List) (x as num).toDouble()],
    ],
    canonicalCorrelations: [
      for (final x in json['canonical_correlations'] as List)
        (x as num?)?.toDouble(),
    ],
    modelFits: [
      for (final x in json['model_fits'] as List)
        (x as Map<String, dynamic>).map((k, v) => MapEntry(k, v as num)),
    ],
    recordings: [
      for (final x in json['recordings'] as List)
        MicrostateRecordingResult.fromJson(x as Map<String, dynamic>),
    ],
  );
}

const _legacyMetaLabels = <String>{'T3','T4','T5','T6','NZ','IZ','C3','C4','CZ','F3','F4','F7','F8','FPZ','FP1','FP2','FZ','O1','O2','P3','P4','PZ','T7/T3','T8/T4','P7/T5','P8/T6','OZ','AF7','AF3','AFZ','AF4','AF8','F5','F1','F2','F6','FT7','FC5','FC3','FC1','FCZ','FC2','FC4','FC6','FT8','C5','C1','C2','C6','TP7','CP5','CP3','CP1','CPZ','CP2','CP4','CP6','TP8','P5','P1','P2','P6','PO7','PO3','POZ','PO4','PO8','F9','F10','FT9','FT10','T9','T10','P9','P10'};
/// One representative sequence per entropy class; adjacent repeats are omitted.
Map<String, String> microstateSyntaxExamples(int length, {int maxStates = 8}) {
  final examples = <String, String>{};
  if (length < 2 || length > 8) return examples;
  final word = <int>[0];
  void visit(int highest) {
    if (word.length == length) {
      final counts = <int, int>{};
      for (final state in word) { counts[state] = (counts[state] ?? 0) + 1; }
      var entropy = 0.0;
      for (final count in counts.values) { final p = count / length; entropy -= p * math.log(p) / math.ln2; }
      examples.putIfAbsent(entropy.toStringAsFixed(3), () => word.map((i) => String.fromCharCode(65 + i)).join(' '));
      return;
    }
    for (var state = 0; state <= math.min(highest + 1, maxStates - 1); state++) {
      if (state == word.last) continue;
      word.add(state); visit(math.max(highest, state)); word.removeLast();
    }
  }
  visit(0);
  return examples;
}

const _legacyAliasPositions = <String, List<double>>{'T7': [-1.0, 0.0],'T8': [1.0, 1.2246467991473532e-16],'P7': [-0.8090556128140002, -0.587840406937045],'P8': [0.8090556128140003, -0.5878404069370448]};
class MicrostateScalpPosition {
  const MicrostateScalpPosition({
    required this.label,
    required this.x,
    required this.y,
  });
  final String label;
  final double x;
  final double y;

  factory MicrostateScalpPosition.fromJson(Map<String, dynamic> json, {bool legacyOrientation = false}) {
    final label = json['label'] as String;
    final x = (json['x'] as num).toDouble(), y = (json['y'] as num).toDouble();
    if (legacyOrientation) {
      final alias = _legacyAliasPositions[label.toUpperCase()];
      if (alias != null) return MicrostateScalpPosition(label: label, x: alias[0], y: alias[1]);
      if (_legacyMetaLabels.contains(label.toUpperCase())) return MicrostateScalpPosition(label: label, x: -y, y: -x);
    }
    return MicrostateScalpPosition(label: label, x: x, y: y);
  }
}

class MicrostateRecordingResult {
  const MicrostateRecordingResult({
    required this.filename,
    required this.sampleRate,
    required this.gevTotal,
    required this.states,
    required this.transitions,
    required this.sequence,
    required this.stateProbabilities,
    required this.sequenceMetrics,
    this.syntax = const {},
    this.sampleCsv = '',
  });

  final String filename;
  final double sampleRate;
  final double gevTotal;
  final List<Map<String, dynamic>> states;
  final List<List<double>> transitions;
  final List<int> sequence;
  final List<List<double>> stateProbabilities;
  final Map<String, num> sequenceMetrics;
  final Map<String, dynamic> syntax;
  final String sampleCsv;

  factory MicrostateRecordingResult.fromJson(Map<String, dynamic> json) =>
      MicrostateRecordingResult(
        syntax: Map<String, dynamic>.from(json['syntax'] as Map? ?? {}),
        sampleCsv: json['sample_csv'] as String? ?? '',
        filename: json['filename'] as String,
        sampleRate: (json['sample_rate'] as num).toDouble(),
        gevTotal: (json['gev_total'] as num).toDouble(),
        states: [
          for (final x in json['states'] as List)
            Map<String, dynamic>.from(x as Map),
        ],
        transitions: [
          for (final row in json['transition_matrix'] as List)
            [for (final x in row as List) (x as num).toDouble()],
        ],
        sequence: [
          for (final x in json['sequence'] as List) (x as num).toInt(),
        ],
        stateProbabilities: json['state_probabilities'] is List
            ? [
                for (final row in json['state_probabilities'] as List)
                  [for (final x in row as List) (x as num).toDouble()],
              ]
            : const [],
        sequenceMetrics: (json['sequence_metrics'] as Map<String, dynamic>).map(
          (k, v) => MapEntry(k, v as num),
        ),
      );
}

// Top-level worker boundaries prevent Isolate closures from capturing UI State,
// progress callbacks, or WidgetsFlutterBinding through shared async contexts.
Future<void> writeMicrostateSignalInWorker(
  String path,
  Map<String, dynamic> signal,
) => Isolate.run(() => File(path).writeAsString(jsonEncode(signal)));

Future<Map<String, dynamic>> decodeMicrostateJsonInWorker(String rawJson) =>
    Isolate.run(() => jsonDecode(rawJson) as Map<String, dynamic>);

class MicrostateService {
  Process? _process;
  bool _cancelled = false;

  void cancel() {
    _cancelled = true;
    _process?.kill();
  }

  Future<MicrostateResult> run({
    required List<EegRecording> recordings,
    required String outputDirectory,
    required MicrostateOptions options,
    required MicrostateProgress onProgress,
  }) async {
    if (recordings.isEmpty) throw ArgumentError('No recordings selected.');
    _cancelled = false;
    final temp = await Directory.systemTemp.createTemp('ccs_microstates_');
    try {
      final inputs = <String>[];
      final names = <String>[];
      for (var i = 0; i < recordings.length; i++) {
        onProgress(
          i / recordings.length * .1,
          'Loading full-resolution input ${i + 1}/${recordings.length}',
        );
        final recording = await RecordingLoader().loadFull(recordings[i]);
        final file = File('${temp.path}/input_$i.ccseeg.json');
        onProgress(
          i / recordings.length * .1,
          'Preparing input ${i + 1}/${recordings.length}: ${names.isEmpty ? recording.path : File(recording.path).uri.pathSegments.last}',
        );
        final signal = {
          'format': 'ccseeg-v1',
          'sample_rate': recording.sampleRate,
          'labels': recording.labels,
          'channels': recording.preview,
          if (recording.pointsPerEpoch != null)
            'source_epoch_samples': recording.pointsPerEpoch,
        };
        await writeMicrostateSignalInWorker(file.path, signal);
        if (_cancelled) throw StateError('Analysis cancelled');
        inputs.add(file.path);
        names.add(File(recording.path).uri.pathSegments.last);
      }
      await Directory(outputDirectory).create(recursive: true);
      final job = File('${temp.path}/job.json');
      await job.writeAsString(
        jsonEncode({
          'job_type': 'microstates',
          'input': inputs.first,
          'output': outputDirectory,
          'format': 'ccseeg',
          'epoch_seconds': 2.0,
          'options': _emptyEngineOptions,
          'microstate_inputs': inputs,
          'microstate_names': names,
          'microstate_options': options.toJson(),
        }),
      );
      final process = await Process.start(ExtractionService.findEngine(), [
        job.path,
      ]);
      _process = process;
      if (_cancelled) process.kill();
      final errors = <String>[];
      final stderrDone = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .forEach((line) {
            if (line.startsWith('PROGRESS ')) {
              final parts = line.split(' ');
              onProgress(
                .1 + .88 * (double.tryParse(parts[1]) ?? 0) / 100,
                parts.skip(2).join(' '),
              );
            } else if (line.trim().isNotEmpty) {
              errors.add(line);
            }
          });
      final stdout = await process.stdout.transform(utf8.decoder).join();
      final code = await process.exitCode;
      await stderrDone;
      _process = null;
      if (code != 0) {
        throw StateError(
          errors.isEmpty
              ? 'Microstate engine exited with code $code'
              : errors.join('\n'),
        );
      }
      onProgress(.99, 'Reading microstate and syntax results…');
      final decoded = await decodeMicrostateJsonInWorker(stdout);
      final result = MicrostateResult.fromJson(outputDirectory, decoded);
      onProgress(1, 'Microstate analysis and exports complete');
      return result;
    } finally {
      _process = null;
      await temp.delete(recursive: true);
    }
  }
}

const _emptyEngineOptions = <String, Object>{
  'mode': 'full',
  'start_seconds': 0,
  'end_seconds': 0,
  'bin_seconds': 60,
  'psd': false,
  'fooof': false,
  'irasa': false,
  'nonlinear': false,
  'acw': false,
  'connectivity': false,
  'mic': false,
  'mim': false,
  'gc': false,
  'gc_tr': false,
  'coh': false,
  'plv': false,
  'ciplv': false,
  'pli': false,
  'wpli': false,
  'remove_non_eeg': false,
  'exclusions': <String>[],
  'non_eeg_channels': <String>[],
};

class MicrostateAnalysisView extends StatefulWidget {
  const MicrostateAnalysisView({
    super.key,
    this.activeRecording,
    this.batchMode = false,
    this.stage1Builder,
    this.onRunPreprocessing,
    this.onCloseBatch,
  });
  final EegRecording? activeRecording;
  final bool batchMode;
  final Widget Function({VoidCallback? onNext})? stage1Builder;
  final Future<List<String>> Function()? onRunPreprocessing;
  final VoidCallback? onCloseBatch;

  @override
  State<MicrostateAnalysisView> createState() => _MicrostateAnalysisViewState();
}

class _MicrostateAnalysisViewState extends State<MicrostateAnalysisView> {
  final _service = MicrostateService();
  final _loader = RecordingLoader();
  final _states = TextEditingController(text: '8');
  final _peaks = TextEditingController(text: '300');
  final _segment = TextEditingController(text: '30');
  final _batchLimit = TextEditingController(text: '0');
  final List<String> _batchPaths = [];
  final List<String> _prepFiles = [];
  bool get _batch => widget.batchMode;
  bool _running = false;
  double _progress = 0;
  int _syntaxWordLength = 6;
  bool _syntaxLegacyWindows = false;
  bool _removeEpochDc = true;
  bool _batchPreprocessedInput = false;
  bool _batchSkipExisting = false;
  bool _batchTabbedView = false;
  int _batchActiveStage = 0;
  bool _batchStage1Enabled = true;
  bool _batchStage2Enabled = true;
  bool _batchStage3Enabled = true;
  bool _batchUseStage1Outputs = true;
  bool _batchShowResults = false;
  bool _msPrepFilter = true;
  bool _msPrepBadChannels = true;
  bool _msPrepRereference = true;
  bool _msPrepGedai = true;
  bool _cancelRequested = false;
  bool _pickingOutput = false;
  String _message = '';
  String? _outputDirectory;
  MicrostateResult? _result;
  int _recordingIndex = 0;
  EegRecording? _interactiveRecording;
  List<EegRecording> _analysisInputs = const [];
  double _timelineStartSeconds = 0;
  int _transitionMode = 1; // 0 all samples, 1 leaving a state, 2 versus chance
  double _timelineWindowSeconds = 5;
  bool _similarityOverlay = false;
  int _similarityState = 0, _timelineChannelOffset = 0;
  int _timelineWaveformChannels = 6;
  final Set<int> _hiddenSimilarityStates = {};

  EegRecording? get _interactiveInput =>
      _interactiveRecording ?? widget.activeRecording;

  @override
  void dispose() {
    _service.cancel();
    _states.dispose();
    _peaks.dispose();
    _segment.dispose();
    _batchLimit.dispose();
    super.dispose();
  }

  Future<void> _addBatch() async {
    final picked = await pickFilteredFiles(
      context,
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: const [
        'edf',
        'set',
        'fif',
        'mat',
        'vhdr',
        'json',
        'orb',
        'signal',
      ],
    );
    if (picked == null) return;
    setState(() {
      for (final f in picked.files) {
        if (f.path != null && !_batchPaths.contains(f.path))
          _batchPaths.add(f.path!);
      }
    });
  }

  Future<void> _chooseInteractiveRecording() async {
    final picked = await pickFilteredFiles(
      context,
      allowMultiple: false,
      type: FileType.custom,
      allowedExtensions: const [
        'edf',
        'set',
        'fif',
        'mat',
        'vhdr',
        'json',
        'orb',
        'signal',
      ],
    );
    final path = picked == null || picked.files.isEmpty
        ? null
        : picked.files.first.path;
    if (path == null) return;
    setState(() => _message = 'Loading ${_name(path)}…');
    try {
      final recording = await _loader.load(path);
      if (!mounted) return;
      setState(() {
        _interactiveRecording = recording;
        _result = null;
        _message = '';
      });
    } catch (error) {
      if (mounted)
        setState(() => _message = 'Could not load recording: $error');
    }
  }

  String _name(String path) => File(path).uri.pathSegments.last;

  Future<String?> _pickOutputDirectory({String? dialogTitle}) async {
    if (_pickingOutput) return null;
    setState(() => _pickingOutput = true);
    try {
      final chosen = await pickDirectorySafe(
        dialogTitle: dialogTitle ?? 'Choose microstates output folder',
        currentDirectory: _outputDirectory,
        fallbackFilePath: _batch
            ? _batchPaths.firstOrNull
            : _interactiveInput?.path,
      );
      if (chosen != null && mounted) {
        setState(() => _outputDirectory = chosen);
      }
      return chosen;
    } finally {
      if (mounted) setState(() => _pickingOutput = false);
    }
  }

  Future<void> _run() async {
    final paths = _batch ? List<String>.of(_batchPaths) : const <String>[];
    if (!_batch && _interactiveInput == null) return;
    if (_batch && paths.isEmpty) return;
    var output = _outputDirectory;
    output ??= await _pickOutputDirectory(
      dialogTitle: 'Microstate analysis output directory',
    );
    if (output == null) return;
    setState(() {
      _running = true;
      _progress = 0;
      _message = 'Loading recordings…';
      _cancelRequested = false;
      _outputDirectory = output;
    });
    try {
      final recordings = <EegRecording>[];
      if (_batch) {
        for (var i = 0; i < paths.length; i++) {
          if (_cancelRequested) throw StateError('Analysis cancelled');
          if (mounted)
            setState(() {
              _progress = .12 * i / paths.length;
              _message = 'Loading ${i + 1}/${paths.length}: ${_name(paths[i])}';
            });
          recordings.add(await _loader.load(paths[i]));
        }
      } else {
        recordings.add(_interactiveInput!);
      }
      if (_cancelRequested) throw StateError('Analysis cancelled');
      final k = int.tryParse(_states.text)?.clamp(3, 8) ?? 8;
      final result = await _service.run(
        recordings: recordings,
        outputDirectory: output,
        options: MicrostateOptions(
          selectedStates: k,
          syntaxWordLength: _syntaxWordLength,
          removeEpochDc: _removeEpochDc,
          syntaxLegacyWindows: _syntaxLegacyWindows,
          peaksPerRecording: int.tryParse(_peaks.text)?.clamp(20, 5000) ?? 300,
          minSegmentMs: double.tryParse(_segment.text)?.clamp(0, 1000) ?? 30,
        ),
        onProgress: (p, m) {
          if (mounted)
            setState(() {
              _progress = math.max(_progress, .12 + .88 * p);
              _message = m;
            });
        },
      );
      if (mounted)
        setState(() {
          _analysisInputs = recordings;
          _result = result;
          _batchShowResults = true;
          _recordingIndex = 0;
          _timelineStartSeconds = 0;
        });
    } catch (e) {
      if (mounted) setState(() => _message = 'Error: $e');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_batch) {
      return _buildUniformMicrostateBatchWorkspace(context);
    }
    return _buildInteractiveMicrostateLayout(context);
  }

  Future<void> _runMicrostateStage1Only() async {
    if (widget.onRunPreprocessing != null) {
      setState(() {
        _running = true;
        _message = 'Running Stage 1 Preprocessing…';
      });
      try {
        final written = await widget.onRunPreprocessing!();
        if (written.isNotEmpty && mounted) {
          setState(() {
            _batchPaths
              ..clear()
              ..addAll(written);
            _result = null;
          });
        }
      } finally {
        if (mounted) setState(() => _running = false);
      }
      return;
    }
    if (_prepFiles.isNotEmpty) {
      setState(() {
        _batchPaths
          ..clear()
          ..addAll(_prepFiles);
        _result = null;
      });
    }
  }

  Future<void> _runFullMicrostatePipeline() async {
    if (_batchStage1Enabled && !_batchPreprocessedInput) {
      await _runMicrostateStage1Only();
    }
    if (_batchPaths.isNotEmpty && !_running) {
      await _run();
    }
  }

  Widget _buildUniformMicrostateBatchWorkspace(BuildContext context) {
    const bgColor = Color(0xFFF0F4F8);
    const cardColor = Color(0xFFFFFFFF);
    const borderColor = Color(0xFFCBD5E1);
    const textMuted = Color(0xFF64748B);
    const accentBlue = Color(0xFF3B6EA5);
    const accentGreen = Color(0xFF16A34A);

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
                    '${_batchPaths.length} files queued',
                    style: const TextStyle(color: textMuted, fontSize: 11),
                  ),
                  if (_prepFiles.isNotEmpty ||
                      _batchPaths.isNotEmpty ||
                      _result != null) ...[
                    const SizedBox(width: 8),
                    TextButton.icon(
                      onPressed: _running
                          ? null
                          : () => setState(() {
                              _prepFiles.clear();
                              _batchPaths.clear();
                              _result = null;
                              _batchShowResults = false;
                              _recordingIndex = 0;
                              _analysisInputs = const [];
                              _message = '';
                            }),
                      icon: const Icon(Icons.clear_all, size: 14),
                      label: const Text('Clear All', style: TextStyle(fontSize: 11)),
                      style: TextButton.styleFrom(
                        foregroundColor: textMuted,
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      ),
                    ),
                  ],
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
                            : 'View Microstate Results',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  if (_running)
                    TextButton.icon(
                      onPressed: () {
                        setState(() => _cancelRequested = true);
                        _service.cancel();
                      },
                      icon: const Icon(Icons.stop_circle, size: 14),
                      label: const Text('Cancel', style: TextStyle(fontSize: 11)),
                      style: TextButton.styleFrom(
                        foregroundColor: const Color(0xFFDC2626),
                      ),
                    )
                  else
                    FilledButton.icon(
                      onPressed: _batchPaths.isNotEmpty ||
                              (_batchStage1Enabled &&
                                  !_batchPreprocessedInput &&
                                  _prepFiles.isNotEmpty)
                          ? _runFullMicrostatePipeline
                          : null,
                      icon: const Icon(Icons.play_circle_filled, size: 14),
                      label: Text(
                        _batchStage1Enabled && !_batchPreprocessedInput
                            ? 'Run Full Pipeline'
                            : 'Run Microstate Batch',
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
            Expanded(child: _buildInteractiveMicrostateLayout(context))
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
                  'Batch parameters are configured inside each stage below. Preprocess raw recordings in Stage 1, configure canonical microstate clustering in Stage 2, set back-fitting & syntax parameters in Stage 3, and inspect/export group microstate maps in Stage 4.',
                  style: TextStyle(color: Color(0xFF475569), fontSize: 11),
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
                          _outputDirectory == null
                              ? 'Next to source files (default for each recording)'
                              : _outputDirectory!,
                          style: TextStyle(
                            color: _outputDirectory == null
                                ? textMuted
                                : const Color(0xFF1E293B),
                            fontSize: 12,
                            fontWeight: _outputDirectory == null
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
                    onPressed: _running || _pickingOutput
                        ? null
                        : () => _pickOutputDirectory(
                            dialogTitle:
                                'Select Microstates batch output directory',
                          ),
                    icon: _pickingOutput
                        ? const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.folder_open, size: 14),
                    label: Text(_pickingOutput ? 'Opening…' : 'Browse…'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                    ),
                  ),
                  if (_outputDirectory != null) ...[
                    const SizedBox(width: 6),
                    IconButton(
                      tooltip: 'Reset to default output location',
                      icon: const Icon(Icons.clear, size: 16, color: textMuted),
                      onPressed: _running
                          ? null
                          : () => setState(() => _outputDirectory = null),
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
                              'Already preprocessed: start with microstates',
                              style: TextStyle(fontSize: 12),
                            ),
                            value: _batchPreprocessedInput,
                            onChanged: _running
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
                            onChanged: _running
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
                      _batchLimit,
                      'Folder import limit (0 = all subjects)',
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
            _buildMicrostateBatchStageTabs(),

            // 6. 4 Stage Cards (Columns or Tabs)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                child: _batchTabbedView
                    ? switch (_batchActiveStage) {
                        0 => _buildMsStage1Card(
                            onNext: () => setState(() => _batchActiveStage = 1),
                          ),
                        1 => _buildMsStage2Card(
                            onPrevious: _batchPreprocessedInput
                                ? null
                                : () => setState(() => _batchActiveStage = 0),
                            onNext: () => setState(() => _batchActiveStage = 2),
                          ),
                        2 => _buildMsStage3Card(
                            onPrevious: () =>
                                setState(() => _batchActiveStage = 1),
                            onNext: () => setState(() => _batchActiveStage = 3),
                          ),
                        _ => _buildMsStage4Card(
                            onPrevious: () =>
                                setState(() => _batchActiveStage = 2),
                          ),
                      }
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (!_batchPreprocessedInput) ...[
                            Expanded(child: _buildMsStage1Card()),
                            const SizedBox(width: 10),
                          ],
                          Expanded(child: _buildMsStage2Card()),
                          const SizedBox(width: 10),
                          Expanded(child: _buildMsStage3Card()),
                          const SizedBox(width: 10),
                          Expanded(child: _buildMsStage4Card()),
                        ],
                      ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMicrostateBatchStageTabs() {
    const borderColor = Color(0xFFCBD5E1);
    const textMuted = Color(0xFF64748B);
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
        title: 'Stage 2: Template & Clustering',
        color: const Color(0xFF10B981),
        icon: Icons.grain,
        badge: !_batchStage2Enabled
            ? 'Skipped'
            : (_batchUseStage1Outputs && _batchPaths.isEmpty
                ? 'Stage 1 output'
                : '${_batchPaths.length} files'),
        enabled: true,
        stageActive: _batchStage2Enabled,
      ),
      (
        index: 2,
        title: 'Stage 3: Dynamics & Syntax',
        color: const Color(0xFFF59E0B),
        icon: Icons.timeline,
        badge: !_batchStage3Enabled ? 'Skipped' : 'Back-fit / Syntax',
        enabled: true,
        stageActive: _batchStage3Enabled,
      ),
      (
        index: 3,
        title: 'Stage 4: Maps & Group Stats',
        color: const Color(0xFF3B82F6),
        icon: Icons.auto_graph,
        badge: _result != null
            ? '${_result!.recordings.length} results'
            : 'Canonical Maps',
        enabled: true,
        stageActive: true,
      ),
    ];

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 6),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFFF0F4F8),
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
                                    ? const Color(0xFF1E293B)
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
                                ? const Color(0xFFD97706)
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

  Widget _msBatchCardShell({
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
    const cardColor = Color(0xFFFFFFFF);
    const borderColor = Color(0xFFCBD5E1);
    const textMuted = Color(0xFF64748B);

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
                      onTap: _running
                          ? null
                          : () => onStageEnabledChanged(!stageEnabled),
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: stageEnabled
                              ? color.withValues(alpha: 0.18)
                              : const Color(0xFFF0F4F8),
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
                        disabledBackgroundColor: const Color(0xFFE2E8F0),
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

  Widget _buildMsStage1Card({VoidCallback? onNext}) {
    if (widget.stage1Builder != null) {
      return widget.stage1Builder!(onNext: onNext);
    }
    const accentPurple = Color(0xFF8B5CF6);
    const borderColor = Color(0xFFCBD5E1);
    const textMuted = Color(0xFF64748B);

    return _msBatchCardShell(
      title: 'Stage 1: Preprocessing',
      icon: Icons.cleaning_services,
      color: accentPurple,
      stageEnabled: _batchStage1Enabled,
      onStageEnabledChanged: (v) => setState(() => _batchStage1Enabled = v),
      onNext: onNext,
      runLabel: 'Run Preprocessing Only',
      onRun: !_running && _prepFiles.isNotEmpty ? _runMicrostateStage1Only : null,
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
                  onPressed: _running
                      ? null
                      : () async {
                          final picked = await pickFilteredFiles(
                            context,
                            allowMultiple: true,
                            type: FileType.custom,
                            allowedExtensions: const [
                              'edf',
                              'set',
                              'fif',
                              'mat',
                              'vhdr',
                              'json',
                              'orb',
                              'signal',
                            ],
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
                  onPressed: _running || _prepFiles.isEmpty
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
            color: const Color(0xFFF0F4F8),
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
                      File(_prepFiles[idx]).uri.pathSegments.last,
                      style: const TextStyle(fontSize: 11),
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.close, size: 13),
                      onPressed: _running
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
            'Average reference & bad channel interpolation for scalp topographies',
            style: TextStyle(fontSize: 10.5, color: textMuted),
          ),
          children: [
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'Interpolate bad channels automatically',
                style: TextStyle(fontSize: 12),
              ),
              value: _msPrepBadChannels,
              onChanged: _running
                  ? null
                  : (v) => setState(() => _msPrepBadChannels = v ?? true),
            ),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'Re-reference to Common Average Reference',
                style: TextStyle(fontSize: 12),
              ),
              value: _msPrepRereference,
              onChanged: _running
                  ? null
                  : (v) => setState(() => _msPrepRereference = v ?? true),
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
            'Microstate bandpass 2.0–20.0 Hz · GEDAI artifact removal',
            style: TextStyle(fontSize: 10.5, color: textMuted),
          ),
          children: [
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'Microstate bandpass filter (2.0–20.0 Hz)',
                style: TextStyle(fontSize: 12),
              ),
              value: _msPrepFilter,
              onChanged: _running
                  ? null
                  : (v) => setState(() => _msPrepFilter = v ?? true),
            ),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'GEDAI artifact cleaning',
                style: TextStyle(fontSize: 12),
              ),
              value: _msPrepGedai,
              onChanged: _running
                  ? null
                  : (v) => setState(() => _msPrepGedai = v ?? true),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildMsStage2Card({VoidCallback? onPrevious, VoidCallback? onNext}) {
    const accentGreen = Color(0xFF16A34A);

    return _msBatchCardShell(
      title: 'Stage 2: Template & Clustering',
      icon: Icons.grain,
      color: accentGreen,
      stageEnabled: _batchStage2Enabled,
      onStageEnabledChanged: (v) => setState(() => _batchStage2Enabled = v),
      onPrevious: onPrevious,
      onNext: onNext,
      runLabel: 'Add recordings to queue',
      onRun: _running ? null : _addBatch,
      children: [
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text(
            'Use Stage 1 outputs (or choose recordings directly)',
            style: TextStyle(fontSize: 11, color: Color(0xFF1E293B)),
          ),
          value: _batchUseStage1Outputs,
          onChanged: _running
              ? null
              : (v) => setState(() => _batchUseStage1Outputs = v ?? true),
        ),
        const SizedBox(height: 6),
        _sectionTitle('1', 'Input'),
        const SizedBox(height: 8),
        const Text(
          'Batch inputs · shared template and per-recording results',
          style: TextStyle(fontSize: 11, color: Color(0xFF475569)),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _running ? null : _addBatch,
                icon: const Icon(Icons.add),
                label: const Text('Add recordings'),
              ),
            ),
            if (_batchPaths.isNotEmpty) ...[
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: _running
                    ? null
                    : () => setState(() {
                        _batchPaths.clear();
                        _result = null;
                        _batchShowResults = false;
                        _recordingIndex = 0;
                      }),
                icon: const Icon(Icons.clear_all, size: 15),
                label: const Text('Clear'),
              ),
            ],
          ],
        ),
        const SizedBox(height: 6),
        Text(
          '${_batchPaths.length} files. One shared group template will be learned and back-fitted to every recording.',
          style: const TextStyle(
            color: Color(0xFF475569),
            fontSize: 11,
          ),
        ),
        for (final (i, path) in _batchPaths.indexed)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(
              File(path).uri.pathSegments.last,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11),
            ),
            trailing: IconButton(
              icon: const Icon(Icons.close, size: 14),
              onPressed: _running
                  ? null
                  : () => setState(() => _batchPaths.removeAt(i)),
            ),
          ),
        const SizedBox(height: 16),
        _sectionTitle('2', 'Configure'),
        const SizedBox(height: 9),
        const Text(
          'Number of states',
          style: TextStyle(color: Color(0xFF475569), fontSize: 11),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          children: [
            for (final count in [4, 5, 6, 7, 8])
              ChoiceChip(
                label: Text('$count'),
                selected: _states.text == '$count',
                onSelected: _running
                    ? null
                    : (_) => setState(() => _states.text = '$count'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        _field(_peaks, 'GFP peaks / recording'),
        const SizedBox(height: 8),
        _field(_segment, 'Minimum segment (ms)'),
      ],
    );
  }

  Widget _buildMsStage3Card({VoidCallback? onPrevious, VoidCallback? onNext}) {
    const accentAmber = Color(0xFFF59E0B);

    return _msBatchCardShell(
      title: 'Stage 3: Dynamics & Syntax',
      icon: Icons.timeline,
      color: accentAmber,
      stageEnabled: _batchStage3Enabled,
      onStageEnabledChanged: (v) => setState(() => _batchStage3Enabled = v),
      onPrevious: onPrevious,
      onNext: onNext,
      runLabel: _running ? 'Analysing…' : 'Run Microstate Analysis',
      onRun: _running || _batchPaths.isEmpty ? null : _run,
      children: [
        _sectionTitle('3', 'Run & export'),
        const SizedBox(height: 9),
        OutlinedButton.icon(
          onPressed: _running || _pickingOutput
              ? null
              : () => _pickOutputDirectory(),
          icon: _pickingOutput
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.folder),
          label: Text(
            _pickingOutput
                ? 'Opening folder picker…'
                : _outputDirectory == null
                ? 'Choose output folder…'
                : 'Output: ${File(_outputDirectory!).uri.pathSegments.where((x) => x.isNotEmpty).last}',
          ),
        ),
        const SizedBox(height: 8),
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Remove per-epoch channel DC before fitting'),
          subtitle: const Text(
            'Analysis only. Original GFP is retained in sample exports.',
          ),
          value: _removeEpochDc,
          onChanged: _running
              ? null
              : (v) => setState(() => _removeEpochDc = v!),
        ),
        const SizedBox(height: 6),
        DropdownButtonFormField<int>(
          initialValue: _syntaxWordLength,
          decoration: const InputDecoration(
            labelText: 'Syntax word length',
          ),
          items: [
            for (final w in [2, 3, 4, 5, 6, 7])
              DropdownMenuItem(value: w, child: Text('$w')),
          ],
          onChanged: _running
              ? null
              : (v) => setState(() => _syntaxWordLength = v!),
        ),
        const SizedBox(height: 6),
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Legacy microsynt.py window count'),
          subtitle: const Text(
            'Default includes the final valid word, as in the paper.',
          ),
          value: _syntaxLegacyWindows,
          onChanged: _running
              ? null
              : (v) => setState(() => _syntaxLegacyWindows = v!),
        ),
        const SizedBox(height: 8),
        const Text(
          'Parity defaults: average reference, dataset normalization, 10 ms peak distance, 1.5 SD GFP threshold, modified k-means ×10, polarity ignored, CV models 3–8.',
          style: TextStyle(
            color: Color(0xFF475569),
            fontSize: 10.5,
            height: 1.4,
          ),
        ),
        if (_running) ...[
          const SizedBox(height: 10),
          ProcessingProgress(
            progress: _progress,
            message: _message,
            stopping: _cancelRequested,
            onCancel: () {
              setState(() => _cancelRequested = true);
              _service.cancel();
            },
          ),
        ],
        if (_message.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            _message,
            style: const TextStyle(color: Color(0xFF475569), fontSize: 11),
          ),
        ],
      ],
    );
  }

  Widget _buildMsStage4Card({VoidCallback? onPrevious}) {
    const accentBlue = Color(0xFF3B6EA5);

    return _msBatchCardShell(
      title: 'Stage 4: Maps & Group Stats',
      icon: Icons.auto_graph,
      color: accentBlue,
      onPrevious: onPrevious,
      runLabel: _result != null
          ? 'Open Interactive Microstate Results'
          : 'Open Microstate Results Workbench',
      onRun: _result != null
          ? () => setState(() => _batchShowResults = true)
          : (!_running && _batchPaths.isNotEmpty ? _run : null),
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: accentBlue.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: accentBlue.withValues(alpha: 0.3)),
          ),
          child: const Text(
            'Shared group canonical headmaps, global explained variance (GEV), state duration/coverage/occurrence, Markov transition matrices, and Lempel-Ziv / entropy syntax complexity.',
            style: TextStyle(fontSize: 11, color: Color(0xFF475569)),
          ),
        ),
        const SizedBox(height: 14),
        if (_result == null)
          const Text(
            'Run Stage 3 Microstate Analysis to inspect canonical maps, per-recording state dynamics, transition graphs, and CSV exports.',
            style: TextStyle(fontSize: 11, color: Color(0xFF475569)),
          )
        else ...[
          Text(
            '✓ ${_result!.selectedStates}-state group template computed across ${_result!.recordings.length} recording(s).',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: Color(0xFF10B981),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Output folder: ${_result!.outputDirectory}',
            style: const TextStyle(fontSize: 11, color: Color(0xFF475569)),
          ),
        ],
      ],
    );
  }

  Widget _buildInteractiveMicrostateLayout(BuildContext context) => Row(
    children: [
      SizedBox(
        width: 300,
        child: Material(
          color: const Color(0xFFF0F4F8),
          child: ListView(
            padding: const EdgeInsets.all(14),
            children: [
              const Text(
                'MICROSTATE ANALYSIS',
                style: TextStyle(
                  color: Color(0xFF06B6D4),
                  fontWeight: FontWeight.bold,
                  letterSpacing: .8,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Canonical maps, temporal dynamics, and sequence complexity',
                style: TextStyle(color: Color(0xFF475569), fontSize: 11),
              ),
              const SizedBox(height: 14),
              _workflowProgress(),
              const SizedBox(height: 18),
              _sectionTitle('1', 'Input'),
              const SizedBox(height: 8),
              const SizedBox(height: 12),
              Text(
                _batch
                    ? 'Batch inputs · shared template and per-recording results'
                    : 'Active recording · use Batch Workspace → Microstates for multiple files',
                style: const TextStyle(fontSize: 11, color: Color(0xFF475569)),
              ),
              const SizedBox(height: 12),
              if (!_batch)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _info(
                      _interactiveInput == null
                          ? 'No recording selected.'
                          : 'Input: ${_name(_interactiveInput!.path)}\n${_interactiveInput!.labels.length} channels · ${_interactiveInput!.sampleRate.toStringAsFixed(1)} Hz',
                    ),
                    const SizedBox(height: 7),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _running ? null : _chooseInteractiveRecording,
                            icon: const Icon(Icons.folder_open, size: 16),
                            label: Text(
                              _interactiveInput == null
                                  ? 'Choose recording'
                                  : 'Choose a different recording',
                            ),
                          ),
                        ),
                        if (_interactiveRecording != null || _result != null) ...[
                          const SizedBox(width: 8),
                          TextButton.icon(
                            onPressed: _running
                                ? null
                                : () => setState(() {
                                    _interactiveRecording = null;
                                    _result = null;
                                    _analysisInputs = const [];
                                    _message = '';
                                  }),
                            icon: const Icon(Icons.clear, size: 15),
                            label: const Text('Clear'),
                          ),
                        ],
                      ],
                    ),
                  ],
                )
              else ...[
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _running ? null : _addBatch,
                        icon: const Icon(Icons.add),
                        label: const Text('Add recordings'),
                      ),
                    ),
                    if (_batchPaths.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      TextButton.icon(
                        onPressed: _running
                            ? null
                            : () => setState(() {
                                _batchPaths.clear();
                                _result = null;
                                _recordingIndex = 0;
                              }),
                        icon: const Icon(Icons.clear_all, size: 15),
                        label: const Text('Clear'),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '${_batchPaths.length} files. One shared group template will be learned and back-fitted to every recording.',
                  style: const TextStyle(
                    color: Color(0xFF475569),
                    fontSize: 11,
                  ),
                ),
                for (final (i, path) in _batchPaths.indexed)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      File(path).uri.pathSegments.last,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.close, size: 14),
                      onPressed: _running
                          ? null
                          : () => setState(() => _batchPaths.removeAt(i)),
                    ),
                  ),
              ],
              const SizedBox(height: 18),
              _sectionTitle('2', 'Configure'),
              const SizedBox(height: 9),
              const Text(
                'Number of states',
                style: TextStyle(color: Color(0xFF475569), fontSize: 11),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                children: [
                  for (final count in [4, 5, 6, 7, 8])
                    ChoiceChip(
                      label: Text('$count'),
                      selected: _states.text == '$count',
                      onSelected: _running
                          ? null
                          : (_) => setState(() => _states.text = '$count'),
                    ),
                ],
              ),
              const SizedBox(height: 5),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 6),
                title: const Text(
                  'Advanced parameters',
                  style: TextStyle(fontSize: 12),
                ),
                children: [
                  _field(_peaks, 'GFP peaks / recording'),
                  const SizedBox(height: 8),
                  _field(_segment, 'Minimum segment (ms)'),
                  const SizedBox(height: 9),
                  const Text(
                    'Parity defaults: average reference, dataset normalization, 10 ms peak distance, 1.5 SD GFP threshold, modified k-means ×10, polarity ignored, CV models 3–8.',
                    style: TextStyle(
                      color: Color(0xFF475569),
                      fontSize: 10.5,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _sectionTitle('3', 'Run & export'),
              const SizedBox(height: 9),
              OutlinedButton.icon(
                onPressed: _running || _pickingOutput
                    ? null
                    : () => _pickOutputDirectory(),
                icon: _pickingOutput
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.folder),
                label: Text(
                  _pickingOutput
                      ? 'Opening folder picker…'
                      : _outputDirectory == null
                      ? 'Choose output folder…'
                      : 'Output: ${File(_outputDirectory!).uri.pathSegments.where((x) => x.isNotEmpty).last}',
                ),
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                dense: true,
                title: const Text('Remove per-epoch channel DC before fitting'),
                subtitle: const Text(
                  'Analysis only. Original GFP is retained in sample exports.',
                ),
                value: _removeEpochDc,
                onChanged: _running
                    ? null
                    : (v) => setState(() => _removeEpochDc = v!),
              ),
              DropdownButtonFormField<int>(
                initialValue: _syntaxWordLength,
                decoration: const InputDecoration(
                  labelText: 'Syntax word length',
                ),
                items: [
                  for (final w in [2, 3, 4, 5, 6, 7])
                    DropdownMenuItem(value: w, child: Text('$w')),
                ],
                onChanged: _running
                    ? null
                    : (v) => setState(() => _syntaxWordLength = v!),
              ),
              CheckboxListTile(
                dense: true,
                title: const Text('Legacy microsynt.py window count'),
                subtitle: const Text(
                  'Default includes the final valid word, as in the paper.',
                ),
                value: _syntaxLegacyWindows,
                onChanged: _running
                    ? null
                    : (v) => setState(() => _syntaxLegacyWindows = v!),
              ),
              FilledButton.icon(
                onPressed:
                    _running ||
                        (!_batch && _interactiveInput == null) ||
                        (_batch && _batchPaths.isEmpty)
                    ? null
                    : _run,
                icon: const Icon(Icons.play_arrow),
                label: Text(
                  _running ? 'Analysing…' : 'Run Microstate Analysis',
                ),
              ),
              if (_running) ...[
                const SizedBox(height: 8),
                ProcessingProgress(
                  progress: _progress,
                  message: _message,
                  stopping: _cancelRequested,
                  onCancel: () {
                    setState(() => _cancelRequested = true);
                    _service.cancel();
                  },
                ),
              ],
              if (_message.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  _message,
                  style: const TextStyle(
                    color: Color(0xFF475569),
                    fontSize: 11,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      const VerticalDivider(width: 1),
      Expanded(
        child: _running
            ? Center(
                child: SizedBox(
                  width: 640,
                  child: ProcessingProgress(
                    progress: _progress,
                    message: _message,
                    stopping: _cancelRequested,
                    onCancel: () {
                      setState(() => _cancelRequested = true);
                      _service.cancel();
                    },
                  ),
                ),
              )
            : _result == null
            ? Center(
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 480),
                  padding: const EdgeInsets.all(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          color: const Color(0xFF06B6D4).withValues(alpha: .12),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.grain,
                          color: Color(0xFF06B6D4),
                          size: 30,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _interactiveInput == null && !_batch
                            ? 'Choose a recording to begin'
                            : _running
                            ? 'Microstate analysis in progress'
                            : 'Ready for microstate analysis',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Results will organize canonical headmaps, fit quality, state dynamics, transition probabilities, and complexity metrics in one workspace.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Color(0xFF475569), height: 1.5),
                      ),
                    ],
                  ),
                ),
              )
            : _results(),
      ),
    ],
  );

  Widget _results() {
    final result = _result!;
    final recording = result.recordings[_recordingIndex];
    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        Row(
          children: [
            Text(
              '${result.selectedStates}-state solution',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const Spacer(),
            if (result.recordings.length > 1)
              DropdownButton<int>(
                value: _recordingIndex,
                items: [
                  for (final (i, r) in result.recordings.indexed)
                    DropdownMenuItem(value: i, child: Text(r.filename)),
                ],
                onChanged: (v) => setState(() {
                  _recordingIndex = v ?? 0;
                  _timelineStartSeconds = 0;
                  _timelineChannelOffset = 0;
                }),
              ),
          ],
        ),
        const SizedBox(height: 10),
        MicrostateGroupPanel(result: result),
        const SizedBox(height: 12),
        _howToRead(result, recording),
        const SizedBox(height: 12),
        SizedBox(
          height: 250.0 * (result.prototypes.length / 4).ceil(),
          child: CustomPaint(
            painter: _TopographyPainter(
              result.channelPositions,
              result.prototypes,
              result.canonicalCorrelations,
              result.stateLabels,
              _mapSubtitles(result, recording),
            ),
          ),
        ),
        Text(
          [
            'Each head is one recurring scalp pattern, seen from above (nose up). Red and blue are opposite polarity relative to the average; the sign is arbitrary, so a map and its colour-reversed version are the same state. Colours are scaled per map (± its own maximum), so compare shapes, not amplitudes. The line under each head gives that state\'s share of the recording, its mean duration, and how often it starts.',
            if (result.canonicalCorrelations.any((r) => r != null))
              'The r next to a label is its absolute spatial correlation with the matched MetaMaps_2023_06 canonical template.'
            else
              'No canonical template exists for a ${result.prototypes.length}-state solution, so these states are labelled in order (A, B, …) and carry no established functional meaning. Use 4–7 states if you want canonical labels and r values.',
            if (result.stateLabels.any((label) => label.startsWith('U')))
              'U = unmatched: this state did not reach |r| > 0.5 with the remaining template maps.',
          ].join(' '),
          textAlign: TextAlign.center,
          style: const TextStyle(color: Color(0xFF475569), fontSize: 11),
        ),
        const SizedBox(height: 14),
        Text(
          recording.filename,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        Text(
          'Analysis preparation: per-epoch channel DC removal ${result.removeEpochDc ? 'on' : 'off'}. Original and fitting GFP are exported separately.',
        ),
        Text(
          'GEV ${(recording.gevTotal * 100).toStringAsFixed(2)}%  ·  normalized LZ ${_n(recording.sequenceMetrics['normalized_lz'])}  ·  MDV ${_n(recording.sequenceMetrics['duration_variance_samples2'])}  ·  entropy production ${_n(recording.sequenceMetrics['entropy_production'])}',
          style: const TextStyle(color: Color(0xFF475569)),
        ),
        const SizedBox(height: 10),
        _timelineExplorer(result, recording),
        const SizedBox(height: 14),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columns: const [
              DataColumn(label: Text('State')),
              DataColumn(
                label: Text('GFP (normalized)'),
                tooltip: 'Global field power: how strong the scalp pattern is while this state is active (relative to the recording average)',
              ),
              DataColumn(
                label: Text('Occurrence/s'),
                tooltip: 'How many times per second this state starts',
              ),
              DataColumn(
                label: Text('Duration ms'),
                tooltip: 'Average time the state lasts each time it appears',
              ),
              DataColumn(
                label: Text('Coverage'),
                tooltip: 'Fraction of the recording spent in this state (all states add to 1)',
              ),
              DataColumn(
                label: Text('GEV'),
                tooltip: 'Global explained variance: share of the signal variance this state accounts for',
              ),
              DataColumn(
                label: Text('Mean assigned-state r'),
                tooltip: 'Average spatial correlation between the state map and the EEG samples assigned to it (closer to 1 = better fit)',
              ),
            ],
            rows: [
              for (final s in recording.states)
                DataRow(
                  cells: [
                    DataCell(Text('${s['label']}')),
                    DataCell(Text(_n(s['mean_gfp']))),
                    DataCell(Text(_n(s['occurrence_hz']))),
                    DataCell(Text(_n(s['mean_duration_ms']))),
                    DataCell(Text(_n(s['coverage']))),
                    DataCell(Text(_n(s['gev']))),
                    DataCell(Text(_n(s['mean_spatial_correlation']))),
                  ],
                ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _syntaxSection(result, recording),
        const SizedBox(height: 18),
        _transitionSection(result, recording),
        const SizedBox(height: 12),
        Text(
          'Exports: MicrostateGroupStates.csv, MicrostateGroupSyntax.csv, MicrostateGroupTransitions.csv, GroupTables_README.txt, MicrostateDictionaryDiscovery.csv, MicrostateSyntax.csv, per-recording samples.csv (labels/GFP/fit), microstates.json, MicrostateAnalysisResults.csv, MicrostateSequenceMetrics.csv, MicrostateTransitions.csv, template topographies SVG, and per-recording sequence SVG in ${result.outputDirectory}',
          style: const TextStyle(color: Color(0xFF475569), fontSize: 11),
        ),
      ],
    );
  }

  // ── Result interpretation helpers ───────────────────────────────────────

  static double _d(Object? x) => x is num ? x.toDouble() : double.nan;

  /// Coverage may be stored as a fraction (0–1) or a percentage; return a fraction.
  static double _coverageFraction(MicrostateRecordingResult r, Map<String, dynamic> state) {
    final total = r.states.fold<double>(0, (a, e) => a + (_d(e['coverage']).isNaN ? 0 : _d(e['coverage'])));
    final v = _d(state['coverage']);
    return total > 1.5 ? v / 100 : v;
  }

  List<String> _mapSubtitles(MicrostateResult result, MicrostateRecordingResult r) {
    return [
      for (final label in result.stateLabels)
        () {
          final matches = r.states.where((e) => '${e['label']}' == label);
          if (matches.isEmpty) return '';
          final st = matches.first;
          final cov = _coverageFraction(r, st);
          return '${(cov * 100).toStringAsFixed(1)}% of time · ${_d(st['mean_duration_ms']).toStringAsFixed(0)} ms · ${_d(st['occurrence_hz']).toStringAsFixed(1)}/s';
        }(),
    ];
  }

  Widget _howToRead(MicrostateResult result, MicrostateRecordingResult r) {
    final states = [...r.states]..sort((a, b) => _coverageFraction(r, b).compareTo(_coverageFraction(r, a)));
    final dur = [for (final e in r.states) _d(e['mean_duration_ms'])].where((v) => !v.isNaN).toList();
    final meanDur = dur.isEmpty ? double.nan : dur.reduce((a, b) => a + b) / dur.length;
    String pct(double v) => '${(v * 100).toStringAsFixed(0)}%';
    final top = states.take(3).map((e) => '${e['label']} (${pct(_coverageFraction(r, e))})').join(', ');
    final lz = _d(r.sequenceMetrics['normalized_lz']);
    final ep = _d(r.sequenceMetrics['entropy_production']);
    final gev = r.gevTotal;
    final lines = <(String, String)>[
      (
        'Fit',
        'The ${result.selectedStates} states together explain ${(gev * 100).toStringAsFixed(1)}% of the variance of the EEG topography. '
            '${gev < .5 ? "That is modest: the patterns capture the main recurring topographies but a lot of variance remains (more states raise it, but small states are harder to interpret)." : "That is a good fit for this number of states."}',
      ),
      (
        'Time spent',
        'Most of the recording is in $top. Each state lasts ${meanDur.isNaN ? "—" : meanDur.toStringAsFixed(0)} ms on average '
            '${meanDur.isNaN ? "" : (meanDur < 40
                      ? "(very short: the labels flip quickly, which can mean noisy fitting or too many states)"
                      : meanDur <= 140
                      ? "(in the range usually reported for resting EEG, roughly 60–120 ms)"
                      : "(longer than usually reported; check smoothing)")}.',
      ),
      (
        'Sequence regularity',
        'Lempel-Ziv complexity ${lz.isNaN ? "—" : lz.toStringAsFixed(2)} (0 = the same pattern repeating, 1 = random order). '
            'Entropy production ${ep.isNaN ? "—" : ep.toStringAsFixed(4)} (0 = the sequence looks the same played forwards or backwards; larger = a preferred cyclic order of states).',
      ),
    ];
    return Card(
      color: const Color(0xFFF0F4F8),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('How to read this result', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            const Text(
              'Microstates: the scalp pattern of the EEG at every moment is assigned to one of a few recurring patterns. '
              'This page shows the patterns (heads), how the recording moves between them over time, and how regular that sequence is.',
              style: TextStyle(fontSize: 12, color: Color(0xFF475569), height: 1.4),
            ),
            const SizedBox(height: 8),
            for (final (title, text) in lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 118,
                      child: Text(
                        title,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF38BDF8),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        text,
                        style: const TextStyle(fontSize: 12, height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _syntaxSection(MicrostateResult result, MicrostateRecordingResult recording) {
    final syntax = recording.syntax;
    if (syntax.isEmpty) return const SizedBox.shrink();
    final classes = (syntax['classes'] as List? ?? const []).cast<Map>();
    final len = (syntax['word_length'] as num?)?.toInt() ?? 0;
    final windows = (syntax['windows'] as num?)?.toInt() ?? 0;
    final examples = microstateSyntaxExamples(len, maxStates: recording.states.length);
    final k = recording.states.length;
    final possible = len > 0 && k > 1 ? k * math.pow(k - 1, len - 1) : 0;
    final share = possible > 0 ? windows / possible : 0.0;
    final warnings = [for (final w in syntax['warnings'] as List? ?? const []) '$w'];
    String share2(Object? v) => v is num ? '${(v * 100).toStringAsFixed(2)}%' : '—';
    String ratio(Object? v) => v is num ? v.toStringAsFixed(2) : '—';
    Map? biggest;
    var gap = 0.0;
    for (final c in classes) {
      final e = _d(c['empirical']), t = _d(c['theoretical']);
      if (!e.isNaN && !t.isNaN && (e - t).abs() > gap) {
        gap = (e - t).abs();
        biggest = c;
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('State sequences · $len state visits per word', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        const Text(
          'A “word” is a run of consecutive microstates (staying in a state does not count, so A A A B C → A B C). '
          'Syntax asks whether the recording visits states in more (or less) structured orders than chance. '
          'Words are grouped by how varied they are: a low entropy word uses fewer distinct states more often; a highest-entropy word visits all different states. Entropy describes state counts within a word, not its exact order.',
          style: TextStyle(fontSize: 12, color: Color(0xFF475569), height: 1.4),
        ),
        const SizedBox(height: 8),
        Text('Example: ${List.generate(len, (i) => i.isEven ? 'A' : 'B').join(' → ')} repeatedly alternates two maps. ${List.generate(len, (i) => String.fromCharCode(65 + i % k)).join(' → ')} visits different maps. Each sliding word is counted; classes combine many sequences with the same state-count distribution.', style: const TextStyle(fontSize: 12)),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: (share < .1 ? const Color(0x33F59E0B) : const Color(0x3322C55E)),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            windows == 0
                ? 'No complete $len-state words were found (epochs are never joined). Try a shorter word length.'
                : 'Evidence: $windows overlapping word windows were sampled; $possible different $len-visit sequences are possible. This is not the percentage of unique sequences discovered. '
                      '${share < .1 ? "That is sparse, so the class shares below are noisy. Use a shorter word length (3–4) or fewer states, or analyse more data, before drawing conclusions." : "Compare the observed and reference shares below; this comparison alone does not establish statistical significance."}',
            style: const TextStyle(fontSize: 12, height: 1.4),
          ),
        ),
        for (final w in warnings.where((w) => !w.startsWith('Only ')))
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(w, style: const TextStyle(color: Colors.orange, fontSize: 11)),
          ),
        const SizedBox(height: 10),
        if (classes.isNotEmpty) ...[
          const Text('Share of words · example sequence for each entropy class', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          SizedBox(height: 200, child: CustomPaint(painter: _SyntaxBarsPainter(classes, examples), child: const SizedBox.expand())),
          Wrap(
            spacing: 14,
            children: const [
              _Swatch(Color(0xFF64748B), 'Chance (random states)'),
              _Swatch(Color(0xFFF59E0B), 'Markov (each state depends on the previous one)'),
              _Swatch(Color(0xFF22D3EE), 'Observed'),
            ],
          ),
          if (biggest != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Largest difference from chance: words with entropy ${_d(biggest['entropy_bits']).toStringAsFixed(2)} bits are '
                '${share2(biggest['empirical'])} of the observed words versus ${share2(biggest['theoretical'])} expected by chance '
                '(×${ratio(biggest['ratio_theoretical'])}). Ratios are descriptive, not significance tests.',
                style: const TextStyle(fontSize: 12, height: 1.4),
              ),
            ),
          const SizedBox(height: 6),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: const [
                DataColumn(
                  label: Text('Example sequence · entropy'),
                  tooltip:
                      'How varied the states within a word are. Low = bouncing between few states; highest = all different.',
                ),
                DataColumn(
                  label: Text('Chance'),
                  tooltip:
                      'TER: share of words in this class if states followed each other at random (no repeats).',
                ),
                DataColumn(
                  label: Text('Observed'),
                  tooltip:
                      'EER: share of the words actually seen in the recording.',
                ),
                DataColumn(
                  label: Text('Markov'),
                  tooltip:
                      'MER: share expected if the next state depended only on the current state, using your observed transition probabilities.',
                ),
                DataColumn(
                  label: Text('Observed ÷ chance'),
                  tooltip:
                      'EER/TER. Above 1 = more words of this class than random.',
                ),
                DataColumn(
                  label: Text('Observed ÷ Markov'),
                  tooltip:
                      'EER/MER. Above 1 = more than a one-step-memory process would give, i.e. longer-range structure.',
                ),
              ],
              rows: [
                for (final c in classes)
                  DataRow(cells: [
                    DataCell(Text('${examples[_d(c['entropy_bits']).toStringAsFixed(3)] ?? '—'}\n${_d(c['entropy_bits']).toStringAsFixed(3)} bits')),
                    DataCell(Text(share2(c['theoretical']))),
                    DataCell(Text(share2(c['empirical']))),
                    DataCell(Text(share2(c['markov']))),
                    DataCell(Text(ratio(c['ratio_theoretical']))),
                    DataCell(Text(ratio(c['ratio_markov']))),
                  ]),
              ],
            ),
          ),
        ],
        if (syntax['dictionary_discovery'] is List)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('How many different words appear at each word length?', style: TextStyle(fontSize: 13)),
            subtitle: const Text(
              'Compares your recording with random state sequences. Use it to choose a word length that is neither empty nor saturated.',
              style: TextStyle(fontSize: 11),
            ),
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columns: const [
                    DataColumn(label: Text('Word length')),
                    DataColumn(label: Text('Possible words')),
                    DataColumn(label: Text('Observed words')),
                    DataColumn(label: Text('Random mean')),
                    DataColumn(label: Text('Random min')),
                    DataColumn(label: Text('Random max')),
                  ],
                  rows: [
                    for (final row in syntax['dictionary_discovery'] as List)
                      DataRow(cells: [
                        for (final key in ['word_length', 'theoretical_words', 'observed_words', 'random_words_mean', 'random_words_min', 'random_words_max'])
                          DataCell(Text(row[key] is double ? (row[key] as double).toStringAsFixed(1) : '${row[key]}')),
                      ]),
                  ],
                ),
              ),
            ],
          ),
        Text('Sample labels, GFP and fit: ${recording.sampleCsv}', style: const TextStyle(fontSize: 11, color: Color(0xFF475569))),
      ],
    );
  }

  /// P(next = j | the sequence leaves state i): self-transitions removed, rows add to 1.
  static List<List<double>> _leaveMatrix(List<List<double>> t) {
    final n = t.length;
    return [
      for (var i = 0; i < n; i++)
        () {
          var sum = 0.0;
          for (var j = 0; j < n; j++) {
            if (j != i) sum += t[i][j];
          }
          return [for (var j = 0; j < n; j++) i == j || sum <= 0 ? 0.0 : t[i][j] / sum];
        }(),
    ];
  }

  /// Share of state entries that go into each state (self-transitions removed).
  static List<double> _entryShare(List<List<double>> t) {
    final n = t.length;
    final entries = [
      for (var j = 0; j < n; j++) [for (var i = 0; i < n; i++) if (i != j) t[i][j]].fold<double>(0, (a, b) => a + b),
    ];
    final total = entries.fold<double>(0, (a, b) => a + b);
    return [for (final e in entries) total > 0 ? e / total : 0.0];
  }

  Widget _transitionSection(MicrostateResult result, MicrostateRecordingResult recording) {
    final raw = recording.transitions;
    if (raw.isEmpty) return const SizedBox.shrink();
    final n = raw.length;
    final labels = [for (var i = 0; i < n; i++) i < result.stateLabels.length ? result.stateLabels[i] : String.fromCharCode(65 + i)];
    final leave = _leaveMatrix(raw);
    final entry = _entryShare(raw);
    final ratio = [
      for (var i = 0; i < n; i++)
        [
          for (var j = 0; j < n; j++)
            () {
              if (i == j) return 0.0;
              final expected = (1 - entry[i]) <= 0 ? 0.0 : entry[j] / (1 - entry[i]);
              return expected <= 0 ? 0.0 : leave[i][j] / expected;
            }(),
        ],
    ];
    final total = raw.fold<double>(0, (a, r) => a + r.fold<double>(0, (x, y) => x + y));
    final stay = total > 0 ? [for (var i = 0; i < n; i++) raw[i][i]].fold<double>(0, (a, b) => a + b) / total : double.nan;
    final preferred = <(int, int, double)>[];
    for (var i = 0; i < n; i++) {
      for (var j = 0; j < n; j++) {
        if (i != j && leave[i][j] >= .05) preferred.add((i, j, ratio[i][j]));
      }
    }
    preferred.sort((a, b) => b.$3.compareTo(a.$3));
    final matrix = _transitionMode == 0 ? raw : (_transitionMode == 1 ? leave : ratio);
    const blurbs = [
      'Share of all consecutive EEG samples that go from the row state to the column state. The diagonal (staying in the same state) dominates because states last many samples, so off-diagonal cells look like zero.',
      'Staying in a state is removed. Each row shows where the sequence goes after it leaves that state; rows add to 100%.',
      'Leaving-state probability divided by what you would expect if the next state were chosen at random in proportion to how often each state starts. Above ×1 = preferred transition, below ×1 = avoided.',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Which state follows which', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        SegmentedButton<int>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 1, label: Text('After leaving a state', style: TextStyle(fontSize: 12))),
            ButtonSegment(value: 2, label: Text('Versus chance', style: TextStyle(fontSize: 12))),
            ButtonSegment(value: 0, label: Text('All samples', style: TextStyle(fontSize: 12))),
          ],
          selected: {_transitionMode},
          onSelectionChanged: (v) => setState(() => _transitionMode = v.first),
        ),
        const SizedBox(height: 6),
        Text(blurbs[_transitionMode], style: const TextStyle(fontSize: 12, color: Color(0xFF475569), height: 1.4)),
        const SizedBox(height: 6),
        SizedBox(
          height: 320,
          child: CustomPaint(painter: _TransitionPainter(matrix, labels, _transitionMode), child: const SizedBox.expand()),
        ),
        Text(
          [
            if (!stay.isNaN) '${(stay * 100).toStringAsFixed(1)}% of consecutive samples stay in the same state.',
            if (preferred.isNotEmpty)
              'Strongest preferred transitions: ${preferred.take(3).map((e) => '${labels[e.$1]}→${labels[e.$2]} (${(leave[e.$1][e.$2] * 100).toStringAsFixed(0)}% of exits, ×${e.$3.toStringAsFixed(1)} chance)').join('; ')}.',
          ].join(' '),
          style: const TextStyle(fontSize: 12, height: 1.4),
        ),
      ],
    );
  }

  EegRecording? _recordingFor(MicrostateRecordingResult result) {
    for (final recording in _analysisInputs) {
      if (_name(recording.path) == result.filename) return recording;
    }
    return _analysisInputs.length == 1 ? _analysisInputs.first : null;
  }

  Widget _timelineExplorer(
    MicrostateResult result,
    MicrostateRecordingResult recording,
  ) {
    final duration = recording.sequence.length / recording.sampleRate;
    final window = math.min(_timelineWindowSeconds, duration);
    final maxStart = math.max(0.0, duration - window);
    final start = _timelineStartSeconds.clamp(0.0, maxStart);
    final startSample = (start * recording.sampleRate).floor().clamp(
      0,
      recording.sequence.length,
    );
    final endSample = ((start + window) * recording.sampleRate).ceil().clamp(
      startSample,
      recording.sequence.length,
    );
    final source = _recordingFor(recording);

    return Card(
      color: const Color(0xFFF0F4F8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  'Timeline explorer',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(width: 10),
                Text(
                  '${_time(start)} – ${_time(start + window)}',
                  style: const TextStyle(
                    color: Color(0xFF475569),
                    fontSize: 11,
                  ),
                ),
                const Spacer(),
                const Text(
                  'Window',
                  style: TextStyle(color: Color(0xFF475569), fontSize: 11),
                ),
                const SizedBox(width: 6),
                DropdownButton<double>(
                  value: _timelineWindowSeconds,
                  items: [
                    for (final seconds in const [
                      2.0,
                      5.0,
                      10.0,
                      20.0,
                      30.0,
                      60.0,
                    ])
                      DropdownMenuItem(
                        value: seconds,
                        child: Text('${seconds.toInt()} s'),
                      ),
                  ],
                  onChanged: (value) => setState(() {
                    _timelineWindowSeconds = value ?? 20;
                    _timelineStartSeconds = start.clamp(
                      0.0,
                      math.max(0.0, duration - _timelineWindowSeconds),
                    );
                  }),
                ),
              ],
            ),
            const Text(
              'Similarity traces (tap a state to show or hide it)',
              style: TextStyle(color: Color(0xFF475569), fontSize: 10),
            ),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                for (final (index, label) in result.stateLabels.indexed)
                  FilterChip(
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    selected: _similarityOverlay ? !_hiddenSimilarityStates.contains(index) : index == _similarityState,
                    selectedColor: _stateColors[index % _stateColors.length]
                        .withValues(alpha: .35),
                    avatar: Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        color: _stateColors[index % _stateColors.length],
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    label: Text(label, style: const TextStyle(fontSize: 10)),
                    onSelected: (selected) => setState(() {
                      _similarityState = index;
                      selected
                          ? _hiddenSimilarityStates.remove(index)
                          : _hiddenSimilarityStates.add(index);
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            LayoutBuilder(
              builder: (context, constraints) => GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (details) => setState(() {
                  final fraction =
                      details.localPosition.dx / constraints.maxWidth;
                  _timelineStartSeconds = (fraction * duration - window / 2)
                      .clamp(0.0, maxStart);
                }),
                child: SizedBox(
                  height: 34,
                  width: double.infinity,
                  child: CustomPaint(
                    painter: _TimelineSequencePainter(
                      recording.sequence,
                      startSample,
                      endSample,
                      start,
                      window,
                    ),
                  ),
                ),
              ),
            ),
            if (maxStart > 0)
              Slider(
                min: 0,
                max: maxStart,
                value: start,
                onChanged: (value) =>
                    setState(() => _timelineStartSeconds = value),
              ),
            if (source != null) ...[
              Row(
                children: [
                  const Text(
                    'EEG waveform',
                    style: TextStyle(
                      color: Color(0xFF475569),
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  IconButton(tooltip: 'Previous channels', onPressed: _timelineChannelOffset > 0 ? () => setState(() => _timelineChannelOffset = math.max(0, _timelineChannelOffset - _timelineWaveformChannels)) : null, icon: const Icon(Icons.chevron_left)),
                  Text('${_timelineChannelOffset + 1}–${math.min(source.labels.length, _timelineChannelOffset + _timelineWaveformChannels)}'),
                  IconButton(tooltip: 'Next channels', onPressed: _timelineChannelOffset + _timelineWaveformChannels < source.labels.length ? () => setState(() => _timelineChannelOffset += _timelineWaveformChannels) : null, icon: const Icon(Icons.chevron_right)),
                  const Text(
                    'Visible channels',
                    style: TextStyle(color: Color(0xFF64748B), fontSize: 10),
                  ),
                  const SizedBox(width: 6),
                  DropdownButton<int>(
                    value: _timelineWaveformChannels,
                    isDense: true,
                    items: [
                      for (final n in const [3, 6, 12, 24])
                        DropdownMenuItem(value: n, child: Text('$n')),
                    ],
                    onChanged: (value) =>
                        setState(() { _timelineWaveformChannels = value ?? 6; _timelineChannelOffset = 0; }),
                  ),
                ],
              ),
              SizedBox(
                height: math.max(230, _timelineWaveformChannels * 44),
                child: CustomPaint(
                  painter: _MicrostateWaveformPainter(
                    source,
                    start,
                    window,
                    _timelineWaveformChannels,
                    _timelineChannelOffset,
                  ),
                  size: Size.infinite,
                ),
              ),
            ],
            const SizedBox(height: 8),
            const Text(
              'Similarity to scalp patterns',
              style: TextStyle(
                color: Color(0xFF475569),
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
            const Text(
              'Select a state chip above to inspect its trace. Values are relative similarity (0–1), not a probability of brain activity. Overlay is optional.',
              style: TextStyle(color: Color(0xFF64748B), fontSize: 10),
            ),
            SwitchListTile(dense: true, title: const Text('Overlay selected state traces'), value: _similarityOverlay, onChanged: (v) => setState(() => _similarityOverlay = v)),
            SizedBox(
              height: 190,
              child: recording.stateProbabilities.isEmpty
                  ? const Center(
                      child: Text(
                        'Re-run this analysis to generate similarity traces.',
                        style: TextStyle(color: Color(0xFF475569)),
                      ),
                    )
                  : CustomPaint(
                      painter: _ProbabilityPainter(
                        recording.stateProbabilities,
                        startSample,
                        endSample,
                        start,
                        window,
                        _similarityOverlay ? {..._hiddenSimilarityStates} : {for (var i = 0; i < recording.stateProbabilities.length; i++) if (i != _similarityState) i},
                      ),
                      size: Size.infinite,
                    ),
            ),
          ],
        ),
      ),
    );
  }

  static String _time(double seconds) {
    final minutes = seconds ~/ 60;
    final remainder = (seconds % 60).toStringAsFixed(1).padLeft(4, '0');
    return minutes > 0
        ? '$minutes:$remainder'
        : '${seconds.toStringAsFixed(1)} s';
  }

  static String _n(Object? x) => x is num ? x.toStringAsFixed(4) : '—';
  Widget _workflowProgress() {
    final hasInput = _batch
        ? _batchPaths.isNotEmpty
        : _interactiveInput != null;
    return Row(
      children: [
        _progressStep('1', 'Input', hasInput),
        _progressConnector(hasInput),
        _progressStep('2', 'Configure', hasInput),
        _progressConnector(_result != null),
        _progressStep('3', 'Results', _result != null),
      ],
    );
  }

  Widget _progressStep(String number, String label, bool complete) => Expanded(
    child: Column(
      children: [
        CircleAvatar(
          radius: 11,
          backgroundColor: complete
              ? const Color(0xFF06B6D4)
              : const Color(0xFFFFFFFF),
          child: complete
              ? const Icon(Icons.check, size: 13, color: Colors.black)
              : Text(number, style: const TextStyle(fontSize: 10)),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: const TextStyle(color: Color(0xFF475569), fontSize: 9),
        ),
      ],
    ),
  );

  Widget _progressConnector(bool active) => Expanded(
    child: Container(
      height: 1,
      margin: const EdgeInsets.only(bottom: 16),
      color: active ? const Color(0xFF06B6D4) : const Color(0xFFCBD5E1),
    ),
  );

  Widget _sectionTitle(String number, String label) => Row(
    children: [
      Container(
        width: 20,
        height: 20,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: const Color(0xFF06B6D4).withValues(alpha: .14),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Text(
          number,
          style: const TextStyle(
            color: Color(0xFF06B6D4),
            fontSize: 10,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      const SizedBox(width: 7),
      Text(
        label,
        style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
      ),
    ],
  );

  Widget _info(String text) => Container(
    padding: const EdgeInsets.all(9),
    decoration: BoxDecoration(
      color: const Color(0xFFF8F9FB),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      style: const TextStyle(color: Color(0xFF475569), fontSize: 11),
    ),
  );
  Widget _field(TextEditingController c, String label) => TextField(
    controller: c,
    keyboardType: TextInputType.number,
    decoration: InputDecoration(labelText: label),
  );
}

const _stateColors = [
  Color(0xFF3B82F6),
  Color(0xFF22C55E),
  Color(0xFFF59E0B),
  Color(0xFFA855F7),
  Color(0xFF06B6D4),
  Color(0xFFEC4899),
  Color(0xFFEF4444),
  Color(0xFF84CC16),
];

class _TimelineSequencePainter extends CustomPainter {
  const _TimelineSequencePainter(
    this.sequence,
    this.start,
    this.end,
    this.startSeconds,
    this.windowSeconds,
  );
  final List<int> sequence;
  final int start;
  final int end;
  final double startSeconds, windowSeconds;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = _timelinePlotRect(size);
    canvas.drawRect(rect, Paint()..color = const Color(0xFFFFFFFF));
    if (sequence.isEmpty || end <= start) return;
    var runStart = start;
    for (var i = start + 1; i <= end; i++) {
      if (i == end || sequence[i] != sequence[runStart]) {
        canvas.drawRect(
          Rect.fromLTWH(
            rect.left + (runStart - start) / (end - start) * rect.width,
            rect.top + 2,
            (i - runStart) / (end - start) * rect.width + .5,
            rect.height - 4,
          ),
          Paint()
            ..color =
                _stateColors[(sequence[runStart] - 1) % _stateColors.length],
        );
        runStart = i;
      }
    }
    _paintTimelineAxis(canvas, size, startSeconds, windowSeconds);
  }

  @override
  bool shouldRepaint(covariant _TimelineSequencePainter old) =>
      old.sequence != sequence ||
      old.start != start ||
      old.end != end ||
      old.startSeconds != startSeconds ||
      old.windowSeconds != windowSeconds;
}

class _ProbabilityPainter extends CustomPainter {
  const _ProbabilityPainter(
    this.probabilities,
    this.start,
    this.end,
    this.startSeconds,
    this.windowSeconds,
    this.hiddenStates,
  );
  final List<List<double>> probabilities;
  final int start;
  final int end;
  final double startSeconds, windowSeconds;
  final Set<int> hiddenStates;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = _timelinePlotRect(size);
    final left = rect.left;
    final width = rect.width;
    final height = rect.height;
    canvas.drawRect(rect, Paint()..color = const Color(0xFFF8FAFC));
    final grid = Paint()
      ..color = const Color(0xFFDDE3EA)
      ..strokeWidth = .6;
    for (var i = 0; i <= 4; i++) {
      final y = rect.top + height * i / 4;
      canvas.drawLine(Offset(left, y), Offset(rect.right, y), grid);
    }
    final range = end - start;
    if (range < 2) return;
    final stride = math.max(1, (range / math.max(2, width.ceil())).ceil());
    for (final (state, values) in probabilities.indexed) {
      if (hiddenStates.contains(state)) continue;
      if (values.isEmpty) continue;
      final path = Path();
      var point = 0;
      for (var binStart = start; binStart < end; binStart += stride) {
        final binEnd = math.min(end, binStart + stride);
        var total = 0.0;
        var count = 0;
        for (var i = binStart; i < binEnd && i < values.length; i++) {
          total += values[i];
          count++;
        }
        if (count == 0) continue;
        final x = left + (binStart - start) / math.max(1, range - 1) * width;
        final y = rect.top + height * (1 - total / count);
        point++ == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = _stateColors[state % _stateColors.length]
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.25
          ..isAntiAlias = true,
      );
    }
    _axisText(canvas, '1', Offset(5, rect.top));
    _axisText(canvas, '0', Offset(5, rect.bottom - 10));
    _paintTimelineAxis(canvas, size, startSeconds, windowSeconds);
  }

  void _axisText(Canvas canvas, String text, Offset offset) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(color: Color(0xFF64748B), fontSize: 9),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _ProbabilityPainter old) =>
      old.probabilities != probabilities ||
      old.start != start ||
      old.end != end ||
      old.hiddenStates != hiddenStates ||
      old.startSeconds != startSeconds ||
      old.windowSeconds != windowSeconds;
}

class _MicrostateWaveformPainter extends CustomPainter {
  const _MicrostateWaveformPainter(
    this.recording,
    this.startSeconds,
    this.windowSeconds,
    this.channelCount,
    this.channelOffset,
  );
  final int channelOffset;
  final EegRecording recording;
  final double startSeconds;
  final double windowSeconds;
  final int channelCount;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = _timelinePlotRect(size);
    final left = rect.left;
    final width = rect.width;
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    final channels = math.min(channelCount, recording.preview.length - channelOffset);
    if (channels == 0) return;
    final lane = rect.height / channels;
    final duration = recording.durationSeconds;
    for (var channel = 0; channel < channels; channel++) {
      final values = recording.preview[channel + channelOffset];
      if (values.length < 2 || duration <= 0) continue;
      final a = (startSeconds / duration * values.length).floor().clamp(
        0,
        values.length - 1,
      );
      final b = ((startSeconds + windowSeconds) / duration * values.length)
          .ceil()
          .clamp(a + 1, values.length);
      var mean = 0.0;
      var peak = 1e-6;
      for (var i = a; i < b; i++) mean += values[i];
      mean /= b - a;
      for (var i = a; i < b; i++)
        peak = math.max(peak, (values[i] - mean).abs());
      final center = rect.top + lane * (channel + .5);
      final path = Path();
      final stride = math.max(1, ((b - a) / math.max(2, width.ceil())).ceil());
      var point = 0;
      for (var i = a; i < b; i += stride) {
        final x = left + (i - a) / math.max(1, b - a - 1) * width;
        final y = center - (values[i] - mean) / peak * lane * .38;
        point++ == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = const Color(0xFF172033)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..isAntiAlias = true,
      );
      final label = TextPainter(
        text: TextSpan(
          text: recording.labels[channel + channelOffset],
          style: const TextStyle(
            color: Color(0xFF334155),
            fontSize: 9,
            fontWeight: FontWeight.w600,
          ),
        ),
        maxLines: 1,
        ellipsis: '…',
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: left - 6);
      label.paint(canvas, Offset(4, center - label.height / 2));
      canvas.drawLine(
        Offset(left, rect.top + lane * (channel + 1)),
        Offset(rect.right, rect.top + lane * (channel + 1)),
        Paint()
          ..color = const Color(0xFFE2E8F0)
          ..strokeWidth = .5,
      );
    }
    _paintTimelineAxis(
      canvas,
      size,
      startSeconds,
      windowSeconds,
      darkText: true,
    );
  }

  @override
  bool shouldRepaint(covariant _MicrostateWaveformPainter old) =>
      old.recording != recording ||
      old.startSeconds != startSeconds ||
      old.windowSeconds != windowSeconds ||
      old.channelCount != channelCount || old.channelOffset != channelOffset;
}

const _timelineLeft = 58.0;
const _timelineRight = 8.0;
const _timelineBottom = 18.0;

Rect _timelinePlotRect(Size size) => Rect.fromLTWH(
  _timelineLeft,
  0,
  math.max(1, size.width - _timelineLeft - _timelineRight),
  math.max(1, size.height - _timelineBottom),
);

void _paintTimelineAxis(
  Canvas canvas,
  Size size,
  double start,
  double window, {
  bool darkText = false,
}) {
  final rect = _timelinePlotRect(size);
  final color = darkText ? const Color(0xFF475569) : const Color(0xFF475569);
  final grid = Paint()
    ..color = color.withValues(alpha: .18)
    ..strokeWidth = .5;
  for (var i = 0; i <= 4; i++) {
    final x = rect.left + rect.width * i / 4;
    canvas.drawLine(Offset(x, rect.top), Offset(x, rect.bottom), grid);
    final seconds = start + window * i / 4;
    final text = seconds >= 60
        ? '${seconds ~/ 60}:${(seconds % 60).toStringAsFixed(1).padLeft(4, '0')}'
        : '${seconds.toStringAsFixed(window <= 5 ? 1 : 0)} s';
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: color, fontSize: 8),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(
      canvas,
      Offset(
        (x - tp.width / 2).clamp(rect.left, rect.right - tp.width),
        rect.bottom + 3,
      ),
    );
  }
}

class _TopographyPainter extends CustomPainter {
  const _TopographyPainter(
    this.positions,
    this.maps,
    this.correlations,
    this.labels,
    this.subtitles,
  );
  final List<MicrostateScalpPosition> positions;
  final List<List<double>> maps;
  final List<double?> correlations;
  final List<String> labels;
  final List<String> subtitles;

  @override
  void paint(Canvas c, Size size) {
    if (maps.isEmpty) return;
    final columns = maps.length < 4 ? maps.length : 4;
    final rows = (maps.length / columns).ceil();
    final cellWidth = size.width / columns;
    final cellHeight = size.height / rows;
    for (final (s, map) in maps.indexed) {
      final row = s ~/ columns;
      final column = s % columns;
      final center = Offset(
        cellWidth * (column + .5),
        cellHeight * (row + .52),
      );
      final radius = math.min(cellWidth * .36, cellHeight * .32);
      final head = Path()
        ..addOval(Rect.fromCircle(center: center, radius: radius));
      c.save();
      c.clipPath(head);
      const grid = 84;
      final step = radius * 2 / grid;
      final absmax = map
          .map((x) => x.abs())
          .fold<double>(0, math.max)
          .clamp(1e-12, double.infinity);
      for (var gy = 0; gy < grid; gy++) {
        for (var gx = 0; gx < grid; gx++) {
          final x = -1 + (gx + .5) * 2 / grid;
          final y = 1 - (gy + .5) * 2 / grid;
          if (x * x + y * y > 1) continue;
          final value = _interpolate(x, y, map) / absmax;
          c.drawRect(
            Rect.fromLTWH(
              center.dx - radius + gx * step,
              center.dy - radius + gy * step,
              step + .5,
              step + .5,
            ),
            Paint()..color = _diverging(value),
          );
        }
      }
      c.restore();
      c.drawCircle(
        center,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = _stateColors[s % _stateColors.length],
      );
      // Nose and ears follow the conventional EEGLAB topoplot silhouette.
      c.drawPath(
        Path()
          ..moveTo(center.dx - radius * .16, center.dy - radius * .96)
          ..lineTo(center.dx, center.dy - radius * 1.18)
          ..lineTo(center.dx + radius * .16, center.dy - radius * .96),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8
          ..color = const Color(0xFFE2E8F0),
      );
      for (final side in [-1.0, 1.0]) {
        c.drawPath(
          Path()
            ..moveTo(center.dx + side * radius, center.dy - radius * .25)
            ..cubicTo(
              center.dx + side * radius * 1.14,
              center.dy - radius * .18,
              center.dx + side * radius * 1.14,
              center.dy + radius * .18,
              center.dx + side * radius,
              center.dy + radius * .28,
            ),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = const Color(0xFFE2E8F0),
        );
      }
      for (final position in positions) {
        // electrodes beyond the head outline (e.g. ear / reference sites) are not drawn
        if (position.x * position.x + position.y * position.y > 1.02) continue;
        c.drawCircle(
          center +
              Offset(position.x * radius, -position.y * radius),
          math.max(1.2, radius * .022),
          Paint()..color = const Color(0xFFF8FAFC),
        );
      }
      final correlation = s < correlations.length ? correlations[s] : null;
      final tp = TextPainter(
        text: TextSpan(
          text: correlation != null
              ? '${labels[s]}  r=${correlation.toStringAsFixed(2)}'
              : labels[s],
          style: TextStyle(
            color: _stateColors[s % _stateColors.length],
            fontWeight: FontWeight.bold,
            fontSize: 12,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(c, Offset(center.dx - tp.width / 2, row * cellHeight + 2));

      final barWidth = radius * 1.25;
      final barLeft = center.dx - barWidth / 2;
      final barTop = row * cellHeight + cellHeight - 13;
      const colorSteps = 36;
      for (var i = 0; i < colorSteps; i++) {
        c.drawRect(
          Rect.fromLTWH(
            barLeft + i * barWidth / colorSteps,
            barTop,
            barWidth / colorSteps + .5,
            6,
          ),
          Paint()..color = _diverging(-1 + 2 * i / (colorSteps - 1)),
        );
      }
      c.drawRect(
        Rect.fromLTWH(barLeft, barTop, barWidth, 6),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = .6
          ..color = const Color(0xFF475569),
      );
      for (final (text, x, anchorRight) in [
        ('−max', barLeft - 3, true),
        ('0', barLeft + barWidth / 2, null),
        ('+max', barLeft + barWidth + 3, false),
      ]) {
        final lp = TextPainter(
          text: TextSpan(text: text, style: const TextStyle(fontSize: 9, color: Color(0xFF475569))),
          textDirection: TextDirection.ltr,
        )..layout();
        final dx = anchorRight == true ? x - lp.width : (anchorRight == null ? x - lp.width / 2 : x);
        lp.paint(c, Offset(dx, anchorRight == null ? barTop + 7 : barTop - 2));
      }
      if (s < subtitles.length && subtitles[s].isNotEmpty) {
        final sp = TextPainter(
          text: TextSpan(text: subtitles[s], style: const TextStyle(fontSize: 10.5, color: Color(0xFF475569))),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: cellWidth - 8);
        sp.paint(c, Offset(center.dx - sp.width / 2, barTop - 18));
      }
    }
  }

  double _interpolate(double x, double y, List<double> values) {
    var weighted = 0.0, weights = 0.0;
    for (var i = 0; i < positions.length; i++) {
      final p = positions[i];
      final d2 = math.pow(x - p.x, 2) + math.pow(y - p.y, 2);
      if (d2 < 1e-8) return values[i];
      final weight = 1 / math.pow(d2, 1.5);
      weighted += values[i] * weight;
      weights += weight;
    }
    return weighted / weights;
  }

  Color _diverging(double value) {
    final v = value.clamp(-1.0, 1.0);
    if (v < 0) return Color.lerp(const Color(0xFF3B4CC0), Colors.white, v + 1)!;
    return Color.lerp(Colors.white, const Color(0xFFB40426), v)!;
  }

  @override
  bool shouldRepaint(covariant _TopographyPainter old) =>
      old.maps != maps || old.positions != positions || old.subtitles != subtitles;
}

class _Swatch extends StatelessWidget {
  const _Swatch(this.color, this.label);
  final Color color;
  final String label;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(width: 10, height: 10, color: color),
      const SizedBox(width: 4),
      Text(label, style: const TextStyle(fontSize: 11, color: Color(0xFF475569))),
    ],
  );
}

/// Grouped bars per word class: chance, Markov, observed (percent of words).
class _SyntaxBarsPainter extends CustomPainter {
  const _SyntaxBarsPainter(this.classes, this.examples);
  final Map<String, String> examples;
  final List<Map> classes;

  @override
  void paint(Canvas c, Size z) {
    if (classes.isEmpty) return;
    final left = 38.0, bottom = 32.0, top = 6.0;
    final plotW = z.width - left - 4, plotH = z.height - bottom - top;
    double v(Map m, String k) => m[k] is num ? (m[k] as num).toDouble() : 0.0;
    var maxV = 0.0;
    for (final m in classes) {
      for (final k in ['theoretical', 'markov', 'empirical']) {
        maxV = math.max(maxV, v(m, k));
      }
    }
    if (maxV <= 0) maxV = 1;
    final axis = Paint()..color = const Color(0xFF334155);
    for (var g = 0; g <= 4; g++) {
      final y = top + plotH * (1 - g / 4);
      c.drawLine(Offset(left, y), Offset(left + plotW, y), axis);
      final t = TextPainter(
        text: TextSpan(text: '${(maxV * g / 4 * 100).toStringAsFixed(0)}%', style: const TextStyle(fontSize: 9, color: Color(0xFF475569))),
        textDirection: TextDirection.ltr,
      )..layout();
      t.paint(c, Offset(left - t.width - 4, y - t.height / 2));
    }
    final group = plotW / classes.length;
    const colors = [Color(0xFF64748B), Color(0xFFF59E0B), Color(0xFF22D3EE)];
    const keys = ['theoretical', 'markov', 'empirical'];
    for (var i = 0; i < classes.length; i++) {
      final bw = group * .22;
      for (var b = 0; b < 3; b++) {
        final h = plotH * v(classes[i], keys[b]) / maxV;
        c.drawRect(Rect.fromLTWH(left + i * group + group * .12 + b * (bw + 2), top + plotH - h, bw, h), Paint()..color = colors[b]);
      }
      final t = TextPainter(
        text: TextSpan(
          text: (examples[v(classes[i], 'entropy_bits').toStringAsFixed(3)] ?? v(classes[i], 'entropy_bits').toStringAsFixed(2)),
          style: const TextStyle(fontSize: 9, color: Color(0xFF475569)),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      t.paint(c, Offset(left + i * group + (group - t.width) / 2, top + plotH + 4));
    }
  }

  @override
  bool shouldRepaint(covariant _SyntaxBarsPainter old) => old.classes != classes;
}

/// mode 0 = all samples (%), 1 = after leaving a state (%), 2 = versus chance (×).
class _TransitionPainter extends CustomPainter {
  const _TransitionPainter(this.matrix, this.labels, this.mode);
  final List<List<double>> matrix;
  final List<String> labels;
  final int mode;

  TextPainter _t(String s, double size, Color color, {FontWeight? w}) => TextPainter(
    text: TextSpan(text: s, style: TextStyle(fontSize: size, color: color, fontWeight: w)),
    textDirection: TextDirection.ltr,
  )..layout();

  @override
  void paint(Canvas c, Size z) {
    if (matrix.isEmpty) return;
    final n = matrix.length;
    const left = 46.0, top = 34.0;
    final side = math.min(z.width - left - 8, z.height - top - 8);
    if (side <= 20) return;
    final cell = side / n;
    var maxV = 1e-12;
    for (var i = 0; i < n; i++) {
      for (var j = 0; j < n; j++) {
        if (mode == 0 || i != j) maxV = math.max(maxV, matrix[i][j]);
      }
    }
    final title = _t('TO state →', 11, const Color(0xFF475569), w: FontWeight.w600);
    title.paint(c, Offset(left + (side - title.width) / 2, 0));
    c.save();
    c.translate(12, top + (side + _t('FROM state →', 11, const Color(0xFF475569)).width) / 2);
    c.rotate(-math.pi / 2);
    _t('FROM state →', 11, const Color(0xFF475569), w: FontWeight.w600).paint(c, Offset.zero);
    c.restore();
    for (var i = 0; i < n; i++) {
      final color = _stateColors[i % _stateColors.length];
      final lab = _t(i < labels.length ? labels[i] : '', 12, color, w: FontWeight.bold);
      lab.paint(c, Offset(left - lab.width - 6, top + i * cell + (cell - lab.height) / 2));
      lab.paint(c, Offset(left + i * cell + (cell - lab.width) / 2, top - lab.height - 2));
      for (var j = 0; j < n; j++) {
        final rect = Rect.fromLTWH(left + j * cell, top + i * cell, cell - 1.5, cell - 1.5);
        if (i == j && mode != 0) {
          c.drawRect(rect, Paint()..color = const Color(0xFFF0F4F8));
          final dash = _t('—', 11, const Color(0xFF64748B));
          dash.paint(c, Offset(rect.center.dx - dash.width / 2, rect.center.dy - dash.height / 2));
          continue;
        }
        final value = matrix[i][j];
        Color fill;
        String text;
        double strength;
        if (mode == 2) {
          final lg = value <= 0 ? -1.0 : (math.log(value) / math.ln2).clamp(-1.0, 1.0);
          fill = lg >= 0
              ? Color.lerp(const Color(0xFF172554), const Color(0xFFF59E0B), lg)!
              : Color.lerp(const Color(0xFF172554), const Color(0xFF3B82F6), -lg)!;
          text = value <= 0 ? '–' : '×${value.toStringAsFixed(value >= 10 ? 0 : 1)}';
          strength = lg.abs();
        } else {
          strength = (value / maxV).clamp(0.0, 1.0);
          fill = Color.lerp(const Color(0xFF172554), const Color(0xFF22D3EE), strength)!;
          text = mode == 0 ? '${(value * 100).toStringAsFixed(2)}%' : '${(value * 100).toStringAsFixed(0)}%';
        }
        c.drawRect(rect, Paint()..color = fill);
        final tp = _t(text, math.max(7, math.min(12, cell * .26)), strength > .6 && mode != 2 ? Colors.black : Colors.white);
        tp.paint(c, Offset(rect.center.dx - tp.width / 2, rect.center.dy - tp.height / 2));
      }
    }
  }

  @override
  bool shouldRepaint(covariant _TransitionPainter old) =>
      old.matrix != matrix || old.mode != mode || old.labels != labels;
}

/// Descriptive comparisons use the shared batch template, preserving state identity.
class MicrostateGroupPanel extends StatefulWidget {
  const MicrostateGroupPanel({super.key, required this.result});
  final MicrostateResult result;
  @override
  State<MicrostateGroupPanel> createState() => _MicrostateGroupPanelState();
}

class _MicrostateGroupPanelState extends State<MicrostateGroupPanel> {
  String metric = 'coverage';
  String grouping = 'Recording';
  int state = 0;
  double? entropy;
  static const metrics = {
    'coverage': 'Coverage (%)',
    'mean_duration_ms': 'Mean duration (ms)',
    'occurrence_hz': 'Occurrence (/s)',
    'gev': 'State GEV (%)',
    'normalized_lz': 'Normalized LZ',
    'syntax': 'Syntax observed share (%)',
    'syntax_ratio': 'Syntax observed / chance',
  };
  String subject(String name) =>
      RegExp(
        r'(?:^|_)(sub-[a-z0-9]+|sub[0-9]+(?:_TKG[0-9]+)?|P[0-9]+|S[0-9]+)(?:_|$)',
        caseSensitive: false,
      ).firstMatch(name)?.group(1) ??
      name;

  @override
  Widget build(BuildContext context) {
    final r = widget.result;
    final isSyntax = metric.startsWith('syntax');
    final entropies = <double>{
      for (final recording in r.recordings)
        for (final c in recording.syntax['classes'] as List? ?? [])
          (c['entropy_bits'] as num).toDouble(),
    }.toList()..sort();
    final selectedEntropy = entropies.contains(entropy)
        ? entropy
        : entropies.firstOrNull;
    final selectedState = state < r.stateLabels.length ? state : 0;
    final groups = <String, List<double>>{};
    for (final recording in r.recordings) {
      double? value;
      if (isSyntax) {
        if ((recording.syntax['windows'] as num? ?? 0) > 0) {
          for (final c in recording.syntax['classes'] as List? ?? []) {
            if ((c['entropy_bits'] as num).toDouble() == selectedEntropy) {
              value =
                  (c[metric == 'syntax' ? 'empirical' : 'ratio_theoretical']
                          as num?)
                      ?.toDouble();
              if (metric == 'syntax' && value != null) value *= 100;
            }
          }
        }
      } else if (metric == 'normalized_lz') {
        value = recording.sequenceMetrics[metric]?.toDouble();
      } else if (selectedState < recording.states.length) {
        value = (recording.states[selectedState][metric] as num?)?.toDouble();
        if ((metric == 'coverage' || metric == 'gev') && value != null)
          value *= 100;
      }
      if (value == null || !value.isFinite) continue;
      final key = grouping == 'Subject mean'
          ? subject(recording.filename)
          : recording.filename;
      groups.putIfAbsent(key, () => []).add(value);
    }
    final means = groups.map(
      (key, values) =>
          MapEntry(key, values.reduce((a, b) => a + b) / values.length),
    );
    final maximum = math.max(1e-12, means.values.fold(0.0, math.max));
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Group comparisons · shared template',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Wrap(
              spacing: 18,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                DropdownButton<String>(
                  value: metric,
                  items: [
                    for (final e in metrics.entries)
                      DropdownMenuItem(value: e.key, child: Text(e.value)),
                  ],
                  onChanged: (v) => setState(() => metric = v!),
                ),
                DropdownButton<String>(
                  value: grouping,
                  items: [
                    for (final v in ['Recording', 'Subject mean'])
                      DropdownMenuItem(value: v, child: Text(v)),
                  ],
                  onChanged: (v) => setState(() => grouping = v!),
                ),
                if (!isSyntax && metric != 'normalized_lz')
                  DropdownButton<int>(
                    value: selectedState,
                    items: [
                      for (final (i, label) in r.stateLabels.indexed)
                        DropdownMenuItem(value: i, child: Text('State $label')),
                    ],
                    onChanged: (v) => setState(() => state = v!),
                  ),
                if (isSyntax && selectedEntropy != null)
                  DropdownButton<double>(
                    value: selectedEntropy,
                    items: [
                      for (final h in entropies)
                        DropdownMenuItem(
                          value: h,
                          child: Text('${h.toStringAsFixed(3)} bits'),
                        ),
                    ],
                    onChanged: (v) => setState(() => entropy = v),
                  ),
              ],
            ),
            const Text(
              'Descriptive values. Subject means weight each recording equally; repeated sessions are not independent participants. Participant IDs are inferred from filenames; verify them in the CSV tables.',
            ),
            const SizedBox(height: 10),
            if (means.isEmpty)
              const Text('No valid observations for this selection.'),
            for (final entry in means.entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    SizedBox(
                      width: 200,
                      child: Tooltip(
                        message: entry.key,
                        child: Text(
                          entry.key,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: LinearProgressIndicator(
                        value: (entry.value / maximum).clamp(0.0, 1.0),
                        minHeight: 12,
                      ),
                    ),
                    SizedBox(
                      width: 100,
                      child: Text(
                        '  ${entry.value.toStringAsFixed(3)} (n=${groups[entry.key]!.length})',
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 10),
            const SelectableText(
              'Compiled exports: MicrostateGroupStates.csv · MicrostateGroupSyntax.csv · MicrostateGroupTransitions.csv · GroupTables_README.txt',
            ),
            TextButton.icon(
              icon: const Icon(Icons.folder_open),
              label: const Text('Open compiled tables folder'),
              onPressed: () async {
                try {
                  await Process.run(
                    Platform.isWindows
                        ? 'explorer.exe'
                        : Platform.isMacOS
                        ? 'open'
                        : 'xdg-open',
                    [r.outputDirectory],
                  );
                } catch (e) {
                  if (context.mounted)
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Could not open folder: $e')),
                    );
                }
              },
            ),
            SelectableText('Output: ${r.outputDirectory}'),
          ],
        ),
      ),
    );
  }
}
