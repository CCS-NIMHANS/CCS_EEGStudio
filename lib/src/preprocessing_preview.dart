import 'recording_storage.dart';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'models.dart';
import 'extraction_service.dart';
import 'recording_loader.dart';

/// Persistent per-input cache. The engine retains lossless intermediate stages;
/// Dart retains complete combinations and the last successfully displayed state.
class PreprocessingPreview {
  PreprocessingPreview(this.baseline, {this.cacheRoot});
  static const schema = 'interactive-v3-full-ica';
  final EegRecording baseline;
  final Directory? cacheRoot;
  final Map<String, EegRecording> _results = {};
  Directory? _directory;
  Map<String, dynamic> _manifest = {};
  Map<String, Map<String, dynamic>> restoredSteps = {};
  Map<String, dynamic> restoredSettings = {};
  Map<String, dynamic> restoredConfiguration = {};
  String? get cachePath => _directory?.path;

  /// Export the displayed samples, never call the cleaning engine again.
  Future<EegRecording> finalize({
    required EegRecording recording,
    required String outputPath,
    required Map<String, Map<String, dynamic>> steps,
  }) async {
    await _initialize();
    if (File(outputPath).absolute.path == File(baseline.path).absolute.path ||
        File(outputPath).absolute.path == File(recording.path).absolute.path) {
      throw ArgumentError(
        'Choose a new output path to preserve original and cached samples.',
      );
    }
    final full = await RecordingLoader().loadFull(recording);
    await RecordingStorage.save(
      full,
      outputPath,
      provenance: {
        'source_path': baseline.path,
        'finalized_preprocessing': true,
        'interactive_applied_steps': steps,
      },
    );
    final saved = await RecordingLoader().load(outputPath);
    final stat = await File(outputPath).stat();
    final copies = Map<String, dynamic>.from(
      _manifest['finalized_copies'] as Map? ?? {},
    );
    copies[recording.path] = {
      'path': outputPath,
      'size': stat.size,
      'modified': stat.modified.toIso8601String(),
    };
    _manifest['finalized_copies'] = copies;
    await _writeManifest();
    return saved;
  }

