import 'reference_channel_picker.dart';
import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'models.dart';
import 'recording_storage.dart';
import 'legacy_file_migration.dart';

Future<bool> showProcessingSettings(
  BuildContext context,
  AnalysisConfig config,
  String stage, {
  String? section,
  List<String> availableChannels = const [],
}) async {
  final spectralSettings = ['Coherence (COH)', 'PLV', 'ciPLV', 'PLI', 'wPLI'].contains(section);
  var spectralGraph = config.spectralGraph;
  final roiSettings = ['MIC', 'MIM', 'Granger Causality', 'GC-TR', 'GC − GC-TR contrast'].contains(section);
  var seed = List<String>.from(config.roiSeed);
  var target = List<String>.from(config.roiTarget);
  final taps = TextEditingController(text: '${config.firTaps}'),
      width = TextEditingController(text: '${config.notchWidthHz}'),
      transition = TextEditingController(text: '${config.notchTransitionHz}'),
      references = TextEditingController(
        text: config.referenceChannels.join(', '),
      ),
      snr = TextEditingController(text: '${config.sourceSnr}'),
      regions = TextEditingController(text: config.sourceRegions.join(', ')),
      window = TextEditingController(text: '${config.psdWindowSeconds}'),
      bands = TextEditingController(
        text: config.psdBands
            .map((b) => '${b['label']}: ${b['low']}-${b['high']}')
            .join('\n'),
      );
  final featureRefs = TextEditingController(
    text: config.featureReferenceChannels.join(', '),
  );
  final gedaiThreshold = TextEditingController(text: config.gedaiThreshold);
  final sourceModel = TextEditingController(text: config.sourceModelPath);
  var outputFormat = RecordingStorage.preferredFormat;
  var sourceMethod = config.sourceMethod;
  var featureReference = config.featureReferenceMode;
  final order = TextEditingController(text: '${config.iirOrder}');
  var filterType = config.filterType,
      reference = config.referenceMode,
      average = config.psdAverage,
      psdMethod = config.psdMethod,
      psdMultitaperAdaptive = config.psdMultitaperAdaptive;
  final psdMultitaperNw = TextEditingController(
    text: '${config.psdMultitaperNw}',
  );
  final definitions = <String, (String, String, double, double, bool)>{
    'fooof_max_peaks': ('FOOOF maximum peaks', '20', 0, 20, true),
    'fooof_peak_threshold': ('FOOOF peak threshold (SD)', '2', 0.01, 10, false),
    'sample_entropy_tolerance': (
      'Sample entropy tolerance (× SD)',
      '0.2',
      0.001,
      0.999,
      false,
    ),
    'higuchi_kmax': ('Higuchi kmax', '10', 2, 100, true),
    'acw_fraction': ('ACW correlation crossing', '0.5', 0.01, 0.99, false),
    'gc_lags': ('GC autoregressive lags', '25', 1, 27, true),
  };
  final advanced = {
    for (final entry in definitions.entries)
      entry.key: TextEditingController(
        text: '${config.featureParameters[entry.key] ?? entry.value.$2}',
      ),
  };
  final factors = TextEditingController(
    text: (config.featureParameters['irasa_factors'] as List? ?? []).join(', '),
  );
  final sourceNames = stage == 'Source Space'
      ? (jsonDecode(await rootBundle.loadString('assets/source_regions.json'))
                as List)
            .cast<String>()
      : <String>[];
  if (!context.mounted) return false;
  final variance = TextEditingController(text: '${config.badVarianceRatio}'),
      stiffness = TextEditingController(text: '${config.splineStiffness}'),
      regularization = TextEditingController(
        text: '${config.splineRegularization}',
      );
  final icaEye = TextEditingController(text: config.icaEyeChannel),
      icaEpochs = TextEditingController(text: '${config.icaBlinkEpochs}'),
      icaBlinkHi = TextEditingController(text: '${config.icaBlinkThreshold}'),
      icaBlinkLo = TextEditingController(
        text: '${config.icaBlinkThresholdFloor}',
      ),
      icaArtefacts = TextEditingController(
        text: config.icaArtefacts.join(', '),
      ),
      icaOtherHi = TextEditingController(text: '${config.icaOtherThreshold}'),
      icaOtherLo = TextEditingController(
        text: '${config.icaOtherThresholdFloor}',
      ),
      icaSeed = TextEditingController(text: '${config.icaSeed}'),
      icaFitCutoff = TextEditingController(text: '${config.icaFitAsrCutoff}'),
      asrCutoff = TextEditingController(text: '${config.asrCutoff}'),
      asrAlpha = TextEditingController(text: '${config.asrAdaptAlpha}'),
      asrEmbedDim = TextEditingController(text: '${config.asrEmbedDim}'),
      asrEmbedTau = TextEditingController(text: '${config.asrEmbedTau}'),
      asrModes = TextEditingController(text: '${config.asrModes}'),
      bsscaN = TextEditingController(text: '${config.bsscaNRemove}'),
      iccThr = TextEditingController(text: '${config.iccThreshold}'),
      wicaLevels = TextEditingController(text: '${config.wicaLevels}');
  var icaBlink = config.icaBlink,
      icaOther = config.icaOther,
      icaRemoveEcg = config.icaRemoveEcg,
      icaFitAsr = config.icaFitAsr;
  String? error;
  Widget field(
    TextEditingController c,
    String label, {
    String? help,
    int lines = 1,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(
      controller: c,
      maxLines: lines,
      decoration: InputDecoration(
        labelText: label,
        helperText: help,
        helperMaxLines: 4,
      ),
    ),
  );
  final changed = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(
          stage == 'Feature Extraction' && section != null
              ? '${const {'Bands': 'Frequency band', 'GC': 'Granger causality', 'PSD': 'PSD', 'FOOOF': 'FOOOF / specparam', 'IRASA': 'IRASA', 'Nonlinear': 'Nonlinear dynamics', 'ACW': 'Autocorrelation window'}[section] ?? section} parameters'
              : '$stage parameters',
        ),
        content: SizedBox(
          width: 500,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (stage != 'Feature Extraction') ...[
                DropdownButtonFormField<RecordingFileFormat>(
                  isExpanded: true,
                  initialValue: outputFormat,
                  decoration: const InputDecoration(
                    labelText: 'Saved recording format (all workflows)',
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: RecordingFileFormat.ccseeg,
                      child: Text('CCSEEG · native portable'),
                    ),
                    DropdownMenuItem(
                      value: RecordingFileFormat.fif,
                      child: Text('FIF · floating-point EEG / epochs'),
                    ),
                    DropdownMenuItem(
                      value: RecordingFileFormat.edf,
                      child: Text('EDF+ · 16-bit + .ccsmeta metadata'),
                    ),
                  ],
                  onChanged: (v) => setState(() => outputFormat = v!),
                ),
                const Text(
                  'EDF/FIF exports include a matching .ccsmeta file (JSON contents). Keep it with the signal file for exact epoch timing, labels and processing history. EDF quantizes amplitudes to 16-bit.',
                ),
                TextButton.icon(
                  icon: const Icon(Icons.drive_file_rename_outline),
                  label: const Text('Organise legacy output filenames…'),
                  onPressed: () async {
                    final folder = await FilePicker.getDirectoryPath();
                    if (folder == null || !context.mounted) return;
                    try {
                      final plan = await LegacyFileMigration.plan(folder);
                      if (!context.mounted) return;
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: Text('${plan.length} legacy filenames'),
                          content: SizedBox(
                            width: 600,
                            child: SingleChildScrollView(
                              child: Text(
                                plan.isEmpty
                                    ? 'No known legacy filenames need changing.'
                                    : plan.entries
                                          .map(
                                            (e) =>
                                                '${e.key.split(RegExp(r"[/\\]")).last} → ${e.value.split(RegExp(r"[/\\]")).last}',
                                          )
                                          .join('\n'),
                              ),
                            ),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('Cancel'),
                            ),
                            if (plan.isNotEmpty)
                              FilledButton(
                                onPressed: () => Navigator.pop(ctx, true),
                                child: const Text('Rename outputs'),
                              ),
                          ],
                        ),
                      );
                      if (confirmed == true)
                        await LegacyFileMigration.apply(folder, plan);
                    } catch (e) {
                      if (context.mounted)
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(SnackBar(content: Text('$e')));
                    }
                  },
                ),
                ],
                if (stage == 'Preprocessing') ...[
                  ExpansionTile(
                    title: const Text('Filter and notch'),
                    initiallyExpanded: section == 'Filter',
                    children: [
                      DropdownButtonFormField<String>(
                        isExpanded: true,
                        initialValue: filterType,
                        decoration: const InputDecoration(
                          labelText: 'Bandpass filter type',
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'fir',
                            child: Text('FIR Hamming (centred)'),
                          ),
                          DropdownMenuItem(
                            value: 'iir',
                            child: Text('Butterworth IIR (forward / backward)'),
                          ),
                        ],
                        onChanged: (v) => setState(() => filterType = v!),
                      ),
                      if (filterType == 'iir')
                        field(
                          order,
                          'IIR order per pass (2-12, even)',
                          help:
                              'Forward/backward filtering squares the magnitude response.',
                        ),
                      if (filterType == 'fir')
                        const Text(
                          'FIR Hamming, centred zero-phase filtering. Order = taps − 1.',
                        ),
                      field(
                        taps,
                        'FIR taps (0 = automatic)',
                        help: 'Custom taps must be odd and at least 3.',
                      ),
                      field(width, 'Notch stop-band width (Hz)'),
                      field(transition, 'Notch transition width (Hz)'),
                    ],
                  ),
                  ExpansionTile(
                    title: const Text('Bad channels and interpolation'),
                    initiallyExpanded: section == 'Bad channels',
                    children: [
                      field(
                        variance,
                        'Bad-channel variance / median ratio',
                        help: 'Flat channels are also flagged. Default 25.',
                      ),
                      field(stiffness, 'Spherical spline stiffness (2-8)'),
                      field(
                        regularization,
                        'Spline regularization',
                        help: 'Positive; default 0.00001.',
                      ),
                    ],
                  ),
                  ExpansionTile(
                    title: const Text('GEDAI · optional additional cleaning'),
                    initiallyExpanded: section == 'GEDAI',
                    children: [
                      DropdownButtonFormField<String>(
                        isExpanded: true,
                        initialValue: const [
                          'auto-',
                          'auto',
                          'auto+',
                          '0.5',
                          '1.0',
                          '2.0',
                          '3.0',
                          '5.0',
                          '8.0',
                        ].contains(gedaiThreshold.text.trim())
                            ? gedaiThreshold.text.trim()
                            : 'custom',
                        decoration: const InputDecoration(
                          labelText: 'GEDAI threshold preset',
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'auto-',
                            child: Text('Gentle (auto- · ~99th pct, conservative)'),
                          ),
                          DropdownMenuItem(
                            value: 'auto',
                            child: Text('Standard (auto · ~95th pct, balanced)'),
                          ),
                          DropdownMenuItem(
                            value: 'auto+',
                            child: Text('Strong (auto+ · ~90th pct, aggressive)'),
                          ),
                          DropdownMenuItem(value: '0.5', child: Text('Numeric: 0.5 SD')),
                          DropdownMenuItem(value: '1.0', child: Text('Numeric: 1.0 SD')),
                          DropdownMenuItem(value: '2.0', child: Text('Numeric: 2.0 SD')),
                          DropdownMenuItem(value: '3.0', child: Text('Numeric: 3.0 SD')),
                          DropdownMenuItem(value: '5.0', child: Text('Numeric: 5.0 SD')),
                          DropdownMenuItem(value: '8.0', child: Text('Numeric: 8.0 SD')),
                          DropdownMenuItem(value: 'custom', child: Text('Custom numeric (0–12)…')),
                        ],
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() {
                            gedaiThreshold.text = v == 'custom' ? '1.5' : v;
                          });
                        },
                      ),
                      const SizedBox(height: 8),
                      field(
                        gedaiThreshold,
                        'GEDAI threshold value (0–12 or auto-/auto/auto+)',
                        help:
                            'Choose a preset above or enter a numeric threshold (0–12 SD; lower = stronger cleaning).',
                      ),
                      const Text(
                        'Disabled in new configurations. Existing saved choices are retained. Compare with GEDAI off before accepting strong power reductions: the alpha-power warning measures signal change, not artifact-removal accuracy. Saved event trials retain their own boundaries.',
                      ),
                    ],
                  ),
                  ExpansionTile(
                    title: const Text('Output reference'),
                    initiallyExpanded: section == 'Reference',
                    children: [
                      DropdownButtonFormField<String>(
                        isExpanded: true,
                        initialValue: reference,
                        decoration: const InputDecoration(
                          labelText: 'Output reference',
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'none',
                            child: Text('Keep cleaned reference'),
                          ),
                          DropdownMenuItem(
                            value: 'average',
                            child: Text('Common average'),
                          ),
                          DropdownMenuItem(
                            value: 'channels',
                            child: Text(
                              'Selected electrode(s) / linked references',
                            ),
                          ),
                        ],
                        onChanged: (v) => setState(() => reference = v!),
                      ),
                      if (reference == 'channels' &&
                          availableChannels.isNotEmpty)
                        ReferenceChannelPicker(
                          channels: availableChannels,
                          selected: references.text
                              .split(',')
                              .map((s) => s.trim())
                              .where((s) => s.isNotEmpty)
                              .toList(),
                          onChanged: (v) =>
                              setState(() => references.text = v.join(', ')),
                        ),
                      if (reference == 'channels' && availableChannels.isEmpty)
                        field(
                          references,
                          'Reference channel labels',
                          help:
                              'Comma-separated. These channels must be included among EEG channels.',
                        ),
                      const Text(
                        'GEDAI still uses its internal full-rank pseudo-average reference. The chosen output reference is applied after cleaning.',
                      ),
                    ],
                  ),
                  ExpansionTile(
                    title: const Text('ICA and ICLabel'),
                    initiallyExpanded: section == 'ICA',
                    children: [
                      const Divider(height: 24),
                      const Text(
                        'ICA cleaning (choose the algorithm in the Preprocessing panel)',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const Padding(
                        padding: EdgeInsets.only(top: 4, bottom: 6),
                        child: Text(
                          'Decomposition copy high-pass filter: 1.0 Hz FIR (reuses main filter if ≥ 1.0 Hz). '
                          'Stage 2 safety caps: stops if >10% of components or >30% of signal variance would be removed.',
                          style: TextStyle(fontSize: 11, color: Colors.white70),
                        ),
                      ),
                      CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                          'Blink-locked ICA stage (eye / heart)',
                        ),
                        value: icaBlink,
                        onChanged: (v) => setState(() => icaBlink = v!),
                      ),
                      if (icaBlink) ...[
                        field(
                          icaEye,
                          'Blink detection channel',
                          help:
                              'Empty = Fp1, Fp2, AFz, Fz, F7, F8, AF3 or AF4, whichever exists.',
                        ),
                        field(icaEpochs, 'Blink epochs for the decomposition'),
                        field(
                          icaBlinkHi,
                          'Eye component threshold (start)',
                          help:
                              'ICLabel probability; lowered stepwise to the floor below.',
                        ),
                        field(icaBlinkLo, 'Eye component threshold (floor)'),
                        CheckboxListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: const Text(
                            'Also remove heart (ECG) components',
                          ),
                          value: icaRemoveEcg,
                          onChanged: (v) => setState(() => icaRemoveEcg = v!),
                        ),
                      ],
                      CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                          'Second ICA stage (muscle / line noise / channel noise)',
                        ),
                        value: icaOther,
                        onChanged: (v) => setState(() => icaOther = v!),
                      ),
                      if (icaOther) ...[
                        field(
                          icaArtefacts,
                          'ICLabel classes to remove',
                          help:
                              'Comma-separated; empty = Muscle, Line Noise, Channel Noise.',
                        ),
                        field(icaOtherHi, 'Component threshold (start)'),
                        field(icaOtherLo, 'Component threshold (floor)'),
                        field(
                          icaFitCutoff,
                          'Bad segment removal cutoff for the ICA fit copy (SD)',
                          help:
                              'ASR-based burst and bad-segment rejection (MATLAB ica2_BurstCriterion, default 15 SD) applied to the 1 Hz ICA fit copy only.',
                        ),
                        CheckboxListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Fit ICA after bad segment removal (ASR)'),
                          subtitle: const Text(
                            'As the MATLAB pipeline: bursts/bad segments are rejected from the 1 Hz copy ICA is fitted on only.',
                          ),
                          value: icaFitAsr,
                          onChanged: (v) => setState(() => icaFitAsr = v!),
                        ),
                      ],
                      field(
                        icaSeed,
                        'ICA random seed',
                        help:
                            'Fixed seed makes the decomposition reproducible.',
                      ),
                    ],
                  ),
                  ExpansionTile(
                    title: const Text('ASR and muscle correction'),
                    initiallyExpanded: section == 'ASR',
                    children: [
                      const Divider(height: 24),
                      field(
                        asrCutoff,
                        'ASR burst cutoff (SD)',
                        help:
                            'clean_rawdata BurstCriterion: 5 aggressive, 20 conservative (default).',
                      ),
                      if (config.asrVariant == 'adaptive')
                        field(
                          asrAlpha,
                          'Adaptive ASR update rate (0-1)',
                          help:
                              'Weight of each clean block in the running calibration; 0 = static ASR.',
                        ),
                      if (config.asrVariant == 'easr') ...[
                        field(
                          asrEmbedDim,
                          'E-ASR embedding dimension',
                          help: 'Pseudo-channels per channel (2-32).',
                        ),
                        field(
                          asrEmbedTau,
                          'E-ASR delay (samples)',
                          help: '1-50.',
                        ),
                      ],
                      if (config.asrVariant == 'vmd' ||
                          config.asrVariant == 'emd')
                        field(
                          asrModes,
                          'Number of modes',
                          help:
                              'VMD modes / EMD components used as ASR channels (2-12).',
                        ),
                      if (config.muscleMethod == 'bss_cca')
                        field(
                          bsscaN,
                          'BSS-CCA sources removed',
                          help:
                              'Lowest-autocorrelation sources dropped (1+; typical 1-10% of channels).',
                        ),
                      if (config.muscleMethod == 'icanclean')
                        field(
                          iccThr,
                          'iCanClean R² threshold',
                          help:
                              'Canonical components with R² above this are removed (default 0.7).',
                        ),
                      if (config.muscleMethod == 'wica')
                        field(
                          wicaLevels,
                          'wICA wavelet levels',
                          help:
                              'HAPPE wICA: coif5 SWT levels, soft threshold (default 5).',
                        ),
                    ],
                  ),
                ],
                if (stage == 'Source Space') ...[
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: sourceMethod,
                    decoration: const InputDecoration(
                      labelText: 'Inverse method',
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'mne',
                        child: Text('Minimum norm (MNE)'),
                      ),
                      DropdownMenuItem(
                        value: 'dspm',
                        child: Text('dSPM (noise-normalized)'),
                      ),
                      DropdownMenuItem(
                        value: 'sloreta',
                        child: Text('sLORETA (resolution-normalized)'),
                      ),
                      DropdownMenuItem(
                        value: 'eloreta',
                        child: Text('eLORETA (exact zero-localization-error)'),
                      ),
                      DropdownMenuItem(
                        value: 'lcmv',
                        child: Text(
                          'LCMV (unit gain; 5% covariance regularization)',
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'xpikan',
                        child: Text('XPIKAN (3-shell Physics-Informed NN)'),
                      ),
                    ],
                    onChanged: (v) => setState(() => sourceMethod = v!),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.folder_open),
                    label: const Text('Choose forward + atlas model…'),
                    onPressed: () async {
                      final picked = await FilePicker.pickFiles(
                        type: FileType.custom,
                        allowedExtensions: ['json', 'gz'],
                      );
                      if (picked != null &&
                          picked.files.single.path != null &&
                          context.mounted) {
                        setState(() {
                          sourceModel.text = picked.files.single.path!;
                          regions.clear();
                        });
                      }
                    },
                  ),
                  field(
                    sourceModel,
                    'Custom forward + atlas JSON path (empty = bundled fsaverage)',
                    help:
                        'Fixed-orientation channels × sources leadfield and ROI source indices; HCPex requires a matching source grid. Identity noise covariance.',
                  ),

                  field(
                    snr,
                    'Inverse regularization SNR',
                    help: 'Positive value; default 3 (λ² = 1/SNR²).',
                  ),
                  Builder(
                    builder: (_) {
                      final snrVal = double.tryParse(snr.text.trim()) ?? 3.0;
                      final lambda2 = snrVal > 0 ? (1.0 / (snrVal * snrVal)) : 0.111;
                      final customModel = sourceModel.text.trim();
                      final fwdLabel = sourceMethod == 'xpikan'
                          ? 'XPIKAN 3-shell PINN (concentric spherical)'
                          : customModel.isEmpty
                              ? 'MNE fsaverage 3-shell BEM'
                              : 'Custom JSON (${customModel.split(RegExp(r"[\\/]")).last})';
                      final atlasLabel = customModel.isEmpty
                          ? 'Desikan-Killiany 68 cortical ROIs (DK68)'
                          : 'Custom atlas from JSON';
                      final covLabel = sourceMethod == 'lcmv'
                          ? 'Data covariance (5% trace regularization)'
                          : 'Identity noise covariance';
                      return Container(
                        width: double.infinity,
                        margin: const EdgeInsets.only(top: 8, bottom: 8),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0F172A),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.white12),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Publication Model Specification',
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: Colors.cyanAccent,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Forward model: $fwdLabel\n'
                              'Conductivities: Brain 0.33 S/m · Skull 0.0042 S/m · Scalp 0.33 S/m (radii 0.87 / 0.92 / 1.00)\n'
                              'Atlas map: $atlasLabel\n'
                              'Inverse: ${sourceMethod.toUpperCase()} · fixed surface-normal orientations · SNR $snrVal (λ² = ${lambda2.toStringAsFixed(4)}) · $covLabel',
                              style: const TextStyle(fontSize: 10.5, color: Colors.white70, height: 1.35),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                  if (sourceModel.text.trim().isEmpty)
                    ExpansionTile(
                      title: const Text('Choose bundled source regions'),
                      children: [
                        for (final name in sourceNames)
                          CheckboxListTile(
                            dense: true,
                            title: Text(name),
                            value:
                                regions.text.trim().isEmpty ||
                                regions.text
                                    .split(',')
                                    .map((s) => s.trim())
                                    .contains(name),
                            onChanged: (v) => setState(() {
                              final selected = regions.text.trim().isEmpty
                                  ? sourceNames.toSet()
                                  : regions.text
                                        .split(',')
                                        .map((s) => s.trim())
                                        .where((s) => s.isNotEmpty)
                                        .toSet();
                              if (v == true) {
                                selected.add(name);
                              } else {
                                if (selected.length == 1) return;
                                selected.remove(name);
                              }
                              regions.text = selected.join(', ');
                            }),
                          ),
                      ],
                    ),
                  field(
                    regions,
                    'Source region labels (empty = all model regions)',
                    lines: 3,
                    help:
                        'Comma-separated labels from the selected atlas; unknown names are rejected.',
                  ),
                ],
                if (stage == 'Feature Extraction') ...[
                  if (spectralSettings) ...[
                    Text('$section · undirected channel connectivity'),
                    const Text('Computed separately in each frequency band. The bands below are shared by spectral connectivity features.'),
                    SwitchListTile(title: const Text('Save channel × channel matrices'), subtitle: const Text('Required for graph theory; otherwise save per-channel means.'), value: spectralGraph, onChanged: (v) => setState(() => spectralGraph = v)),
                  ],
                  if (roiSettings) ...[
                    Text('$section · ${section == 'MIC' || section == 'MIM' ? 'undirected' : 'directed seed → target'}'),
                    const Text('Choose the two channel regions to compare. These settings are shared by MIC, MIM and Granger measures.'),
                    if (availableChannels.isEmpty) const Text('Open a recording to choose ROI channels. The default remains Frontal → Parieto-occipital.'),
                    for (final isSeed in [true, false]) ...[
                      Text(isSeed ? 'Seed region' : 'Target region', style: const TextStyle(fontWeight: FontWeight.bold)),
                      TextButton(onPressed: availableChannels.isEmpty ? null : () => setState(() {
                        final selected = availableChannels.where((c) => isSeed ? c.toUpperCase().startsWith('F') : (c.toUpperCase().startsWith('P') || c.toUpperCase().startsWith('O'))).toList();
                        if (isSeed) { seed = selected; } else { target = selected; }
                      }), child: Text(isSeed ? 'Use frontal channels' : 'Use parietal / occipital channels')),
                      Wrap(spacing: 4, children: [for (final ch in availableChannels)
                        FilterChip(label: Text(ch), selected: (isSeed ? seed : target).contains(ch), onSelected: (selected) => setState(() {
                          final list = isSeed ? seed : target;
                          if (selected) { list.add(ch); } else { list.remove(ch); }
                        })),
                      ]),
                    ],
                  ],
                  if (section == null || section == 'Reference') DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: featureReference,
                    decoration: const InputDecoration(
                      labelText: 'Feature-analysis reference',
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'none',
                        child: Text('Keep input reference'),
                      ),
                      DropdownMenuItem(
                        value: 'average',
                        child: Text('Common average'),
                      ),
                      DropdownMenuItem(
                        value: 'channels',
                        child: Text('Selected electrode(s)'),
                      ),
                    ],
                    onChanged: (v) => setState(() => featureReference = v!),
                  ),
                  if ((section == null || section == 'Reference') && featureReference == 'channels')
                    field(featureRefs, 'Feature reference channels'),
                  if (section == null || section == 'PSD') DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: psdMethod,
                    decoration: const InputDecoration(
                      labelText: 'PSD estimation method',
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'welch',
                        child: Text("Welch's modified periodogram"),
                      ),
                      DropdownMenuItem(
                        value: 'multitaper',
                        child: Text(
                          "Adaptive Multitaper (Thomson / Slepian DPSS)",
                        ),
                      ),
                    ],
                    onChanged: (v) => setState(() => psdMethod = v!),
                  ),
                  if (section == null || section == 'PSD')
                  if (psdMethod == 'welch') ...[
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      initialValue: average,
                      decoration: const InputDecoration(
                        labelText: 'Welch segment averaging',
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'median',
                          child: Text(
                            'Median average (robust against transients)',
                          ),
                        ),
                        DropdownMenuItem(
                          value: 'mean',
                          child: Text('Mean average'),
                        ),
                      ],
                      onChanged: (v) => setState(() => average = v!),
                    ),
                    field(
                      window,
                      'PSD window (s)',
                      help: '50% overlap; cannot exceed the analysis epoch.',
                    ),
                  ] else ...[
                    field(
                      psdMultitaperNw,
                      'Multitaper time-bandwidth product (NW)',
                      help:
                          'Standard NW=3.0 (K=5 tapers). Half-bandwidth W = NW / epoch duration.',
                    ),
                    CheckboxListTile(
                      title: const Text('Adaptive spectral weighting'),
                      subtitle: const Text(
                        'Iterative Thomson weighting to minimize broadband spectral leakage',
                      ),
                      value: psdMultitaperAdaptive,
                      onChanged: (v) =>
                          setState(() => psdMultitaperAdaptive = v ?? true),
                      controlAffinity: ListTileControlAffinity.leading,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ],
                  for (final entry in definitions.entries)
                    if (section == null || (entry.key == 'gc_lags' && roiSettings && section != 'MIC' && section != 'MIM') ||
                        section ==
                            (entry.key.startsWith('fooof_')
                                ? 'FOOOF'
                                : entry.key == 'gc_lags'
                                ? 'GC'
                                : entry.key == 'acw_fraction'
                                ? 'ACW'
                                : 'Nonlinear'))
                      field(advanced[entry.key]!, entry.value.$1),
                  if (section == null || section == 'IRASA')
                  field(
                    factors,
                    'IRASA resampling factors',
                    help:
                        'Empty = standard 17 factors. Custom list between 1 and 2; rounded to two decimals.',
                  ),
                  if (section == null || section == 'PSD' || section == 'Bands' || roiSettings || spectralSettings)
                    _FrequencyBandEditor(controller: bands),
                ],
                if (error != null)
                  Text(error!, style: const TextStyle(color: Colors.redAccent)),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              try {
                if (stage == 'Preprocessing') {
                  final n = int.parse(taps.text),
                      w = double.parse(width.text),
                      t = double.parse(transition.text);
                  if (n < 0 ||
                      (n != 0 && (n < 3 || n.isEven)) ||
                      !w.isFinite ||
                      w <= 0 ||
                      !t.isFinite ||
                      t <= 0)
                    throw const FormatException(
                      'Invalid FIR taps or notch widths.',
                    );
                  final refs = references.text
                      .split(',')
                      .map((v) => v.trim())
                      .where((v) => v.isNotEmpty)
                      .toList();
                  if (reference == 'channels' && refs.isEmpty)
                    throw const FormatException('Choose reference channels.');
                  final vr = double.parse(variance.text),
                      sr = double.parse(regularization.text);
                  final ss = int.parse(stiffness.text);
                  if (!vr.isFinite ||
                      vr < 2 ||
                      !sr.isFinite ||
                      sr <= 0 ||
                      ss < 2 ||
                      ss > 8)
                    throw const FormatException(
                      'Invalid bad-channel or spline parameters.',
                    );
                  final o = int.parse(order.text);
                  if (o < 2 || o > 12 || o.isOdd)
                    throw const FormatException(
                      'IIR order must be even, 2-12.',
                    );
                  final eh = double.parse(icaBlinkHi.text),
                      el = double.parse(icaBlinkLo.text),
                      oh = double.parse(icaOtherHi.text),
                      ol = double.parse(icaOtherLo.text),
                      ac = double.parse(asrCutoff.text),
                      fc = double.parse(icaFitCutoff.text);
                  final ne = int.parse(icaEpochs.text),
                      sd = int.parse(icaSeed.text);
                  if (!eh.isFinite ||
                      !el.isFinite ||
                      !oh.isFinite ||
                      !ol.isFinite ||
                      eh > 1 ||
                      oh > 1 ||
                      el <= 0 ||
                      ol <= 0 ||
                      ne < 2 ||
                      sd < 0)
                    throw const FormatException(
                      'ICA thresholds must be in (0, 1], blink epochs at least 2, seed non-negative.',
                    );
                  if (!fc.isFinite || fc < 1 || fc > 200)
                    throw const FormatException(
                      'ICA fit ASR cutoff must be between 1 and 200.',
                    );
                  if (!ac.isFinite || ac < 1 || ac > 200)
                    throw const FormatException(
                      'ASR cutoff must be between 1 and 200.',
                    );
                  final aa = double.parse(asrAlpha.text),
                      ed = int.parse(asrEmbedDim.text),
                      et = int.parse(asrEmbedTau.text),
                      am = int.parse(asrModes.text),
                      bn = int.parse(bsscaN.text),
                      it = double.parse(iccThr.text),
                      wl = int.parse(wicaLevels.text);
                  if (!aa.isFinite || aa < 0 || aa > 1)
                    throw const FormatException(
                      'Adaptive ASR rate must be in [0, 1].',
                    );
                  if (ed < 2 || ed > 32 || et < 1 || et > 50)
                    throw const FormatException(
                      'E-ASR dimension must be 2-32 and delay 1-50.',
                    );
                  if (am < 2 || am > 12)
                    throw const FormatException('Mode count must be 2-12.');
                  if (bn < 1)
                    throw const FormatException(
                      'BSS-CCA must remove at least 1 source.',
                    );
                  if (!it.isFinite || it <= 0 || it >= 1)
                    throw const FormatException(
                      'iCanClean R² threshold must be in (0, 1).',
                    );
                  if (wl < 1 || wl > 12)
                    throw const FormatException('wICA levels must be 1-12.');
                  config
                    ..icaBlink = icaBlink
                    ..icaOther = icaOther
                    ..icaRemoveEcg = icaRemoveEcg
                    ..icaFitAsr = icaFitAsr
                    ..icaEyeChannel = icaEye.text.trim()
                    ..icaBlinkEpochs = ne
                    ..icaBlinkThreshold = eh
                    ..icaBlinkThresholdFloor = el
                    ..icaOtherThreshold = oh
                    ..icaOtherThresholdFloor = ol
                    ..icaSeed = sd
                    ..asrCutoff = ac
                    ..asrAdaptAlpha = aa
                    ..asrEmbedDim = ed
                    ..asrEmbedTau = et
                    ..asrModes = am
                    ..bsscaNRemove = bn
                    ..iccThreshold = it
                    ..wicaLevels = wl
                    ..icaFitAsrCutoff = fc
                    ..icaArtefacts = icaArtefacts.text
                        .split(',')
                        .map((v) => v.trim())
                        .where((v) => v.isNotEmpty)
                        .toList();
                  config
                    ..badVarianceRatio = vr
                    ..splineStiffness = ss
                    ..splineRegularization = sr
                    ..gedaiThreshold = gedaiThreshold.text.trim()
                    ..filterType = filterType
                    ..iirOrder = o
                    ..firTaps = n
                    ..notchWidthHz = w
                    ..notchTransitionHz = t
                    ..referenceMode = reference
                    ..referenceChannels = refs;
                  if (reference != 'none')
                    config
                      ..featureReferenceMode = 'none'
                      ..featureReferenceChannels = [];
                } else if (stage == 'Source Space') {
                  final value = double.parse(snr.text);
                  if (!value.isFinite || value <= 0)
                    throw const FormatException('SNR must be positive.');
                  config
                    ..sourceMethod = sourceMethod
                    ..sourceModelPath = sourceModel.text.trim()
                    ..sourceSnr = value
                    ..sourceRegions = regions.text
                        .split(',')
                        .map((s) => s.trim())
                        .where((s) => s.isNotEmpty)
                        .toList();
                } else {
                  double psdWinVal = config.psdWindowSeconds;
                  if (psdMethod == 'welch') {
                    final value = double.parse(window.text);
                    if (!value.isFinite || value <= 0)
                      throw const FormatException(
                        'PSD window must be positive.',
                      );
                    psdWinVal = value;
                  } else {
                    final nw = double.parse(psdMultitaperNw.text);
                    if (!nw.isFinite || nw < 1.0 || nw > 20.0)
                      throw const FormatException(
                        'Multitaper NW must be between 1.0 and 20.0.',
                      );
                  }
                  final parsed = <Map<String, dynamic>>[];
                  for (final line
                      in bands.text
                          .split('\n')
                          .where((l) => l.trim().isNotEmpty)) {
                    final match = RegExp(
                      r'^\s*([A-Za-z][A-Za-z0-9_]*)\s*:\s*([0-9.]+)\s*-\s*([0-9.]+)\s*$',
                    ).firstMatch(line);
                    if (match == null)
                      throw const FormatException(
                        'Use label: low-high for each band.',
                      );
                    final low = double.parse(match[2]!),
                        high = double.parse(match[3]!);
                    if (!low.isFinite ||
                        !high.isFinite ||
                        high <= low ||
                        parsed.any((b) => b['label'] == match[1]))
                      throw const FormatException(
                        'Band limits and labels must be valid and unique.',
                      );
                    parsed.add({'label': match[1], 'low': low, 'high': high});
                  }
                  final advancedValues = <String, dynamic>{};
                  for (final entry in definitions.entries) {
                    final value = double.parse(advanced[entry.key]!.text);
                    if (!value.isFinite ||
                        value < entry.value.$3 ||
                        value > entry.value.$4 ||
                        (entry.value.$5 && value != value.roundToDouble()))
                      throw FormatException('Invalid ${entry.value.$1}');
                    advancedValues[entry.key] = entry.value.$5
                        ? value.toInt()
                        : value;
                  }
                  final hs = factors.text
                      .split(',')
                      .where((s) => s.trim().isNotEmpty)
                      .map((s) => double.parse(s.trim()))
                      .toList();
                  if (hs.any(
                    (h) =>
                        !h.isFinite ||
                        (h * 100).round() <= 100 ||
                        (h * 100).round() >= 200,
                  ))
                    throw const FormatException(
                      'IRASA factors must round to values strictly between 1 and 2.',
                    );
                  advancedValues['irasa_factors'] = hs;
                  final refs = featureRefs.text
                      .split(',')
                      .map((v) => v.trim())
                      .where((v) => v.isNotEmpty)
                      .toList();
                  if (featureReference == 'channels' && refs.isEmpty)
                    throw const FormatException(
                      'Choose feature reference channels.',
                    );
                  if (spectralSettings) config.spectralGraph = spectralGraph;
                  if (roiSettings) {
                    if (seed.isNotEmpty && target.isNotEmpty && seed.every(target.contains)) throw const FormatException('Choose at least one target channel outside the seed region.');
                    config..roiSeed = seed..roiTarget = target
                      ..roiSeedName = seed.isEmpty ? 'default' : 'Custom'
                      ..roiTargetName = target.isEmpty ? 'default' : 'Custom';
                  }
                  config
                    ..featureReferenceMode = featureReference
                    ..featureReferenceChannels = refs
                    ..psdMethod = psdMethod
                    ..psdAverage = average
                    ..psdWindowSeconds = psdWinVal
                    ..psdMultitaperNw =
                        double.tryParse(psdMultitaperNw.text) ?? 3.0
                    ..psdMultitaperAdaptive = psdMultitaperAdaptive
                    ..psdBands = parsed
                    ..featureParameters = advancedValues;
                }
                if (stage != 'Feature Extraction') await RecordingStorage.setPreferredFormat(outputFormat);
                if (context.mounted) Navigator.pop(context, true);
              } catch (e) {
                setState(() => error = '$e');
              }
            },
            child: const Text('Apply'),
          ),
        ],
      ),
    ),
  );
  for (final c in [
    gedaiThreshold,
    ...advanced.values,
    factors,
    variance,
    stiffness,
    regularization,
    taps,
    width,
    transition,
    references,
    snr,
    sourceModel,
    regions,
    window,
    psdMultitaperNw,
    bands,
    order,
    featureRefs,
    icaEye,
    icaEpochs,
    icaBlinkHi,
    icaBlinkLo,
    icaArtefacts,
    icaOtherHi,
    icaOtherLo,
    icaSeed,
    icaFitCutoff,
    asrCutoff,
    asrAlpha,
    asrEmbedDim,
    asrEmbedTau,
    asrModes,
    bsscaN,
    iccThr,
    wicaLevels,
  ]) {
    c.dispose();
  }
  return changed == true;
}


