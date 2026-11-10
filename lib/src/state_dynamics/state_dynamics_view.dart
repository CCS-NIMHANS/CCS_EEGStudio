import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../extraction_service.dart';

// ── Models ────────────────────────────────────────────────────────────────────

class StateDynamicsResult {
  StateDynamicsResult({
    required this.featureSet,
    required this.scale,
    required this.chosenK,
    required this.ivThreshold,
    required this.displayBand,
    required this.reprChannel,
    required this.silhouetteScores,
    required this.availableScales,
    required this.metrics,
    required this.rois,
    required this.recordings,
    required this.states,
  });

  factory StateDynamicsResult.fromJson(Map<String, dynamic> json) {
    return StateDynamicsResult(
      featureSet: json['feature_set'] as String? ?? 'paper',
      scale: json['scale'] as String? ?? '60s',
      chosenK: (json['chosen_k'] as num?)?.toInt() ?? 6,
      ivThreshold: (json['iv_threshold'] as num?)?.toDouble() ?? 0.4,
      displayBand: json['display_band'] as String? ?? 'Gamma1',
      reprChannel: json['repr_channel'] as String? ?? 'Fz',
      silhouetteScores: {
        for (final entry
            in (json['silhouette_scores'] as Map<String, dynamic>? ?? {})
                .entries)
          int.tryParse(entry.key) ?? 2: (entry.value as num).toDouble(),
      },
      availableScales: (json['available_scales'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      metrics: (json['metrics'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      rois: (json['rois'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      recordings: (json['recordings'] as List<dynamic>? ?? [])
          .map((e) => RecordingTimeline.fromJson(e as Map<String, dynamic>))
          .toList(),
      states: (json['states'] as List<dynamic>? ?? [])
          .map((e) => StateSummary.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  final String featureSet;
  final String scale;
  final int chosenK;
  final double ivThreshold;
  final String displayBand;
  final String reprChannel;
  final Map<int, double> silhouetteScores;
  final List<String> availableScales;
  final List<String> metrics;
  final List<String> rois;
  final List<RecordingTimeline> recordings;
  final List<StateSummary> states;
}

class RecordingTimeline {
  RecordingTimeline({
    required this.key,
    required this.label,
    required this.file,
    required this.nWindows,
    required this.durationS,
    required this.windows,
    required this.events,
    required this.cutPoints,
  });

  factory RecordingTimeline.fromJson(Map<String, dynamic> json) {
    return RecordingTimeline(
      key: json['key'] as String? ?? '',
      label: json['label'] as String? ?? '',
      file: json['file'] as String? ?? '',
      nWindows: (json['n_windows'] as num?)?.toInt() ?? 0,
      durationS: (json['duration_s'] as num?)?.toDouble() ?? 0.0,
      windows: (json['windows'] as List<dynamic>? ?? [])
          .map((w) => WindowPoint.fromJson(w as Map<String, dynamic>))
          .toList(),
      events: (json['events'] as List<dynamic>? ?? [])
          .map((e) => EventMarker.fromJson(e as Map<String, dynamic>))
          .toList(),
      cutPoints: {
        for (final entry
            in (json['cut_points'] as Map<String, dynamic>? ?? {}).entries)
          entry.key: (entry.value as List<dynamic>)
              .map((v) => (v as num).toInt())
              .toList(),
      },
    );
  }

  final String key;
  final String label;
  final String file;
  final int nWindows;
  final double durationS;
  final List<WindowPoint> windows;
  final List<EventMarker> events;
  final Map<String, List<int>> cutPoints;
}

class WindowPoint {
  WindowPoint({
    required this.winIdx,
    required this.tStart,
    required this.tCenter,
    required this.stageIdx,
    required this.stateLabel,
    required this.stateColor,
    required this.bandMean,
    required this.bandCi95,
    required this.reprChan,
  });

  factory WindowPoint.fromJson(Map<String, dynamic> json) {
    return WindowPoint(
      winIdx: (json['win_idx'] as num?)?.toInt() ?? 0,
      tStart: (json['t_start'] as num?)?.toDouble() ?? 0.0,
      tCenter: (json['t_center'] as num?)?.toDouble() ?? 0.0,
      stageIdx: (json['stage_idx'] as num?)?.toInt() ?? 0,
      stateLabel: json['state_label'] as String? ?? 'A',
      stateColor: json['state_color'] as String? ?? '#0072B2',
      bandMean: (json['band_mean'] as num?)?.toDouble() ?? 0.0,
      bandCi95: (json['band_ci95'] as num?)?.toDouble() ?? 0.0,
      reprChan: (json['repr_chan'] as num?)?.toDouble() ?? 0.0,
    );
  }

  final int winIdx;
  final double tStart;
  final double tCenter;
  final int stageIdx;
  final String stateLabel;
  final String stateColor;
  final double bandMean;
  final double bandCi95;
  final double reprChan;
}

class EventMarker {
  EventMarker({
    required this.onsetS,
    required this.label,
    required this.markerType,
  });

  factory EventMarker.fromJson(Map<String, dynamic> json) {
    return EventMarker(
      onsetS: (json['onset_s'] as num?)?.toDouble() ?? 0.0,
      label: json['label'] as String? ?? '',
      markerType: json['marker_type'] as String? ?? '',
    );
  }

  final double onsetS;
  final String label;
  final String markerType;
}

class StateSummary {
  StateSummary({
    required this.label,
    required this.color,
    required this.nStages,
    required this.totalTimeS,
    required this.durationMin,
    required this.percentTime,
    required this.medianStageS,
    required this.timePerRecording,
    required this.topFeatures,
    required this.centroidZ,
    required this.sigDots,
    required this.ivValues,
  });

  factory StateSummary.fromJson(Map<String, dynamic> json) {
    return StateSummary(
      label: json['label'] as String? ?? '',
      color: json['color'] as String? ?? '#0072B2',
      nStages: (json['n_stages'] as num?)?.toInt() ?? 0,
      totalTimeS: (json['total_time_s'] as num?)?.toDouble() ?? 0.0,
      durationMin: (json['duration_min'] as num?)?.toDouble() ?? 0.0,
      percentTime: (json['percent_time'] as num?)?.toDouble() ?? 0.0,
      medianStageS: (json['median_stage_s'] as num?)?.toDouble() ?? 0.0,
      timePerRecording: {
        for (final entry
            in (json['time_per_recording'] as Map<String, dynamic>? ?? {})
                .entries)
          entry.key: (entry.value as num).toDouble(),
      },
      topFeatures: (json['top_features'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      centroidZ: (json['centroid_z'] as List<dynamic>? ?? [])
          .map(
            (row) =>
                (row as List<dynamic>).map((v) => (v as num).toDouble()).toList(),
          )
          .toList(),
      sigDots: (json['sig_dots'] as List<dynamic>? ?? [])
          .map(
            (row) =>
                (row as List<dynamic>).map((v) => v as bool? ?? false).toList(),
          )
          .toList(),
      ivValues: (json['iv_values'] as List<dynamic>? ?? [])
          .map(
            (row) =>
                (row as List<dynamic>).map((v) => (v as num).toDouble()).toList(),
          )
          .toList(),
    );
  }

  final String label;
  final String color;
  final int nStages;
  final double totalTimeS;
  final double durationMin;
  final double percentTime;
  final double medianStageS;
  final Map<String, double> timePerRecording;
  final List<String> topFeatures;
  final List<List<double>> centroidZ;
  final List<List<bool>> sigDots;
  final List<List<double>> ivValues;
}

// ── Main View ─────────────────────────────────────────────────────────────────

class StateDynamicsView extends StatefulWidget {
  const StateDynamicsView({
    super.key,
    required this.featureFilePaths,
    this.title = 'State Dynamics Analysis',
    this.autoRun = false,
  });

  final List<String> featureFilePaths;
  final String title;
  final bool autoRun;

  @override
  State<StateDynamicsView> createState() => _StateDynamicsViewState();
}

class _StateDynamicsViewState extends State<StateDynamicsView> {
  String _featureSet = 'paper';
  String _scale = '60s';
  int? _chosenK = 6;
  double _ivThreshold = 0.4;
  String _displayBand = 'Gamma1';
  String _reprChannel = 'Fz';
  final bool _rankTransform = false;

  bool _loading = false;
  String _status = '';
  String? _error;
  StateDynamicsResult? _result;
  String? _selectedStateLabel;
  Process? _process;

  @override
  void initState() {
    super.initState();
    if (widget.autoRun && widget.featureFilePaths.isNotEmpty) {
      _runAnalysis();
    }
  }

  @override
  void dispose() {
    _process?.kill();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant StateDynamicsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.autoRun &&
        oldWidget.featureFilePaths != widget.featureFilePaths &&
        widget.featureFilePaths.isNotEmpty) {
      _runAnalysis();
    }
  }

  Future<void> _runAnalysis() async {
    if (widget.featureFilePaths.isEmpty) {
      setState(() => _error = 'No feature files loaded.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _status = 'Running State Dynamics in Rust engine…';
    });

    try {
      final engine = ExtractionService.findEngine();
      final temp = await Directory.systemTemp.createTemp('ccs_state_dyn_');
      final jobFile = File('${temp.path}/job.json');

      final job = {
        'job_type': 'state_dynamics',
        'files': widget.featureFilePaths,
        'featureset': _featureSet,
        'scale': _scale,
        'k': _chosenK,
        'iv_threshold': _ivThreshold,
        'display_band': _displayBand,
        'repr_channel': _reprChannel,
        'rank_transform': _rankTransform,
        'step_s': 2.5,
        'win_s': 5.0,
      };

      await jobFile.writeAsString(jsonEncode(job));

      final process = await Process.start(engine, [jobFile.path]);
      _process = process;
      final stdout = await process.stdout.transform(utf8.decoder).join();
      final stderr = await process.stderr.transform(utf8.decoder).join();
      final code = await process.exitCode;
      _process = null;

      if (code != 0) {
        throw StateError(
          'Engine exited with code $code: ${stderr.isNotEmpty ? stderr : stdout}',
        );
      }

      final jsonResult = jsonDecode(stdout) as Map<String, dynamic>;
      final parsed = StateDynamicsResult.fromJson(jsonResult);

      if (mounted) {
        setState(() {
          _result = parsed;
          _selectedStateLabel ??= parsed.states.firstOrNull?.label;
          _loading = false;
          _status = 'Complete.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  Color _parseHex(String hex) {
    var c = hex.replaceAll('#', '');
    if (c.length == 6) c = 'FF$c';
    return Color(int.tryParse(c, radix: 16) ?? 0xFF0072B2);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final res = _result;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      elevation: 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header / Controls bar
            _buildControlsBar(theme),
            const Divider(height: 20),

            if (_loading)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 36),
                child: Column(
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 12),
                    Text(_status, style: const TextStyle(fontSize: 12)),
                  ],
                ),
              )
            else if (_error != null)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.shade400),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline, color: Colors.redAccent),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _error!,
                        style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                      ),
                    ),
                    TextButton(
                      onPressed: _runAnalysis,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              )
            else if (res != null) ...[
              // Snapshot 1: Stable-State Segmentation Timeline
              _buildTimelineSection(res, theme),

              const SizedBox(height: 20),
              const Divider(height: 24),

              // Snapshot 2: State Feature Mapping Heatmap
              _buildFeatureMappingSection(res, theme),
            ] else if (widget.featureFilePaths.isNotEmpty)
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Column(
                    children: [
                      Icon(Icons.waves, size: 40, color: theme.colorScheme.primary.withValues(alpha: 0.5)),
                      const SizedBox(height: 8),
                      Text(
                        'Ready to compute State Dynamics for ${widget.featureFilePaths.length} feature file(s).',
                        style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 13),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: _loading ? null : _runAnalysis,
                        icon: const Icon(Icons.play_arrow, size: 18),
                        label: const Text('Compute State Dynamics'),
                      ),
                    ],
                  ),
                ),
              )
            else
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Text(
                    'No feature files available to run State Dynamics.',
                    style: TextStyle(color: theme.colorScheme.outline),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildControlsBar(ThemeData theme) {
    final silScores = _result?.silhouetteScores ?? {};
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.hasBoundedWidth ? constraints.maxWidth : 1000.0;
        return SizedBox(
          width: w,
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.waves, size: 20, color: Color(0xFF0072B2)),
                  const SizedBox(width: 8),
                  Text(
                    widget.title,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                ],
              ),
              // Feature set
              DropdownButton<String>(
                value: _featureSet,
                isDense: true,
                underline: const SizedBox(),
                items: const [
                  DropdownMenuItem(value: 'paper', child: Text('Paper-like (214 features)')),
                  DropdownMenuItem(value: 'full', child: Text('Full features')),
                ],
                onChanged: _loading
                    ? null
                    : (v) {
                        if (v != null) {
                          setState(() => _featureSet = v);
                          _runAnalysis();
                        }
                      },
              ),
              // Scale
              DropdownButton<String>(
                value: _scale,
                isDense: true,
                underline: const SizedBox(),
                items: const [
                  DropdownMenuItem(value: '60s', child: Text('Scale: 60s stages')),
                  DropdownMenuItem(value: '30s', child: Text('Scale: 30s stages')),
                  DropdownMenuItem(value: '15s', child: Text('Scale: 15s stages')),
                  DropdownMenuItem(value: 'auto', child: Text('Scale: auto')),
                  DropdownMenuItem(value: '120s', child: Text('Scale: 120s stages')),
                  DropdownMenuItem(value: '300s', child: Text('Scale: 300s stages')),
                ],
                onChanged: _loading
                    ? null
                    : (v) {
                        if (v != null) {
                          setState(() => _scale = v);
                          _runAnalysis();
                        }
                      },
              ),
              // Number of states K with silhouette scores
              DropdownButton<int?>(
                value: _chosenK,
                isDense: true,
                underline: const SizedBox(),
                items: [
                  for (var k = 2; k <= 8; k++)
                    DropdownMenuItem(
                      value: k,
                      child: Text(
                        'k=$k ${silScores.containsKey(k) ? "(sil: ${silScores[k]!.toStringAsFixed(2)})" : ""}',
                        style: TextStyle(
                          fontWeight: (_chosenK == k) ? FontWeight.bold : FontWeight.normal,
                          color: (_chosenK == k) ? const Color(0xFF0072B2) : null,
                        ),
                      ),
                    ),
                ],
                onChanged: _loading
                    ? null
                    : (v) {
                        if (v != null) {
                          setState(() => _chosenK = v);
                          _runAnalysis();
                        }
                      },
              ),
              // IV Threshold
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('IV: ', style: TextStyle(fontSize: 12)),
                  SizedBox(
                    width: 50,
                    height: 28,
                    child: TextFormField(
                      initialValue: _ivThreshold.toString(),
                      style: const TextStyle(fontSize: 12),
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                        border: OutlineInputBorder(),
                      ),
                      onFieldSubmitted: (v) {
                        final val = double.tryParse(v);
                        if (val != null) {
                          setState(() => _ivThreshold = val);
                          _runAnalysis();
                        }
                      },
                    ),
                  ),
                ],
              ),
              // Display Band
              DropdownButton<String>(
                value: _displayBand,
                isDense: true,
                underline: const SizedBox(),
                items: const [
                  DropdownMenuItem(value: 'Gamma1', child: Text('Band: Gamma1')),
                  DropdownMenuItem(value: 'Alpha', child: Text('Band: Alpha')),
                  DropdownMenuItem(value: 'Theta', child: Text('Band: Theta')),
                  DropdownMenuItem(value: 'Beta1', child: Text('Band: Beta1')),
                  DropdownMenuItem(value: 'Beta2', child: Text('Band: Beta2')),
                  DropdownMenuItem(value: 'Delta', child: Text('Band: Delta')),
                ],
                onChanged: _loading
                    ? null
                    : (v) {
                        if (v != null) {
                          setState(() => _displayBand = v);
                          _runAnalysis();
                        }
                      },
              ),
              // Repr Channel
              DropdownButton<String>(
                value: _reprChannel,
                isDense: true,
                underline: const SizedBox(),
                items: const [
                  DropdownMenuItem(value: 'Fz', child: Text('Chan: Fz')),
                  DropdownMenuItem(value: 'Cz', child: Text('Chan: Cz')),
                  DropdownMenuItem(value: 'Pz', child: Text('Chan: Pz')),
                  DropdownMenuItem(value: 'Oz', child: Text('Chan: Oz')),
                ],
                onChanged: _loading
                    ? null
                    : (v) {
                        if (v != null) {
                          setState(() => _reprChannel = v);
                          _runAnalysis();
                        }
                      },
              ),
              FilledButton.icon(
                onPressed: _loading ? null : _runAnalysis,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Recompute'),
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ── Snapshot 1: Timeline Section ──────────────────────────────────────────

  Widget _buildTimelineSection(StateDynamicsResult res, ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Title & State Legend
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                'Stable-state segmentation of ${res.displayBand} PSD course — scale ${res.scale} (purple = task markers, dashed = ${res.reprChannel})',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
            ),
            Wrap(
              spacing: 6,
              children: [
                for (final st in res.states)
                  InkWell(
                    onTap: () => setState(() => _selectedStateLabel = st.label),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: _selectedStateLabel == st.label
                            ? _parseHex(st.color)
                            : _parseHex(st.color).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: _parseHex(st.color)),
                      ),
                      child: Text(
                        'state ${st.label}',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: _selectedStateLabel == st.label
                              ? Colors.white
                              : _parseHex(st.color),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 10),

        // Side-by-side timeline plots for each recording
        SizedBox(
          height: 280,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < res.recordings.len(); i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(
                  flex: math.max(1, (res.recordings[i].durationS / 60.0).round()),
                  child: _buildSingleRecordingTimeline(res.recordings[i], res, theme, showYAxis: i == 0),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSingleRecordingTimeline(
    RecordingTimeline rec,
    StateDynamicsResult res,
    ThemeData theme, {
    required bool showYAxis,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Recording label header
        Center(
          child: Text(
            rec.label,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(height: 4),

        // Custom plotted canvas: PSD curve + State Strip + Raster
        Expanded(
          child: CustomPaint(
            painter: _StateTimelinePainter(
              rec: rec,
              res: res,
              showYAxis: showYAxis,
              theme: theme,
              onStateTap: (label) => setState(() => _selectedStateLabel = label),
            ),
          ),
        ),
      ],
    );
  }

  // ── Snapshot 2: Feature Mapping Heatmap Section ────────────────────────────

  Widget _buildFeatureMappingSection(StateDynamicsResult res, ThemeData theme) {
    final activeLabel = _selectedStateLabel ?? res.states.firstOrNull?.label ?? 'A';
    final activeState = res.states.firstWhere(
      (s) => s.label == activeLabel,
      orElse: () => res.states.first,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '${res.featureSet} features, ${res.chosenK} pooled states: State Feature Mapping (dot = sig vs rest & |r|>=0.5 or IV>=${res.ivThreshold})',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            // State selector chips
            Wrap(
              spacing: 4,
              children: [
                for (final st in res.states)
                  ChoiceChip(
                    label: Text('State ${st.label} (${st.durationMin.toStringAsFixed(1)} min)'),
                    selected: st.label == activeLabel,
                    selectedColor: _parseHex(st.color).withValues(alpha: 0.3),
                    onSelected: (_) => setState(() => _selectedStateLabel = st.label),
                  ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 8),

        // Active State Summary Box
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: _parseHex(activeState.color).withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: _parseHex(activeState.color)),
          ),
          child: Row(
            children: [
              Text(
                'State ${activeState.label}: ${activeState.nStages} stages, ${activeState.durationMin.toStringAsFixed(1)} min (${activeState.percentTime.toStringAsFixed(1)}% of total time)',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
              ),
              const Spacer(),
              if (activeState.topFeatures.isNotEmpty)
                Expanded(
                  child: Text(
                    'Top: ${activeState.topFeatures.take(4).join("; ")}',
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),

        // Interactive Heatmap Grid
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: _buildHeatmapGrid(activeState, res, theme),
        ),
      ],
    );
  }

  Widget _buildHeatmapGrid(StateSummary st, StateDynamicsResult res, ThemeData theme) {
    const double cellW = 32;
    const double cellH = 14;
    final nRows = res.metrics.length;
    final nCols = res.rois.length;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Metric labels on left
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            const SizedBox(height: 70), // space for top rotated ROI headers
            for (var r = 0; r < nRows; r++)
              SizedBox(
                height: cellH,
                child: Text(
                  res.metrics[r],
                  style: const TextStyle(fontSize: 9),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
        const SizedBox(width: 8),

        // Heatmap Cells & Column Headers
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Rotated ROI Headers
            SizedBox(
              height: 70,
              child: Row(
                children: [
                  for (var c = 0; c < nCols; c++)
                    SizedBox(
                      width: cellW,
                      child: Transform.rotate(
                        angle: -math.pi / 3,
                        alignment: Alignment.bottomLeft,
                        child: Text(
                          res.rois[c],
                          style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold),
                          overflow: TextOverflow.visible,
                        ),
                      ),
                    ),
                ],
              ),
            ),

            // 2D Matrix of cells
            for (var r = 0; r < nRows; r++)
              Row(
                children: [
                  for (var c = 0; c < nCols; c++)
                    Builder(
                      builder: (ctx) {
                        final val = r < st.centroidZ.length && c < st.centroidZ[r].length
                            ? st.centroidZ[r][c]
                            : 0.0;
                        final hasDot = r < st.sigDots.length && c < st.sigDots[r].length
                            ? st.sigDots[r][c]
                            : false;
                        final ivVal = r < st.ivValues.length && c < st.ivValues[r].length
                            ? st.ivValues[r][c]
                            : 0.0;

                        final color = _rdBuColor(val);

                        return Tooltip(
                          message:
                              '${res.metrics[r]} @ ${res.rois[c]}\nMean z: ${val.toStringAsFixed(2)}\nIV: ${ivVal.toStringAsFixed(2)}${hasDot ? "\n★ Significant vs rest" : ""}',
                          child: Container(
                            width: cellW,
                            height: cellH,
                            decoration: BoxDecoration(
                              color: color,
                              border: Border.all(color: Colors.black12, width: 0.5),
                            ),
                            child: hasDot
                                ? Center(
                                    child: Container(
                                      width: 4,
                                      height: 4,
                                      decoration: const BoxDecoration(
                                        color: Colors.black,
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                  )
                                : null,
                          ),
                        );
                      },
                    ),
                ],
              ),
          ],
        ),

        const SizedBox(width: 16),
        // Colorbar legend
        _buildColorBar(),
      ],
    );
  }

  Widget _buildColorBar() {
    return Column(
      children: [
        const SizedBox(height: 70),
        const Text('+2.0', style: TextStyle(fontSize: 9)),
        Container(
          width: 14,
          height: 180,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0xFF67001F), // dark red
                Color(0xFFB2182B),
                Color(0xFFD6604D),
                Color(0xFFF4A582),
                Color(0xFFF7F7F7), // white
                Color(0xFF92C5DE),
                Color(0xFF4393C3),
                Color(0xFF2166AC),
                Color(0xFF053061), // dark blue
              ],
            ),
          ),
        ),
        const Text('-2.0', style: TextStyle(fontSize: 9)),
        const SizedBox(height: 4),
        const Text('z', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
      ],
    );
  }

  Color _rdBuColor(double z) {
    // RdBu_r: positive is red, negative is blue, zero is near white
    final clamped = z.clamp(-2.0, 2.0);
    final norm = (clamped + 2.0) / 4.0; // 0..1 (0 is -2, 1 is +2)

    if (norm < 0.5) {
      // Blue side (0 -> dark blue, 0.5 -> white)
      final t = norm / 0.5;
      return Color.lerp(const Color(0xFF053061), const Color(0xFFF7F7F7), t)!;
    } else {
      // Red side (0.5 -> white, 1.0 -> dark red)
      final t = (norm - 0.5) / 0.5;
      return Color.lerp(const Color(0xFFF7F7F7), const Color(0xFF67001F), t)!;
    }
  }
}

// ── Custom Painter for Timeline, State Strip and Raster ───────────────────────

class _StateTimelinePainter extends CustomPainter {
  _StateTimelinePainter({
    required this.rec,
    required this.res,
    required this.showYAxis,
    required this.theme,
    required this.onStateTap,
  });

  final RecordingTimeline rec;
  final StateDynamicsResult res;
  final bool showYAxis;
  final ThemeData theme;
  final void Function(String stateLabel) onStateTap;

  @override
  void paint(Canvas canvas, Size size) {
    if (rec.windows.isEmpty) return;

    final totalMin = rec.durationS / 60.0;
    if (totalMin <= 0) return;

    // Layout proportions:
    // Top graph: 60% of height
    // State strip: 18% of height
    // Raster: 22% of height
    final topH = size.height * 0.58;
    final stripY = topH + 6.0;
    final stripH = size.height * 0.16;
    final rasterY = stripY + stripH + 6.0;
    final rasterH = size.height - rasterY;

    // X coordinate mapping
    double mapX(double tSec) => (tSec / 60.0 / totalMin) * size.width;

    // 1. Top Panel: Background tint per window/stage
    for (var i = 0; i < rec.windows.length; i++) {
      final w = rec.windows[i];
      final x1 = mapX(w.tStart);
      final nextT = (i + 1 < rec.windows.length) ? rec.windows[i + 1].tStart : rec.durationS;
      final x2 = mapX(nextT);
      final c = _parseColor(w.stateColor).withValues(alpha: 0.15);
      canvas.drawRect(Rect.fromLTRB(x1, 0, x2, topH), Paint()..color = c);
    }

    // Top Panel: Y scaling for PSD
    var minVal = rec.windows.first.bandMean;
    var maxVal = rec.windows.first.bandMean;
    for (final w in rec.windows) {
      if (w.bandMean - w.bandCi95 < minVal) minVal = w.bandMean - w.bandCi95;
      if (w.bandMean + w.bandCi95 > maxVal) maxVal = w.bandMean + w.bandCi95;
      if (w.reprChan < minVal) minVal = w.reprChan;
      if (w.reprChan > maxVal) maxVal = w.reprChan;
    }
    if (minVal > 0) minVal = 0.0;
    if (maxVal <= minVal) maxVal = minVal + 0.1;
    final rangeY = maxVal - minVal;

    double mapY(double val) => topH - ((val - minVal) / rangeY * topH);

    // Draw CI95 shaded band
    final ciPath = Path();
    ciPath.moveTo(mapX(rec.windows.first.tCenter), mapY(rec.windows.first.bandMean - rec.windows.first.bandCi95));
    for (final w in rec.windows) {
      ciPath.lineTo(mapX(w.tCenter), mapY(w.bandMean - w.bandCi95));
    }
    for (var i = rec.windows.length - 1; i >= 0; i--) {
      final w = rec.windows[i];
      ciPath.lineTo(mapX(w.tCenter), mapY(w.bandMean + w.bandCi95));
    }
    ciPath.close();
    canvas.drawPath(ciPath, Paint()..color = const Color(0xFFD9D9D9).withValues(alpha: 0.6));

    // Draw Channel Mean solid line (red)
    final meanPath = Path();
    meanPath.moveTo(mapX(rec.windows.first.tCenter), mapY(rec.windows.first.bandMean));
    for (final w in rec.windows) {
      meanPath.lineTo(mapX(w.tCenter), mapY(w.bandMean));
    }
    canvas.drawPath(
      meanPath,
      Paint()
        ..color = const Color(0xFFC0392B)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );

    // Draw Representative Channel dashed line (blue)
    final reprPath = Path();
    reprPath.moveTo(mapX(rec.windows.first.tCenter), mapY(rec.windows.first.reprChan));
    for (final w in rec.windows) {
      reprPath.lineTo(mapX(w.tCenter), mapY(w.reprChan));
    }
    canvas.drawPath(
      reprPath,
      Paint()
        ..color = const Color(0xFF4F81BD)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0,
    );

    // Event markers (purple vertical lines + text)
    final purplePaint = Paint()
      ..color = const Color(0xFF7B3FA0)
      ..strokeWidth = 0.9;

    for (var k = 0; k < rec.events.length; k++) {
      final ev = rec.events[k];
      final ex = mapX(ev.onsetS);
      canvas.drawLine(Offset(ex, 0), Offset(ex, topH), purplePaint);

      // Label
      final tp = TextPainter(
        text: TextSpan(
          text: ev.label,
          style: const TextStyle(color: Color(0xFF7B3FA0), fontSize: 8),
        ),
        textDirection: TextDirection.ltr,
      );
      tp.layout();
      tp.paint(canvas, Offset(ex + 1, 4.0 + (k % 3) * 10.0));
    }

    // Border around top graph
    canvas.drawRect(
      Rect.fromLTRB(0, 0, size.width, topH),
      Paint()
        ..color = Colors.black26
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5,
    );

    if (showYAxis) {
      // Y-axis label
      final tp = TextPainter(
        text: TextSpan(
          text: '${res.displayBand}_PSD\n(mean ± CI95 across ch.)',
          style: const TextStyle(fontSize: 8, color: Colors.grey),
        ),
        textDirection: TextDirection.ltr,
      );
      tp.layout();
      tp.paint(canvas, const Offset(4, 4));
    }

    // 2. Middle Strip: State classification bar
    for (var i = 0; i < rec.windows.length; i++) {
      final w = rec.windows[i];
      final x1 = mapX(w.tStart);
      final nextT = (i + 1 < rec.windows.length) ? rec.windows[i + 1].tStart : rec.durationS;
      final x2 = mapX(nextT);
      final c = _parseColor(w.stateColor);
      canvas.drawRect(Rect.fromLTRB(x1, stripY, x2, stripY + stripH), Paint()..color = c);

      // Draw state letter if wide enough
      if (x2 - x1 > 14) {
        final tp = TextPainter(
          text: TextSpan(
            text: w.stateLabel,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 9,
            ),
          ),
          textDirection: TextDirection.ltr,
        );
        tp.layout();
        tp.paint(canvas, Offset((x1 + x2) / 2 - tp.width / 2, stripY + stripH / 2 - tp.height / 2));
      }
    }

    // 3. Bottom Raster: Multi-scale boundary raster (15s, 30s, 60s, auto)
    final scales = ['auto', '60s', '30s', '15s'];
    final tickH = rasterH / scales.length;
    final tickPaint = Paint()
      ..color = Colors.black54
      ..strokeWidth = 0.8;

    for (var sIdx = 0; sIdx < scales.length; sIdx++) {
      final sc = scales[sIdx];
      final cuts = rec.cutPoints[sc] ?? [];
      final yBase = rasterY + sIdx * tickH;

      for (var c = 1; c < cuts.length - 1; c++) {
        final winIdx = cuts[c];
        if (winIdx < rec.windows.length) {
          final tx = mapX(rec.windows[winIdx].tStart);
          canvas.drawLine(Offset(tx, yBase + 1), Offset(tx, yBase + tickH - 1), tickPaint);
        }
      }

      if (showYAxis) {
        final tp = TextPainter(
          text: TextSpan(
            text: '$sc (${cuts.length > 1 ? cuts.length - 1 : 0})',
            style: const TextStyle(fontSize: 7, color: Colors.grey),
          ),
          textDirection: TextDirection.ltr,
        );
        tp.layout();
        tp.paint(canvas, Offset(2, yBase + 1));
      }
    }
  }

  Color _parseColor(String hex) {
    var c = hex.replaceAll('#', '');
    if (c.length == 6) c = 'FF$c';
    return Color(int.tryParse(c, radix: 16) ?? 0xFF0072B2);
  }

  @override
  bool shouldRepaint(covariant _StateTimelinePainter old) => true;
}

extension _ListLen on List {
  int len() => length;
}
