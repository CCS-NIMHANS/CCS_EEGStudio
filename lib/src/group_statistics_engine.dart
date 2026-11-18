import 'dart:io';
import 'dart:math' as math;

import 'erp/factor_grouping_designer.dart';

/// Pure-Dart statistical distributions and multiple-testing helpers.
class StatMath {
  static const double epsilon = 1e-14;
  static const double tiny = 1e-30;

  static double logGamma(double x) {
    const p = [
      0.99999999999980993,
      676.52093408287859,
      -1259.1392167224028,
      771.32342877765313,
      -176.61502916214059,
      12.507343278686905,
      -0.13857109583115912,
      9.9843695780195716e-6,
      1.5056327351493116e-7,
    ];
    if (x < 0.5) {
      return math.log(math.pi / math.sin(math.pi * x)) - logGamma(1.0 - x);
    }
    x -= 1.0;
    var a = p[0];
    final t = x + 7.5;
    for (var i = 1; i < p.length; i++) {
      a += p[i] / (x + i);
    }
    return 0.5 * math.log(2.0 * math.pi) +
        (x + 0.5) * math.log(t) -
        t +
        math.log(a);
  }

  static double _betacf(double a, double b, double x) {
    const maxIterations = 200;
    final qab = a + b;
    final qap = a + 1.0;
    final qam = a - 1.0;
    var c = 1.0;
    var d = 1.0 - qab * x / qap;
    if (d.abs() < tiny) d = tiny;
    d = 1.0 / d;
    var h = d;

    for (var m = 1; m <= maxIterations; m++) {
      final m2 = 2 * m;
      var aa = m * (b - m) * x / ((qam + m2) * (a + m2));
      d = 1.0 + aa * d;
      if (d.abs() < tiny) d = tiny;
      c = 1.0 + aa / c;
      if (c.abs() < tiny) c = tiny;
      d = 1.0 / d;
      h *= d * c;

      aa = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2));
      d = 1.0 + aa * d;
      if (d.abs() < tiny) d = tiny;
      c = 1.0 + aa / c;
      if (c.abs() < tiny) c = tiny;
      d = 1.0 / d;
      final del = d * c;
      h *= del;
      if ((del - 1.0).abs() < epsilon) break;
    }
    return h;
  }

  static double regularizedIncompleteBeta(double a, double b, double x) {
    if (x <= 0.0) return 0.0;
    if (x >= 1.0) return 1.0;
    final bt = math.exp(
      logGamma(a + b) -
          logGamma(a) -
          logGamma(b) +
          a * math.log(x) +
          b * math.log(1.0 - x),
    );
    if (x < (a + 1.0) / (a + b + 2.0)) {
      return bt * _betacf(a, b, x) / a;
    }
    return 1.0 - bt * _betacf(b, a, 1.0 - x) / b;
  }

  static double studentTPValue(double t, double df) {
    if (df <= 0 || !t.isFinite) return 1.0;
    final x = df / (df + t * t);
    return regularizedIncompleteBeta(df / 2.0, 0.5, x).clamp(0.0, 1.0);
  }

  static double fDistributionPValue(double f, double df1, double df2) {
    if (f <= 0.0 || df1 <= 0 || df2 <= 0 || !f.isFinite) return 1.0;
    final x = df2 / (df2 + df1 * f);
    return regularizedIncompleteBeta(df2 / 2.0, df1 / 2.0, x).clamp(0.0, 1.0);
  }

  static List<double> adjustFDR(List<double> rawPValues) {
    final n = rawPValues.length;
    if (n == 0) return [];
    if (n == 1) return [rawPValues.first];
    final indices = List<int>.generate(n, (i) => i)
      ..sort((a, b) => rawPValues[a].compareTo(rawPValues[b]));
    final adjusted = List<double>.filled(n, 1.0);
    var runningMin = 1.0;
    for (var rank = n; rank >= 1; rank--) {
      final idx = indices[rank - 1];
      final adj = (rawPValues[idx] * n / rank).clamp(0.0, 1.0);
      if (adj < runningMin) runningMin = adj;
      adjusted[idx] = runningMin;
    }
    return adjusted;
  }
}

