// Connectivity results viewer: matrices, scalp / circular graphs coloured by Louvain community, node and overall
// graph measures, and the ROI → ROI multivariate measures. Works for channel level and source level (ROI) outputs.
import 'dart:io';

import 'package:flutter/material.dart';

import '../feature_plotter.dart' show Montage;
import 'connectivity_data.dart';
import 'connectivity_painters.dart';

const _panel = Color(0xFFF0F4F8);
const _muted = Color(0xFF64748B);

class ConnectivityView extends StatefulWidget {
  const ConnectivityView({super.key, required this.csvPaths});

  /// *.features.csv files produced by Stage 3.
  final List<String> csvPaths;

  @override
  State<ConnectivityView> createState() => _ConnectivityViewState();
}

enum _Tab { matrix, scalp, circle, measures, roi }

class _ConnectivityViewState extends State<ConnectivityView> {
  String? _path;
  Future<ConnectivityData>? _future;
  int _net = 0;
  _Tab _tab = _Tab.matrix;
  double _density = .2;
  String _metric = 'community';
  bool _labels = true;
  final Montage _montage = Montage.build(null);

  @override
  void initState() {
    super.initState();
    if (widget.csvPaths.isNotEmpty) _select(widget.csvPaths.first);
  }

  void _select(String path) {
    _path = path;
    _net = 0;
    _future = ConnectivityData.load(path);
  }

