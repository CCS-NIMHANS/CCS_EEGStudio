import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/vhdr_loader.dart';

void main() {
  test('recovers from BrainVision DataFile and MarkerFile rename typo and repairs CRLF headers', () async {
    final dir = await Directory.systemTemp.createTemp('ccs_vhdr_typo_');
    try {
      final vhdrPath =
          '${dir.path}/Sub01_TKG01_7_Pilot_Tukdam_11.11.2026_Microphenomenology_Emptiness.vhdr';
      final eegPath =
          '${dir.path}/Sub01_TKG01_7_Pilot_Tukdam_11.11.2026_Microphenomenology_Emptiness.eeg';
      final vmrkPath =
          '${dir.path}/Sub01_TKG01_7_Pilot_Tukdam_11.11.2026_Microphenomenology_Emptiness.vmrk';

      await File(vhdrPath).writeAsString(
        'BrainVision Data Exchange Header File Version 1.0\r\n'
        '[Common Infos]\r\n'
        'Codepage=UTF-8\r\n'
        'DataFile=Sub01_TK01_7_Pilot_Tukdam_11.11.2026_Microphenomenology_Emptiness.eeg\r\n'
        'MarkerFile=Sub01_TK01_7_Pilot_Tukdam_11.11.2026_Microphenomenology_Emptiness.vmrk\r\n'
        'DataFormat=BINARY\r\n'
        'DataOrientation=MULTIPLEXED\r\n'
        'NumberOfChannels=2\r\n'
        'SamplingInterval=2000\r\n'
        '[Binary Infos]\r\n'
        'BinaryFormat=IEEE_FLOAT_32\r\n'
        '[Channel Infos]\r\n'
        'Ch1=Fp1,,0.5,µV\r\n'
        'Ch2=Fz,,1,µV\r\n',
      );
      await File(vmrkPath).writeAsString(
        'BrainVision Data Exchange Marker File Version 1.0\r\n'
        '[Common Infos]\r\n'
        'DataFile=Sub01_TK01_7_Pilot_Tukdam_11.11.2026_Microphenomenology_Emptiness.eeg\r\n'
        '[Marker Infos]\r\n'
        'Mk1=Stimulus,S  1,2,1,0\r\n',
      );

      final bd = ByteData(16);
      bd.setFloat32(0, 10.0, Endian.little);
      bd.setFloat32(4, 2.0, Endian.little);
      bd.setFloat32(8, 20.0, Endian.little);
      bd.setFloat32(12, 3.0, Endian.little);
      await File(eegPath).writeAsBytes(bd.buffer.asUint8List());

      final rec = VhdrLoader().load(vhdrPath);
      expect(rec.labels, ['Fp1', 'Fz']);
      expect(rec.sampleCount, 2);
      expect(rec.preview[0][0], closeTo(5.0, 1e-5));
      expect(rec.markers.length, 1);
      expect(rec.markers.first.description, 'S  1');

      final rawIssues =
          (rec.provenance['vhdr_mapping_issues'] as List?) ?? const [];
      expect(rawIssues.length, 2);
      final issues = [
        for (final j in rawIssues)
          VhdrMappingIssue.fromJson(Map<String, dynamic>.from(j as Map)),
      ];
      expect(issues.every((i) => i.isResolved), isTrue);

      for (final issue in issues) {
        await repairVhdrMapping(issue);
      }

      final repairedVhdr = await File(vhdrPath).readAsString();
      expect(repairedVhdr.contains('\r\n'), isTrue);
      expect(
        repairedVhdr.contains(
          'DataFile=Sub01_TKG01_7_Pilot_Tukdam_11.11.2026_Microphenomenology_Emptiness.eeg',
        ),
        isTrue,
      );
      expect(
        repairedVhdr.contains(
          'MarkerFile=Sub01_TKG01_7_Pilot_Tukdam_11.11.2026_Microphenomenology_Emptiness.vmrk',
        ),
        isTrue,
      );
      final repairedVmrk = await File(vmrkPath).readAsString();
      expect(
        repairedVmrk.contains(
          'DataFile=Sub01_TKG01_7_Pilot_Tukdam_11.11.2026_Microphenomenology_Emptiness.eeg',
        ),
        isTrue,
      );

      final cleanRec = VhdrLoader().load(vhdrPath);
      expect(cleanRec.provenance['vhdr_mapping_issues'], isNull);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('resolves unique fuzzy typo even when binary filename differs from vhdr stem', () async {
    final dir = await Directory.systemTemp.createTemp('ccs_vhdr_fuzzy_');
    try {
      final vhdrPath = '${dir.path}/Sub01_Renamed.vhdr';
      final eegPath = '${dir.path}/Sub01_TKG01_data.eeg';
      await File(vhdrPath).writeAsString(
        '[Common Infos]\n'
        'DataFile=Sub01_TK01_data.eeg\n'
        'NumberOfChannels=1\n'
        'SamplingInterval=1000\n'
        '[Binary Infos]\n'
        'BinaryFormat=IEEE_FLOAT_32\n'
        '[Channel Infos]\n'
        'Ch1=Cz,,1,µV\n',
      );
      final bd = ByteData(8);
      bd.setFloat32(0, 1.5, Endian.little);
      bd.setFloat32(4, 2.5, Endian.little);
      await File(eegPath).writeAsBytes(bd.buffer.asUint8List());

      final rec = VhdrLoader().load(vhdrPath);
      expect(rec.dataPath, eegPath);
      final rawIssues = rec.provenance['vhdr_mapping_issues'] as List;
      expect(rawIssues.length, 1);
      final issue = VhdrMappingIssue.fromJson(
        Map<String, dynamic>.from(rawIssues.first as Map),
      );
      expect(issue.matchStrategy, 'fuzzy_typo');
      expect(issue.editDistance, 1);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('reports actionable error with sibling candidates when data file is truly missing', () async {
    final dir = await Directory.systemTemp.createTemp('ccs_vhdr_missing_');
    try {
      final vhdrPath = '${dir.path}/SubjectA.vhdr';
      await File('${dir.path}/CompletelyDifferentOne.eeg').writeAsBytes([1, 2]);
      await File('${dir.path}/CompletelyDifferentTwo.eeg').writeAsBytes([3, 4]);
      await File(vhdrPath).writeAsString(
        '[Common Infos]\n'
        'DataFile=SubjectA_Missing.eeg\n'
        'NumberOfChannels=1\n'
        'SamplingInterval=1000\n'
        '[Channel Infos]\n'
        'Ch1=Cz,,1,µV\n',
      );
      expect(
        () => VhdrLoader().load(vhdrPath),
        throwsA(
          predicate<FormatException>(
            (e) =>
                e.message.contains('SubjectA_Missing.eeg') &&
                e.message.contains('CompletelyDifferentOne.eeg'),
          ),
        ),
      );
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
