import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'dart:convert';
import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/models.dart';
import 'package:ccs_eeg_app/src/source_review_workspace.dart';
import 'package:ccs_eeg_app/src/reference_channel_picker.dart';
import 'package:ccs_eeg_app/src/eeg_viewer.dart';
import 'package:ccs_eeg_app/src/event_navigation.dart';

EegRecording recording(
  String name,
  List<String> labels, {
  bool epochs = false,
}) => EegRecording(
  path: name,
  sampleRate: 100,
  labels: labels,
  preview: [
    for (var ch = 0; ch < labels.length; ch++)
      Float32List.fromList(
        List.generate(10000, (i) => math.sin(i * .07 + ch) * (ch + 1)),
      ),
  ],
  sampleCount: 10000,
  format: 'ccseeg',
  pointsPerEpoch: epochs ? 500 : null,
  epochCount: epochs ? 2 : 1,
);
void main() {
  test('spatial point, window mean and RMS never bridge saved trials', () {
    final rec = EegRecording(
      path: 'memory',
      sampleRate: 2,
      labels: ['Fz'],
      preview: [
        Float32List.fromList([1, 3, 100, 200]),
      ],
      sampleCount: 4,
      format: 'ccseeg',
      pointsPerEpoch: 2,
      epochCount: 2,
    );
    expect(spatialValues(rec, 0, 1, 'point', 0), [1]);
    expect(spatialValues(rec, 0, 1, 'mean', 0), [2]);
    expect(spatialValues(rec, .5, 10, 'mean', 0), [3]);
    expect(spatialValues(rec, 0, 1, 'mean', 1), [150]);
    expect(
      spatialValues(
        rec,
        0,
        1,
        'point',
        0,
        standardization: traceStandardization(rec, 0),
      ),
      [-1],
    );
    expect(
      spatialValues(rec, 0, 1, 'rms', 0).single,
      closeTo(math.sqrt(5), 1e-10),
    );
  });
  testWidgets(
    'reference picker searches channels and keeps a linked reference',
    (tester) async {
      var selected = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => ReferenceChannelPicker(
                channels: const ['Fp1', 'Cz', 'M1'],
                selected: selected,
                onChanged: (v) => setState(() => selected = v),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Choose reference channels…'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cz'));
      await tester.pump();
      await tester.tap(find.text('M1'));
      await tester.pump();
      await tester.tap(find.text('Use selected channels'));
      await tester.pumpAndSettle();
      expect(selected, ['Cz', 'M1']);
      expect(find.byType(InputChip), findsNWidgets(2));
    },
  );
  testWidgets(
    'source/channel switching preserves time and links the head-plot cursor',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final channels = recording('channels', [
        'Fp1',
        'Fp2',
        'F3',
        'F4',
        'Cz',
        'Pz',
        'O1',
        'O2',
      ]);
      final source = recording('source', [
        'precentral-lh',
        'precentral-rh',
        'postcentral-lh',
        'postcentral-rh',
      ]);
      final atlas =
          jsonDecode(
                File('assets/source_review_geometry.json').readAsStringSync(),
              )
              as Map<String, dynamic>;
      final fonts = FontLoader('DejaVuSans')
        ..addFont(rootBundle.load('assets/fonts/DejaVuSans.ttf'));
      await tester.runAsync(fonts.load);
      final boundary = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            brightness: Brightness.dark,
            useMaterial3: true,
            fontFamily: 'DejaVuSans',
          ),
          home: Scaffold(
            body: RepaintBoundary(
              key: boundary,
              child: SourceReviewWorkspace(
                channels: channels,
                sources: source,
                atlasGeometry: SynchronousFuture(atlas),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<EegViewer>(find.byType(EegViewer)).recording,
        source,
      );
      expect(
        tester.widget<EegViewer>(find.byType(EegViewer)).autoscaleByDefault,
        true,
      );
      expect(find.byKey(const ValueKey('source-time-slider')), findsNothing);
      final navigator = tester.widget<RecordingNavigator>(
        find.byType(RecordingNavigator),
      );
      navigator.onNavigate(40);
      await tester.pumpAndSettle();
      expect(
        tester
            .getSize(find.byKey(const ValueKey('source-full-height-waveform')))
            .height,
        greaterThan(900),
      );
      expect(
        tester
            .getSize(find.byKey(const ValueKey('source-spatial-side-panel')))
            .width,
        320,
      );
      final time = tester
          .widget<EegViewer>(find.byType(EegViewer))
          .cursorSeconds!;
      expect(time, 40);
      await tester.tap(find.text('Channels'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<EegViewer>(find.byType(EegViewer)).recording,
        channels,
      );
      expect(
        tester.widget<EegViewer>(find.byType(EegViewer)).cursorSeconds,
        time,
      );
      await tester.tap(find.text('Source / ROIs'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<EegViewer>(find.byType(EegViewer))
            .traceColors['precentral-lh'],
        isNotNull,
      );
      expect(tester.takeException(), isNull);
      if (Platform.environment['CCS_CAPTURE_SOURCE_REVIEW'] == '1')
        await tester.runAsync(() async {
          final image =
              await (boundary.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '${Directory.systemTemp.path}/ccs-source-review-preview.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
    },
  );
}
