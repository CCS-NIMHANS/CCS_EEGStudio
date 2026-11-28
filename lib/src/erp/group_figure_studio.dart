import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import '../extraction_service.dart';
import '../group_statistics_plots.dart';
import '../theme.dart';

class ErpGroupFigureStudio extends StatefulWidget {
  const ErpGroupFigureStudio({
    super.key,
    required this.inspection,
    required this.csvPath,
    required this.config,
    required this.levelOrder,
    required this.excludedLevels,
    required this.findPython,
    this.differenceOnly = false,
    this.initialPlotDifferences = false,
    this.initialDifferencePairs = const [],
  });

  final Map<String, dynamic> inspection;
  final String csvPath;
  final StatsPlotLayoutConfig config;
  final Map<String, List<String>> levelOrder;
  final Map<String, Set<String>> excludedLevels;
  final Future<String?> Function() findPython;
  final bool differenceOnly;
  final bool initialPlotDifferences;
  final List<List<String>> initialDifferencePairs;

  @override
  State<ErpGroupFigureStudio> createState() => _ErpGroupFigureStudioState();
}

class _ErpGroupFigureStudioState extends State<ErpGroupFigureStudio> {
  final folder = TextEditingController(),
      output = TextEditingController(),
      channels = TextEditingController(text: 'Cz');
  final width = TextEditingController(text: '12'),
      height = TextEditingController(text: '7'),
      dpi = TextEditingController(text: '300'),
      font = TextEditingController(text: '10'),
      line = TextEditingController(text: '1.6');
  final start = TextEditingController(text: '300'),
      end = TextEditingController(text: '600'),
      predictor = TextEditingController(text: 'Class_B_minus_A');
  final xmin = TextEditingController(),
      xmax = TextEditingController(),
      ymin = TextEditingController(),
      ymax = TextEditingController(),
      colorLimit = TextEditingController();
  final fmin = TextEditingController(text: '2'),
      fmax = TextEditingController(text: '40'),
      nfreq = TextEditingController(text: '24'),
      baseline0 = TextEditingController(text: '-200'),
      baseline1 = TextEditingController(text: '0');

  String mode = 'erp', error = 'SEM', colormap = 'RdBu_r', status = '';
  String? series, facet, row, conditionA, conditionB;
  bool busy = false, negativeUp = true, autoSize = true, showWindow = true;
  bool plotDifferences = false;
  bool cancelled = false;
  String? image;
  List<String> warnings = [];
  Process? process;
  late final Map<String, int> colors;
  final Set<String> selectedConditions = {};
  final Set<String> selectedFacets = {};
  final List<List<String>> differencePairs = [];

  static const _defaultPalette = [
    0xFF0072B2,
    0xFFD55E00,
    0xFF009E73,
    0xFFCC79A7,
    0xFFB45309,
    0xFF6D28D9,
    0xFF0284C7,
    0xFF334155,
  ];

  Map<String, dynamic> get levels => Map<String, dynamic>.from(
    widget.inspection['factor_levels'] as Map? ?? {},
  );

  List<String> _orderedLevels(String? factor) {
    if (factor == null) return const [];
    final raw = (levels[factor] as List? ?? const []).map((v) => '$v').toList();
    final excl = widget.excludedLevels[factor] ?? const <String>{};
    final allowed = raw.where((v) => !excl.contains(v)).toList();
    final custom = widget.levelOrder[factor];
    if (custom == null || custom.isEmpty) return allowed;
    return [
      for (final l in custom)
        if (allowed.contains(l)) l,
      for (final l in allowed)
        if (!custom.contains(l)) l,
    ];
  }

