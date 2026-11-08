// ignore_for_file: avoid_print, unused_local_variable, unused_catch_stack

import 'dart:convert';
import 'dart:io';
import 'package:ccs_eeg_app/src/recording_loader.dart';
import 'package:ccs_eeg_app/src/extraction_service.dart';
import 'package:ccs_eeg_app/src/models.dart';
import 'package:ccs_eeg_app/src/recording_storage.dart';
import 'package:ccs_eeg_app/src/channel_types.dart';
import 'package:ccs_eeg_app/src/erp/output_naming.dart';

void main() async {
  RecordingStorage.preferredFormat = RecordingFileFormat.edf;

  const srcDir = '/Users/arunsasidharan/EEGdata/PreethiHegde_EEG/RESEARCH_DATA02';
  const outDir = '/Users/arunsasidharan/EEGdata/PreethiHegde_EEG/Analysis_20261104';

  final dir = Directory(outDir);
  if (!dir.existsSync()) dir.createSync(recursive: true);

  // Scan all EDF files
  final entries = <Map<String, String>>[];
  for (final entity in Directory(srcDir).listSync(recursive: true)) {
    if (entity is File && entity.path.toLowerCase().endsWith('.edf')) {
      final rel = entity.path.substring(srcDir.length + 1);
      final parts = rel.split(Platform.pathSeparator);
      final group = parts.length > 1 ? parts.first : 'UNKNOWN';
      final fileName = parts.last;
      final subject = fileName.replaceAll(RegExp(r'\.edf$', caseSensitive: false), '').trim();
      entries.add({
        'path': entity.path,
        'group': group,
        'fileName': fileName,
        'subject': subject,
      });
    }
  }

  entries.sort((a, b) => a['fileName']!.compareTo(b['fileName']!));
  print('Found ${entries.length} raw EDF recordings across groups:');
  final groupCounts = <String, int>{};
  for (final e in entries) {
    groupCounts[e['group']!] = (groupCounts[e['group']!] ?? 0) + 1;
  }
  for (final g in groupCounts.keys.toList()..sort()) {
    print('  $g: ${groupCounts[g]} recordings');
  }

  // Preprocessing config matching AANCHAL-epo_clean.edf
  final cfg = AnalysisConfig()
    ..downsample = true
    ..downsampleFreq = 250
    ..filter = true
    ..lowHz = 0.5
    ..highHz = 40
    ..notchHz = 50
    ..badChannels = true
    ..interpolate = true
    ..gedai = true
    ..gedaiEpochSeconds = 1
    ..gedaiThreshold = 'auto'
    ..epochBeforeGedai = false
    ..preprocessingEpochSeconds = 4.0
    ..preprocessingOverlapSeconds = 2.0
    ..referenceMode = 'average'
    ..icaMethod = 'runica'
    ..icaBlink = true
    ..icaOther = true
    ..icaBlinkEpochs = 20
    ..icaBlinkThreshold = 0.99
    ..icaBlinkThresholdFloor = 0.60
    ..icaRemoveEcg = true
    ..icaOtherThreshold = 0.99
    ..icaOtherThresholdFloor = 0.60
    ..icaFitAsr = true
    ..icaFitAsrCutoff = 15
    ..icaSeed = 1
    ..asrMode = 'correct'
    ..asrCutoff = 20
    ..asrVariant = 'standard';

  // Save Preprocessing_Pipeline.json into outDir
  final pipelineFile = File('$outDir/Preprocessing_Pipeline.json');
  pipelineFile.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(cfg.toPreprocessingJson()));
  print('Wrote $outDir/Preprocessing_Pipeline.json');

  final service = ExtractionService();
  final loader = RecordingLoader();

  var preprocessedCount = 0;
  var skippedCount = 0;
  var failedCount = 0;

  final allPreprocessedPaths = <Map<String, String>>[];

  print('\n=== STAGE 1: BATCH PREPROCESSING ===');
  for (var i = 0; i < entries.length; i++) {
    final item = entries[i];
    final path = item['path']!;
    final subject = item['subject']!;
    final group = item['group']!;
    
    final outName = erpOutputName(path, extension: 'edf', epoched: true, cleaned: true);
    final outPath = '$outDir/$outName';

    if (File(outPath).existsSync() && File(outPath).lengthSync() > 1000) {
      print('[${i + 1}/${entries.length}] [$group] $subject -> SKIPPING (already preprocessed: $outName)');
      skippedCount++;
      allPreprocessedPaths.add({
        'rawPath': path,
        'cleanPath': outPath,
        'subject': subject,
        'group': group,
      });
      continue;
    }

    print('[${i + 1}/${entries.length}] [$group] $subject -> Preprocessing...');
    final sw = Stopwatch()..start();
    try {
      final raw = await loader.load(path);
      final channels = ChannelTypeMap.autoDetect(raw.labels);
      
      final preprocessed = await service.preprocess(
        recording: raw,
        outputPath: outPath,
        selection: const ViewerSelection.empty(),
        options: cfg.toPreprocessingOptions(nonEegChannels: channels.nonEegChannels),
        outputWindowSeconds: 4.0,
        outputOverlapSeconds: 2.0,
        onProgress: (p, msg) {
          if (p == 0.0 || p == 1.0 || p >= 0.5 && p < 0.55 || p >= 0.8 && p < 0.85) {
            // print occasional progress
          }
        },
      );
      print('  ✓ Done in ${sw.elapsed.inSeconds}s -> $outName (${File(outPath).lengthSync()} bytes)');
      preprocessedCount++;
      allPreprocessedPaths.add({
        'rawPath': path,
        'cleanPath': outPath,
        'subject': subject,
        'group': group,
      });
    } catch (e, st) {
      print('  ✗ FAILED: $e');
      print('    $st');
      failedCount++;
    }
  }

  print('\nPreprocessing Summary:');
  print('  Newly Preprocessed: $preprocessedCount');
  print('  Skipped (Existing): $skippedCount');
  print('  Failed:             $failedCount');
  print('  Total Available:    ${allPreprocessedPaths.length} / ${entries.length}');

  if (allPreprocessedPaths.isEmpty) {
    print('No preprocessed recordings to extract features from.');
    return;
  }

  print('\n=== STAGE 2: BATCH FEATURE EXTRACTION ===');
  // Feature config: PSD, IRASA, FOOOF, Nonlinear, Connectivity
  cfg
    ..psd = true
    ..psdAverage = 'median'
    ..fooof = true
    ..irasa = true
    ..nonlinear = true
    ..acw = true
    ..dfaFei = false
    ..coh = true
    ..plv = false
    ..ciplv = false
    ..pli = false
    ..wpli = false
    ..mic = true
    ..mim = false
    ..gc = false
    ..spectralGraph = false;

  final combinedPath = '$outDir/Batch_features.csv';
  final combinedSink = File(combinedPath).openWrite();
  var combinedHasHeader = false;

  var extractedCount = 0;
  var featSkipped = 0;
  var featFailed = 0;

  for (var i = 0; i < allPreprocessedPaths.length; i++) {
    final item = allPreprocessedPaths[i];
    final cleanPath = item['cleanPath']!;
    final subject = item['subject']!;
    final group = item['group']!;

    final perFilePath = '$outDir/$subject.features.csv';
    if (File(perFilePath).existsSync() && File(perFilePath).lengthSync() > 1000) {
      print('[${i + 1}/${allPreprocessedPaths.length}] [$group] $subject -> SKIPPING feature extraction (already exists)');
      featSkipped++;
      // Copy to combined
      var firstLine = true;
      for (final line in File(perFilePath).readAsLinesSync()) {
        if (firstLine) {
          firstLine = false;
          if (combinedHasHeader) continue;
          combinedHasHeader = true;
          combinedSink.writeln('Group,Subject,$line');
        } else {
          combinedSink.writeln('$group,$subject,$line');
        }
      }
      continue;
    }

    print('[${i + 1}/${allPreprocessedPaths.length}] [$group] $subject -> Extracting features...');
    final sw = Stopwatch()..start();
    try {
      final rec = await loader.load(cleanPath);
      final channels = ChannelTypeMap.autoDetect(rec.labels);
      final options = cfg.toExtractionOptions(
        nonEegChannels: channels.nonEegChannels,
        applyExclusions: false,
      );

      await service.run(
        recordings: [rec],
        outputPath: perFilePath,
        epochSeconds: 4.0,
        epochOverlapSeconds: 0.0,
        subepochExisting: false,
        selection: const ViewerSelection.empty(),
        writeCombined: true,
        options: options,
        onProgress: (p, msg) {},
      );

      print('  ✓ Extracted in ${sw.elapsed.inSeconds}s -> $subject.features.csv');
      extractedCount++;

      var firstLine = true;
      for (final line in File(perFilePath).readAsLinesSync()) {
        if (firstLine) {
          firstLine = false;
          if (combinedHasHeader) continue;
          combinedHasHeader = true;
          combinedSink.writeln('Group,Subject,$line');
        } else {
          combinedSink.writeln('$group,$subject,$line');
        }
      }
    } catch (e, st) {
      print('  ✗ Feature extraction failed for $subject: $e');
      featFailed++;
    }
  }

  await combinedSink.flush();
  await combinedSink.close();

  print('\nFeature Extraction Summary:');
  print('  Newly Extracted: $extractedCount');
  print('  Skipped:         $featSkipped');
  print('  Failed:          $featFailed');
  print('  Combined CSV:    $combinedPath (${File(combinedPath).existsSync() ? File(combinedPath).lengthSync() : 0} bytes)');

  // Build Metadata CSV
  final metaPath = '$outDir/metadata.csv';
  final metaSink = File(metaPath).openWrite();
  metaSink.writeln('Subject,Group');
  for (final item in allPreprocessedPaths) {
    metaSink.writeln('${item['subject']},${item['group']}');
  }
  await metaSink.flush();
  await metaSink.close();
  print('Wrote metadata to $metaPath');

  print('\n=== ALL BATCH STAGES COMPLETED SUCCESSFULLY ===');
}