/// Pure-Dart N-way Factorial GLM & LMM engine with restricted/exchangeable
/// permutation testing (inspired by CCS_SleepStudio's GroupStatsEngine).
class ErpGroupStatsEngine {
  /// Inspects a CSV (and optional CSV/XLSX metadata sheet) and returns
  /// detected factors, levels, counts, and numeric metrics.
  static Future<Map<String, dynamic>> inspectDataset({
    required String csvPath,
    String? metadataPath,
    String? metadataKey,
  }) async {
    final parsed = await TabularSheetReader.read(csvPath);
    var headers = List<String>.from(parsed.headers);
    var rows = List<List<String>>.from(parsed.rows);

    if (metadataPath != null &&
        metadataPath.trim().isNotEmpty &&
        await File(metadataPath.trim()).exists()) {
      final meta = await TabularSheetReader.read(metadataPath.trim());
      if (meta.headers.isNotEmpty) {
        final merged = _mergeMetadata(
          headers: headers,
          rows: rows,
          metaHeaders: meta.headers,
          metaRows: meta.rows,
          explicitKey: metadataKey,
        );
        headers = merged.headers;
        rows = merged.rows;
      }
    }

    final factorCols = <String>[];
    final metricCols = <String>[];
    final factorLevels = <String, List<String>>{};
    final factorCounts = <String, Map<String, int>>{};
    String? detectedSubjectCol;

    for (var c = 0; c < headers.length; c++) {
      final h = headers[c];
      final hl = h.toLowerCase();
      if (detectedSubjectCol == null &&
          (hl == 'subjid' ||
              hl == 'subject' ||
              hl == 'participant_id' ||
              hl == 'subject_id' ||
              hl == 'id')) {
        detectedSubjectCol = h;
      }

      var numCount = 0;
      var nonEmpty = 0;
      final counts = <String, int>{};
      for (final r in rows) {
        if (c >= r.length) continue;
        final v = r[c].trim();
        if (v.isEmpty) continue;
        nonEmpty++;
        if (double.tryParse(v) != null) numCount++;
        counts[v] = (counts[v] ?? 0) + 1;
      }

      if (nonEmpty > 0 && numCount == nonEmpty && counts.length > 6) {
        if (hl != 'sl.no.' && hl != 'sno' && hl != 'index') {
          metricCols.add(h);
        }
      } else if (counts.isNotEmpty) {
        factorCols.add(h);
        final levels = counts.keys.toList()..sort();
        factorLevels[h] = levels;
        factorCounts[h] = counts;
      }
    }

    return {
      'headers': headers,
      'rows': rows,
      'row_count': rows.length,
      'factor_columns': factorCols,
      'metric_columns': metricCols,
      'factor_levels': factorLevels,
      'factor_counts': factorCounts,
      'detected_subject_col': detectedSubjectCol,
    };
  }

