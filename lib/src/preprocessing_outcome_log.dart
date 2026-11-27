import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'models.dart';
import 'theme.dart';

class PreprocessingOutcomeEntry {
  const PreprocessingOutcomeEntry({
    required this.fileName,
    required this.inputPath,
    required this.outputPath,
    required this.status,
    this.error,
    required this.inputChannelsTotal,
    required this.nonEegRemoved,
    required this.inputEegChannels,
    required this.outputChannels,
    required this.inputSampleRateHz,
    required this.outputSampleRateHz,
    required this.inputDurationSec,
    required this.outputDurationSec,
    required this.durationLostSec,
    required this.signalLostPct,
    required this.asrSamplesModified,
    required this.asrSamplesTotal,
    required this.asrModifiedPct,
    required this.epochsDropped,
    required this.badChannels,
    required this.interpolatedChannels,
    required this.skippedInterpolationChannels,
    required this.icaBlinkRemoved,
    required this.icaOtherRemoved,
    required this.icaTotalComponents,
    this.gedaiReference,
    this.gedaiAlphaRetentionPct,
    required this.inputRmsUv,
    required this.outputRmsUv,
    required this.rmsChangePct,
    required this.inputRangeMinUv,
    required this.inputRangeMaxUv,
    required this.inputP01Uv,
    required this.inputP99Uv,
    required this.outputRangeMinUv,
    required this.outputRangeMaxUv,
    required this.outputP01Uv,
    required this.outputP99Uv,
    this.signalChangeNrmsePct,
    this.signalCorrelationMedian,
    this.blinkEventsCount,
    this.eyeMovementEventsCount,
    this.emgSurgeEventsCount,
    this.ecgRPeaksCount,
    this.stepsApplied = const [],
    this.warnings = const [],
  });

  final String fileName;
  final String inputPath;
  final String outputPath;
  final String status;
  final String? error;
  final int inputChannelsTotal;
  final List<String> nonEegRemoved;
  final int inputEegChannels;
  final int outputChannels;
  final double inputSampleRateHz;
  final double outputSampleRateHz;
  final double inputDurationSec;
  final double outputDurationSec;
  final double durationLostSec;
  final double signalLostPct;
  final int asrSamplesModified;
  final int asrSamplesTotal;
  final double asrModifiedPct;
  final int epochsDropped;
  final List<String> badChannels;
  final List<String> interpolatedChannels;
  final List<String> skippedInterpolationChannels;
  final int icaBlinkRemoved;
  final int icaOtherRemoved;
  final int icaTotalComponents;
  final String? gedaiReference;
  final double? gedaiAlphaRetentionPct;
  final double inputRmsUv;
  final double outputRmsUv;
  final double rmsChangePct;
  final double inputRangeMinUv;
  final double inputRangeMaxUv;
  final double inputP01Uv;
  final double inputP99Uv;
  final double outputRangeMinUv;
  final double outputRangeMaxUv;
  final double outputP01Uv;
  final double outputP99Uv;
  final double? signalChangeNrmsePct;
  final double? signalCorrelationMedian;
  final int? blinkEventsCount;
  final int? eyeMovementEventsCount;
  final int? emgSurgeEventsCount;
  final int? ecgRPeaksCount;
  final List<String> stepsApplied;
  final List<String> warnings;

