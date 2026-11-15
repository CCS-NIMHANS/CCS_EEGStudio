import 'linked_review_profile.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import '../eeg_viewer.dart';
import '../epoch_service.dart';
import '../models.dart';
import '../recording_loader.dart';
import '../recording_save_dialog.dart';
import '../recording_storage.dart';
import 'erp_core_presets.dart';
import 'erp_image_panel.dart';
import 'topo_channel_selector.dart';
import 'erp_workbench_view.dart';
import 'interactive_erp_session.dart';
import 'stim_epoch_panel.dart';
import 'protocol_tools.dart';

const List<Color> _erpCondColors = [
  Color(0xFF3B82F6), // Blue: Condition A
  Color(0xFFEF4444), // Red: Condition B
  Color(0xFF10B981), // Emerald: Condition C
  Color(0xFFF59E0B), // Amber: Condition D
];

/// One interactive path: protocol -> browse/review trials -> live averages.
/// Advanced statistics remain in the workbench and consume accepted trials.
class InteractiveErpWorkspace extends StatefulWidget {
  const InteractiveErpWorkspace({
    super.key,
    required this.recording,
    required this.config,
    required this.onOpenRecording,
    required this.onUseReviewed,
    this.availableRecordings = const [],
    this.onSelectRecording,
  });
  final EegRecording? recording;
  final AnalysisConfig config;
  final VoidCallback onOpenRecording;
  final ValueChanged<EegRecording> onUseReviewed;
  final List<EegRecording> availableRecordings;
  final ValueChanged<EegRecording>? onSelectRecording;
  @override
  State<InteractiveErpWorkspace> createState() =>
      _InteractiveErpWorkspaceState();
}

class _InteractiveErpWorkspaceState extends State<InteractiveErpWorkspace> {
  InteractiveErpSession? _session;
  String _preset = 'Custom', _mode = 'epochs', _trialSubView = 'trial', _status = '';
  bool _busy = false, _dirty = false, _closing = false;
  int _trial = 0, _channel = 0;
  String? _condition;
  late final TextEditingController _baseStartCtrl = TextEditingController(text: '-200');
  late final TextEditingController _baseEndCtrl = TextEditingController(text: '0');
  File? _reviewFile;
  Timer? _persistTimer;
  EegRecording? _savedReviewed;
  int _savedRevision = -1;
  EegRecording? _measurementRecording;
  Map<String, dynamic>? _measurementInspection;
  String? _measurementOutput;
  int _measurementRevision = -1;