  static ({List<String> headers, List<List<String>> rows}) _mergeMetadata({
    required List<String> headers,
    required List<List<String>> rows,
    required List<String> metaHeaders,
    required List<List<String>> metaRows,
    String? explicitKey,
  }) {
    String? csvKey;
    String? metaKey;
    if (explicitKey != null &&
        explicitKey.trim().isNotEmpty &&
        headers.contains(explicitKey.trim()) &&
        metaHeaders.contains(explicitKey.trim())) {
      csvKey = explicitKey.trim();
      metaKey = explicitKey.trim();
    } else {
      const candidates = [
        'subjid',
        'subject',
        'participant_id',
        'subject_id',
        'id',
        'filename',
      ];
      for (final cand in candidates) {
        csvKey ??= headers
            .where((h) => h.toLowerCase() == cand)
            .firstOrNull;
        metaKey ??= metaHeaders
            .where((h) => h.toLowerCase() == cand)
            .firstOrNull;
      }
      csvKey ??= headers.firstOrNull;
      metaKey ??= metaHeaders.firstOrNull;
    }
    if (csvKey == null || metaKey == null) {
      return (headers: headers, rows: rows);
    }

    final csvKeyIdx = headers.indexOf(csvKey);
    final metaKeyIdx = metaHeaders.indexOf(metaKey);
    final newCols = metaHeaders
        .where((h) => h != metaKey && !headers.contains(h))
        .toList();
    if (newCols.isEmpty) return (headers: headers, rows: rows);

    final lookup = <String, List<String>>{};
    for (final mr in metaRows) {
      if (metaKeyIdx >= mr.length) continue;
      final k = mr[metaKeyIdx].trim().toLowerCase();
      if (k.isEmpty) continue;
      lookup[k] = [
        for (final col in newCols)
          metaHeaders.indexOf(col) < mr.length
              ? mr[metaHeaders.indexOf(col)].trim()
              : '',
      ];
    }

    final mergedHeaders = [...headers, ...newCols];
    final mergedRows = <List<String>>[];
    for (final r in rows) {
      final k = csvKeyIdx < r.length ? r[csvKeyIdx].trim().toLowerCase() : '';
      var hit = lookup[k];
      if (hit == null && k.isNotEmpty) {
        for (final e in lookup.entries) {
          if (e.key.length >= 3 &&
              (k.startsWith(e.key) || k.contains(e.key))) {
            hit = e.value;
            break;
          }
        }
      }
      mergedRows.add([
        ...List.generate(headers.length, (i) => i < r.length ? r[i] : ''),
        ...(hit ?? List.filled(newCols.length, 'Unknown')),
      ]);
    }
    return (headers: mergedHeaders, rows: mergedRows);
  }

