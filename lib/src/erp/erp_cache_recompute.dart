import 'dart:math' as math;

import 'erp_component_spec.dart';

/// Cached per-file ERP waveforms keyed by input files + event extraction signature
/// so Grand Average Localizer, epoch view cropping, baseline changes, grouping,
/// and multi-component definitions recompute in milliseconds without disk I/O.
class ErpWaveformCache {
  const ErpWaveformCache({
    required this.cacheKey,
    required this.files,
    required this.cachedAt,
    this.epochStartMs,
    this.epochEndMs,
    this.baselineStartMs,
    this.baselineEndMs,
  });

  final String cacheKey;
  final List<Map<String, dynamic>> files;
  final DateTime cachedAt;
  final double? epochStartMs;
  final double? epochEndMs;
  final double? baselineStartMs;
  final double? baselineEndMs;

  bool matches(String key) => cacheKey == key && files.isNotEmpty;
}

class ErpCacheRecompute {
  static List<double> _toDoubles(dynamic raw) {
    if (raw is! List) return const [];
    return [
      for (final v in raw)
        if (v is num) v.toDouble() else double.tryParse('$v') ?? 0.0,
    ];
  }

  /// Subtracts the mean amplitude within `[baseStartMs, baseEndMs]` from [wave].
  static List<double> rebaselineWave(
    List<double> wave,
    List<double> timesMs,
    double baseStartMs,
    double baseEndMs,
  ) {
    if (wave.isEmpty || wave.length != timesMs.length) {
      return List<double>.from(wave);
    }
    final lo = math.min(baseStartMs, baseEndMs);
    final hi = math.max(baseStartMs, baseEndMs);
    var sum = 0.0;
    var count = 0;
    for (var i = 0; i < timesMs.length; i++) {
      final t = timesMs[i];
      if (t >= lo - 1e-6 && t <= hi + 1e-6) {
        sum += wave[i];
        count++;
      }
    }
    if (count == 0) return List<double>.from(wave);
    final base = sum / count;
    return [for (final v in wave) v - base];
  }

  /// Measures mean amplitude, signed/pos/neg AUCs (uV*s), and peak amp/latency
  /// inside `[winStartMs, winEndMs]` for waveform [wave] sampled at [timesMs].
  static Map<String, dynamic> measureWave(
    List<double> wave,
    List<double> timesMs,
    double winStartMs,
    double winEndMs,
    double polarity,
  ) {
    final lo = math.min(winStartMs, winEndMs);
    final hi = math.max(winStartMs, winEndMs);
    final idx = <int>[];
    for (var i = 0; i < timesMs.length && i < wave.length; i++) {
      if (timesMs[i] >= lo - 1e-6 && timesMs[i] <= hi + 1e-6) {
        idx.add(i);
      }
    }
    if (idx.isEmpty) {
      return {
        'mean': 0.0,
        'signed_auc': 0.0,
        'positive_auc': 0.0,
        'negative_auc': 0.0,
        'peak_amplitude': 0.0,
        'peak_latency': lo / 1000.0,
      };
    }

    var sum = 0.0;
    var signedAuc = 0.0;
    var posAuc = 0.0;
    var negAuc = 0.0;
    var peakAmp = wave[idx.first];
    var peakLatMs = timesMs[idx.first];

    for (var k = 0; k < idx.length; k++) {
      final i = idx[k];
      final v = wave[i];
      final tMs = timesMs[i];
      sum += v;
      if (polarity < 0 ? (v < peakAmp) : (v > peakAmp)) {
        peakAmp = v;
        peakLatMs = tMs;
      }
      if (k > 0) {
        final prevI = idx[k - 1];
        final dtS = (timesMs[i] - timesMs[prevI]) / 1000.0;
        final v0 = wave[prevI];
        final trap = 0.5 * (v0 + v) * dtS;
        signedAuc += trap;
        if (v0 >= 0 && v >= 0) {
          posAuc += trap;
        } else if (v0 <= 0 && v <= 0) {
          negAuc += trap.abs();
        } else {
          final fracPos = (v0 >= 0 ? v0 : v) / ((v0 - v).abs().clamp(1e-12, double.infinity));
          final posT = dtS * fracPos;
          final negT = dtS - posT;
          posAuc += 0.5 * (v0 >= 0 ? v0 : v) * posT;
          negAuc += 0.5 * (v0 < 0 ? -v0 : -v) * negT;
        }
      }
    }

    return {
      'mean': sum / idx.length,
      'signed_auc': signedAuc,
      'positive_auc': posAuc,
      'negative_auc': negAuc,
      'peak_amplitude': peakAmp,
      'peak_latency': peakLatMs / 1000.0,
    };
  }