  Future<EegRecording?> finalizedCopyFor(EegRecording recording) async {
    await _initialize();
    try {
      final entry =
          (_manifest['finalized_copies'] as Map? ?? {})[recording.path] as Map?;
      if (entry == null) return null;
      final stat = await File(entry['path'] as String).stat();
      if (stat.size != entry['size'] ||
          stat.modified.toIso8601String() != entry['modified'])
        return null;
      return await RecordingLoader().load(entry['path'] as String);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeManifest() async {
    final temp = File(
      '${_directory!.path}/session-${DateTime.now().microsecondsSinceEpoch}.writing',
    );
    await temp.writeAsString(jsonEncode(_manifest));
    await temp.rename('${_directory!.path}/session.json');
  }

  Future<void> _initialize() async {
    if (_directory != null) return;
    final input = File(baseline.path);
    // Include the source content and metadata: edits to signal, montage, history,
    // markers, external sample files, or preparation invalidate stale results.
    final digestParts = <Object?>[
      schema,
      input.absolute.path,
      baseline.sampleRate,
      baseline.labels,
      baseline.sampleCount,
      baseline.pointsPerEpoch,
      baseline.epochLabels,
      baseline.epochTmin,
      baseline.provenance,
      baseline.markers.map((m) => m.toJson()).toList(),
    ];
    final files = <String>{
      baseline.path,
      if (baseline.dataPath != null) baseline.dataPath!,
      for (final suffix in ['.ccsmeta', '.ccshistory', '.ccspreparation'])
        '${baseline.path}$suffix',
    };
    // BrainVision and EEGLAB often store samples outside the header.
    if (baseline.path.toLowerCase().endsWith('.vhdr')) {
      final header = await input.readAsString();
      for (final m in RegExp(
        r'^(?:DataFile|MarkerFile)=(.+)$',
        multiLine: true,
      ).allMatches(header)) {
        files.add('${input.parent.path}/${m[1]!.trim()}');
      }
    }
    if (baseline.path.toLowerCase().endsWith('.set'))
      files.add(
        baseline.path.replaceFirst(
          RegExp(r'\.set$', caseSensitive: false),
          '.fdt',
        ),
      );
    for (final path in files.toList()..sort()) {
      final file = File(path);
      if (await file.exists())
        digestParts.add([
          file.absolute.path,
          (await sha256.bind(file.openRead()).first).toString(),
        ]);
    }
    if (!await input.exists()) {
      // In-memory/prepared inputs must not collide just because their names match.
      digestParts.add(baseline.preview.map((ch) => ch.toList()).toList());
    }
    final fingerprint = sha256
        .convert(utf8.encode(jsonEncode(_identityCanonical(digestParts))))
        .toString();
    final taskHome = Platform.environment['HOME'] ?? Directory.systemTemp.path;
    final roots = [
      if (cacheRoot != null)
        cacheRoot!
      else
        Directory('${input.parent.path}/.ccs_eegstudio_cache'),
      if (cacheRoot == null)
        Directory(
          '$taskHome/Library/Application Support/CCS EEG Studio/preprocessing_cache',
        ),
    ];
    Object? failure;
    for (final root in roots) {
      final dir = Directory('${root.path}/$fingerprint');
      try {
        await dir.create(recursive: true);
        final probe = File(
          '${dir.path}/.probe-${DateTime.now().microsecondsSinceEpoch}',
        );
        await probe.writeAsString('');
        await probe.delete();
        _directory = dir;
        final manifest = File('${dir.path}/session.json');
        if (await manifest.exists()) {
          try {
            _manifest = Map<String, dynamic>.from(
              jsonDecode(await manifest.readAsString()) as Map,
            );
          } catch (_) {
            _manifest = {};
          }
        }
        return;
      } catch (e) {
        failure = e;
      }
    }
    throw FileSystemException('Could not create preprocessing cache: $failure');
  }

  Future<void> initialize() => _initialize();

  Future<EegRecording?> restore({
    ExtractionService? service,
    void Function(double, String)? onProgress,
  }) async {
    await _initialize();
    final last = _manifest['last'] as Map?;
    if (last == null) return null;
    final steps = (last['steps'] as Map?) ?? {};
    restoredSteps = {
      for (final e in steps.entries)
        e.key as String: Map<String, dynamic>.from(e.value as Map),
    };
    restoredSettings = Map<String, dynamic>.from(
      last['settings'] as Map? ?? {},
    );
    restoredConfiguration = Map<String, dynamic>.from(
      last['configuration'] as Map? ?? {},
    );
    if (restoredSteps.isEmpty) return baseline;
    final path = last['path'] as String?;
    if (path == null || !await File(path).exists()) return null;
    try {
      final result = await RecordingLoader().load(path);
      final prep = result.provenance['preprocessing'] as Map? ?? {};
      if (restoredSteps.containsKey('gedai') &&
          prep['gedai_implementation'] != gedaiImplementation) {
        if (service == null) return null;
        onProgress?.call(
          0,
          'Refreshing corrected GEDAI; upstream stages remain cached',
        );
        return await compute(
          service: service,
          steps: restoredSteps,
          settings: restoredSettings,
          configuration: restoredConfiguration,
          onProgress: onProgress ?? (_, _) {},
        );
      }
      return result;
    } catch (_) {
      return null;
    }
  }

  Future<EegRecording> compute({
    required ExtractionService service,
    required Map<String, Map<String, dynamic>> steps,
    required Map<String, dynamic> settings,
    Map<String, dynamic> configuration = const {},
    required void Function(double, String) onProgress,
  }) async {
    await _initialize();
    final requestedOptions = <String, dynamic>{
      ...settings,
      'downsample': false,
      'filter': false,
      'badchannel': false,
      'ica_method': 'none',
      'asr_mode': 'off',
      'muscle_method': 'none',
      'gedai': false,
      'interpolate': false,
      'reference_mode': 'none',
      'source_localization': false,
      'epoch_before_gedai': false,
      'stim_epochs_spec': null,
      for (final id in (steps.keys.toList()..sort())) ...steps[id]!,
    };
    final options = effectivePreviewOptions(
      requestedOptions,
      baseline.sampleRate,
    );
    final key = sha256
        .convert(utf8.encode(jsonEncode(_canonical(options))))
        .toString();
    final output = '${_directory!.path}/combination-$key.ccseeg';
    EegRecording result;
    if (steps.isEmpty) {
      result = baseline;
    } else if (_results.containsKey(key)) {
      onProgress(1, 'Restored cached preprocessing combination');
      result = _results.remove(key)!;
      _results[key] = result;
    } else {
      EegRecording? cached;
      if (await File(output).exists() && await File('$output.ready').exists()) {
        try {
          cached = await RecordingLoader().load(output);
        } catch (_) {
          /* recompute incomplete/corrupt entries */
        }
      }
      if (cached != null &&
          steps.containsKey('gedai') &&
          (cached.provenance['preprocessing']
                  as Map?)?['gedai_implementation'] !=
              gedaiImplementation)
        cached = null;
      cached ??= await _legacyCombination(options);
      if (cached != null) {
        onProgress(
          1,
          'Restored preprocessing combination from persistent file cache',
        );
        result = cached;
      } else {
        result = await service.preprocess(
          recording: baseline,
          outputPath: output,
          options: PreprocessingOptions.fromJson({
            ...options,
            'preview_cache_dir': '${_directory!.path}/stages',
          }),
          onProgress: onProgress,
        );
      }
      final summary = result.provenance['summary'] as Map? ?? {};
      final warnings = (summary['warnings'] as List? ?? []).map((w) => '$w');
      if (warnings.any(
        (w) =>
            w.startsWith('ICA/ASR skipped:') ||
            w.startsWith('GEDAI skipped:') ||
            w.startsWith('ASR skipped:') ||
            (w.startsWith('Muscle cleaner') && w.contains('skipped')) ||
            w.startsWith('Standalone ASR / muscle cleaning skipped'),
      )) {
        throw StateError(
          'The requested stage could not complete: ${warnings.join('; ')}',
        );
      }
      await File('${result.path}.ready').writeAsString(schema);
      _results[key] = result;
      // Keep recent toggles instant without retaining every full EEG/ICA report in RAM.
      while (_results.length > 4) {
        _results.remove(_results.keys.first);
      }
    }
    // Commit the last state only after success. Stage checkpoints are atomic too.
    _manifest = {
      'schema': schema,
      if (_manifest['finalized_copies'] != null)
        'finalized_copies': _manifest['finalized_copies'],
      'baseline': baseline.path,
      'cache_directory': _directory!.path,
      'last': {
        'steps': steps,
        'settings': settings,
        'configuration': configuration,
        'path': result.path,
      },
    };
    await _writeManifest();
    return result;
  }

  final Map<String, String> _legacyIndex = {};
  bool _legacyIndexed = false;
  Future<EegRecording?> _legacyCombination(Map<String, dynamic> options) async {
    if (!_legacyIndexed) {
      _legacyIndexed = true;
      await for (final entity in _directory!.list()) {
        if (entity is! File || !entity.path.endsWith('.ccshistory')) continue;
        final path = entity.path.substring(
          0,
          entity.path.length - '.ccshistory'.length,
        );
        if (!await File('$path.ready').exists()) continue;
        try {
          final file = await entity.open();
          late final List<int> bytes;
          try {
            bytes = await file.read(262144);
          } finally {
            await file.close();
          }
          final text = utf8.decode(bytes, allowMalformed: true);
          var start = -1, outerDepth = 0;
          var outerString = false, outerEscape = false;
          for (var i = 0; i < text.length; i++) {
            final c = text[i];
            if (outerString) {
              if (outerEscape) {
                outerEscape = false;
              } else if (c == r'\') {
                outerEscape = true;
              } else if (c == '"') {
                outerString = false;
              }
            } else if (c == '"') {
              if (outerDepth == 1 && text.startsWith('"preprocessing"', i)) {
                final match = RegExp(
                  r'^"preprocessing"\s*:\s*\{',
                ).firstMatch(text.substring(i));
                if (match != null) {
                  start = i + match.end - 1;
                  break;
                }
              }
              outerString = true;
            } else if (c == '{' || c == '[') {
              outerDepth++;
            } else if (c == '}' || c == ']') {
              outerDepth--;
            }
          }
          if (start < 0) continue;
          var depth = 0, inString = false, escaped = false;
          for (var i = start; i < text.length; i++) {
            final c = text[i];
            if (inString) {
              if (escaped) {
                escaped = false;
              } else if (c == r'\') {
                escaped = true;
              } else if (c == '"') {
                inString = false;
              }
            } else if (c == '"') {
              inString = true;
            } else if (c == '{') {
              depth++;
            } else if (c == '}' && --depth == 0) {
              final old = Map<String, dynamic>.from(
                jsonDecode(text.substring(start, i + 1)) as Map,
              );
              if (old['gedai'] == true &&
                  old['gedai_implementation'] != gedaiImplementation)
                break;
              _legacyIndex[jsonEncode(
                    _canonical(
                      effectivePreviewOptions(old, baseline.sampleRate),
                    ),
                  )] =
                  path;
              break;
            }
          }
        } catch (_) {
          /* Ignore incomplete legacy entries. */
        }
      }
    }
    final path = _legacyIndex[jsonEncode(_canonical(options))];
    if (path == null) return null;
    try {
      return await RecordingLoader().load(path);
    } catch (_) {
      return null;
    }
  }

  Future<void> selectOriginal() async {
    await _initialize();
    _manifest['last'] = {'steps': {}, 'settings': {}, 'path': baseline.path};
    final temp = File(
      '${_directory!.path}/original-${DateTime.now().microsecondsSinceEpoch}.writing',
    );
    await temp.writeAsString(jsonEncode(_manifest));
    await temp.rename('${_directory!.path}/session.json');
  }

  /// Closing/switching input drops memory only. Persistent results remain reusable.
  Future<void> dispose() async {
    _results.clear();
  }
}

Object? _canonical(Object? value) {
  if (value is Map)
    return {
      for (final k in (value.keys.cast<String>().toList()..sort()))
        k: _canonical(value[k]),
    };
  if (value is List) return value.map(_canonical).toList();
  if (value is num && value.isFinite && value == value.roundToDouble())
    return value.toInt();
  return value;
}

/// Compare settings semantically: JSON order and 250 vs 250.0 do not change EEG.
bool preprocessingSettingsEqual(Object? a, Object? b) =>
    jsonEncode(_canonical(a)) == jsonEncode(_canonical(b));

Map<String, dynamic> effectivePreviewOptions(
  Map<String, dynamic> requested,
  double inputRate,
) {
  final defaults = AnalysisConfig().toPreprocessingOptions().toJson();
  final parsed = PreprocessingOptions.fromJson({
    ...defaults,
    ...requested,
  }).toJson();
  final result = <String, dynamic>{
    ...defaults,
    'downsample': false,
    'filter': false,
    'badchannel': false,
    'ica_method': 'none',
    'muscle_method': 'none',
    'asr_mode': 'off',
    'gedai': false,
    'interpolate': false,
    'reference_mode': 'none',
    'source_localization': false,
    'epoch_before_gedai': false,
  };
  result.remove('stim_epochs_spec');
  result.remove('preview_cache_dir');
  result['non_eeg_channels'] =
      ((parsed['non_eeg_channels'] as List?)?.cast<String>().toList() ?? [])
        ..sort();
  void include(Iterable<String> keys) {
    for (final k in keys) {
      if (parsed.containsKey(k)) result[k] = parsed[k];
    }
  }

  if (parsed['downsample'] == true &&
      ((parsed['downsample_freq'] as num).toDouble() - inputRate).abs() > .5)
    include(['downsample', 'downsample_freq']);
  if (parsed['filter'] == true)
    include([
      'filter',
      'low_hz',
      'high_hz',
      'notch_hz',
      'fir_taps',
      'filter_type',
      'iir_order',
      'notch_width_hz',
      'notch_transition_hz',
    ]);
  if (parsed['badchannel'] == true)
    include(['badchannel', 'bad_variance_ratio']);
  if (['runica', 'picard'].contains(parsed['ica_method'])) {
    include(parsed.keys.where((k) => k.startsWith('ica_')));
    include(['fir_taps']);
  }
  if (parsed['muscle_method'] != 'none')
    include([
      'muscle_method',
      'bsscca_n_remove',
      'icc_threshold',
      'wica_levels',
      'ica_seed',
      'fir_taps',
    ]);
  if (parsed['asr_mode'] != 'off') {
    include(parsed.keys.where((k) => k.startsWith('asr_')));
    include(['ica_seed', 'fir_taps']);
  }
  if (parsed['gedai'] == true) {
    include(['gedai', 'gedai_threshold', 'gedai_epoch_seconds']);
    final numeric = double.tryParse('${result['gedai_threshold']}');
    if (numeric != null && numeric.isFinite)
      result['gedai_threshold'] = numeric == numeric.roundToDouble()
          ? numeric.toInt().toString()
          : numeric.toString();
  }
  if (parsed['interpolate'] == true)
    include(['interpolate', 'spline_stiffness', 'spline_regularization']);
  if (parsed['reference_mode'] != 'none') {
    include(['reference_mode']);
    if (parsed['reference_mode'] == 'channels') {
      include(['reference_channels']);
      result['reference_channels'] =
          (result['reference_channels'] as List).cast<String>().toList()
            ..sort();
    }
  }
  if (result['gedai'] == true) {
    result['gedai_implementation'] = gedaiImplementation;
  } else {
    result.remove('gedai_implementation');
  }
  return result;
}

Object? _identityCanonical(Object? value) {
  if (value is Map)
    return {
      for (final k in (value.keys.cast<String>().toList()..sort()))
        k: _identityCanonical(value[k]),
    };
  if (value is List) return value.map(_identityCanonical).toList();
  return value;
}

/// The full configured run and individual step buttons use the same cache.
/// Only enabled stages are included; finalisation itself only exports samples.
Map<String, Map<String, dynamic>> configuredPreviewSteps(
  Map<String, dynamic> options,
) {
  Map<String, dynamic> keys(List<String> names) => {
    for (final name in names)
      if (options.containsKey(name)) name: options[name],
  };
  return {
    if (options['downsample'] == true)
      'resample': keys(['downsample', 'downsample_freq']),
    if (options['filter'] == true)
      'filter': keys([
        'filter',
        'low_hz',
        'high_hz',
        'notch_hz',
        'fir_taps',
        'filter_type',
        'iir_order',
        'notch_width_hz',
        'notch_transition_hz',
      ]),
    if (options['badchannel'] == true)
      'badchannels': keys(['badchannel', 'bad_variance_ratio']),
    if (options['ica_method'] != null && options['ica_method'] != 'none')
      'ica': {
        for (final e in options.entries)
          if (e.key.startsWith('ica_')) e.key: e.value,
      },
    if (options['asr_mode'] != null && options['asr_mode'] != 'off')
      'asr': {
        for (final e in options.entries)
          if (e.key.startsWith('asr_')) e.key: e.value,
      },
    if (options['muscle_method'] != null && options['muscle_method'] != 'none')
      'muscle': keys([
        'muscle_method',
        'bsscca_n_remove',
        'icc_threshold',
        'wica_levels',
      ]),
    if (options['gedai'] == true)
      'gedai': keys(['gedai', 'gedai_threshold', 'gedai_epoch_seconds']),
    if (options['interpolate'] == true) 'interpolate': {'interpolate': true},
    if (options['reference_mode'] != null &&
        options['reference_mode'] != 'none')
      'reference': keys(['reference_mode', 'reference_channels']),
  };
}
