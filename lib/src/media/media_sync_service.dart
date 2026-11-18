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
  List<double> waveformMin;
  List<double> waveformMax;
  List<double> envelopePreview;

  String? get audioPath => isVideo ? extractedWavPath : path;
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
  });

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

  /// Resolves the EEG recording start timestamp from metadata (.vmrk / provenance)
  /// or filename patterns (YYYYMMDD_HHMMSS / DD.MM.YYYY).
  static Future<DateTime?> resolveEegStartTime(EegRecording rec) async {
    final iso = rec.provenance['recording_start_iso'] as String?;
    if (iso != null) {
      final dt = DateTime.tryParse(iso);
      if (dt != null) return dt;
    }
    if (rec.path.toLowerCase().endsWith('.vhdr')) {
      final vmrk = File(rec.path.replaceFirst(RegExp(r'\.vhdr$', caseSensitive: false), '.vmrk'));
      if (await vmrk.exists()) {
        try {
          final text = await vmrk.readAsString();
          final m = RegExp(r'New Segment[^,\n]*,[^,\n]*,[^,\n]*,[^,\n]*,(\d{14})').firstMatch(text);
          if (m != null) {
            final s = m.group(1)!;
            return DateTime(
              int.parse(s.substring(0, 4)),
              int.parse(s.substring(4, 6)),
              int.parse(s.substring(6, 8)),
              int.parse(s.substring(8, 10)),
              int.parse(s.substring(10, 12)),
              int.parse(s.substring(12, 14)),
            );
          }
        } catch (_) {}
      }
    }
    final fromName = parseTimestampFromFilename(rec.path);
    if (fromName != null) return fromName;
    try {
      final f = File(rec.path);
      if (await f.exists()) {
        final stat = await f.stat();
        return stat.modified.subtract(
          Duration(milliseconds: (rec.durationSeconds * 1000).round()),
        );
      }
    } catch (_) {}
    return null;
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

  static Future<(DateTime?, double, String)> probeMediaMetadata(String path) async {
    double duration = 0.0;
    DateTime? metaStart;
    String source = 'sequential';

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
            if (metaStart != null) source = 'metadata (creation_time)';
          }
        }
      } catch (_) {}
    }

    if (metaStart == null) {
      metaStart = parseTimestampFromFilename(path);
      if (metaStart != null) source = 'filename';
    }
    if (metaStart == null) {
      try {
        final f = File(path);
        if (await f.exists()) {
          final stat = await f.stat();
          metaStart = duration > 0
              ? stat.modified.subtract(Duration(milliseconds: (duration * 1000).round()))
              : stat.modified;
          source = 'file mtime';
        }
      } catch (_) {}
    }
    return (metaStart, duration, source);
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

  static Future<SpeechTrackingSummary> runSpeechTracking({
    required String eegPath,
    required String wavPath,
    double audioOffsetSeconds = 0.0,
    double tminMs = -100.0,
    double tmaxMs = 450.0,
    double ridgeLambda = 100.0,
    List<String>? channels,
  }) async {
    final exe = ExtractionService.findEngine();
    final temp = await Directory.systemTemp.createTemp('ccs_eeg_trf_');
    try {
      final jobFile = File('${temp.path}${Platform.pathSeparator}trf.json');
      await jobFile.writeAsString(jsonEncode({
        'job_type': 'speech_tracking',
        'eeg_path': eegPath,
        'audio_wav_path': wavPath,
        'audio_offset_seconds': audioOffsetSeconds,
        'tmin_ms': tminMs,
        'tmax_ms': tmaxMs,
        'ridge_lambda': ridgeLambda,
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
