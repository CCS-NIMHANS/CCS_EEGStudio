import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'erp_cache_recompute.dart';
import 'erp_component_spec.dart';
import 'topo_channel_selector.dart';
import 'workbench_figures.dart';

class GrandAverageSelection {
  const GrandAverageSelection({
    required this.roi,
    required this.startMs,
    required this.endMs,
    required this.polarity,
    this.components = const [],
    this.epochMinMs,
    this.epochMaxMs,
    this.baselineStartMs,
    this.baselineEndMs,
    this.updatedParticipantGroups,
    this.updatedExcludedFiles,
  });

  final String roi;
  final double startMs;
  final double endMs;
  final double polarity;
  final List<ErpComponentSpec> components;
  final double? epochMinMs;
  final double? epochMaxMs;
  final double? baselineStartMs;
  final double? baselineEndMs;
  final Map<String, String>? updatedParticipantGroups;
  final Set<String>? updatedExcludedFiles;
}

enum _GrandAvgMode { collapsed, byCondition, byGroup, groupByCondition }

/// Interactive Grand Average Localizer for unbiased ROI and time-window selection
/// across groups, conditions, or collapsed across all trials/subjects.
class GrandAverageLocalizerDialog extends StatefulWidget {
  const GrandAverageLocalizerDialog({
    super.key,
    required this.files,
    required this.participantGroups,
    required this.initialRoi,
    required this.initialStartMs,
    required this.initialEndMs,
    required this.initialPolarity,
    this.negativeUp = true,
    this.initialComponents = const [],
    this.initialEpochMinMs,
    this.initialEpochMaxMs,
    this.initialBaselineStartMs,
    this.initialBaselineEndMs,
    this.initialExcludedFiles = const {},
    this.onConfigureFactors,
  });

  final List<Map<String, dynamic>> files;
  final Map<String, String> participantGroups;
  final String initialRoi;
  final double initialStartMs;
  final double initialEndMs;
  final double initialPolarity;
  final bool negativeUp;
  final List<ErpComponentSpec> initialComponents;
  final double? initialEpochMinMs;
  final double? initialEpochMaxMs;
  final double? initialBaselineStartMs;
  final double? initialBaselineEndMs;
  final Set<String> initialExcludedFiles;
  final Future<({Map<String, String> groups, Set<String> excludedFiles})?>
  Function(BuildContext context)?
  onConfigureFactors;

  static Future<GrandAverageSelection?> show(
    BuildContext context, {
    required List<Map<String, dynamic>> files,
    required Map<String, String> participantGroups,
    required String initialRoi,
    required double initialStartMs,
    required double initialEndMs,
    required double initialPolarity,
    bool negativeUp = true,
    List<ErpComponentSpec> initialComponents = const [],
    double? initialEpochMinMs,
    double? initialEpochMaxMs,
    double? initialBaselineStartMs,
    double? initialBaselineEndMs,
    Set<String> initialExcludedFiles = const {},
    Future<({Map<String, String> groups, Set<String> excludedFiles})?>
    Function(BuildContext context)?
    onConfigureFactors,
  }) {
    return showDialog<GrandAverageSelection>(
      context: context,
      builder: (_) => GrandAverageLocalizerDialog(
        files: files,
        participantGroups: participantGroups,
        initialRoi: initialRoi,
        initialStartMs: initialStartMs,
        initialEndMs: initialEndMs,
        initialPolarity: initialPolarity,
        negativeUp: negativeUp,
        initialComponents: initialComponents,
        initialEpochMinMs: initialEpochMinMs,
        initialEpochMaxMs: initialEpochMaxMs,
        initialBaselineStartMs: initialBaselineStartMs,
        initialBaselineEndMs: initialBaselineEndMs,
        initialExcludedFiles: initialExcludedFiles,
        onConfigureFactors: onConfigureFactors,
      ),
    );
  }

  @override
  State<GrandAverageLocalizerDialog> createState() =>
      _GrandAverageLocalizerDialogState();
}