class _FrequencyBandEditor extends StatefulWidget {
  const _FrequencyBandEditor({required this.controller});
  final TextEditingController controller;
  @override
  State<_FrequencyBandEditor> createState() => _FrequencyBandEditorState();
}
class _FrequencyBandEditorState extends State<_FrequencyBandEditor> {
  final List<List<TextEditingController>> rows = [];
  void add([List<String> values = const ['', '', '']]) {
    rows.add([for (final value in values) TextEditingController(text: value)]);
  }
  @override
  void initState() {
    super.initState();
    for (final line in widget.controller.text.split('\n')) {
      final parts = RegExp(r'^(.+):\s*([0-9.]+)-([0-9.]+)$').firstMatch(line.trim());
      if (parts != null) add([parts[1]!.trim(), parts[2]!, parts[3]!]);
    }
  }
  void sync() => widget.controller.text = rows.map((r) => '${r[0].text}: ${r[1].text}-${r[2].text}').join('\n');
  @override
  void dispose() { for (final row in rows) { for (final c in row) { c.dispose(); } } super.dispose(); }
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    const Text('Frequency bands (shared by band-based features)', style: TextStyle(fontWeight: FontWeight.bold)),
    if (rows.isEmpty) const Text('Standard bands (Hz): Delta 1–4 · Theta 4–8 · ThetaAlpha 6–10 · Alpha 8–12 · Beta1 12–18 · Beta2 18–30 · Gamma1 30–40. Add rows to use custom bands instead.'),
    const Text('Connectivity uses 4–40 Hz; FOOOF / IRASA use 1–40 Hz.'),
    for (final row in rows) Row(children: [
      for (var i = 0; i < 3; i++) Expanded(child: Padding(padding: const EdgeInsets.all(4), child: TextField(controller: row[i], decoration: InputDecoration(labelText: ['Band name', 'From (Hz)', 'To (Hz)'][i]), onChanged: (_) => sync()))),
      IconButton(tooltip: 'Remove band', icon: const Icon(Icons.delete_outline), onPressed: () => setState(() { rows.remove(row); for (final c in row) { c.dispose(); } sync(); })),
    ]),
    TextButton.icon(icon: const Icon(Icons.add), label: const Text('Add frequency band'), onPressed: () => setState(() { add(); sync(); })),
    TextButton(onPressed: () => setState(() { for (final r in rows) { for (final c in r) { c.dispose(); } } rows.clear(); sync(); }), child: const Text('Use standard bands')),
  ]);
}
