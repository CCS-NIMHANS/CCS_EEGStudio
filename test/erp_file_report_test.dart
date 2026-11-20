import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/erp/erp_cache_recompute.dart';
import 'package:ccs_eeg_app/src/erp/erp_component_spec.dart';
import 'package:ccs_eeg_app/src/erp/workbench_report.dart';
import 'package:ccs_eeg_app/src/microstate_analysis.dart';
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('syntax examples identify alternating and varied six-visit words', () {
    final examples = microstateSyntaxExamples(6);
    expect(examples['1.000'], 'A B A B A B');
    expect(examples['2.585'], 'A B C D E F');
    expect(examples['2.252'], isNotNull);
  });
  test('legacy MetaMaps positions rotate while corrected coordinates stay unchanged', () {
    final old = MicrostateScalpPosition.fromJson({'label': 'Fz', 'x': -.5, 'y': 0}, legacyOrientation: true);
    expect(old.x, 0); expect(old.y, .5);
    final current = MicrostateScalpPosition.fromJson({'label': 'Fz', 'x': 0, 'y': .5});
    expect(current.x, 0); expect(current.y, .5);
  });
  testWidgets('a single-file PDF is generated from the selected measurement snapshot', (tester) async {
    await (FontLoader('DejaVuSans')..addFont(rootBundle.load('assets/fonts/DejaVuSans.ttf'))).load();
    final snapshot = ErpCacheRecompute.recomputeErpResultsFromCache(
      cachedFiles: [{
        'path': '/tmp/example_participant.edf', 'subject': 'S1', 'group': 'All participants',
        'labels': ['Fz','Cz','Pz','Oz'], 'times': [-.2, -.1, 0.0, .1, .2, .3, .4, .5, .6, .7, .8],
        'condition_names': ['Standard','Rare'], 'condition_counts': [20,10], 'n_a':20, 'n_b':10,
        'channel_conditions': {
          'Standard': [for (var i=0;i<4;i++) [0.0,0.0,0.0,1.0,2.0,1.0,0.0,-1.0,0.0,0.0,0.0]],
          'Rare': [for (var i=0;i<4;i++) [0.0,0.0,0.0,1.0,2.0,4.0,5.0,4.0,3.0,1.0,0.0]],
        },
      }], task:'Custom',
      components: [const ErpComponentSpec(name:'P3',windowStartMs:300,windowEndMs:600,polarity:1,roiChannels:['Pz'])],
      participantGroups: {}, excludedFiles: {}, baselineStartMs:-200,baselineEndMs:0,
    );
    final output = Directory('/private/tmp/ccs-report-review')..createSync(recursive:true);
    final path = await tester.runAsync(() => writeErpWorkbenchReport(snapshot, output.path, filename:'example_report.pdf'));
    expect(File(path!).readAsBytesSync().take(4), [37,80,68,70]);
    expect(File(path).lengthSync(), greaterThan(5000));
  });
}
