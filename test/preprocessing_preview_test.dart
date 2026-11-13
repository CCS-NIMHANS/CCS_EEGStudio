import 'dart:convert';
import 'dart:io';
import 'package:ccs_eeg_app/src/recording_storage.dart';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_eeg_app/src/models.dart';
import 'package:ccs_eeg_app/src/extraction_service.dart';
import 'package:ccs_eeg_app/src/preprocessing_preview.dart';
import 'package:ccs_eeg_app/src/ica_review.dart';

class _Engine extends ExtractionService {
  final List<PreprocessingOptions> calls = [];
  final List<EegRecording> inputs = [];
  bool fail = false;
  @override
  Future<EegRecording> preprocess({
    required EegRecording recording,
    required String outputPath,
    required PreprocessingOptions options,
    double outputOverlapSeconds = 0,
    double? outputWindowSeconds,
    ViewerSelection selection = const ViewerSelection.empty(),
    required void Function(double, String) onProgress,
  }) async {
    if (fail) throw StateError('cancelled');
    calls.add(options);
    inputs.add(recording);
    final result = EegRecording(
      path: outputPath,
      sampleRate: options.downsample ? 100 : recording.sampleRate,
      labels: recording.labels,
      preview: recording.preview,
      sampleCount: recording.sampleCount,
      format: 'ccseeg',
      provenance: {'preprocessing': options.toJson()},
    );
    await RecordingStorage.save(result, outputPath);
    return result;
  }
}

EegRecording _recording({
  String path = 'original',
  Map<String, dynamic> provenance = const {},
}) => EegRecording(
  path: path,
  sampleRate: 250,
  labels: ['Fp1', 'Fp2', 'F3', 'F4'],
  preview: List.generate(4, (_) => Float32List(250)),
  sampleCount: 250,
  format: 'ccseeg',
  provenance: provenance,
);

