import 'dart:typed_data';

import 'package:ccs_eeg_app/src/models.dart';
import 'package:ccs_eeg_app/src/preprocessing_outcome_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('PreprocessingOutcomeEntry parses summary outcomes and collates CSV', () {
    final rec = EegRecording(
      path: '/tmp/sub-01_clean.edf',
      sampleRate: 250,
      labels: const ['Fp1', 'Fp2', 'Cz'],
      preview: [Float32List(500), Float32List(500), Float32List(500)],
      sampleCount: 500,
      format: 'edf',
      provenance: {
        'source_path': '/tmp/sub-01.edf',
        'physio_events_summary': {
          'blink_count': 12,
          'eye_movement_count': 4,
          'emg_surge_count': 3,
          'ecg_r_peak_count': 65,
        },
        'summary': {
          'bad_channels': ['T8', 'Tp10'],
          'interpolated_channels': ['T8'],
          'skipped_interpolation_channels': ['Tp10'],
          'gedai_reference': 'leadfield',
          'warnings': ['Skipped interpolation for Tp10'],
          'outcomes': {
            'input_channels_total': 4,
            'non_eeg_channels_removed': ['ECG'],
            'input_eeg_channels': 3,
            'output_channels': 3,
            'input_sample_rate_hz': 500.0,
            'output_sample_rate_hz': 250.0,
            'input_duration_sec': 120.0,
            'output_duration_sec': 114.0,
            'duration_lost_sec': 6.0,
            'signal_lost_pct': 5.0,
            'asr_samples_modified': 300,
            'asr_samples_total': 3000,
            'asr_modified_pct': 10.0,
            'epochs_dropped': 1,
            'ica_blink_components_removed': 2,
            'ica_other_components_removed': 1,
            'ica_total_components': 18,
            'gedai_alpha_retention_pct': 92.4,
            'input_rms_uv': 45.0,
            'output_rms_uv': 18.0,
            'rms_change_pct': -60.0,
            'input_range_min_uv': -320.0,
            'input_range_max_uv': 410.0,
            'input_p01_uv': -95.0,
            'input_p99_uv': 102.0,
            'output_range_min_uv': -75.0,
            'output_range_max_uv': 82.0,
            'output_p01_uv': -38.0,
            'output_p99_uv': 41.0,
            'signal_change_nrmse_pct': 24.5,
            'signal_correlation_median': 0.912,
            'steps_applied': ['Resample (250 Hz)', 'Filter', 'Spline interpolation'],
          },
        },
      },
    );

    final entry = PreprocessingOutcomeEntry.fromRecording(rec);
    expect(entry.signalLostPct, 5.0);
    expect(entry.interpolatedChannels, ['T8']);
    expect(entry.skippedInterpolationChannels, ['Tp10']);
    expect(entry.signalChangeNrmsePct, 24.5);
    expect(entry.ecgRPeaksCount, 65);
    expect(entry.toLogLines().first, contains('Signal lost: 5.0%'));
    expect(entry.toLogLines().first, contains('New range: [-75.0, 82.0] µV'));

    final csv = PreprocessingOutcomeEntry.buildBatchCollatedCsv([
      entry,
      PreprocessingOutcomeEntry.fromError('/tmp/sub-02.edf', 'Corrupt EDF'),
    ]);
    final lines = csv.trim().split('\n');
    expect(lines.length, 4);
    expect(lines[0], startsWith('file_name,status,'));
    expect(lines[1], contains('sub-01.edf'));
    expect(lines[2], contains('Failed'));
    expect(lines[3], startsWith('BATCH SUMMARY (1/2 ready)'));
  });
}