  /// Runs N-way Permutation-based GLM / LMM analysis on [rows].
  static Map<String, dynamic> runAnalysis({
    required List<String> headers,
    required List<List<String>> rows,
    required List<String> factors,
    required List<String> metrics,
    String? subjectCol,
    String preferredModel = 'auto', // 'auto', 'lmm', 'glm'
    String posthocMethod = 'fdr', // 'fdr', 'bonferroni'
    bool includeInteractions = true,
    int nPermutations = 1000,
    int seed = 42,
    Map<String, Set<String>> excludedLevels = const {},
    Map<String, List<String>> customLevelOrder = const {},
  }) {
    final colIdx = {for (var i = 0; i < headers.length; i++) headers[i]: i};
    final subjIdx = subjectCol != null ? colIdx[subjectCol] : null;
    final activeFactors = factors.where(colIdx.containsKey).toList();
    if (activeFactors.isEmpty || metrics.isEmpty) {
      return {'error': 'Select at least one factor and one metric.'};
    }

    // Filter rows by excluded factor levels
    final filteredRows = rows.where((r) {
      for (final f in activeFactors) {
        final idx = colIdx[f]!;
        if (idx >= r.length) return false;
        final val = r[idx].trim();
        if (val.isEmpty) return false;
        if ((excludedLevels[f] ?? const <String>{}).contains(val)) {
          return false;
        }
      }
      return true;
    }).toList();

    if (filteredRows.isEmpty) {
      return {'error': 'No rows remain after filtering factor levels.'};
    }

    // Determine ordered levels per factor
    final factorLevels = <String, List<String>>{};
    for (final f in activeFactors) {
      final idx = colIdx[f]!;
      final raw = filteredRows.map((r) => r[idx].trim()).toSet().toList()
        ..sort();
      final custom = customLevelOrder[f];
      if (custom != null && custom.isNotEmpty) {
        factorLevels[f] = [
          for (final l in custom)
            if (raw.contains(l)) l,
          for (final l in raw)
            if (!custom.contains(l)) l,
        ];
      } else {
        factorLevels[f] = raw;
      }
    }

    final metricResults = <Map<String, dynamic>>[];
    final rng = math.Random(seed);

    for (final metric in metrics) {
      final mIdx = colIdx[metric];
      if (mIdx == null) continue;

      final obs = <_Obs>[];
      for (final r in filteredRows) {
        if (mIdx >= r.length) continue;
        final y = double.tryParse(r[mIdx].trim());
        if (y == null || !y.isFinite) continue;
        final subj = (subjIdx != null && subjIdx < r.length)
            ? r[subjIdx].trim()
            : 'obs_${obs.length}';
        final levels = {
          for (final f in activeFactors) f: r[colIdx[f]!].trim(),
        };
        obs.add(_Obs(subject: subj, y: y, levels: levels));
      }
      if (obs.length < 3) continue;

      final subjects = obs.map((o) => o.subject).toSet();
      final isRepeated = subjIdx != null &&
          subjects.length >= 2 &&
          obs.length > subjects.length;
      final useLmm = (preferredModel == 'lmm' && isRepeated) ||
          (preferredModel == 'auto' && isRepeated);

      // Identify which factors are between-subject vs within-subject
      final isBetweenFactor = <String, bool>{};
      for (final f in activeFactors) {
        if (!isRepeated) {
          isBetweenFactor[f] = true;
        } else {
          final subjLvls = <String, Set<String>>{};
          for (final o in obs) {
            subjLvls.putIfAbsent(o.subject, () => {}).add(o.levels[f]!);
          }
          isBetweenFactor[f] = subjLvls.values.every((s) => s.length <= 1);
        }
      }

      // Compute observed ANOVA/LMM effects (Type-I/II sequential cell-mean SS)
      final terms = _buildTerms(activeFactors, includeInteractions);
      final obsStats = _computeFactorialStats(
        obs: obs,
        factors: activeFactors,
        terms: terms,
        useLmm: useLmm,
        isBetweenFactor: isBetweenFactor,
      );

      // Permutation testing
      final exceedCounts = {for (final t in terms) t.label: 0};
      final effectivePerms = nPermutations.clamp(1, 5000);
      for (var p = 0; p < effectivePerms; p++) {
        final permObs = _permuteObs(
          obs: obs,
          factors: activeFactors,
          isBetweenFactor: isBetweenFactor,
          useLmm: useLmm,
          rng: rng,
        );
        final permStats = _computeFactorialStats(
          obs: permObs,
          factors: activeFactors,
          terms: terms,
          useLmm: useLmm,
          isBetweenFactor: isBetweenFactor,
        );
        for (final t in terms) {
          final fObs = obsStats[t.label]?.fStat ?? 0.0;
          final fPerm = permStats[t.label]?.fStat ?? 0.0;
          if (fPerm >= fObs - 1e-12) {
            exceedCounts[t.label] = exceedCounts[t.label]! + 1;
          }
        }
      }

      final modelEffects = <Map<String, dynamic>>[
        for (final t in terms)
          if (obsStats.containsKey(t.label))
            {
              'term': t.label,
              'f_stat': obsStats[t.label]!.fStat,
              'p_value': obsStats[t.label]!.pValue,
              'p_perm': (1.0 + exceedCounts[t.label]!) / (1.0 + effectivePerms),
              'df_num': obsStats[t.label]!.dfNum,
              'df_denom': obsStats[t.label]!.dfDenom,
              'eta_sq': obsStats[t.label]!.etaSq,
              'n_obs': obs.length,
              'n_perm': effectivePerms,
            },
      ];

      // Cell descriptives keyed by "f1=v1|f2=v2|..."
      final cellMap = <String, List<double>>{};
      for (final o in obs) {
        final key = activeFactors.map((f) => '$f=${o.levels[f]}').join('|');
        cellMap.putIfAbsent(key, () => []).add(o.y);
      }
      final cellDescriptives = <String, Map<String, dynamic>>{};
      for (final e in cellMap.entries) {
        cellDescriptives[e.key] = _descriptiveStats(e.value);
      }

      // Pairwise post-hocs per factor
      final posthocs = <Map<String, dynamic>>[];
      for (final f in activeFactors) {
        final lvls = factorLevels[f] ?? const [];
        for (var i = 0; i < lvls.length; i++) {
          for (var j = i + 1; j < lvls.length; j++) {
            final vA = obs
                .where((o) => o.levels[f] == lvls[i])
                .map((o) => o.y)
                .toList();
            final vB = obs
                .where((o) => o.levels[f] == lvls[j])
                .map((o) => o.y)
                .toList();
            if (vA.length < 2 || vB.length < 2) continue;
            final tRes = _welchT(vA, vB);
            posthocs.add({
              'factor': f,
              'group_a': lvls[i],
              'group_b': lvls[j],
              'mean_diff': tRes.meanDiff,
              't_stat': tRes.t,
              'df': tRes.df,
              'p_raw': tRes.p,
            });
          }
        }
      }
      final rawPs = posthocs.map((p) => p['p_raw'] as double).toList();
      final adjPs = posthocMethod == 'bonferroni'
          ? rawPs.map((p) => (p * rawPs.length).clamp(0.0, 1.0)).toList()
          : StatMath.adjustFDR(rawPs);
      for (var i = 0; i < posthocs.length; i++) {
        posthocs[i]['p_adj'] = adjPs[i];
        posthocs[i]['significant'] = adjPs[i] < 0.05;
      }

      metricResults.add({
        'metric': metric,
        'model_type': useLmm
            ? '${activeFactors.length}-Factor Permutation LMM (Random Subject Intercept, $effectivePerms perms)'
            : '${activeFactors.length}-Factor Permutation GLM / ANOVA ($effectivePerms perms)',
        'factors': activeFactors,
        'factor_levels': factorLevels,
        'model_effects': modelEffects,
        'posthoc': posthocs,
        'cell_descriptives': cellDescriptives,
        'n_obs': obs.length,
        'n_subjects': subjects.length,
      });
    }

    return {
      'factors': activeFactors,
      'factor_levels': factorLevels,
      'results': metricResults,
    };
  }

