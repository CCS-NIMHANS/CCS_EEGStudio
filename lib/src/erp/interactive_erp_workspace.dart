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
import 'erp_workbench_view.dart';
import 'interactive_erp_session.dart';
import 'stim_epoch_panel.dart';
import 'protocol_tools.dart';

/// One interactive path: protocol -> browse/review trials -> live averages.
/// Advanced statistics remain in the workbench and consume accepted trials.
class InteractiveErpWorkspace extends StatefulWidget {
  const InteractiveErpWorkspace({
    super.key,
    required this.recording,
    required this.config,
    required this.onOpenRecording,
    required this.onUseReviewed,
  });
  final EegRecording? recording;
  final AnalysisConfig config;
  final VoidCallback onOpenRecording;
  final ValueChanged<EegRecording> onUseReviewed;
  @override
  State<InteractiveErpWorkspace> createState() =>
      _InteractiveErpWorkspaceState();
}

class _InteractiveErpWorkspaceState extends State<InteractiveErpWorkspace> {
  InteractiveErpSession? _session;
  String _preset = 'Custom', _mode = 'epochs', _status = '';
  bool _busy = false, _dirty = false;
  int _trial = 0, _channel = 0;
  String? _condition;
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
    _persistTimer?.cancel();
    unawaited(_persist());
    super.dispose();
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

  Future<void> _persist() async {
    final file = _reviewFile, session = _session;
    if (file == null || session == null) return;
    final data = jsonEncode({
      'source': widget.recording?.path,
      'rejected': session.rejected.toList()..sort(),
    });
    try {
      await file.writeAsString(data);
    } catch (e) {
      if (mounted)
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
        await _persist();
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
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                TextButton.icon(
                  onPressed: () => setState(() => _mode = 'epochs'),
                  icon: const Icon(Icons.view_list),
                  label: const Text('Trial review'),
                ),
                TextButton.icon(
                  onPressed: () => setState(() => _mode = 'averages'),
                  icon: const Icon(Icons.show_chart),
                  label: const Text('Live averages'),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    'ERP measurements · ${session!.acceptedCount} accepted trials · conditions carried from review',
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
              TextButton(
                onPressed: session == null
                    ? null
                    : () => setState(() => _mode = 'epochs'),
                child: const Text('Show epochs'),
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
            title: const Text('3. Averaging & ERP review'),
            subtitle: const Text('Updates immediately when trials change'),
            onExpansionChanged: (open) {
              if (open) setState(() => _mode = 'averages');
            },
            childrenPadding: const EdgeInsets.all(10),
            children: [
              TextButton(
                onPressed: session == null
                    ? null
                    : () => setState(() => _mode = 'averages'),
                child: const Text('Show live averages'),
              ),
              if (session != null) ...[
                for (final c in session.conditions)
                  Text('$c: n = ${session.counts[c]}'),
              ],
              const SizedBox(height: 8),
              const Text(
                'Descriptive condition averages. Lateralized differences and statistical measurements are available under Measurements & models.',
              ),
              FilledButton.icon(
                onPressed: session == null || _busy || _dirty
                    ? null
                    : () => _save(),
                icon: const Icon(Icons.save_outlined),
                label: const Text('Save accepted epochs…'),
              ),
              TextButton(
                onPressed: session == null || _busy || _dirty
                    ? null
                    : _openMeasurements,
                child: const Text('Show ERP measurements'),
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
    return Row(
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
                      padding: const EdgeInsets.all(8),
                      child: Wrap(
                        spacing: 12,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          SegmentedButton<String>(
                            segments: const [
                              ButtonSegment(
                                value: 'epochs',
                                label: Text('Epochs'),
                              ),
                              ButtonSegment(
                                value: 'averages',
                                label: Text('ERP averages'),
                              ),
                            ],
                            selected: {_mode},
                            onSelectionChanged: (v) =>
                                setState(() => _mode = v.first),
                          ),
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
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: DropdownButtonFormField<int>(
                        value: _channel,
                        decoration: const InputDecoration(
                          labelText: 'ERP channel',
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
                    Expanded(
                      flex: _mode == 'epochs' ? 3 : 1,
                      child: _mode == 'epochs'
                          ? EegViewer(
                              key: ValueKey(
                                'erp-trial-$_trial-${identityHashCode(session)}',
                              ),
                              recording: session.trial(_trial),
                              externalEpochNavigation: true,
                              selection: const ViewerSelection.empty(),
                              onSelectionChanged: (_) {},
                              autoscaleByDefault: true,
                            )
                          : Padding(
                              padding: const EdgeInsets.all(18),
                              child: Column(
                                children: [
                                  Wrap(
                                    spacing: 16,
                                    children: [
                                      for (
                                        var i = 0;
                                        i < session.conditions.length;
                                        i++
                                      )
                                        Text(
                                          '${session.conditions[i]} · n=${session.counts[session.conditions[i]]}',
                                          style: TextStyle(
                                            color:
                                                Colors.primaries[i %
                                                    Colors.primaries.length],
                                          ),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
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
                    ),
                    if (_mode == 'epochs')
                      Expanded(
                        flex: 2,
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            children: [
                              const Text(
                                'Live ERP averages · fixed amplitude scale',
                              ),
                              Wrap(
                                spacing: 16,
                                children: [
                                  for (
                                    var i = 0;
                                    i < session.conditions.length;
                                    i++
                                  )
                                    Text(
                                      '${session.conditions[i]} · n=${session.counts[session.conditions[i]]}',
                                      style: TextStyle(
                                        color:
                                            Colors.primaries[i %
                                                Colors.primaries.length],
                                      ),
                                    ),
                                ],
                              ),
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
          ..color = Colors.primaries[i % Colors.primaries.length]
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
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
