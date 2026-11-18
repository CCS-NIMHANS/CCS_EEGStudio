import 'dart:convert';
import 'dart:io';

import '../models.dart';

/// Generates publication-ready preprocessing & feature extraction parameter logs
/// and a combined Batch Methodology & Results report.
class MethodologyReport {
  static Future<void> writeParameterLogs({
    required Directory outputDir,
    required AnalysisConfig config,
    List<String> inputFiles = const [],
    String? title,
  }) async {
    await outputDir.create(recursive: true);
    final now = DateTime.now().toIso8601String();
    final prepJson = {
      'generated_at': now,
      'app': 'CCS EEG Studio',
      'context': ?title,
      'input_files': inputFiles,
      'preprocessing': config.toPreprocessingOptions().toJson(),
    };
    final featJson = {
      'generated_at': now,
      'app': 'CCS EEG Studio',
      'context': ?title,
      'input_files': inputFiles,
      'feature_extraction': config.toExtractionOptions().toJson(),
    };
    await File(
      '${outputDir.path}${Platform.pathSeparator}preprocessing_parameters.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(prepJson));
    await File(
      '${outputDir.path}${Platform.pathSeparator}feature_parameters.json',
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(featJson));

    final md = StringBuffer()
      ..writeln('# Analysis Parameter Log')
      ..writeln()
      ..writeln('- **Generated:** $now')
      ..writeln('- **Inputs (${inputFiles.length}):** ${inputFiles.take(10).map((p) => p.split(RegExp(r"[\\/]")).last).join(", ")}${inputFiles.length > 10 ? " …" : ""}')
      ..writeln()
      ..writeln('## Preprocessing Parameters')
      ..writeln('- **Resample:** ${config.downsample ? "${config.downsampleFreq} Hz" : "Disabled"}')
      ..writeln('- **Bandpass / Notch Filter:** ${config.filter ? "${config.lowHz}–${config.highHz} Hz (${config.filterType.toUpperCase()}), Notch ${config.notchHz} Hz" : "Disabled"}')
      ..writeln('- **Bad Channel Detection:** Auto=${config.badChannels}, Manual=[${config.manualBadChannels.join(", ")}], Interpolate=${config.interpolate}')
      ..writeln('- **ICA / ICLabel:** ${config.icaMethod} (Eye thresh=${config.icaBlinkThreshold}/${config.icaBlinkThresholdFloor}, Other=${config.icaOtherThreshold}/${config.icaOtherThresholdFloor})')
      ..writeln('- **Muscle Cleaning:** ${config.muscleMethod}')
      ..writeln('- **ASR:** ${config.asrMode} (cutoff=${config.asrCutoff}, variant=${config.asrVariant})')
      ..writeln('- **GEDAI:** ${config.gedai ? "Enabled (threshold=${config.gedaiThreshold}, epoch=${config.gedaiEpochSeconds} s)" : "Disabled"}')
      ..writeln('- **Re-reference:** ${config.referenceMode}')
      ..writeln('- **Source Localization:** ${config.sourceLocalization ? "${config.sourceMethod.toUpperCase()} (SNR=${config.sourceSnr})" : "Sensor space"}')
      ..writeln()
      ..writeln('## Feature Extraction Parameters')
      ..writeln('- **Epoch / Bin Window:** ${config.epochSeconds} s (overlap ${config.epochOverlapSeconds} s)')
      ..writeln('- **PSD / IAF / Frequency Sliding:** ${config.psd ? "${config.psdMethod}, window=${config.psdWindowSeconds} s, IAF + IndAlpha/IndTheta + Frequency Sliding" : "Disabled"}')
      ..writeln('- **FOOOF:** ${config.fooof ? "Enabled" : "Disabled"} · **IRASA:** ${config.irasa ? "Enabled" : "Disabled"}')
      ..writeln('- **Nonlinear / DFA / fE:I / ACW:** Nonlinear=${config.nonlinear}, DFA/fE:I=${config.dfaFei}, ACW=${config.acw}')
      ..writeln('- **Connectivity:** COH=${config.coh}, PLV=${config.plv}, ciPLV=${config.ciplv}, PLI=${config.pli}, wPLI=${config.wpli}, MIC=${config.mic}, MIM=${config.mim}, GC=${config.gc}');

    await File(
      '${outputDir.path}${Platform.pathSeparator}analysis_parameters_log.md',
    ).writeAsString(md.toString());
  }

  static Future<File> writeBatchMethodologyAndResultsReport({
    required Directory outputDir,
    required AnalysisConfig config,
    required List<String> inputFiles,
    required List<String> outputFiles,
    required Map<String, String> fileStatuses,
    String? groupStatsSummary,
  }) async {
    await writeParameterLogs(
      outputDir: outputDir,
      config: config,
      inputFiles: inputFiles,
      title: 'Batch Analysis',
    );
    final now = DateTime.now().toIso8601String();
    final okCount = fileStatuses.values
        .where((v) => v.toLowerCase().contains('done') || v.toLowerCase().contains('ok'))
        .length;
    final md = StringBuffer()
      ..writeln('# CCS EEG Studio — Batch Methodology & Results Report')
      ..writeln()
      ..writeln('**Generated:** $now  ')
      ..writeln('**Total Recordings Queued:** ${inputFiles.length} · **Completed:** $okCount')
      ..writeln()
      ..writeln('## 1. Publication-Ready Methodology Summary')
      ..writeln()
      ..writeln(
        'EEG recordings were processed using **CCS EEG Studio** (native Rust `ccs_eeg_engine`). '
        '${config.downsample ? "Signals were resampled to ${config.downsampleFreq} Hz. " : ""}'
        '${config.filter ? "Bandpass (${config.lowHz}–${config.highHz} Hz, ${config.filterType.toUpperCase()}) and notch (${config.notchHz} Hz) filtering were applied. " : ""}'
        '${config.badChannels || config.manualBadChannels.isNotEmpty ? "Bad channels were identified via automated flatline, log-variance, and spatial-correlation checks${config.manualBadChannels.isNotEmpty ? " alongside manual exclusions (${config.manualBadChannels.join(", ")})" : ""}${config.interpolate ? " and spherically interpolated" : ""}. " : ""}'
        '${config.icaMethod != "none" ? "Independent Component Analysis (${config.icaMethod}) with ICLabel-style artifact classification removed ocular/artifact components. " : ""}'
        '${config.asrMode != "off" ? "Artifact Subspace Reconstruction (${config.asrMode}, cutoff=${config.asrCutoff}) repaired transient high-amplitude bursts. " : ""}'
        '${config.gedai ? "GEDAI (${config.gedaiThreshold}) attenuated spatially non-physiological noise. " : ""}'
        '${config.referenceMode != "none" ? "Data were re-referenced (${config.referenceMode}). " : ""}'
        '${config.sourceLocalization ? "Source-space ROI time series were estimated using ${config.sourceMethod.toUpperCase()} (SNR=${config.sourceSnr}). " : ""}'
        'Features were extracted in ${config.epochSeconds} s epochs (${config.epochOverlapSeconds} s overlap)${config.psd ? ", including Welch/multitaper PSD, Individual Alpha Frequency (IAF), Individual Alpha/Theta power, and Alpha/Theta frequency sliding" : ""}'
        '${config.fooof ? ", FOOOF aperiodic/periodic decomposition" : ""}'
        '${config.irasa ? ", IRASA fractal separation" : ""}'
        '${config.anyConnectivity ? ", and functional connectivity metrics" : ""}.',
      )
      ..writeln()
      ..writeln('## 2. File Processing Results')
      ..writeln()
      ..writeln('| # | Recording | Status |')
      ..writeln('| :--- | :--- | :--- |');
    for (var i = 0; i < inputFiles.length; i++) {
      final f = inputFiles[i];
      final name = f.split(RegExp(r'[\\/]')).last;
      final st = fileStatuses[f] ?? 'Processed';
      md.writeln('| ${i + 1} | `$name` | $st |');
    }
    md
      ..writeln()
      ..writeln('## 3. Generated Outputs (${outputFiles.length})')
      ..writeln();
    for (final out in outputFiles) {
      md.writeln('- `${out.split(RegExp(r'[\\/]')).last}`');
    }
    if (groupStatsSummary != null && groupStatsSummary.trim().isNotEmpty) {
      md
        ..writeln()
        ..writeln('## 4. Group Statistics Summary')
        ..writeln()
        ..writeln(groupStatsSummary);
    }

    final reportFile = File(
      '${outputDir.path}${Platform.pathSeparator}batch_methodology_and_results_report.md',
    );
    await reportFile.writeAsString(md.toString());
    return reportFile;
  }
}
