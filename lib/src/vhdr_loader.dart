import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'models.dart';

/// Describes a broken or auto-recovered BrainVision header file pointer
/// (`DataFile=` or `MarkerFile=` in `[Common Infos]`).
class VhdrMappingIssue {
  const VhdrMappingIssue({
    required this.vhdrPath,
    required this.kind,
    required this.declaredName,
    required this.resolvedPath,
    required this.matchStrategy,
    this.editDistance,
    this.siblingCandidates = const [],
  });

  final String vhdrPath;
  final String kind; // 'DataFile' | 'MarkerFile'
  final String declaredName;
  final String? resolvedPath;
  final String matchStrategy; // 'same_stem' | 'fuzzy_typo' | 'unique_sibling' | 'missing'
  final int? editDistance;
  final List<String> siblingCandidates;

  bool get isResolved => resolvedPath != null;

  String get vhdrFileName => vhdrPath.split(RegExp(r'[/\\]')).last;

  String? get resolvedFileName =>
      resolvedPath?.split(RegExp(r'[/\\]')).last;

  String get summary {
    final target = resolvedFileName;
    if (target == null) {
      return '$vhdrFileName: $kind="$declaredName" was not found'
          '${siblingCandidates.isEmpty ? '.' : ' (available in folder: ${siblingCandidates.join(', ')}).'}';
    }
    final strategyLabel = switch (matchStrategy) {
      'same_stem' => 'matched header filename stem',
      'fuzzy_typo' =>
        'closest filename match (${editDistance ?? 1} character difference)',
      'unique_sibling' => 'only companion file in folder',
      _ => 'matched companion file',
    };
    return '$vhdrFileName: $kind pointed to missing "$declaredName" → '
        'resolved to "$target" ($strategyLabel)';
  }

  Map<String, dynamic> toJson() => {
    'vhdr_path': vhdrPath,
    'kind': kind,
    'declared_name': declaredName,
    'resolved_path': resolvedPath,
    'match_strategy': matchStrategy,
    if (editDistance != null) 'edit_distance': editDistance,
    if (siblingCandidates.isNotEmpty) 'sibling_candidates': siblingCandidates,
  };

  factory VhdrMappingIssue.fromJson(Map<String, dynamic> json) =>
      VhdrMappingIssue(
        vhdrPath: json['vhdr_path'] as String? ?? '',
        kind: json['kind'] as String? ?? 'DataFile',
        declaredName: json['declared_name'] as String? ?? '',
        resolvedPath: json['resolved_path'] as String?,
        matchStrategy: json['match_strategy'] as String? ?? 'missing',
        editDistance: (json['edit_distance'] as num?)?.toInt(),
        siblingCandidates:
            (json['sibling_candidates'] as List? ?? const []).cast<String>(),
      );
}

class VhdrCompanionResolution {
  const VhdrCompanionResolution({
    required this.resolvedDataPath,
    required this.resolvedMarkerPath,
    required this.issues,
  });

  final String? resolvedDataPath;
  final String? resolvedMarkerPath;
  final List<VhdrMappingIssue> issues;
}

/// Case-insensitive Levenshtein edit distance for detecting minor spelling
/// mismatches between BrainVision `.vhdr` internal pointers and filenames.
int levenshteinDistance(String a, String b) {
  final s = a.toLowerCase();
  final t = b.toLowerCase();
  if (s == t) return 0;
  if (s.isEmpty) return t.length;
  if (t.isEmpty) return s.length;

  var prev = List<int>.generate(t.length + 1, (j) => j);
  var curr = List<int>.filled(t.length + 1, 0);
  for (var i = 1; i <= s.length; i++) {
    curr[0] = i;
    final sc = s.codeUnitAt(i - 1);
    for (var j = 1; j <= t.length; j++) {
      final cost = sc == t.codeUnitAt(j - 1) ? 0 : 1;
      curr[j] = math.min(
        math.min(curr[j - 1] + 1, prev[j] + 1),
        prev[j - 1] + cost,
      );
    }
    final tmp = prev;
    prev = curr;
    curr = tmp;
  }
  return prev[t.length];
}

