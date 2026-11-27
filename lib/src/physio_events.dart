import 'dart:io';

import 'models.dart';

class PhysioEventOptions {
  const PhysioEventOptions({
    this.detectBlinks = true,
    this.detectEyeMovements = true,
    this.detectEmgSurges = true,
    this.detectEcg = true,
    this.detectArtifactBursts = false,
    this.blinkChannel = '',
    this.eogChannel = '',
    this.emgChannel = '',
    this.ecgChannel = '',
    this.eyeMovementZ = 3.5,
    this.emgZ = 3.5,
    this.emgMinDurationSec = 0.25,
    this.artifactZ = 5.0,
    this.artifactMinUv = 150.0,
  });

  final bool detectBlinks;
  final bool detectEyeMovements;
  final bool detectEmgSurges;
  final bool detectEcg;
  final bool detectArtifactBursts;
  final String blinkChannel;
  final String eogChannel;
  final String emgChannel;
  final String ecgChannel;
  final double eyeMovementZ;
  final double emgZ;
  final double emgMinDurationSec;
  final double artifactZ;
  final double artifactMinUv;

  bool get anyEnabled =>
      detectBlinks ||
      detectEyeMovements ||
      detectEmgSurges ||
      detectEcg ||
      detectArtifactBursts;

  Set<String> get selectedEventTypes => {
    if (detectBlinks) 'Physio/Blink',
    if (detectEyeMovements) 'Physio/EyeMovement',
    if (detectEmgSurges) 'Physio/EMG',
    if (detectEcg) 'Physio/ECG',
    if (detectArtifactBursts) 'Physio/Artifact',
  };

  PhysioEventOptions copyWith({
    bool? detectBlinks,
    bool? detectEyeMovements,
    bool? detectEmgSurges,
    bool? detectEcg,
    bool? detectArtifactBursts,
    String? blinkChannel,
    String? eogChannel,
    String? emgChannel,
    String? ecgChannel,
    double? eyeMovementZ,
    double? emgZ,
    double? emgMinDurationSec,
    double? artifactZ,
    double? artifactMinUv,
  }) => PhysioEventOptions(
    detectBlinks: detectBlinks ?? this.detectBlinks,
    detectEyeMovements: detectEyeMovements ?? this.detectEyeMovements,
    detectEmgSurges: detectEmgSurges ?? this.detectEmgSurges,
    detectEcg: detectEcg ?? this.detectEcg,
    detectArtifactBursts: detectArtifactBursts ?? this.detectArtifactBursts,
    blinkChannel: blinkChannel ?? this.blinkChannel,
    eogChannel: eogChannel ?? this.eogChannel,
    emgChannel: emgChannel ?? this.emgChannel,
    ecgChannel: ecgChannel ?? this.ecgChannel,
    eyeMovementZ: eyeMovementZ ?? this.eyeMovementZ,
    emgZ: emgZ ?? this.emgZ,
    emgMinDurationSec: emgMinDurationSec ?? this.emgMinDurationSec,
    artifactZ: artifactZ ?? this.artifactZ,
    artifactMinUv: artifactMinUv ?? this.artifactMinUv,
  );

  Map<String, dynamic> toJson() => {
    'detect_blinks': detectBlinks,
    'detect_eye_movements': detectEyeMovements,
    'detect_emg_surges': detectEmgSurges,
    'detect_ecg': detectEcg,
    'detect_artifact_bursts': detectArtifactBursts,
    'blink_channel': blinkChannel,
    'eog_channel': eogChannel,
    'emg_channel': emgChannel,
    'ecg_channel': ecgChannel,
    'eye_movement_z': eyeMovementZ,
    'emg_z': emgZ,
    'emg_min_duration_sec': emgMinDurationSec,
    'artifact_z': artifactZ,
    'artifact_min_uv': artifactMinUv,
  };

  factory PhysioEventOptions.fromJson(Map<String, dynamic> json) =>
      PhysioEventOptions(
        detectBlinks: json['detect_blinks'] as bool? ?? true,
        detectEyeMovements: json['detect_eye_movements'] as bool? ?? true,
        detectEmgSurges: json['detect_emg_surges'] as bool? ?? true,
        detectEcg: json['detect_ecg'] as bool? ?? true,
        detectArtifactBursts:
            json['detect_artifact_bursts'] as bool? ?? false,
        blinkChannel: json['blink_channel'] as String? ?? '',
        eogChannel: json['eog_channel'] as String? ?? '',
        emgChannel: json['emg_channel'] as String? ?? '',
        ecgChannel: json['ecg_channel'] as String? ?? '',
        eyeMovementZ: (json['eye_movement_z'] as num?)?.toDouble() ?? 3.5,
        emgZ: (json['emg_z'] as num?)?.toDouble() ?? 3.5,
        emgMinDurationSec:
            (json['emg_min_duration_sec'] as num?)?.toDouble() ?? 0.25,
        artifactZ: (json['artifact_z'] as num?)?.toDouble() ?? 5.0,
        artifactMinUv: (json['artifact_min_uv'] as num?)?.toDouble() ?? 150.0,
      );
}

