import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../recording_save_dialog.dart';
import 'workbench_figures.dart';
import 'workbench_service.dart';

/// Interactive ERSP (dB) and ITC (0–1) time-frequency workspace with
/// permutation masking, scalp topographies, common epoch selection, and CSV export.
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
    this.conditionALabels = const [],
    this.conditionBLabels = const [],
    this.groupMode = false,
    this.batchFiles = const [],
    this.participantGroups = const {},
    this.excludedFiles = const {},
    this.epochTminMs,
    this.outputDirectory,
    this.onEditEpochs,
    this.initialChannel,
    this.onChannelChanged,
    this.topoStartMs = 300.0,
    this.topoEndMs = 600.0,
    this.onTopoWindowChanged,
  });

  final String? recordingPath;
  final List<String> labels;
  final List<String> roiLabels;
  final List<int> conditionATrials;
  final List<int> conditionBTrials;
  final String conditionAName;
  final String conditionBName;
  final List<String> conditionALabels;
  final List<String> conditionBLabels;
  final bool groupMode;
  final List<Map<String, dynamic>> batchFiles;
  final Map<String, String> participantGroups;
  final Set<String> excludedFiles;
  final double? epochTminMs;
  final String? outputDirectory;
  final VoidCallback? onEditEpochs;
  final String? initialChannel;
  final ValueChanged<String>? onChannelChanged;
  final double topoStartMs;
  final double topoEndMs;
  final ValueChanged<(double, double)>? onTopoWindowChanged;

  @override
  State<ErspItcPanel> createState() => _ErspItcPanelState();
}

class _ErspItcPanelState extends State<ErspItcPanel> {
  final ErpWorkbenchService _service = ErpWorkbenchService();
  String _selectedChannel = 'ROI';
  String _viewMode = 'diff'; // 'a', 'b', 'diff'
  String? _selectedGroupView; // null = Grand Average across all active groups
  bool _maskSignificant = false;
  bool _busy = false;
  String _status = '';
  Map<String, dynamic>? _result;

  final TextEditingController _fminCtrl = TextEditingController(text: '2');
  final TextEditingController _fmaxCtrl = TextEditingController(text: '40');
  final TextEditingController _baseStartCtrl = TextEditingController(
    text: '-200',
  );
  final TextEditingController _baseEndCtrl = TextEditingController(text: '0');
  late final TextEditingController _topoStartCtrl = TextEditingController(
    text: '${widget.topoStartMs.round()}',
  );
  late final TextEditingController _topoEndCtrl = TextEditingController(
    text: '${widget.topoEndMs.round()}',
  );
  final TextEditingController _topoFminCtrl = TextEditingController(text: '2');
  final TextEditingController _topoFmaxCtrl = TextEditingController(text: '40');

  Offset? _hoverErsp;
  Offset? _hoverItc;

