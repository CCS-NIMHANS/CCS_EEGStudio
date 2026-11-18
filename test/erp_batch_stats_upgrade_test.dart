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
  });
}
