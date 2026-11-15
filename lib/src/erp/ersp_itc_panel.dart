import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../recording_save_dialog.dart';
import 'workbench_service.dart';

/// Interactive ERSP (dB) and ITC (0–1) time-frequency workspace with
/// permutation masking, trial-level rejection/inclusion, and CSV export.
class ErspItcPanel extends StatefulWidget {
  const ErspItcPanel({
    super.key,
    required this.recordingPath,
    required this.labels,
    required this.roiLabels,
    required this.conditionATrials,
    required this.conditionBTrials,
    required this.conditionAName,
    required this.conditionBName,
    this.epochTminMs,
    this.outputDirectory,
  });

  final String? recordingPath;
  final List<String> labels;
  final List<String> roiLabels;
  final List<int> conditionATrials;
  final List<int> conditionBTrials;
  final String conditionAName;
  final String conditionBName;
  final double? epochTminMs;
  final String? outputDirectory;

  @override
  State<ErspItcPanel> createState() => _ErspItcPanelState();
}

class _ErspItcPanelState extends State<ErspItcPanel> {
  final ErpWorkbenchService _service = ErpWorkbenchService();
  String _selectedChannel = 'ROI';
  String _viewMode = 'diff'; // 'a', 'b', 'diff'
  bool _maskSignificant = false;
  bool _busy = false;
  String _status = '';
  Map<String, dynamic>? _result;
  final Set<int> _excludedTrials = {};

  final TextEditingController _fminCtrl = TextEditingController(text: '2');
  final TextEditingController _fmaxCtrl = TextEditingController(text: '40');
  final TextEditingController _baseStartCtrl = TextEditingController(
    text: '-200',
  );
  final TextEditingController _baseEndCtrl = TextEditingController(text: '0');

  Offset? _hoverErsp;
  Offset? _hoverItc;

  @override
  void initState() {
    super.initState();
    if (widget.roiLabels.isEmpty && widget.labels.isNotEmpty) {
      _selectedChannel = widget.labels.first;
    }
    if (widget.conditionBTrials.isEmpty) {
      _viewMode = 'a';
    }
  }

  @override
  void dispose() {
    _fminCtrl.dispose();
    _fmaxCtrl.dispose();
    _baseStartCtrl.dispose();
    _baseEndCtrl.dispose();
    super.dispose();
  }