/// Resolves BrainVision `DataFile` and `MarkerFile` companions for [vhdrPath].
///
/// When files have been renamed on disk without updating `[Common Infos]`
/// inside the `.vhdr`, recovers the true companion file via:
///   1. Same-stem sibling (`<vhdr_stem>.eeg/.dat` or `.vmrk`, case-insensitive)
///   2. Unique close Levenshtein typo match among same-extension siblings
///   3. Unique single `.vhdr` + single companion pair in the folder
VhdrCompanionResolution resolveVhdrCompanions(
  String vhdrPath, {
  String? declaredDataFile,
  String? declaredMarkerFile,
}) {
  final vhdrFile = File(vhdrPath);
  final parentDir = vhdrFile.parent;
  final sep = Platform.pathSeparator;
  final vhdrBase = vhdrPath.split(RegExp(r'[/\\]')).last;
  final vhdrStem = vhdrBase.replaceFirst(
    RegExp(r'\.vhdr$', caseSensitive: false),
    '',
  );

  var dataDeclared = declaredDataFile;
  var markerDeclared = declaredMarkerFile;
  if ((dataDeclared == null || markerDeclared == null) &&
      vhdrFile.existsSync()) {
    final parsed = _parseCommonInfosPointers(vhdrFile.readAsStringSync());
    dataDeclared ??= parsed.$1;
    markerDeclared ??= parsed.$2;
  }
  final dataRef = (dataDeclared ?? '').trim();
  final markerRef = (markerDeclared ?? '').trim();

  final siblings = parentDir.existsSync()
      ? parentDir
            .listSync(followLinks: false)
            .whereType<File>()
            .map((f) => f.path)
            .where((p) => !p.split(RegExp(r'[/\\]')).last.startsWith('._'))
            .toList()
      : <String>[];

  final issues = <VhdrMappingIssue>[];

  ({String? path, VhdrMappingIssue? issue}) resolveKind({
    required String kind,
    required String declared,
    required List<String> allowedExts,
  }) {
    final declaredBase = declared.isEmpty
        ? ''
        : declared.split(RegExp(r'[/\\]')).last.trim();
    final directPath = declaredBase.isNotEmpty
        ? '${parentDir.path}$sep$declaredBase'
        : '${parentDir.path}$sep$vhdrStem${allowedExts.first}';
    if (File(directPath).existsSync()) {
      return (path: directPath, issue: null);
    }

    final candidates = siblings.where((p) {
      final low = p.split(RegExp(r'[/\\]')).last.toLowerCase();
      return allowedExts.any(low.endsWith);
    }).toList()..sort();

    // Case-insensitive exact match to declared basename (important on Linux).
    if (declaredBase.isNotEmpty) {
      final ciDeclared = candidates.where(
        (p) =>
            p.split(RegExp(r'[/\\]')).last.toLowerCase() ==
            declaredBase.toLowerCase(),
      );
      if (ciDeclared.isNotEmpty) {
        return (path: ciDeclared.first, issue: null);
      }
    }

    String? matchedPath;
    var strategy = 'missing';
    int? matchDist;

    // 1. Exact same-stem sibling (case-insensitive)
    for (final ext in allowedExts) {
      final expected = '$vhdrStem$ext'.toLowerCase();
      final hit = candidates
          .where((p) => p.split(RegExp(r'[/\\]')).last.toLowerCase() == expected)
          .firstOrNull;
      if (hit != null) {
        matchedPath = hit;
        strategy = 'same_stem';
        if (declaredBase.isNotEmpty) {
          matchDist = levenshteinDistance(
            declaredBase,
            hit.split(RegExp(r'[/\\]')).last,
          );
        }
        break;
      }
    }

    // 2. Unique close Levenshtein typo match against declared name (or stem)
    if (matchedPath == null && candidates.isNotEmpty) {
      final query = declaredBase.isNotEmpty
          ? declaredBase
          : '$vhdrStem${allowedExts.first}';
      final scored = [
        for (final c in candidates)
          (
            path: c,
            dist: levenshteinDistance(
              query,
              c.split(RegExp(r'[/\\]')).last,
            ),
            len: math.min(
              query.length,
              c.split(RegExp(r'[/\\]')).last.length,
            ),
          ),
      ]..sort((a, b) => a.dist.compareTo(b.dist));

      final best = scored.first;
      final maxAllowed = math.max(2, (best.len * 0.25).ceil()).clamp(1, 5);
      final uniqueGap = scored.length == 1 || (scored[1].dist - best.dist) >= 2;
      if (best.dist <= maxAllowed && uniqueGap) {
        matchedPath = best.path;
        strategy = 'fuzzy_typo';
        matchDist = best.dist;
      }
    }

    // 3. Unique companion in folder when there is only 1 .vhdr and 1 companion
    if (matchedPath == null && candidates.length == 1) {
      final vhdrCount = siblings
          .where((p) => p.toLowerCase().endsWith('.vhdr'))
          .length;
      if (vhdrCount <= 1) {
        matchedPath = candidates.single;
        strategy = 'unique_sibling';
      }
    }

    final shouldReport =
        kind == 'DataFile' || declaredBase.isNotEmpty || matchedPath != null;
    final issue = shouldReport
        ? VhdrMappingIssue(
            vhdrPath: vhdrPath,
            kind: kind,
            declaredName: declaredBase.isNotEmpty
                ? declaredBase
                : '(unspecified)',
            resolvedPath: matchedPath,
            matchStrategy: matchedPath != null ? strategy : 'missing',
            editDistance: matchDist,
            siblingCandidates: [
              for (final c in candidates) c.split(RegExp(r'[/\\]')).last,
            ],
          )
        : null;

    return (path: matchedPath, issue: issue);
  }

  final dataRes = resolveKind(
    kind: 'DataFile',
    declared: dataRef,
    allowedExts: const ['.eeg', '.dat'],
  );
  if (dataRes.issue != null) issues.add(dataRes.issue!);

  final markerRes = resolveKind(
    kind: 'MarkerFile',
    declared: markerRef,
    allowedExts: const ['.vmrk'],
  );
  // Only flag MarkerFile issue if the .vhdr explicitly declared a MarkerFile that
  // did not match on disk (omitted MarkerFile with no .vmrk is normal).
  if (markerRes.issue != null && markerRef.isNotEmpty) {
    issues.add(markerRes.issue!);
  }

  return VhdrCompanionResolution(
    resolvedDataPath: dataRes.path,
    resolvedMarkerPath: markerRes.path,
    issues: issues,
  );
}