class PhysioEventSummary {
  const PhysioEventSummary({
    required this.durationSeconds,
    required this.blinkCount,
    required this.blinkRatePerMin,
    this.blinkChannel,
    required this.eyeMovementCount,
    required this.eyeMovementRatePerMin,
    this.eyeMovementChannel,
    required this.emgSurgeCount,
    required this.emgSurgeRatePerMin,
    required this.emgBurdenPct,
    required this.emgMeanDurationSec,
    this.emgChannels = const [],
    required this.ecgRPeakCount,
    this.heartRateBpm,
    this.meanRrMs,
    this.sdnnMs,
    this.rmssdMs,
    this.ecgChannel,
    required this.artifactBurstCount,
    this.notes = const [],
  });

  final double durationSeconds;
  final int blinkCount;
  final double blinkRatePerMin;
  final String? blinkChannel;
  final int eyeMovementCount;
  final double eyeMovementRatePerMin;
  final String? eyeMovementChannel;
  final int emgSurgeCount;
  final double emgSurgeRatePerMin;
  final double emgBurdenPct;
  final double emgMeanDurationSec;
  final List<String> emgChannels;
  final int ecgRPeakCount;
  final double? heartRateBpm;
  final double? meanRrMs;
  final double? sdnnMs;
  final double? rmssdMs;
  final String? ecgChannel;
  final int artifactBurstCount;
  final List<String> notes;

  int get totalEvents =>
      blinkCount +
      eyeMovementCount +
      emgSurgeCount +
      ecgRPeakCount +
      artifactBurstCount;

  Map<String, dynamic> toJson() => {
    'duration_seconds': durationSeconds,
    'blink_count': blinkCount,
    'blink_rate_per_min': blinkRatePerMin,
    if (blinkChannel != null) 'blink_channel': blinkChannel,
    'eye_movement_count': eyeMovementCount,
    'eye_movement_rate_per_min': eyeMovementRatePerMin,
    if (eyeMovementChannel != null) 'eye_movement_channel': eyeMovementChannel,
    'emg_surge_count': emgSurgeCount,
    'emg_surge_rate_per_min': emgSurgeRatePerMin,
    'emg_burden_pct': emgBurdenPct,
    'emg_mean_duration_sec': emgMeanDurationSec,
    'emg_channels': emgChannels,
    'ecg_r_peak_count': ecgRPeakCount,
    if (heartRateBpm != null) 'heart_rate_bpm': heartRateBpm,
    if (meanRrMs != null) 'mean_rr_ms': meanRrMs,
    if (sdnnMs != null) 'sdnn_ms': sdnnMs,
    if (rmssdMs != null) 'rmssd_ms': rmssdMs,
    if (ecgChannel != null) 'ecg_channel': ecgChannel,
    'artifact_burst_count': artifactBurstCount,
    'notes': notes,
  };