  static List<_Term> _buildTerms(List<String> factors, bool interactions) {
    final terms = <_Term>[
      for (final f in factors) _Term([f]),
    ];
    if (interactions && factors.length >= 2) {
      for (var i = 0; i < factors.length; i++) {
        for (var j = i + 1; j < factors.length; j++) {
          terms.add(_Term([factors[i], factors[j]]));
        }
      }
      if (factors.length == 3) {
        terms.add(_Term(List<String>.from(factors)));
      }
    }
    return terms;
  }

  static Map<String, _TermStat> _computeFactorialStats({
    required List<_Obs> obs,
    required List<String> factors,
    required List<_Term> terms,
    required bool useLmm,
    required Map<String, bool> isBetweenFactor,
  }) {
    final n = obs.length;
    if (n == 0) return {};
    final grandMean = obs.map((o) => o.y).reduce((a, b) => a + b) / n;

    // Total & full-cell residual SS
    final fullCells = <String, List<double>>{};
    for (final o in obs) {
      final k = factors.map((f) => o.levels[f]!).join('\u0000');
      fullCells.putIfAbsent(k, () => []).add(o.y);
    }
    var ssWithin = 0.0;
    for (final vals in fullCells.values) {
      final m = vals.reduce((a, b) => a + b) / vals.length;
      for (final v in vals) {
        ssWithin += (v - m) * (v - m);
      }
    }
    final dfWithin = math.max(1, n - fullCells.length).toDouble();
    final msWithin = ssWithin / dfWithin;

    // Subject random intercept error term for between-subject factors
    var msBetweenErr = msWithin;
    var dfBetweenErr = dfWithin;
    if (useLmm) {
      final betweenFactors =
          factors.where((f) => isBetweenFactor[f] == true).toList();
      final subjMeans = <String, List<double>>{};
      final subjCellKey = <String, String>{};
      for (final o in obs) {
        subjMeans.putIfAbsent(o.subject, () => []).add(o.y);
        subjCellKey[o.subject] =
            betweenFactors.map((f) => o.levels[f]!).join('\u0000');
      }
      final cellSubjMeans = <String, List<double>>{};
      for (final e in subjMeans.entries) {
        final m = e.value.reduce((a, b) => a + b) / e.value.length;
        cellSubjMeans.putIfAbsent(subjCellKey[e.key]!, () => []).add(m);
      }
      var ssSubj = 0.0;
      for (final e in subjMeans.entries) {
        final mSubj = e.value.reduce((a, b) => a + b) / e.value.length;
        final cList = cellSubjMeans[subjCellKey[e.key]!]!;
        final cMean = cList.reduce((a, b) => a + b) / cList.length;
        ssSubj += e.value.length * (mSubj - cMean) * (mSubj - cMean);
      }
      final dfS = math.max(1, subjMeans.length - cellSubjMeans.length)
          .toDouble();
      msBetweenErr = math.max(msWithin, ssSubj / dfS);
      dfBetweenErr = dfS;
    }

    final ssByTerm = <String, double>{};
    final dfByTerm = <String, double>{};
    final out = <String, _TermStat>{};

    for (final term in terms) {
      final groups = <String, List<double>>{};
      for (final o in obs) {
        final k = term.factors.map((f) => o.levels[f]!).join('\u0000');
        groups.putIfAbsent(k, () => []).add(o.y);
      }
      var ssMarginal = 0.0;
      for (final vals in groups.values) {
        final m = vals.reduce((a, b) => a + b) / vals.length;
        ssMarginal += vals.length * (m - grandMean) * (m - grandMean);
      }

      // Subtract lower-order terms for interactions
      var ssLower = 0.0;
      if (term.factors.length == 2) {
        ssLower =
            (ssByTerm[term.factors[0]] ?? 0.0) +
            (ssByTerm[term.factors[1]] ?? 0.0);
      } else if (term.factors.length == 3) {
        for (final f in term.factors) {
          ssLower += ssByTerm[f] ?? 0.0;
        }
        ssLower += ssByTerm['${term.factors[0]} × ${term.factors[1]}'] ?? 0.0;
        ssLower += ssByTerm['${term.factors[0]} × ${term.factors[2]}'] ?? 0.0;
        ssLower += ssByTerm['${term.factors[1]} × ${term.factors[2]}'] ?? 0.0;
      }

      final ssTerm = math.max(0.0, ssMarginal - ssLower);
      var dfNum = 1.0;
      for (final f in term.factors) {
        final kLvl = obs.map((o) => o.levels[f]!).toSet().length;
        dfNum *= math.max(1, kLvl - 1);
      }
      ssByTerm[term.label] = ssTerm;
      dfByTerm[term.label] = dfNum;

      final isPureBetween = term.factors.every(
        (f) => isBetweenFactor[f] == true,
      );
      final msErr = (useLmm && isPureBetween) ? msBetweenErr : msWithin;
      final dfDen = (useLmm && isPureBetween) ? dfBetweenErr : dfWithin;
      final msTerm = ssTerm / dfNum;
      final fStat = msErr > 1e-15 ? msTerm / msErr : 0.0;
      final pVal = StatMath.fDistributionPValue(fStat, dfNum, dfDen);
      final etaSq = (ssTerm + ssWithin) > 0
          ? ssTerm / (ssTerm + ssWithin)
          : 0.0;

      out[term.label] = _TermStat(
        fStat: fStat,
        pValue: pVal,
        dfNum: dfNum.round(),
        dfDenom: dfDen.round(),
        etaSq: etaSq,
      );
    }
    return out;
  }