  Future<void> _openMeasurements() async {
    final session = _session;
    if (session == null || _dirty || _busy || session.acceptedCount == 0)
      return;
    if (_measurementRecording != null &&
        _measurementRevision == session.revision) {
      setState(() => _mode = 'measurements');
      return;
    }
    setState(() {
      _busy = true;
      _status = 'Preparing accepted trials for measurements…';
    });
    try {
      final identity = sha256
          .convert(utf8.encode(jsonEncode(session.rejected.toList()..sort())))
          .toString();
      final dir = Directory('${_reviewFile!.path}.measurements/$identity');
      await dir.create(recursive: true);
      final path = '${dir.path}/accepted.ccseeg';
      final accepted = session.accepted();
      await RecordingStorage.save(accepted, path);
      final recording = await RecordingLoader().load(path);
      final inspection = linkedReviewInspection(
        recording,
        _preset,
        widget.config,
      );
      if (!mounted) return;
      setState(() {
        _measurementRecording = recording;
        _measurementInspection = inspection;
        _measurementOutput = dir.path;
        _measurementRevision = session.revision;
        _mode = 'measurements';
        _status = 'Measurements use the current accepted trials automatically.';
      });
    } catch (e) {
      if (mounted)
        setState(() => _status = 'Could not prepare measurements: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void initState() {
    super.initState();
    final record = widget.recording;
    if (record != null) {
      for (final name in erpCorePresets.keys) {
        if (record.path.toLowerCase().contains(name.toLowerCase())) {
          _preset = name;
          if (!record.isEpoched) _applyPreset(name);
          break;
        }
      }
      if (record.isEpoched)
        WidgetsBinding.instance.addPostFrameCallback((_) => _createEpochs());
    }
  }

  @override
  void dispose() {
    _closing = true;
    _persistTimer?.cancel();
    _persist();
    _baseStartCtrl.dispose();
    _baseEndCtrl.dispose();
    super.dispose();
  }

  void _applyInteractiveBaseline() {
    final s = _session;
    if (s == null) return;
    final start = double.tryParse(_baseStartCtrl.text.trim()) ?? -200.0;
    final end = double.tryParse(_baseEndCtrl.text.trim()) ?? 0.0;
    setState(() {
      _session = s.withBaselineCorrection(start, end);
      _measurementRevision = -1;
      _status = 'Applied baseline correction [${start.round()}..${end.round()} ms] to ${s.epochs.epochCount} epochs.';
    });
  }

  void _applyPreset(String name) {
    final p = erpCorePresets[name];
    if (p == null) return;
    final cfg = widget.config;
    cfg.stimEpochs = true;
    cfg.stimMarkers = [];
    cfg.stimPattern = '';
    cfg.stimResponseRules = {};
    cfg.stimCropMarker = '';
    cfg.stimCropMinutes = 0;
    cfg.stimMarkerGroups = {
      p['a_name'] as String: List<String>.from(p['a_codes'] as List),
      p['b_name'] as String: List<String>.from(p['b_codes'] as List),
    };
    cfg.stimTmin = (p['epoch'][0] as num).toDouble();
    cfg.stimTmax = (p['epoch'][1] as num).toDouble();
    cfg.stimBaseline = true;
    cfg.stimBaselineStart = (p['baseline'][0] as num).toDouble();
    cfg.stimBaselineEnd = (p['baseline'][1] as num).toDouble();
    // Pass the same task and windows to advanced measurements.
    cfg.erpAnalysisProtocol = {'task': name};
  }

  Future<void> _createEpochs() async {
    final input = widget.recording;
    if (_busy || input == null) return;
    setState(() {
      _busy = true;
      _status = 'Loading trials…';
    });
    try {
      final full = await RecordingLoader().loadFull(input);
      EegRecording epochs;
      final spec = widget.config.stimEpochSpec;
      if (full.isEpoched) {
        epochs = full;
      } else {
        if (spec == null)
          throw StateError('Choose a preset or define events first.');
        final events = spec.selectEvents(full.markers);
        if (events.isEmpty)
          throw StateError(
            'No matching events. Choose the correct task or edit event codes.',
          );
        final times = events
            .map((e) => (e.$1 * full.sampleRate).round())
            .toSet();
        epochs = await generateEpochsInWorker(
          recording: full,
          selectedMarkers: full.markers
              .where(
                (m) =>
                    spec.matches(m) &&
                    times.contains((m.startSeconds * full.sampleRate).round()),
              )
              .toList(),
          options: EpochOptions(
            targetEvents: const [],
            markerGroups: spec.markerGroups,
            tmin: spec.tmin,
            tmax: spec.tmax,
            applyBaseline: spec.baseline,
            baselineMin: spec.baselineStart,
            baselineMax: spec.baselineEnd,
          ),
        );
      }
      final session = InteractiveErpSession(epochs);
      // Keep the signal cache separate from review decisions. A protocol or
      // input change gets a different decision file, so old rejections cannot leak.
      final stat = await File(input.path).stat();
      final identity = sha256
          .convert(
            utf8.encode(
              jsonEncode([
                input.path,
                stat.size,
                stat.modified.toIso8601String(),
                epochs.sampleRate,
                epochs.sampleCount,
                epochs.pointsPerEpoch,
                input.isEpoched ? null : spec?.toJson(),
              ]),
            ),
          )
          .toString();
      final root = Directory(
        '${File(input.path).parent.path}/.ccs_eegstudio_cache/erp_review',
      );
      try {
        await root.create(recursive: true);
        _reviewFile = File('${root.path}/$identity.ccsreview');
      } catch (_) {
        final fallback = Directory(
          '${Platform.environment['HOME'] ?? Directory.systemTemp.path}/.config/ccs-eeg-studio/erp_review',
        );
        await fallback.create(recursive: true);
        _reviewFile = File('${fallback.path}/$identity.ccsreview');
      }
      try {
        final saved = jsonDecode(await _reviewFile!.readAsString()) as Map;
        for (final i in (saved['rejected'] as List? ?? []).whereType<int>()) {
          if (i >= 0 && i < epochs.epochCount) session.setRejected(i, true);
        }
      } catch (_) {
        /* first review */
      }
      if (!mounted) return;
      setState(() {
        _session = session;
        _trial = 0;
        _condition = null;
        _channel = 0;
        final roi = erpCorePresets[_preset]?['roi'] as List? ?? [];
        for (final label in roi) {
          final i = epochs.labels.indexOf('$label');
          if (i >= 0) {
            _channel = i;
            break;
          }
        }
        _dirty = false;
        _savedReviewed = null;
        _savedRevision = -1;
        _mode = 'epochs';
        _status =
            '${session.acceptedCount}/${epochs.epochCount} trials included. Review decisions are saved locally.';
      });
    } catch (e) {
      if (mounted) setState(() => _status = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _persist() {
    final file = _reviewFile, session = _session;
    if (file == null || session == null) return;
    final data = jsonEncode({
      'source': widget.recording?.path,
      'rejected': session.rejected.toList()..sort(),
    });
    try {
      // Only the small decision JSON is written here, never signal samples.
      // Finish before disposal returns so Windows has no lingering file handle.
      final staging = File('${file.path}.writing');
      staging.writeAsStringSync(data, flush: true);
      staging.renameSync(file.path);
    } catch (e) {
      if (mounted && !_closing)
        setState(() => _status = 'Could not save review decisions: $e');
    }
  }

  void _reject(int index, bool value) {
    final session = _session!;
    setState(() {
      session.setRejected(index, value);
      _status =
          '${session.acceptedCount}/${session.epochs.epochCount} trials included · averages updated';
    });
    _persistTimer?.cancel();
    _persistTimer = Timer(const Duration(milliseconds: 150), _persist);
  }

  Future<void> _save() async {
    final session = _session;
    if (session == null || _dirty || _busy || session.acceptedCount == 0)
      return;
    try {
      if (_savedReviewed == null || _savedRevision != session.revision) {
        final input = widget.recording!;
        final path = await saveRecordingDialog(
          context,
          dialogTitle: 'Save reviewed epochs · accepted trials only',
          initialDirectory: File(input.path).parent.path,
          fileName:
              '${recordingDialogStem(input.path.split(RegExp(r'[/\\]')).last)}-reviewed-epo.${RecordingStorage.extension}',
        );
        if (path == null || !mounted) return;
        if (File(path).absolute.path == File(input.path).absolute.path) {
          setState(
            () => _status =
                'Choose a new filename to preserve the input recording.',
          );
          return;
        }
        setState(() {
          _busy = true;
          _status =
              'Saving accepted trials; no cleaning or epoching is repeated…';
        });
        await RecordingStorage.save(session.accepted(), path);
        _savedReviewed = await RecordingLoader().load(path);
        _savedRevision = session.revision;
        _persist();
        if (!mounted) return;
        setState(
          () =>
              _status = 'Saved ${session.acceptedCount} reviewed trials: $path',
        );
      }
    } catch (e) {
      if (mounted) setState(() => _status = 'Save failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _buildRecordingSwitcherBar(EegRecording input) {
    final recs = widget.availableRecordings;
    if (recs.length <= 1 && widget.onSelectRecording == null) {
      return const SizedBox.shrink();
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: const BoxDecoration(
        color: Color(0xFF0B1120),
        border: Border(bottom: BorderSide(color: Colors.white12)),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Text(
            'Active Recording:',
            style: TextStyle(fontSize: 11, color: Colors.white70, fontWeight: FontWeight.w600),
          ),
          for (final rec in recs)
            ChoiceChip(
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              avatar: Icon(
                rec.path.contains('_clean')
                    ? Icons.auto_fix_high
                    : Icons.graphic_eq,
                size: 14,
                color: rec.path == input.path
                    ? Colors.white
                    : (rec.path.contains('_clean')
                          ? Colors.greenAccent
                          : Colors.white70),
              ),
              label: Text(
                '${rec.path.split(RegExp(r'[/\\]')).last} (${rec.labels.length} ch · ${rec.sampleRate.round()} Hz)',
                style: const TextStyle(fontSize: 11),
              ),
              selected: rec.path == input.path,
              selectedColor: rec.path.contains('_clean')
                  ? const Color(0xFF166534)
                  : const Color(0xFF1D4ED8),
              onSelected: widget.onSelectRecording == null || _busy
                  ? null
                  : (_) => widget.onSelectRecording!(rec),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final input = widget.recording, session = _session;
    if (input == null)
      return Center(
        child: FilledButton.icon(
          onPressed: widget.onOpenRecording,
          icon: const Icon(Icons.folder_open),
          label: const Text('Open EEG / epochs'),
        ),
      );
    final filtered = session == null
        ? <int>[]
        : [
            for (var i = 0; i < session.epochs.epochCount; i++)
              if (_condition == null || session.condition(i) == _condition) i,
          ];
    if (filtered.isNotEmpty && !filtered.contains(_trial))
      _trial = filtered.first;
    if (_mode == 'measurements' && _measurementRecording != null) {
      final resultPath = '$_measurementOutput/erp_results.ccserp';
      var validResult = false;
      try {
        final result = jsonDecode(File(resultPath).readAsStringSync());
        validResult =
            result is Map &&
            result['files'] is List &&
            (result['files'] as List).isNotEmpty;
      } catch (_) {
        /* unfinished or missing results are computed again */
      }
      return Column(
        children: [
          _buildRecordingSwitcherBar(input),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: const BoxDecoration(
              color: Color(0xFF0F172A),
              border: Border(bottom: BorderSide(color: Colors.white12)),
            ),
            child: Row(
              children: [
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: 'epochs',
                      icon: Icon(Icons.view_list, size: 16),
                      label: Text('Trial Review & ERPimage'),
                    ),
                    ButtonSegment(
                      value: 'measurements',
                      icon: Icon(Icons.analytics_outlined, size: 16),
                      label: Text('ERP Analysis & Measurements'),
                    ),
                  ],
                  selected: const {'measurements'},
                  onSelectionChanged: (v) {
                    if (v.first == 'epochs') {
                      setState(() => _mode = 'epochs');
                    }
                  },
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    '${session!.acceptedCount} accepted trials · conditions & baseline carried from review',
                    style: const TextStyle(fontSize: 12, color: Colors.white70),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ErpWorkbenchView(
              key: ValueKey('linked-measurements-$_measurementRevision'),
              activeRecording: _measurementRecording,
              config: widget.config,
              batchMode: false,
              linkedReview: true,
              linkedOutputDirectory: _measurementOutput,
              initialInspection: _measurementInspection,
              initialResultPath: validResult ? resultPath : null,
            ),
          ),
        ],
      );
    }
    final sidebar = ListView(
      padding: const EdgeInsets.all(12),
      children: [
        const Text(
          'Epochs & ERP',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Text(
          'Input: ${input.path.split(RegExp(r'[/\\]')).last}',
          style: const TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 12),
        Card(
          child: ExpansionTile(
            key: ValueKey('erp-protocol-${session == null}'),
            initiallyExpanded: session == null && !input.isEpoched,
            title: const Text('1. Protocol & event groups'),
            subtitle: Text(
              input.isEpoched ? 'Saved trial definitions retained' : _preset,
            ),
            childrenPadding: const EdgeInsets.all(10),
            children: [
              if (!input.isEpoched) ...[
                DropdownButtonFormField<String>(
                  initialValue: _preset,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'ERP-CORE / custom protocol',
                  ),
                  items: [
                    for (final p in [...erpCorePresets.keys, 'Custom'])
                      DropdownMenuItem(value: p, child: Text(p)),
                  ],
                  onChanged: _busy
                      ? null
                      : (v) => setState(() {
                          _preset = v!;
                          _applyPreset(v);
                          _dirty = session != null;
                        }),
                ),
                ProtocolTools(
                  config: widget.config,
                  onChanged: () => setState(() => _dirty = session != null),
                ),
                StimEpochPanel(
                  config: widget.config,
                  markers: input.markers,
                  compact: true,
                  showEnableControl: true,
                  onChanged: () => setState(() {
                    _preset = 'Custom';
                    _dirty = session != null;
                  }),
                ),
              ] else
                Text(
                  '${input.epochCount} saved trials. Their groups and baseline are preserved.',
                ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _busy ? null : _createEpochs,
                icon: const Icon(Icons.content_cut),
                label: Text(
                  session == null
                      ? 'Create / load trial preview'
                      : 'Update trial preview',
                ),
              ),
              if (_dirty)
                const Text(
                  'Protocol changed. Update trials before continuing.',
                ),
            ],
          ),
        ),
        Card(
          child: ExpansionTile(
            title: const Text('2. Epoching & trial review'),
            subtitle: Text(
              session == null
                  ? 'Create trials first'
                  : '${session.acceptedCount} included · ${session.rejected.length} excluded',
            ),
            onExpansionChanged: (open) {
              if (open) setState(() => _mode = 'epochs');
            },
            childrenPadding: const EdgeInsets.all(10),
            children: [
              const Text(
                'Browse trials, exclude artifacts, or reinstate any excluded trial. Original samples stay intact.',
              ),
              if (session != null)
                DropdownButtonFormField<String>(
                  value: _condition ?? '*',
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Browse condition',
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: '*',
                      child: Text('All conditions'),
                    ),
                    for (final c in session.conditions)
                      DropdownMenuItem(
                        value: c,
                        child: Text('$c (${session.counts[c]} included)'),
                      ),
                  ],
                  onChanged: (v) =>
                      setState(() => _condition = v == '*' ? null : v),
                ),
              if (session != null)
                SizedBox(
                  height: 220,
                  child: ListView(
                    children: [
                      for (final i in filtered)
                        CheckboxListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            'Trial ${i + 1} · ${session.condition(i)}',
                          ),
                          subtitle: i < session.epochs.epochStartSeconds.length
                              ? Text(
                                  'Source ${session.epochs.epochStartSeconds[i].toStringAsFixed(3)} s',
                                )
                              : null,
                          value: !session.rejected.contains(i),
                          onChanged: _busy || _dirty
                              ? null
                              : (v) => _reject(i, !v!),
                          secondary: IconButton(
                            icon: Icon(
                              _trial == i
                                  ? Icons.visibility
                                  : Icons.visibility_outlined,
                            ),
                            onPressed: () => setState(() {
                              _trial = i;
                              _mode = 'epochs';
                            }),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        Card(
          child: ExpansionTile(
            title: const Text('3. Save & ERP Analysis'),
            subtitle: const Text('Export accepted epochs or open full ERP suite'),
            childrenPadding: const EdgeInsets.all(10),
            children: [
              if (session != null) ...[
                for (final c in session.conditions)
                  Text('$c: n = ${session.counts[c]}'),
              ],
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: session == null || _busy || _dirty
                    ? null
                    : _openMeasurements,
                icon: const Icon(Icons.analytics_outlined),
                label: const Text('Open ERP Analysis & Measurements'),
              ),
              const SizedBox(height: 6),
              OutlinedButton.icon(
                onPressed: session == null || _busy || _dirty
                    ? null
                    : () => _save(),
                icon: const Icon(Icons.save_outlined),
                label: const Text('Save accepted epochs…'),
              ),
              if (widget.config.erpEpochFirst)
                TextButton(
                  onPressed: session == null || _busy || _dirty
                      ? null
                      : () async {
                          await _save();
                          if (_savedReviewed != null && mounted)
                            widget.onUseReviewed(_savedReviewed!);
                        },
                  child: const Text('Use reviewed epochs for cleaning'),
                ),
            ],
          ),
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_dirty)
          const Text(
            'Displayed trials and averages belong to the previous protocol.',
            style: TextStyle(color: Colors.orange),
          ),
        Text(_status, style: const TextStyle(fontSize: 12)),
      ],
    );
    return Column(
      children: [
        _buildRecordingSwitcherBar(input),
        Expanded(
          child: Row(
            children: [
              SizedBox(
                width: 340,
                child: AbsorbPointer(absorbing: _busy, child: sidebar),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: session == null
                    ? Center(
                        child: Text(
                          _busy
                              ? 'Preparing trials…'
                              : 'Choose an ERP-CORE preset or define event groups, then create a trial preview.',
                        ),
                      )
                    : Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            child: Wrap(
                              spacing: 10,
                              runSpacing: 6,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                SegmentedButton<String>(
                                  segments: const [
                                    ButtonSegment(
                                      value: 'epochs',
                                      icon: Icon(Icons.view_list, size: 16),
                                      label: Text('Trial Review & ERPimage'),
                                    ),
                                    ButtonSegment(
                                      value: 'measurements',
                                      icon: Icon(Icons.analytics_outlined, size: 16),
                                      label: Text('ERP Analysis & Measurements'),
                                    ),
                                  ],
                                  selected: {_mode},
                                  onSelectionChanged: (v) {
                                    if (v.first == 'measurements') {
                                      _openMeasurements();
                                    } else {
                                      setState(() => _mode = v.first);
                                    }
                                  },
                                ),
                                SegmentedButton<String>(
                                  segments: const [
                                    ButtonSegment(
                                      value: 'trial',
                                      label: Text('Single Trial'),
                                    ),
                                    ButtonSegment(
                                      value: 'erpimage',
                                      label: Text('ERPimage'),
                                    ),
                                  ],
                                  selected: {_trialSubView},
                                  onSelectionChanged: (v) =>
                                      setState(() => _trialSubView = v.first),
                                ),
                                if (_trialSubView == 'trial') ...[
                                  IconButton(
                                    onPressed: filtered.indexOf(_trial) > 0
                                        ? () => setState(
                                            () => _trial =
                                                filtered[filtered.indexOf(_trial) - 1],
                                          )
                                        : null,
                                    icon: const Icon(Icons.chevron_left),
                                  ),
                                  Text(
                                    'Trial ${_trial + 1} / ${session.epochs.epochCount} · ${session.condition(_trial)}',
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                  IconButton(
                                    onPressed:
                                        filtered.indexOf(_trial) < filtered.length - 1
                                        ? () => setState(
                                            () => _trial =
                                                filtered[filtered.indexOf(_trial) + 1],
                                          )
                                        : null,
                                    icon: const Icon(Icons.chevron_right),
                                  ),
                                  FilledButton.tonal(
                                    onPressed: _dirty || _busy
                                        ? null
                                        : () => _reject(
                                            _trial,
                                            !session.rejected.contains(_trial),
                                          ),
                                    child: Text(
                                      session.rejected.contains(_trial)
                                          ? 'Reinstate trial'
                                          : 'Exclude trial',
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                            child: Wrap(
                              spacing: 12,
                              runSpacing: 6,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                SizedBox(
                                  width: 170,
                                  child: DropdownButtonFormField<int>(
                                    value: _channel,
                                    isDense: true,
                                    decoration: const InputDecoration(
                                      labelText: 'ERP channel',
                                      isDense: true,
                                    ),
                                    items: [
                                      for (var c = 0; c < input.labels.length; c++)
                                        DropdownMenuItem(
                                          value: c,
                                          child: Text(input.labels[c]),
                                        ),
                                    ],
                                    onChanged: (v) => setState(() => _channel = v!),
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Select channel from Topoplot',
                                  icon: const Icon(Icons.radar, size: 18),
                                  onPressed: () {
                                    showDialog<void>(
                                      context: context,
                                      builder: (ctx) => AlertDialog(
                                        title: const Text('Select ERP Channel'),
                                        content: TopoChannelSelector(
                                          availableChannels: input.labels,
                                          selectedChannels: {input.labels[_channel]},
                                          multiSelect: false,
                                          size: 260,
                                          onSelectChannel: (ch) {
                                            final idx = input.labels.indexWhere(
                                              (l) => l.toUpperCase() == ch.toUpperCase(),
                                            );
                                            if (idx >= 0) {
                                              setState(() => _channel = idx);
                                            }
                                            Navigator.pop(ctx);
                                          },
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () => Navigator.pop(ctx),
                                            child: const Text('Close'),
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                                const Text('Baseline (ms):', style: TextStyle(fontSize: 11, color: Colors.white70)),
                                SizedBox(
                                  width: 62,
                                  child: TextField(
                                    controller: _baseStartCtrl,
                                    decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 6)),
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ),
                                const Text('to', style: TextStyle(fontSize: 11, color: Colors.white70)),
                                SizedBox(
                                  width: 62,
                                  child: TextField(
                                    controller: _baseEndCtrl,
                                    decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 6)),
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ),
                                OutlinedButton(
                                  onPressed: _busy ? null : _applyInteractiveBaseline,
                                  child: const Text('Apply baseline', style: TextStyle(fontSize: 11)),
                                ),
                              ],
                            ),
                          ),
                          Expanded(
                            flex: 3,
                            child: _trialSubView == 'erpimage'
                                ? ErpImagePanel(
                                    session: session,
                                    channelIndex: _channel,
                                    trialIndices: filtered,
                                    onToggleReject: _reject,
                                    onInspectTrial: (idx) => setState(() {
                                      _trial = idx;
                                      _trialSubView = 'trial';
                                    }),
                                  )
                                : EegViewer(
                                    key: ValueKey(
                                      'erp-trial-$_trial-${identityHashCode(session)}',
                                    ),
                                    recording: session.trial(_trial),
                                    externalEpochNavigation: true,
                                    selection: const ViewerSelection.empty(),
                                    onSelectionChanged: (_) {},
                                    autoscaleByDefault: true,
                                  ),
                          ),
                          Container(
                            height: 200,
                            margin: const EdgeInsets.fromLTRB(12, 4, 12, 10),
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: const Color(0xFF0F172A),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.white12),
                            ),
                            child: Column(
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      'Live ERP Preview (${input.labels[_channel]})',
                                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                                    ),
                                    const SizedBox(width: 14),
                                    for (var i = 0; i < session.conditions.length; i++)
                                      Padding(
                                        padding: const EdgeInsets.only(right: 12),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Container(
                                              width: 12,
                                              height: 3,
                                              color: _erpCondColors[i % _erpCondColors.length],
                                            ),
                                            const SizedBox(width: 4),
                                            Text(
                                              '${session.conditions[i]} (n=${session.counts[session.conditions[i]]})',
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: _erpCondColors[i % _erpCondColors.length],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    if (session.conditions.length >= 2)
                                      const Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          SizedBox(
                                            width: 12,
                                            height: 3,
                                            child: ColoredBox(color: Colors.white70),
                                          ),
                                          SizedBox(width: 4),
                                          Text(
                                            'Difference (B − A)',
                                            style: TextStyle(fontSize: 11, color: Colors.white70),
                                          ),
                                        ],
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Expanded(
                                  child: CustomPaint(
                                    painter: _AveragePainter(
                                      session,
                                      _channel,
                                      session.revision,
                                    ),
                                    child: const SizedBox.expand(),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _AveragePainter extends CustomPainter {
  _AveragePainter(this.session, this.channel, this.revision);
  final InteractiveErpSession session;
  final int channel, revision;
  @override
  void paint(Canvas canvas, Size size) {
    final box = Rect.fromLTRB(
      60,
      20,
      math.max(80, size.width - 15),
      math.max(60, size.height - 45),
    );
    final means = <Float64List?>[
      for (final c in session.conditions) session.mean(c, channel),
    ];
    final maxV = session.displayLimit(channel);
    final start = session.epochs.epochTmin ?? 0;
    final duration = (session.points - 1) / session.epochs.sampleRate;
    void text(String value, Offset at) {
      final p = TextPainter(
        text: TextSpan(
          text: value,
          style: const TextStyle(
            color: Colors.grey,
            fontSize: 12,
            fontFamily: 'DejaVuSans',
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      p.paint(canvas, at);
    }

    final axis = Paint()
      ..color = Colors.grey
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(box.left, box.center.dy),
      Offset(box.right, box.center.dy),
      axis,
    );
    if (start <= 0 && start + duration >= 0) {
      final x = box.left + box.width * (-start) / duration;
      canvas.drawLine(Offset(x, box.top), Offset(x, box.bottom), axis);
    }
    canvas.drawRect(
      box,
      Paint()
        ..color = Colors.grey
        ..style = PaintingStyle.stroke,
    );
    for (var i = 0; i < means.length; i++) {
      final mean = means[i];
      if (mean == null) continue;
      final path = Path();
      for (var j = 0; j < mean.length; j++) {
        final x = box.left + box.width * j / math.max(1, mean.length - 1),
            y = box.center.dy - mean[j] / maxV * box.height * .45;
        if (j == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = _erpCondColors[i % _erpCondColors.length]
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
    if (means.length >= 2 && means[0] != null && means[1] != null) {
      final a = means[0]!;
      final b = means[1]!;
      final diffPath = Path();
      for (var j = 0; j < math.min(a.length, b.length); j++) {
        final x = box.left + box.width * j / math.max(1, a.length - 1);
        final y = box.center.dy - (b[j] - a[j]) / maxV * box.height * .45;
        if (j == 0) {
          diffPath.moveTo(x, y);
        } else {
          diffPath.lineTo(x, y);
        }
      }
      canvas.drawPath(
        diffPath,
        Paint()
          ..color = Colors.white70
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6,
      );
    }
    text('${maxV.toStringAsFixed(1)} µV', Offset(0, box.top));
    text('0', Offset(30, box.center.dy));
    text('-${maxV.toStringAsFixed(1)} µV', Offset(0, box.bottom - 14));
    for (var i = 0; i <= 4; i++) {
      text(
        '${((start + duration * i / 4) * 1000).round()} ms',
        Offset(box.left + box.width * i / 4 - 15, box.bottom + 12),
      );
    }
    if (session.acceptedCount == 0)
      text(
        'No included trials. Reinstate a trial to restore the average.',
        box.center - const Offset(160, 0),
      );
  }

  @override
  bool shouldRepaint(covariant _AveragePainter old) =>
      old.session != session ||
      old.channel != channel ||
      old.revision != revision;
}
