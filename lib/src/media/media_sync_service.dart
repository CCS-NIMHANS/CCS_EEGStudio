import 'dart:convert';
import 'dart:io';

import '../extraction_service.dart';
import '../models.dart';

class SyncedMediaSegment {
  SyncedMediaSegment({
    required this.path,
    required this.label,
    required this.isVideo,
    required this.offsetSeconds,
    required this.durationSeconds,
    this.extractedWavPath,
    this.timestampSource = 'manual/sequential',
    this.syncNote = '',
    this.waveformMin = const [],
    this.waveformMax = const [],
    this.envelopePreview = const [],
  });

  final String path;
  final String label;
  final bool isVideo;
  double offsetSeconds;
  final double durationSeconds;
  String? extractedWavPath;
  final String timestampSource;

  String? _alignmentOverride;

  /// Short label of how the clock alignment was obtained (file name, auto-aligned, manual…).
  String get alignmentSource => _alignmentOverride ?? timestampSource;
  set alignmentSource(String v) => _alignmentOverride = v;

  /// How the alignment was obtained, e.g. "start time from file name" or
  /// "auto-aligned to video audio (r=0.62, z=11)". Shown next to the envelope.
  String syncNote;
  List<double> waveformMin;
  List<double> waveformMax;
  List<double> envelopePreview;

  String? get audioPath => isVideo ? extractedWavPath : path;

  /// Where the audio shown in the waveform/envelope really comes from.
  String get audioSourceKind => isVideo ? 'Video audio track' : 'Audio file';

  String get audioSourceDescription =>
      isVideo ? '$audioSourceKind · $label (extracted 16 kHz mono WAV)' : '$audioSourceKind · $label';
}

class AudioEnvelopeData {
  const AudioEnvelopeData({
    required this.sampleRate,
    required this.durationSeconds,
    required this.displayMin,
    required this.displayMax,
    required this.envelopePreview,
  });

  final double sampleRate;
  final double durationSeconds;
  final List<double> displayMin;
  final List<double> displayMax;
  final List<double> envelopePreview;
}

class SpeechTrackingChannelResult {
  const SpeechTrackingChannelResult({
    required this.channel,
    required this.xcorrPeakR,
    required this.xcorrPeakLagMs,
    required this.trfEncodingR,
    required this.trfWeights,
    required this.deltaCoherence,
    required this.thetaCoherence,
  });

  final String channel;
  final double xcorrPeakR;
  final double xcorrPeakLagMs;
  final double trfEncodingR;
  final List<double> trfWeights;
  final double deltaCoherence;
  final double thetaCoherence;
}

/// Time-resolved speech tracking (sliding window). [timesSec] are window
/// centres in seconds on the EEG recording's own clock.
class SpeechTrackingSeries {
  const SpeechTrackingSeries({
    required this.windowSeconds,
    required this.timesSec,
    required this.decoderR,
    required this.encodingR,
    required this.decoderNull95,
    required this.encodingNull95,
  });

  final double windowSeconds;
  final List<double> timesSec;
  final List<double> decoderR;
  final List<double> encodingR;
  final double decoderNull95;
  final double encodingNull95;
}

class SpeechTrackingSummary {
  const SpeechTrackingSummary({
    required this.trackingRateHz,
    required this.overlapSeconds,
    required this.lagTimesMs,
    required this.decoderReconstructionR,
    required this.decoderPApprox,
    required this.bestChannel,
    required this.bestEncodingR,
    required this.channels,
    this.series,
  });

  final SpeechTrackingSeries? series;
  final double trackingRateHz;
  final double overlapSeconds;
  final List<double> lagTimesMs;
  final double decoderReconstructionR;
  final double decoderPApprox;
  final String bestChannel;
  final double bestEncodingR;
  final List<SpeechTrackingChannelResult> channels;
}

/// Timestamp parsing, video audio extraction, waveform/envelope extraction,
/// and Neural Speech Tracking bridge.
class MediaSyncService {
  static const videoExtensions = {
    'mp4', 'mov', 'mkv', 'avi', 'webm', 'm2t', 'ts', 'mts', 'm2ts', 'mpg', 'mpeg', 'wmv',
  };
  static const audioExtensions = {'wav', 'mp3', 'm4a', 'aac', 'flac', 'ogg'};

  static bool isVideoPath(String path) {
    final ext = path.split('.').last.toLowerCase();
    return videoExtensions.contains(ext);
  }

