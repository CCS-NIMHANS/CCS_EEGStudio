import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/erp/erp_cache_recompute.dart';
import 'package:ccs_eeg_app/src/erp/erp_component_spec.dart';

void main() {
  test('recomputeErpResultsFromCache computes multi-component metrics, exclusions, and view cropping', () {
    // 11 time points from -200ms to +800ms (step 100ms)
    final timesS = [for (var ms = -200; ms <= 800; ms += 100) ms / 1000.0];
    final labels = ['Fz', 'Cz', 'Pz'];

    List<List<double>> makeGrid(double offset, double n1, double p3) {
      return [
        // Fz
        [for (var ms = -200; ms <= 800; ms += 100) offset + (ms == 100 ? n1 : 0.0)],
        // Cz
        [for (var ms = -200; ms <= 800; ms += 100) offset + (ms == 100 ? n1 : 0.0)],
        // Pz
        [for (var ms = -200; ms <= 800; ms += 100) offset + (ms >= 300 && ms <= 500 ? p3 : 0.0)],
      ];
    }

    final cachedFiles = [
      {
        'path': '/tmp/SKYMED013SESSION03.edf',
        'subject': 'SKYMED013',
        'group': 'ADV',
        'labels': labels,
        'times': timesS,
        'condition_names': ['Freq', 'Rare'],
        'condition_counts': [20, 10],
        'n_a': 20,
        'n_b': 10,
        'channel_conditions': {
          'Freq': makeGrid(2.0, -1.0, 1.0), // +2 uV DC offset removed by rebaseline!
          'Rare': makeGrid(2.0, -5.0, 7.0),
        },
      },
      {
        'path': '/tmp/SKYMED046SESSION03.edf',
        'subject': 'SKYMED046',
        'group': 'Unknown',
        'labels': labels,
        'times': timesS,
        'condition_names': ['Freq', 'Rare'],
        'condition_counts': [20, 10],
        'n_a': 20,
        'n_b': 10,
        'channel_conditions': {
          'Freq': makeGrid(0.0, 99.0, 99.0),
          'Rare': makeGrid(0.0, 99.0, 99.0),
        },
      },
    ];

    final components = [
      const ErpComponentSpec(
        name: 'N100',
        windowStartMs: 100,
        windowEndMs: 100,
        polarity: -1.0,
        roiChannels: ['Fz', 'Cz'],
      ),
      const ErpComponentSpec(
        name: 'P300',
        windowStartMs: 300,
        windowEndMs: 500,
        polarity: 1.0,
        roiChannels: ['Pz'],
      ),
    ];

    final result = ErpCacheRecompute.recomputeErpResultsFromCache(
      cachedFiles: cachedFiles,
      task: 'Custom',
      components: components,
      participantGroups: {'SKYMED013': 'ADV'},
      excludedFiles: {'/tmp/SKYMED046SESSION03.edf'},
      viewEpochStartMs: -100,
      viewEpochEndMs: 600,
      baselineStartMs: -200,
      baselineEndMs: 0,
    );

    final files = result['files'] as List<Map<String, dynamic>>;
    expect(files.length, 1);
    final f = files.first;
    final slicedTimes = (f['times'] as List).cast<double>();
    expect(slicedTimes.first, closeTo(-0.1, 1e-9));
    expect(slicedTimes.last, closeTo(0.6, 1e-9));

    final compMeas = (f['component_measurements'] as List).cast<Map<String, dynamic>>();
    final n1Rare = compMeas.firstWhere(
      (m) => m['component'] == 'N100' && m['condition'] == 'Rare',
    );
    expect((n1Rare['measures']['mean'] as double), closeTo(-5.0, 1e-6));

    final p3Rare = compMeas.firstWhere(
      (m) => m['component'] == 'P300' && m['condition'] == 'Rare',
    );
    expect((p3Rare['measures']['mean'] as double), closeTo(7.0, 1e-6));
  });
}