  factory PhysioEventSummary.fromJson(Map<String, dynamic> json) =>
      PhysioEventSummary(
        durationSeconds:
            (json['duration_seconds'] as num?)?.toDouble() ?? 0.0,
        blinkCount: (json['blink_count'] as num?)?.toInt() ?? 0,
        blinkRatePerMin:
            (json['blink_rate_per_min'] as num?)?.toDouble() ?? 0.0,
        blinkChannel: json['blink_channel'] as String?,
        eyeMovementCount: (json['eye_movement_count'] as num?)?.toInt() ?? 0,
        eyeMovementRatePerMin:
            (json['eye_movement_rate_per_min'] as num?)?.toDouble() ?? 0.0,
        eyeMovementChannel: json['eye_movement_channel'] as String?,
        emgSurgeCount: (json['emg_surge_count'] as num?)?.toInt() ?? 0,
        emgSurgeRatePerMin:
            (json['emg_surge_rate_per_min'] as num?)?.toDouble() ?? 0.0,
        emgBurdenPct: (json['emg_burden_pct'] as num?)?.toDouble() ?? 0.0,
        emgMeanDurationSec:
            (json['emg_mean_duration_sec'] as num?)?.toDouble() ?? 0.0,
        emgChannels:
            (json['emg_channels'] as List?)?.cast<String>() ?? const [],
        ecgRPeakCount: (json['ecg_r_peak_count'] as num?)?.toInt() ?? 0,
        heartRateBpm: (json['heart_rate_bpm'] as num?)?.toDouble(),
        meanRrMs: (json['mean_rr_ms'] as num?)?.toDouble(),
        sdnnMs: (json['sdnn_ms'] as num?)?.toDouble(),
        rmssdMs: (json['rmssd_ms'] as num?)?.toDouble(),
        ecgChannel: json['ecg_channel'] as String?,
        artifactBurstCount:
            (json['artifact_burst_count'] as num?)?.toInt() ?? 0,
        notes: (json['notes'] as List?)?.cast<String>() ?? const [],
      );
}

class PhysioExtractionResult {
  const PhysioExtractionResult({
    required this.markers,
    required this.rawEvents,
    required this.summary,
  });

  final List<EegMarker> markers;
  final List<Map<String, dynamic>> rawEvents;
  final PhysioEventSummary summary;
}

/// Preserves all experimental/original markers while replacing any previously
/// auto-extracted `Physio/*` events in [replacedTypes], sorted chronologically.
List<EegMarker> mergePhysioMarkers(
  List<EegMarker> existing,
  List<EegMarker> extracted, {
  Set<String> replacedTypes = const {
    'Physio/Blink',
    'Physio/EyeMovement',
    'Physio/EMG',
    'Physio/ECG',
    'Physio/Artifact',
  },
}) {
  final merged = <EegMarker>[
    for (final m in existing)
      if (!replacedTypes.contains(m.type)) m,
    ...extracted,
  ];
  merged.sort((a, b) => a.startSeconds.compareTo(b.startSeconds));
  return merged;
}

/// EEGLAB `.evt` tab-separated text sidecar (type, latency in seconds, duration in seconds).
String formatEeglabEvtSidecar(List<EegMarker> markers) {
  final buf = StringBuffer()..writeln('type\tlatency\tduration');
  final sorted = List<EegMarker>.of(markers)
    ..sort((a, b) => a.startSeconds.compareTo(b.startSeconds));
  for (final m in sorted) {
    final label = m.label.replaceAll('\t', ' ').replaceAll('\n', ' ');
    buf.writeln(
      '$label\t${m.startSeconds.toStringAsFixed(4)}\t${m.durationSeconds.toStringAsFixed(4)}',
    );
  }
  return buf.toString();
}

Future<void> writeEeglabEvtSidecar(
  List<EegMarker> markers,
  String path,
) async {
  await File(path).writeAsString(formatEeglabEvtSidecar(markers));
}

/// BIDS `_events.tsv` compatible table including source channel and Z score.
String formatBidsEventsTsv(List<Map<String, dynamic>> events) {
  final buf = StringBuffer()
    ..writeln('onset\tduration\ttrial_type\tevent_group\tchannel\tscore');
  final sorted = List<Map<String, dynamic>>.of(events)
    ..sort(
      (a, b) => ((a['start_seconds'] as num?)?.toDouble() ?? 0.0).compareTo(
        (b['start_seconds'] as num?)?.toDouble() ?? 0.0,
      ),
    );
  for (final ev in sorted) {
    final onset = ((ev['start_seconds'] as num?)?.toDouble() ?? 0.0)
        .toStringAsFixed(4);
    final dur = ((ev['duration_seconds'] as num?)?.toDouble() ?? 0.0)
        .toStringAsFixed(4);
    final desc = '${ev['description'] ?? ev['type'] ?? 'Event'}'
        .replaceAll('\t', ' ');
    final group = '${ev['type'] ?? ''}'.replaceAll('\t', ' ');
    final ch = '${ev['channel'] ?? 'n/a'}'.replaceAll('\t', ' ');
    final score = ((ev['score'] as num?)?.toDouble() ?? 0.0).toStringAsFixed(2);
    buf.writeln('$onset\t$dur\t$desc\t$group\t$ch\t$score');
  }
  return buf.toString();
}

Future<void> writeBidsEventsTsv(
  List<Map<String, dynamic>> events,
  String path,
) async {
  await File(path).writeAsString(formatBidsEventsTsv(events));
}
