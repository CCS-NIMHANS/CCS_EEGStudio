import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'workbench_figures.dart';
import 'topo_channel_selector.dart';

class GrandAverageSelection {
  const GrandAverageSelection({
    required this.roi,
    required this.startMs,
    required this.endMs,
    required this.polarity,
  });

  final String roi;
  final double startMs;
  final double endMs;
  final double polarity;
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
  });

  final List<Map<String, dynamic>> files;
  final Map<String, String> participantGroups;
  final String initialRoi;
  final double initialStartMs;
  final double initialEndMs;
  final double initialPolarity;
  final bool negativeUp;

  static Future<GrandAverageSelection?> show(
    BuildContext context, {
    required List<Map<String, dynamic>> files,
    required Map<String, String> participantGroups,
    required String initialRoi,
    required double initialStartMs,
    required double initialEndMs,
    required double initialPolarity,
    bool negativeUp = true,
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
  late double _polarity;
  late double _winStartMs;
  late double _winEndMs;
  late Set<String> _selectedRoi;

  late final TextEditingController _startCtrl;
  late final TextEditingController _endCtrl;

  late final List<double> _timesMs;
  late final List<String> _channels;
  late final List<String> _conditions;
  late final List<String> _groups;

  double? _dragStartMs;

  @override
  void initState() {
    super.initState();
    _negativeUp = widget.negativeUp;
    _polarity = widget.initialPolarity;
    _winStartMs = widget.initialStartMs;
    _winEndMs = widget.initialEndMs;
    _startCtrl = TextEditingController(text: _winStartMs.toStringAsFixed(0));
    _endCtrl = TextEditingController(text: _winEndMs.toStringAsFixed(0));

    _selectedRoi = widget.initialRoi
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet();

    final first = widget.files.first;
    final rawTimes = erpNumbers(first['times']);
    _timesMs = rawTimes.map((t) => t * 1000.0).toList();
    _channels = (first['labels'] as List? ?? []).map((e) => '$e').toList();
    if (_selectedRoi.isEmpty && _channels.isNotEmpty) {
      _selectedRoi.add(_channels.first);
    }

    final condSet = <String>{};
    final grpSet = <String>{};
    for (final f in widget.files) {
      final subj = '${f['subject'] ?? ''}';
      final grp = widget.participantGroups[subj] ?? '${f['group'] ?? ''}';
      if (grp.trim().isNotEmpty) grpSet.add(grp.trim());
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
    _groups = grpSet.isEmpty ? ['All'] : (grpSet.toList()..sort());

    if (_timesMs.isNotEmpty) {
      _winStartMs = _winStartMs.clamp(_timesMs.first, _timesMs.last);
      _winEndMs = _winEndMs.clamp(_timesMs.first, _timesMs.last);
      if (_winEndMs <= _winStartMs) {
        _winStartMs = _timesMs.first;
        _winEndMs = _timesMs.last;
      }
      _startCtrl.text = _winStartMs.toStringAsFixed(0);
      _endCtrl.text = _winEndMs.toStringAsFixed(0);
    }
  }

  @override
  void dispose() {
    _startCtrl.dispose();
    _endCtrl.dispose();
    super.dispose();
  }

  void _setWindow(double a, double b) {
    final lo = math.min(a, b).clamp(_timesMs.first, _timesMs.last);
    final hi = math.max(a, b).clamp(_timesMs.first, _timesMs.last);
    if ((hi - lo) < 5) return;
    setState(() {
      _winStartMs = lo;
      _winEndMs = hi;
      _startCtrl.text = lo.toStringAsFixed(0);
      _endCtrl.text = hi.toStringAsFixed(0);
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
  Map<String, List<List<double>>> _computeGrandAverages() {
    final nT = _timesMs.length;
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
      final subj = '${f['subject'] ?? ''}';
      final grp =
          (widget.participantGroups[subj] ?? '${f['group'] ?? ''}').trim();
      final effectiveGrp = grp.isEmpty ? 'Unassigned' : grp;
      final labels = (f['labels'] as List? ?? []).map((e) => '$e').toList();

      for (var chIdx = 0; chIdx < nCh; chIdx++) {
        final fChIdx = labels.indexWhere(
          (l) => l.toUpperCase() == _channels[chIdx].toUpperCase(),
        );
        if (fChIdx < 0) continue;

        for (final cond in _conditions) {
          final wave = _extractCondWave(f, cond, fChIdx);
          if (wave == null) continue;
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
    return accum;
  }

  /// Computes mean amplitude per channel inside [_winStartMs, _winEndMs]
  /// across all traces for the live scalp topography.
  Map<String, double> _computeWindowTopo(
    Map<String, List<List<double>>> grandAvgs,
  ) {
    final out = <String, double>{};
    if (grandAvgs.isEmpty || _timesMs.isEmpty) return out;
    final tIndices = <int>[];
    for (var i = 0; i < _timesMs.length; i++) {
      if (_timesMs[i] >= _winStartMs && _timesMs[i] <= _winEndMs) {
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
    final entries = topoValues.entries.toList()
      ..sort((a, b) {
        final scoreA = _polarity < 0 ? -a.value : a.value;
        final scoreB = _polarity < 0 ? -b.value : b.value;
        return scoreB.compareTo(scoreA);
      });
    setState(() {
      _selectedRoi = entries.take(count).map((e) => e.key).toSet();
    });
  }

  @override
  Widget build(BuildContext context) {
    final grandAvgs = _computeGrandAverages();
    final topoValues = _computeWindowTopo(grandAvgs);

    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.insights, size: 20, color: Colors.amberAccent),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'Grand Average Localizer (Unbiased Time Window & ROI)',
            ),
          ),
          Text(
            '${widget.files.length} recording(s) · ${_groups.length} group(s) · ${_conditions.length} condition(s)',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      content: SizedBox(
        width: 980,
        height: 580,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
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
                  label: const Text('Butterfly + GFP', style: TextStyle(fontSize: 11)),
                  selected: _butterflyMode,
                  onSelected: (v) => setState(() => _butterflyMode = v),
                ),
                FilterChip(
                  label: const Text('Neg Up', style: TextStyle(fontSize: 11)),
                  selected: _negativeUp,
                  onSelected: (v) => setState(() => _negativeUp = v),
                ),
                SizedBox(
                  width: 120,
                  child: DropdownButtonFormField<double>(
                    initialValue: _polarity,
                    isDense: true,
                    decoration: const InputDecoration(
                      labelText: 'Polarity',
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                    ),
                    items: const [
                      DropdownMenuItem(value: 1.0, child: Text('Positive (+)')),
                      DropdownMenuItem(value: -1.0, child: Text('Negative (−)')),
                    ],
                    onChanged: (v) {
                      if (v != null) setState(() => _polarity = v);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
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
                              color: const Color(0xFF0F172A),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.white12),
                            ),
                            child: LayoutBuilder(
                              builder: (context, constraints) {
                                double xToMs(double dx) {
                                  const leftPad = 48.0;
                                  const rightPad = 16.0;
                                  final w = math.max(
                                    1.0,
                                    constraints.maxWidth - leftPad - rightPad,
                                  );
                                  final frac = ((dx - leftPad) / w).clamp(
                                    0.0,
                                    1.0,
                                  );
                                  return _timesMs.first +
                                      frac * (_timesMs.last - _timesMs.first);
                                }

                                return GestureDetector(
                                  onHorizontalDragStart: (d) {
                                    _dragStartMs = xToMs(d.localPosition.dx);
                                  },
                                  onHorizontalDragUpdate: (d) {
                                    if (_dragStartMs != null) {
                                      _setWindow(
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
                                      timesMs: _timesMs,
                                      channels: _channels,
                                      selectedRoi: _selectedRoi,
                                      grandAvgs: grandAvgs,
                                      winStartMs: _winStartMs,
                                      winEndMs: _winEndMs,
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
                        Row(
                          children: [
                            const Text(
                              'Drag on waveform or adjust window (ms):',
                              style: TextStyle(fontSize: 11.5),
                            ),
                            const SizedBox(width: 10),
                            SizedBox(
                              width: 90,
                              child: TextField(
                                controller: _startCtrl,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  labelText: 'Start ms',
                                  isDense: true,
                                  border: OutlineInputBorder(),
                                ),
                                onSubmitted: (v) {
                                  final val = double.tryParse(v);
                                  if (val != null) _setWindow(val, _winEndMs);
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 90,
                              child: TextField(
                                controller: _endCtrl,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  labelText: 'End ms',
                                  isDense: true,
                                  border: OutlineInputBorder(),
                                ),
                                onSubmitted: (v) {
                                  final val = double.tryParse(v);
                                  if (val != null) _setWindow(_winStartMs, val);
                                },
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _timesMs.isEmpty
                                  ? const SizedBox.shrink()
                                  : RangeSlider(
                                      min: _timesMs.first,
                                      max: _timesMs.last,
                                      values: RangeValues(
                                        _winStartMs,
                                        _winEndMs,
                                      ),
                                      onChanged: (rv) =>
                                          _setWindow(rv.start, rv.end),
                                    ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 280,
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F172A),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Column(
                        children: [
                          TopoChannelSelector(
                            title:
                                'Window Topo (${_winStartMs.round()}–${_winEndMs.round()} ms)',
                            availableChannels: _channels,
                            selectedChannels: _selectedRoi,
                            channelValues: topoValues,
                            multiSelect: true,
                            size: 230,
                            onToggleChannel: (ch) {
                              setState(() {
                                if (_selectedRoi.contains(ch)) {
                                  if (_selectedRoi.length > 1) {
                                    _selectedRoi.remove(ch);
                                  }
                                } else {
                                  _selectedRoi.add(ch);
                                }
                              });
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
                              'Selected ROI (${_selectedRoi.length}): ${_selectedRoi.join(', ')}',
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
            Navigator.pop(
              context,
              GrandAverageSelection(
                roi: _selectedRoi.join(', '),
                startMs: _winStartMs,
                endMs: _winEndMs,
                polarity: _polarity,
              ),
            );
          },
          icon: const Icon(Icons.check, size: 16),
          label: const Text('Apply ROI & Window to Stage 3'),
        ),
      ],
    );
  }
}

class _GrandAveragePainter extends CustomPainter {
  const _GrandAveragePainter({
    required this.timesMs,
    required this.channels,
    required this.selectedRoi,
    required this.grandAvgs,
    required this.winStartMs,
    required this.winEndMs,
    required this.butterflyMode,
    required this.negativeUp,
  });

  final List<double> timesMs;
  final List<String> channels;
  final Set<String> selectedRoi;
  final Map<String, List<List<double>>> grandAvgs;
  final double winStartMs;
  final double winEndMs;
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
    if (timesMs.isEmpty || grandAvgs.isEmpty) return;

    const leftPad = 48.0;
    const rightPad = 16.0;
    const topPad = 24.0;
    const bottomPad = 28.0;
    final plotW = math.max(1.0, size.width - leftPad - rightPad);
    final plotH = math.max(1.0, size.height - topPad - bottomPad);

    final tMin = timesMs.first;
    final tMax = timesMs.last;
    final tSpan = math.max(1e-6, tMax - tMin);
    double xOf(double ms) => leftPad + ((ms - tMin) / tSpan) * plotW;

    // Collect waveforms to plot and determine y range
    final roiIndices = <int>[];
    final roiUpper = selectedRoi.map((e) => e.toUpperCase()).toSet();
    for (var i = 0; i < channels.length; i++) {
      if (roiUpper.contains(channels[i].toUpperCase())) roiIndices.add(i);
    }
    if (roiIndices.isEmpty && channels.isNotEmpty) roiIndices.add(0);

    var yMaxAbs = 1.0;
    final traces = <({String label, List<double> wave, Color color, double width})>[];

    if (butterflyMode) {
      // Average across grandAvgs keys for butterfly channels, plus highlight ROI mean
      final nT = timesMs.length;
      final nCh = channels.length;
      final avgGrid = List.generate(nCh, (_) => List<double>.filled(nT, 0.0));
      for (final grid in grandAvgs.values) {
        for (var ch = 0; ch < nCh; ch++) {
          for (var t = 0; t < nT; t++) {
            avgGrid[ch][t] += grid[ch][t] / grandAvgs.length;
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
              : Colors.white.withValues(alpha: 0.18),
          width: isRoi ? 2.0 : 1.0,
        ));
      }
    } else {
      var colorIdx = 0;
      for (final entry in grandAvgs.entries) {
        final nT = timesMs.length;
        final meanWave = List<double>.filled(nT, 0.0);
        for (final ch in roiIndices) {
          for (var t = 0; t < nT; t++) {
            meanWave[t] += entry.value[ch][t] / roiIndices.length;
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

    // Measurement window shading
    final xW0 = xOf(winStartMs);
    final xW1 = xOf(winEndMs);
    canvas.drawRect(
      Rect.fromLTRB(xW0, topPad, xW1, topPad + plotH),
      Paint()..color = const Color(0xFFF59E0B).withValues(alpha: 0.18),
    );
    final winEdge = Paint()
      ..color = const Color(0xFFF59E0B).withValues(alpha: 0.7)
      ..strokeWidth = 1.2;
    canvas.drawLine(Offset(xW0, topPad), Offset(xW0, topPad + plotH), winEdge);
    canvas.drawLine(Offset(xW1, topPad), Offset(xW1, topPad + plotH), winEdge);

    // Axes (0 uV and 0 ms)
    final axisPaint = Paint()
      ..color = Colors.white24
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

    // Draw waveforms
    for (final tr in traces) {
      final path = Path();
      for (var i = 0; i < timesMs.length; i++) {
        final pt = Offset(xOf(timesMs[i]), yOf(tr.wave[i]));
        if (i == 0) {
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

    // Time ticks
    for (final ms in [tMin, 0.0, winStartMs, winEndMs, tMax]) {
      if (ms < tMin || ms > tMax) continue;
      final tp = TextPainter(
        text: TextSpan(
          text: '${ms.round()}',
          style: const TextStyle(color: Colors.white60, fontSize: 10),
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
          style: const TextStyle(color: Colors.white60, fontSize: 9.5),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(4, yOf(uv) - tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant _GrandAveragePainter oldDelegate) => true;
}