  static List<_Obs> _permuteObs({
    required List<_Obs> obs,
    required List<String> factors,
    required Map<String, bool> isBetweenFactor,
    required bool useLmm,
    required math.Random rng,
  }) {
    if (!useLmm) {
      final ys = obs.map((o) => o.y).toList()..shuffle(rng);
      return [
        for (var i = 0; i < obs.length; i++)
          _Obs(subject: obs[i].subject, y: ys[i], levels: obs[i].levels),
      ];
    }

    // Exchangeable permutation for LMM:
    // 1. Permute between-subject factor labels across subjects
    // 2. Permute y within each subject
    final subjList = obs.map((o) => o.subject).toSet().toList();
    final shuffledSubj = List<String>.from(subjList)..shuffle(rng);
    final subjMap = {
      for (var i = 0; i < subjList.length; i++) subjList[i]: shuffledSubj[i],
    };

    final bySubjIndices = <String, List<int>>{};
    for (var i = 0; i < obs.length; i++) {
      bySubjIndices.putIfAbsent(obs[i].subject, () => []).add(i);
    }
    final permutedY = List<double>.filled(obs.length, 0.0);
    for (final idxs in bySubjIndices.values) {
      final vals = [for (final i in idxs) obs[i].y]..shuffle(rng);
      for (var k = 0; k < idxs.length; k++) {
        permutedY[idxs[k]] = vals[k];
      }
    }

    // Map between-subject factors from permuted subject
    final subjBetween = <String, Map<String, String>>{};
    for (final o in obs) {
      subjBetween.putIfAbsent(o.subject, () => {
        for (final f in factors)
          if (isBetweenFactor[f] == true) f: o.levels[f]!,
      });
    }

    return [
      for (var i = 0; i < obs.length; i++)
        _Obs(
          subject: obs[i].subject,
          y: permutedY[i],
          levels: {
            for (final f in factors)
              f: isBetweenFactor[f] == true
                  ? (subjBetween[subjMap[obs[i].subject]!]?[f] ??
                        obs[i].levels[f]!)
                  : obs[i].levels[f]!,
          },
        ),
    ];
  }