  Future<void> _compute() async {
    final path = widget.recordingPath;
    if (path == null || path.isEmpty || _busy) return;
    final activeA = widget.conditionATrials
        .where((i) => !_excludedTrials.contains(i))
        .toList();
    final activeB = widget.conditionBTrials
        .where((i) => !_excludedTrials.contains(i))
        .toList();
    if (activeA.isEmpty) {
      setState(() => _status = 'Include at least 1 trial in Condition A.');
      return;
    }
    setState(() {
      _busy = true;
      _status = 'Computing Morlet wavelet ERSP & ITC + permutation stats…';
    });
    try {
      final res = await _service.runErspItc({
        'recording_path': path,
        'channel_name': _selectedChannel,
        'roi_channels': widget.roiLabels,
        'condition_a_trials': activeA,
        'condition_b_trials': activeB,
        if (widget.epochTminMs != null) 'epoch_tmin_ms': widget.epochTminMs,
        'fmin_hz': double.tryParse(_fminCtrl.text.trim()) ?? 2.0,
        'fmax_hz': double.tryParse(_fmaxCtrl.text.trim()) ?? 40.0,
        'n_freqs': 24,
        'baseline_start_ms': double.tryParse(_baseStartCtrl.text.trim()) ?? -200.0,
        'baseline_end_ms': double.tryParse(_baseEndCtrl.text.trim()) ?? 0.0,
        'n_perm': 200,
      });
      if (!mounted) return;
      setState(() {
        _result = res;
        if (activeB.isEmpty && _viewMode != 'a') _viewMode = 'a';
        _status =
            'ERSP & ITC ready (${res['n_trials_a']} ${widget.conditionAName}, ${res['n_trials_b']} ${widget.conditionBName} trials).';
      });
    } catch (e) {
      if (mounted) setState(() => _status = 'ERSP/ITC error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportCsv() async {
    final res = _result;
    if (res == null) return;
    final initialDir =
        widget.outputDirectory ??
        (widget.recordingPath != null
            ? File(widget.recordingPath!).parent.path
            : Directory.current.path);
    final path = await saveRecordingDialog(
      context,
      dialogTitle: 'Export ERSP & ITC Time-Frequency Table (CSV)',
      initialDirectory: initialDir,
      fileName: 'ersp_itc_table.csv',
    );
    if (path == null || !mounted) return;

    final times = (res['times_ms'] as List).cast<num>();
    final freqs = (res['freqs_hz'] as List).cast<num>();
    final erspA = (res['ersp_a_db'] as List).cast<num>();
    final itcA = (res['itc_a'] as List).cast<num>();
    final erspB = (res['ersp_b_db'] as List?)?.cast<num>();
    final itcB = (res['itc_b'] as List?)?.cast<num>();
    final erspDiff = (res['ersp_diff_db'] as List?)?.cast<num>();
    final itcDiff = (res['itc_diff'] as List?)?.cast<num>();
    final pErsp = (res['p_values_ersp'] as List).cast<num>();
    final pItc = (res['p_values_itc'] as List).cast<num>();

    final buf = StringBuffer()
      ..writeln(
        'channel,freq_hz,time_ms,ersp_a_db,itc_a,ersp_b_db,itc_b,ersp_diff_db,itc_diff,p_ersp,p_itc',
      );
    final nt = times.length;
    for (var fi = 0; fi < freqs.length; fi++) {
      for (var ti = 0; ti < nt; ti++) {
        final idx = fi * nt + ti;
        buf.writeln(
          '${res['channel']},${freqs[fi].toStringAsFixed(2)},${times[ti].toStringAsFixed(1)},'
          '${erspA[idx].toStringAsFixed(5)},${itcA[idx].toStringAsFixed(5)},'
          '${erspB != null ? erspB[idx].toStringAsFixed(5) : ""},${itcB != null ? itcB[idx].toStringAsFixed(5) : ""},'
          '${erspDiff != null ? erspDiff[idx].toStringAsFixed(5) : ""},${itcDiff != null ? itcDiff[idx].toStringAsFixed(5) : ""},'
          '${pErsp[idx].toStringAsFixed(5)},${pItc[idx].toStringAsFixed(5)}',
        );
      }
    }
    await File(path).writeAsString(buf.toString());

    // Also write per-trial summary table
    final trialPath = path.replaceFirst(RegExp(r'\.csv$', caseSensitive: false), '_trials.csv');
    final tBuf = StringBuffer()
      ..writeln('trial_index,condition,included,mean_ersp_db,itc_alignment');
    final idxA = (res['trial_indices_a'] as List? ?? []).cast<int>();
    final powA = (res['trial_power_a_db'] as List? ?? []).cast<num>();
    final itcTrA = (res['trial_itc_a'] as List? ?? []).cast<num>();
    for (var k = 0; k < idxA.length; k++) {
      final tid = idxA[k];
      tBuf.writeln(
        '${tid + 1},${widget.conditionAName},${!_excludedTrials.contains(tid)},${powA[k].toStringAsFixed(4)},${itcTrA[k].toStringAsFixed(4)}',
      );
    }
    final idxB = (res['trial_indices_b'] as List? ?? []).cast<int>();
    final powB = (res['trial_power_b_db'] as List? ?? []).cast<num>();
    final itcTrB = (res['trial_itc_b'] as List? ?? []).cast<num>();
    for (var k = 0; k < idxB.length; k++) {
      final tid = idxB[k];
      tBuf.writeln(
        '${tid + 1},${widget.conditionBName},${!_excludedTrials.contains(tid)},${powB[k].toStringAsFixed(4)},${itcTrB[k].toStringAsFixed(4)}',
      );
    }
    await File(trialPath).writeAsString(tBuf.toString());

    if (mounted) {
      setState(() => _status = 'Exported ERSP/ITC CSV & trial table to $path');
    }
  }

  void _toggleTrial(int trialIndex) {
    setState(() {
      if (_excludedTrials.contains(trialIndex)) {
        _excludedTrials.remove(trialIndex);
      } else {
        _excludedTrials.add(trialIndex);
      }
    });
    _compute();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.recordingPath == null) {
      return const Center(
        child: Text('Load or run an epoched ERP recording to compute ERSP & ITC.'),
      );
    }

    final res = _result;
    final hasB = res != null && res['ersp_b_db'] != null;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            color: const Color(0xFF1E293B),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: 150,
                    child: DropdownButtonFormField<String>(
                      value: _selectedChannel,
                      isDense: true,
                      decoration: const InputDecoration(
                        labelText: 'Channel / ROI',
                        isDense: true,
                      ),
                      items: [
                        if (widget.roiLabels.isNotEmpty)
                          DropdownMenuItem(
                            value: 'ROI',
                            child: Text('ROI (${widget.roiLabels.join(",")})'),
                          ),
                        for (final ch in widget.labels)
                          DropdownMenuItem(value: ch, child: Text(ch)),
                      ],
                      onChanged: (v) {
                        if (v != null) setState(() => _selectedChannel = v);
                      },
                    ),
                  ),
                  SizedBox(
                    width: 72,
                    child: TextField(
                      controller: _fminCtrl,
                      decoration: const InputDecoration(labelText: 'Min Hz', isDense: true),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  SizedBox(
                    width: 72,
                    child: TextField(
                      controller: _fmaxCtrl,
                      decoration: const InputDecoration(labelText: 'Max Hz', isDense: true),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  SizedBox(
                    width: 82,
                    child: TextField(
                      controller: _baseStartCtrl,
                      decoration: const InputDecoration(labelText: 'Base start', isDense: true),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  SizedBox(
                    width: 82,
                    child: TextField(
                      controller: _baseEndCtrl,
                      decoration: const InputDecoration(labelText: 'Base end', isDense: true),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: _busy ? null : _compute,
                    icon: const Icon(Icons.waves, size: 16),
                    label: Text(res == null ? 'Compute ERSP & ITC' : 'Recompute'),
                  ),
                  if (res != null)
                    OutlinedButton.icon(
                      onPressed: _exportCsv,
                      icon: const Icon(Icons.download, size: 16),
                      label: const Text('Export CSV'),
                    ),
                  if (_excludedTrials.isNotEmpty)
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () {
                              setState(() => _excludedTrials.clear());
                              _compute();
                            },
                      child: Text('Restore ${_excludedTrials.length} excluded'),
                    ),
                ],
              ),
            ),
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_status.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(_status, style: const TextStyle(fontSize: 12, color: Colors.white70)),
            ),
          if (res != null) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SegmentedButton<String>(
                  segments: [
                    ButtonSegment(value: 'a', label: Text(widget.conditionAName)),
                    if (hasB) ...[
                      ButtonSegment(value: 'b', label: Text(widget.conditionBName)),
                      const ButtonSegment(value: 'diff', label: Text('Difference (B − A)')),
                    ],
                  ],
                  selected: {_viewMode},
                  onSelectionChanged: (v) => setState(() => _viewMode = v.first),
                ),
                FilterChip(
                  label: const Text('Mask p < 0.05 (permutation)'),
                  selected: _maskSignificant,
                  onSelected: (v) => setState(() => _maskSignificant = v),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _buildHeatmapCard(
                    title: 'ERSP (dB vs baseline)',
                    times: (res['times_ms'] as List).cast<num>().map((e) => e.toDouble()).toList(),
                    freqs: (res['freqs_hz'] as List).cast<num>().map((e) => e.toDouble()).toList(),
                    values: _pickGrid(res, isItc: false),
                    pValues: (res['p_values_ersp'] as List).cast<num>().map((e) => e.toDouble()).toList(),
                    isItc: false,
                    hover: _hoverErsp,
                    onHover: (pos) => setState(() => _hoverErsp = pos),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildHeatmapCard(
                    title: 'ITC (Inter-Trial Coherence 0–1)',
                    times: (res['times_ms'] as List).cast<num>().map((e) => e.toDouble()).toList(),
                    freqs: (res['freqs_hz'] as List).cast<num>().map((e) => e.toDouble()).toList(),
                    values: _pickGrid(res, isItc: true),
                    pValues: (res['p_values_itc'] as List).cast<num>().map((e) => e.toDouble()).toList(),
                    isItc: true,
                    hover: _hoverItc,
                    onHover: (pos) => setState(() => _hoverItc = pos),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _buildInteractiveTrialStrip(res),
          ],
        ],
      ),
    );
  }

  List<double> _pickGrid(Map<String, dynamic> res, {required bool isItc}) {
    final key = isItc
        ? (_viewMode == 'b' && res['itc_b'] != null
              ? 'itc_b'
              : (_viewMode == 'diff' && res['itc_diff'] != null
                    ? 'itc_diff'
                    : 'itc_a'))
        : (_viewMode == 'b' && res['ersp_b_db'] != null
              ? 'ersp_b_db'
              : (_viewMode == 'diff' && res['ersp_diff_db'] != null
                    ? 'ersp_diff_db'
                    : 'ersp_a_db'));
    return (res[key] as List).cast<num>().map((e) => e.toDouble()).toList();
  }

  Widget _buildHeatmapCard({
    required String title,
    required List<double> times,
    required List<double> freqs,
    required List<double> values,
    required List<double> pValues,
    required bool isItc,
    required Offset? hover,
    required ValueChanged<Offset?> onHover,
  }) {
    return Container(
      height: 290,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFCBD5E1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 12,
              color: Color(0xFF0F172A),
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: MouseRegion(
              onHover: (e) => onHover(e.localPosition),
              onExit: (_) => onHover(null),
              child: CustomPaint(
                painter: _TimeFreqPainter(
                  times: times,
                  freqs: freqs,
                  values: values,
                  pValues: pValues,
                  maskSignificant: _maskSignificant,
                  diverging: !isItc || _viewMode == 'diff',
                  unit: isItc ? '' : ' dB',
                  hoverPos: hover,
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInteractiveTrialStrip(Map<String, dynamic> res) {
    final idxA = (res['trial_indices_a'] as List? ?? []).cast<int>();
    final powA = (res['trial_power_a_db'] as List? ?? []).cast<num>();
    final itcA = (res['trial_itc_a'] as List? ?? []).cast<num>();
    final idxB = (res['trial_indices_b'] as List? ?? []).cast<int>();
    final powB = (res['trial_power_b_db'] as List? ?? []).cast<num>();
    final itcB = (res['trial_itc_b'] as List? ?? []).cast<num>();

    final entries = <({int idx, String cond, double pow, double itc})>[
      for (var k = 0; k < idxA.length; k++)
        (
          idx: idxA[k],
          cond: widget.conditionAName,
          pow: powA[k].toDouble(),
          itc: itcA[k].toDouble(),
        ),
      for (var k = 0; k < idxB.length; k++)
        (
          idx: idxB[k],
          cond: widget.conditionBName,
          pow: powB[k].toDouble(),
          itc: itcB[k].toDouble(),
        ),
    ]..sort((a, b) => a.idx.compareTo(b.idx));

    return Card(
      color: const Color(0xFF0F172A),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Interactive Trial Inspector (click any trial bar to exclude/include and recompute ERSP & ITC)',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final tr in entries)
                  Tooltip(
                    message:
                        'Trial ${tr.idx + 1} (${tr.cond})\nERSP: ${tr.pow.toStringAsFixed(2)} dB · ITC align: ${tr.itc.toStringAsFixed(2)}\nClick to ${_excludedTrials.contains(tr.idx) ? "reinstate" : "exclude"}',
                    child: InkWell(
                      onTap: _busy ? null : () => _toggleTrial(tr.idx),
                      child: Container(
                        width: 24,
                        height: 28,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: _excludedTrials.contains(tr.idx)
                              ? Colors.red.shade900
                              : (tr.cond == widget.conditionAName
                                    ? const Color(0xFF1E3A8A)
                                    : const Color(0xFF991B1B)),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color: _excludedTrials.contains(tr.idx)
                                ? Colors.redAccent
                                : Colors.white24,
                          ),
                        ),
                        child: Text(
                          '${tr.idx + 1}',
                          style: TextStyle(
                            fontSize: 9,
                            decoration: _excludedTrials.contains(tr.idx)
                                ? TextDecoration.lineThrough
                                : null,
                            color: _excludedTrials.contains(tr.idx)
                                ? Colors.white54
                                : Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TimeFreqPainter extends CustomPainter {
  _TimeFreqPainter({
    required this.times,
    required this.freqs,
    required this.values,
    required this.pValues,
    required this.maskSignificant,
    required this.diverging,
    required this.unit,
    this.hoverPos,
  });

  final List<double> times;
  final List<double> freqs;
  final List<double> values;
  final List<double> pValues;
  final bool maskSignificant;
  final bool diverging;
  final String unit;
  final Offset? hoverPos;

  @override
  void paint(Canvas canvas, Size size) {
    final ax = Rect.fromLTRB(44, 10, size.width - 14, size.height - 28);
    if (ax.width <= 0 || ax.height <= 0 || times.isEmpty || freqs.isEmpty) {
      return;
    }

    final nf = freqs.length;
    final nt = times.length;
    var maxAbs = 0.01;
    for (final v in values) {
      if (v.isFinite && v.abs() > maxAbs) maxAbs = v.abs();
    }
    if (!diverging) maxAbs = math.max(0.2, maxAbs);

    final cw = ax.width / nt;
    final ch = ax.height / nf;

    for (var fi = 0; fi < nf; fi++) {
      // Low freq at bottom, high freq at top
      final y = ax.bottom - (fi + 1) * ch;
      for (var ti = 0; ti < nt; ti++) {
        final idx = fi * nt + ti;
        final v = idx < values.length ? values[idx] : 0.0;
        final p = idx < pValues.length ? pValues[idx] : 1.0;
        Color col;
        if (maskSignificant && p >= 0.05) {
          col = const Color(0xFFE2E8F0);
        } else if (diverging) {
          final norm = (v / maxAbs).clamp(-1.0, 1.0);
          col = norm >= 0
              ? Color.lerp(Colors.white, const Color(0xFFDC2626), norm)!
              : Color.lerp(Colors.white, const Color(0xFF2563EB), -norm)!;
        } else {
          final norm = (v / maxAbs).clamp(0.0, 1.0);
          col = Color.lerp(const Color(0xFFF8FAFC), const Color(0xFF7C3AED), norm)!;
        }
        canvas.drawRect(
          Rect.fromLTWH(ax.left + ti * cw, y, cw + 0.6, ch + 0.6),
          Paint()..color = col,
        );
      }
    }

    // 0 ms vertical dashed/solid line
    if (times.first <= 0 && times.last >= 0) {
      final x0 =
          ax.left + (0 - times.first) / (times.last - times.first) * ax.width;
      canvas.drawLine(
        Offset(x0, ax.top),
        Offset(x0, ax.bottom),
        Paint()
          ..color = const Color(0xFF0F172A)
          ..strokeWidth = 1.4,
      );
    }

    canvas.drawRect(
      ax,
      Paint()
        ..color = const Color(0xFF94A3B8)
        ..style = PaintingStyle.stroke,
    );

    void drawTxt(String s, Offset pos) {
      final tp = TextPainter(
        text: TextSpan(
          text: s,
          style: const TextStyle(
            color: Color(0xFF334155),
            fontSize: 10,
            fontFamily: 'DejaVuSans',
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, pos);
    }

    drawTxt('${freqs.last.round()} Hz', Offset(2, ax.top));
    drawTxt('${freqs.first.round()} Hz', Offset(2, ax.bottom - 12));
    for (var i = 0; i <= 4; i++) {
      final t = times.first + (times.last - times.first) * i / 4;
      drawTxt('${t.round()}', Offset(ax.left + ax.width * i / 4 - 10, ax.bottom + 6));
    }

    if (hoverPos != null && ax.contains(hoverPos!)) {
      final ti = ((hoverPos!.dx - ax.left) / ax.width * nt)
          .floor()
          .clamp(0, nt - 1);
      final fi = ((ax.bottom - hoverPos!.dy) / ax.height * nf)
          .floor()
          .clamp(0, nf - 1);
      final idx = fi * nt + ti;
      final v = values[idx];
      final p = pValues[idx];
      drawTxt(
        '${times[ti].round()} ms · ${freqs[fi].toStringAsFixed(1)} Hz · ${v.toStringAsFixed(2)}$unit (p=${p.toStringAsFixed(3)})',
        Offset(ax.left + 6, ax.top + 4),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TimeFreqPainter old) =>
      old.values != values ||
      old.maskSignificant != maskSignificant ||
      old.hoverPos != hoverPos;
}
