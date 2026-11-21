import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import '../extraction_service.dart';
import '../group_statistics_plots.dart';

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
  });
  final Map<String, dynamic> inspection;
  final String csvPath;
  final StatsPlotLayoutConfig config;
  final Map<String, List<String>> levelOrder;
  final Map<String, Set<String>> excludedLevels;
  final Future<String?> Function() findPython;
  final bool differenceOnly;
  @override
  State<ErpGroupFigureStudio> createState() => _ErpGroupFigureStudioState();
}

class _ErpGroupFigureStudioState extends State<ErpGroupFigureStudio> {
  final folder = TextEditingController(),
      output = TextEditingController(),
      channels = TextEditingController(text: 'Cz');
  final width = TextEditingController(text: '12'),
      height = TextEditingController(text: '5'),
      dpi = TextEditingController(text: '300'),
      font = TextEditingController(text: '10'),
      line = TextEditingController(text: '1.5');
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
  bool busy = false, negativeUp = true;
  bool cancelled = false;
  String? image;
  Process? process;
  late final Map<String, int> colors;
  Map<String, dynamic> get levels => Map<String, dynamic>.from(
    widget.inspection['factor_levels'] as Map? ?? {},
  );
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
    final conditions = (levels['Condition'] as List? ?? [])
        .map((x) => '$x')
        .toList();
    conditionA = conditions.contains('Freq') ? 'Freq' : conditions.firstOrNull;
    conditionB = conditions.contains('Rare')
        ? 'Rare'
        : conditions.length > 1
        ? conditions[1]
        : conditions.firstOrNull;
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