(String, String) _parseCommonInfosPointers(String content) {
  final lines = content
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n');
  var dataFile = '';
  var markerFile = '';
  var section = '';
  for (final raw in lines) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith(';')) continue;
    if (line.startsWith('[')) {
      section = line.replaceAll('[', '').replaceAll(']', '').trim();
      continue;
    }
    if (section.toLowerCase() == 'common infos' && line.contains('=')) {
      final eq = line.indexOf('=');
      final k = line.substring(0, eq).trim().toLowerCase();
      final v = line.substring(eq + 1).trim();
      if (k == 'datafile') dataFile = v;
      if (k == 'markerfile') markerFile = v;
    }
  }
  return (dataFile, markerFile);
}

/// Opt-in header repair: updates `[Common Infos]` in `issue.vhdrPath` (and the
/// companion `.vmrk` `DataFile=` entry when repairing `DataFile`) to point to the
/// resolved companion file on disk, preserving original line endings.
Future<void> repairVhdrMapping(VhdrMappingIssue issue) async {
  final targetPath = issue.resolvedPath;
  if (targetPath == null || !await File(targetPath).exists()) {
    throw FileSystemException(
      'Cannot repair ${issue.kind}: target companion file does not exist.',
      targetPath,
    );
  }
  final vhdrFile = File(issue.vhdrPath);
  if (!await vhdrFile.exists()) {
    throw FileSystemException(
      'BrainVision header file not found.',
      issue.vhdrPath,
    );
  }
  final newName = targetPath.split(RegExp(r'[/\\]')).last;
  await _rewriteIniPointer(vhdrFile, issue.kind, newName);

  // If repairing DataFile, keep companion .vmrk DataFile= in sync when broken.
  if (issue.kind == 'DataFile') {
    final comp = resolveVhdrCompanions(issue.vhdrPath);
    final vmrkPath = comp.resolvedMarkerPath;
    if (vmrkPath != null && await File(vmrkPath).exists()) {
      final vmrkFile = File(vmrkPath);
      final (vmrkDataFile, _) = _parseCommonInfosPointers(
        await vmrkFile.readAsString(),
      );
      final vmrkDataBase = vmrkDataFile.split(RegExp(r'[/\\]')).last.trim();
      if (vmrkDataBase.isNotEmpty && vmrkDataBase != newName) {
        final vmrkDir = vmrkFile.parent.path;
        if (!File('$vmrkDir${Platform.pathSeparator}$vmrkDataBase')
            .existsSync()) {
          await _rewriteIniPointer(vmrkFile, 'DataFile', newName);
        }
      }
    }
  }
}

