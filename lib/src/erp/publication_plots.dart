import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:file_picker/file_picker.dart';
import 'erp_component_spec.dart';
import 'workbench_figures.dart';
import 'review_math.dart';
import '../topostats/mpl_colormaps.dart';
import '../topostats/topo_interp.dart';
import '../topostats/topo_paint.dart';
import '../group_statistics.dart';
import 'factor_grouping_designer.dart';

const List<Color> kPublicationGroupColors = [
  Color(0xFF0072B2), // Okabe-Ito Blue
  Color(0xFFD55E00), // Vermilion
  Color(0xFF009E73), // Bluish Green
  Color(0xFFCC79A7), // Reddish Purple
  Color(0xFFE69F00), // Orange
  Color(0xFF56B4E9), // Sky Blue
  Color(0xFF8B5CF6), // Violet
  Color(0xFF334155), // Slate
];

const List<String> kPublicationGroupHexes = [
  '#0072b2',
  '#d55e00',
  '#009e73',
  '#cc79a7',
  '#e69f00',
  '#56b4e9',
  '#8b5cf6',
  '#334155',
];

String resolvePublicationFileGroup(
  Map<String, dynamic> f,
  List<String> groups,
  Map<String, String> participantGroups,
  Map<String, Map<String, String>> fileFactors,
) {
  final path = '${f['path'] ?? ''}';
  final fGrp = (fileFactors[path]?['Group'] ?? '').trim();
  if (fGrp.isNotEmpty) return fGrp;
  final subj = '${f['subject'] ?? ''}';
  final pGrp = (participantGroups[subj] ?? '${f['group'] ?? ''}').trim();
  if (pGrp.isNotEmpty) return pGrp;
  return groups.length == 1 && groups.first == 'All participants'
      ? groups.first
      : 'Unknown';
}

/// Preset component definitions matching cognitive ERP literature (e.g. Cahn & Polich 2009).
class ErpComponentDef {
  ErpComponentDef({
    required this.name,
    required this.startMs,
    required this.endMs,
    this.polarity = 1.0,
    this.calloutElectrode = 'Cz',
  });

  String name;
  double startMs;
  double endMs;
  double
  polarity; // 1.0 for positive (P2, P3a, P300), -1.0 for negative (N1, N2pc, N400)
  String calloutElectrode;
}

/// Interactive publication plotting studio providing journal-ready figures
/// matching Cahn & Polich (2009) style (Fig 1 Waveform Grid, Fig 2 Topo Grid, Fig 3/5 Interaction Plots).
class ErpPublicationPlotsView extends StatefulWidget {
  const ErpPublicationPlotsView({
    super.key,
    required this.files,
    required this.groupData,
    required this.profile,
    required this.participantGroups,
    required this.onGroupsChanged,
    this.fileFactors = const {},
    this.excludedFiles = const {},
    this.initialComponents = const [],
    this.onComponentsChanged,
    this.outputDir,
    this.selectedChannel,
  });

  final List<Map<String, dynamic>> files;
  final Map<String, dynamic> groupData;
  final Map<String, dynamic> profile;
  final Map<String, String> participantGroups;
  final ValueChanged<Map<String, String>> onGroupsChanged;
  final Map<String, Map<String, String>> fileFactors;
  final Set<String> excludedFiles;
  final List<ErpComponentSpec> initialComponents;
  final ValueChanged<List<ErpComponentSpec>>? onComponentsChanged;
  final String? outputDir;
  final String? selectedChannel;

  @override
  State<ErpPublicationPlotsView> createState() =>
      _ErpPublicationPlotsViewState();
}

enum _InteractionLayout { byConditionXElectrode, byElectrodeXCondition, byGroupXCondition }

class _ErpPublicationPlotsViewState extends State<ErpPublicationPlotsView> {
  final GlobalKey _repaintBoundaryKey = GlobalKey();

  int _figureMode =
      0; // 0: Fig 1 Waveform Grid, 1: Fig 2 Topo Grid, 2: Fig 3/5 Interaction Plot
  List<String> _selectedElectrodes = ['Fz', 'Cz', 'Pz'];
  String _interactionMetric = 'mean'; // 'mean', 'peak_amp', 'peak_lat'
  _InteractionLayout _interactionLayout =
      _InteractionLayout.byConditionXElectrode;
  int _selectedComponentIndex = 0; // For Fig 3/5 interaction plot
  bool _negativeUp = true;
  bool _academicMonochrome = false;
  bool _showSemBands = true;
  bool _showPeakCallouts = false;
  bool _excludeUnknownGroups = true;

  String _colormap = 'RdBu_r';
  final TextEditingController _xMinCtrl = TextEditingController();
  final TextEditingController _xMaxCtrl = TextEditingController();
  final TextEditingController _yMinCtrl = TextEditingController();
  final TextEditingController _yMaxCtrl = TextEditingController();
  final TextEditingController _topoLimitCtrl = TextEditingController();
  double? _customXMinMs;
  double? _customXMaxMs;
  double? _customYMinUv;
  double? _customYMaxUv;
  double? _customTopoLimitUv;

  final List<ErpComponentDef> _components = [
    ErpComponentDef(
      name: 'N1',
      startMs: 80,
      endMs: 140,
      polarity: -1.0,
      calloutElectrode: 'Cz',
    ),
    ErpComponentDef(
      name: 'P2',
      startMs: 160,
      endMs: 240,
      polarity: 1.0,
      calloutElectrode: 'Cz',
    ),
    ErpComponentDef(
      name: 'P3a',
      startMs: 250,
      endMs: 380,
      polarity: 1.0,
      calloutElectrode: 'Cz',
    ),
  ];

  List<Map<String, dynamic>> get _activeFiles => widget.files
      .where((f) => !widget.excludedFiles.contains('${f['path'] ?? ''}'))
      .toList();

  List<String> get _conditions {
    final names =
        (widget.groupData['condition_names'] as List?)?.cast<String>() ?? [];
    if (names.isNotEmpty) return names;
    final f = _activeFiles.isNotEmpty ? _activeFiles.first : null;
    if (f != null && f['condition_names'] is List) {
      return (f['condition_names'] as List).cast<String>();
    }
    return ['Standard', 'Oddball', 'Distracter'];
  }

  List<String> get _groups {
    final gSet = <String>{};
    for (final f in _activeFiles) {
      final path = '${f['path'] ?? ''}';
      final subj = '${f['subject'] ?? ''}';
      final g = (widget.fileFactors[path]?['Group'] ??
              widget.participantGroups[subj] ??
              '${f['group'] ?? ''}')
          .trim();
      final eff = g.isEmpty ? 'Unknown' : g;
      if (_excludeUnknownGroups &&
          (eff.toLowerCase() == 'unknown' ||
              eff.toLowerCase() == 'unlabelled')) {
        continue;
      }
      gSet.add(eff);
    }
    if (gSet.isEmpty) {
      return _activeFiles.isEmpty ? ['All participants'] : ['All participants'];
    }
    return gSet.toList()..sort();
  }

  List<String> get _availableChannels {
    if (_activeFiles.isEmpty) return ['Fz', 'Cz', 'Pz'];
    final labels =
        (_activeFiles.first['labels'] as List? ?? []).cast<String>();
    return labels;
  }

  @override
  void initState() {
    super.initState();
    final chans = _availableChannels;
    if (widget.initialComponents.isNotEmpty) {
      _components
        ..clear()
        ..addAll(
          widget.initialComponents.map(
            (c) => ErpComponentDef(
              name: c.name,
              startMs: c.windowStartMs,
              endMs: c.windowEndMs,
              polarity: c.polarity,
              calloutElectrode:
                  c.roiChannels.isNotEmpty ? c.roiChannels.first : 'Cz',
            ),
          ),
        );
    } else {
      final window = erpNumbers(widget.profile['window']);
      if (window.length == 2) {
        _components
          ..clear()
          ..add(
            ErpComponentDef(
              name:
                  '${widget.profile['component_name'] ?? widget.profile['task'] ?? 'ERP'}',
              startMs: window[0] * 1000,
              endMs: window[1] * 1000,
              polarity: (widget.profile['polarity'] == 'negative' ||
                      (widget.profile['polarity'] is num &&
                          (widget.profile['polarity'] as num) < 0))
                  ? -1
                  : 1,
            ),
          );
      }
    }
    _selectedElectrodes = widget.selectedChannel != null && chans.contains(widget.selectedChannel) ? [widget.selectedChannel!] : ['Fz', 'Cz', 'Pz'].where(chans.contains).toList();
    if (_selectedElectrodes.isEmpty && chans.isNotEmpty) {
      _selectedElectrodes = chans.take(3).toList();
    }
    _academicMonochrome = _groups.length <= 2 ? false : false;
  }