  @override
  void didUpdateWidget(covariant ErspItcPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.topoStartMs != widget.topoStartMs) {
      _topoStartCtrl.text = '${widget.topoStartMs.round()}';
    }
    if (oldWidget.topoEndMs != widget.topoEndMs) {
      _topoEndCtrl.text = '${widget.topoEndMs.round()}';
    }
    if (oldWidget.initialChannel != widget.initialChannel &&
        widget.initialChannel != null &&
        (widget.initialChannel == 'ROI' ||
            widget.labels.contains(widget.initialChannel))) {
      _selectedChannel = widget.initialChannel!;
    }
  }

  @override
  void initState() {
    super.initState();
    final init = widget.initialChannel;
    if (init != null && (init == 'ROI' || widget.labels.contains(init))) {
      _selectedChannel = init;
    } else if (widget.roiLabels.isEmpty && widget.labels.isNotEmpty) {
      _selectedChannel = widget.labels.first;
    }
    if (widget.conditionBTrials.isEmpty && widget.conditionBLabels.isEmpty) {
      _viewMode = 'a';
    }
  }

  @override
  void dispose() {
    _fminCtrl.dispose();
    _fmaxCtrl.dispose();
    _baseStartCtrl.dispose();
    _baseEndCtrl.dispose();
    _topoStartCtrl.dispose();
    _topoEndCtrl.dispose();
    _topoFminCtrl.dispose();
    _topoFmaxCtrl.dispose();
    super.dispose();
  }

  Future<void> _compute() async {
    if (_busy) return;
    if (widget.groupMode && widget.batchFiles.isNotEmpty) {
      final activeFiles = widget.batchFiles
          .where((f) => !widget.excludedFiles.contains('${f['path'] ?? ''}'))
          .toList();
      if (activeFiles.isEmpty) {
        setState(() => _status = 'No active batch recordings to average.');
        return;
      }
      setState(() {
        _busy = true;
        _status =
            'Computing Group Grand-Average ERSP & ITC across ${activeFiles.length} recordings…';
      });
      try {
        final inputs = [
          for (final f in activeFiles)
            {
              'path': '${f['path'] ?? ''}',
              'subject': '${f['subject'] ?? ''}',
              'group': (widget.participantGroups['${f['subject'] ?? ''}'] ??
                      '${f['group'] ?? ''}')
                  .trim(),
              'condition_a_labels': widget.conditionALabels,
              'condition_b_labels': widget.conditionBLabels,
            },
        ];
        final res = await _service.runGroupErspItc({
          'inputs': inputs,
          'channel_name': _selectedChannel,
          'roi_channels': widget.roiLabels,
          if (widget.epochTminMs != null) 'epoch_tmin_ms': widget.epochTminMs,
          'fmin_hz': double.tryParse(_fminCtrl.text.trim()) ?? 2.0,
          'fmax_hz': double.tryParse(_fmaxCtrl.text.trim()) ?? 40.0,
          'n_freqs': 24,
          'baseline_start_ms':
              double.tryParse(_baseStartCtrl.text.trim()) ?? -200.0,
          'baseline_end_ms': double.tryParse(_baseEndCtrl.text.trim()) ?? 0.0,
          'n_perm': 200,
        });
        if (!mounted) return;
        setState(() {
          _result = res;
          _selectedGroupView = null;
          if (res['ersp_b_db'] == null && _viewMode != 'a') _viewMode = 'a';
          final failed = (res['failed_files'] as List? ?? const []).length;
          _status =
              'Grand-Avg ERSP & ITC ready across ${res['n_subjects']} participant(s) '
              '(${res['n_files']} files${failed > 0 ? ', $failed skipped' : ''}).';
        });
      } catch (e) {
        if (mounted) setState(() => _status = 'Group ERSP/ITC error: $e');
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      return;
    }

    final path = widget.recordingPath;
    if (path == null || path.isEmpty) return;
    final activeA = widget.conditionATrials;
    final activeB = widget.conditionBTrials;
    if (activeA.isEmpty && widget.conditionALabels.isEmpty) {
      setState(() => _status = 'Include at least 1 trial or condition label.');
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
        'condition_a_labels': widget.conditionALabels,
        'condition_b_labels': widget.conditionBLabels,
        if (widget.epochTminMs != null) 'epoch_tmin_ms': widget.epochTminMs,
        'fmin_hz': double.tryParse(_fminCtrl.text.trim()) ?? 2.0,
        'fmax_hz': double.tryParse(_fmaxCtrl.text.trim()) ?? 40.0,
        'n_freqs': 24,
        'baseline_start_ms': double.tryParse(_baseStartCtrl.text.trim()) ?? -200.0,
        'baseline_end_ms': double.tryParse(_baseEndCtrl.text.trim()) ?? 0.0,
        'topo_tmin_ms': double.tryParse(_topoStartCtrl.text.trim()) ?? widget.topoStartMs,
        'topo_tmax_ms': double.tryParse(_topoEndCtrl.text.trim()) ?? widget.topoEndMs,
        'topo_fmin_hz': double.tryParse(_topoFminCtrl.text.trim()) ?? 2.0,
        'topo_fmax_hz': double.tryParse(_topoFmaxCtrl.text.trim()) ?? 40.0,
        'n_perm': 200,
      });
      if (!mounted) return;
      setState(() {
        _result = res;
        _selectedGroupView = null;
        if (res['ersp_b_db'] == null && _viewMode != 'a') _viewMode = 'a';
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

    // Also write per-trial summary table when in single-recording mode
    final idxA = (res['trial_indices_a'] as List? ?? []).cast<int>();
    final powA = (res['trial_power_a_db'] as List? ?? []).cast<num>();
    final itcTrA = (res['trial_itc_a'] as List? ?? []).cast<num>();
    final idxB = (res['trial_indices_b'] as List? ?? []).cast<int>();
    final powB = (res['trial_power_b_db'] as List? ?? []).cast<num>();
    final itcTrB = (res['trial_itc_b'] as List? ?? []).cast<num>();
    if (idxA.isNotEmpty || idxB.isNotEmpty) {
      final trialPath = path.replaceFirst(
        RegExp(r'\.csv$', caseSensitive: false),
        '_trials.csv',
      );
      final tBuf = StringBuffer()
        ..writeln('trial_index,condition,included,mean_ersp_db,itc_alignment');
      for (var k = 0; k < idxA.length && k < powA.length; k++) {
        tBuf.writeln(
          '${idxA[k] + 1},${widget.conditionAName},true,${powA[k].toStringAsFixed(4)},${itcTrA[k].toStringAsFixed(4)}',
        );
      }
      for (var k = 0; k < idxB.length && k < powB.length; k++) {
        tBuf.writeln(
          '${idxB[k] + 1},${widget.conditionBName},true,${powB[k].toStringAsFixed(4)},${itcTrB[k].toStringAsFixed(4)}',
        );
      }
      await File(trialPath).writeAsString(tBuf.toString());
    }

    if (mounted) {
      setState(() => _status = 'Exported ERSP/ITC CSV & trial table to $path');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.groupMode && widget.recordingPath == null) {
      return const Center(
        child: Text(
          'Load or run an epoched ERP recording (or switch to Grand Average) to compute ERSP & ITC.',
        ),
      );
    }

    final res = _result;
    final hasB = res != null && res['ersp_b_db'] != null;
    final availableResultGroups =
        (res?['groups'] as List? ?? const []).map((e) => '$e').toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            color: const Color(0xFFFFFFFF),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: 170,
                    child: DropdownButtonFormField<String>(
                      key: ValueKey('ersp_ch_$_selectedChannel'),
                      initialValue: _selectedChannel,
                      isDense: true,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Channel / ROI',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        if (widget.roiLabels.isNotEmpty)
                          DropdownMenuItem(
                            value: 'ROI',
                            child: Text(
                              'ROI (${widget.roiLabels.join(",")})',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        for (final ch in widget.labels)
                          DropdownMenuItem(
                            value: ch,
                            child: Text(ch, overflow: TextOverflow.ellipsis),
                          ),
                      ],
                      onChanged: (v) {
                        if (v != null) {
                          setState(() => _selectedChannel = v);
                          widget.onChannelChanged?.call(v);
                        }
                      },
                    ),
                  ),
                  SizedBox(
                    width: 100,
                    child: TextField(
                      controller: _fminCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Min Hz',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  SizedBox(
                    width: 100,
                    child: TextField(
                      controller: _fmaxCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Max Hz',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  SizedBox(
                    width: 112,
                    child: TextField(
                      controller: _baseStartCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Base start (ms)',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  SizedBox(
                    width: 112,
                    child: TextField(
                      controller: _baseEndCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Base end (ms)',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: _busy ? null : _compute,
                    icon: const Icon(Icons.waves, size: 16),
                    label: Text(
                      res == null
                          ? (widget.groupMode
                                ? 'Compute Group ERSP & ITC'
                                : 'Compute ERSP & ITC')
                          : 'Recompute',
                    ),
                  ),
                  if (res != null)
                    OutlinedButton.icon(
                      onPressed: _exportCsv,
                      icon: const Icon(Icons.download, size: 16),
                      label: const Text('Export CSV'),
                    ),
                ],
              ),
            ),
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_status.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(_status, style: const TextStyle(fontSize: 12, color: Color(0xFF475569))),
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
                if (availableResultGroups.length > 1)
                  SizedBox(
                    width: 210,
                    child: DropdownButtonFormField<String?>(
                      initialValue: availableResultGroups.contains(_selectedGroupView)
                          ? _selectedGroupView
                          : null,
                      isDense: true,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Group View',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        DropdownMenuItem<String?>(
                          value: null,
                          child: Text('All Groups (${res['n_subjects']} subj)'),
                        ),
                        for (final g in availableResultGroups)
                          DropdownMenuItem<String?>(
                            value: g,
                            child: Text(
                              '$g (${(res['group_subject_counts'] as Map?)?[g] ?? 0} subj)',
                            ),
                          ),
                      ],
                      onChanged: (v) => setState(() => _selectedGroupView = v),
                    ),
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
            _buildTopoRow(res),
            const SizedBox(height: 12),
            _buildCommonTrialStrip(res),
          ],
        ],
      ),
    );
  }

  List<double> _pickGrid(Map<String, dynamic> res, {required bool isItc}) {
    final grp = _selectedGroupView;
    if (grp != null) {
      final grpMapKey = isItc
          ? (_viewMode == 'b'
                ? 'group_itc_b'
                : (_viewMode == 'diff' ? 'group_itc_diff' : 'group_itc_a'))
          : (_viewMode == 'b'
                ? 'group_ersp_b_db'
                : (_viewMode == 'diff'
                      ? 'group_ersp_diff_db'
                      : 'group_ersp_a_db'));
      final m = res[grpMapKey] as Map?;
      final list = m?[grp] as List?;
      if (list != null) {
        return list.cast<num>().map((e) => e.toDouble()).toList();
      }
    }
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
                  roiTminMs: double.tryParse(_topoStartCtrl.text.trim()) ?? widget.topoStartMs,
                  roiTmaxMs: double.tryParse(_topoEndCtrl.text.trim()) ?? widget.topoEndMs,
                  roiFminHz: double.tryParse(_topoFminCtrl.text.trim()) ?? 2.0,
                  roiFmaxHz: double.tryParse(_topoFmaxCtrl.text.trim()) ?? 40.0,
                ),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<double> _pickTopo(Map<String, dynamic> res, {required bool isItc}) {
    final key = isItc
        ? (_viewMode == 'b' && res['topo_itc_b'] != null
              ? 'topo_itc_b'
              : (_viewMode == 'diff' && res['topo_itc_diff'] != null
                    ? 'topo_itc_diff'
                    : 'topo_itc_a'))
        : (_viewMode == 'b' && res['topo_ersp_b'] != null
              ? 'topo_ersp_b'
              : (_viewMode == 'diff' && res['topo_ersp_diff'] != null
                    ? 'topo_ersp_diff'
                    : 'topo_ersp_a'));
    return (res[key] as List? ?? []).cast<num>().map((e) => e.toDouble()).toList();
  }

  Widget _buildTopoRow(Map<String, dynamic> res) {
    final topoLabels = (res['labels'] as List? ?? widget.labels).cast<String>();
    final erspTopo = _pickTopo(res, isItc: false);
    final itcTopo = _pickTopo(res, isItc: true);
    if (topoLabels.isEmpty || (erspTopo.isEmpty && itcTopo.isEmpty)) {
      return const SizedBox.shrink();
    }
    final modeLabel = _viewMode == 'b'
        ? widget.conditionBName
        : (_viewMode == 'diff'
              ? '${widget.conditionBName} − ${widget.conditionAName}'
              : widget.conditionAName);
    final selectedSet = _selectedChannel == 'ROI'
        ? widget.roiLabels.toSet()
        : {_selectedChannel};

    Widget topoCard(String title, List<double> values) {
      return Container(
        height: 230,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFCBD5E1)),
        ),
        child: CustomPaint(
          painter: ErpWorkbenchTopoPainter(
            {
              'labels': topoLabels,
              'profile': {
                'a_name': widget.conditionAName,
                'b_name': widget.conditionBName,
              },
            },
            valuesOverride: values,
            customTitle: title,
            showPValues: false,
            selectedChannels: selectedSet,
          ),
          child: const SizedBox.expand(),
        ),
      );
    }

    final t0Label = _topoStartCtrl.text.trim();
    final t1Label = _topoEndCtrl.text.trim();
    final f0Label = _topoFminCtrl.text.trim();
    final f1Label = _topoFmaxCtrl.text.trim();
    final winSuffix = ' ($t0Label–$t1Label ms · $f0Label–$f1Label Hz)';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          color: const Color(0xFFFFFFFF),
          margin: const EdgeInsets.only(bottom: 8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text(
                  'Topo Window:',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFFD97706)),
                ),
                SizedBox(
                  width: 92,
                  child: TextField(
                    controller: _topoStartCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Start ms',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
                SizedBox(
                  width: 92,
                  child: TextField(
                    controller: _topoEndCtrl,
                    decoration: const InputDecoration(
                      labelText: 'End ms',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
                SizedBox(
                  width: 84,
                  child: TextField(
                    controller: _topoFminCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Min Hz',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
                SizedBox(
                  width: 84,
                  child: TextField(
                    controller: _topoFmaxCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Max Hz',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
                FilledButton.tonalIcon(
                  onPressed: _busy
                      ? null
                      : () {
                          final a = double.tryParse(_topoStartCtrl.text.trim());
                          final b = double.tryParse(_topoEndCtrl.text.trim());
                          if (a != null && b != null) {
                            widget.onTopoWindowChanged?.call((math.min(a, b), math.max(a, b)));
                          }
                          _compute();
                        },
                  icon: const Icon(Icons.sync, size: 14),
                  label: const Text('Update & Link Topo', style: TextStyle(fontSize: 11)),
                ),
              ],
            ),
          ),
        ),
        Row(
          children: [
            if (erspTopo.isNotEmpty)
              Expanded(child: topoCard('ERSP Topo: $modeLabel$winSuffix (dB)', erspTopo)),
            if (erspTopo.isNotEmpty && itcTopo.isNotEmpty) const SizedBox(width: 12),
            if (itcTopo.isNotEmpty)
              Expanded(child: topoCard('ITC Topo: $modeLabel$winSuffix (0–1)', itcTopo)),
          ],
        ),
      ],
    );
  }

  Widget _buildCommonTrialStrip(Map<String, dynamic> res) {
    final idxA = (res['trial_indices_a'] as List? ?? []).cast<int>();
    final powA = (res['trial_power_a_db'] as List? ?? []).cast<num>();
    final itcA = (res['trial_itc_a'] as List? ?? []).cast<num>();
    final idxB = (res['trial_indices_b'] as List? ?? []).cast<int>();
    final powB = (res['trial_power_b_db'] as List? ?? []).cast<num>();
    final itcB = (res['trial_itc_b'] as List? ?? []).cast<num>();
    if (idxA.isEmpty && idxB.isEmpty) {
      return const SizedBox.shrink();
    }

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
      color: const Color(0xFFF0F4F8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  'Common Epoch Selection (${entries.length} accepted trials shared across ERP, rERP, ERPimage, ML, ERSP & ITC)',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                ),
                if (widget.onEditEpochs != null)
                  OutlinedButton.icon(
                    onPressed: widget.onEditEpochs,
                    icon: const Icon(Icons.tune, size: 14),
                    label: const Text('Modify in Trial Review', style: TextStyle(fontSize: 11)),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final tr in entries)
                  Tooltip(
                    message:
                        'Trial ${tr.idx + 1} (${tr.cond})\nERSP: ${tr.pow.toStringAsFixed(2)} dB · ITC align: ${tr.itc.toStringAsFixed(2)}',
                    child: Container(
                      width: 24,
                      height: 28,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: tr.cond == widget.conditionAName
                            ? const Color(0xFF1E3A8A)
                            : const Color(0xFF991B1B),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: const Color(0xFFCBD5E1)),
                      ),
                      child: Text(
                        '${tr.idx + 1}',
                        style: const TextStyle(fontSize: 9, color: Colors.white),
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
    this.roiTminMs,
    this.roiTmaxMs,
    this.roiFminHz,
    this.roiFmaxHz,
  });

  final List<double> times;
  final List<double> freqs;
  final List<double> values;
  final List<double> pValues;
  final bool maskSignificant;
  final bool diverging;
  final String unit;
  final Offset? hoverPos;
  final double? roiTminMs;
  final double? roiTmaxMs;
  final double? roiFminHz;
  final double? roiFmaxHz;

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

    // Active Topo Time-Frequency ROI Box
    if (roiTminMs != null &&
        roiTmaxMs != null &&
        roiFminHz != null &&
        roiFmaxHz != null &&
        times.last > times.first &&
        freqs.last > freqs.first) {
      final tLo = math.min(roiTminMs!, roiTmaxMs!);
      final tHi = math.max(roiTminMs!, roiTmaxMs!);
      final fLo = math.min(roiFminHz!, roiFmaxHz!);
      final fHi = math.max(roiFminHz!, roiFmaxHz!);
      final x0 = (ax.left + (tLo - times.first) / (times.last - times.first) * ax.width)
          .clamp(ax.left, ax.right);
      final x1 = (ax.left + (tHi - times.first) / (times.last - times.first) * ax.width)
          .clamp(ax.left, ax.right);
      final yBot = (ax.bottom - (fLo - freqs.first) / (freqs.last - freqs.first) * ax.height)
          .clamp(ax.top, ax.bottom);
      final yTop = (ax.bottom - (fHi - freqs.first) / (freqs.last - freqs.first) * ax.height)
          .clamp(ax.top, ax.bottom);
      if (x1 > x0 && yBot > yTop) {
        final roiRect = Rect.fromLTRB(x0, yTop, x1, yBot);
        canvas.drawRect(
          roiRect,
          Paint()..color = const Color(0xFFFACC15).withValues(alpha: 0.12),
        );
        canvas.drawRect(
          roiRect,
          Paint()
            ..color = const Color(0xFFD97706)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6,
        );
      }
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
      old.roiTminMs != roiTminMs ||
      old.roiTmaxMs != roiTmaxMs ||
      old.roiFminHz != roiFminHz ||
      old.roiFmaxHz != roiFmaxHz ||
      old.hoverPos != hoverPos;
}