  @override
  void initState() {
    super.initState();
    final parent = File(widget.csvPath).parent;
    folder.text = parent.path.endsWith('Group_Statistics')
        ? parent.parent.path
        : parent.path;
    output.text =
        '${folder.text}${Platform.pathSeparator}Publication_Figures_Groups';
    series = widget.config.seriesFactor;
    facet = widget.config.facetColFactor;
    row = widget.config.facetRowFactor;
    colors = Map.from(widget.config.seriesColors);

    final conditions = _orderedLevels('Condition')
        .where((c) => c != 'B_minus_A' && c != 'B - A')
        .toList();
    selectedConditions.addAll(conditions);
    if (facet != null) {
      selectedFacets.addAll(_orderedLevels(facet));
    }

    conditionA = conditions.contains('Freq') ? 'Freq' : conditions.firstOrNull;
    conditionB = conditions.contains('Rare')
        ? 'Rare'
        : conditions.length > 1
        ? conditions[1]
        : conditions.firstOrNull;

    plotDifferences = widget.initialPlotDifferences;
    if (widget.initialDifferencePairs.isNotEmpty) {
      differencePairs.addAll(
        widget.initialDifferencePairs.map((p) => [p[0], p[1]]),
      );
    } else if (conditions.length >= 2) {
      final base = conditions.contains('Freq') ? 'Freq' : conditions.first;
      for (final c in conditions) {
        if (c != base) differencePairs.add([c, base]);
      }
    }

    if (widget.differenceOnly) mode = 'difference_table';
  }