  static String _baseName(String path) =>
      path.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).lastOrNull ??
      path;

  factory PreprocessingOutcomeEntry.fromRecording(
    EegRecording rec, {
    String status = 'Completed',
    String? error,
    String? sourceInputPath,
    Map<String, dynamic>? physioSummary,
  }) {
    final p = rec.provenance;
    final summary = p['summary'] is Map
        ? Map<String, dynamic>.from(p['summary'] as Map)
        : <String, dynamic>{};
    final out = summary['outcomes'] is Map
        ? Map<String, dynamic>.from(summary['outcomes'] as Map)
        : <String, dynamic>{};
    final physio = physioSummary ??
        (p['physio_events_summary'] is Map
            ? Map<String, dynamic>.from(p['physio_events_summary'] as Map)
            : null);

    final src = sourceInputPath ?? p['source_path'] as String? ?? rec.path;
    final bad = (summary['bad_channels'] as List?)?.cast<String>() ?? const [];
    final interp =
        (summary['interpolated_channels'] as List?)?.cast<String>() ?? const [];
    final skippedInterp =
        (summary['skipped_interpolation_channels'] as List?)?.cast<String>() ??
        const [];
    final warnings =
        (summary['warnings'] as List?)?.map((e) => '$e').toList() ?? const [];

    return PreprocessingOutcomeEntry(
      fileName: _baseName(src),
      inputPath: src,
      outputPath: rec.path,
      status: status,
      error: error,
      inputChannelsTotal:
          (out['input_channels_total'] as num?)?.toInt() ?? rec.labels.length,
      nonEegRemoved:
          (out['non_eeg_channels_removed'] as List?)?.cast<String>() ??
          const [],
      inputEegChannels:
          (out['input_eeg_channels'] as num?)?.toInt() ?? rec.labels.length,
      outputChannels:
          (out['output_channels'] as num?)?.toInt() ?? rec.labels.length,
      inputSampleRateHz:
          (out['input_sample_rate_hz'] as num?)?.toDouble() ?? rec.sampleRate,
      outputSampleRateHz:
          (out['output_sample_rate_hz'] as num?)?.toDouble() ?? rec.sampleRate,
      inputDurationSec:
          (out['input_duration_sec'] as num?)?.toDouble() ??
          rec.durationSeconds,
      outputDurationSec:
          (out['output_duration_sec'] as num?)?.toDouble() ??
          rec.durationSeconds,
      durationLostSec: (out['duration_lost_sec'] as num?)?.toDouble() ?? 0.0,
      signalLostPct: (out['signal_lost_pct'] as num?)?.toDouble() ?? 0.0,
      asrSamplesModified:
          (out['asr_samples_modified'] as num?)?.toInt() ?? 0,
      asrSamplesTotal: (out['asr_samples_total'] as num?)?.toInt() ?? 0,
      asrModifiedPct: (out['asr_modified_pct'] as num?)?.toDouble() ?? 0.0,
      epochsDropped: (out['epochs_dropped'] as num?)?.toInt() ?? 0,
      badChannels: bad,
      interpolatedChannels: interp,
      skippedInterpolationChannels: skippedInterp,
      icaBlinkRemoved:
          (out['ica_blink_components_removed'] as num?)?.toInt() ?? 0,
      icaOtherRemoved:
          (out['ica_other_components_removed'] as num?)?.toInt() ?? 0,
      icaTotalComponents: (out['ica_total_components'] as num?)?.toInt() ?? 0,
      gedaiReference: summary['gedai_reference'] as String?,
      gedaiAlphaRetentionPct:
          (out['gedai_alpha_retention_pct'] as num?)?.toDouble(),
      inputRmsUv: (out['input_rms_uv'] as num?)?.toDouble() ?? 0.0,
      outputRmsUv: (out['output_rms_uv'] as num?)?.toDouble() ?? 0.0,
      rmsChangePct: (out['rms_change_pct'] as num?)?.toDouble() ?? 0.0,
      inputRangeMinUv:
          (out['input_range_min_uv'] as num?)?.toDouble() ?? 0.0,
      inputRangeMaxUv:
          (out['input_range_max_uv'] as num?)?.toDouble() ?? 0.0,
      inputP01Uv: (out['input_p01_uv'] as num?)?.toDouble() ?? 0.0,
      inputP99Uv: (out['input_p99_uv'] as num?)?.toDouble() ?? 0.0,
      outputRangeMinUv:
          (out['output_range_min_uv'] as num?)?.toDouble() ?? 0.0,
      outputRangeMaxUv:
          (out['output_range_max_uv'] as num?)?.toDouble() ?? 0.0,
      outputP01Uv: (out['output_p01_uv'] as num?)?.toDouble() ?? 0.0,
      outputP99Uv: (out['output_p99_uv'] as num?)?.toDouble() ?? 0.0,
      signalChangeNrmsePct:
          (out['signal_change_nrmse_pct'] as num?)?.toDouble(),
      signalCorrelationMedian:
          (out['signal_correlation_median'] as num?)?.toDouble(),
      blinkEventsCount: (physio?['blink_count'] as num?)?.toInt(),
      eyeMovementEventsCount:
          (physio?['eye_movement_count'] as num?)?.toInt(),
      emgSurgeEventsCount: (physio?['emg_surge_count'] as num?)?.toInt(),
      ecgRPeaksCount: (physio?['ecg_r_peak_count'] as num?)?.toInt(),
      stepsApplied:
          (out['steps_applied'] as List?)?.cast<String>() ?? const [],
      warnings: warnings,
    );
  }

  factory PreprocessingOutcomeEntry.fromError(
    String inputPath,
    String error, {
    String status = 'Failed',
  }) => PreprocessingOutcomeEntry(
    fileName: _baseName(inputPath),
    inputPath: inputPath,
    outputPath: '',
    status: status,
    error: error,
    inputChannelsTotal: 0,
    nonEegRemoved: const [],
    inputEegChannels: 0,
    outputChannels: 0,
    inputSampleRateHz: 0,
    outputSampleRateHz: 0,
    inputDurationSec: 0,
    outputDurationSec: 0,
    durationLostSec: 0,
    signalLostPct: 0,
    asrSamplesModified: 0,
    asrSamplesTotal: 0,
    asrModifiedPct: 0,
    epochsDropped: 0,
    badChannels: const [],
    interpolatedChannels: const [],
    skippedInterpolationChannels: const [],
    icaBlinkRemoved: 0,
    icaOtherRemoved: 0,
    icaTotalComponents: 0,
    inputRmsUv: 0,
    outputRmsUv: 0,
    rmsChangePct: 0,
    inputRangeMinUv: 0,
    inputRangeMaxUv: 0,
    inputP01Uv: 0,
    inputP99Uv: 0,
    outputRangeMinUv: 0,
    outputRangeMaxUv: 0,
    outputP01Uv: 0,
    outputP99Uv: 0,
  );

  List<String> toLogLines() {
    if (status == 'Failed' || status == 'Cancelled') {
      return ['  Outcome [$status]: ${error ?? 'unknown error'}'];
    }
    final parts = <String>[
      'Signal lost: ${signalLostPct.toStringAsFixed(1)}% (${durationLostSec.toStringAsFixed(2)}s)',
      if (asrModifiedPct > 0) 'ASR modified: ${asrModifiedPct.toStringAsFixed(1)}%',
      if (epochsDropped > 0) 'Epochs dropped: $epochsDropped',
      'Bad ch: ${badChannels.isEmpty ? 'none' : badChannels.join(', ')}',
      'Interpolated (${interpolatedChannels.length}): ${interpolatedChannels.isEmpty ? 'none' : interpolatedChannels.join(', ')}',
      if (skippedInterpolationChannels.isNotEmpty)
        'Skipped interp: ${skippedInterpolationChannels.join(', ')}',
      if (signalChangeNrmsePct != null || signalCorrelationMedian != null)
        'Signal change: ${signalChangeNrmsePct?.toStringAsFixed(1) ?? '-'}% NRMSE · r=${signalCorrelationMedian?.toStringAsFixed(3) ?? '-'}',
      'RMS: ${inputRmsUv.toStringAsFixed(1)}→${outputRmsUv.toStringAsFixed(1)} µV (${rmsChangePct >= 0 ? '+' : ''}${rmsChangePct.toStringAsFixed(1)}%)',
      'New range: [${outputRangeMinUv.toStringAsFixed(1)}, ${outputRangeMaxUv.toStringAsFixed(1)}] µV (P1..P99: ${outputP01Uv.toStringAsFixed(1)}..${outputP99Uv.toStringAsFixed(1)} µV)',
    ];
    return ['  Outcome [$status]: ${parts.join(' | ')}'];
  }

  Map<String, dynamic> toJson() => {
    'file_name': fileName,
    'input_path': inputPath,
    'output_path': outputPath,
    'status': status,
    if (error != null) 'error': error,
    'input_channels_total': inputChannelsTotal,
    'non_eeg_removed': nonEegRemoved,
    'input_eeg_channels': inputEegChannels,
    'output_channels': outputChannels,
    'input_sample_rate_hz': inputSampleRateHz,
    'output_sample_rate_hz': outputSampleRateHz,
    'input_duration_sec': inputDurationSec,
    'output_duration_sec': outputDurationSec,
    'duration_lost_sec': durationLostSec,
    'signal_lost_pct': signalLostPct,
    'asr_samples_modified': asrSamplesModified,
    'asr_samples_total': asrSamplesTotal,
    'asr_modified_pct': asrModifiedPct,
    'epochs_dropped': epochsDropped,
    'bad_channels': badChannels,
    'interpolated_channels': interpolatedChannels,
    'skipped_interpolation_channels': skippedInterpolationChannels,
    'ica_blink_removed': icaBlinkRemoved,
    'ica_other_removed': icaOtherRemoved,
    'ica_total_components': icaTotalComponents,
    if (gedaiReference != null) 'gedai_reference': gedaiReference,
    if (gedaiAlphaRetentionPct != null)
      'gedai_alpha_retention_pct': gedaiAlphaRetentionPct,
    'input_rms_uv': inputRmsUv,
    'output_rms_uv': outputRmsUv,
    'rms_change_pct': rmsChangePct,
    'input_range_min_uv': inputRangeMinUv,
    'input_range_max_uv': inputRangeMaxUv,
    'input_p01_uv': inputP01Uv,
    'input_p99_uv': inputP99Uv,
    'output_range_min_uv': outputRangeMinUv,
    'output_range_max_uv': outputRangeMaxUv,
    'output_p01_uv': outputP01Uv,
    'output_p99_uv': outputP99Uv,
    if (signalChangeNrmsePct != null)
      'signal_change_nrmse_pct': signalChangeNrmsePct,
    if (signalCorrelationMedian != null)
      'signal_correlation_median': signalCorrelationMedian,
    if (blinkEventsCount != null) 'blink_events_count': blinkEventsCount,
    if (eyeMovementEventsCount != null)
      'eye_movement_events_count': eyeMovementEventsCount,
    if (emgSurgeEventsCount != null)
      'emg_surge_events_count': emgSurgeEventsCount,
    if (ecgRPeaksCount != null) 'ecg_r_peaks_count': ecgRPeaksCount,
    'steps_applied': stepsApplied,
    'warnings': warnings,
  };

  static const List<String> csvHeaders = [
    'file_name',
    'status',
    'input_path',
    'output_path',
    'input_channels_total',
    'non_eeg_removed',
    'input_eeg_channels',
    'output_channels',
    'input_rate_hz',
    'output_rate_hz',
    'input_duration_sec',
    'output_duration_sec',
    'duration_lost_sec',
    'signal_lost_pct',
    'asr_modified_pct',
    'epochs_dropped',
    'bad_channels_count',
    'bad_channels',
    'interpolated_count',
    'interpolated_channels',
    'skipped_interpolation_count',
    'skipped_interpolation_channels',
    'ica_blink_removed',
    'ica_other_removed',
    'gedai_alpha_retention_pct',
    'input_rms_uv',
    'output_rms_uv',
    'rms_change_pct',
    'signal_change_nrmse_pct',
    'signal_correlation_median',
    'input_range_uv',
    'output_range_uv',
    'output_p01_uv',
    'output_p99_uv',
    'physio_blinks',
    'physio_eye_moves',
    'physio_emg_surges',
    'physio_ecg_r_peaks',
    'steps_applied',
    'warnings_or_error',
  ];

  static String _csvCell(Object? v) {
    final s = '${v ?? ''}';
    return s.contains(RegExp('[,"\n\r]'))
        ? '"${s.replaceAll('"', '""')}"'
        : s;
  }

  List<String> toCsvFields() => [
    fileName,
    status,
    inputPath,
    outputPath,
    '$inputChannelsTotal',
    nonEegRemoved.join('; '),
    '$inputEegChannels',
    '$outputChannels',
    inputSampleRateHz.toStringAsFixed(2),
    outputSampleRateHz.toStringAsFixed(2),
    inputDurationSec.toStringAsFixed(2),
    outputDurationSec.toStringAsFixed(2),
    durationLostSec.toStringAsFixed(2),
    signalLostPct.toStringAsFixed(2),
    asrModifiedPct.toStringAsFixed(2),
    '$epochsDropped',
    '${badChannels.length}',
    badChannels.join('; '),
    '${interpolatedChannels.length}',
    interpolatedChannels.join('; '),
    '${skippedInterpolationChannels.length}',
    skippedInterpolationChannels.join('; '),
    '$icaBlinkRemoved',
    '$icaOtherRemoved',
    gedaiAlphaRetentionPct?.toStringAsFixed(1) ?? '',
    inputRmsUv.toStringAsFixed(2),
    outputRmsUv.toStringAsFixed(2),
    rmsChangePct.toStringAsFixed(2),
    signalChangeNrmsePct?.toStringAsFixed(2) ?? '',
    signalCorrelationMedian?.toStringAsFixed(4) ?? '',
    '${inputRangeMinUv.toStringAsFixed(1)} .. ${inputRangeMaxUv.toStringAsFixed(1)}',
    '${outputRangeMinUv.toStringAsFixed(1)} .. ${outputRangeMaxUv.toStringAsFixed(1)}',
    outputP01Uv.toStringAsFixed(2),
    outputP99Uv.toStringAsFixed(2),
    '${blinkEventsCount ?? ''}',
    '${eyeMovementEventsCount ?? ''}',
    '${emgSurgeEventsCount ?? ''}',
    '${ecgRPeaksCount ?? ''}',
    stepsApplied.join('; '),
    error ?? warnings.join(' | '),
  ];

  String toCsvRow() => toCsvFields().map(_csvCell).join(',');

  static String buildBatchCollatedCsv(List<PreprocessingOutcomeEntry> entries) {
    final buf = StringBuffer()..writeln(csvHeaders.map(_csvCell).join(','));
    for (final e in entries) {
      buf.writeln(e.toCsvRow());
    }
    final ok = entries.where((e) => e.outputPath.isNotEmpty).toList();
    if (ok.isNotEmpty) {
      double medianOf(Iterable<double> xs) {
        final s = xs.toList()..sort();
        if (s.isEmpty) return 0.0;
        return s[s.length ~/ 2];
      }

      final nrmseVals = ok
          .map((e) => e.signalChangeNrmsePct)
          .whereType<double>()
          .toList();
      final corrVals = ok
          .map((e) => e.signalCorrelationMedian)
          .whereType<double>()
          .toList();
      final summaryRow = <String>[
        'BATCH SUMMARY (${ok.length}/${entries.length} ready)',
        'Summary',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        ok.fold(0.0, (a, b) => a + b.inputDurationSec).toStringAsFixed(2),
        ok.fold(0.0, (a, b) => a + b.outputDurationSec).toStringAsFixed(2),
        ok.fold(0.0, (a, b) => a + b.durationLostSec).toStringAsFixed(2),
        medianOf(ok.map((e) => e.signalLostPct)).toStringAsFixed(2),
        medianOf(ok.map((e) => e.asrModifiedPct)).toStringAsFixed(2),
        '${ok.fold(0, (a, b) => a + b.epochsDropped)}',
        '${ok.fold(0, (a, b) => a + b.badChannels.length)}',
        '',
        '${ok.fold(0, (a, b) => a + b.interpolatedChannels.length)}',
        '',
        '${ok.fold(0, (a, b) => a + b.skippedInterpolationChannels.length)}',
        '',
        '${ok.fold(0, (a, b) => a + b.icaBlinkRemoved)}',
        '${ok.fold(0, (a, b) => a + b.icaOtherRemoved)}',
        '',
        medianOf(ok.map((e) => e.inputRmsUv)).toStringAsFixed(2),
        medianOf(ok.map((e) => e.outputRmsUv)).toStringAsFixed(2),
        medianOf(ok.map((e) => e.rmsChangePct)).toStringAsFixed(2),
        nrmseVals.isEmpty ? '' : medianOf(nrmseVals).toStringAsFixed(2),
        corrVals.isEmpty ? '' : medianOf(corrVals).toStringAsFixed(4),
        '',
        '',
        medianOf(ok.map((e) => e.outputP01Uv)).toStringAsFixed(2),
        medianOf(ok.map((e) => e.outputP99Uv)).toStringAsFixed(2),
        '${ok.fold(0, (a, b) => a + (b.blinkEventsCount ?? 0))}',
        '${ok.fold(0, (a, b) => a + (b.eyeMovementEventsCount ?? 0))}',
        '${ok.fold(0, (a, b) => a + (b.emgSurgeEventsCount ?? 0))}',
        '${ok.fold(0, (a, b) => a + (b.ecgRPeaksCount ?? 0))}',
        '',
        'Medians for rates/RMS/NRMSE/corr; Totals for counts/durations',
      ];
      buf.writeln(summaryRow.map(_csvCell).join(','));
    }
    return buf.toString();
  }

  static String buildBatchCollatedJson(List<PreprocessingOutcomeEntry> entries) =>
      const JsonEncoder.withIndent('  ').convert({
        'schema': 'ccs-batch-preprocessing-outcomes-v1',
        'total_files': entries.length,
        'completed': entries
            .where((e) => e.status == 'Completed' || e.status == 'Skipped')
            .length,
        'failed': entries.where((e) => e.status == 'Failed').length,
        'files': [for (final e in entries) e.toJson()],
      });
}

