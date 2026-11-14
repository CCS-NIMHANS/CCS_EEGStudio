import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/models.dart';
import 'package:ccs_eeg_app/src/erp/interactive_erp_session.dart';
import 'package:ccs_eeg_app/src/erp/interactive_erp_workspace.dart';

EegRecording fixture(String path) => EegRecording(
  path: path,
  sampleRate: 10,
  labels: const ['FCz'],
  sampleCount: 12,
  format: 'ccseeg',
  epochCount: 3,
  pointsPerEpoch: 4,
  epochTmin: -.1,
  epochLabels: const ['Correct', 'Correct', 'Error'],
  epochStartSeconds: const [10, 20, 30],
  preview: [
    Float32List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 10, 20, 30, 40]),
  ],
  completedStages: const ['preprocessing'],
  markers: const [
    EegMarker(
      type: 'Response',
      description: '111',
      startSeconds: .1,
      durationSeconds: 0,
      epochIndex: 0,
    ),
    EegMarker(
      type: 'Response',
      description: '111',
      startSeconds: .1,
      durationSeconds: 0,
      epochIndex: 1,
    ),
    EegMarker(
      type: 'Response',
      description: '112',
      startSeconds: .1,
      durationSeconds: 0,
      epochIndex: 2,
    ),
  ],
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      'DejaVuSans',
    )..addFont(rootBundle.load('assets/fonts/DejaVuSans.ttf'))).load();
  });
  test(
    'rejection and reinstatement update the correct average without changing samples',
    () {
      final input = fixture('/unused');
      final review = InteractiveErpSession(input);
      expect(review.mean('Correct', 0), [3, 4, 5, 6]);
      review.setRejected(1, true);
      expect(review.mean('Correct', 0), [1, 2, 3, 4]);
      expect(review.mean('Error', 0), [10, 20, 30, 40]);
      review.setRejected(1, true);
      expect(review.counts['Correct'], 1);
      review.setRejected(1, false);
      expect(review.mean('Correct', 0), [3, 4, 5, 6]);
      expect(input.preview.first, [1, 2, 3, 4, 5, 6, 7, 8, 10, 20, 30, 40]);
      review.setRejected(0, true);
      review.setRejected(1, true);
      expect(review.mean('Correct', 0), isNull);
      review.setRejected(2, true);
      expect(review.accepted, throwsStateError);
    },
  );
  test(
    'accepted exports retain trial boundaries, labels, timing and reindex markers',
    () {
      final review = InteractiveErpSession(fixture('/unused'))
        ..setRejected(1, true);
      final kept = review.accepted();
      expect(kept.epochCount, 2);
      expect(kept.pointsPerEpoch, 4);
      expect(kept.epochLabels, ['Correct', 'Error']);
      expect(kept.epochStartSeconds, [10, 30]);
      expect(kept.epochTmin, -.1);
      expect(kept.markers.map((m) => m.epochIndex), [0, 1]);
      expect(kept.markers.last.description, '112');
      expect(kept.completedStages, ['preprocessing']);
      expect(kept.provenance['erp_review']['rejected_trial_indices'], [1]);
      expect(kept.preview.first, [1, 2, 3, 4, 10, 20, 30, 40]);
    },
  );
  testWidgets(
    'ERN preset creates trials in the same workspace and excludes simultaneous unrelated markers',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final dir = Directory.systemTemp.createTempSync('ern-preset-review');
      final path = '${dir.path}/1_ERN.ccseeg';
      File(path).writeAsStringSync('fixture');
      final input = EegRecording(
        path: path,
        sampleRate: 100,
        labels: const ['FCz'],
        preview: [
          Float32List.fromList(List.generate(1000, (i) => (i % 20).toDouble())),
        ],
        sampleCount: 1000,
        format: 'ccseeg',
        markers: const [
          EegMarker(
            type: 'Response',
            description: '111',
            startSeconds: 2,
            durationSeconds: 0,
          ),
          EegMarker(
            type: 'Stimulus',
            description: '51',
            startSeconds: 2,
            durationSeconds: 0,
          ),
          EegMarker(
            type: 'Response',
            description: '112',
            startSeconds: 4,
            durationSeconds: 0,
          ),
          EegMarker(
            type: 'Response',
            description: '111',
            startSeconds: 6,
            durationSeconds: 0,
          ),
          EegMarker(
            type: 'Response',
            description: '112',
            startSeconds: 8,
            durationSeconds: 0,
          ),
        ],
      );
      final config = AnalysisConfig();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: InteractiveErpWorkspace(
              recording: input,
              config: config,
              onOpenRecording: () {},
              onUseReviewed: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(config.stimTmin, -.6);
      final create = find.text('Create / load trial preview');
      await tester.ensureVisible(create);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(create);
        await Future<void>.delayed(const Duration(milliseconds: 350));
      });
      await tester.pumpAndSettle();
      expect(find.text('Trial 1 / 4 · Correct response'), findsOneWidget);
      await tester.tap(find.text('Exclude trial'));
      await tester.pumpAndSettle();
      expect(find.textContaining('3/4 trials included'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      dir.deleteSync(recursive: true);
    },
  );
  testWidgets(
    'one workspace browses epochs and instantly reinstates excluded trials',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final dir = Directory.systemTemp.createTempSync('interactive_erp');
      final path = '${dir.path}/ERN.ccseeg';
      File(path).writeAsStringSync('fixture');
      Future<void> open() async {
        await tester.runAsync(() async {
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData.dark().copyWith(
                textTheme: ThemeData.dark().textTheme.apply(
                  fontFamily: 'DejaVuSans',
                ),
              ),
              home: RepaintBoundary(
                key: const ValueKey('erp-capture'),
                child: Scaffold(
                  body: InteractiveErpWorkspace(
                    recording: fixture(path),
                    config: AnalysisConfig(),
                    onOpenRecording: () {},
                    onUseReviewed: (_) {},
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await tester.pumpAndSettle();
      }

      await open();
      expect(find.text('Trial 1 / 3 · Correct'), findsOneWidget);
      expect(
        find.text('Live ERP averages · fixed amplitude scale'),
        findsOneWidget,
      );
      await tester.tap(find.text('Exclude trial'));
      await tester.pumpAndSettle();
      expect(find.text('Reinstate trial'), findsOneWidget);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)),
      );
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await open();
      expect(find.text('Reinstate trial'), findsOneWidget);
      await tester.tap(find.text('Reinstate trial'));
      await tester.pumpAndSettle();
      expect(find.text('Exclude trial'), findsOneWidget);
      if (Platform.environment['CCS_CAPTURE_INTERACTIVE_ERP'] == '1') {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('erp-capture')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            '${Directory.systemTemp.path}/ccs-interactive-erp.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.tap(find.text('ERP averages'));
      await tester.pumpAndSettle();
      expect(find.text('Correct · n=2'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      dir.deleteSync(recursive: true);
    },
  );
}