  /// Recomputes full per-file component measurements and participant-weighted
  /// Grand Average result maps in memory from [cachedFiles].
  static Map<String, dynamic> recomputeErpResultsFromCache({
    required List<Map<String, dynamic>> cachedFiles,
    required String task,
    required List<ErpComponentSpec> components,
    required Map<String, String> participantGroups,
    required Set<String> excludedFiles,
    double? viewEpochStartMs,
    double? viewEpochEndMs,
    double? baselineStartMs,
    double? baselineEndMs,
  }) {
    final activeComps = components.isNotEmpty
        ? components
        : const [
            ErpComponentSpec(
              name: 'Primary',
              windowStartMs: 250,
              windowEndMs: 500,
              polarity: 1.0,
              roiChannels: ['Cz'],
            ),
          ];
    final primary = activeComps.first;

    final retainedRaw = cachedFiles.where((f) {
      final path = '${f['path'] ?? ''}';
      return path.isEmpty || !excludedFiles.contains(path);
    }).toList();

    final recomputedFiles = <Map<String, dynamic>>[];

    for (final raw in retainedRaw) {
      final f = Map<String, dynamic>.from(raw);
      final subj = '${f['subject'] ?? ''}';
      final assignedGroup = (participantGroups[subj] ?? '${f['group'] ?? ''}').trim();
      if (assignedGroup.isNotEmpty) {
        f['group'] = assignedGroup;
      }

      final fullTimesS = _toDoubles(raw['times']);
      final fullTimesMs = [for (final s in fullTimesS) s * 1000.0];
      if (fullTimesMs.isEmpty) {
        recomputedFiles.add(f);
        continue;
      }

      final keepIndices = <int>[];
      for (var i = 0; i < fullTimesMs.length; i++) {
        final t = fullTimesMs[i];
        final afterMin = viewEpochStartMs == null || t >= viewEpochStartMs - 1e-6;
        final beforeMax = viewEpochEndMs == null || t <= viewEpochEndMs + 1e-6;
        if (afterMin && beforeMax) keepIndices.add(i);
      }
      if (keepIndices.isEmpty) {
        for (var i = 0; i < fullTimesMs.length; i++) {
          keepIndices.add(i);
        }
      }
      final slicedTimesS = [for (final i in keepIndices) fullTimesS[i]];
      final slicedTimesMs = [for (final i in keepIndices) fullTimesMs[i]];
      f['times'] = slicedTimesS;

      final labels = (raw['labels'] as List? ?? []).map((e) => '$e').toList();

      List<List<double>> processChanGrid(dynamic rawGrid) {
        if (rawGrid is! List) return const [];
        final out = <List<double>>[];
        for (final row in rawGrid) {
          var wave = _toDoubles(row);
          if (baselineStartMs != null && baselineEndMs != null) {
            wave = rebaselineWave(
              wave,
              fullTimesMs,
              baselineStartMs,
              baselineEndMs,
            );
          }
          out.add([for (final i in keepIndices) i < wave.length ? wave[i] : 0.0]);
        }
        return out;
      }

      final procChannelConditions = <String, List<List<double>>>{};
      final rawCondMap = raw['channel_conditions'];
      if (rawCondMap is Map) {
        for (final entry in rawCondMap.entries) {
          procChannelConditions['${entry.key}'] = processChanGrid(entry.value);
        }
      }
      var procChanA = processChanGrid(raw['channel_a']);
      var procChanB = processChanGrid(raw['channel_b']);
      final condNames = (raw['condition_names'] as List? ?? procChannelConditions.keys.toList())
          .map((e) => '$e')
          .toList();
      if (procChanA.isEmpty && condNames.isNotEmpty && procChannelConditions.containsKey(condNames.first)) {
        procChanA = procChannelConditions[condNames.first]!;
      }
      if (procChanB.isEmpty && condNames.length >= 2 && procChannelConditions.containsKey(condNames[1])) {
        procChanB = procChannelConditions[condNames[1]]!;
      }

      final chanDiff = <List<double>>[];
      if (procChanA.isNotEmpty && procChanB.length == procChanA.length) {
        for (var c = 0; c < procChanA.length; c++) {
          final aRow = procChanA[c];
          final bRow = procChanB[c];
          chanDiff.add([
            for (var t = 0; t < aRow.length && t < bRow.length; t++) bRow[t] - aRow[t],
          ]);
        }
      }

      List<int> resolveRoiIndices(List<String> roiNames) {
        final idx = <int>[];
        final upper = roiNames.map((e) => e.trim().toUpperCase()).toSet();
        for (var i = 0; i < labels.length; i++) {
          if (upper.contains(labels[i].toUpperCase())) idx.add(i);
        }
        if (idx.isEmpty && labels.isNotEmpty) idx.add(0);
        return idx;
      }

      List<double> avgRoi(List<List<double>> grid, List<int> roiIdx) {
        if (grid.isEmpty || slicedTimesMs.isEmpty) return const [];
        return List<double>.generate(slicedTimesMs.length, (t) {
          var s = 0.0;
          var n = 0;
          for (final ch in roiIdx) {
            if (ch < grid.length && t < grid[ch].length) {
              s += grid[ch][t];
              n++;
            }
          }
          return n > 0 ? s / n : 0.0;
        });
      }

      final condCounts = (raw['condition_counts'] as List? ?? const [])
          .map((e) => (e is num) ? e.toInt() : 0)
          .toList();

      final compMeasRows = <Map<String, dynamic>>[];
      for (final comp in activeComps) {
        final roiIdx = resolveRoiIndices(comp.roiChannels);
        final roiNames = [for (final i in roiIdx) labels[i]];
        for (var k = 0; k < condNames.length; k++) {
          final cName = condNames[k];
          final grid = procChannelConditions[cName];
          if (grid == null || grid.isEmpty) continue;
          final w = avgRoi(grid, roiIdx);
          final nTrials = k < condCounts.length ? condCounts[k] : ((raw['n_a'] as num?)?.toInt() ?? 0);
          compMeasRows.add({
            'component': comp.name,
            'roi': roiNames,
            'window': [comp.windowStartMs / 1000.0, comp.windowEndMs / 1000.0],
            'polarity': comp.polarity,
            'condition': cName,
            'n_trials': nTrials,
            'measures': measureWave(
              w,
              slicedTimesMs,
              comp.windowStartMs,
              comp.windowEndMs,
              comp.polarity,
            ),
          });
        }
        if (procChanA.isNotEmpty && procChanB.isNotEmpty) {
          final wa = avgRoi(procChanA, roiIdx);
          final wb = avgRoi(procChanB, roiIdx);
          final diffW = [
            for (var t = 0; t < wa.length && t < wb.length; t++) wb[t] - wa[t],
          ];
          compMeasRows.add({
            'component': comp.name,
            'roi': roiNames,
            'window': [comp.windowStartMs / 1000.0, comp.windowEndMs / 1000.0],
            'polarity': comp.polarity,
            'condition': 'B_minus_A',
            'n_trials':
                ((raw['n_a'] as num?)?.toInt() ?? 0) +
                ((raw['n_b'] as num?)?.toInt() ?? 0),
            'measures': measureWave(
              diffW,
              slicedTimesMs,
              comp.windowStartMs,
              comp.windowEndMs,
              comp.polarity,
            ),
          });
        }
      }

      // Primary component ROI waveforms + measurements
      final primaryRoiIdx = resolveRoiIndices(primary.roiChannels);
      final roiCondWaves = <String, List<double>>{};
      final primaryMeasures = <String, dynamic>{};
      for (final cName in condNames) {
        final grid = procChannelConditions[cName];
        if (grid == null || grid.isEmpty) continue;
        final w = avgRoi(grid, primaryRoiIdx);
        roiCondWaves[cName] = w;
        primaryMeasures[cName] = measureWave(
          w,
          slicedTimesMs,
          primary.windowStartMs,
          primary.windowEndMs,
          primary.polarity,
        );
      }
      final roiA = avgRoi(procChanA, primaryRoiIdx);
      final roiB = avgRoi(procChanB, primaryRoiIdx);
      final roiDiff = [
        for (var t = 0; t < roiA.length && t < roiB.length; t++) roiB[t] - roiA[t],
      ];
      if (roiA.isNotEmpty) {
        primaryMeasures['A'] = measureWave(
          roiA,
          slicedTimesMs,
          primary.windowStartMs,
          primary.windowEndMs,
          primary.polarity,
        );
      }
      if (roiB.isNotEmpty) {
        primaryMeasures['B'] = measureWave(
          roiB,
          slicedTimesMs,
          primary.windowStartMs,
          primary.windowEndMs,
          primary.polarity,
        );
      }
      if (roiDiff.isNotEmpty) {
        primaryMeasures['B_minus_A'] = measureWave(
          roiDiff,
          slicedTimesMs,
          primary.windowStartMs,
          primary.windowEndMs,
          primary.polarity,
        );
      }

      List<double> meanInWin(List<List<double>> grid) => [
        for (final row in grid)
          measureWave(
            row,
            slicedTimesMs,
            primary.windowStartMs,
            primary.windowEndMs,
            primary.polarity,
          )['mean'] as double,
      ];

      final existingProfile = (raw['profile'] is Map)
          ? Map<String, dynamic>.from(raw['profile'] as Map)
          : <String, dynamic>{};
      existingProfile['component_name'] = primary.name;
      existingProfile['roi'] = primary.roiChannels;
      existingProfile['window'] = [
        primary.windowStartMs / 1000.0,
        primary.windowEndMs / 1000.0,
      ];
      existingProfile['polarity'] = primary.polarity;
      existingProfile['epoch'] = [
        slicedTimesS.first,
        slicedTimesS.last,
      ];
      if (baselineStartMs != null && baselineEndMs != null) {
        existingProfile['baseline'] = [
          baselineStartMs / 1000.0,
          baselineEndMs / 1000.0,
        ];
      }
      existingProfile['components'] = [
        for (final c in activeComps) c.toRustJson(),
      ];

      f['profile'] = existingProfile;
      f['a'] = roiA;
      f['b'] = roiB;
      f['difference'] = roiDiff;
      f['condition_waves'] = roiCondWaves;
      f['channel_a'] = procChanA;
      f['channel_b'] = procChanB;
      f['channel_difference'] = chanDiff;
      f['channel_conditions'] = procChannelConditions;
      f['topo_a'] = meanInWin(procChanA);
      f['topo_b'] = meanInWin(procChanB);
      f['topo_difference'] = meanInWin(chanDiff);
      f['measurements'] = primaryMeasures;
      f['component_specs'] = [for (final c in activeComps) c.toRustJson()];
      f['component_measurements'] = compMeasRows;

      recomputedFiles.add(f);
    }

    final groupSummary = _buildParticipantGrandAverage(
      files: recomputedFiles,
      task: task,
      primary: primary,
      components: activeComps,
    );

    return {
      'schema': 'ccs-erp-workbench-v1',
      'files': recomputedFiles,
      'groups': [groupSummary],
      'failures': const <dynamic>[],
      'recomputed_from_cache': true,
    };
  }

