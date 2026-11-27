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
import 'workbench_figures.dart';

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
  String _preset = 'Custom', _mode = 'epochs', _trialSubView = 'erpimage', _status = '';
  String? _butterflySource; // null defaults to the first condition average
  String _epochPreviewMode = 'distributed'; // 'distributed' | 'butterfly'
  int _activeStep = 1; // 1 = Protocol & Epoching, 2 = Review & Multi-Stream, 3 = Measurements & Export
  int _workbenchTab = 0; // 0=ERP & Topo, 1=ERPimage, 2=ERSP & ITC, 3=rERP & ML, 4=Measurements & Export
  double _winStartMs = 300.0;
  double _winEndMs = 600.0;
  bool _busy = false, _dirty = false, _closing = false;
  int _trial = 0, _channel = 0;
  String? _condition;
  final Set<int> _disabledProtocolEpochs = {};
  final Set<String> _includedChannels = {};
  late final TextEditingController _baseStartCtrl = TextEditingController(text: '-200');
  late final TextEditingController _baseEndCtrl = TextEditingController(text: '0');
  late final TextEditingController _win0Ctrl = TextEditingController(text: '300');
  late final TextEditingController _win1Ctrl = TextEditingController(text: '600');

  void _updateMeasurementWindow(double startMs, double endMs) {
    final lo = math.min(startMs, endMs);
    final hi = math.max(startMs, endMs);
    setState(() {
      _winStartMs = lo;
      _winEndMs = hi;
      _win0Ctrl.text = '${lo.round()}';
      _win1Ctrl.text = '${hi.round()}';
    });
  }
  File? _reviewFile;
  Timer? _persistTimer;
  EegRecording? _savedReviewed;
  int _savedRevision = -1;
  EegRecording? _measurementRecording;
  Map<String, dynamic>? _measurementInspection;
  String? _measurementOutput;
  int _measurementRevision = -1;

  Future<void> _openMeasurements({int targetTab = 4, int? targetStep}) async {
    final session = _session;
    if (session == null || _dirty || _busy || session.acceptedCount == 0)
      return;
    if (_measurementRecording != null &&
        _measurementRevision == session.revision) {
      setState(() {
        _mode = 'measurements';
        _workbenchTab = targetTab;
        if (targetStep != null) _activeStep = targetStep;
      });
      return;
    }
    setState(() {
      _busy = true;
      _status = 'Preparing accepted trials for analysis & measurements…';
    });
    try {
      final identity = sha256
          .convert(utf8.encode(jsonEncode(session.rejected.toList()..sort())))
          .toString()
          .substring(0, 16);
      final dir = Directory('${_reviewFile!.parent.path}/.erp_m/$identity');
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
        _workbenchTab = targetTab;
        if (targetStep != null) _activeStep = targetStep;
        _status = 'All streams use the current ${session.acceptedCount} accepted trials & ${_winStartMs.round()}–${_winEndMs.round()} ms window.';
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
    _win0Ctrl.dispose();
    _win1Ctrl.dispose();
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
      for (final idx in _disabledProtocolEpochs) {
        if (idx >= 0 && idx < epochs.epochCount) {
          session.setRejected(idx, true);
        }
      }
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
        _activeStep = 2;
        _includedChannels
          ..clear()
          ..addAll(epochs.labels);
        _savedReviewed = null;
        _savedRevision = -1;
        _measurementRecording = null;
        _measurementRevision = -1;
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

  List<EpochShadeSpec> _buildProtocolEpochShades(EegRecording input) {
    final spec = widget.config.stimEpochSpec;
    if (spec == null || input.isEpoched) return const [];
    final events = spec.selectEvents(input.markers);
    final groupNames = spec.markerGroups.keys.toList();
    return [
      for (var i = 0; i < events.length; i++)
        () {
          final (tSec, groupLabel) = events[i];
          final gIdx = math.max(0, groupNames.indexOf(groupLabel));
          final color = _erpCondColors[gIdx % _erpCondColors.length];
          return EpochShadeSpec(
            index: i,
            startSeconds: tSec + spec.tmin,
            endSeconds: tSec + spec.tmax,
            label: groupLabel,
            color: color,
            enabled: !_disabledProtocolEpochs.contains(i),
          );
        }(),
    ];
  }

  Map<String, List<double>> _buildEpochButterflyWaves(
    InteractiveErpSession session,
    int trialIdx,
  ) {
    final activeCh = _includedChannels.isEmpty
        ? session.epochs.labels.toSet()
        : _includedChannels;
    final pts = session.points;
    return {
      for (var c = 0; c < session.epochs.labels.length; c++)
        if (activeCh.contains(session.epochs.labels[c]))
          session.epochs.labels[c]: [
            for (var s = 0; s < pts; s++) session.trialSample(trialIdx, c, s),
          ],
    };
  }

  Widget _buildLiveAverage(InteractiveErpSession session, EegRecording input, {bool imageAligned = false}) => Container(
                                        height: 250,
                                        margin: imageAligned ? EdgeInsets.zero : const EdgeInsets.fromLTRB(12, 2, 12, 6),
                                        padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFFF0F4F8),
                                          borderRadius: BorderRadius.circular(8),
                                          border: Border.all(color: const Color(0xFFCBD5E1)),
                                        ),
                                        child: Column(
                                          children: [
                                            Wrap(
                                              spacing: 8, runSpacing: 4,
                                              children: [
                                                Text(
                                                  'Live ERP Preview (${input.labels[_channel]}) · negative up',
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
                                                        child: ColoredBox(color: Color(0xFF475569)),
                                                      ),
                                                      SizedBox(width: 4),
                                                      Text(
                                                        'Difference (B − A)',
                                                        style: TextStyle(fontSize: 11, color: Color(0xFF475569)),
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
                                                  imageAligned: imageAligned,
                                                  windowStartMs: _winStartMs,
                                                  windowEndMs: _winEndMs,
                                                ),
                                                child: const SizedBox.expand(),
                                              ),
                                            ),
                                          ],
                                        ),
                                      );

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

  Future<void> _showChannelInclusionDialog(InteractiveErpSession session) async {
    final labels = session.epochs.labels;
    final current = _includedChannels.isEmpty
        ? labels.toSet()
        : Set<String>.from(_includedChannels);
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: const Text('Include / Remove Channels'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TopoChannelSelector(
                    availableChannels: labels,
                    selectedChannels: current,
                    multiSelect: true,
                    size: 240,
                    onSelectChannel: (ch) {
                      setDlg(() {
                        if (current.contains(ch)) {
                          if (current.length > 1) current.remove(ch);
                        } else {
                          current.add(ch);
                        }
                      });
                    },
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final ch in labels)
                        FilterChip(
                          label: Text(ch, style: const TextStyle(fontSize: 11)),
                          selected: current.contains(ch),
                          onSelected: (v) {
                            setDlg(() {
                              if (v) {
                                current.add(ch);
                              } else if (current.length > 1) {
                                current.remove(ch);
                              }
                            });
                          },
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => setDlg(() => current..clear()..addAll(labels)),
              child: const Text('Select all'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                setState(() {
                  _includedChannels
                    ..clear()
                    ..addAll(current);
                });
                Navigator.pop(ctx);
              },
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
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
        color: Color(0xFFF0F4F8),
        border: Border(bottom: BorderSide(color: Color(0xFFCBD5E1))),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Text(
            'Active Recording:',
            style: TextStyle(fontSize: 11, color: Color(0xFF1E293B), fontWeight: FontWeight.w600),
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
                    ? const Color(0xFF1E293B)
                    : (rec.path.contains('_clean')
                          ? const Color(0xFF16A34A)
                          : const Color(0xFF475569)),
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
    final String? workbenchResultPath = _measurementOutput != null
        ? '$_measurementOutput/erp_results.ccserp'
        : null;
    var validWorkbenchResult = false;
    if (workbenchResultPath != null) {
      try {
        final result = jsonDecode(File(workbenchResultPath).readAsStringSync());
        validWorkbenchResult =
            result is Map &&
            result['files'] is List &&
            (result['files'] as List).isNotEmpty;
      } catch (_) {
        /* unfinished or missing results are computed again */
      }
    }
    Widget stepCard({
      required int step,
      required String title,
      required String subtitle,
      required bool done,
      required String actionLabel,
      required VoidCallback? onAction,
      Widget? body,
    }) {
      final active = _activeStep == step;
      return Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF3B6EA5).withValues(alpha: 0.12) : const Color(0xFFFFFFFF),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: active ? const Color(0xFF3B6EA5) : const Color(0xFFCBD5E1),
            width: active ? 1.4 : 1.0,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => setState(() => _activeStep = step),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    Container(
                      width: 22,
                      height: 22,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: done
                            ? const Color(0xFF16A34A).withValues(alpha: 0.25)
                            : (active ? const Color(0xFF3B6EA5).withValues(alpha: 0.15) : const Color(0xFFE2E8F0)),
                        border: Border.all(
                          color: done
                              ? const Color(0xFF22C55E)
                              : (active ? const Color(0xFF3B6EA5) : const Color(0xFF94A3B8)),
                        ),
                      ),
                      child: done
                          ? const Icon(Icons.check, size: 13, color: Color(0xFF4ADE80))
                          : Text('$step', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                          Text(
                            subtitle,
                            style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    TextButton(
                      onPressed: onAction,
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(actionLabel, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
              ),
            ),
            if (active && body != null) ...[
              const Divider(height: 1, color: Color(0xFFCBD5E1)),
              Padding(padding: const EdgeInsets.all(10), child: body),
            ],
          ],
        ),
      );
    }

    final shades = _buildProtocolEpochShades(input);
    final enabledShadeCount = shades.where((s) => s.enabled).length;

    final sidebar = ListView(
      padding: const EdgeInsets.all(12),
      children: [
        const Text(
          'Epochs & ERP',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Text(
          input.path.split(RegExp(r'[/\\]')).last,
          style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _busy ? null : widget.onOpenRecording,
          icon: const Icon(Icons.folder_open),
          label: const Text('Open saved epochs / another EEG…'),
        ),
        Text(input.isEpoched
          ? '${input.epochCount} saved trials detected. Trial boundaries and condition labels are restored automatically.'
          : 'Continuous EEG · ${input.markers.length} events. Create trials below, or open a saved epoch file. Cleaned EEG alone does not contain saved trials.',
          style: const TextStyle(fontSize: 11, color: Color(0xFF475569))),
        const SizedBox(height: 12),
        stepCard(
          step: 1,
          title: 'Define ERP Protocol',
          subtitle: input.isEpoched
              ? '${input.epochCount} saved epochs'
              : '$_preset · $enabledShadeCount/${shades.length} epochs enabled',
          done: session != null && !_dirty,
          actionLabel: session == null ? 'Create' : 'Update',
          onAction: _busy ? null : _createEpochs,
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!input.isEpoched) ...[
                DropdownButtonFormField<String>(
                  initialValue: _preset,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'ERP-CORE / custom protocol',
                    isDense: true,
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
                          _disabledProtocolEpochs.clear();
                          _dirty = session != null;
                        }),
                ),
                const SizedBox(height: 6),
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
                if (shades.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'Click shaded epochs on the EEG plot to enable/disable ($enabledShadeCount/${shades.length} active).',
                      style: const TextStyle(fontSize: 11, color: const Color(0xFF0284C7)),
                    ),
                  ),
              ] else
                Text(
                  '${input.epochCount} saved trials. Their groups and baseline are preserved.',
                  style: const TextStyle(fontSize: 12),
                ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _busy ? null : _createEpochs,
                icon: const Icon(Icons.content_cut, size: 16),
                label: Text(
                  session == null ? 'Create Epochs & Review' : 'Update Epochs',
                ),
              ),
            ],
          ),
        ),
        stepCard(
          step: 2,
          title: 'Epoch Review & Analysis',
          subtitle: session == null
              ? 'Create epochs in Step 1 first'
              : '${session.acceptedCount} included · ${session.rejected.length} excluded',
          done: session != null && session.acceptedCount > 0,
          actionLabel: 'ERP & Topo',
          onAction: session == null || _busy || _dirty
              ? null
              : () => _openMeasurements(targetTab: 0, targetStep: 2),
          body: session == null
              ? const Text('Create epochs in Step 1 to begin reviewing.', style: TextStyle(fontSize: 12, color: Color(0xFF64748B)))
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    DropdownButtonFormField<String>(
                      value: _condition ?? '*',
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Filter condition',
                        isDense: true,
                      ),
                      items: [
                        const DropdownMenuItem(value: '*', child: Text('All conditions')),
                        for (final c in session.conditions)
                          DropdownMenuItem(
                            value: c,
                            child: Text('$c (${session.counts[c]} included)'),
                          ),
                      ],
                      onChanged: (v) => setState(() => _condition = v == '*' ? null : v),
                    ),
                    const SizedBox(height: 6),
                    OutlinedButton.icon(
                      onPressed: () => _showChannelInclusionDialog(session),
                      icon: const Icon(Icons.radar, size: 15),
                      label: Text(
                        'Channels (${_includedChannels.isEmpty ? session.epochs.labels.length : _includedChannels.length}/${session.epochs.labels.length})',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    const SizedBox(height: 6),
                    SizedBox(
                      height: 200,
                      child: ListView(
                        children: [
                          for (final i in filtered)
                            CheckboxListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text('Trial ${i + 1} · ${session.condition(i)}', style: const TextStyle(fontSize: 12)),
                              subtitle: i < session.epochs.epochStartSeconds.length
                                  ? Text('Source ${session.epochs.epochStartSeconds[i].toStringAsFixed(2)} s', style: const TextStyle(fontSize: 10))
                                  : null,
                              value: !session.rejected.contains(i),
                              onChanged: _busy || _dirty ? null : (v) => _reject(i, !v!),
                              secondary: IconButton(
                                icon: Icon(
                                  _trial == i ? Icons.visibility : Icons.visibility_outlined,
                                  size: 16,
                                ),
                                onPressed: () => setState(() {
                                  _trial = i;
                                  _activeStep = 2;
                                }),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 6),
                    FilledButton.icon(
                      onPressed: _busy || _dirty
                          ? null
                          : () => _openMeasurements(targetTab: 0, targetStep: 2),
                      icon: const Icon(Icons.analytics_outlined, size: 16),
                      label: const Text('Open Analysis Streams (ERP, ERSP, rERP, ML)'),
                    ),
                  ],
                ),
        ),
        stepCard(
          step: 3,
          title: 'Measurements, Plots & Save',
          subtitle: 'Window ${_winStartMs.round()}–${_winEndMs.round()} ms · tables & export',
          done: _savedReviewed != null,
          actionLabel: 'Save',
          onAction: session == null || _busy || _dirty ? null : () => _save(),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (session != null)
                for (final c in session.conditions)
                  Text('$c: n = ${session.counts[c]}', style: const TextStyle(fontSize: 12)),
              const SizedBox(height: 8),
              const Text(
                'Measurement window (ms)',
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _win0Ctrl,
                      decoration: const InputDecoration(
                        labelText: 'Start',
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                      ),
                      style: const TextStyle(fontSize: 12),
                      onSubmitted: (_) {
                        final a = double.tryParse(_win0Ctrl.text.trim());
                        final b = double.tryParse(_win1Ctrl.text.trim());
                        if (a != null && b != null) _updateMeasurementWindow(a, b);
                      },
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6),
                    child: Text('–', style: TextStyle(fontSize: 12)),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _win1Ctrl,
                      decoration: const InputDecoration(
                        labelText: 'End',
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                      ),
                      style: const TextStyle(fontSize: 12),
                      onSubmitted: (_) {
                        final a = double.tryParse(_win0Ctrl.text.trim());
                        final b = double.tryParse(_win1Ctrl.text.trim());
                        if (a != null && b != null) _updateMeasurementWindow(a, b);
                      },
                    ),
                  ),
                  const SizedBox(width: 6),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    ),
                    onPressed: () {
                      final a = double.tryParse(_win0Ctrl.text.trim());
                      final b = double.tryParse(_win1Ctrl.text.trim());
                      if (a != null && b != null) _updateMeasurementWindow(a, b);
                    },
                    child: const Text('Sync', style: TextStyle(fontSize: 11)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: session == null || _busy || _dirty
                    ? null
                    : () => _openMeasurements(targetTab: 4, targetStep: 3),
                icon: const Icon(Icons.table_chart_outlined, size: 16),
                label: const Text('Measurements & Result Plots'),
              ),
              const SizedBox(height: 6),
              OutlinedButton.icon(
                onPressed: session == null || _busy || _dirty ? null : () => _save(),
                icon: const Icon(Icons.save_outlined, size: 16),
                label: const Text('Save accepted epochs…'),
              ),
              if (widget.config.erpEpochFirst)
                TextButton(
                  onPressed: session == null || _busy || _dirty
                      ? null
                      : () async {
                          await _save();
                          if (_savedReviewed != null && mounted) {
                            widget.onUseReviewed(_savedReviewed!);
                          }
                        },
                  child: const Text('Use reviewed epochs for cleaning'),
                ),
            ],
          ),
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_dirty)
          const Text(
            'Protocol changed — click Update Epochs to apply.',
            style: TextStyle(color: Colors.orange, fontSize: 12),
          ),
        Text(_status, style: const TextStyle(fontSize: 12, color: Color(0xFF475569))),
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
                child: (_activeStep == 1 && !input.isEpoched) || session == null
                    ? (!input.isEpoched
                          ? Column(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                  decoration: const BoxDecoration(
                                    color: Color(0xFFF0F4F8),
                                    border: Border(bottom: BorderSide(color: Color(0xFFCBD5E1))),
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(Icons.layers, size: 16, color: const Color(0xFF0284C7)),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          'Protocol Epoch Preview: $enabledShadeCount/${shades.length} epochs enabled · Click any shaded epoch on the EEG plot to enable/disable it',
                                          style: const TextStyle(fontSize: 12, color: Color(0xFF475569)),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      if (_disabledProtocolEpochs.isNotEmpty)
                                        TextButton(
                                          onPressed: () => setState(() {
                                            _disabledProtocolEpochs.clear();
                                            _dirty = session != null;
                                          }),
                                          child: const Text('Enable all', style: TextStyle(fontSize: 11)),
                                        ),
                                    ],
                                  ),
                                ),
                                Expanded(
                                  child: EegViewer(
                                    key: ValueKey('protocol-preview-${input.path}'),
                                    recording: input,
                                    selection: const ViewerSelection.empty(),
                                    onSelectionChanged: (_) {},
                                    autoscaleByDefault: true,
                                    epochShades: shades,
                                    onToggleEpochShade: (idx) {
                                      setState(() {
                                        if (_disabledProtocolEpochs.contains(idx)) {
                                          _disabledProtocolEpochs.remove(idx);
                                        } else {
                                          _disabledProtocolEpochs.add(idx);
                                        }
                                        if (session != null && idx < session.epochs.epochCount) {
                                          _reject(idx, _disabledProtocolEpochs.contains(idx));
                                        }
                                      });
                                    },
                                  ),
                                ),
                              ],
                            )
                          : Center(
                              child: Text(
                                _busy
                                    ? 'Preparing trials…'
                                    : 'Click Create Epochs & Review in Step 1 to begin.',
                              ),
                            ))
                    : Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                            child: Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                SegmentedButton<String>(
                                  style: SegmentedButton.styleFrom(
                                    visualDensity: VisualDensity.compact,
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                                    textStyle: const TextStyle(fontSize: 12),
                                  ),
                                  segments: const [
                                    ButtonSegment(value: 'erpimage', label: Text('ERPimage')),
                                    ButtonSegment(value: 'trial', label: Text('Distributed')),
                                    ButtonSegment(value: 'butterfly', label: Text('Butterfly')),
                                    ButtonSegment(value: 'wb_0', label: Text('ERP & Topo')),
                                    ButtonSegment(value: 'wb_2', label: Text('ERSP & ITC')),
                                    ButtonSegment(value: 'wb_3', label: Text('rERP & ML')),
                                    ButtonSegment(value: 'wb_4', label: Text('Measurements')),
                                  ],
                                  selected: {
                                    _mode == 'measurements'
                                        ? 'wb_$_workbenchTab'
                                        : (_trialSubView == 'trial' && _epochPreviewMode == 'butterfly'
                                            ? 'butterfly'
                                            : _trialSubView),
                                  },
                                  onSelectionChanged: (v) {
                                    final sel = v.first;
                                    if (sel.startsWith('wb_')) {
                                      final tab = int.parse(sel.substring(3));
                                      _openMeasurements(
                                        targetTab: tab,
                                        targetStep: tab == 4 ? 3 : 2,
                                      );
                                    } else {
                                      setState(() {
                                        _mode = 'epochs';
                                        _activeStep = 2;
                                        if (sel == 'butterfly') {
                                          _trialSubView = 'trial';
                                          _epochPreviewMode = 'butterfly';
                                        } else if (sel == 'trial') {
                                          _trialSubView = 'trial';
                                          _epochPreviewMode = 'distributed';
                                        } else {
                                          _trialSubView = 'erpimage';
                                        }
                                      });
                                    }
                                  },
                                ),
                                if (_mode != 'measurements') ...[
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
                          if (_mode == 'measurements' && _measurementRecording != null)
                            Expanded(
                              child: ErpWorkbenchView(
                                key: ValueKey('linked-measurements-$_measurementRevision'),
                                activeRecording: _measurementRecording,
                                config: widget.config,
                                batchMode: false,
                                linkedReview: true,
                                embeddedInEpochWorkspace: true,
                                controlledTabIndex: _workbenchTab,
                                onTabChanged: (t) => setState(() {
                                  _workbenchTab = t;
                                  _activeStep = t == 4 ? 3 : 2;
                                }),
                                externalMeasurementWindow: (_winStartMs, _winEndMs),
                                onMeasurementWindowChanged: (w) =>
                                    _updateMeasurementWindow(w.$1, w.$2),
                                externalRoi: input.labels[_channel],
                                onRoiChanged: (ch) {
                                  final idx = input.labels.indexWhere(
                                    (l) => l.toUpperCase() == ch.toUpperCase(),
                                  );
                                  if (idx >= 0 && idx != _channel) {
                                    setState(() => _channel = idx);
                                  }
                                },
                                linkedOutputDirectory: _measurementOutput,
                                initialInspection: _measurementInspection,
                                initialResultPath: validWorkbenchResult ? workbenchResultPath : null,
                                onEditEpochs: () => setState(() {
                                  _mode = 'epochs';
                                  _activeStep = 2;
                                }),
                              ),
                            )
                          else ...[
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                            child: Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                SizedBox(
                                  width: 130,
                                  child: DropdownButtonFormField<int>(
                                    value: _channel,
                                    isDense: true,
                                    decoration: const InputDecoration(
                                      labelText: 'ERP channel',
                                      isDense: true,
                                      contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
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
                                if (_trialSubView == 'trial' && _epochPreviewMode == 'butterfly')
                                  DropdownButton<String>(
                                    value: _butterflySource == 'trial' ? 'trial'
                                        : (session.conditions.contains(_butterflySource) ? _butterflySource : session.conditions.first),
                                    items: [
                                      for (final c in session.conditions) DropdownMenuItem(value: c, child: Text('Average: $c (n=${session.counts[c]})')),
                                      const DropdownMenuItem(value: 'trial', child: Text('Selected single trial')),
                                    ],
                                    onChanged: (value) => setState(() => _butterflySource = value),
                                  ),
                                const Text('Baseline (ms):', style: TextStyle(fontSize: 11, color: Color(0xFF475569))),
                                SizedBox(
                                  width: 62,
                                  child: TextField(
                                    controller: _baseStartCtrl,
                                    decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 6)),
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ),
                                const Text('to', style: TextStyle(fontSize: 11, color: Color(0xFF475569))),
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
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(
                                  child: Column(
                                    children: [
                                      Expanded(
                                        flex: 5,
                                        child: _trialSubView == 'erpimage'
                                            ? ErpImagePanel(
                                                session: session,
                                                average: _buildLiveAverage(session, input, imageAligned: true),
                                                channelIndex: _channel,
                                                trialIndices: filtered,
                                                windowStartMs: _winStartMs,
                                                windowEndMs: _winEndMs,
                                                activeTrialIndex: _trial,
                                                onTopoWindowChanged: (w) =>
                                                    _updateMeasurementWindow(w.$1, w.$2),
                                                onToggleReject: _reject,
                                                onInspectTrial: (idx) => setState(() {
                                                  _trial = idx;
                                                  _trialSubView = 'trial';
                                                }),
                                              )
                                            : (_epochPreviewMode == 'butterfly'
                                                  ? Container(
                                                      margin: const EdgeInsets.fromLTRB(12, 2, 12, 2),
                                                      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
                                                      decoration: BoxDecoration(
                                                        color: Colors.white,
                                                        borderRadius: BorderRadius.circular(8),
                                                        border: Border.all(color: const Color(0xFFCBD5E1)),
                                                      ),
                                                      child: CustomPaint(
                                                        painter: ErpButterflyPainter(
                                                          title: _butterflySource == 'trial' ? 'Single-trial butterfly' : 'ERP average butterfly · ${session.conditions.contains(_butterflySource) ? _butterflySource : session.conditions.first}',
                                                          times: [
                                                            for (var s = 0; s < session.points; s++)
                                                              (session.epochs.epochTmin ?? -0.2) +
                                                                  s / session.epochs.sampleRate,
                                                          ],
                                                          channelWaves: _butterflySource == 'trial'
                                                              ? _buildEpochButterflyWaves(session, _trial)
                                                              : session.averageChannelWaves(
                                                                  _butterflySource != null && session.conditions.contains(_butterflySource)
                                                                      ? _butterflySource! : session.conditions.first,
                                                                  includedChannels: _includedChannels,
                                                                ),
                                                          highlightedChannel: input.labels[_channel],
                                                          negativeUp: true,
                                                          windowSec: [_winStartMs / 1000.0, _winEndMs / 1000.0],
                                                        ),
                                                        child: const SizedBox.expand(),
                                                      ),
                                                    )
                                                  : EegViewer(
                                                      key: ValueKey(
                                                        'erp-trial-$_trial-${_includedChannels.length}-${identityHashCode(session)}',
                                                      ),
                                                      recording: session.trial(_trial),
                                                      externalEpochNavigation: true,
                                                      selection: ViewerSelection(
                                                        selectedChannels: (_includedChannels.isEmpty
                                                            ? session.epochs.labels
                                                            : _includedChannels.toList()),
                                                        acceptedIntervals: const [],
                                                        rejectedIntervals: const [],
                                                      ),
                                                      onSelectionChanged: (_) {},
                                                      autoscaleByDefault: true,
                                                    )),
                                      ),
                                      if (_trialSubView != 'erpimage') _buildLiveAverage(session, input),
                                    ],
                                  ),
                                ),
                                if (_trialSubView == 'trial' &&
                                    _epochPreviewMode == 'butterfly' &&
                                    input.labels.length >= 4) ...[
                                  Container(
                                    width: 215,
                                    margin: const EdgeInsets.fromLTRB(0, 2, 12, 6),
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFF0F4F8),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(color: const Color(0xFFCBD5E1)),
                                    ),
                                    child: Column(
                                      children: [
                                        Text(
                                          'Pick Channel: ${input.labels[_channel]}',
                                          style: const TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.bold,
                                            color: const Color(0xFF0284C7),
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Expanded(
                                          child: FittedBox(
                                            child: TopoChannelSelector(
                                              availableChannels: input.labels,
                                              selectedChannels: {input.labels[_channel]},
                                              multiSelect: false,
                                              size: 185,
                                              onSelectChannel: (ch) {
                                                final idx = input.labels.indexWhere(
                                                  (l) => l.toUpperCase() == ch.toUpperCase(),
                                                );
                                                if (idx >= 0) {
                                                  setState(() => _channel = idx);
                                                }
                                              },
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Builder(
                                          builder: (_) {
                                            final chName = input.labels[_channel];
                                            final activeSet = _includedChannels.isEmpty
                                                ? input.labels.toSet()
                                                : _includedChannels;
                                            final isIncluded = activeSet.contains(chName);
                                            return OutlinedButton.icon(
                                              style: OutlinedButton.styleFrom(
                                                visualDensity: VisualDensity.compact,
                                                foregroundColor: isIncluded
                                                    ? const Color(0xFFD97706)
                                                    : const Color(0xFF16A34A),
                                              ),
                                              onPressed: () {
                                                setState(() {
                                                  if (_includedChannels.isEmpty) {
                                                    _includedChannels.addAll(input.labels);
                                                  }
                                                  if (isIncluded && _includedChannels.length > 1) {
                                                    _includedChannels.remove(chName);
                                                  } else {
                                                    _includedChannels.add(chName);
                                                  }
                                                });
                                              },
                                              icon: Icon(
                                                isIncluded ? Icons.block : Icons.check_circle_outline,
                                                size: 14,
                                              ),
                                              label: Text(
                                                isIncluded ? 'Mark $chName Bad' : 'Restore $chName',
                                                style: const TextStyle(fontSize: 11),
                                              ),
                                            );
                                          },
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          ],
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
  _AveragePainter(
    this.session,
    this.channel,
    this.revision, {
    this.windowStartMs = 300.0,
    this.windowEndMs = 600.0,
    this.imageAligned = false,
  });
  final bool imageAligned;
  final InteractiveErpSession session;
  final int channel, revision;
  final double windowStartMs, windowEndMs;
  @override
  void paint(Canvas canvas, Size size) {
    final box = Rect.fromLTRB(
      imageAligned ? 46 : 60,
      20,
      math.max(80, size.width - (imageAligned ? 42 : 15)),
      math.max(60, size.height - 45),
    );
    final means = <Float64List?>[
      for (final c in session.conditions) session.mean(c, channel),
    ];
    var maxV = session.displayLimit(channel);
    for (final mean in means) {
      if (mean != null) for (final value in mean) { maxV = math.max(maxV, value.abs() * 1.1); }
    }
    if (means.length >= 2 && means[0] != null && means[1] != null) {
      for (var i = 0; i < math.min(means[0]!.length, means[1]!.length); i++) {
        maxV = math.max(maxV, (means[1]![i] - means[0]![i]).abs() * 1.1);
      }
    }
    final start = session.epochs.epochTmin ?? -0.2;
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
    if (duration > 0) {
      final x0 = (box.left + box.width * ((windowStartMs / 1000.0) - start) / duration)
          .clamp(box.left, box.right);
      final x1 = (box.left + box.width * ((windowEndMs / 1000.0) - start) / duration)
          .clamp(box.left, box.right);
      if (x1 > x0) {
        canvas.drawRect(
          Rect.fromLTRB(x0, box.top, x1, box.bottom),
          Paint()..color = const Color(0xFFF59E0B).withValues(alpha: 0.18),
        );
        final edgePaint = Paint()
          ..color = const Color(0xFFD97706).withValues(alpha: 0.85)
          ..strokeWidth = 1.2;
        canvas.drawLine(Offset(x0, box.top), Offset(x0, box.bottom), edgePaint);
        canvas.drawLine(Offset(x1, box.top), Offset(x1, box.bottom), edgePaint);
        text(
          '${windowStartMs.round()}–${windowEndMs.round()} ms',
          Offset((x0 + 4).clamp(box.left, math.max(box.left, box.right - 80)), box.top + 3),
        );
      }
    }
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
            y = box.center.dy + mean[j] / maxV * box.height * .5;
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
        final y = box.center.dy + (b[j] - a[j]) / maxV * box.height * .5;
        if (j == 0) {
          diffPath.moveTo(x, y);
        } else {
          diffPath.lineTo(x, y);
        }
      }
      canvas.drawPath(
        diffPath,
        Paint()
          ..color = const Color(0xFF475569)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6,
      );
    }
    text('-${maxV.toStringAsFixed(1)} µV', Offset(0, box.top));
    text('0', Offset(30, box.center.dy));
    text('${maxV.toStringAsFixed(1)} µV', Offset(0, box.bottom - 14));
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
      old.revision != revision ||
      old.windowStartMs != windowStartMs || old.windowEndMs != windowEndMs;
}