  @override
  void didUpdateWidget(covariant ErpPublicationPlotsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedChannel != oldWidget.selectedChannel && _availableChannels.contains(widget.selectedChannel)) {
      _selectedElectrodes = [widget.selectedChannel!];
    }
    final next = widget.initialComponents;
    if (next.isNotEmpty) {
      final signature = next.map((c) => '${c.name}:${c.windowStartMs}:${c.windowEndMs}:${c.polarity}:${c.roiChannels.join(",")}').join('|');
      final previous = oldWidget.initialComponents.map((c) => '${c.name}:${c.windowStartMs}:${c.windowEndMs}:${c.polarity}:${c.roiChannels.join(",")}').join('|');
      if (signature != previous) {
        _components..clear()..addAll(next.map((c) => ErpComponentDef(name: c.name, startMs: c.windowStartMs, endMs: c.windowEndMs, polarity: c.polarity, calloutElectrode: c.roiChannels.firstOrNull ?? 'Cz')));
        _selectedComponentIndex = _selectedComponentIndex.clamp(0, _components.length - 1);
      }
    }
  }

  @override
  void dispose() {
    _xMinCtrl.dispose();
    _xMaxCtrl.dispose();
    _yMinCtrl.dispose();
    _yMaxCtrl.dispose();
    _topoLimitCtrl.dispose();
    super.dispose();
  }

  void _applyAxisFields() {
    setState(() {
      _customXMinMs = double.tryParse(_xMinCtrl.text.trim());
      _customXMaxMs = double.tryParse(_xMaxCtrl.text.trim());
      _customYMinUv = double.tryParse(_yMinCtrl.text.trim());
      _customYMaxUv = double.tryParse(_yMaxCtrl.text.trim());
      final topoVal = double.tryParse(_topoLimitCtrl.text.trim());
      _customTopoLimitUv = (topoVal != null && topoVal > 0) ? topoVal : null;
    });
  }

  void _resetAxisFields() {
    _xMinCtrl.clear();
    _xMaxCtrl.clear();
    _yMinCtrl.clear();
    _yMaxCtrl.clear();
    _topoLimitCtrl.clear();
    setState(() {
      _customXMinMs = null;
      _customXMaxMs = null;
      _customYMinUv = null;
      _customYMaxUv = null;
      _customTopoLimitUv = null;
    });
  }

  void _notifyComponentsChanged() {
    if (widget.onComponentsChanged == null) return;
    widget.onComponentsChanged!([
      for (var i = 0; i < _components.length; i++)
        ErpComponentSpec(
          name: _components[i].name,
          windowStartMs: _components[i].startMs,
          windowEndMs: _components[i].endMs,
          polarity: _components[i].polarity,
          roiChannels: [_components[i].calloutElectrode],
          colorValue: ErpComponentSpec.paletteColorValues[
              i % ErpComponentSpec.paletteColorValues.length],
        ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildControlHeader(),
        const Divider(height: 1),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildConfigSidebar(),
              const VerticalDivider(width: 1),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: RepaintBoundary(
                      key: _repaintBoundaryKey,
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.08),
                              blurRadius: 10,
                              offset: const Offset(0, 4),
                            ),
                          ],
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: Colors.grey.shade300),
                        ),
                        child: _buildCurrentFigure(),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildControlHeader() {
    final totalActive = _activeFiles.length;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: Theme.of(context).colorScheme.surface,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('Preview and export: ${_activeFiles.length} recording(s) · ${_selectedElectrodes.join(', ')} · ${_components.map((c) => '${c.name} ${c.startMs.round()}–${c.endMs.round()} ms').join('; ')}', style: const TextStyle(fontSize: 11)),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(
                value: 0,
                label: Text('Fig 1: Waveforms Grid'),
                icon: Icon(Icons.show_chart),
              ),
              ButtonSegment(
                value: 1,
                label: Text('Fig 2: Voltage Topomaps'),
                icon: Icon(Icons.map),
              ),
              ButtonSegment(
                value: 2,
                label: Text('Fig 3/5: Interaction Plots'),
                icon: Icon(Icons.stacked_line_chart),
              ),
            ],
            selected: {_figureMode},
            onSelectionChanged: (s) => setState(() => _figureMode = s.first),
          ),
          ElevatedButton.icon(
            onPressed: _openGroupLabelDialog,
            icon: const Icon(Icons.label, size: 17),
            label: Text(
              'Groups (${_groups.length} · $totalActive files)',
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1D4ED8),
              foregroundColor: Colors.white,
            ),
          ),
          OutlinedButton.icon(
            onPressed: _figureMode == 1 ? null : _exportSvg,
            icon: const Icon(Icons.code, size: 17),
            label: Text(_figureMode == 1 ? 'Topomaps: use PNG' : 'Save displayed figure · SVG'),
          ),
          OutlinedButton.icon(
            onPressed: _exportPng,
            icon: const Icon(Icons.image, size: 17),
            label: const Text('Save displayed figure · PNG'),
          ),
          FilledButton.icon(
            onPressed: _launchAdvancedStats,
            icon: const Icon(Icons.auto_graph, size: 17),
            label: const Text('LMM / GLM Stats & eTFCE'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF047857),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConfigSidebar() {
    return SizedBox(
      width: 295,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          const Text(
            'FIGURE SETTINGS',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 12,
              color: Colors.blueGrey,
            ),
          ),
          const SizedBox(height: 6),
          SwitchListTile(
            dense: true,
            title: const Text('Academic B&W (dashed + monochrome)'),
            subtitle: const Text('Turn off for colorblind-safe multi-group hues'),
            value: _academicMonochrome,
            onChanged: (v) => setState(() => _academicMonochrome = v),
          ),
          SwitchListTile(
            dense: true,
            title: const Text('Hide "Unknown" / Unlabelled'),
            value: _excludeUnknownGroups,
            onChanged: (v) => setState(() => _excludeUnknownGroups = v),
          ),
          if (_figureMode == 0) ...[
            SwitchListTile(
              dense: true,
              title: const Text('Negative Up'),
              value: _negativeUp,
              onChanged: (v) => setState(() => _negativeUp = v),
            ),
            SwitchListTile(
              dense: true,
              title: const Text('Shaded SEM bands'),
              value: _showSemBands,
              onChanged: (v) => setState(() => _showSemBands = v),
            ),
            SwitchListTile(
              dense: true,
              title: const Text('Component window markers'),
              value: _showPeakCallouts,
              onChanged: (v) => setState(() => _showPeakCallouts = v),
            ),
            const Divider(height: 16),
            const Text(
              'AXIS LIMITS (DISPLAY ONLY)',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 11.5,
                color: Colors.blueGrey,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _xMinCtrl,
                    decoration: const InputDecoration(
                      labelText: 'X min (ms)',
                      hintText: 'Auto',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _applyAxisFields(),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: TextField(
                    controller: _xMaxCtrl,
                    decoration: const InputDecoration(
                      labelText: 'X max (ms)',
                      hintText: 'Auto',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _applyAxisFields(),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _yMinCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Y min (µV)',
                      hintText: 'Auto',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _applyAxisFields(),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: TextField(
                    controller: _yMaxCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Y max (µV)',
                      hintText: 'Auto',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _applyAxisFields(),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                OutlinedButton(
                  onPressed: _applyAxisFields,
                  child: const Text('Apply', style: TextStyle(fontSize: 11)),
                ),
                const SizedBox(width: 6),
                TextButton(
                  onPressed: _resetAxisFields,
                  child: const Text('Auto', style: TextStyle(fontSize: 11)),
                ),
              ],
            ),
          ],
          if (_figureMode == 1) ...[
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: _colormap,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Topomap Colormap',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              items: [
                for (final k in kMplColormaps.keys)
                  DropdownMenuItem(value: k, child: Text(k)),
              ],
              onChanged: (v) {
                if (v != null) setState(() => _colormap = v);
              },
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _topoLimitCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Color limit (±µV)',
                      hintText: 'Auto',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _applyAxisFields(),
                  ),
                ),
                const SizedBox(width: 6),
                OutlinedButton(
                  onPressed: _applyAxisFields,
                  child: const Text('Set', style: TextStyle(fontSize: 11)),
                ),
              ],
            ),
          ],
          if (_figureMode == 2) ...[
            const SizedBox(height: 8),
            DropdownButtonFormField<_InteractionLayout>(
              initialValue: _interactionLayout,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Plot Axis Grouping',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(
                  value: _InteractionLayout.byConditionXElectrode,
                  child: Text('Panels: Condition · X: Electrode'),
                ),
                DropdownMenuItem(
                  value: _InteractionLayout.byElectrodeXCondition,
                  child: Text('Panels: Electrode · X: Condition'),
                ),
                DropdownMenuItem(
                  value: _InteractionLayout.byGroupXCondition,
                  child: Text('Panels: Group · X: Condition'),
                ),
              ],
              onChanged: (v) {
                if (v != null) setState(() => _interactionLayout = v);
              },
            ),
            const SizedBox(height: 8),
            const Text(
              'Interaction Measure:',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5),
            ),
            DropdownButton<String>(
              isExpanded: true,
              value: _interactionMetric,
              items: const [
                DropdownMenuItem(
                  value: 'mean',
                  child: Text('Mean Amplitude (µV)'),
                ),
                DropdownMenuItem(
                  value: 'peak_amp',
                  child: Text('Peak Amplitude (µV)'),
                ),
                DropdownMenuItem(
                  value: 'peak_lat',
                  child: Text('Peak Latency (ms)'),
                ),
              ],
              onChanged: (v) => setState(() => _interactionMetric = v!),
            ),
            const SizedBox(height: 8),
            const Text(
              'Component:',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5),
            ),
            DropdownButton<int>(
              isExpanded: true,
              value: _selectedComponentIndex.clamp(0, _components.length - 1),
              items: [
                for (var i = 0; i < _components.length; i++)
                  DropdownMenuItem(
                    value: i,
                    child: Text(
                      '${_components[i].name} (${_components[i].startMs.round()}–${_components[i].endMs.round()} ms)',
                    ),
                  ),
              ],
              onChanged: (v) => setState(() => _selectedComponentIndex = v!),
            ),
          ],
          const SizedBox(height: 12),
          const Text(
            'ELECTRODES (ROWS)',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 12,
              color: Colors.blueGrey,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final ch in _availableChannels)
                FilterChip(
                  label: Text(ch, style: const TextStyle(fontSize: 11)),
                  visualDensity: VisualDensity.compact,
                  selected: _selectedElectrodes.contains(ch),
                  onSelected: (sel) {
                    setState(() {
                      if (sel) {
                        _selectedElectrodes.add(ch);
                      } else if (_selectedElectrodes.length > 1) {
                        _selectedElectrodes.remove(ch);
                      }
                    });
                  },
                ),
            ],
          ),
          const SizedBox(height: 16),
          const Text(
            'COMPONENT WINDOWS',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 12,
              color: Colors.blueGrey,
            ),
          ),
          for (final comp in _components)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 60,
                    child: Text(
                      comp.name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      '${comp.startMs.round()}–${comp.endMs.round()} ms (${comp.polarity > 0 ? "+" : "−"}) · ${comp.calloutElectrode}',
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11.5),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _openComponentEditor,
            icon: const Icon(Icons.edit, size: 16),
            label: const Text('Add / Edit Components'),
          ),
        ],
      ),
    );
  }

  Widget _buildCurrentFigure() {
    final activeFiles = _activeFiles;
    final groups = _groups;
    switch (_figureMode) {
      case 0:
        return SizedBox(
          width: math.max(840.0, _conditions.length * 260.0 + 100.0),
          height: 185.0 * _selectedElectrodes.length + 110.0,
          child: CustomPaint(
            painter: PublicationWaveformGridPainter(
              files: activeFiles,
              groups: groups,
              participantGroups: widget.participantGroups,
              fileFactors: widget.fileFactors,
              conditions: _conditions,
              electrodes: _selectedElectrodes,
              components: _components,
              negativeUp: _negativeUp,
              monochrome: _academicMonochrome,
              showSem: _showSemBands,
              showCallouts: _showPeakCallouts,
              xMinMs: _customXMinMs,
              xMaxMs: _customXMaxMs,
              yMinUv: _customYMinUv,
              yMaxUv: _customYMaxUv,
            ),
          ),
        );
      case 1:
        return SizedBox(
          width: math.max(840.0, groups.length * _conditions.length * 115.0 + 140.0),
          height: 160.0 * _components.length + 100.0,
          child: CustomPaint(
            painter: PublicationTopomapGridPainter(
              files: activeFiles,
              groups: groups,
              participantGroups: widget.participantGroups,
              fileFactors: widget.fileFactors,
              conditions: _conditions,
              components: _components,
              colormap: _colormap,
              customLimitUv: _customTopoLimitUv,
            ),
          ),
        );
      case 2:
      default:
        final comp =
            _components[_selectedComponentIndex.clamp(
              0,
              _components.length - 1,
            )];
        return SizedBox(
          width: 860,
          height: 410,
          child: CustomPaint(
            painter: PublicationInteractionPlotPainter(
              files: activeFiles,
              groups: groups,
              participantGroups: widget.participantGroups,
              fileFactors: widget.fileFactors,
              conditions: _conditions,
              electrodes: _selectedElectrodes,
              component: comp,
              metric: _interactionMetric,
              monochrome: _academicMonochrome,
              layoutMode: _interactionLayout.index,
            ),
          ),
        );
    }
  }

  Future<void> _openGroupLabelDialog() async {
    final active = _activeFiles;
    final paths = active
        .map((f) => '${f['path'] ?? f['subject'] ?? ''}'.trim())
        .where((p) => p.isNotEmpty)
        .toList();
    if (paths.isEmpty) return;
    final res = await FactorGroupingDesignerDialog.show(
      context,
      filePaths: paths,
      initialFileFactors: widget.fileFactors,
      initialParticipantGroups: widget.participantGroups,
      initialExcludedFiles: widget.excludedFiles,
    );
    if (res == null || !mounted) return;
    widget.onGroupsChanged(res.participantGroups);
    setState(() {});
    if (widget.outputDir != null) {
      await _saveGroupsCsv(res.participantGroups);
    }
  }

  Future<void> _saveGroupsCsv(Map<String, String> groups) async {
    try {
      final file = File('${widget.outputDir}/participant_groups.csv');
      final buf = StringBuffer('subject,group\n');
      for (final e in groups.entries) {
        buf.writeln('"${e.key}","${e.value}"');
      }
      await file.writeAsString(buf.toString());
    } catch (_) {}
  }

  void _openComponentEditor() {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Row(
            children: [
              const Expanded(child: Text('Edit ERP Components')),
              TextButton.icon(
                onPressed: () {
                  setDialogState(() {
                    _components.add(
                      ErpComponentDef(
                        name: 'C${_components.length + 1}',
                        startMs: 250,
                        endMs: 450,
                        polarity: 1.0,
                        calloutElectrode: _availableChannels.contains('Pz')
                            ? 'Pz'
                            : _availableChannels.first,
                      ),
                    );
                  });
                },
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add Component'),
              ),
            ],
          ),
          content: SizedBox(
            width: 620,
            height: 360,
            child: ListView.builder(
              itemCount: _components.length,
              itemBuilder: (_, idx) {
                final comp = _components[idx];
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        SizedBox(
                          width: 90,
                          child: TextFormField(
                            initialValue: comp.name,
                            decoration: const InputDecoration(
                              labelText: 'Name',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                            onChanged: (v) {
                              if (v.trim().isNotEmpty) comp.name = v.trim();
                            },
                          ),
                        ),
                        SizedBox(
                          width: 82,
                          child: TextFormField(
                            initialValue: comp.startMs.round().toString(),
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Start ms',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                            onChanged: (v) {
                              final n = double.tryParse(v);
                              if (n != null) comp.startMs = n;
                            },
                          ),
                        ),
                        SizedBox(
                          width: 82,
                          child: TextFormField(
                            initialValue: comp.endMs.round().toString(),
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'End ms',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                            onChanged: (v) {
                              final n = double.tryParse(v);
                              if (n != null) comp.endMs = n;
                            },
                          ),
                        ),
                        SizedBox(
                          width: 120,
                          child: DropdownButtonFormField<double>(
                            initialValue: comp.polarity < 0 ? -1.0 : 1.0,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: 'Polarity',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                            items: const [
                              DropdownMenuItem(value: 1.0, child: Text('Pos (+)')),
                              DropdownMenuItem(value: -1.0, child: Text('Neg (−)')),
                            ],
                            onChanged: (v) {
                              if (v != null) setDialogState(() => comp.polarity = v);
                            },
                          ),
                        ),
                        SizedBox(
                          width: 95,
                          child: DropdownButtonFormField<String>(
                            initialValue: _availableChannels.contains(
                                    comp.calloutElectrode)
                                ? comp.calloutElectrode
                                : _availableChannels.first,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: 'ROI ch',
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                            items: [
                              for (final ch in _availableChannels)
                                DropdownMenuItem(value: ch, child: Text(ch)),
                            ],
                            onChanged: (v) {
                              if (v != null) {
                                setDialogState(() => comp.calloutElectrode = v);
                              }
                            },
                          ),
                        ),
                        if (_components.length > 1)
                          IconButton(
                            icon: const Icon(Icons.delete_outline, size: 18),
                            onPressed: () {
                              setDialogState(() {
                                _components.removeAt(idx);
                                if (_selectedComponentIndex >= _components.length) {
                                  _selectedComponentIndex =
                                      _components.length - 1;
                                }
                              });
                            },
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () {
                setState(() {});
                _notifyComponentsChanged();
                Navigator.pop(ctx);
              },
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _writeExportContext(String path) => File('$path.settings.json').writeAsString(const JsonEncoder.withIndent('  ').convert({
    'figure': ['waveform_grid', 'topomaps', 'interaction'][_figureMode],
    'sources': [for (final f in _activeFiles) {'path': f['path'], 'subject': f['subject'], 'condition_counts': f['condition_counts'], 'profile': f['profile']}],
    'electrodes': _selectedElectrodes,
    'components': [for (final c in _components) {'name': c.name, 'start_ms': c.startMs, 'end_ms': c.endMs, 'polarity': c.polarity}],
    'negative_up': _negativeUp, 'sem': _showSemBands,
    'x_limits_ms': [_customXMinMs, _customXMaxMs], 'y_limits_uv': [_customYMinUv, _customYMaxUv],
  })).then((_) {});

  Future<void> _exportSvg() async {
    if (_figureMode == 1) return;
    final savePath = await FilePicker.saveFile(
      dialogTitle: 'Save Publication Figure as SVG',
      fileName:
          'erp_figure_${_figureMode == 0
              ? "1_waveforms"
              : _figureMode == 1
              ? "2_topomaps"
              : "3_interaction"}.svg',
      type: FileType.custom,
      allowedExtensions: ['svg'],
    );
    if (savePath == null) return;

    String svgContent;
    final activeFiles = _activeFiles;
    final groups = _groups;
    if (_figureMode == 0) {
      svgContent = generateWaveformGridSvg(
        files: activeFiles,
        groups: groups,
        participantGroups: widget.participantGroups,
        fileFactors: widget.fileFactors,
        conditions: _conditions,
        electrodes: _selectedElectrodes,
        components: _components,
        negativeUp: _negativeUp,
        monochrome: _academicMonochrome,
        showSem: _showSemBands,
        showCallouts: _showPeakCallouts,
        xMinMs: _customXMinMs,
        xMaxMs: _customXMaxMs,
        yMinUv: _customYMinUv,
        yMaxUv: _customYMaxUv,
      );
    } else if (_figureMode == 2) {
      final comp =
          _components[_selectedComponentIndex.clamp(0, _components.length - 1)];
      svgContent = generateInteractionPlotSvg(
        files: activeFiles,
        groups: groups,
        participantGroups: widget.participantGroups,
        fileFactors: widget.fileFactors,
        conditions: _conditions,
        electrodes: _selectedElectrodes,
        component: comp,
        metric: _interactionMetric,
        monochrome: _academicMonochrome,
        layoutMode: _interactionLayout.index,
      );
    } else {
      return;
    }

    await File(savePath).writeAsString(svgContent);
    await _writeExportContext(savePath);
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Saved vector SVG to $savePath')));
    }
  }

  Future<void> _exportPng() async {
    try {
      final boundary =
          _repaintBoundaryKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) return;
      final ui.Image image = await boundary.toImage(
        pixelRatio: 3.0,
      ); // 300 DPI equivalent
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return;

      final savePath = await FilePicker.saveFile(
        dialogTitle: 'Save High-Res 300 DPI PNG',
        fileName:
            'erp_figure_${_figureMode == 0
                ? "1_waveforms"
                : _figureMode == 1
                ? "2_topomaps"
                : "3_interaction"}.png',
        type: FileType.custom,
        allowedExtensions: ['png'],
      );
      if (savePath == null) return;

      await File(savePath).writeAsBytes(byteData.buffer.asUint8List());
      await _writeExportContext(savePath);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved 300 DPI PNG to $savePath')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to export PNG: $e')));
      }
    }
  }

  Future<void> _launchAdvancedStats() async {
    final comp =
        _components[_selectedComponentIndex.clamp(0, _components.length - 1)];
    final outDir = widget.outputDir ?? Directory.systemTemp.path;
    final csvPath = '$outDir/ERP_${comp.name}_lmm_input.csv';

    final extraCols = <String>{};
    for (final m in widget.fileFactors.values) {
      for (final k in m.keys) {
        if (k != 'Subject' && k != 'Group' && k != 'group' && k != 'subjid') {
          extraCols.add(k);
        }
      }
    }
    final extraColList = extraCols.toList()..sort();

    final buf = StringBuffer();
    final headerParts = [
      'subjid',
      'group',
      ...extraColList,
      'condition',
      'electrode',
      'mean_amplitude_ERP',
      'peak_amplitude_ERP',
      'peak_latency_ms_ERP',
    ];
    buf.writeln(headerParts.join(','));

    final times = erpNumbers(widget.files.first['times']);
    for (final f in widget.files) {
      final path = '${f['path'] ?? ''}';
      if (path.isNotEmpty && widget.excludedFiles.contains(path)) continue;
      final subjid = f['subject'] as String? ?? 'unknown';
      final fFactors = widget.fileFactors[path] ?? const <String, String>{};
      final group = fFactors['Group'] ??
          widget.participantGroups[subjid] ??
          'Unknown';
      final labels = (f['labels'] as List? ?? []).cast<String>();
      final chans = f['channel_conditions'] as Map?;

      for (final cond in _conditions) {
        for (final el in _selectedElectrodes) {
          final cIdx = labels.indexOf(el);
          if (cIdx < 0) continue;
          List<double>? wave;
          if (chans != null && chans.containsKey(cond)) {
            final rows = chans[cond] as List?;
            if (rows != null && cIdx < rows.length)
              wave = erpNumbers(rows[cIdx]);
          } else if (f['channel_a'] != null) {
            final rows = f['channel_a'] as List?;
            if (rows != null && cIdx < rows.length)
              wave = erpNumbers(rows[cIdx]);
          }
          if (wave != null && wave.length == times.length) {
            final m = reviewMeasures(
              times,
              wave,
              comp.startMs / 1000,
              comp.endMs / 1000,
              comp.polarity,
            );
            final extraVals = [
              for (final col in extraColList)
                '"${(fFactors[col] ?? 'Unknown').replaceAll('"', '""')}"',
            ];
            buf.writeln(
              '"$subjid","$group",${extraVals.isEmpty ? '' : '${extraVals.join(',')},'}"$cond","$el",${m['mean']?.toStringAsFixed(4) ?? 0},${m['peak_amplitude']?.toStringAsFixed(4) ?? 0},${((m['peak_latency'] ?? 0) * 1000).toStringAsFixed(1)}',
            );
          }
        }
      }
    }

    await File(csvPath).writeAsString(buf.toString());
    if (!mounted) return;

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (ctx) => Scaffold(
          appBar: AppBar(
            title: Text(
              '${comp.name} · LMM, Repeated-Measures ANOVA & eTFCE Stats',
            ),
          ),
          body: GroupStatisticsWorkbench(initialCsvPath: csvPath),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// DIALOG: PARTICIPANT GROUP LABELING
// ─────────────────────────────────────────────────────────────────────────────

class ErpGroupLabelDialog extends StatefulWidget {
  const ErpGroupLabelDialog({
    super.key,
    required this.files,
    required this.initialGroups,
    required this.onSaved,
  });

  final List<Map<String, dynamic>> files;
  final Map<String, String> initialGroups;
  final ValueChanged<Map<String, String>> onSaved;

  @override
  State<ErpGroupLabelDialog> createState() => _ErpGroupLabelDialogState();
}

class _ErpGroupLabelDialogState extends State<ErpGroupLabelDialog> {
  late Map<String, String> _groups;
  final TextEditingController _group1Ctrl = TextEditingController(
    text: 'CONTROL',
  );
  final TextEditingController _group2Ctrl = TextEditingController(
    text: 'MEDITATION',
  );
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _groups = Map<String, String>.from(widget.initialGroups);
    for (final file in widget.files) {
      final subject = '${file['subject'] ?? ''}';
      final saved = '${file['group'] ?? ''}'.trim();
      _groups.putIfAbsent(subject, () => saved);
    }
    final names = _groups.values.where((g) => g.isNotEmpty).toSet().toList()
      ..sort();
    if (names.isNotEmpty) _group1Ctrl.text = names.first;
    if (names.length > 1) _group2Ctrl.text = names[1];
  }

  void _renameGroup(String oldName, String newName) {
    for (final subject in _groups.keys.toList()) {
      if (oldName.isNotEmpty && _groups[subject] == oldName)
        _groups[subject] = newName.trim();
    }
  }

  @override
  void dispose() {
    _group1Ctrl.dispose();
    _group2Ctrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final subjects =
        widget.files.map((f) => f['subject'].toString()).toSet().toList()
          ..sort();
    final filter = _searchCtrl.text.trim().toLowerCase();
    final visible = filter.isEmpty
        ? subjects
        : subjects.where((s) => s.toLowerCase().contains(filter)).toList();

    final g1 = _group1Ctrl.text.trim();
    final g2 = _group2Ctrl.text.trim();

    return AlertDialog(
      title: const Text('Assign Participant Groups'),
      content: SizedBox(
        width: 550,
        height: 500,
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _group1Ctrl,
                    decoration: const InputDecoration(
                      labelText: 'Group 1 Name',
                      isDense: true,
                    ),
                    onChanged: (value) =>
                        setState(() => _renameGroup(g1, value)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _group2Ctrl,
                    decoration: const InputDecoration(
                      labelText: 'Group 2 Name',
                      isDense: true,
                    ),
                    onChanged: (value) =>
                        setState(() => _renameGroup(g2, value)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    decoration: const InputDecoration(
                      hintText: 'Search subjects…',
                      prefixIcon: Icon(Icons.search, size: 18),
                      isDense: true,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () {
                    final half = (subjects.length / 2).ceil();
                    setState(() {
                      for (var i = 0; i < subjects.length; i++) {
                        _groups[subjects[i]] = i < half ? g1 : g2;
                      }
                    });
                  },
                  child: const Text('Split 50/50'),
                ),
                const SizedBox(width: 4),
                OutlinedButton(
                  onPressed: () {
                    setState(() {
                      for (final s in subjects) {
                        final lower = s.toLowerCase();
                        if (lower.contains('med') || lower.contains('vip')) {
                          _groups[s] = g2;
                        } else {
                          _groups[s] = g1;
                        }
                      }
                    });
                  },
                  child: const Text('Auto-Prefix'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.builder(
                itemCount: visible.length,
                itemBuilder: (ctx, i) {
                  final s = visible[i];
                  return ListTile(
                    dense: true,
                    title: Text(
                      s,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    trailing: DropdownButton<String>(
                      value: _groups[s] ?? '',
                      items: {'', g1, g2, ..._groups.values}
                          .map(
                            (name) => DropdownMenuItem(
                              value: name,
                              child: Text(name.isEmpty ? 'Unassigned' : name),
                            ),
                          )
                          .toList(),
                      onChanged: (value) =>
                          setState(() => _groups[s] = value ?? ''),
                    ),
                  );
                },
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
        FilledButton(
          onPressed: g1.isEmpty || g2.isEmpty || g1 == g2
              ? null
              : () {
                  widget.onSaved(_groups);
                  Navigator.pop(context);
                },
          child: const Text('Apply Groups'),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIGURE 1: GRAND-AVERAGED WAVEFORM GRID PAINTER
// ─────────────────────────────────────────────────────────────────────────────

double publicationAmplitude(
  List<Map<String, dynamic>> files,
  List<String> electrodes, {
  List<String> groups = const ['All participants'],
  Map<String, String> participantGroups = const {},
  Map<String, Map<String, String>> fileFactors = const {},
  List<String> conditions = const [],
  double? tMinS,
  double? tMaxS,
}) {
  if (files.isEmpty || electrodes.isEmpty) return 5.0;
  final times = erpNumbers(files.first['times']);
  var peak = 0.0;
  final effectiveConds = conditions.isNotEmpty
      ? conditions
      : ((files.first['channel_conditions'] as Map?)?.keys
                .map((e) => '$e')
                .toList() ??
            const <String>[]);

  for (final gName in groups) {
    final gFiles = files.where((f) {
      final grp = resolvePublicationFileGroup(
        f,
        groups,
        participantGroups,
        fileFactors,
      );
      return grp.toUpperCase() == gName.toUpperCase();
    }).toList();
    if (gFiles.isEmpty) continue;
    for (final el in electrodes) {
      for (final cond in effectiveConds) {
        final waves = <List<double>>[];
        for (final f in gFiles) {
          final labels = (f['labels'] as List? ?? []).cast<String>();
          final cIdx = labels.indexOf(el);
          if (cIdx < 0) continue;
          final rows = (f['channel_conditions'] as Map?)?[cond] as List?;
          if (rows != null && cIdx < rows.length) {
            final w = erpNumbers(rows[cIdx]);
            if (w.length == times.length) waves.add(w);
          }
        }
        if (waves.isEmpty) continue;
        final avg = reviewAverage(waves);
        final sem = reviewSem(waves);
        for (var i = 0; i < times.length && i < avg.length; i++) {
          if (tMinS != null && times[i] < tMinS - 1e-9) continue;
          if (tMaxS != null && times[i] > tMaxS + 1e-9) continue;
          final s = i < sem.length ? sem[i] : 0.0;
          peak = math.max(peak, avg[i].abs() + s);
        }
      }
    }
  }
  if (peak <= 0.2) return 2.0;
  final padded = peak * 1.18;
  for (final nice in [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0, 12.0, 15.0, 20.0, 25.0, 30.0, 50.0]) {
    if (nice >= padded) return nice;
  }
  return (padded / 5.0).ceil() * 5.0;
}

List<double> _niceTimeTicksSec(double tMinS, double tMaxS, double pixelWidth) {
  final spanMs = (tMaxS - tMinS) * 1000.0;
  if (spanMs <= 0 || pixelWidth <= 0) return const [];
  final maxTicks = math.max(2, (pixelWidth / 44.0).floor());
  for (final stepMs in [50.0, 100.0, 200.0, 250.0, 400.0, 500.0, 1000.0]) {
    final first = ((tMinS * 1000.0) / stepMs).ceil() * stepMs;
    final ticks = <double>[];
    for (var ms = first; ms <= tMaxS * 1000.0 + 1e-6; ms += stepMs) {
      ticks.add(ms / 1000.0);
    }
    if (ticks.length <= maxTicks) return ticks;
  }
  return [0.0];
}

void _drawMonochromeOrColoredPath(
  Canvas canvas,
  List<Offset> pts,
  Color color,
  double strokeWidth,
  bool monochrome,
  int groupIndex,
) {
  if (pts.length < 2) return;
  final paint = Paint()
    ..color = color
    ..strokeWidth = strokeWidth
    ..style = PaintingStyle.stroke;

  if (!monochrome || groupIndex == 0) {
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (var i = 1; i < pts.length; i++) {
      path.lineTo(pts[i].dx, pts[i].dy);
    }
    canvas.drawPath(path, paint);
    return;
  }

  // Distinct dash patterns per group in monochrome mode
  final dashLen = groupIndex == 1 ? 8.0 : (groupIndex == 2 ? 3.0 : 10.0);
  final gapLen = groupIndex == 1 ? 4.0 : (groupIndex == 2 ? 4.0 : 4.0);
  final metrics = () {
    final p = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (var i = 1; i < pts.length; i++) {
      p.lineTo(pts[i].dx, pts[i].dy);
    }
    return p.computeMetrics();
  }();
  for (final metric in metrics) {
    var d = 0.0;
    while (d < metric.length) {
      final end = math.min(metric.length, d + dashLen);
      canvas.drawPath(metric.extractPath(d, end), paint);
      d += dashLen + gapLen;
    }
  }
}

class PublicationWaveformGridPainter extends CustomPainter {
  PublicationWaveformGridPainter({
    required this.files,
    required this.groups,
    required this.participantGroups,
    this.fileFactors = const {},
    required this.conditions,
    required this.electrodes,
    required this.components,
    required this.negativeUp,
    required this.monochrome,
    required this.showSem,
    required this.showCallouts,
    this.xMinMs,
    this.xMaxMs,
    this.yMinUv,
    this.yMaxUv,
  });

  final List<Map<String, dynamic>> files;
  final List<String> groups;
  final Map<String, String> participantGroups;
  final Map<String, Map<String, String>> fileFactors;
  final List<String> conditions;
  final List<String> electrodes;
  final List<ErpComponentDef> components;
  final bool negativeUp, monochrome, showSem, showCallouts;
  final double? xMinMs, xMaxMs, yMinUv, yMaxUv;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    if (files.isEmpty || conditions.isEmpty || electrodes.isEmpty) return;

    final times = erpNumbers(files.first['times']);
    if (times.length < 2) return;

    final nCols = conditions.length;
    final nRows = electrodes.length;

    const leftMargin = 62.0;
    final legendRows = math.max(1, (groups.length / 4).ceil());
    final topMargin = 66.0 + legendRows * 18.0;
    const rightMargin = 20.0;
    const bottomMargin = 42.0;

    final cellWidth = (size.width - leftMargin - rightMargin) / nCols;
    final cellHeight = (size.height - topMargin - bottomMargin) / nRows;

    _drawLegend(canvas, Offset(leftMargin + 10, 18), size.width - leftMargin - 30);

    for (var c = 0; c < nCols; c++) {
      final headerX = leftMargin + c * cellWidth + cellWidth / 2;
      erpText(
        canvas,
        conditions[c].toUpperCase(),
        Offset(headerX - (conditions[c].length * 4.0), topMargin - 20),
        size: 12.5,
        color: Colors.black,
      );
    }

    final rawMin = times.first;
    final rawMax = times.last;
    final tMin = (xMinMs != null) ? (xMinMs! / 1000.0).clamp(rawMin, rawMax - 0.05) : rawMin;
    final tMax = (xMaxMs != null) ? (xMaxMs! / 1000.0).clamp(tMin + 0.05, rawMax) : rawMax;

    final autoAmp = publicationAmplitude(
      files,
      electrodes,
      groups: groups,
      participantGroups: participantGroups,
      fileFactors: fileFactors,
      conditions: conditions,
      tMinS: tMin,
      tMaxS: tMax,
    );
    final loUv = yMinUv ?? -autoAmp;
    final hiUv = yMaxUv ?? autoAmp;
    final yTopVal = negativeUp ? loUv : hiUv;
    final yBotVal = negativeUp ? hiUv : loUv;

    for (var r = 0; r < nRows; r++) {
      final el = electrodes[r];
      for (var c = 0; c < nCols; c++) {
        final cond = conditions[c];
        final cellAx = Rect.fromLTWH(
          leftMargin + c * cellWidth + 24,
          topMargin + r * cellHeight + 16,
          cellWidth - 36,
          cellHeight - 36,
        );

        _drawCellAxes(
          canvas,
          cellAx,
          tMin,
          tMax,
          yTopVal,
          yBotVal,
          el,
          c == 0,
          r == nRows - 1,
        );

        // Optional component window shading inside cell
        if (showCallouts) {
          for (var ci = 0; ci < components.length; ci++) {
            final comp = components[ci];
            final c0 = comp.startMs / 1000.0;
            final c1 = comp.endMs / 1000.0;
            if (c1 < tMin || c0 > tMax) continue;
            final x0 = cellAx.left + ((c0.clamp(tMin, tMax) - tMin) / (tMax - tMin)) * cellAx.width;
            final x1 = cellAx.left + ((c1.clamp(tMin, tMax) - tMin) / (tMax - tMin)) * cellAx.width;
            canvas.drawRect(
              Rect.fromLTRB(x0, cellAx.top, x1, cellAx.bottom),
              Paint()..color = kPublicationGroupColors[ci % kPublicationGroupColors.length].withValues(alpha: 0.08),
            );
            if (r == 0 && c == nCols - 1) {
              erpText(canvas, comp.name, Offset(x0 + 2, cellAx.top + 2), size: 8.5, color: Colors.black54);
            }
          }
        }

        // Compute group grand averages for this cell (equal participant weight across all groups)
        for (var gIdx = 0; gIdx < groups.length; gIdx++) {
          final groupName = groups[gIdx];
          final groupFiles = files.where((f) {
            final g = resolvePublicationFileGroup(
              f,
              groups,
              participantGroups,
              fileFactors,
            );
            return g.toUpperCase() == groupName.toUpperCase();
          }).toList();

          final bySubj = <String, List<List<double>>>{};
          for (final f in groupFiles) {
            final subj = '${f['subject'] ?? f['path'] ?? ''}';
            final w = _extractWaveForFile(f, el, cond, times.length);
            if (w != null) bySubj.putIfAbsent(subj, () => []).add(w);
          }
          if (bySubj.isEmpty) continue;
          final subjWaves = [for (final ws in bySubj.values) reviewAverage(ws)];
          final meanWave = reviewAverage(subjWaves);
          final semWave = reviewSem(subjWaves);

          _drawWave(
            canvas,
            cellAx,
            times,
            meanWave,
            semWave,
            tMin,
            tMax,
            yTopVal,
            yBotVal,
            gIdx,
          );
        }
      }
    }

    erpText(
      canvas,
      'Fig. 1. Grand averaged ERPs across conditions and electrodes (N=${files.length} files, ${groups.length} group(s)).',
      Offset(leftMargin, size.height - 22),
      size: 11,
      color: Colors.black87,
    );
  }

  void _drawLegend(Canvas canvas, Offset at, double maxWidth) {
    final cols = math.min(4, math.max(1, groups.length));
    final colW = math.min(180.0, maxWidth / cols);
    for (var i = 0; i < groups.length; i++) {
      final g = groups[i];
      final row = i ~/ cols;
      final col = i % cols;
      final x = at.dx + col * colW;
      final y = at.dy + row * 18.0;
      final color = monochrome
          ? Colors.black
          : kPublicationGroupColors[i % kPublicationGroupColors.length];

      _drawMonochromeOrColoredPath(
        canvas,
        [Offset(x, y + 6), Offset(x + 26, y + 6)],
        color,
        2.0,
        monochrome,
        i,
      );
      erpText(
        canvas,
        g,
        Offset(x + 32, y),
        size: 10.5,
        color: monochrome ? Colors.black : color,
      );
    }
  }

  void _drawCellAxes(
    Canvas canvas,
    Rect ax,
    double tMin,
    double tMax,
    double yTopVal,
    double yBotVal,
    String electrode,
    bool showYAxis,
    bool showXAxis,
  ) {
    double x(double t) => ax.left + (t - tMin) / (tMax - tMin) * ax.width;
    double y(double v) => ax.top + (yTopVal - v) / (yTopVal - yBotVal) * ax.height;

    final zeroY = y(0).clamp(ax.top, ax.bottom);
    canvas.drawLine(
      Offset(ax.left, zeroY),
      Offset(ax.right, zeroY),
      Paint()
        ..color = const Color(0xFF475569)
        ..strokeWidth = 1.0,
    );

    if (tMin <= 0 && tMax >= 0) {
      final zeroX = x(0);
      canvas.drawLine(
        Offset(zeroX, ax.top),
        Offset(zeroX, ax.bottom),
        Paint()
          ..color = const Color(0xFFCBD5E1)
          ..strokeWidth = 0.9,
      );
    }

    erpText(
      canvas,
      electrode,
      Offset(ax.left + 2, ax.top - 12),
      size: 11,
      color: Colors.black,
    );

    if (showYAxis) {
      canvas.drawLine(
        Offset(ax.left, ax.top),
        Offset(ax.left, ax.bottom),
        Paint()
          ..color = Colors.black
          ..strokeWidth = 1.0,
      );
      for (final v in [yTopVal, 0.0, yBotVal]) {
        final tickY = y(v);
        if (tickY < ax.top - 2 || tickY > ax.bottom + 2) continue;
        canvas.drawLine(
          Offset(ax.left - 3, tickY),
          Offset(ax.left, tickY),
          Paint()..color = Colors.black,
        );
        erpText(
          canvas,
          v.abs() >= 10 || v == v.roundToDouble()
              ? '${v.round()}'
              : v.toStringAsFixed(1),
          Offset(ax.left - 24, tickY - 5),
          size: 9,
          color: Colors.black,
        );
      }
      erpText(
        canvas,
        'µV',
        Offset(ax.left - 30, ax.top - 14),
        size: 9,
        color: Colors.black,
      );
    }

    final ticksS = _niceTimeTicksSec(tMin, tMax, ax.width);
    var lastTickRight = -1e9;
    for (final t in ticksS) {
      final tickX = x(t);
      canvas.drawLine(
        Offset(tickX, zeroY - 2),
        Offset(tickX, zeroY + 2),
        Paint()..color = Colors.black,
      );
      if (showXAxis && (tickX - lastTickRight) >= 30.0) {
        final label = '${(t * 1000).round()}';
        erpText(
          canvas,
          label,
          Offset(tickX - (label.length * 2.5), ax.bottom + 4),
          size: 8.5,
          color: Colors.black87,
        );
        lastTickRight = tickX + label.length * 5.0;
      }
    }
    if (showXAxis) {
      erpText(
        canvas,
        'Time (ms)',
        Offset(ax.center.dx - 22, ax.bottom + 16),
        size: 9,
        color: Colors.black,
      );
    }
  }

  void _drawWave(
    Canvas canvas,
    Rect ax,
    List<double> times,
    List<double> wave,
    List<double> sem,
    double tMin,
    double tMax,
    double yTopVal,
    double yBotVal,
    int groupIndex,
  ) {
    double x(double t) => ax.left + (t - tMin) / (tMax - tMin) * ax.width;
    double y(double v) => ax.top + (yTopVal - v) / (yTopVal - yBotVal) * ax.height;

    final color = monochrome
        ? Colors.black
        : kPublicationGroupColors[groupIndex % kPublicationGroupColors.length];

    canvas.save();
    canvas.clipRect(ax);

    if (showSem && sem.length == times.length) {
      final idxInRange = [
        for (var i = 0; i < times.length; i++)
          if (times[i] >= tMin - 1e-6 && times[i] <= tMax + 1e-6) i,
      ];
      if (idxInRange.length >= 2) {
        final semPath = Path()
          ..moveTo(
            x(times[idxInRange.first]),
            y(wave[idxInRange.first] - sem[idxInRange.first]),
          );
        for (var k = 1; k < idxInRange.length; k++) {
          final i = idxInRange[k];
          semPath.lineTo(x(times[i]), y(wave[i] - sem[i]));
        }
        for (var k = idxInRange.length - 1; k >= 0; k--) {
          final i = idxInRange[k];
          semPath.lineTo(x(times[i]), y(wave[i] + sem[i]));
        }
        semPath.close();
        canvas.drawPath(
          semPath,
          Paint()..color = color.withValues(alpha: monochrome ? 0.08 : 0.14),
        );
      }
    }

    final pts = <Offset>[];
    for (var i = 0; i < times.length; i++) {
      if (times[i] < tMin - 1e-6 || times[i] > tMax + 1e-6) continue;
      final v = wave[i];
      if (!v.isFinite) continue;
      pts.add(Offset(x(times[i]), y(v)));
    }
    _drawMonochromeOrColoredPath(canvas, pts, color, 1.7, monochrome, groupIndex);
    canvas.restore();
  }

  List<double>? _extractWaveForFile(
    Map<String, dynamic> f,
    String electrode,
    String cond,
    int nTimes,
  ) {
    final labels = (f['labels'] as List? ?? []).cast<String>();
    final cIdx = labels.indexWhere((l) => l.toUpperCase() == electrode.toUpperCase());
    if (cIdx < 0) return null;
    final chans = f['channel_conditions'] as Map?;
    if (chans != null && chans.containsKey(cond)) {
      final rows = chans[cond] as List?;
      if (rows != null && cIdx < rows.length) {
        final w = erpNumbers(rows[cIdx]);
        if (w.length == nTimes) return w;
      }
    } else if (f['channel_a'] != null) {
      final rows = f['channel_a'] as List?;
      if (rows != null && cIdx < rows.length) {
        final w = erpNumbers(rows[cIdx]);
        if (w.length == nTimes) return w;
      }
    }
    return null;
  }

  @override
  bool shouldRepaint(covariant PublicationWaveformGridPainter old) => true;
}

// ─────────────────────────────────────────────────────────────────────────────
// FIGURE 2: TOPOGRAPHIC VOLTAGE MAPS GRID PAINTER (ALL GROUPS)
// ─────────────────────────────────────────────────────────────────────────────

class PublicationTopomapGridPainter extends CustomPainter {
  PublicationTopomapGridPainter({
    required this.files,
    required this.groups,
    required this.participantGroups,
    this.fileFactors = const {},
    required this.conditions,
    required this.components,
    this.colormap = 'RdBu_r',
    this.customLimitUv,
  });

  final List<Map<String, dynamic>> files;
  final List<String> groups;
  final Map<String, String> participantGroups;
  final Map<String, Map<String, String>> fileFactors;
  final List<String> conditions;
  final List<ErpComponentDef> components;
  final String colormap;
  final double? customLimitUv;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    if (files.isEmpty || groups.isEmpty || conditions.isEmpty) return;

    final labels = (files.first['labels'] as List? ?? []).cast<String>();
    final times = erpNumbers(files.first['times']);

    final topoChans = labels.where(isStandard1020Channel).toList();
    if (topoChans.length < 4) {
      erpText(
        canvas,
        'Need at least 4 standard 10-20 channels for scalp topoplots.',
        const Offset(40, 40),
      );
      return;
    }
    final interp = TopoInterpolator.forChannels(topoChans, res: 48);

    const leftMargin = 64.0;
    const rightMargin = 68.0;
    const topMargin = 48.0;
    final totalW = math.max(100.0, size.width - leftMargin - rightMargin);
    final groupW = totalW / groups.length;

    for (var g = 0; g < groups.length; g++) {
      final grpX = leftMargin + g * groupW + groupW / 2 - (groups[g].length * 3.5);
      erpText(
        canvas,
        groups[g],
        Offset(grpX, 10),
        size: 13,
        color: Colors.black,
      );

      final condW = (groupW - 16) / conditions.length;
      for (var c = 0; c < conditions.length; c++) {
        final cX = leftMargin + g * groupW + 8 + c * condW + condW / 2 - (conditions[c].length * 2.8);
        erpText(
          canvas,
          conditions[c],
          Offset(cX, 29),
          size: 10.5,
          color: Colors.black87,
        );
      }
    }

    final rowH = (size.height - topMargin - 44) / components.length;

    for (var r = 0; r < components.length; r++) {
      final comp = components[r];
      final rowY = topMargin + r * rowH;

      erpText(
        canvas,
        '${comp.name}\n${comp.startMs.round()}–${comp.endMs.round()}',
        Offset(8, rowY + rowH / 2 - 14),
        size: 11,
        color: Colors.black,
      );

      // Compute all maps in this row first so we can auto-scale symmetrically
      final rowMaps = <List<List<double>>>[];
      var absMax = 0.5;
      for (var g = 0; g < groups.length; g++) {
        final gFiles = files.where((f) {
          final grp = resolvePublicationFileGroup(
            f,
            groups,
            participantGroups,
            fileFactors,
          );
          return grp.toUpperCase() == groups[g].toUpperCase();
        }).toList();

        final gMaps = <List<double>>[];
        for (var c = 0; c < conditions.length; c++) {
          final cond = conditions[c];
          final chanVals = <double>[];
          for (final ch in topoChans) {
            final cIdx = labels.indexOf(ch);
            final bySubj = <String, List<double>>{};
            for (final f in gFiles) {
              final subj = '${f['subject'] ?? f['path'] ?? ''}';
              final chans = f['channel_conditions'] as Map?;
              if (chans != null && chans.containsKey(cond)) {
                final rows = chans[cond] as List?;
                if (rows != null && cIdx < rows.length) {
                  final w = erpNumbers(rows[cIdx]);
                  if (w.length == times.length) {
                    final m = reviewMeasures(
                      times,
                      w,
                      comp.startMs / 1000,
                      comp.endMs / 1000,
                      comp.polarity,
                    );
                    final mv = m['mean'];
                    if (mv != null && mv.isFinite) {
                      bySubj.putIfAbsent(subj, () => []).add(mv);
                    }
                  }
                }
              }
            }
            final subjMeans = [
              for (final vs in bySubj.values)
                vs.reduce((a, b) => a + b) / vs.length,
            ];
            final val = subjMeans.isEmpty
                ? 0.0
                : subjMeans.reduce((a, b) => a + b) / subjMeans.length;
            absMax = math.max(absMax, val.abs());
            chanVals.add(val);
          }
          gMaps.add(chanVals);
        }
        rowMaps.add(gMaps);
      }

      final lim = customLimitUv ?? math.max(1.0, (absMax * 1.1).ceilToDouble());
      final vmin = -lim;
      final vmax = lim;

      for (var g = 0; g < groups.length; g++) {
        final condW = (groupW - 16) / conditions.length;
        for (var c = 0; c < conditions.length; c++) {
          final mapBox = Rect.fromLTWH(
            leftMargin + g * groupW + 8 + c * condW + 4,
            rowY + 6,
            condW - 8,
            rowH - 12,
          );
          paintTopomap(
            canvas,
            mapBox,
            interp,
            rowMaps[g][c],
            vmin: vmin,
            vmax: vmax,
            cmap: kMplColormaps.containsKey(colormap) ? colormap : 'RdBu_r',
            fittedHead: true,
          );
        }
      }

      _drawColorbar(
        canvas,
        Rect.fromLTWH(size.width - rightMargin + 8, rowY + 14, 10, rowH - 28),
        vmin,
        vmax,
      );
    }

    erpText(
      canvas,
      'Fig. 2. Topographic voltage maps across all ${groups.length} group(s) and ${conditions.length} condition(s) ($colormap).',
      Offset(leftMargin, size.height - 20),
      size: 11,
      color: Colors.black87,
    );
  }

  void _drawColorbar(Canvas canvas, Rect box, double vmin, double vmax) {
    final lut = kMplColormaps[colormap] ?? kMplColormaps['RdBu_r']!;
    final stops = [
      for (var i = 0; i <= 8; i++)
        Color(lut[((1.0 - i / 8.0) * (lut.length - 1)).round()]),
    ];
    final gradient = ui.Gradient.linear(
      Offset(box.left, box.top),
      Offset(box.left, box.bottom),
      stops,
      [for (var i = 0; i <= 8; i++) i / 8.0],
    );
    canvas.drawRect(box, Paint()..shader = gradient);
    canvas.drawRect(
      box,
      Paint()
        ..color = Colors.black
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5,
    );

    erpText(
      canvas,
      '+${vmax.toStringAsFixed(1)} µV',
      Offset(box.right + 3, box.top - 4),
      size: 8.5,
      color: Colors.black,
    );
    erpText(
      canvas,
      '${vmin.toStringAsFixed(1)} µV',
      Offset(box.right + 3, box.bottom - 6),
      size: 8.5,
      color: Colors.black,
    );
  }

  @override
  bool shouldRepaint(covariant PublicationTopomapGridPainter old) => true;
}

// ─────────────────────────────────────────────────────────────────────────────
// FIGURE 3 & 5: COMPONENT INTERACTION LINE PLOT PAINTER
// ─────────────────────────────────────────────────────────────────────────────

typedef InteractionPoint = ({int xIndex, double mean, double sem});

Map<String, Map<String, List<InteractionPoint>>> interactionValues({
  required List<Map<String, dynamic>> files,
  required List<String> groups,
  required Map<String, String> participantGroups,
  Map<String, Map<String, String>> fileFactors = const {},
  required List<String> conditions,
  required List<String> electrodes,
  required ErpComponentDef component,
  required String metric,
  int layoutMode = 0, // 0: Panel=Cond/X=Elec/Series=Grp, 1: Panel=Elec/X=Cond/Series=Grp, 2: Panel=Grp/X=Cond/Series=Elec
}) {
  final panelNames = layoutMode == 0
      ? conditions
      : (layoutMode == 1 ? electrodes : groups);
  final xNames = layoutMode == 0
      ? electrodes
      : conditions;
  final seriesNames = layoutMode == 2 ? electrodes : groups;

  return {
    for (final panel in panelNames)
      panel: {
        for (final series in seriesNames)
          series: [
            for (var xi = 0; xi < xNames.length; xi++)
              ...(() {
                final xName = xNames[xi];
                final targetCond = layoutMode == 0 ? panel : xName;
                final targetElec = layoutMode == 0
                    ? xName
                    : (layoutMode == 1 ? panel : series);
                final targetGroup = layoutMode == 2 ? panel : series;

                final subjects = <String, List<double>>{};
                for (final f in files) {
                  final subject = '${f['subject']}';
                  final g = resolvePublicationFileGroup(
                    f,
                    groups,
                    participantGroups,
                    fileFactors,
                  );
                  if (g.toUpperCase() != targetGroup.toUpperCase()) continue;
                  final labels = (f['labels'] as List? ?? []).cast<String>();
                  final index = labels.indexWhere(
                    (l) => l.toUpperCase() == targetElec.toUpperCase(),
                  );
                  final rows =
                      (f['channel_conditions'] as Map?)?[targetCond] as List?;
                  if (index < 0 || rows == null || index >= rows.length) {
                    continue;
                  }
                  final times = erpNumbers(f['times']),
                      wave = erpNumbers(rows[index]);
                  if (times.length < 2 || wave.length != times.length) continue;
                  final measures = reviewMeasures(
                    times,
                    wave,
                    component.startMs / 1000,
                    component.endMs / 1000,
                    component.polarity,
                  );
                  final value = metric == 'peak_lat'
                      ? (measures['peak_latency'] == null
                            ? null
                            : measures['peak_latency']! * 1000)
                      : measures[metric == 'peak_amp'
                            ? 'peak_amplitude'
                            : 'mean'];
                  if (value != null && value.isFinite) {
                    subjects.putIfAbsent(subject, () => []).add(value);
                  }
                }
                final values = [
                  for (final v in subjects.values)
                    v.reduce((a, b) => a + b) / v.length,
                ];
                if (values.isEmpty) return <InteractionPoint>[];
                final mean = values.reduce((a, b) => a + b) / values.length;
                final sem = values.length < 2
                    ? 0.0
                    : math.sqrt(
                        values
                                .map((v) => math.pow(v - mean, 2))
                                .reduce((a, b) => a + b) /
                            (values.length * (values.length - 1)),
                      );
                return <InteractionPoint>[(xIndex: xi, mean: mean, sem: sem)];
              })(),
          ],
      },
  };
}

(double, double) interactionRange(
  Map<String, Map<String, List<InteractionPoint>>> values,
) {
  final points = values.values
      .expand((v) => v.values)
      .expand((v) => v)
      .toList();
  if (points.isEmpty) return (-1, 1);
  final low = math.min(0.0, points.map((p) => p.mean - p.sem).reduce(math.min));
  final high = math.max(
    0.0,
    points.map((p) => p.mean + p.sem).reduce(math.max),
  );
  final pad = math.max((high - low) * .12, .1);
  return (low - pad, high + pad);
}

class PublicationInteractionPlotPainter extends CustomPainter {
  PublicationInteractionPlotPainter({
    required this.files,
    required this.groups,
    required this.participantGroups,
    this.fileFactors = const {},
    required this.conditions,
    required this.electrodes,
    required this.component,
    required this.metric,
    required this.monochrome,
    this.layoutMode = 0,
  });
  final List<Map<String, dynamic>> files;
  final List<String> groups, conditions, electrodes;
  final Map<String, String> participantGroups;
  final Map<String, Map<String, String>> fileFactors;
  final ErpComponentDef component;
  final String metric;
  final bool monochrome;
  final int layoutMode;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    if (files.isEmpty || conditions.isEmpty || electrodes.isEmpty) return;
    final values = interactionValues(
      files: files,
      groups: groups,
      participantGroups: participantGroups,
      fileFactors: fileFactors,
      conditions: conditions,
      electrodes: electrodes,
      component: component,
      metric: metric,
      layoutMode: layoutMode,
    );
    final (low, high) = interactionRange(values);
    final metricLabel = metric == 'peak_lat'
        ? 'Peak latency (ms)'
        : metric == 'peak_amp'
        ? 'Peak amplitude (µV)'
        : 'Mean amplitude (µV)';
    erpText(
      canvas,
      '${component.name} (${component.startMs.round()}–${component.endMs.round()} ms) · $metricLabel',
      const Offset(14, 10),
      size: 12.5,
      color: Colors.black,
    );

    final panelNames = layoutMode == 0
        ? conditions
        : (layoutMode == 1 ? electrodes : groups);
    final xNames = layoutMode == 0 ? electrodes : conditions;
    final seriesNames = layoutMode == 2 ? electrodes : groups;

    final colsLegend = math.min(4, math.max(1, seriesNames.length));
    final colW = math.min(180.0, (size.width - 28) / colsLegend);
    for (var s = 0; s < seriesNames.length; s++) {
      final lx = 14.0 + (s % colsLegend) * colW;
      final ly = 34.0 + (s ~/ colsLegend) * 18.0;
      final color = monochrome
          ? Colors.black
          : kPublicationGroupColors[s % kPublicationGroupColors.length];
      canvas.drawLine(
        Offset(lx, ly + 6),
        Offset(lx + 20, ly + 6),
        Paint()
          ..color = color
          ..strokeWidth = 1.6,
      );
      canvas.drawCircle(
        Offset(lx + 10, ly + 6),
        3.2,
        Paint()..color = s.isEven ? Colors.white : color,
      );
      canvas.drawCircle(
        Offset(lx + 10, ly + 6),
        3.2,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.3,
      );
      erpText(
        canvas,
        seriesNames[s],
        Offset(lx + 26, ly),
        size: 10.5,
        color: monochrome ? Colors.black : color,
      );
    }

    final top = 74.0 + ((seriesNames.length - 1) ~/ colsLegend) * 18.0;
    final panelWidth = (size.width - 70) / panelNames.length;
    for (var c = 0; c < panelNames.length; c++) {
      final ax = Rect.fromLTWH(
        58 + c * panelWidth,
        top,
        panelWidth - 22,
        size.height - top - 66,
      );
      double y(double v) => ax.bottom - (v - low) / (high - low) * ax.height;
      double x(int e) => ax.left + (e + .5) / xNames.length * ax.width;
      erpText(
        canvas,
        panelNames[c],
        Offset(ax.left, ax.top - 18),
        size: 11,
        color: Colors.black,
      );
      final pen = Paint()
        ..color = Colors.black
        ..strokeWidth = 1;
      canvas.drawLine(ax.topLeft, ax.bottomLeft, pen);
      canvas.drawLine(ax.bottomLeft, ax.bottomRight, pen);
      for (var t = 0; t <= 4; t++) {
        final v = low + (high - low) * t / 4;
        if (c == 0) {
          erpText(
            canvas,
            v.toStringAsFixed(metric == 'peak_lat' ? 0 : 1),
            Offset(ax.left - 40, y(v) - 5),
            size: 9,
            color: Colors.black,
          );
        }
        canvas.drawLine(
          Offset(ax.left, y(v)),
          Offset(ax.right, y(v)),
          Paint()..color = Colors.grey.shade200,
        );
      }
      for (var e = 0; e < xNames.length; e++) {
        erpText(
          canvas,
          xNames[e],
          Offset(x(e) - (xNames[e].length * 3.0), ax.bottom + 8),
          size: 10,
          color: Colors.black,
        );
      }
      canvas.save();
      canvas.clipRect(ax);
      for (var s = 0; s < seriesNames.length; s++) {
        final points = values[panelNames[c]]![seriesNames[s]]!;
        final color = monochrome
            ? Colors.black
            : kPublicationGroupColors[s % kPublicationGroupColors.length];
        final line = Paint()
          ..color = color
          ..strokeWidth = 1.5;
        for (var i = 0; i < points.length; i++) {
          final p = points[i],
              pt = Offset(x(points[i].xIndex), y(points[i].mean));
          if (i > 0 && p.xIndex == points[i - 1].xIndex + 1) {
            canvas.drawLine(
              Offset(x(points[i - 1].xIndex), y(points[i - 1].mean)),
              pt,
              line,
            );
          }
          canvas.drawLine(
            Offset(pt.dx, y(p.mean - p.sem)),
            Offset(pt.dx, y(p.mean + p.sem)),
            line,
          );
          canvas.drawCircle(
            pt,
            3.2,
            Paint()..color = s.isEven ? Colors.white : color,
          );
          canvas.drawCircle(
            pt,
            3.2,
            Paint()
              ..color = color
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.3,
          );
        }
      }
      canvas.restore();
      if (values[panelNames[c]]!.values.every((v) => v.isEmpty)) {
        erpText(
          canvas,
          'No observations',
          Offset(ax.left + 8, ax.center.dy),
          size: 10,
          color: Colors.black54,
        );
      }
    }
    erpText(
      canvas,
      '${layoutMode == 0 ? "Electrode" : "Condition"} · mean ± SEM across participants',
      Offset(58, size.height - 24),
      size: 10,
      color: Colors.black,
    );
  }

  @override
  bool shouldRepaint(covariant PublicationInteractionPlotPainter old) => true;
}

// ─────────────────────────────────────────────────────────────────────────────
// W3C VECTOR SVG GENERATORS
// ─────────────────────────────────────────────────────────────────────────────

String generateWaveformGridSvg({
  required List<Map<String, dynamic>> files,
  required List<String> groups,
  required Map<String, String> participantGroups,
  Map<String, Map<String, String>> fileFactors = const {},
  required List<String> conditions,
  required List<String> electrodes,
  required List<ErpComponentDef> components,
  required bool negativeUp,
  required bool monochrome,
  required bool showSem,
  required bool showCallouts,
  double? xMinMs,
  double? xMaxMs,
  double? yMinUv,
  double? yMaxUv,
}) {
  final times = erpNumbers(files.first['times']);
  final nCols = conditions.length;
  final nRows = electrodes.length;

  final w = math.max(840.0, nCols * 260.0 + 100.0);
  final legendRows = math.max(1, (groups.length / 4).ceil());
  final topMargin = 66.0 + legendRows * 18.0;
  final h = 185.0 * nRows + topMargin + 44.0;
  const leftMargin = 62.0;
  final cellW = (w - leftMargin - 20) / nCols;
  final cellH = (h - topMargin - 44.0) / nRows;

  final sb = StringBuffer();
  sb.writeln(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $w $h" width="$w" height="$h">',
  );
  sb.writeln('<rect width="100%" height="100%" fill="white"/>');

  // Legend
  final legendCols = math.min(4, math.max(1, groups.length));
  final legendColW = math.min(180.0, (w - leftMargin - 20) / legendCols);
  for (var g = 0; g < groups.length; g++) {
    final lx = leftMargin + 10 + (g % legendCols) * legendColW;
    final ly = 18.0 + (g ~/ legendCols) * 18.0;
    final color = monochrome ? 'black' : kPublicationGroupHexes[g % kPublicationGroupHexes.length];
    final dash = monochrome && g > 0 ? ' stroke-dasharray="6,3"' : '';
    sb.writeln(
      '<line x1="$lx" y1="${ly + 4}" x2="${lx + 24}" y2="${ly + 4}" stroke="$color" stroke-width="2"$dash/>',
    );
    sb.writeln(
      '<text x="${lx + 30}" y="${ly + 8}" font-family="Arial, sans-serif" font-size="11" fill="$color">${groups[g]}</text>',
    );
  }

  for (var c = 0; c < nCols; c++) {
    final x = leftMargin + c * cellW + cellW / 2;
    sb.writeln(
      '<text x="$x" y="${topMargin - 16}" font-family="Arial, sans-serif" font-size="13" font-weight="bold" text-anchor="middle">${conditions[c].toUpperCase()}</text>',
    );
  }

  final rawMin = times.first;
  final rawMax = times.last;
  final tMin = (xMinMs != null) ? (xMinMs / 1000.0).clamp(rawMin, rawMax - 0.05) : rawMin;
  final tMax = (xMaxMs != null) ? (xMaxMs / 1000.0).clamp(tMin + 0.05, rawMax) : rawMax;
  final amplitude = publicationAmplitude(
    files,
    electrodes,
    groups: groups,
    participantGroups: participantGroups,
    fileFactors: fileFactors,
    conditions: conditions,
    tMinS: tMin,
    tMaxS: tMax,
  );
  final loUv = yMinUv ?? -amplitude;
  final hiUv = yMaxUv ?? amplitude;
  final yTopVal = negativeUp ? loUv : hiUv;
  final yBotVal = negativeUp ? hiUv : loUv;

  for (var r = 0; r < nRows; r++) {
    final el = electrodes[r];
    for (var c = 0; c < nCols; c++) {
      final cond = conditions[c];
      final axLeft = leftMargin + c * cellW + 24;
      final axTop = topMargin + r * cellH + 16;
      final axW = cellW - 36;
      final axH = cellH - 36;

      double sx(double t) => axLeft + (t - tMin) / (tMax - tMin) * axW;
      double sy(double v) => axTop + (yTopVal - v) / (yTopVal - yBotVal) * axH;

      final zY = sy(0).clamp(axTop, axTop + axH);
      sb.writeln(
        '<line x1="$axLeft" y1="$zY" x2="${axLeft + axW}" y2="$zY" stroke="#64748b" stroke-width="1"/>',
      );
      if (tMin <= 0 && tMax >= 0) {
        final zX = sx(0);
        sb.writeln(
          '<line x1="$zX" y1="$axTop" x2="$zX" y2="${axTop + axH}" stroke="#cbd5e1" stroke-width="1"/>',
        );
      }
      if (c == 0) {
        sb.writeln(
          '<text x="${axLeft - 4}" y="${axTop - 4}" font-family="Arial, sans-serif" font-size="11" font-weight="bold">$el</text>',
        );
        for (final v in [yTopVal, 0.0, yBotVal]) {
          final ty = sy(v);
          sb.writeln(
            '<text x="${axLeft - 6}" y="${ty + 3}" font-family="Arial, sans-serif" font-size="9" text-anchor="end">${v.round()}</text>',
          );
        }
      }
      if (r == nRows - 1) {
        for (final t in _niceTimeTicksSec(tMin, tMax, axW)) {
          final tx = sx(t);
          sb.writeln(
            '<text x="$tx" y="${axTop + axH + 14}" font-family="Arial, sans-serif" font-size="9" text-anchor="middle">${(t * 1000).round()}</text>',
          );
        }
      }

      sb.writeln(
        '<defs><clipPath id="wave$r-$c"><rect x="$axLeft" y="$axTop" width="$axW" height="$axH"/></clipPath></defs><g clip-path="url(#wave$r-$c)">',
      );
      for (var g = 0; g < groups.length; g++) {
        final gName = groups[g];
        final gFiles = files
            .where(
              (f) =>
                  resolvePublicationFileGroup(
                    f,
                    groups,
                    participantGroups,
                    fileFactors,
                  ).toUpperCase() ==
                  gName.toUpperCase(),
            )
            .toList();
        final bySubj = <String, List<List<double>>>{};
        for (final f in gFiles) {
          final subj = '${f['subject'] ?? f['path'] ?? ''}';
          final labels = (f['labels'] as List? ?? []).cast<String>();
          final cIdx = labels.indexWhere((l) => l.toUpperCase() == el.toUpperCase());
          if (cIdx < 0) continue;
          final chans = f['channel_conditions'] as Map?;
          if (chans != null && chans.containsKey(cond)) {
            final rows = chans[cond] as List?;
            if (rows != null && cIdx < rows.length) {
              final wv = erpNumbers(rows[cIdx]);
              if (wv.length == times.length) {
                bySubj.putIfAbsent(subj, () => []).add(wv);
              }
            }
          }
        }
        if (bySubj.isEmpty) continue;
        final avg = reviewAverage([for (final ws in bySubj.values) reviewAverage(ws)]);

        final pBuf = StringBuffer();
        var started = false;
        for (var i = 0; i < times.length; i++) {
          if (times[i] < tMin - 1e-6 || times[i] > tMax + 1e-6) continue;
          pBuf.write(started ? ' L ' : 'M ');
          pBuf.write('${sx(times[i]).toStringAsFixed(1)},${sy(avg[i]).toStringAsFixed(1)}');
          started = true;
        }
        final strokeColor = monochrome
            ? 'black'
            : kPublicationGroupHexes[g % kPublicationGroupHexes.length];
        final strokeDash = (g > 0 && monochrome)
            ? ' stroke-dasharray="5,3"'
            : '';
        sb.writeln(
          '<path d="$pBuf" fill="none" stroke="$strokeColor" stroke-width="1.6"$strokeDash/>',
        );
      }
      sb.writeln('</g>');
    }
  }

  sb.writeln('</svg>');
  return sb.toString();
}

String generateInteractionPlotSvg({
  required List<Map<String, dynamic>> files,
  required List<String> groups,
  required Map<String, String> participantGroups,
  Map<String, Map<String, String>> fileFactors = const {},
  required List<String> conditions,
  required List<String> electrodes,
  required ErpComponentDef component,
  required String metric,
  required bool monochrome,
  int layoutMode = 0,
}) {
  String esc(String v) => v
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
  final values = interactionValues(
    files: files,
    groups: groups,
    participantGroups: participantGroups,
    fileFactors: fileFactors,
    conditions: conditions,
    electrodes: electrodes,
    component: component,
    metric: metric,
    layoutMode: layoutMode,
  );
  final (low, high) = interactionRange(values);
  final sb = StringBuffer(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 860 410"><rect width="860" height="410" fill="white"/>',
  );
  void text(String v, double x, double y, {String fill = 'black'}) => sb.write(
    '<text x="$x" y="$y" font-family="sans-serif" font-size="11" fill="$fill">${esc(v)}</text>',
  );
  text(
    '${component.name} (${component.startMs.round()}–${component.endMs.round()} ms) · ${metric == 'peak_lat'
        ? 'Peak latency (ms)'
        : metric == 'peak_amp'
        ? 'Peak amplitude (µV)'
        : 'Mean amplitude (µV)'}',
    14,
    22,
  );

  final panelNames = layoutMode == 0
      ? conditions
      : (layoutMode == 1 ? electrodes : groups);
  final xNames = layoutMode == 0 ? electrodes : conditions;
  final seriesNames = layoutMode == 2 ? electrodes : groups;

  final colsLegend = math.min(4, math.max(1, seriesNames.length));
  for (var s = 0; s < seriesNames.length; s++) {
    final lx = 14.0 + (s % colsLegend) * 180.0;
    final ly = 42.0 + (s ~/ colsLegend) * 18.0;
    final color = monochrome ? 'black' : kPublicationGroupHexes[s % kPublicationGroupHexes.length];
    sb.write(
      '<line x1="$lx" y1="$ly" x2="${lx + 20}" y2="$ly" stroke="$color" stroke-width="1.6"/>'
      '<circle cx="${lx + 10}" cy="$ly" r="3" fill="${s.isEven ? 'white' : color}" stroke="$color"/>',
    );
    text(seriesNames[s], lx + 26, ly + 4, fill: color);
  }

  final top = 74.0 + ((seriesNames.length - 1) ~/ colsLegend) * 18.0;
  for (var c = 0; c < panelNames.length; c++) {
    final width = 790 / panelNames.length,
        left = 58 + c * width,
        right = left + width - 22,
        bottom = 340.0;
    double x(int e) => left + (e + .5) / xNames.length * (right - left);
    double y(double v) => bottom - (v - low) / (high - low) * (bottom - top);
    text(panelNames[c], left, top - 8);
    sb.write(
      '<path d="M$left $top V$bottom H$right" fill="none" stroke="black"/><defs><clipPath id="panel$c"><rect x="$left" y="$top" width="${right - left}" height="${bottom - top}"/></clipPath></defs>',
    );
    for (var e = 0; e < xNames.length; e++) {
      text(xNames[e], x(e) - 10, bottom + 20);
    }
    for (var t = 0; t <= 4; t++) {
      final v = low + (high - low) * t / 4;
      if (c == 0) {
        text(
          v.toStringAsFixed(metric == 'peak_lat' ? 0 : 1),
          left - 40,
          y(v) + 4,
        );
      }
    }
    sb.write('<g clip-path="url(#panel$c)">');
    for (var s = 0; s < seriesNames.length; s++) {
      final points = values[panelNames[c]]![seriesNames[s]]!;
      final color = monochrome
          ? 'black'
          : kPublicationGroupHexes[s % kPublicationGroupHexes.length];
      for (var i = 0; i < points.length; i++) {
        final p = points[i];
        if (i > 0 && p.xIndex == points[i - 1].xIndex + 1) {
          sb.write(
            '<line x1="${x(points[i - 1].xIndex)}" y1="${y(points[i - 1].mean)}" x2="${x(p.xIndex)}" y2="${y(p.mean)}" stroke="$color" stroke-width="1.5"/>',
          );
        }
        sb.write(
          '<line x1="${x(p.xIndex)}" y1="${y(p.mean - p.sem)}" x2="${x(p.xIndex)}" y2="${y(p.mean + p.sem)}" stroke="$color"/><circle cx="${x(p.xIndex)}" cy="${y(p.mean)}" r="3" fill="${s.isEven ? 'white' : color}" stroke="$color"/>',
        );
      }
    }
    sb.write('</g>');
  }
  text(
    '${layoutMode == 0 ? "Electrode" : "Condition"} · mean ± SEM across participants',
    58,
    384,
  );
  sb.write('</svg>');
  return sb.toString();
}
