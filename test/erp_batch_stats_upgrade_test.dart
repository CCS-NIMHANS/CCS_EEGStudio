import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/erp/factor_grouping_designer.dart';
import 'package:ccs_eeg_app/src/group_statistics_engine.dart';

void main() {
  group('FilenameCropRule', () {
    test('infers keyword+digits rule for SKYMED013SESSION03', () {
      const sample = 'SKYMED013SESSION03-epo_clean.edf';
      // Crop 'SESSION03' -> indices 9..18
      final rules = FilenameCropRule.inferCandidates(sample, 9, 18);
      expect(rules, isNotEmpty);
      expect(rules.first.apply('SKYMED014SESSION05-epo_clean.edf'), 'SESSION05');
      expect(rules.first.apply('SKYMED120SESSION06-epo_clean.edf'), 'SESSION06');
    });

    test('infers subject prefix rule for SKYMED013', () {
      const sample = 'SKYMED013SESSION03-epo_clean.edf';
      final rules = FilenameCropRule.inferCandidates(sample, 0, 9);
      expect(rules, isNotEmpty);
      expect(rules.first.apply('SKYMED026SESSION06-epo_clean.edf'), 'SKYMED026');
    });
  });

  group('ErpGroupStatsEngine Permutation GLM & LMM', () {
    test('runs 3-factor permutation LMM and detects group/condition effects', () {
      final headers = [
        'subjid',
        'group',
        'condition',
        'electrode',
        'mean_amplitude_ERP',
      ];
      final rows = <List<String>>[];
      // 6 subjects per group (CON vs ADV), 2 conditions (Standard, Rare), 2 electrodes (Fz, Pz)
      for (var s = 1; s <= 12; s++) {
        final grp = s <= 6 ? 'CON' : 'ADV';
        final grpShift = grp == 'ADV' ? 3.5 : 0.0;
        final subjOffset = (s % 3 - 1) * 0.4;
        for (final cond in ['Standard', 'Rare']) {
          final condShift = cond == 'Rare' ? 4.0 : 0.0;
          for (final el in ['Fz', 'Pz']) {
            final elShift = el == 'Pz' ? 1.5 : 0.0;
            final val = 2.0 + grpShift + condShift + elShift + subjOffset;
            rows.add([
              'SKYMED${s.toString().padLeft(3, '0')}',
              grp,
              cond,
              el,
              val.toStringAsFixed(3),
            ]);
          }
        }
      }

      final res = ErpGroupStatsEngine.runAnalysis(
        headers: headers,
        rows: rows,
        factors: ['group', 'condition', 'electrode'],
        metrics: ['mean_amplitude_ERP'],
        subjectCol: 'subjid',
        preferredModel: 'lmm',
        nPermutations: 200,
        seed: 42,
      );

      expect(res.containsKey('error'), isFalse);
      final results = res['results'] as List;
      expect(results, hasLength(1));
      final m = results.first as Map<String, dynamic>;
      expect(m['model_type'], contains('LMM'));
      final effects = (m['model_effects'] as List).cast<Map<String, dynamic>>();
      final condEff = effects.firstWhere((e) => e['term'] == 'condition');
      expect((condEff['p_perm'] as num), lessThan(0.05));
      final grpEff = effects.firstWhere((e) => e['term'] == 'group');
      expect((grpEff['p_perm'] as num), lessThan(0.05));
      expect((m['cell_descriptives'] as Map), isNotEmpty);
    });

    test('reads real Groups.xlsx if present on volume', () async {
      const xlsxPath =
          '/Volumes/CCS Storage/CCS_UserFolders/neethi/SKYMeditation_2026/AOBD_Analysis/Groups.xlsx';
      if (!File(xlsxPath).existsSync()) return;
      final parsed = await TabularSheetReader.read(xlsxPath);
      expect(parsed.headers, containsAll(['subject', 'Group']));
      expect(parsed.rows.length, greaterThan(100));
    });

    test('split-plot within-subject error removes subject random-intercept variance', () {
      final headers = ['subjid', 'group', 'condition', 'amp'];
      final rows = <List<String>>[];
      // Balanced 2x2 mixed design: 6 subjects per group, huge +/-99 subject baseline offsets,
      // reliable +2.0 within-subject condition shift and tiny +/-0.25 within-subject residual.
      for (var s = 1; s <= 12; s++) {
        final grp = s <= 6 ? 'A' : 'B';
        final subjOffset = (s - 6.5) * 18.0; // +/- ~99
        final err = (s.isEven ? 0.25 : -0.25);
        final v1 = 10.0 + subjOffset;
        final v2 = 12.0 + subjOffset + err;
        rows.add(['S$s', grp, 'C1', v1.toStringAsFixed(6)]);
        rows.add(['S$s', grp, 'C2', v2.toStringAsFixed(6)]);
      }

      // Compute exact analytical repeated-measures F_within = SS_cond / MS_{Subj x Cond(within Group)}
      // Since C2 - C1 = 2.0 + err across 12 subjects split across 2 groups:
      // Analytical MS_within_err = 0.5 * sum_within_grp((d_{g,i} - d_bar_g)^2) / (12 - 2) = 0.5 * (12 * 0.0625) / 10 = 0.0375
      // Analytical SS_cond = 12 * 0.5 * (mean_C2 - mean_C1)^2 = 6 * 4.0 = 24.0 => F_cond = 24.0 / 0.0375 = 640.0
      final res = ErpGroupStatsEngine.runAnalysis(
        headers: headers,
        rows: rows,
        factors: ['group', 'condition'],
        metrics: ['amp'],
        subjectCol: 'subjid',
        preferredModel: 'lmm',
        nPermutations: 400,
        seed: 7,
      );

      final m = (res['results'] as List).first as Map<String, dynamic>;
      final effects = (m['model_effects'] as List).cast<Map<String, dynamic>>();
      final condEff = effects.firstWhere((e) => e['term'] == 'condition');
      expect((condEff['f_stat'] as num).toDouble(), closeTo(640.0, 1e-4));
      expect((condEff['df_denom'] as num).toInt(), 10);
      expect((condEff['p_value'] as num).toDouble(), lessThan(1e-6));
      expect((condEff['p_perm'] as num).toDouble(), lessThan(0.01));
    });
  });
}