  /// Scalp positions when most labels are known 10-10 electrodes; null for source-level (ROI) labels.
  List<Offset>? _positions(ConnNetwork net) {
    final p = <Offset>[];
    var known = 0;
    for (final l in net.labels) {
      final o = _montage[l];
      if (o != null) known++;
      p.add(o ?? const Offset(.5, .5));
    }
    return known >= net.labels.length * .6 && known >= 4 ? p : null;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.csvPaths.isEmpty) {
      return const Center(child: Text('Run feature extraction with connectivity features first.'));
    }
    return FutureBuilder<ConnectivityData>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Center(child: Text('Could not read connectivity results: ${snap.error}'));
        }
        final data = snap.data!;
        final nets = data.networks;
        final hasMv = data.multivariate.isNotEmpty;
        if (nets.isEmpty && !hasMv) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'This feature file has no channel × channel connectivity. Enable GCMI, transfer entropy, or '
                '“Save channel × channel matrices” for the spectral measures, then rerun extraction.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        if (_net >= nets.length) _net = 0;
        final net = nets.isEmpty ? null : nets[_net];
        final positions = net == null ? null : _positions(net);
        final tabs = <_Tab>[
          if (net != null) _Tab.matrix,
          if (net != null && positions != null) _Tab.scalp,
          if (net != null) _Tab.circle,
          if (net != null) _Tab.measures,
          if (hasMv) _Tab.roi,
        ];
        if (!tabs.contains(_tab)) _tab = tabs.first;
        final measures = net == null
            ? <String>[]
            : [for (final m in kNodeMeasures) if (net.nodeMeasures.containsKey(m)) m];
        if (!measures.contains(_metric)) _metric = measures.isEmpty ? 'community' : measures.first;
        return Column(
          children: [
            _toolbar(data, net, tabs, measures, positions != null),
            const Divider(height: 1),
            Expanded(child: _body(data, net, positions)),
          ],
        );
      },
    );
  }

  Widget _toolbar(ConnectivityData data, ConnNetwork? net, List<_Tab> tabs, List<String> measures, bool scalp) {
    const names = {
      _Tab.matrix: 'Matrix',
      _Tab.scalp: 'Scalp graph',
      _Tab.circle: 'Circular graph',
      _Tab.measures: 'Graph measures',
      _Tab.roi: 'ROI → ROI (MIC / MIM / GC)',
    };
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (widget.csvPaths.length > 1)
            DropdownButton<String>(
              value: _path,
              dropdownColor: _panel,
              items: [
                for (final p in widget.csvPaths)
                  DropdownMenuItem(value: p, child: Text(p.split(Platform.pathSeparator).last, style: const TextStyle(fontSize: 12))),
              ],
              onChanged: (v) => setState(() => _select(v!)),
            ),
          if (data.networks.isNotEmpty)
            DropdownButton<int>(
              value: _net,
              dropdownColor: _panel,
              items: [
                for (var i = 0; i < data.networks.length; i++)
                  DropdownMenuItem(
                    value: i,
                    child: Text(
                      '${data.networks[i].title}  ·  ${data.networks[i].directed ? "directed" : "undirected"}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
              ],
              onChanged: (v) => setState(() => _net = v!),
            ),
          SegmentedButton<_Tab>(
            showSelectedIcon: false,
            segments: [for (final t in tabs) ButtonSegment(value: t, label: Text(names[t]!, style: const TextStyle(fontSize: 11)))],
            selected: {_tab},
            onSelectionChanged: (s) => setState(() => _tab = s.first),
          ),
          if (net != null && (_tab == _Tab.scalp || _tab == _Tab.circle)) ...[
            SizedBox(
              width: 210,
              child: Row(
                children: [
                  const Text('Edges', style: TextStyle(fontSize: 11, color: _muted)),
                  Expanded(
                    child: Slider(
                      value: _density,
                      min: .02,
                      max: 1,
                      divisions: 49,
                      label: '${(_density * 100).round()}%',
                      onChanged: (v) => setState(() => _density = v),
                    ),
                  ),
                  Text('${(_density * 100).round()}%', style: const TextStyle(fontSize: 11)),
                ],
              ),
            ),
            DropdownButton<String>(
              value: _metric,
              dropdownColor: _panel,
              items: [
                for (final m in measures)
                  DropdownMenuItem(value: m, child: Text('Node colour: ${kMeasureTitles[m] ?? m}', style: const TextStyle(fontSize: 12))),
              ],
              onChanged: (v) => setState(() => _metric = v!),
            ),
            FilterChip(
              label: const Text('Labels', style: TextStyle(fontSize: 11)),
              selected: _labels,
              onSelected: (v) => setState(() => _labels = v),
            ),
          ],
        ],
      ),
    );
  }

  Widget _body(ConnectivityData data, ConnNetwork? net, List<Offset>? positions) {
    switch (_tab) {
      case _Tab.matrix:
        return Padding(
          padding: const EdgeInsets.all(12),
          child: CustomPaint(painter: ConnMatrixPainter(net!), child: const SizedBox.expand()),
        );
      case _Tab.scalp:
      case _Tab.circle:
        final scalp = _tab == _Tab.scalp;
        return Column(
          children: [
            Expanded(
              child: CustomPaint(
                painter: ConnGraphPainter(
                  net: net!,
                  positions: scalp ? positions : null,
                  density: _density,
                  metric: _metric,
                  showLabels: _labels,
                ),
                child: const SizedBox.expand(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Text(
                net.directed
                    ? 'Arrows point source → target. Node size = strength; node colour = ${kMeasureTitles[_metric] ?? _metric}; outline = Louvain community.'
                    : 'Edge width = connection strength. Node size = strength; node colour = ${kMeasureTitles[_metric] ?? _metric}; outline = Louvain community.',
                style: const TextStyle(fontSize: 11, color: _muted),
              ),
            ),
          ],
        );
      case _Tab.measures:
        return _measuresTab(net!);
      case _Tab.roi:
        return _roiTab(data);
    }
  }

  Widget _measuresTab(ConnNetwork net) {
    final cols = [for (final m in kNodeMeasures) if (net.nodeMeasures.containsKey(m)) m];
    final comm = net.communities;
    String f(double v) => v.isNaN ? '–' : (v.abs() >= 100 || v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(3));
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Text('Overall (whole network)', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        if (net.globalMeasures.isEmpty)
          const Text('No overall graph measures in this file. Enable “Graph measures + Louvain communities”.', style: TextStyle(color: _muted))
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final k in kGlobalMeasures)
                if (net.globalMeasures.containsKey(k) && !net.globalMeasures[k]!.isNaN)
                  Container(
                    width: 170,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: _panel, borderRadius: BorderRadius.circular(8)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(kMeasureTitles[k] ?? k, style: const TextStyle(fontSize: 11, color: _muted)),
                        const SizedBox(height: 2),
                        Text(f(net.globalMeasures[k]!), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
            ],
          ),
        const SizedBox(height: 14),
        Text('Per channel / ROI', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 6),
        if (cols.isEmpty)
          const Text('No per-node graph measures in this file.', style: TextStyle(color: _muted))
        else
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              headingRowHeight: 34,
              dataRowMinHeight: 26,
              dataRowMaxHeight: 28,
              columns: [
                const DataColumn(label: Text('Node')),
                for (final m in cols) DataColumn(label: Text(kMeasureTitles[m] ?? m, style: const TextStyle(fontSize: 11)), numeric: true),
              ],
              rows: [
                for (var i = 0; i < net.labels.length; i++)
                  DataRow(cells: [
                    DataCell(Text(net.labels[i], style: TextStyle(fontSize: 12, color: comm == null ? null : communityColor(comm[i])))),
                    for (final m in cols)
                      DataCell(Text(m == 'community' ? (net.nodeMeasures[m]![i].isNaN ? '–' : '${net.nodeMeasures[m]![i].round() + 1}') : f(net.nodeMeasures[m]![i]),
                          style: const TextStyle(fontSize: 12))),
                  ]),
              ],
            ),
          ),
      ],
    );
  }

  Widget _roiTab(ConnectivityData data) {
    final roi = data.roi;
    final mv = data.multivariate;
    const titles = {
      'mic': 'MIC · maximised imaginary coherency (undirected)',
      'mim': 'MIM · multivariate interaction measure (undirected)',
      'gc': 'Granger causality, seed → target (directed)',
      'gc_tr': 'Time-reversed Granger causality (directed control)',
      'gc_contrast': 'GC − GC-TR contrast (directed; > 0 = seed drives target)',
    };
    final groups = <String, Map<String, double>>{};
    for (final e in mv.entries) {
      final i = e.key.startsWith('gc_contrast_')
          ? 'gc_contrast'
          : e.key.startsWith('gc_tr_')
          ? 'gc_tr'
          : e.key.split('_').first;
      groups.putIfAbsent(i, () => {})[e.key.substring(i.length + 1)] = e.value;
    }
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: _panel, borderRadius: BorderRadius.circular(8)),
          child: roi == null
              ? const Text('ROI definition not stored in this file (older run). The built-in default was frontal → parieto-occipital.',
                  style: TextStyle(color: _muted))
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${roi.seedName.isEmpty ? "Seed ROI" : roi.seedName}  →  ${roi.targetName.isEmpty ? "Target ROI" : roi.targetName}',
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    Text('Seed (${roi.seed.length}): ${roi.seed.join(", ")}', style: const TextStyle(fontSize: 12, color: Color(0xFF38BDF8))),
                    Text('Target (${roi.target.length}): ${roi.target.join(", ")}', style: const TextStyle(fontSize: 12, color: Color(0xFFF59E0B))),
                  ],
                ),
        ),
        const SizedBox(height: 12),
        for (final g in titles.keys)
          if (groups.containsKey(g)) ...[
            Text(titles[g]!, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            _bandBars(groups[g]!, signed: g == 'gc_contrast'),
            const SizedBox(height: 12),
          ],
      ],
    );
  }

  Widget _bandBars(Map<String, double> values, {required bool signed}) {
    var maxAbs = 0.0;
    for (final v in values.values) {
      if (!v.isNaN && v.abs() > maxAbs) maxAbs = v.abs();
    }
    if (maxAbs == 0) maxAbs = 1;
    return Column(
      children: [
        for (final e in values.entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                SizedBox(width: 90, child: Text(e.key, style: const TextStyle(fontSize: 12))),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, c) {
                      final w = c.maxWidth;
                      final frac = e.value.isNaN ? 0.0 : e.value.abs() / maxAbs;
                      final left = signed ? w / 2 + (e.value < 0 ? -frac * w / 2 : 0) : 0.0;
                      return SizedBox(
                        height: 14,
                        child: Stack(children: [
                          Positioned(
                            left: left,
                            width: (signed ? frac * w / 2 : frac * w).clamp(0.0, w).toDouble(),
                            top: 0,
                            bottom: 0,
                            child: Container(color: e.value < 0 ? const Color(0xFFEF4444) : const Color(0xFF3B82F6)),
                          ),
                        ]),
                      );
                    },
                  ),
                ),
                SizedBox(width: 64, child: Text(e.value.isNaN ? '–' : e.value.toStringAsFixed(4), textAlign: TextAlign.right, style: const TextStyle(fontSize: 12))),
              ],
            ),
          ),
      ],
    );
  }
}