Future<void> _rewriteIniPointer(File file, String keyName, String value) async {
  final raw = await file.readAsString();
  final eol = raw.contains('\r\n') ? '\r\n' : '\n';
  final lines = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
  final keyLower = keyName.toLowerCase();

  var inCommon = false;
  var commonEndIdx = -1;
  var replaced = false;

  for (var i = 0; i < lines.length; i++) {
    final trimmed = lines[i].trim();
    if (trimmed.startsWith('[')) {
      if (inCommon) commonEndIdx = i;
      inCommon = trimmed.toLowerCase() == '[common infos]';
      continue;
    }
    if (inCommon && !trimmed.startsWith(';') && trimmed.contains('=')) {
      final eq = trimmed.indexOf('=');
      final k = trimmed.substring(0, eq).trim().toLowerCase();
      if (k == keyLower) {
        lines[i] = '$keyName=$value';
        replaced = true;
        break;
      }
    }
  }

  if (!replaced && commonEndIdx >= 0) {
    lines.insert(commonEndIdx, '$keyName=$value');
  }
  await file.writeAsString(lines.join(eol));
}

/// Loader for BrainVision BrainAmp format files (.vhdr / .eeg / .dat).
///
/// Supports:
///   DataOrientation : MULTIPLEXED | VECTORIZED
///   BinaryFormat    : IEEE_FLOAT_32 | INT_16 | UINT_16 | INT_32
///   Resolution      : per-channel float multiplier from [Channel Infos]
class VhdrLoader {
  EegRecording load(String vhdrPath) {
    // ── Parse header ───────────────────────────────────────────────────────
    final lines = File(vhdrPath)
        .readAsStringSync()
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n');

    String key(String line) =>
        line.contains('=') ? line.substring(0, line.indexOf('=')).trim() : '';
    String val(String line) =>
        line.contains('=') ? line.substring(line.indexOf('=') + 1).trim() : '';

    String dataFile = '';
    String markerFile = '';
    String orientation = 'MULTIPLEXED';
    String binaryFormat = 'IEEE_FLOAT_32';
    int numChannels = 0;
    int samplingIntervalUs = 0; // microseconds

    final channelNames = <int, String>{};
    final channelResolutions = <int, double>{}; // index → µV/bit

    String section = '';
    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith(';')) continue;
      if (line.startsWith('[')) {
        section = line.replaceAll('[', '').replaceAll(']', '').trim();
        continue;
      }
      final k = key(line);
      final v = val(line);
      switch (section) {
        case 'Common Infos':
          if (k == 'DataFile') dataFile = v;
          if (k == 'MarkerFile') markerFile = v;
          if (k == 'DataOrientation') orientation = v.toUpperCase();
          if (k == 'NumberOfChannels') numChannels = int.tryParse(v) ?? 0;
          if (k == 'SamplingInterval')
            samplingIntervalUs = int.tryParse(v) ?? 0;
        case 'Binary Infos':
          if (k == 'BinaryFormat') binaryFormat = v.toUpperCase();
        case 'Channel Infos':
          // Ch<N>=name,ref,resolution,unit,...
          if (k.startsWith('Ch')) {
            final idx = int.tryParse(k.substring(2));
            if (idx != null) {
              final parts = v.split(',');
              channelNames[idx] = parts.isNotEmpty ? parts[0].trim() : 'Ch$idx';
              if (parts.length >= 3 && parts[2].trim().isNotEmpty) {
                channelResolutions[idx] =
                    double.tryParse(parts[2].trim()) ?? 1.0;
              } else {
                channelResolutions[idx] = 1.0;
              }
              final unit = parts.length >= 4
                  ? parts[3].trim().toLowerCase().replaceAll('μ', 'µ')
                  : 'µv';
              final multiplier = switch (unit) {
                'v' => 1e6,
                'mv' => 1e3,
                'nv' => .001,
                _ => 1.0,
              };
              channelResolutions[idx] = channelResolutions[idx]! * multiplier;
            }
          }
      }
    }

    if (samplingIntervalUs <= 0) {
      throw const FormatException('Invalid SamplingInterval in .vhdr');
    }
    final sampleRate = 1000000.0 / samplingIntervalUs;
    if (numChannels <= 0) {
      throw FormatException('Invalid NumberOfChannels=$numChannels in .vhdr');
    }

    // Build ordered label list
    final labels = <String>[];
    final resolutions = <double>[];
    for (var i = 1; i <= numChannels; i++) {
      labels.add(channelNames[i] ?? 'Ch$i');
      resolutions.add(channelResolutions[i] ?? 1.0);
    }

    // ── Resolve data & marker file paths (with rename/typo auto-recovery) ───
    final resolution = resolveVhdrCompanions(
      vhdrPath,
      declaredDataFile: dataFile,
      declaredMarkerFile: markerFile,
    );
    final dataPath = resolution.resolvedDataPath;
    if (dataPath == null || !File(dataPath).existsSync()) {
      final missingIssue = resolution.issues
          .where((i) => i.kind == 'DataFile')
          .firstOrNull;
      final declaredLabel = dataFile.trim().isEmpty
          ? '(unspecified)'
          : dataFile.trim();
      final candidates = missingIssue?.siblingCandidates ?? const <String>[];
      final hint = candidates.isEmpty
          ? 'No .eeg or .dat companion files were found in ${File(vhdrPath).parent.path}.'
          : 'Sibling companion file(s) in folder: ${candidates.join(', ')}. '
                'If the recording was renamed, update DataFile= inside the .vhdr header.';
      throw FormatException(
        'BrainVision DataFile="$declaredLabel" referenced inside '
        '${vhdrPath.split(RegExp(r"[/\\]")).last} was not found. $hint',
      );
    }

    // ── Read binary data ────────────────────────────────────────────────────
    final bytes = File(dataPath).readAsBytesSync();
    final bytesPerSample = switch (binaryFormat) {
      'INT_16' || 'UINT_16' => 2,
      'INT_32' => 4,
      _ => 4, // IEEE_FLOAT_32
    };
    final totalSamples = bytes.length ~/ (numChannels * bytesPerSample);

    if (totalSamples <= 0) {
      throw FormatException('Data file appears empty: $dataPath');
    }

    final bd = ByteData.sublistView(bytes);
    const stride = 1;

    final preview = <Float32List>[];

    if (orientation == 'VECTORIZED') {
      // Each channel is stored contiguously: [ch0_t0, ch0_t1, ..., ch1_t0, ...]
      for (var c = 0; c < numChannels; c++) {
        final res = resolutions[c];
        final channelValues = Float32List(totalSamples);
        for (var s = 0; s < totalSamples; s += stride) {
          final offset = (c * totalSamples + s) * bytesPerSample;
          channelValues[s] = _readSample(bd, offset, binaryFormat, res);
        }
        preview.add(channelValues);
      }
    } else {
      // MULTIPLEXED: [ch0_t0, ch1_t0, ..., chN_t0, ch0_t1, ch1_t1, ...]
      for (var c = 0; c < numChannels; c++) {
        final res = resolutions[c];
        final channelValues = Float32List(totalSamples);
        for (var s = 0; s < totalSamples; s += stride) {
          final offset = (s * numChannels + c) * bytesPerSample;
          channelValues[s] = _readSample(bd, offset, binaryFormat, res);
        }
        preview.add(channelValues);
      }
    }

    final markers = _loadVmrk(
      vhdrPath,
      sampleRate,
      resolvedMarkerPath: resolution.resolvedMarkerPath,
    );

    final provenance = <String, dynamic>{};
    if (resolution.issues.isNotEmpty) {
      provenance['vhdr_mapping_issues'] = [
        for (final issue in resolution.issues) issue.toJson(),
      ];
    }

    return EegRecording(
      path: vhdrPath,
      dataPath: dataPath,
      sampleRate: sampleRate,
      labels: labels,
      preview: preview,
      sampleCount: totalSamples,
      format: 'vhdr',
      markers: markers,
      provenance: provenance,
    );
  }

  List<EegMarker> _loadVmrk(
    String vhdrPath,
    double sampleRate, {
    String? resolvedMarkerPath,
  }) {
    final vmrkPath =
        resolvedMarkerPath ??
        vhdrPath.replaceAll(RegExp(r'\.vhdr$', caseSensitive: false), '.vmrk');
    final file = File(vmrkPath);
    if (!file.existsSync()) return const [];

    final markers = <EegMarker>[];
    final lines = file
        .readAsStringSync()
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n');

    String section = '';
    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith(';')) continue;
      if (line.startsWith('[')) {
        section = line.replaceAll('[', '').replaceAll(']', '').trim();
        continue;
      }
      if (section == 'Marker Infos' && line.startsWith('Mk')) {
        final eqIdx = line.indexOf('=');
        if (eqIdx < 0) continue;
        final val = line.substring(eqIdx + 1).trim();
        final parts = val.split(',');
        if (parts.length >= 3) {
          final type = parts[0].trim();
          final desc = parts[1].trim();
          final posSamples = int.tryParse(parts[2].trim()) ?? 1;
          final sizeSamples = parts.length >= 4
              ? (int.tryParse(parts[3].trim()) ?? 0)
              : 0;
          final chNum = parts.length >= 5
              ? (int.tryParse(parts[4].trim()) ?? 0)
              : 0;

          final startSec = (posSamples - 1) / sampleRate;
          final durSec = sizeSamples / sampleRate;

          markers.add(
            EegMarker(
              type: type,
              description: desc,
              startSeconds: startSec > 0 ? startSec : 0.0,
              durationSeconds: durSec > 0 ? durSec : 0.0,
              channelIndex: chNum > 0 ? chNum - 1 : null,
            ),
          );
        }
      }
    }
    return markers;
  }

  double _readSample(
    ByteData bd,
    int offset,
    String format,
    double resolution,
  ) {
    if (offset + (format == 'INT_16' || format == 'UINT_16' ? 2 : 4) >
        bd.lengthInBytes) {
      return 0.0;
    }
    return switch (format) {
      'IEEE_FLOAT_32' => bd.getFloat32(offset, Endian.little) * resolution,
      'INT_16' => bd.getInt16(offset, Endian.little) * resolution,
      'UINT_16' => bd.getUint16(offset, Endian.little) * resolution,
      'INT_32' => bd.getInt32(offset, Endian.little) * resolution,
      _ => bd.getFloat32(offset, Endian.little) * resolution,
    };
  }
}