  Widget field(TextEditingController c, String label, {double w = 120}) =>
      SizedBox(
        width: w,
        child: TextField(
          controller: c,
          decoration: InputDecoration(labelText: label, isDense: true),
        ),
      );
  Widget factor(String label, String? value, ValueChanged<String?> change) =>
      SizedBox(
        width: 210,
        child: DropdownButtonFormField<String>(
          isExpanded: true,
          initialValue: value ?? '',
          decoration: InputDecoration(labelText: label),
          items: [
            const DropdownMenuItem(value: '', child: Text('None')),
            for (final f in levels.keys.where(
              (f) => f != 'participant_id' && f != 'subjid',
            ))
              DropdownMenuItem(
                value: f,
                child: Text(widget.config.factorLabel(f)),
              ),
          ],
          onChanged: busy
              ? null
              : (v) => setState(() => change(v == '' ? null : v)),
        ),
      );
  Future<void> run() async {
    if (busy) return;
    cancelled = false;
    setState(() {
      busy = true;
      status =
          'Preparing grouped ${widget.differenceOnly ? 'difference measurements' : 'publication figures'}…';
    });
    Directory? runtime;
    try {
      final python = await widget.findPython();
      if (python == null)
        throw StateError(
          'Python with numpy, pandas, scipy, statsmodels and matplotlib is required.',
        );
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
          for (final e in widget.excludedLevels.entries)
            e.key: e.value.toList(),
        },
        'channels': channels.text,
        'window_start': double.tryParse(start.text) ?? 300,
        'window_end': double.tryParse(end.text) ?? 600,
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
        'width': double.tryParse(width.text) ?? 12,
        'height': double.tryParse(height.text) ?? 5,
        'dpi': int.tryParse(dpi.text) ?? 300,
        'font_size': double.tryParse(font.text) ?? 10,
        'line_width': double.tryParse(line.text) ?? 1.5,
        'x_min': double.tryParse(xmin.text),
        'x_max': double.tryParse(xmax.text),
        'y_min': double.tryParse(ymin.text),
        'y_max': double.tryParse(ymax.text),
        'color_limit': double.tryParse(colorLimit.text),
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
      if (exit != 0)
        throw StateError(
          message.length > 4000
              ? message.substring(message.length - 4000)
              : message,
        );
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
        status =
            'Saved PNG, SVG, PDF, data and parameter manifest to ${output.text}. ${(data['warnings'] as List? ?? []).take(8).join('\n')}';
      });
    } catch (e) {
      if (mounted) setState(() => status = '$e');
    } finally {
      process = null;
      if (runtime != null) await runtime.delete(recursive: true);
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        widget.differenceOnly
            ? 'ERP difference → group models'
            : 'Grouped ERP publication studio',
      ),
    ),
    body: Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Uses the reviewed participant IDs, factors, exclusions and level order. Every participant has equal weight within a cell. Group ITC is the average of participant ITC, not pooled phase coherence.',
                ),
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
                    TextButton(
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
                    TextButton(
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
                if (!widget.differenceOnly) ...[
                  Wrap(
                    spacing: 14,
                    runSpacing: 12,
                    children: [
                      SizedBox(
                        width: 220,
                        child: DropdownButtonFormField<String>(
                          isExpanded: true,
                          initialValue: mode,
                          decoration: const InputDecoration(
                            labelText: 'Figure',
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
                      factor('Lines / cohorts', series, (v) => series = v),
                      factor('Column facets', facet, (v) => facet = v),
                      factor('Row facets', row, (v) => row = v),
                      field(channels, 'ROI channels (comma separated)', w: 250),
                      field(start, 'Topo start (ms)'),
                      field(end, 'Topo end (ms)'),
                      if (mode == 'rerp')
                        field(predictor, 'Saved predictor', w: 200),
                      if (mode == 'ersp' || mode == 'itc') ...[
                        field(fmin, 'Minimum Hz'),
                        field(fmax, 'Maximum Hz'),
                        field(nfreq, 'Frequencies'),
                        field(baseline0, 'Baseline start ms'),
                        field(baseline1, 'Baseline end ms'),
                      ],
                      if (mode == 'ersp' || mode == 'itc')
                        for (final isA in [true, false])
                          SizedBox(
                            width: 180,
                            child: DropdownButtonFormField<String>(
                              isExpanded: true,
                              initialValue: isA ? conditionA : conditionB,
                              decoration: InputDecoration(
                                labelText: isA ? 'Condition A' : 'Condition B',
                              ),
                              items: [
                                for (final v
                                    in levels['Condition'] as List? ?? [])
                                  DropdownMenuItem(
                                    value: '$v',
                                    child: Text('$v'),
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
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 14,
                    runSpacing: 10,
                    children: [
                      field(width, 'Width (in)'),
                      field(height, 'Height (in)'),
                      field(dpi, 'DPI'),
                      field(font, 'Font size'),
                      field(line, 'Line width'),
                      field(xmin, 'X minimum (ms)'),
                      field(xmax, 'X maximum (ms)'),
                      field(ymin, 'Y minimum'),
                      field(ymax, 'Y maximum'),
                      field(colorLimit, 'Colour ± limit'),
                      DropdownButton<String>(
                        value: error,
                        items: [
                          for (final v in ['None', 'SEM', '95% CI'])
                            DropdownMenuItem(value: v, child: Text(v)),
                        ],
                        onChanged: busy
                            ? null
                            : (v) => setState(() => error = v!),
                      ),
                      DropdownButton<String>(
                        value: colormap,
                        items: [
                          for (final v in [
                            'RdBu_r',
                            'viridis',
                            'magma',
                            'cividis',
                          ])
                            DropdownMenuItem(value: v, child: Text(v)),
                        ],
                        onChanged: busy
                            ? null
                            : (v) => setState(() => colormap = v!),
                      ),
                      FilterChip(
                        label: const Text('Negative up'),
                        selected: negativeUp,
                        onSelected: busy
                            ? null
                            : (v) => setState(() => negativeUp = v),
                      ),
                    ],
                  ),
                  if (series != null)
                    Wrap(
                      spacing: 12,
                      children: [
                        for (final value in (levels[series] as List? ?? []).map(
                          (v) => '$v',
                        ))
                          SizedBox(
                            width: 130,
                            child: TextFormField(
                              initialValue: colors[value] == null
                                  ? ''
                                  : (colors[value]! & 0xffffff)
                                        .toRadixString(16)
                                        .padLeft(6, '0'),
                              decoration: InputDecoration(
                                labelText: '$value RRGGBB',
                              ),
                              onChanged: (v) {
                                final c = int.tryParse(
                                  v.replaceFirst('#', ''),
                                  radix: 16,
                                );
                                if (c != null &&
                                    v.replaceFirst('#', '').length == 6)
                                  colors[value] = 0xff000000 | c;
                              },
                            ),
                          ),
                      ],
                    ),
                  const Text(
                    'Order and display labels follow the group-analysis design. rERP / ML require saved model results; they cannot be reconstructed from ERP averages. ERSP / ITC require readable source epochs and are recomputed for these groupings. Figures carry no inferred significance from visual separation.',
                  ),
                ] else
                  const Text(
                    'Reads saved B-minus-A waveform measurements at their saved ROI and window, including peaks and latencies. This does not subtract condition peak/latency scalars. Constant Condition is removed from the next model.',
                  ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
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
                      TextButton(
                        onPressed: stopProcess,
                        child: const Text('Stop'),
                      ),
                  ],
                ),
                if (busy) const LinearProgressIndicator(),
                SelectableText(status),
                if (image != null)
                  SizedBox(
                    height: 650,
                    child: InteractiveViewer(
                      minScale: .2,
                      maxScale: 5,
                      child: Image.file(File(image!), fit: BoxFit.contain),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}
