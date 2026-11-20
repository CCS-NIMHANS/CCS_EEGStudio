import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/media/media_sync_service.dart';
import 'package:ccs_eeg_app/src/media/synced_media_panel.dart';
import 'package:ccs_eeg_app/src/topostats/topostats_view.dart';
import 'package:ccs_eeg_app/src/state_dynamics/state_dynamics_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('tracking method explains held-out moving windows and silence', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SingleChildScrollView(child: SpeechTrackingMethod()))));
    await tester.tap(find.text('How speech tracking is computed'));
    await tester.pumpAndSettle();
    expect(find.textContaining('20-second moving windows'), findsOneWidget);
    expect(find.textContaining('Silence is included'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('six state chips do not collapse feature mapping heading', (tester) async {
    tester.view.physicalSize = const Size(1100, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final result = StateDynamicsResult.fromJson({
      'feature_set': 'paper', 'chosen_k': 6,
      'metrics': ['power'], 'rois': ['Fz'],
      'states': [for (final label in ['A','B','C','D','E','F']) {
        'label': label, 'centroid_z': [[0.0]], 'sig_dots': [[false]], 'iv_values': [[0.0]],
      }],
    });
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: StateDynamicsView(featureFilePaths: const [], result: result, hideTimeline: true)))));
    await tester.pumpAndSettle();
    final heading = find.textContaining('pooled states: State Feature Mapping');
    expect(tester.getSize(heading).width, greaterThan(700));
    expect(tester.getSize(heading).height, lessThan(80));
    expect(tester.takeException(), isNull);
  });
  test('speech tracking resolves a controller primary feature CSV to EEG samples', () {
    final dir = Directory.systemTemp.createTempSync('tracking-source-');
    addTearDown(() => dir.deleteSync(recursive:true));
    final feature = '${dir.path}${Platform.pathSeparator}session_clean.features.csv';
    File(feature).writeAsStringSync('channel,feature\nFz,1');
    final eeg = '${dir.path}${Platform.pathSeparator}session_clean.edf';
    File(eeg).writeAsStringSync('EEG fixture');
    expect(MediaSyncService.trackingRecordingPath(feature), eeg);
    expect(MediaSyncService.trackingRecordingPath(eeg), eeg);
    File(eeg).deleteSync();
    expect(() => MediaSyncService.trackingRecordingPath(feature), throwsStateError);
  });
  testWidgets('Start fresh remains available and resets files without deleting sources', (tester) async {
    tester.view.physicalSize = const Size(1800,1000); tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize); addTearDown(tester.view.resetDevicePixelRatio);
    var cleared = false;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: TopoStatsView(featureFilePaths: const ['/data/1_Day1_Task.features.csv'], onStartFresh: () => cleared = true))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start fresh')); await tester.pumpAndSettle();
    expect(cleared, isTrue);
    expect(find.text('Load feature CSVs…'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  test('audio waveform and envelope layers repaint independently', () async {
    Future<List<int>> raster(bool wave, bool envelope) async {
      final recorder = ui.PictureRecorder(); final canvas = Canvas(recorder);
      final p = SessionAlignedAudioPainter(minBins: const [-1,-.5,-.8], maxBins: const [1,.5,.8], envelope: const [.2,1,.2], segStartSec:0,segDurationSec:10,axisEndSec:10,left:0,right:200,label:'',showWaveform:wave,showEnvelope:envelope);
      p.paint(canvas, const Size(200,60));
      final picture = recorder.endRecording(); final image = await picture.toImage(200,60);
      final bytes = await image.toByteData(); image.dispose(); picture.dispose();
      return bytes!.buffer.asUint8List();
    }
    final hidden = await raster(false,false), wave = await raster(true,false), envelope = await raster(false,true);
    expect(wave, isNot(orderedEquals(hidden))); expect(envelope, isNot(orderedEquals(hidden))); expect(wave, isNot(orderedEquals(envelope)));
  });
}