void main() {
  test(
    'arbitrary disable rebuilds from baseline and revisits use cache',
    () async {
      final raw = _recording(), engine = _Engine();
      final root = await Directory.systemTemp.createTemp('preview-cache-test-');
      addTearDown(() => root.delete(recursive: true));
      final session = PreprocessingPreview(raw, cacheRoot: root);
      addTearDown(session.dispose);
      final settings = AnalysisConfig().toPreprocessingOptions().toJson();
      Future<EegRecording> run(Map<String, Map<String, dynamic>> steps) =>
          session.compute(
            service: engine,
            steps: steps,
            settings: settings,
            onProgress: (_, _) {},
          );
      final filter = <String, dynamic>{'filter': true, 'low_hz': 1.0};
      final resample = <String, dynamic>{
        'downsample': true,
        'downsample_freq': 100.0,
      };
      final first = await run({'filter': filter});
      await run({'filter': filter, 'resample': resample});
      await run({'resample': resample});
      expect(engine.calls.last.filter, false);
      expect(engine.calls.last.downsample, true);
      expect(engine.calls.last.gedai, false);
      expect(engine.inputs.every((r) => identical(r, raw)), true);
      expect(identical(await run({'filter': filter}), first), true);
      expect(engine.calls.length, 3);
      expect(identical(await run({}), raw), true);
      await run({
        'filter': {...filter, 'low_hz': 2.0},
      });
      expect(engine.calls.length, 4);
      engine.fail = true;
      await expectLater(
        run({
          'filter': {...filter, 'low_hz': 3.0},
        }),
        throwsStateError,
      );
      engine.fail = false;
      await run({
        'filter': {...filter, 'low_hz': 3.0},
      });
      expect(engine.calls.length, 5);
    },
  );

  test(
    'file cache survives reopening, restores selection, and invalidates modified source',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'preview-persistence-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final raw = _recording(path: '${temp.path}/input.ccseeg');
      await RecordingStorage.save(raw, raw.path);
      final root = Directory('${temp.path}/cache');
      final engine = _Engine();
      final settings = AnalysisConfig().toPreprocessingOptions().toJson();
      final steps = <String, Map<String, dynamic>>{
        'filter': {'filter': true, 'low_hz': 1.0},
      };
      final first = PreprocessingPreview(raw, cacheRoot: root);
      final result = await first.compute(
        service: engine,
        steps: steps,
        settings: settings,
        configuration: {'low_hz': 1.0},
        onProgress: (_, _) {},
      );
      final originalCache = first.cachePath;
      await first.dispose();
      expect(await File(result.path).exists(), true);
      final reopened = PreprocessingPreview(raw, cacheRoot: root);
      expect((await reopened.restore())?.path, result.path);
      expect(reopened.restoredSteps, steps);
      expect(reopened.restoredConfiguration['low_hz'], 1.0);
      await reopened.compute(
        service: engine,
        steps: steps,
        settings: settings,
        onProgress: (_, _) {},
      );
      expect(engine.calls.length, 1);
      // Persist an explicit return to original without discarding earlier checkpoints.
      await reopened.selectOriginal();
      final original = PreprocessingPreview(raw, cacheRoot: root);
      expect(identical(await original.restore(), raw), true);
      expect(original.restoredSteps, isEmpty);
      await File(raw.path).writeAsString(' ', mode: FileMode.append);
      final changed = PreprocessingPreview(raw, cacheRoot: root);
      expect(await changed.restore(), null);
      expect(changed.cachePath, isNot(originalCache));
      await changed.compute(
        service: engine,
        steps: steps,
        settings: settings,
        onProgress: (_, _) {},
      );
      expect(engine.calls.length, 2);
    },
  );

  test(
    'cache ignores ineffective resampling, inactive parameters, map order and numeric spelling',
    () async {
      final root = await Directory.systemTemp.createTemp('preview-effective-');
      addTearDown(() => root.delete(recursive: true));
      final engine = _Engine(),
          session = PreprocessingPreview(_recording(), cacheRoot: root);
      final settings = AnalysisConfig().toPreprocessingOptions().toJson();
      final filter = <String, Map<String, dynamic>>{
        'filter': {'filter': true, 'low_hz': 1},
      };
      await session.compute(
        service: engine,
        steps: filter,
        settings: settings,
        onProgress: (_, _) {},
      );
      await session.compute(
        service: engine,
        steps: {
          'resample': {'downsample': true, 'downsample_freq': 250.0},
          'filter': {'low_hz': 1.0, 'filter': true},
        },
        settings: {
          ...settings,
          'source_snr': 20,
          'gedai_threshold': 'unused',
          'reference_channels': ['Cz'],
        },
        onProgress: (_, _) {},
      );
      expect(engine.calls.length, 1);
      expect(
        preprocessingSettingsEqual(
          {'rate': 250, 'on': true},
          {'on': true, 'rate': 250.0},
        ),
        true,
      );
    },
  );

  test(
    'previously saved combinations are reused under the normalized key',
    () async {
      final root = await Directory.systemTemp.createTemp('preview-legacy-key-');
      addTearDown(() => root.delete(recursive: true));
      final session = PreprocessingPreview(_recording(), cacheRoot: root),
          engine = _Engine();
      await session.initialize();
      final legacy = '${session.cachePath}/combination-previous-key.ccseeg';
      await RecordingStorage.save(_recording(path: legacy), legacy);
      final settings = AnalysisConfig().toPreprocessingOptions().toJson();
      final old = {
        ...settings,
        'downsample': false,
        'filter': true,
        'low_hz': 1.0,
        'badchannel': false,
        'ica_method': 'none',
        'asr_mode': 'off',
        'muscle_method': 'none',
        'gedai': false,
        'interpolate': false,
        'reference_mode': 'none',
        'source_localization': false,
        'epoch_before_gedai': false,
      };
      await File('$legacy.ccshistory').writeAsString(
        jsonEncode({
          'parent_provenance': {
            'preprocessing': {'filter': true, 'low_hz': 30},
          },
          'preprocessing': old,
          'summary': {},
        }),
      );
      await File('$legacy.ready').writeAsString('interactive-v3-full-ica');
      final result = await session.compute(
        service: engine,
        steps: {
          'filter': {'low_hz': 1, 'filter': true},
          'resample': {'downsample': true, 'downsample_freq': 250},
        },
        settings: settings,
        onProgress: (_, _) {},
      );
      expect(
        await File(result.path).resolveSymbolicLinks(),
        await File(legacy).resolveSymbolicLinks(),
      );
      expect(engine.calls, isEmpty);
    },
  );

  test(
    'older GEDAI results are refreshed rather than reused after a scientific correction',
    () async {
      final root = await Directory.systemTemp.createTemp('gedai-revision-');
      addTearDown(() => root.delete(recursive: true));
      final raw = _recording(), engine = _Engine();
      final session = PreprocessingPreview(raw, cacheRoot: root);
      final settings = AnalysisConfig().toPreprocessingOptions().toJson();
      final result = await session.compute(
        service: engine,
        steps: {
          'gedai': {'gedai': true},
        },
        settings: settings,
        onProgress: (_, _) {},
      );
      final oldPrep = Map<String, dynamic>.from(
        result.provenance['preprocessing'] as Map,
      )..remove('gedai_implementation');
      await RecordingStorage.save(
        _recording(path: result.path, provenance: {'preprocessing': oldPrep}),
        result.path,
      );
      final reopened = PreprocessingPreview(raw, cacheRoot: root);
      final restored = await reopened.restore(service: engine);
      expect(engine.calls.length, 2);
      expect(
        restored?.provenance['preprocessing']['gedai_implementation'],
        gedaiImplementation,
      );
    },
  );

  test(
    'older combinations reload from disk after the resident cache rotates',
    () async {
      final root = await Directory.systemTemp.createTemp('preview-resident-');
      addTearDown(() => root.delete(recursive: true));
      final session = PreprocessingPreview(_recording(), cacheRoot: root),
          engine = _Engine();
      final settings = AnalysisConfig().toPreprocessingOptions().toJson();
      Future<EegRecording> run(double low) => session.compute(
        service: engine,
        steps: {
          'filter': {'filter': true, 'low_hz': low},
        },
        settings: settings,
        onProgress: (_, _) {},
      );
      final first = await run(1);
      for (var i = 2; i <= 6; i++) await run(i.toDouble());
      expect((await run(1)).path, first.path);
      expect(engine.calls.length, 6);
    },
  );

  testWidgets('ICA review browses retained and removed components and stages', (
    tester,
  ) async {
    final stage = {
      'ran': true,
      'removed': [2],
      'review': {
        'class_names': ['Brain', 'Eye'],
        'probabilities': [
          [.9, .1],
          [.05, .95],
        ],
        'mixing': [
          [1, 2],
          [2, 1],
          [.2, .3],
          [.3, .2],
        ],
        'traces': [
          List.generate(12000, (i) => (i % 10).toDouble()),
          List.generate(12000, (i) => (i % 7).toDouble()),
        ],
        'trace_sample_rate': 100,
        'trace_duration_seconds': 120.0,
        'criteria': {
          'target_classes': ['Eye'],
          'applied_threshold': .9,
          'initial_threshold': .99,
          'floor_threshold': .6,
          'max_component_fraction': .1,
          'max_brain_probability_sum': .4,
          'iterations': 181,
          'explanation': 'Recorded threshold search',
        },
      },
    };
    final rec = _recording(
      provenance: {
        'summary': {
          'ica': {
            'ica': {
              'channels_used': ['Fp1', 'Fp2', 'F3', 'F4'],
              'blink_stage': stage,
              'other_stage': {'ran': false},
            },
          },
        },
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showIcaReview(context, rec),
            child: const Text('Review'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();
    expect(find.text('IC 1 · Retained in output'), findsOneWidget);
    await tester.tap(find.text('IC 2'));
    await tester.pumpAndSettle();
    expect(find.text('IC 2 · Removed from output'), findsOneWidget);
    expect(find.text('95.0%'), findsOneWidget);
    expect(find.textContaining('Removed: Eye 95.00% ≥ 90.00%'), findsOneWidget);
    final next = find.byTooltip('Next time window');
    await tester.ensureVisible(next);
    await tester.pumpAndSettle();
    for (var i = 0; i < 4; i++) {
      await tester.tap(next);
      await tester.pumpAndSettle();
    }
    expect(find.text('40.0 – 50.0 s / 120.0 s'), findsOneWidget);
    await tester.tap(find.text('General artifact stage'));
    await tester.pumpAndSettle();
    expect(find.textContaining('This stage did not run.'), findsOneWidget);
  });
}