  static Map<String, dynamic> _buildParticipantGrandAverage({
    required List<Map<String, dynamic>> files,
    required String task,
    required ErpComponentSpec primary,
    required List<ErpComponentSpec> components,
  }) {
    if (files.isEmpty) {
      return {
        'task': task,
        'n_subjects': 0,
        'n_files': 0,
        'times': const <double>[],
        'labels': const <String>[],
        'condition_names': const <String>[],
        'statistics': const <dynamic>[],
      };
    }

    final first = files.first;
    final times = _toDoubles(first['times']);
    final labels = (first['labels'] as List? ?? []).map((e) => '$e').toList();
    final condNames = (first['condition_names'] as List? ?? const [])
        .map((e) => '$e')
        .toList();
    final nT = times.length;
    final nCh = labels.length;

    // Group files by subject so each participant has equal weight.
    final bySubject = <String, List<Map<String, dynamic>>>{};
    for (final f in files) {
      final subj = '${f['subject'] ?? f['path'] ?? ''}'.trim();
      bySubject.putIfAbsent(subj, () => []).add(f);
    }

    List<double> meanWaves(List<List<double>> ws, int len) {
      if (ws.isEmpty || len == 0) return List<double>.filled(len, 0.0);
      final out = List<double>.filled(len, 0.0);
      for (final w in ws) {
        for (var i = 0; i < len && i < w.length; i++) {
          out[i] += w[i] / ws.length;
        }
      }
      return out;
    }

    List<double> semWaves(List<List<double>> ws, List<double> m) {
      if (ws.length < 2 || m.isEmpty) return List<double>.filled(m.length, 0.0);
      return List<double>.generate(m.length, (i) {
        var sq = 0.0;
        for (final w in ws) {
          final d = (i < w.length ? w[i] : m[i]) - m[i];
          sq += d * d;
        }
        return math.sqrt((sq / (ws.length - 1)) / ws.length);
      });
    }

    final subjA = <List<double>>[];
    final subjB = <List<double>>[];
    final subjDiff = <List<double>>[];
    final subjCond = {for (final c in condNames) c: <List<double>>[]};

    for (final sFiles in bySubject.values) {
      subjA.add(meanWaves([for (final f in sFiles) _toDoubles(f['a'])], nT));
      subjB.add(meanWaves([for (final f in sFiles) _toDoubles(f['b'])], nT));
      subjDiff.add(
        meanWaves([for (final f in sFiles) _toDoubles(f['difference'])], nT),
      );
      for (final c in condNames) {
        final ws = <List<double>>[];
        for (final f in sFiles) {
          final cw = f['condition_waves'] as Map?;
          if (cw != null && cw[c] != null) {
            ws.add(_toDoubles(cw[c]));
          }
        }
        if (ws.isNotEmpty) subjCond[c]!.add(meanWaves(ws, nT));
      }
    }

    final gaA = meanWaves(subjA, nT);
    final gaB = meanWaves(subjB, nT);
    final gaDiff = meanWaves(subjDiff, nT);
    final semDiff = semWaves(subjDiff, gaDiff);
    final grandCondWaves = <String, List<double>>{};
    final grandCondSems = <String, List<double>>{};
    for (final c in condNames) {
      final m = meanWaves(subjCond[c]!, nT);
      grandCondWaves[c] = m;
      grandCondSems[c] = semWaves(subjCond[c]!, m);
    }

    final grandChannelConditions = <String, List<List<double>>>{};
    for (final c in condNames) {
      final subjGrids = <List<List<double>>>[];
      for (final sFiles in bySubject.values) {
        final grids = <List<List<double>>>[];
        for (final f in sFiles) {
          final cc = f['channel_conditions'] as Map?;
          final g = cc?[c];
          if (g is List && g.length == nCh) {
            grids.add([for (final chRow in g) _toDoubles(chRow)]);
          }
        }
        if (grids.isNotEmpty) {
          final sm = List.generate(nCh, (ch) {
            return List<double>.generate(nT, (t) {
              var s = 0.0;
              for (final g in grids) {
                if (t < g[ch].length) s += g[ch][t];
              }
              return s / grids.length;
            });
          });
          subjGrids.add(sm);
        }
      }
      if (subjGrids.isNotEmpty) {
        grandChannelConditions[c] = List.generate(nCh, (ch) {
          return List<double>.generate(nT, (t) {
            var s = 0.0;
            for (final g in subjGrids) {
              s += g[ch][t];
            }
            return s / subjGrids.length;
          });
        });
      }
    }

    List<double> meanTopo(String key) {
      final subjTopos = <List<double>>[];
      for (final sFiles in bySubject.values) {
        final ts = [for (final f in sFiles) _toDoubles(f[key])];
        if (ts.isNotEmpty) subjTopos.add(meanWaves(ts, nCh));
      }
      return meanWaves(subjTopos, nCh);
    }

    return {
      'task': task,
      'component_name': primary.name,
      'profile': files.first['profile'],
      'components': [for (final c in components) c.toRustJson()],
      'subjects': bySubject.keys.toList(),
      'n_subjects': bySubject.length,
      'n_files': files.length,
      'times': times,
      'labels': labels,
      'a': gaA,
      'b': gaB,
      'difference': gaDiff,
      'sem_difference': semDiff,
      'condition_names': condNames,
      'condition_waves': grandCondWaves,
      'condition_sems': grandCondSems,
      'channel_conditions': grandChannelConditions,
      'topo_a': meanTopo('topo_a'),
      'topo_b': meanTopo('topo_b'),
      'topo_difference': meanTopo('topo_difference'),
      'statistics': const <dynamic>[],
    };
  }
}