  static String? findTool(String name) {
    final candidates = Platform.isWindows
        ? ['$name.exe', 'C:\\ffmpeg\\bin\\$name.exe']
        : ['/opt/homebrew/bin/$name', '/usr/local/bin/$name', '/usr/bin/$name', name];
    for (final c in candidates) {
      if (c == name || c == '$name.exe') return c;
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  /// Normalised recording identity shared by the raw recording, its cleaned
  /// copy and the `.features.csv` derived from it.
  static String stemKey(String path) {
    var n = path.split(RegExp(r'[\\/]')).last.toLowerCase();
    for (final suf in const [
      '.features.csv', '.ccseeg.json', '.ccseeg', '.vhdr', '.vmrk', '.eeg',
      '.edf', '.fif', '.set', '.mat', '.xdf', '.csv', '.json',
    ]) {
      if (n.endsWith(suf)) {
        n = n.substring(0, n.length - suf.length);
        break;
      }
    }
    return n.replaceAll(RegExp(r'(_clean|_cleaned|_preprocessed|_preproc)+$'), '');
  }

  /// BrainVision `Mk1=New Segment,,1,1,0,YYYYMMDDhhmmssuuuuuu` -> local clock time.
  /// (The previous pattern was one comma short and never matched real files.)
  static DateTime? parseVmrkStart(String text) {
    final m = RegExp(r'New Segment[^\r\n]*?,(\d{14})(\d{0,6})\s*$', multiLine: true)
        .firstMatch(text);
    if (m == null) return null;
    final s = m.group(1)!;
    final us = int.tryParse((m.group(2) ?? '').padRight(6, '0')) ?? 0;
    return DateTime(
      int.parse(s.substring(0, 4)),
      int.parse(s.substring(4, 6)),
      int.parse(s.substring(6, 8)),
      int.parse(s.substring(8, 10)),
      int.parse(s.substring(10, 12)),
      int.parse(s.substring(12, 14)),
      0,
      us,
    );
  }

  static const _recordingExts = ['.ccseeg', '.edf', '.fif', '.set', '.vhdr', '.eeg', '.mat'];

  /// Finds the cleaned recording that a `<name>.features.csv` was computed from.
  static String? findRecordingForFeatures(String featuresCsv) {
    if (!featuresCsv.toLowerCase().endsWith('.features.csv')) {
      return File(featuresCsv).existsSync() ? featuresCsv : null;
    }
    final base = featuresCsv.substring(0, featuresCsv.length - '.features.csv'.length);
    for (final ext in _recordingExts) {
      if (File('$base$ext').existsSync()) return '$base$ext';
    }
    return null;
  }

  /// Tracking requires EEG samples, including for a controller seeded by a CSV.
  static String trackingRecordingPath(String path) {
    final recording = findRecordingForFeatures(path);
    if (recording == null || recording.toLowerCase().endsWith('.csv')) {
      throw StateError('EEG samples are required for speech tracking. Keep the cleaned recording next to its feature CSV, or open the EEG recording first.');
    }
    return recording;
  }

  /// Resolves the absolute (local wall-clock) start time of an EEG recording,
  /// its cleaned copy, or a feature CSV. Follows `.ccshistory` `source_path`
  /// links back to the original BrainVision file. Returns the time and how it
  /// was obtained; never guesses from file modification times.
  static Future<(DateTime?, String)> resolveStartForPath(
    String path, {
    int depth = 0,
    List<String> extraRoots = const [],
  }) async {
    if (depth > 6) return (null, 'unknown');
    final lower = path.toLowerCase();

    // 1. BrainVision marker file next to / derived from this path
    final vmrkCandidates = <String>[];
    if (lower.endsWith('.vhdr')) {
      vmrkCandidates.add(path.replaceFirst(RegExp(r'\.vhdr$', caseSensitive: false), '.vmrk'));
    } else if (lower.endsWith('.vmrk')) {
      vmrkCandidates.add(path);
    } else if (lower.endsWith('.eeg')) {
      vmrkCandidates.add(path.replaceFirst(RegExp(r'\.eeg$', caseSensitive: false), '.vmrk'));
    }
    for (final c in vmrkCandidates) {
      final f = File(c);
      if (await f.exists()) {
        try {
          final dt = parseVmrkStart(await f.readAsString());
          if (dt != null) return (dt, 'EEG marker file (.vmrk New Segment)');
        } catch (_) {}
      }
    }

    // 2. Cleaned recording / feature CSV: sidecar provenance
    final rec = lower.endsWith('.features.csv') ? findRecordingForFeatures(path) : path;
    for (final base in <String>{path, ?rec}) {
      for (final sc in ['$base.ccshistory', '$base.ccsmeta', '$base.json.ccshistory']) {
        final f = File(sc);
        if (!await f.exists()) continue;
        try {
          final meta = jsonDecode(await f.readAsString());
          if (meta is! Map) continue;
          final iso = _findIso(meta, 0);
          if (iso != null) {
            final dt = DateTime.tryParse(iso);
            if (dt != null) return (dt, 'recorded start in processing history');
          }
          final src = meta['source_path'];
          if (src is String && src != path && File(src).existsSync()) {
            final r = await resolveStartForPath(src, depth: depth + 1);
            if (r.$1 != null) return r;
          }
        } catch (_) {}
      }
    }

    // 3. Full date+time in the file name (YYYYMMDD_HHMMSS etc.)
    final fromName = parseTimestampFromFilename(path);
    if (fromName != null) return (fromName, 'file name');

    // 4. Last resort: find the original BrainVision .vmrk with the same recording
    //    name in nearby folders (cleaned files are often moved away from the raw data).
    if (depth == 0) {
      final key = stemKey(path);
      final roots = <String>[
        ..._ancestors(path, 3),
        for (final e in extraRoots) ..._ancestors(e, 3),
      ];
      final f = await _findVmrkByStem(key, roots);
      if (f != null) {
        try {
          final dt = parseVmrkStart(await f.readAsString());
          if (dt != null) {
            return (dt, 'matching EEG marker file ${f.path.split(RegExp(r'[\\/]')).last}');
          }
        } catch (_) {}
      }
    }
    return (null, 'unknown');
  }

  static List<String> _ancestors(String path, int levels) {
    final out = <String>[];
    var dir = File(path).parent;
    for (var i = 0; i < levels; i++) {
      out.add(dir.path);
      final up = dir.parent;
      if (up.path == dir.path) break;
      dir = up;
    }
    return out;
  }

  static Future<File?> _findVmrkByStem(String key, Iterable<String> roots) async {
    final seen = <String>{};
    var budget = 20000;
    for (final root in roots) {
      final queue = <(Directory, int)>[(Directory(root), 0)];
      while (queue.isNotEmpty && budget > 0) {
        final (dir, depth) = queue.removeAt(0);
        if (!seen.add(dir.path)) continue;
        try {
          await for (final e in dir.list(followLinks: false)) {
            budget--;
            final name = e.path.split(RegExp(r'[\\/]')).last;
            if (name.startsWith('.')) continue;
            if (e is File && name.toLowerCase().endsWith('.vmrk') && stemKey(e.path) == key) {
              return e;
            }
            if (e is Directory && depth < 4) queue.add((e, depth + 1));
          }
        } catch (_) {}
      }
    }
    return null;
  }

  static String? _findIso(Map meta, int depth) {
    if (depth > 8) return null;
    final v = meta['recording_start_iso'];
    if (v is String && v.isNotEmpty) return v;
    for (final k in ['provenance', 'parent_provenance']) {
      final c = meta[k];
      if (c is Map) {
        final r = _findIso(c, depth + 1);
        if (r != null) return r;
      }
    }
    return null;
  }

  /// Resolves the EEG recording start timestamp (see [resolveStartForPath]).
  static Future<DateTime?> resolveEegStartTime(EegRecording rec) async {
    final iso = rec.provenance['recording_start_iso'] as String?;
    if (iso != null) {
      final dt = DateTime.tryParse(iso);
      if (dt != null) return dt;
    }
    final nested = _findIso(rec.provenance, 0);
    if (nested != null) {
      final dt = DateTime.tryParse(nested);
      if (dt != null) return dt;
    }
    return (await resolveStartForPath(rec.path)).$1;
  }

  static DateTime? parseTimestampFromFilename(String path) {
    final name = path.split(RegExp(r'[\\/]')).last;
    final ymdHms = RegExp(r'(\d{4})[-_]?(\d{2})[-_]?(\d{2})[-_ T](\d{2})[-_:]?(\d{2})[-_:]?(\d{2})')
        .firstMatch(name);
    if (ymdHms != null) {
      return DateTime.tryParse(
        '${ymdHms[1]}-${ymdHms[2]}-${ymdHms[3]}T${ymdHms[4]}:${ymdHms[5]}:${ymdHms[6]}',
      );
    }
    return null;
  }

  /// Returns (start, duration, source). The clock of a recording is the *local
  /// wall clock of the recording computer*, the same domain as the EEG's
  /// BrainVision timestamp. OBS-style file names carry exactly that, so they
  /// win over the container's UTC `creation_time` (which is only correct if
  /// this computer is in the recording time zone). File modification times
  /// are never used: they reflect file copies, not recording time.
  static Future<(DateTime?, double, String)> probeMediaMetadata(String path) async {
    double duration = 0.0;
    DateTime? metaStart;
    String metaSource = '';

    final ffprobe = findTool('ffprobe');
    if (ffprobe != null) {
      try {
        final res = await Process.run(ffprobe, [
          '-v', 'quiet',
          '-print_format', 'json',
          '-show_format',
          path,
        ]);
        if (res.exitCode == 0) {
          final json = jsonDecode(res.stdout.toString()) as Map<String, dynamic>;
          final fmt = json['format'] as Map<String, dynamic>?;
          duration = double.tryParse('${fmt?['duration'] ?? ''}') ?? 0.0;
          final tags = fmt?['tags'] as Map<String, dynamic>?;
          final ct = tags?['creation_time'] as String?;
          if (ct != null) {
            metaStart = DateTime.tryParse(ct)?.toLocal();
            if (metaStart != null) metaSource = 'container creation_time (UTC→local)';
          }
        }
      } catch (_) {}
    }

    final fromName = parseTimestampFromFilename(path);
    if (fromName != null) return (fromName, duration, 'file name (recording-site local clock)');
    if (metaStart != null) return (metaStart, duration, metaSource);
    return (null, duration, 'no timestamp');
  }

  /// Aligns [targetWav] to [referenceWav] by speech-envelope cross-correlation.
  /// `lagSeconds` is the start of the target on the reference timeline.
  static Future<({double lagSeconds, double peakR, double confidence})> alignAudio({
    required String referenceWav,
    required String targetWav,
    double maxLagSeconds = 900.0,
  }) async {
    final exe = ExtractionService.findEngine();
    final temp = await Directory.systemTemp.createTemp('ccs_eeg_align_');
    try {
      final jobFile = File('${temp.path}${Platform.pathSeparator}align.json');
      await jobFile.writeAsString(jsonEncode({
        'job_type': 'align_audio',
        'reference': referenceWav,
        'target': targetWav,
        'max_lag_seconds': maxLagSeconds,
      }));
      final res = await Process.run(exe, [jobFile.path]);
      if (res.exitCode != 0) {
        throw StateError('Audio alignment failed: ${res.stderr}');
      }
      final d = jsonDecode(res.stdout.toString().trim()) as Map<String, dynamic>;
      return (
        lagSeconds: (d['lag_seconds'] as num).toDouble(),
        peakR: (d['peak_r'] as num).toDouble(),
        confidence: (d['confidence'] as num).toDouble(),
      );
    } finally {
      try {
        await temp.delete(recursive: true);
      } catch (_) {}
    }
  }

  static Future<String> ensureWavAudio(String mediaPath) async {
    if (mediaPath.toLowerCase().endsWith('.wav')) return mediaPath;
    final ffmpeg = findTool('ffmpeg');
    if (ffmpeg == null) {
      throw StateError(
        'ffmpeg is required to extract audio from ${mediaPath.split(RegExp(r"[\\/]")).last}.',
      );
    }
    final tempDir = await Directory.systemTemp.createTemp('ccs_eeg_audio_');
    final stem = mediaPath.split(RegExp(r'[\\/]')).last.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final outWav = '${tempDir.path}${Platform.pathSeparator}$stem.wav';
    final res = await Process.run(ffmpeg, [
      '-y',
      '-i', mediaPath,
      '-vn',
      '-ac', '1',
      '-ar', '16000',
      '-f', 'wav',
      outWav,
    ]);
    if (res.exitCode != 0 || !await File(outWav).exists()) {
      throw StateError('Audio extraction failed: ${res.stderr}');
    }
    return outWav;
  }

  static Future<AudioEnvelopeData> extractEnvelope(
    String wavPath, {
    double targetRate = 100.0,
    int bins = 2000,
  }) async {
    final exe = ExtractionService.findEngine();
    final temp = await Directory.systemTemp.createTemp('ccs_eeg_env_');
    try {
      final jobFile = File('${temp.path}${Platform.pathSeparator}env.json');
      await jobFile.writeAsString(jsonEncode({
        'job_type': 'extract_audio_envelope',
        'input': wavPath,
        'target_rate': targetRate,
        'n_display_bins': bins,
      }));
      final res = await Process.run(exe, [jobFile.path]);
      if (res.exitCode != 0) {
        throw StateError('Audio envelope extraction failed: ${res.stderr}');
      }
      final data = jsonDecode(res.stdout.toString().trim()) as Map<String, dynamic>;
      return AudioEnvelopeData(
        sampleRate: (data['sample_rate'] as num).toDouble(),
        durationSeconds: (data['duration_seconds'] as num).toDouble(),
        displayMin: [for (final v in data['display_min'] as List) (v as num).toDouble()],
        displayMax: [for (final v in data['display_max'] as List) (v as num).toDouble()],
        envelopePreview: [for (final v in data['envelope_preview'] as List) (v as num).toDouble()],
      );
    } finally {
      try {
        await temp.delete(recursive: true);
      } catch (_) {}
    }
  }

  static SpeechTrackingSeries? _parseSeries(dynamic j) {
    if (j is! Map) return null;
    List<double> l(String k) => [for (final v in (j[k] as List)) (v as num).toDouble()];
    return SpeechTrackingSeries(
      windowSeconds: (j['window_seconds'] as num).toDouble(),
      timesSec: l('times_sec'),
      decoderR: l('decoder_r'),
      encodingR: l('encoding_r'),
      decoderNull95: (j['decoder_null95'] as num).toDouble(),
      encodingNull95: (j['encoding_null95'] as num).toDouble(),
    );
  }

  static Future<SpeechTrackingSummary> runSpeechTracking({
    required String eegPath,
    required String wavPath,
    double audioOffsetSeconds = 0.0,
    double tminMs = -100.0,
    double tmaxMs = 450.0,
    double ridgeLambda = 100.0,
    double windowSeconds = 20.0,
    double stepSeconds = 5.0,
    List<String>? channels,
  }) async {
    final exe = ExtractionService.findEngine();
    final temp = await Directory.systemTemp.createTemp('ccs_eeg_trf_');
    try {
      final jobFile = File('${temp.path}${Platform.pathSeparator}trf.json');
      await jobFile.writeAsString(jsonEncode({
        'job_type': 'speech_tracking',
        'eeg_path': trackingRecordingPath(eegPath),
        'audio_wav_path': wavPath,
        'audio_offset_seconds': audioOffsetSeconds,
        'tmin_ms': tminMs,
        'tmax_ms': tmaxMs,
        'ridge_lambda': ridgeLambda,
        'window_seconds': windowSeconds,
        'step_seconds': stepSeconds,
        if (channels != null && channels.isNotEmpty) 'channels': channels,
      }));
      final res = await Process.run(exe, [jobFile.path]);
      if (res.exitCode != 0) {
        throw StateError('Neural Speech Tracking failed: ${res.stderr}');
      }
      final data = jsonDecode(res.stdout.toString().trim()) as Map<String, dynamic>;
      return SpeechTrackingSummary(
        trackingRateHz: (data['tracking_rate_hz'] as num).toDouble(),
        overlapSeconds: (data['overlap_seconds'] as num).toDouble(),
        lagTimesMs: [for (final v in data['lag_times_ms'] as List) (v as num).toDouble()],
        decoderReconstructionR: (data['decoder_reconstruction_r'] as num).toDouble(),
        decoderPApprox: (data['decoder_p_approx'] as num).toDouble(),
        bestChannel: data['best_channel'] as String,
        bestEncodingR: (data['best_encoding_r'] as num).toDouble(),
        series: _parseSeries(data['tracking_series']),
        channels: [
          for (final c in data['channels'] as List)
            SpeechTrackingChannelResult(
              channel: c['channel'] as String,
              xcorrPeakR: (c['xcorr_peak_r'] as num).toDouble(),
              xcorrPeakLagMs: (c['xcorr_peak_lag_ms'] as num).toDouble(),
              trfEncodingR: (c['trf_encoding_r'] as num).toDouble(),
              trfWeights: [for (final w in c['trf_weights'] as List) (w as num).toDouble()],
              deltaCoherence: (c['delta_coherence'] as num).toDouble(),
              thetaCoherence: (c['theta_coherence'] as num).toDouble(),
            ),
        ],
      );
    } finally {
      try {
        await temp.delete(recursive: true);
      } catch (_) {}
    }
  }
}