Future<void> showSinglePreprocessingOutcomeDialog(
  BuildContext context,
  PreprocessingOutcomeEntry entry,
) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.fact_check, color: CcsTheme.accentBlue),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Preprocessing Outcome Log · ${entry.fileName}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 720,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  _OutcomeKpiCard(
                    label: 'SIGNAL LOST',
                    value: '${entry.signalLostPct.toStringAsFixed(1)}%',
                    sub:
                        '${entry.durationLostSec.toStringAsFixed(2)}s lost · ASR mod ${entry.asrModifiedPct.toStringAsFixed(1)}%',
                    color: entry.signalLostPct > 10
                        ? CcsTheme.accentAmber
                        : CcsTheme.accentGreen,
                  ),
                  const SizedBox(width: 8),
                  _OutcomeKpiCard(
                    label: 'CHANNELS INTERPOLATED',
                    value: '${entry.interpolatedChannels.length}',
                    sub:
                        'Bad ${entry.badChannels.length} · Skipped ${entry.skippedInterpolationChannels.length}',
                    color: CcsTheme.accentBlue,
                  ),
                  const SizedBox(width: 8),
                  _OutcomeKpiCard(
                    label: 'SIGNAL CHANGE',
                    value: entry.signalChangeNrmsePct != null
                        ? '${entry.signalChangeNrmsePct!.toStringAsFixed(1)}%'
                        : '${entry.rmsChangePct >= 0 ? '+' : ''}${entry.rmsChangePct.toStringAsFixed(1)}%',
                    sub: entry.signalCorrelationMedian != null
                        ? 'Median r=${entry.signalCorrelationMedian!.toStringAsFixed(3)} · RMS Δ ${entry.rmsChangePct.toStringAsFixed(1)}%'
                        : 'RMS change (epoch/rate changed)',
                    color: CcsTheme.accentPurple,
                  ),
                  const SizedBox(width: 8),
                  _OutcomeKpiCard(
                    label: 'NEW SIGNAL RANGE',
                    value:
                        '${entry.outputP01Uv.toStringAsFixed(1)}..${entry.outputP99Uv.toStringAsFixed(1)} µV',
                    sub:
                        'Min/Max [${entry.outputRangeMinUv.toStringAsFixed(1)}, ${entry.outputRangeMaxUv.toStringAsFixed(1)}] µV',
                    color: CcsTheme.accentCyan,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _detailRow('Input file', entry.inputPath),
              _detailRow('Output file', entry.outputPath),
              _detailRow(
                'Channels',
                '${entry.inputChannelsTotal} total → ${entry.inputEegChannels} EEG → ${entry.outputChannels} output'
                    '${entry.nonEegRemoved.isNotEmpty ? ' (dropped non-EEG: ${entry.nonEegRemoved.join(', ')})' : ''}',
              ),
              _detailRow(
                'Sample rate & duration',
                '${entry.inputSampleRateHz.toStringAsFixed(1)} → ${entry.outputSampleRateHz.toStringAsFixed(1)} Hz · '
                    '${entry.inputDurationSec.toStringAsFixed(2)} → ${entry.outputDurationSec.toStringAsFixed(2)} s'
                    '${entry.epochsDropped > 0 ? ' (${entry.epochsDropped} edge epochs dropped)' : ''}',
              ),
              _detailRow(
                'Bad channels detected',
                entry.badChannels.isEmpty
                    ? 'None'
                    : entry.badChannels.join(', '),
              ),
              _detailRow(
                'Interpolated channels',
                entry.interpolatedChannels.isEmpty
                    ? 'None'
                    : entry.interpolatedChannels.join(', '),
              ),
              if (entry.skippedInterpolationChannels.isNotEmpty)
                _detailRow(
                  'Skipped interpolation',
                  entry.skippedInterpolationChannels.join(', '),
                ),
              _detailRow(
                'Input vs Output RMS',
                '${entry.inputRmsUv.toStringAsFixed(2)} µV → ${entry.outputRmsUv.toStringAsFixed(2)} µV (${entry.rmsChangePct >= 0 ? '+' : ''}${entry.rmsChangePct.toStringAsFixed(1)}%)',
              ),
              _detailRow(
                'Input amplitude range',
                'Min/Max [${entry.inputRangeMinUv.toStringAsFixed(1)}, ${entry.inputRangeMaxUv.toStringAsFixed(1)}] µV · P1..P99 [${entry.inputP01Uv.toStringAsFixed(1)}, ${entry.inputP99Uv.toStringAsFixed(1)}] µV',
              ),
              _detailRow(
                'New amplitude range',
                'Min/Max [${entry.outputRangeMinUv.toStringAsFixed(1)}, ${entry.outputRangeMaxUv.toStringAsFixed(1)}] µV · P1..P99 [${entry.outputP01Uv.toStringAsFixed(1)}, ${entry.outputP99Uv.toStringAsFixed(1)}] µV',
              ),
              if (entry.icaTotalComponents > 0)
                _detailRow(
                  'ICA components removed',
                  '${entry.icaBlinkRemoved + entry.icaOtherRemoved} of ${entry.icaTotalComponents} (blink/ECG ${entry.icaBlinkRemoved}, other ${entry.icaOtherRemoved})',
                ),
              if (entry.gedaiReference != null)
                _detailRow(
                  'GEDAI reference',
                  '${entry.gedaiReference}${entry.gedaiAlphaRetentionPct != null ? ' · median alpha retention ${entry.gedaiAlphaRetentionPct!.toStringAsFixed(1)}%' : ''}',
                ),
              if (entry.blinkEventsCount != null ||
                  entry.ecgRPeaksCount != null ||
                  entry.emgSurgeEventsCount != null)
                _detailRow(
                  'Physiological events',
                  'Blinks ${entry.blinkEventsCount ?? 0} · Eye moves ${entry.eyeMovementEventsCount ?? 0} · EMG surges ${entry.emgSurgeEventsCount ?? 0} · ECG R-peaks ${entry.ecgRPeaksCount ?? 0}',
                ),
              if (entry.stepsApplied.isNotEmpty)
                _detailRow('Steps applied', entry.stepsApplied.join(' → ')),
              if (entry.warnings.isNotEmpty) ...[
                const Divider(),
                const Text(
                  'Warnings',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: CcsTheme.accentAmber,
                  ),
                ),
                const SizedBox(height: 4),
                for (final w in entry.warnings)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: SelectableText(
                      '⚠ $w',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () {
            Clipboard.setData(
              ClipboardData(
                text: PreprocessingOutcomeEntry.buildBatchCollatedCsv([entry]),
              ),
            );
          },
          icon: const Icon(Icons.copy, size: 15),
          label: const Text('Copy CSV'),
        ),
        OutlinedButton.icon(
          onPressed: () async {
            final path = await FilePicker.saveFile(
              dialogTitle: 'Export Preprocessing Outcome Log CSV',
              fileName: '${entry.fileName}_preprocessing_outcomes.csv',
              allowedExtensions: ['csv'],
              type: FileType.custom,
            );
            if (path != null) {
              await File(path).writeAsString(
                PreprocessingOutcomeEntry.buildBatchCollatedCsv([entry]),
              );
            }
          },
          icon: const Icon(Icons.download, size: 15),
          label: const Text('Export CSV…'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

Future<void> showBatchPreprocessingOutcomeDialog(
  BuildContext context,
  List<PreprocessingOutcomeEntry> entries, {
  String? savedCsvPath,
}) async {
  final ready = entries.where((e) => e.outputPath.isNotEmpty).toList();
  double medianOf(Iterable<double> xs) {
    final s = xs.toList()..sort();
    return s.isEmpty ? 0.0 : s[s.length ~/ 2];
  }

  final nrmses = ready
      .map((e) => e.signalChangeNrmsePct)
      .whereType<double>()
      .toList();

  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.table_view, color: CcsTheme.accentPurple),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Collated Batch Preprocessing Outcomes (${ready.length}/${entries.length} files)',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 980,
        height: 540,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _OutcomeKpiCard(
                  label: 'FILES READY',
                  value: '${ready.length} / ${entries.length}',
                  sub:
                      'Failed: ${entries.where((e) => e.status == 'Failed').length}',
                  color: CcsTheme.accentGreen,
                ),
                const SizedBox(width: 8),
                _OutcomeKpiCard(
                  label: 'MEDIAN SIGNAL LOST',
                  value:
                      '${medianOf(ready.map((e) => e.signalLostPct)).toStringAsFixed(1)}%',
                  sub:
                      'Total dropped: ${ready.fold(0.0, (a, b) => a + b.durationLostSec).toStringAsFixed(1)}s',
                  color: CcsTheme.accentAmber,
                ),
                const SizedBox(width: 8),
                _OutcomeKpiCard(
                  label: 'TOTAL INTERPOLATED CH',
                  value:
                      '${ready.fold(0, (a, b) => a + b.interpolatedChannels.length)}',
                  sub:
                      'Bad ${ready.fold(0, (a, b) => a + b.badChannels.length)} · Skipped ${ready.fold(0, (a, b) => a + b.skippedInterpolationChannels.length)}',
                  color: CcsTheme.accentBlue,
                ),
                const SizedBox(width: 8),
                _OutcomeKpiCard(
                  label: 'MEDIAN SIGNAL CHANGE',
                  value: nrmses.isNotEmpty
                      ? '${medianOf(nrmses).toStringAsFixed(1)}% NRMSE'
                      : '${medianOf(ready.map((e) => e.rmsChangePct)).toStringAsFixed(1)}% RMS Δ',
                  sub:
                      'Median RMS ${medianOf(ready.map((e) => e.inputRmsUv)).toStringAsFixed(1)}→${medianOf(ready.map((e) => e.outputRmsUv)).toStringAsFixed(1)} µV',
                  color: CcsTheme.accentPurple,
                ),
              ],
            ),
            if (savedCsvPath != null) ...[
              const SizedBox(height: 8),
              SelectableText(
                'Collated CSV saved: $savedCsvPath',
                style: const TextStyle(
                  fontSize: 11.5,
                  color: CcsTheme.textSecondary,
                ),
              ),
            ],
            const SizedBox(height: 10),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: CcsTheme.border),
                ),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SingleChildScrollView(
                    child: DataTable(
                      headingRowHeight: 36,
                      dataRowMinHeight: 34,
                      dataRowMaxHeight: 48,
                      columns: const [
                        DataColumn(label: Text('File')),
                        DataColumn(label: Text('Status')),
                        DataColumn(label: Text('Ch (In→Out)')),
                        DataColumn(label: Text('Signal Lost')),
                        DataColumn(label: Text('ASR Mod')),
                        DataColumn(label: Text('Bad Ch')),
                        DataColumn(label: Text('Interpolated')),
                        DataColumn(label: Text('Skipped')),
                        DataColumn(label: Text('Signal Change')),
                        DataColumn(label: Text('RMS In→Out (µV)')),
                        DataColumn(label: Text('New Range (µV)')),
                        DataColumn(label: Text('New P1..P99 (µV)')),
                      ],
                      rows: [
                        for (final e in entries)
                          DataRow(
                            cells: [
                              DataCell(
                                SizedBox(
                                  width: 170,
                                  child: Text(
                                    e.fileName,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                              DataCell(
                                Text(
                                  e.status,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    color: e.status == 'Failed'
                                        ? CcsTheme.accentRed
                                        : CcsTheme.accentGreen,
                                  ),
                                ),
                              ),
                              DataCell(
                                Text(
                                  '${e.inputChannelsTotal}→${e.outputChannels}',
                                ),
                              ),
                              DataCell(
                                Text(
                                  '${e.signalLostPct.toStringAsFixed(1)}% (${e.durationLostSec.toStringAsFixed(1)}s)',
                                ),
                              ),
                              DataCell(
                                Text('${e.asrModifiedPct.toStringAsFixed(1)}%'),
                              ),
                              DataCell(
                                Text(
                                  e.badChannels.isEmpty
                                      ? '0'
                                      : '${e.badChannels.length} (${e.badChannels.join(',')})',
                                ),
                              ),
                              DataCell(
                                Text(
                                  e.interpolatedChannels.isEmpty
                                      ? '0'
                                      : '${e.interpolatedChannels.length} (${e.interpolatedChannels.join(',')})',
                                ),
                              ),
                              DataCell(
                                Text(
                                  e.skippedInterpolationChannels.isEmpty
                                      ? '0'
                                      : e.skippedInterpolationChannels.join(','),
                                ),
                              ),
                              DataCell(
                                Text(
                                  e.signalChangeNrmsePct != null
                                      ? '${e.signalChangeNrmsePct!.toStringAsFixed(1)}% · r=${e.signalCorrelationMedian?.toStringAsFixed(2) ?? '-'}'
                                      : '${e.rmsChangePct >= 0 ? '+' : ''}${e.rmsChangePct.toStringAsFixed(1)}% RMS',
                                ),
                              ),
                              DataCell(
                                Text(
                                  '${e.inputRmsUv.toStringAsFixed(1)}→${e.outputRmsUv.toStringAsFixed(1)}',
                                ),
                              ),
                              DataCell(
                                Text(
                                  '[${e.outputRangeMinUv.toStringAsFixed(1)}, ${e.outputRangeMaxUv.toStringAsFixed(1)}]',
                                ),
                              ),
                              DataCell(
                                Text(
                                  '${e.outputP01Uv.toStringAsFixed(1)}..${e.outputP99Uv.toStringAsFixed(1)}',
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        OutlinedButton.icon(
          onPressed: () async {
            final out = await FilePicker.saveFile(
              dialogTitle: 'Export Collated Batch Outcomes CSV',
              fileName: 'Batch_Preprocessing_Outcomes.csv',
              allowedExtensions: ['csv'],
              type: FileType.custom,
            );
            if (out != null) {
              await File(out).writeAsString(
                PreprocessingOutcomeEntry.buildBatchCollatedCsv(entries),
              );
            }
          },
          icon: const Icon(Icons.download, size: 15),
          label: const Text('Export Collated CSV…'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

Widget _detailRow(String label, String value) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 3),
  child: Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: 175,
        child: Text(
          label,
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 12,
            color: CcsTheme.textSecondary,
          ),
        ),
      ),
      Expanded(
        child: SelectableText(
          value,
          style: const TextStyle(fontSize: 12, color: CcsTheme.text),
        ),
      ),
    ],
  ),
);

class _OutcomeKpiCard extends StatelessWidget {
  const _OutcomeKpiCard({
    required this.label,
    required this.value,
    required this.sub,
    required this.color,
  });

  final String label;
  final String value;
  final String sub;
  final Color color;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: CcsTheme.panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            value,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: CcsTheme.text,
            ),
          ),
          Text(
            sub,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 10, color: CcsTheme.textMuted),
          ),
        ],
      ),
    ),
  );
}