class _GrandAverageLocalizerDialogState
    extends State<GrandAverageLocalizerDialog> {
  _GrandAvgMode _mode = _GrandAvgMode.collapsed;
  bool _butterflyMode = false;
  late bool _negativeUp;

  late Map<String, String> _participantGroups;
  late Set<String> _excludedFiles;
  bool _excludeUnknown = false;

  late List<ErpComponentSpec> _components;
  int _activeCompIdx = 0;

  late final TextEditingController _compNameCtrl;
  late final TextEditingController _startCtrl;
  late final TextEditingController _endCtrl;
  late final TextEditingController _epochMinCtrl;
  late final TextEditingController _epochMaxCtrl;
  late final TextEditingController _baseStartCtrl;
  late final TextEditingController _baseEndCtrl;

  late final List<double> _rawTimesMs;
  late final List<String> _channels;
  late final List<String> _conditions;

  late double _viewEpochMinMs;
  late double _viewEpochMaxMs;
  late double _baseStartMs;
  late double _baseEndMs;
  bool _liveRebaseline = false;

  double? _dragStartMs;

  // Memoized grand averages to keep window drags at 60 FPS even across 360+ files.
  Map<String, List<List<double>>>? _cachedGrandAvgs;
  String? _grandAvgCacheKey;

  ErpComponentSpec get _activeComp => _components[_activeCompIdx];

  @override
  void initState() {
    super.initState();
    _negativeUp = widget.negativeUp;
    _participantGroups = Map<String, String>.from(widget.participantGroups);
    _excludedFiles = Set<String>.from(widget.initialExcludedFiles);

    final first = widget.files.first;
    final rawTimes = erpNumbers(first['times']);
    _rawTimesMs = rawTimes.map((t) => t * 1000.0).toList();
    _channels = (first['labels'] as List? ?? []).map((e) => '$e').toList();

    final rawMin = _rawTimesMs.isNotEmpty ? _rawTimesMs.first : -200.0;
    final rawMax = _rawTimesMs.isNotEmpty ? _rawTimesMs.last : 800.0;
    _viewEpochMinMs = (widget.initialEpochMinMs ?? rawMin).clamp(rawMin, rawMax);
    _viewEpochMaxMs = (widget.initialEpochMaxMs ?? rawMax).clamp(rawMin, rawMax);
    if (_viewEpochMaxMs <= _viewEpochMinMs + 20) {
      _viewEpochMinMs = rawMin;
      _viewEpochMaxMs = rawMax;
    }

    _baseStartMs = (widget.initialBaselineStartMs ?? rawMin).clamp(rawMin, 0.0);
    _baseEndMs = (widget.initialBaselineEndMs ?? math.min(0.0, rawMax)).clamp(
      rawMin,
      rawMax,
    );
    if (_baseEndMs <= _baseStartMs) {
      _baseStartMs = rawMin;
      _baseEndMs = math.min(0.0, rawMax);
    }

    final initialRoiList = widget.initialRoi
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final fallbackRoi = initialRoiList.isNotEmpty
        ? initialRoiList
        : (_channels.isNotEmpty ? [_channels.first] : <String>['Cz']);

    if (widget.initialComponents.isNotEmpty) {
      _components = [for (final c in widget.initialComponents) c.copyWith()];
    } else {
      final lo = widget.initialStartMs.clamp(rawMin, rawMax);
      final hi = math.max(lo + 10, widget.initialEndMs.clamp(rawMin, rawMax));
      _components = [
        ErpComponentSpec(
          name: 'Component 1',
          windowStartMs: lo,
          windowEndMs: hi,
          polarity: widget.initialPolarity,
          roiChannels: fallbackRoi,
          colorValue: ErpComponentSpec.paletteColorValues.first,
        ),
      ];
    }

    final condSet = <String>{};
    for (final f in widget.files) {
      final conds = f['channel_conditions'] as Map?;
      if (conds != null) {
        for (final k in conds.keys) {
          condSet.add('$k');
        }
      } else {
        if (f['channel_a'] != null) condSet.add('Condition A');
        if (f['channel_b'] != null) condSet.add('Condition B');
      }
    }
    _conditions = condSet.toList()..sort();

    _compNameCtrl = TextEditingController();
    _startCtrl = TextEditingController();
    _endCtrl = TextEditingController();
    _epochMinCtrl = TextEditingController(
      text: _viewEpochMinMs.toStringAsFixed(0),
    );
    _epochMaxCtrl = TextEditingController(
      text: _viewEpochMaxMs.toStringAsFixed(0),
    );
    _baseStartCtrl = TextEditingController(
      text: _baseStartMs.toStringAsFixed(0),
    );
    _baseEndCtrl = TextEditingController(
      text: _baseEndMs.toStringAsFixed(0),
    );
    _syncActiveControllers();
  }

  @override
  void dispose() {
    _compNameCtrl.dispose();
    _startCtrl.dispose();
    _endCtrl.dispose();
    _epochMinCtrl.dispose();
    _epochMaxCtrl.dispose();
    _baseStartCtrl.dispose();
    _baseEndCtrl.dispose();
    super.dispose();
  }

  void _syncActiveControllers() {
    final c = _activeComp;
    _compNameCtrl.text = c.name;
    _startCtrl.text = c.windowStartMs.toStringAsFixed(0);
    _endCtrl.text = c.windowEndMs.toStringAsFixed(0);
  }

  void _invalidateCache() {
    _cachedGrandAvgs = null;
    _grandAvgCacheKey = null;
  }

  List<String> get _activeGroups {
    final grpSet = <String>{};
    for (final f in widget.files) {
      final path = '${f['path'] ?? ''}';
      if (_excludedFiles.contains(path)) continue;
      final subj = '${f['subject'] ?? ''}';
      final grp = (_participantGroups[subj] ?? '${f['group'] ?? ''}').trim();
      final eff = grp.isEmpty ? 'Unknown' : grp;
      if (_excludeUnknown && eff.toLowerCase() == 'unknown') continue;
      grpSet.add(eff);
    }
    return grpSet.isEmpty ? ['All'] : (grpSet.toList()..sort());
  }

  void _updateActiveComponent(ErpComponentSpec updated) {
    setState(() {
      _components[_activeCompIdx] = updated;
      _syncActiveControllers();
    });
  }

  void _setActiveWindow(double a, double b) {
    if (_rawTimesMs.isEmpty) return;
    final lo = math.min(a, b).clamp(_viewEpochMinMs, _viewEpochMaxMs);
    final hi = math.max(a, b).clamp(_viewEpochMinMs, _viewEpochMaxMs);
    if ((hi - lo) < 5) return;
    _updateActiveComponent(
      _activeComp.copyWith(windowStartMs: lo, windowEndMs: hi),
    );
  }

  void _applyEpochView(double minMs, double maxMs) {
    if (_rawTimesMs.isEmpty) return;
    final fullMin = _rawTimesMs.first;
    final fullMax = _rawTimesMs.last;
    final lo = math.min(minMs, maxMs).clamp(fullMin, fullMax);
    final hi = math.max(minMs, maxMs).clamp(fullMin, fullMax);
    if ((hi - lo) < 40) return;
    setState(() {
      _viewEpochMinMs = lo;
      _viewEpochMaxMs = hi;
      _epochMinCtrl.text = lo.toStringAsFixed(0);
      _epochMaxCtrl.text = hi.toStringAsFixed(0);
      for (var i = 0; i < _components.length; i++) {
        final c = _components[i];
        final cLo = c.windowStartMs.clamp(lo, hi - 10);
        final cHi = c.windowEndMs.clamp(cLo + 10, hi);
        _components[i] = c.copyWith(windowStartMs: cLo, windowEndMs: cHi);
      }
      _syncActiveControllers();
    });
  }

  void _addComponent() {
    final idx = _components.length;
    final span = (_viewEpochMaxMs - _viewEpochMinMs).clamp(100.0, 2000.0);
    final center = (_viewEpochMinMs + span * 0.5).clamp(
      _viewEpochMinMs + 20,
      _viewEpochMaxMs - 80,
    );
    setState(() {
      _components.add(
        ErpComponentSpec(
          name: 'C${idx + 1}',
          windowStartMs: center,
          windowEndMs: math.min(_viewEpochMaxMs, center + 100),
          polarity: 1.0,
          roiChannels: List<String>.from(_activeComp.roiChannels),
          colorValue: ErpComponentSpec.paletteColorValues[
              idx % ErpComponentSpec.paletteColorValues.length],
        ),
      );
      _activeCompIdx = _components.length - 1;
      _syncActiveControllers();
    });
  }

  void _applyOddballPresets() {
    setState(() {
      _components = ErpComponentSpec.oddballPresets().map((c) {
        final availableRoi = c.roiChannels
            .where((ch) => _channels.any((a) => a.toUpperCase() == ch.toUpperCase()))
            .toList();
        return c.copyWith(
          windowStartMs: c.windowStartMs.clamp(_viewEpochMinMs, _viewEpochMaxMs - 20),
          windowEndMs: c.windowEndMs.clamp(_viewEpochMinMs + 20, _viewEpochMaxMs),
          roiChannels: availableRoi.isNotEmpty
              ? availableRoi
              : (_channels.isNotEmpty ? [_channels.first] : c.roiChannels),
        );
      }).toList();
      _activeCompIdx = 0;
      _syncActiveControllers();
    });
  }

  List<double>? _extractCondWave(
    Map<String, dynamic> f,
    String cond,
    int chIdx,
  ) {
    final chans = f['channel_conditions'] as Map?;
    if (chans != null && chans.containsKey(cond)) {
      final rows = chans[cond] as List?;
      if (rows != null && chIdx < rows.length) {
        return erpNumbers(rows[chIdx]);
      }
    }
    if (cond == 'Condition A' && f['channel_a'] != null) {
      final rows = f['channel_a'] as List?;
      if (rows != null && chIdx < rows.length) return erpNumbers(rows[chIdx]);
    }
    if (cond == 'Condition B' && f['channel_b'] != null) {
      final rows = f['channel_b'] as List?;
      if (rows != null && chIdx < rows.length) return erpNumbers(rows[chIdx]);
    }
    return null;
  }

  /// Returns map of traceLabel -> channelIndex -> mean waveform across subjects/files.
  Map<String, List<List<double>>> _getGrandAverages() {
    final cacheKey =
        '${_mode.index}|$_liveRebaseline|${_baseStartMs.toStringAsFixed(1)}|${_baseEndMs.toStringAsFixed(1)}|'
        '$_excludeUnknown|${_excludedFiles.length}|${_participantGroups.length}|'
        '${_participantGroups.values.take(6).join(",")}';
    if (_cachedGrandAvgs != null && _grandAvgCacheKey == cacheKey) {
      return _cachedGrandAvgs!;
    }

    final nT = _rawTimesMs.length;
    final nCh = _channels.length;
    if (nT == 0 || nCh == 0) return {};

    final accum = <String, List<List<double>>>{};
    final counts = <String, List<int>>{};

    void addWave(String key, int chIdx, List<double> wave) {
      if (wave.length != nT) return;
      final grid = accum.putIfAbsent(
        key,
        () => List.generate(nCh, (_) => List<double>.filled(nT, 0.0)),
      );
      final cnt = counts.putIfAbsent(key, () => List<int>.filled(nCh, 0));
      for (var t = 0; t < nT; t++) {
        grid[chIdx][t] += wave[t];
      }
      cnt[chIdx] += 1;
    }

    for (final f in widget.files) {
      final path = '${f['path'] ?? ''}';
      if (_excludedFiles.contains(path)) continue;
      final subj = '${f['subject'] ?? ''}';
      final grp = (_participantGroups[subj] ?? '${f['group'] ?? ''}').trim();
      final effectiveGrp = grp.isEmpty ? 'Unknown' : grp;
      if (_excludeUnknown && effectiveGrp.toLowerCase() == 'unknown') continue;
      final labels = (f['labels'] as List? ?? []).map((e) => '$e').toList();

      for (var chIdx = 0; chIdx < nCh; chIdx++) {
        final fChIdx = labels.indexWhere(
          (l) => l.toUpperCase() == _channels[chIdx].toUpperCase(),
        );
        if (fChIdx < 0) continue;

        for (final cond in _conditions) {
          var wave = _extractCondWave(f, cond, fChIdx);
          if (wave == null || wave.length != nT) continue;
          if (_liveRebaseline) {
            wave = ErpCacheRecompute.rebaselineWave(
              wave,
              _rawTimesMs,
              _baseStartMs,
              _baseEndMs,
            );
          }
          final key = switch (_mode) {
            _GrandAvgMode.collapsed => 'Collapsed Grand Average',
            _GrandAvgMode.byCondition => cond,
            _GrandAvgMode.byGroup => effectiveGrp,
            _GrandAvgMode.groupByCondition => '$effectiveGrp · $cond',
          };
          addWave(key, chIdx, wave);
        }
      }
    }

    for (final entry in accum.entries) {
      final cnt = counts[entry.key]!;
      for (var ch = 0; ch < nCh; ch++) {
        if (cnt[ch] > 1) {
          final inv = 1.0 / cnt[ch];
          for (var t = 0; t < nT; t++) {
            entry.value[ch][t] *= inv;
          }
        }
      }
    }

    _cachedGrandAvgs = accum;
    _grandAvgCacheKey = cacheKey;
    return accum;
  }

  /// Computes mean amplitude per channel inside active component's window.
  Map<String, double> _computeWindowTopo(
    Map<String, List<List<double>>> grandAvgs,
  ) {
    final out = <String, double>{};
    if (grandAvgs.isEmpty || _rawTimesMs.isEmpty) return out;
    final comp = _activeComp;
    final tIndices = <int>[];
    for (var i = 0; i < _rawTimesMs.length; i++) {
      if (_rawTimesMs[i] >= comp.windowStartMs &&
          _rawTimesMs[i] <= comp.windowEndMs) {
        tIndices.add(i);
      }
    }
    if (tIndices.isEmpty) return out;

    for (var ch = 0; ch < _channels.length; ch++) {
      var sum = 0.0;
      var n = 0;
      for (final grid in grandAvgs.values) {
        for (final t in tIndices) {
          sum += grid[ch][t];
          n++;
        }
      }
      if (n > 0) out[_channels[ch]] = sum / n;
    }
    return out;
  }

  void _pickTopChannels(Map<String, double> topoValues, {int count = 3}) {
    if (topoValues.isEmpty) return;
    final pol = _activeComp.polarity;
    final entries = topoValues.entries.toList()
      ..sort((a, b) {
        final scoreA = pol < 0 ? -a.value : a.value;
        final scoreB = pol < 0 ? -b.value : b.value;
        return scoreB.compareTo(scoreA);
      });
    _updateActiveComponent(
      _activeComp.copyWith(roiChannels: entries.take(count).map((e) => e.key).toList()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final grandAvgs = _getGrandAverages();
    final topoValues = _computeWindowTopo(grandAvgs);
    final activeComp = _activeComp;
    final activeRoiSet = activeComp.roiChannels.toSet();
    final activeGroups = _activeGroups;
    final activeFilesCount = widget.files.where((f) {
      final path = '${f['path'] ?? ''}';
      if (_excludedFiles.contains(path)) return false;
      final subj = '${f['subject'] ?? ''}';
      final grp = (_participantGroups[subj] ?? '${f['group'] ?? ''}').trim();
      final eff = grp.isEmpty ? 'Unknown' : grp;
      return !(_excludeUnknown && eff.toLowerCase() == 'unknown');
    }).length;

    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.insights, size: 20, color: Color(0xFFD97706)),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'Grand Average Localizer (Epochs · Multi-Component Windows · ROIs)',
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (widget.onConfigureFactors != null) ...[
            OutlinedButton.icon(
              onPressed: () async {
                final updated = await widget.onConfigureFactors!(context);
                if (updated != null && mounted) {
                  setState(() {
                    _participantGroups = Map<String, String>.from(
                      updated.groups,
                    );
                    _excludedFiles = Set<String>.from(updated.excludedFiles);
                    _invalidateCache();
                  });
                }
              },
              icon: const Icon(Icons.account_tree_outlined, size: 15),
              label: const Text(
                'Configure Factors & Groups…',
                style: TextStyle(fontSize: 11.5),
              ),
            ),
            const SizedBox(width: 10),
          ],
          Text(
            '$activeFilesCount / ${widget.files.length} files · ${activeGroups.length} group(s)',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      content: SizedBox(
        width: 1120,
        height: 670,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Row 1: Display Mode & Group/Baseline/Epoch Controls
            Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SegmentedButton<_GrandAvgMode>(
                  segments: const [
                    ButtonSegment(
                      value: _GrandAvgMode.collapsed,
                      label: Text('Collapsed', style: TextStyle(fontSize: 11)),
                    ),
                    ButtonSegment(
                      value: _GrandAvgMode.byCondition,
                      label: Text(
                        'By Condition',
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                    ButtonSegment(
                      value: _GrandAvgMode.byGroup,
                      label: Text('By Group', style: TextStyle(fontSize: 11)),
                    ),
                    ButtonSegment(
                      value: _GrandAvgMode.groupByCondition,
                      label: Text(
                        'Group × Cond',
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (s) => setState(() => _mode = s.first),
                ),
                FilterChip(
                  label: const Text(
                    'Butterfly + ROI',
                    style: TextStyle(fontSize: 11),
                  ),
                  selected: _butterflyMode,
                  onSelected: (v) => setState(() => _butterflyMode = v),
                ),
                FilterChip(
                  label: const Text('Neg Up', style: TextStyle(fontSize: 11)),
                  selected: _negativeUp,
                  onSelected: (v) => setState(() => _negativeUp = v),
                ),
                FilterChip(
                  label: const Text(
                    'Exclude "Unknown"',
                    style: TextStyle(fontSize: 11),
                  ),
                  selected: _excludeUnknown,
                  onSelected: (v) => setState(() {
                    _excludeUnknown = v;
                    _invalidateCache();
                  }),
                ),
                // Epoch View Limits
                SizedBox(
                  width: 96,
                  child: TextField(
                    controller: _epochMinCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                      signed: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Epoch min',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (v) {
                      final n = double.tryParse(v);
                      if (n != null) _applyEpochView(n, _viewEpochMaxMs);
                    },
                  ),
                ),
                SizedBox(
                  width: 96,
                  child: TextField(
                    controller: _epochMaxCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                      signed: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Epoch max',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (v) {
                      final n = double.tryParse(v);
                      if (n != null) _applyEpochView(_viewEpochMinMs, n);
                    },
                  ),
                ),
                OutlinedButton(
                  onPressed: () {
                    final a = double.tryParse(_epochMinCtrl.text.trim());
                    final b = double.tryParse(_epochMaxCtrl.text.trim());
                    if (a != null && b != null) _applyEpochView(a, b);
                  },
                  child: const Text('Apply View', style: TextStyle(fontSize: 11)),
                ),
                ActionChip(
                  label: const Text('-200..800', style: TextStyle(fontSize: 10.5)),
                  onPressed: () => _applyEpochView(-200, 800),
                ),
                ActionChip(
                  label: const Text('Full', style: TextStyle(fontSize: 10.5)),
                  onPressed: _rawTimesMs.isEmpty
                      ? null
                      : () => _applyEpochView(_rawTimesMs.first, _rawTimesMs.last),
                ),
                // Live Re-baseline
                FilterChip(
                  label: const Text(
                    'Live Re-base',
                    style: TextStyle(fontSize: 11),
                  ),
                  selected: _liveRebaseline,
                  onSelected: (v) => setState(() {
                    _baseStartMs =
                        double.tryParse(_baseStartCtrl.text.trim()) ??
                        _baseStartMs;
                    _baseEndMs =
                        double.tryParse(_baseEndCtrl.text.trim()) ??
                        _baseEndMs;
                    _liveRebaseline = v;
                    _invalidateCache();
                  }),
                ),
                if (_liveRebaseline) ...[
                  SizedBox(
                    width: 84,
                    child: TextField(
                      controller: _baseStartCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Base lo',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (v) {
                        final n = double.tryParse(v);
                        if (n != null) {
                          setState(() {
                            _baseStartMs = n;
                            _invalidateCache();
                          });
                        }
                      },
                    ),
                  ),
                  SizedBox(
                    width: 84,
                    child: TextField(
                      controller: _baseEndCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Base hi',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (v) {
                        final n = double.tryParse(v);
                        if (n != null) {
                          setState(() {
                            _baseEndMs = n;
                            _invalidateCache();
                          });
                        }
                      },
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),

            // Row 2: Multi-Component Bar
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text(
                  'Components:',
                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
                ),
                for (var i = 0; i < _components.length; i++)
                  InputChip(
                    selected: i == _activeCompIdx,
                    avatar: CircleAvatar(
                      backgroundColor: _components[i].color,
                      radius: 6,
                    ),
                    label: Text(
                      '${_components[i].name} (${_components[i].windowStartMs.round()}–${_components[i].windowEndMs.round()} ms · ${_components[i].roiString})',
                      style: const TextStyle(fontSize: 11),
                    ),
                    onSelected: (_) => setState(() {
                      _activeCompIdx = i;
                      _syncActiveControllers();
                    }),
                    onDeleted: _components.length > 1
                        ? () => setState(() {
                            _components.removeAt(i);
                            if (_activeCompIdx >= _components.length) {
                              _activeCompIdx = _components.length - 1;
                            }
                            _syncActiveControllers();
                          })
                        : null,
                  ),
                OutlinedButton.icon(
                  onPressed: _addComponent,
                  icon: const Icon(Icons.add, size: 15),
                  label: const Text(
                    'Add Component',
                    style: TextStyle(fontSize: 11),
                  ),
                ),
                TextButton(
                  onPressed: _applyOddballPresets,
                  child: const Text(
                    'Load N100/P200/P300 Presets',
                    style: TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Main Waveform + Topo Selector
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: Column(
                      children: [
                        Expanded(
                          child: Container(
                            decoration: BoxDecoration(
                              color: const Color(0xFFF8F9FB),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: const Color(0xFFCBD5E1)),
                            ),
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                double xToMs(double dx) {
                                  const leftPad = 52.0;
                                  const rightPad = 16.0;
                                  final w = math.max(
                                    1.0,
                                    constraints.maxWidth - leftPad - rightPad,
                                  );
                                  final frac = ((dx - leftPad) / w).clamp(
                                    0.0,
                                    1.0,
                                  );
                                  return _viewEpochMinMs +
                                      frac *
                                          (_viewEpochMaxMs - _viewEpochMinMs);
                                }

                                return GestureDetector(
                                  onHorizontalDragStart: (d) {
                                    _dragStartMs = xToMs(d.localPosition.dx);
                                  },
                                  onHorizontalDragUpdate: (d) {
                                    if (_dragStartMs != null) {
                                      _setActiveWindow(
                                        _dragStartMs!,
                                        xToMs(d.localPosition.dx),
                                      );
                                    }
                                  },
                                  onHorizontalDragEnd: (_) =>
                                      _dragStartMs = null,
                                  child: CustomPaint(
                                    size: Size(
                                      constraints.maxWidth,
                                      constraints.maxHeight,
                                    ),
                                    painter: _GrandAveragePainter(
                                      rawTimesMs: _rawTimesMs,
                                      viewMinMs: _viewEpochMinMs,
                                      viewMaxMs: _viewEpochMaxMs,
                                      channels: _channels,
                                      selectedRoi: activeRoiSet,
                                      grandAvgs: grandAvgs,
                                      components: _components,
                                      activeCompIndex: _activeCompIdx,
                                      butterflyMode: _butterflyMode,
                                      negativeUp: _negativeUp,
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        // Active Component Editor Row
                        Wrap(
                          spacing: 10,
                          runSpacing: 6,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            SizedBox(
                              width: 115,
                              child: TextField(
                                controller: _compNameCtrl,
                                decoration: const InputDecoration(
                                  labelText: 'Component',
                                  isDense: true,
                                  border: OutlineInputBorder(),
                                ),
                                onChanged: (v) {
                                  final trimmed = v.trim();
                                  if (trimmed.isNotEmpty) {
                                    _components[_activeCompIdx] =
                                        _activeComp.copyWith(name: trimmed);
                                    setState(() {});
                                  }
                                },
                              ),
                            ),
                            SizedBox(
                              width: 155,
                              child: DropdownButtonFormField<double>(
                                initialValue: activeComp.polarity < 0 ? -1.0 : 1.0,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                  labelText: 'Polarity',
                                  border: OutlineInputBorder(),
                                  contentPadding: EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 10,
                                  ),
                                ),
                                items: const [
                                  DropdownMenuItem(
                                    value: 1.0,
                                    child: Text('Positive (+)'),
                                  ),
                                  DropdownMenuItem(
                                    value: -1.0,
                                    child: Text('Negative (−)'),
                                  ),
                                ],
                                onChanged: (v) {
                                  if (v != null) {
                                    _updateActiveComponent(
                                      activeComp.copyWith(polarity: v),
                                    );
                                  }
                                },
                              ),
                            ),
                            SizedBox(
                              width: 92,
                              child: TextField(
                                controller: _startCtrl,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  labelText: 'Win start ms',
                                  isDense: true,
                                  border: OutlineInputBorder(),
                                ),
                                onSubmitted: (v) {
                                  final val = double.tryParse(v);
                                  if (val != null) {
                                    _setActiveWindow(val, activeComp.windowEndMs);
                                  }
                                },
                              ),
                            ),
                            SizedBox(
                              width: 92,
                              child: TextField(
                                controller: _endCtrl,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  labelText: 'Win end ms',
                                  isDense: true,
                                  border: OutlineInputBorder(),
                                ),
                                onSubmitted: (v) {
                                  final val = double.tryParse(v);
                                  if (val != null) {
                                    _setActiveWindow(
                                      activeComp.windowStartMs,
                                      val,
                                    );
                                  }
                                },
                              ),
                            ),
                            SizedBox(
                              width: 240,
                              child: _rawTimesMs.isEmpty
                                  ? const SizedBox.shrink()
                                  : RangeSlider(
                                      min: _viewEpochMinMs,
                                      max: _viewEpochMaxMs,
                                      values: RangeValues(
                                        activeComp.windowStartMs.clamp(
                                          _viewEpochMinMs,
                                          _viewEpochMaxMs,
                                        ),
                                        activeComp.windowEndMs.clamp(
                                          _viewEpochMinMs,
                                          _viewEpochMaxMs,
                                        ),
                                      ),
                                      onChanged: (rv) =>
                                          _setActiveWindow(rv.start, rv.end),
                                    ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 290,
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8F9FB),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFCBD5E1)),
                      ),
                      child: Column(
                        children: [
                          TopoChannelSelector(
                            title:
                                '${activeComp.name} Topo (${activeComp.windowStartMs.round()}–${activeComp.windowEndMs.round()} ms)',
                            availableChannels: _channels,
                            selectedChannels: activeRoiSet,
                            channelValues: topoValues,
                            multiSelect: true,
                            size: 235,
                            onToggleChannel: (ch) {
                              final next = Set<String>.from(activeRoiSet);
                              if (next.contains(ch)) {
                                if (next.length > 1) next.remove(ch);
                              } else {
                                next.add(ch);
                              }
                              _updateActiveComponent(
                                activeComp.copyWith(roiChannels: next.toList()),
                              );
                            },
                          ),
                          const SizedBox(height: 6),
                          OutlinedButton.icon(
                            onPressed: () => _pickTopChannels(topoValues),
                            icon: const Icon(Icons.auto_awesome, size: 15),
                            label: const Text(
                              'Pick Top 3 Peak Channels',
                              style: TextStyle(fontSize: 11.5),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              '${activeComp.name} ROI (${activeRoiSet.length}): ${activeComp.roiString}',
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
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
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: () {
            final primary = _activeComp;
            final mergedExcluded = Set<String>.from(_excludedFiles);
            if (_excludeUnknown) {
              for (final f in widget.files) {
                final subj = '${f['subject'] ?? ''}';
                final grp =
                    (_participantGroups[subj] ?? '${f['group'] ?? ''}').trim();
                if (grp.isEmpty || grp.toLowerCase() == 'unknown') {
                  final p = '${f['path'] ?? ''}';
                  if (p.isNotEmpty) mergedExcluded.add(p);
                }
              }
            }
            Navigator.pop(
              context,
              GrandAverageSelection(
                roi: primary.roiString,
                startMs: primary.windowStartMs,
                endMs: primary.windowEndMs,
                polarity: primary.polarity,
                components: List<ErpComponentSpec>.from(_components),
                epochMinMs: _viewEpochMinMs,
                epochMaxMs: _viewEpochMaxMs,
                baselineStartMs: _liveRebaseline ? _baseStartMs : null,
                baselineEndMs: _liveRebaseline ? _baseEndMs : null,
                updatedParticipantGroups: Map<String, String>.from(
                  _participantGroups,
                ),
                updatedExcludedFiles: mergedExcluded,
              ),
            );
          },
          icon: const Icon(Icons.check, size: 16),
          label: Text(
            'Apply ${_components.length} Component(s) & View to Stage 3',
          ),
        ),
      ],
    );
  }
}

class _GrandAveragePainter extends CustomPainter {
  const _GrandAveragePainter({
    required this.rawTimesMs,
    required this.viewMinMs,
    required this.viewMaxMs,
    required this.channels,
    required this.selectedRoi,
    required this.grandAvgs,
    required this.components,
    required this.activeCompIndex,
    required this.butterflyMode,
    required this.negativeUp,
  });

  final List<double> rawTimesMs;
  final double viewMinMs;
  final double viewMaxMs;
  final List<String> channels;
  final Set<String> selectedRoi;
  final Map<String, List<List<double>>> grandAvgs;
  final List<ErpComponentSpec> components;
  final int activeCompIndex;
  final bool butterflyMode;
  final bool negativeUp;

  static const _palette = [
    Color(0xFF38BDF8),
    Color(0xFFF472B6),
    Color(0xFF34D399),
    Color(0xFFFBBF24),
    Color(0xFFA78BFA),
    Color(0xFFFB7185),
    Color(0xFF60A5FA),
    Color(0xFF2DD4BF),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (rawTimesMs.isEmpty || grandAvgs.isEmpty) return;

    final visibleIdx = <int>[];
    for (var i = 0; i < rawTimesMs.length; i++) {
      if (rawTimesMs[i] >= viewMinMs - 1e-6 &&
          rawTimesMs[i] <= viewMaxMs + 1e-6) {
        visibleIdx.add(i);
      }
    }
    if (visibleIdx.length < 2) return;

    const leftPad = 52.0;
    const rightPad = 16.0;
    const topPad = 26.0;
    const bottomPad = 28.0;
    final plotW = math.max(1.0, size.width - leftPad - rightPad);
    final plotH = math.max(1.0, size.height - topPad - bottomPad);

    final tMin = viewMinMs;
    final tMax = viewMaxMs;
    final tSpan = math.max(1e-6, tMax - tMin);
    double xOf(double ms) =>
        leftPad + (((ms - tMin) / tSpan).clamp(0.0, 1.0)) * plotW;

    final roiIndices = <int>[];
    final roiUpper = selectedRoi.map((e) => e.toUpperCase()).toSet();
    for (var i = 0; i < channels.length; i++) {
      if (roiUpper.contains(channels[i].toUpperCase())) roiIndices.add(i);
    }
    if (roiIndices.isEmpty && channels.isNotEmpty) roiIndices.add(0);

    var yMaxAbs = 1.0;
    final traces =
        <({String label, List<double> wave, Color color, double width})>[];

    if (butterflyMode) {
      final nT = visibleIdx.length;
      final nCh = channels.length;
      final avgGrid = List.generate(nCh, (_) => List<double>.filled(nT, 0.0));
      for (final grid in grandAvgs.values) {
        for (var ch = 0; ch < nCh; ch++) {
          for (var vi = 0; vi < nT; vi++) {
            avgGrid[ch][vi] += grid[ch][visibleIdx[vi]] / grandAvgs.length;
          }
        }
      }
      for (var ch = 0; ch < nCh; ch++) {
        final isRoi = roiIndices.contains(ch);
        for (final v in avgGrid[ch]) {
          yMaxAbs = math.max(yMaxAbs, v.abs());
        }
        traces.add((
          label: isRoi ? channels[ch] : '',
          wave: avgGrid[ch],
          color: isRoi
              ? const Color(0xFFEF4444)
              : const Color(0xFFE2E8F0),
          width: isRoi ? 2.0 : 1.0,
        ));
      }
    } else {
      var colorIdx = 0;
      for (final entry in grandAvgs.entries) {
        final nT = visibleIdx.length;
        final meanWave = List<double>.filled(nT, 0.0);
        for (final ch in roiIndices) {
          for (var vi = 0; vi < nT; vi++) {
            meanWave[vi] +=
                entry.value[ch][visibleIdx[vi]] / roiIndices.length;
          }
        }
        for (final v in meanWave) {
          yMaxAbs = math.max(yMaxAbs, v.abs());
        }
        traces.add((
          label: entry.key,
          wave: meanWave,
          color: _palette[colorIdx % _palette.length],
          width: 2.2,
        ));
        colorIdx++;
      }
    }
    yMaxAbs *= 1.15;

    double yOf(double uv) {
      final norm = (uv / yMaxAbs).clamp(-1.0, 1.0);
      final signed = negativeUp ? norm : -norm;
      return topPad + plotH * 0.5 * (1.0 + signed);
    }

    // Draw all defined component shaded windows
    for (var i = 0; i < components.length; i++) {
      final comp = components[i];
      if (comp.windowEndMs < tMin || comp.windowStartMs > tMax) continue;
      final xW0 = xOf(comp.windowStartMs);
      final xW1 = xOf(comp.windowEndMs);
      final isActive = i == activeCompIndex;
      canvas.drawRect(
        Rect.fromLTRB(xW0, topPad, xW1, topPad + plotH),
        Paint()..color = comp.color.withValues(alpha: isActive ? 0.22 : 0.10),
      );
      final winEdge = Paint()
        ..color = comp.color.withValues(alpha: isActive ? 0.9 : 0.45)
        ..strokeWidth = isActive ? 1.8 : 1.0;
      canvas.drawLine(Offset(xW0, topPad), Offset(xW0, topPad + plotH), winEdge);
      canvas.drawLine(Offset(xW1, topPad), Offset(xW1, topPad + plotH), winEdge);
      final tp = TextPainter(
        text: TextSpan(
          text: comp.name,
          style: TextStyle(
            color: comp.color,
            fontSize: 10,
            fontWeight: isActive ? FontWeight.bold : FontWeight.w500,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
        canvas,
        Offset(((xW0 + xW1) / 2 - tp.width / 2).clamp(leftPad, leftPad + plotW - tp.width), topPad + 2),
      );
    }

    // Axes (0 uV and 0 ms)
    final axisPaint = Paint()
      ..color = const Color(0xFFCBD5E1)
      ..strokeWidth = 1.0;
    canvas.drawLine(
      Offset(leftPad, yOf(0)),
      Offset(leftPad + plotW, yOf(0)),
      axisPaint,
    );
    if (0 >= tMin && 0 <= tMax) {
      canvas.drawLine(
        Offset(xOf(0), topPad),
        Offset(xOf(0), topPad + plotH),
        axisPaint,
      );
    }

    // Waveforms
    for (final tr in traces) {
      final path = Path();
      for (var vi = 0; vi < visibleIdx.length; vi++) {
        final ms = rawTimesMs[visibleIdx[vi]];
        final pt = Offset(xOf(ms), yOf(tr.wave[vi]));
        if (vi == 0) {
          path.moveTo(pt.dx, pt.dy);
        } else {
          path.lineTo(pt.dx, pt.dy);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = tr.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = tr.width,
      );
    }

    // Legend
    var lx = leftPad + 8;
    for (final tr in traces.where((t) => t.label.isNotEmpty).take(8)) {
      final tp = TextPainter(
        text: TextSpan(
          text: '● ${tr.label}',
          style: TextStyle(
            color: tr.color,
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      if (lx + tp.width < size.width - 16) {
        tp.paint(canvas, Offset(lx, 4));
        lx += tp.width + 12;
      }
    }

    // Non-overlapping clean time ticks
    final stepMs = tSpan <= 450 ? 100.0 : 200.0;
    final firstTick = (tMin / stepMs).ceil() * stepMs;
    final tickList = <double>[tMin];
    for (var t = firstTick; t < tMax; t += stepMs) {
      if ((t - tMin).abs() > 35 && (tMax - t).abs() > 35) tickList.add(t);
    }
    tickList.add(tMax);
    for (final ms in tickList) {
      final tp = TextPainter(
        text: TextSpan(
          text: '${ms.round()}',
          style: const TextStyle(color: Color(0xFF64748B), fontSize: 10),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
        canvas,
        Offset(xOf(ms) - tp.width / 2, topPad + plotH + 6),
      );
    }

    // Y ticks
    for (final uv in [yMaxAbs, 0.0, -yMaxAbs]) {
      final tp = TextPainter(
        text: TextSpan(
          text: '${uv.toStringAsFixed(1)}µV',
          style: const TextStyle(color: Color(0xFF64748B), fontSize: 9.5),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(4, yOf(uv) - tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant _GrandAveragePainter oldDelegate) => true;
}