  @override
  void dispose() {
    cancelled = true;
    stopProcess();
    for (final c in [
      folder,
      output,
      channels,
      width,
      height,
      dpi,
      font,
      line,
      start,
      end,
      predictor,
      xmin,
      xmax,
      ymin,
      ymax,
      colorLimit,
      fmin,
      fmax,
      nfreq,
      baseline0,
      baseline1,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> stopProcess() async {
    cancelled = true;
    final active = process;
    if (active == null) return;
    if (Platform.isWindows) {
      try {
        await Process.run('taskkill', ['/PID', '${active.pid}', '/T', '/F']);
      } catch (_) {
        active.kill();
      }
    } else {
      active.kill();
    }
  }

  void _assignStudioRole(String role, String? next) {
    final oldVal = switch (role) {
      'series' => series,
      'facet' => facet,
      'row' => row,
      _ => null,
    };
    setState(() {
      if (next != null) {
        if (role != 'series' && series == next) series = oldVal;
        if (role != 'facet' && facet == next) facet = oldVal;
        if (role != 'row' && row == next) row = oldVal;
      }
      switch (role) {
        case 'series':
          series = next;
        case 'facet':
          facet = next;
          selectedFacets
            ..clear()
            ..addAll(_orderedLevels(facet));
        case 'row':
          row = next;
      }
    });
  }

  Widget _field(
    TextEditingController c,
    String label, {
    double w = 135,
    bool enabled = true,
  }) => SizedBox(
    width: w,
    child: TextField(
      controller: c,
      enabled: enabled && !busy,
      decoration: InputDecoration(labelText: label, isDense: true),
    ),
  );

  Widget _factorDropdown(String label, String? value, String role) {
    final candidates = levels.keys
        .where((f) => f != 'participant_id' && f != 'subjid')
        .toList();
    final safeVal = (value != null && candidates.contains(value)) ? value : '';
    return SizedBox(
      width: 210,
      child: DropdownButtonFormField<String>(
        key: ValueKey('studio-role-$role-$safeVal'),
        isExpanded: true,
        initialValue: safeVal,
        decoration: InputDecoration(labelText: label, isDense: true),
        items: [
          const DropdownMenuItem(value: '', child: Text('None')),
          for (final f in candidates)
            DropdownMenuItem(
              value: f,
              child: Text(widget.config.factorLabel(f)),
            ),
        ],
        onChanged: busy
            ? null
            : (v) => _assignStudioRole(role, (v == null || v.isEmpty) ? null : v),
      ),
    );
  }

  Future<void> run() async {
    if (busy) return;
    cancelled = false;
    setState(() {
      busy = true;
      warnings = [];
      status =
          'Preparing grouped ${widget.differenceOnly ? 'difference measurements' : 'publication figures'}…';
    });
    Directory? runtime;
    try {
      final python = await widget.findPython();
      if (python == null) {
        throw StateError(
          'Python with numpy, pandas, scipy, statsmodels and matplotlib is required.',
        );
      }
      runtime = await Directory.systemTemp.createTemp('ccs-group-figures-');
      for (final name in ['erp_group_figures.py', 'group_stats.py']) {
        await File(
          '${runtime.path}${Platform.pathSeparator}$name',
        ).writeAsString(await rootBundle.loadString('assets/$name'));
      }
      final headers = (widget.inspection['headers'] as List).cast<String>();
      final metadata = [
        for (final r in widget.inspection['rows'] as List)
          {
            for (final (i, key) in headers.indexed)
              key: i < (r as List).length ? '${r[i]}' : '',
          },
      ];
      final options = <String, dynamic>{
        'folder': folder.text,
        'output_dir': output.text,
        'metadata': metadata,
        'mode': mode,
        'subject_col': widget.inspection['detected_subject_col'],
        'series_factor': series,
        'facet_factor': facet,
        'row_factor': row,
        'factor_labels': widget.config.factorLabels,
        'level_labels': widget.config.levelLabels,
        'colors': colors,
        'level_order': widget.levelOrder,
        'excluded_levels': {
          for (final e in widget.excludedLevels.entries) e.key: e.value.toList(),
        },
        'channels': channels.text,
        'window_start': double.tryParse(start.text) ?? 300,
        'window_end': double.tryParse(end.text) ?? 600,
        'show_window': showWindow,
        'fmin': double.tryParse(fmin.text) ?? 2,
        'fmax': double.tryParse(fmax.text) ?? 40,
        'n_freqs': int.tryParse(nfreq.text) ?? 24,
        'baseline_start': double.tryParse(baseline0.text) ?? -200,
        'baseline_end': double.tryParse(baseline1.text) ?? 0,
        'predictor': predictor.text,
        'negative_up': negativeUp,
        'error': error,
        'colormap': colormap,
        'condition_a': conditionA,
        'condition_b': conditionB,
        'auto_size': autoSize,
        'width': double.tryParse(width.text) ?? 12,
        'height': double.tryParse(height.text) ?? 7,
        'dpi': int.tryParse(dpi.text) ?? 300,
        'font_size': double.tryParse(font.text) ?? 10,
        'line_width': double.tryParse(line.text) ?? 1.6,
        'x_min': double.tryParse(xmin.text),
        'x_max': double.tryParse(xmax.text),
        'y_min': double.tryParse(ymin.text),
        'y_max': double.tryParse(ymax.text),
        'color_limit': double.tryParse(colorLimit.text),
        'plot_differences_only': plotDifferences,
        'difference_pairs': differencePairs,
        if (selectedConditions.isNotEmpty)
          'selected_conditions': selectedConditions.toList(),
        if (selectedFacets.isNotEmpty)
          'selected_facets': selectedFacets.toList(),
        if (mode == 'ersp' || mode == 'itc')
          'engine': ExtractionService.findEngine(),
      };
      final input = File('${runtime.path}${Platform.pathSeparator}input.json'),
          result = File('${runtime.path}${Platform.pathSeparator}result.json');
      await input.writeAsString(jsonEncode(options));
      if (!mounted || cancelled) return;
      process = await Process.start(
        python,
        [
          '${runtime.path}${Platform.pathSeparator}erp_group_figures.py',
          input.path,
          result.path,
        ],
        environment: {
          'MPLCONFIGDIR': '${runtime.path}${Platform.pathSeparator}mpl',
          'OPENBLAS_NUM_THREADS': '1',
        },
      );
      final errors = process!.stderr.transform(utf8.decoder).join();
      final stdout = process!.stdout.drain<void>();
      final exit = await process!.exitCode;
      await stdout;
      final message = await errors;
      process = null;
      if (exit != 0) {
        throw StateError(
          message.length > 4000
              ? message.substring(message.length - 4000)
              : message,
        );
      }
      final data = Map<String, dynamic>.from(
        jsonDecode(await result.readAsString()) as Map,
      );
      if (!mounted) return;
      if (widget.differenceOnly) {
        Navigator.pop(context, data['csv']);
        return;
      }
      final path =
          (data['paths'] as List).firstWhere((p) => '$p'.endsWith('.png'))
              as String;
      await FileImage(File(path)).evict();
      setState(() {
        image = path;
        warnings = (data['warnings'] as List? ?? []).map((w) => '$w').toList();
        status =
            'Saved PNG, SVG, PDF, data and manifest to ${output.text} (${data['n_matched_files']} recordings).';
      });
    } catch (e) {
      if (mounted) setState(() => status = '$e');
    } finally {
      process = null;
      if (runtime != null) await runtime.delete(recursive: true);
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _openOutputFolder() async {
    try {
      final path = output.text.trim();
      if (path.isEmpty) return;
      if (Platform.isMacOS) {
        await Process.run('open', [path]);
      } else if (Platform.isWindows) {
        await Process.run('explorer.exe', [path]);
      } else {
        await Process.run('xdg-open', [path]);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final conditions = _orderedLevels('Condition')
        .where((c) => c != 'B_minus_A' && c != 'B - A')
        .toList();
    final facetLevels = facet == null ? const <String>[] : _orderedLevels(facet);
    final seriesLevels = series == null ? const <String>[] : _orderedLevels(series);
    final isWaveformMode = mode == 'erp' || mode == 'rerp' || mode == 'ml';
    final isTfMode = mode == 'ersp' || mode == 'itc';
    final isTopoMode = mode == 'topo';

    return Theme(
      data: buildCcsLightTheme(),
      child: Scaffold(
        backgroundColor: CcsTheme.panel,
        appBar: AppBar(
          title: Text(
            widget.differenceOnly
                ? 'ERP difference → group models'
                : 'Grouped ERP publication studio',
          ),
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Card 1: Source & Output Folders (compact collapsible)
              Card(
                child: ExpansionTile(
                  initiallyExpanded: false,
                  title: const Text(
                    'Source .ccserp & output folders',
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    'Source: ${folder.text}  →  Output: ${output.text.split(Platform.pathSeparator).last}',
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: CcsTheme.textSecondary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Uses reviewed participant IDs, factors, exclusions and level order. Equal participant weight within every cell.',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: CcsTheme.textSecondary,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: folder,
                                  decoration: const InputDecoration(
                                    labelText: 'Folder containing saved .ccserp files',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              OutlinedButton(
                                onPressed: busy
                                    ? null
                                    : () async {
                                        final p = await FilePicker.getDirectoryPath();
                                        if (p != null) setState(() => folder.text = p);
                                      },
                                child: const Text('Choose folder…'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: output,
                                  decoration: const InputDecoration(
                                    labelText: 'Output folder',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              OutlinedButton(
                                onPressed: busy
                                    ? null
                                    : () async {
                                        final p = await FilePicker.getDirectoryPath();
                                        if (p != null) setState(() => output.text = p);
                                      },
                                child: const Text('Change output…'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              if (!widget.differenceOnly) ...[
                // Card 2: Figure & Grouping Layout
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '1. Figure & Grouping Layout',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: CcsTheme.text,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 12,
                          runSpacing: 10,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            SizedBox(
                              width: 230,
                              child: DropdownButtonFormField<String>(
                                isExpanded: true,
                                initialValue: mode,
                                decoration: const InputDecoration(
                                  labelText: 'Figure',
                                  isDense: true,
                                ),
                                items: [
                                  for (final e in const {
                                    'erp': 'ERP grand averages',
                                    'topo': 'Voltage topographies',
                                    'ersp': 'ERSP (recompute epochs)',
                                    'itc': 'ITC (recompute epochs)',
                                    'rerp': 'rERP coefficients',
                                    'ml': 'ML decoding AUC',
                                  }.entries)
                                    DropdownMenuItem(
                                      value: e.key,
                                      child: Text(e.value),
                                    ),
                                ],
                                onChanged: busy
                                    ? null
                                    : (v) => setState(() => mode = v!),
                              ),
                            ),
                            if ((mode == 'erp' || isTopoMode) &&
                                conditions.length >= 2)
                              SegmentedButton<bool>(
                                showSelectedIcon: false,
                                style: SegmentedButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  textStyle: const TextStyle(fontSize: 11.5),
                                ),
                                segments: const [
                                  ButtonSegment(
                                    value: false,
                                    label: Text('Condition ERPs'),
                                  ),
                                  ButtonSegment(
                                    value: true,
                                    label: Text('ERP Differences (B − A)'),
                                  ),
                                ],
                                selected: {plotDifferences},
                                onSelectionChanged: busy
                                    ? null
                                    : (s) => setState(
                                        () => plotDifferences = s.first,
                                      ),
                              ),
                            _factorDropdown('Lines / cohorts', series, 'series'),
                            _factorDropdown('Column facets', facet, 'facet'),
                            _factorDropdown('Row facets', row, 'row'),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 12,
                          runSpacing: 10,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            if (!isTopoMode && mode != 'ml')
                              _field(
                                channels,
                                'ROI channels (comma separated)',
                                w: 230,
                              ),
                            if (isTopoMode || mode == 'erp') ...[
                              _field(start, 'Window / Topo start (ms)', w: 165),
                              _field(end, 'Window / Topo end (ms)', w: 165),
                            ],
                            if (mode == 'erp')
                              FilterChip(
                                label: const Text(
                                  'Shade window on waveform',
                                  style: TextStyle(fontSize: 11.5),
                                ),
                                selected: showWindow,
                                onSelected: busy
                                    ? null
                                    : (v) => setState(() => showWindow = v),
                              ),
                            if (mode == 'rerp')
                              _field(predictor, 'Saved predictor', w: 200),
                            if (isTfMode) ...[
                              _field(fmin, 'Minimum Hz', w: 120),
                              _field(fmax, 'Maximum Hz', w: 120),
                              _field(nfreq, 'Frequencies', w: 115),
                              _field(baseline0, 'Baseline start ms', w: 135),
                              _field(baseline1, 'Baseline end ms', w: 135),
                              for (final isA in [true, false])
                                SizedBox(
                                  width: 170,
                                  child: DropdownButtonFormField<String>(
                                    isExpanded: true,
                                    initialValue: isA ? conditionA : conditionB,
                                    decoration: InputDecoration(
                                      labelText: isA
                                          ? 'Condition A'
                                          : 'Condition B',
                                      isDense: true,
                                    ),
                                    items: [
                                      for (final v in conditions)
                                        DropdownMenuItem(
                                          value: v,
                                          child: Text(
                                            widget.config.levelLabel(
                                              'Condition',
                                              v,
                                            ),
                                          ),
                                        ),
                                    ],
                                    onChanged: busy
                                        ? null
                                        : (v) => setState(() {
                                            if (isA) {
                                              conditionA = v;
                                            } else {
                                              conditionB = v;
                                            }
                                          }),
                                  ),
                                ),
                            ],
                          ],
                        ),
                        if ((mode == 'erp' || isTopoMode) &&
                            !plotDifferences &&
                            conditions.length > 1) ...[
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              const Text(
                                'Conditions to plot:',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                  color: CcsTheme.textSecondary,
                                ),
                              ),
                              for (final c in conditions)
                                FilterChip(
                                  visualDensity: VisualDensity.compact,
                                  label: Text(
                                    widget.config.levelLabel('Condition', c),
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                  selected: selectedConditions.contains(c),
                                  onSelected: busy
                                      ? null
                                      : (sel) => setState(() {
                                          if (sel) {
                                            selectedConditions.add(c);
                                          } else if (selectedConditions.length >
                                              1) {
                                            selectedConditions.remove(c);
                                          }
                                        }),
                                ),
                            ],
                          ),
                        ],
                        if ((mode == 'erp' || isTopoMode) &&
                            plotDifferences &&
                            differencePairs.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              const Text(
                                'Difference waveforms:',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                  color: CcsTheme.textSecondary,
                                ),
                              ),
                              for (final p in differencePairs)
                                InputChip(
                                  visualDensity: VisualDensity.compact,
                                  label: Text(
                                    '${widget.config.levelLabel('Condition', p[0])} − ${widget.config.levelLabel('Condition', p[1])}',
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                  selected: true,
                                  onDeleted: differencePairs.length > 1
                                      ? () => setState(
                                          () => differencePairs.remove(p),
                                        )
                                      : null,
                                ),
                            ],
                          ),
                        ],
                        if (facetLevels.length > 1) ...[
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                '${widget.config.factorLabel(facet)}s to plot:',
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                  color: CcsTheme.textSecondary,
                                ),
                              ),
                              for (final fv in facetLevels)
                                FilterChip(
                                  visualDensity: VisualDensity.compact,
                                  label: Text(
                                    widget.config.levelLabel(facet, fv),
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                  selected: selectedFacets.contains(fv),
                                  onSelected: busy
                                      ? null
                                      : (sel) => setState(() {
                                          if (sel) {
                                            selectedFacets.add(fv);
                                          } else if (selectedFacets.length > 1) {
                                            selectedFacets.remove(fv);
                                          }
                                        }),
                                ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                // Card 3: Style, Sizing & Colours (collapsible)
                Card(
                  child: ExpansionTile(
                    initiallyExpanded: false,
                    title: const Text(
                      '2. Figure size, axes, error bands & cohort colours',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      autoSize
                          ? 'Auto-sized grid · ${dpi.text} DPI · ${isTopoMode || isTfMode ? colormap : "$error band"}'
                          : '${width.text}×${height.text} in · ${dpi.text} DPI',
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: CcsTheme.textSecondary,
                      ),
                    ),
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Wrap(
                              spacing: 12,
                              runSpacing: 10,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                FilterChip(
                                  label: const Text(
                                    'Auto size (recommended)',
                                    style: TextStyle(fontSize: 11.5),
                                  ),
                                  selected: autoSize,
                                  onSelected: busy
                                      ? null
                                      : (v) => setState(() => autoSize = v),
                                ),
                                _field(
                                  width,
                                  'Width (in)',
                                  w: 110,
                                  enabled: !autoSize,
                                ),
                                _field(
                                  height,
                                  'Height (in)',
                                  w: 110,
                                  enabled: !autoSize,
                                ),
                                _field(dpi, 'DPI', w: 95),
                                _field(font, 'Font size', w: 105),
                                if (isWaveformMode) ...[
                                  _field(line, 'Line width', w: 105),
                                  _field(xmin, 'X min (ms)', w: 115),
                                  _field(xmax, 'X max (ms)', w: 115),
                                  _field(ymin, 'Y min (µV)', w: 115),
                                  _field(ymax, 'Y max (µV)', w: 115),
                                  SizedBox(
                                    width: 120,
                                    child: DropdownButtonFormField<String>(
                                      initialValue: error,
                                      decoration: const InputDecoration(
                                        labelText: 'Error band',
                                        isDense: true,
                                      ),
                                      items: [
                                        for (final v in [
                                          'None',
                                          'SEM',
                                          '95% CI',
                                        ])
                                          DropdownMenuItem(
                                            value: v,
                                            child: Text(v),
                                          ),
                                      ],
                                      onChanged: busy
                                          ? null
                                          : (v) => setState(() => error = v!),
                                    ),
                                  ),
                                  if (mode != 'ml')
                                    FilterChip(
                                      label: const Text('Negative up'),
                                      selected: negativeUp,
                                      onSelected: busy
                                          ? null
                                          : (v) =>
                                                setState(() => negativeUp = v),
                                    ),
                                ] else ...[
                                  _field(colorLimit, 'Colour ± limit', w: 135),
                                  SizedBox(
                                    width: 130,
                                    child: DropdownButtonFormField<String>(
                                      initialValue: colormap,
                                      decoration: const InputDecoration(
                                        labelText: 'Colormap',
                                        isDense: true,
                                      ),
                                      items: [
                                        for (final v in [
                                          'RdBu_r',
                                          'viridis',
                                          'magma',
                                          'cividis',
                                        ])
                                          DropdownMenuItem(
                                            value: v,
                                            child: Text(v),
                                          ),
                                      ],
                                      onChanged: busy
                                          ? null
                                          : (v) =>
                                                setState(() => colormap = v!),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            if (seriesLevels.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              const Text(
                                'Cohort / series colours (hex RRGGBB):',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                  color: CcsTheme.textSecondary,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 12,
                                runSpacing: 8,
                                children: [
                                  for (final (idx, value)
                                      in seriesLevels.indexed)
                                    SizedBox(
                                      width: 155,
                                      child: TextFormField(
                                        initialValue:
                                            ((colors[value] ??
                                                        _defaultPalette[idx %
                                                            _defaultPalette
                                                                .length]) &
                                                    0xffffff)
                                                .toRadixString(16)
                                                .padLeft(6, '0'),
                                        decoration: InputDecoration(
                                          isDense: true,
                                          labelText: widget.config.levelLabel(
                                            series,
                                            value,
                                          ),
                                          prefixIcon: Padding(
                                            padding: const EdgeInsets.all(10),
                                            child: CircleAvatar(
                                              radius: 6,
                                              backgroundColor: Color(
                                                colors[value] ??
                                                    _defaultPalette[idx %
                                                        _defaultPalette.length],
                                              ),
                                            ),
                                          ),
                                        ),
                                        onChanged: (v) {
                                          final clean = v
                                              .replaceFirst('#', '')
                                              .trim();
                                          final c = int.tryParse(
                                            clean,
                                            radix: 16,
                                          );
                                          if (c != null && clean.length == 6) {
                                            setState(
                                              () => colors[value] =
                                                  0xff000000 | c,
                                            );
                                          }
                                        },
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Note: Figures use reviewed groupings and equal participant weighting. No statistical significance is inferred from visual separation; use the Statistical Plot export in Results for significance brackets.',
                  style: TextStyle(fontSize: 11.5, color: CcsTheme.textSecondary),
                ),
              ] else
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(14),
                    child: Text(
                      'Reads saved B-minus-A waveform measurements at their saved ROI and window, including peaks and latencies. Constant Condition is removed from the next model.',
                      style: TextStyle(color: CcsTheme.text),
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: busy ? null : run,
                    icon: const Icon(Icons.auto_graph),
                    label: Text(
                      busy
                          ? 'Working…'
                          : widget.differenceOnly
                          ? 'Load difference measurements'
                          : 'Generate publication figures',
                    ),
                  ),
                  if (busy)
                    OutlinedButton.icon(
                      onPressed: stopProcess,
                      icon: const Icon(Icons.stop, size: 16),
                      label: const Text('Stop'),
                    ),
                  if (image != null)
                    OutlinedButton.icon(
                      onPressed: _openOutputFolder,
                      icon: const Icon(Icons.folder_open, size: 16),
                      label: const Text('Open output folder'),
                    ),
                ],
              ),
              if (busy) ...[
                const SizedBox(height: 8),
                const LinearProgressIndicator(),
              ],
              if (status.isNotEmpty) ...[
                const SizedBox(height: 8),
                SelectableText(
                  status,
                  style: const TextStyle(
                    fontSize: 12,
                    color: CcsTheme.text,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
              if (warnings.isNotEmpty) ...[
                const SizedBox(height: 6),
                Card(
                  child: ExpansionTile(
                    initiallyExpanded: false,
                    title: Text(
                      '${warnings.length} recording notice(s)',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFFB45309),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: SelectableText(
                          warnings.join('\n'),
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: CcsTheme.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (image != null) ...[
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: SizedBox(
                      height: 620,
                      child: InteractiveViewer(
                        minScale: 0.2,
                        maxScale: 5,
                        child: Image.file(File(image!), fit: BoxFit.contain),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