  static Map<String, dynamic> _descriptiveStats(List<double> vals) {
    final sorted = List<double>.from(vals)..sort();
    final n = sorted.length;
    final mean = sorted.reduce((a, b) => a + b) / n;
    var ss = 0.0;
    for (final v in sorted) {
      ss += (v - mean) * (v - mean);
    }
    final sd = n > 1 ? math.sqrt(ss / (n - 1)) : 0.0;
    final sem = n > 0 ? sd / math.sqrt(n) : 0.0;
    return {
      'n': n,
      'mean': mean,
      'sd': sd,
      'sem': sem,
      'median': _pct(sorted, 0.5),
      'q1': _pct(sorted, 0.25),
      'q3': _pct(sorted, 0.75),
      'min': sorted.first,
      'max': sorted.last,
      'values': sorted,
    };
  }

  static double _pct(List<double> s, double p) {
    if (s.isEmpty) return 0.0;
    if (s.length == 1) return s.first;
    final idx = p * (s.length - 1);
    final lo = idx.floor();
    final hi = idx.ceil();
    return s[lo] + (s[hi] - s[lo]) * (idx - lo);
  }

  static ({double meanDiff, double t, double df, double p}) _welchT(
    List<double> a,
    List<double> b,
  ) {
    final ma = a.reduce((x, y) => x + y) / a.length;
    final mb = b.reduce((x, y) => x + y) / b.length;
    var va = 0.0;
    for (final x in a) {
      va += (x - ma) * (x - ma);
    }
    va /= math.max(1, a.length - 1);
    var vb = 0.0;
    for (final x in b) {
      vb += (x - mb) * (x - mb);
    }
    vb /= math.max(1, b.length - 1);
    final se = math.sqrt(va / a.length + vb / b.length);
    final t = se > 1e-12 ? (mb - ma) / se : 0.0;
    final num = math.pow(va / a.length + vb / b.length, 2);
    final den =
        math.pow(va / a.length, 2) / math.max(1, a.length - 1) +
        math.pow(vb / b.length, 2) / math.max(1, b.length - 1);
    final df = den > 1e-12 ? (num / den).toDouble() : (a.length + b.length - 2).toDouble();
    return (
      meanDiff: mb - ma,
      t: t,
      df: df,
      p: StatMath.studentTPValue(t, df),
    );
  }
}

class _Obs {
  const _Obs({required this.subject, required this.y, required this.levels});
  final String subject;
  final double y;
  final Map<String, String> levels;
}

class _Term {
  const _Term(this.factors);
  final List<String> factors;
  String get label => factors.join(' × ');
}

class _TermStat {
  const _TermStat({
    required this.fStat,
    required this.pValue,
    required this.dfNum,
    required this.dfDenom,
    required this.etaSq,
  });
  final double fStat;
  final double pValue;
  final int dfNum;
  final int dfDenom;
  final double etaSq;
}
