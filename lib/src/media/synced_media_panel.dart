import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'media_sync_service.dart';

/// Describes the actual engine evaluation, including its interpretation limits.
class SpeechTrackingMethod extends StatelessWidget {
  const SpeechTrackingMethod({super.key});
  @override
  Widget build(BuildContext context) => TextButton.icon(
    icon: const Icon(Icons.info_outline, size: 16),
    label: const Text('How speech tracking is computed', style: TextStyle(fontSize: 12)),
    onPressed: () => showDialog<void>(context: context, builder: (context) => AlertDialog(
      title: const Text('How speech tracking is computed'),
      scrollable: true,
      content: const SizedBox(width: 620, child: Text(
      'Training: the overlapping EEG/audio recording is divided into 5 contiguous folds. '
      'Each fold is predicted using ridge/TRF weights trained on the other four. '
      'The decoder reconstructs the amplitude envelope from up to 16 EEG channels (0–250 ms lags); '
      'the forward TRF predicts each EEG channel from the envelope (−100 to 450 ms lags). '
      'Signals are resampled to 64 Hz (or the available lower EEG rate).\n\n'
      'Time course: Pearson r is evaluated in 20-second moving windows, every 5 seconds, '
      'using these held-out predictions. The model is not retrained in each moving window. '
      'The forward curve averages channel correlations. Dashed lines are pooled 95th-percentile '
      'circular-shift null thresholds, not correction for testing many windows.\n\n'
      'Silence is included: there is no speech detector or voice-activity mask. '
      'Near-constant audio makes correlations unstable; background noise, movement and shared '
      'slow trends can also affect r. A peak is not evidence of speech presence or attention, '
      'and a drop does not establish loss of attention or explain delta power. '
      'Check audio, alignment and EEG artifacts before interpreting either curve.',
      style: TextStyle(fontSize: 12),
    )),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
    )),
  );
}

/// Master controller syncing timestamped video/audio files, the extracted
/// audio waveform + envelope, Neural Speech Tracking and the EEG/feature plots.
///
/// All clocks meet on one **wall-clock timeline** (seconds since the Unix epoch,
/// in the recording site's local clock): every EEG session (raw, cleaned or
/// feature CSV, matched by [MediaSyncService.stemKey]) has a start time, and every
/// media segment has a start time. The cursor is a single epoch value, so a
/// click on any session's plot, the video position and the audio strip always
/// refer to the same instant, even when a plot shows several recordings.
class MediaSyncController extends ChangeNotifier {
  MediaSyncController({
    required this.eegPath,
    required this.eegDurationSec,
    this.eegStartTime,
    this.onTimeChanged,
  }) {
    _primaryKey = MediaSyncService.stemKey(eegPath);
    _cursorEpoch = primaryStartEpoch;
    _player = Player();
    _videoController = VideoController(
      _player,
      configuration: VideoControllerConfiguration(
        enableHardwareAcceleration: true,
      ),
    );
    _posSub = _player.stream.position.listen(_onPlayerPosition);
    _playSub = _player.stream.playing.listen((p) {
      if (_playing != p) {
        _playing = p;
        notifyListeners();
      }
    });
    _doneSub = _player.stream.completed.listen((done) {
      if (done) unawaited(_onCompleted());
    });
    _errorSub = _player.stream.error.listen((error) { _status = 'Playback error: $error'; notifyListeners(); });
  }

  bool _disposed = false;
  @override
  void notifyListeners() { if (!_disposed) super.notifyListeners(); }

  final String eegPath;
  final double eegDurationSec;
  final DateTime? eegStartTime;
  void Function(double eegSec)? onTimeChanged;

  late final String _primaryKey;
  late final Player _player;
  late final VideoController _videoController;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<bool>? _playSub;
  StreamSubscription<bool>? _doneSub;
  StreamSubscription<String>? _errorSub;

  final List<SyncedMediaSegment> segments = [];
  final Map<String, double> _sessionStart = {};
  final Set<String> _sessionPending = {};
  final Map<String, String> sessionStartSource = {};
  final Map<String, String> _sessionPaths = {};
  final Map<String, SpeechTrackingSummary> _tracking = {};

  int _activeIndex = -1;
  double _cursorEpoch = 0.0;
  DateTime _lastSeek = DateTime.fromMillisecondsSinceEpoch(0);
  bool _outOfRange = false;
  bool _playing = false;
  bool _muted = false;
  double _rate = 1.0;
  bool _busy = false;
  bool _trackingBusy = false;
  String? _status;

  VideoController get videoController => _videoController;

  /// Epoch seconds of the primary EEG's first sample (0 when its clock is unknown).
  double get primaryStartEpoch =>
      (eegStartTime?.microsecondsSinceEpoch ?? 0) / 1e6;
  bool get primaryClockKnown => eegStartTime != null;

  double get cursorEpoch => _cursorEpoch;

  /// Cursor expressed on the primary EEG's own time axis (seconds).
  double get eegSec => _cursorEpoch - primaryStartEpoch;
  bool get playing => _playing;
  bool get muted => _muted;
  double get playbackRate => _rate;
  bool get busy => _busy;
  bool get trackingBusy => _trackingBusy;
  bool get outOfRange => _outOfRange;
  String? get status => _status;
  SyncedMediaSegment? get activeSegment =>
      (_activeIndex >= 0 && _activeIndex < segments.length)
          ? segments[_activeIndex]
          : null;

  double segmentStartEpoch(SyncedMediaSegment s) => primaryStartEpoch + s.offsetSeconds;
  double segmentEndEpoch(SyncedMediaSegment s) => segmentStartEpoch(s) + s.durationSeconds;

  // ── Sessions (EEG recordings shown in plots) ───────────────────────────

  /// Resolves and remembers the wall-clock start of the recording behind
  /// [path] (a recording or `.features.csv`). Safe to call repeatedly.
  Future<void> registerSessionPath(String path) async {
    final key = MediaSyncService.stemKey(path);
    _sessionPaths[key] = path;
    if (key == _primaryKey || _sessionStart.containsKey(key)) return;
    if (!_sessionPending.add(key)) return;
    try {
      final (dt, src) = await MediaSyncService.resolveStartForPath(
        path,
        extraRoots: [for (final s in segments) s.path],
      );
      sessionStartSource[key] = src;
      if (dt != null) {
        _sessionStart[key] = dt.microsecondsSinceEpoch / 1e6;
        notifyListeners();
      }
    } finally {
      _sessionPending.remove(key);
    }
  }

  /// Epoch start of the session behind [path], or null if its clock is unknown.
  double? sessionStartEpoch(String path) {
    final key = MediaSyncService.stemKey(path);
    if (key == _primaryKey) return primaryStartEpoch;
    return _sessionStart[key];
  }

  /// Cursor on [path]'s own time axis (seconds), or null when unknown.
  double? sessionLocalSec(String path) {
    final st = sessionStartEpoch(path);
    return st == null ? null : _cursorEpoch - st;
  }

  Future<void> seekToSessionTime(String path, double sec) async {
    final st = sessionStartEpoch(path);
    if (st == null) return;
    await seekToEpoch(st + sec, notifyExternal: true);
  }

  /// Media segments placed on [path]'s time axis: `startSec` is where each
  /// segment begins relative to that recording's first sample.
  List<({SyncedMediaSegment seg, double startSec})> segmentsForSession(String path) {
    final st = sessionStartEpoch(path);
    if (st == null) return const [];
    return [
      for (final s in segments)
        (seg: s, startSec: segmentStartEpoch(s) - st),
    ];
  }

  SpeechTrackingSummary? trackingFor(String path) =>
      _tracking[MediaSyncService.stemKey(path)];

  // ── Loading media ──────────────────────────────────────────────────────

  Future<void> addMediaFiles(List<String> paths) async {
    _busy = true;
    _status = 'Probing media timestamps & extracting waveform/envelope…';
    notifyListeners();
    final problems = <String>[];
    try {
      // Videos first: audio-only files without a clock are auto-aligned to them.
      final ordered = [...paths]..sort((a, b) {
          final av = MediaSyncService.isVideoPath(a) ? 0 : 1;
          final bv = MediaSyncService.isVideoPath(b) ? 0 : 1;
          return av.compareTo(bv);
        });
      for (final path in ordered) {
        try {
          await _addOne(path);
        } catch (e) {
          problems.add('${path.split(RegExp(r'[\\/]')).last}: $e');
        }
      }
      segments.sort((a, b) => a.offsetSeconds.compareTo(b.offsetSeconds));
      _activeIndex = -1;
      if (segments.isNotEmpty && _indexCovering(_cursorEpoch) < 0) {
        // Park the cursor where the media is: inside the primary EEG if they overlap.
        final first = segments.first;
        final lo = primaryStartEpoch;
        final hi = primaryStartEpoch + eegDurationSec;
        final s0 = segmentStartEpoch(first);
        _cursorEpoch = (s0 >= lo && s0 <= hi) ? s0 : s0.clamp(lo, hi).toDouble();
        if (_indexCovering(_cursorEpoch) < 0) _cursorEpoch = s0;
      }
      await seekToEpoch(_cursorEpoch, notifyExternal: true);
      // Recordings whose clock was unknown may now be found next to the media.
      for (final p in _sessionPaths.values.toList()) {
        if (sessionStartEpoch(p) == null) await registerSessionPath(p);
      }
      _status = problems.isEmpty
          ? '${segments.length} synced media file(s) ready'
          : 'Media load warning: ${problems.join(' | ')}';
    } catch (e) {
      _status = 'Media load warning: $e';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> _addOne(String path) async {
    final label = path.split(RegExp(r'[\\/]')).last;
    final isVid = MediaSyncService.isVideoPath(path);
    final (startDt, probedDur, tsSource) = await MediaSyncService.probeMediaMetadata(path);
    String? wavPath;
    var envMin = const <double>[];
    var envMax = const <double>[];
    var envPreview = const <double>[];
    var envDur = 0.0;
    var extraNote = '';
    try {
      wavPath = await MediaSyncService.ensureWavAudio(path);
    } catch (e) {
      if (MediaSyncService.findTool('ffmpeg') == null &&
          !path.toLowerCase().endsWith('.wav')) {
        extraNote =
            'Playback ready (install ffmpeg or place ffmpeg.exe next to the app '
            'to enable waveform/envelope & Speech Tracking for compressed media; '
            '.wav works without ffmpeg).';
      } else {
        rethrow;
      }
    }
    if (wavPath != null) {
      try {
        final env = await MediaSyncService.extractEnvelope(wavPath);
        envMin = env.displayMin;
        envMax = env.displayMax;
        envPreview = env.envelopePreview;
        envDur = env.durationSeconds;
      } catch (e) {
        if (extraNote.isEmpty) {
          extraNote = 'Playback ready (waveform/envelope unavailable: $e).';
        }
      }
    }
    final dur = probedDur > 0 ? probedDur : envDur;

    double? offset;
    var source = tsSource;
    var note = '';
    if (startDt != null && eegStartTime != null) {
      final diff = startDt.difference(eegStartTime!).inMicroseconds / 1e6;
      if (diff.abs() < 24 * 3600) {
        offset = diff;
        note = 'media starts ${diff >= 0 ? '+' : '−'}${diff.abs().toStringAsFixed(1)} s '
            'relative to this EEG (from $tsSource)';
      } else {
        source = 'implausible timestamp';
        note = 'timestamp is more than 24 h from this EEG and was ignored';
      }
    } else if (startDt != null) {
      note = 'EEG start time unknown, so the media clock could not be applied';
    }
    if (extraNote.isNotEmpty) {
      note = note.isEmpty ? extraNote : '$note. $extraNote';
    }

    final seg = SyncedMediaSegment(
      path: path,
      label: label,
      isVideo: isVid,
      offsetSeconds: offset ?? 0.0,
      durationSeconds: dur,
      extractedWavPath: isVid ? wavPath : null,
      timestampSource: source,
      syncNote: note,
      waveformMin: envMin,
      waveformMax: envMax,
      envelopePreview: envPreview,
    );

    final saved = await MediaSyncService.loadSyncOffset(
      mediaPath: path,
      eegKey: _primaryKey,
    );
    if (saved != null) {
      seg.offsetSeconds = saved.offsetSeconds;
      seg.alignmentSource = 'saved sync';
      final savedNote =
          'Restored saved sync (${saved.alignmentSource}): media starts '
          '${saved.offsetSeconds >= 0 ? '+' : '−'}${saved.offsetSeconds.abs().toStringAsFixed(2)} s relative to EEG';
      seg.syncNote = extraNote.isEmpty ? savedNote : '$savedNote. $extraNote';
    } else if (offset == null) {
      // No usable clock: align by speech envelope to a loaded or sibling video, else assume.
      var aligned = false;
      if (!isVid && wavPath != null) {
        aligned = await _autoAlign(seg, wavPath) ||
            await _autoAlignToSiblingVideo(seg, wavPath);
      }
      if (!aligned) {
        final last = segments.isEmpty
            ? null
            : segments.reduce((a, b) => a.offsetSeconds > b.offsetSeconds ? a : b);
        seg.offsetSeconds = last == null ? 0.0 : last.offsetSeconds + last.durationSeconds;
        seg.syncNote = '${seg.syncNote.isEmpty ? '' : '${seg.syncNote}. '}'
            'No clock: placed ${last == null ? 'at the EEG start' : 'after the previous file'}. '
            'Click Off:${seg.offsetSeconds.toStringAsFixed(1)}s for Landmark Sync, '
            'use "Slide to sync" on the plot, or nudge with −/+.';
        seg.alignmentSource = 'assumed (no timestamp)';
      }
    }
    segments.add(seg);

    // If a timestamped video just arrived after an unclocked audio file, align it now.
    if (isVid && offset != null && wavPath != null) {
      for (final existing in segments) {
        if (!existing.isVideo &&
            existing.alignmentSource == 'assumed (no timestamp)' &&
            existing.audioPath != null) {
          await _autoAlign(existing, existing.audioPath!);
        }
      }
    }
  }

  /// Aligns audio-only [seg] to a loaded video's audio track by cross-correlation.
  Future<bool> _autoAlign(SyncedMediaSegment seg, String wavPath) async {
    ({double lagSeconds, double peakR, double confidence})? best;
    SyncedMediaSegment? bestRef;
    for (final ref in segments.where((s) => s.isVideo && s.extractedWavPath != null)) {
      try {
        final a = await MediaSyncService.alignAudio(
          referenceWav: ref.extractedWavPath!,
          targetWav: wavPath,
        );
        if (best == null || a.confidence > best.confidence) {
          best = a;
          bestRef = ref;
        }
      } catch (_) {}
    }
    if (best == null || bestRef == null || best.confidence < 6.0 || best.peakR < 0.05) {
      return false;
    }
    final totalOff = bestRef.offsetSeconds + best.lagSeconds;
    seg.offsetSeconds = totalOff;
    seg.alignmentSource = 'auto-aligned to video audio';
    seg.syncNote = 'Auto-aligned to the audio of ${bestRef.label}: media starts '
        '${totalOff >= 0 ? '+' : '−'}${totalOff.abs().toStringAsFixed(2)} s relative to EEG '
        '(speech-envelope r=${best.peakR.toStringAsFixed(2)}, z=${best.confidence.toStringAsFixed(1)})';
    unawaited(MediaSyncService.saveSyncOffset(
      mediaPath: seg.path,
      eegKey: _primaryKey,
      offsetSeconds: totalOff,
      alignmentSource: seg.alignmentSource,
      syncNote: seg.syncNote,
    ));
    return true;
  }

  /// Searches sibling folders for a timestamped video from the same session
  /// and aligns clockless audio-only [seg] via speech-envelope cross-correlation.
  Future<bool> _autoAlignToSiblingVideo(SyncedMediaSegment seg, String wavPath) async {
    if (eegStartTime == null || MediaSyncService.findTool('ffmpeg') == null) {
      return false;
    }
    _status = 'Searching for matching video to auto-align ${seg.label}…';
    notifyListeners();
    final candidates = await MediaSyncService.findSiblingTimestampedVideos(
      seg.path,
      eegStartTime: eegStartTime,
      eegDurationSec: eegDurationSec,
    );
    for (final cand in candidates.take(3)) {
      String? refWav;
      try {
        refWav = await MediaSyncService.ensureWavAudio(cand.path);
        final a = await MediaSyncService.alignAudio(
          referenceWav: refWav,
          targetWav: wavPath,
        );
        if (a.confidence >= 6.0 && a.peakR >= 0.05) {
          final vidOffset = cand.startTime.difference(eegStartTime!).inMicroseconds / 1e6;
          final candLabel = cand.path.split(RegExp(r'[\\/]')).last;
          final totalOff = vidOffset + a.lagSeconds;
          seg.offsetSeconds = totalOff;
          seg.alignmentSource = 'auto-aligned to sibling video';
          seg.syncNote = 'Auto-aligned via sibling video $candLabel: media starts '
              '${totalOff >= 0 ? '+' : '−'}${totalOff.abs().toStringAsFixed(2)} s relative to EEG '
              '(speech-envelope r=${a.peakR.toStringAsFixed(2)}, z=${a.confidence.toStringAsFixed(1)})';
          unawaited(MediaSyncService.saveSyncOffset(
            mediaPath: seg.path,
            eegKey: _primaryKey,
            offsetSeconds: totalOff,
            alignmentSource: seg.alignmentSource,
            syncNote: seg.syncNote,
          ));
          return true;
        }
      } catch (_) {
      } finally {
        if (refWav != null && refWav != cand.path) {
          try {
            await File(refWav).parent.delete(recursive: true);
          } catch (_) {}
        }
      }
    }
    return false;
  }

  /// Re-runs envelope alignment of the active audio-only file against loaded videos.
  Future<void> autoAlignActiveToVideo() async {
    final seg = activeSegment;
    final wav = seg?.audioPath;
    if (seg == null || wav == null || seg.isVideo) return;
    _busy = true;
    _status = 'Aligning ${seg.label} to the video audio…';
    notifyListeners();
    try {
      final ok = await _autoAlign(seg, wav);
      if (ok) {
        segments.sort((a, b) => a.offsetSeconds.compareTo(b.offsetSeconds));
        _activeIndex = segments.indexOf(seg);
        _status = seg.syncNote;
      } else {
        _status = 'Could not find a confident match in the loaded video audio.';
      }
      await seekToEpoch(_cursorEpoch, notifyExternal: true);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Aligns the active audio-only segment to a user-chosen timestamped video file.
  Future<void> alignActiveToVideoFile(String videoPath) async {
    final seg = activeSegment;
    final wav = seg?.audioPath;
    if (seg == null || wav == null || seg.isVideo) return;
    _busy = true;
    final vidLabel = videoPath.split(RegExp(r'[\\/]')).last;
    _status = 'Aligning ${seg.label} to $vidLabel…';
    notifyListeners();
    String? refWav;
    try {
      final (vidDt, _, tsSource) = await MediaSyncService.probeMediaMetadata(videoPath);
      if (vidDt == null || eegStartTime == null) {
        _status = 'Media load warning: '
            '${eegStartTime == null ? 'EEG start time is unknown' : '$vidLabel has no usable timestamp'}.';
        return;
      }
      final vidOffset = vidDt.difference(eegStartTime!).inMicroseconds / 1e6;
      if (vidOffset.abs() >= 24 * 3600) {
        _status = 'Media load warning: $vidLabel timestamp is more than 24 h from this EEG.';
        return;
      }
      refWav = await MediaSyncService.ensureWavAudio(videoPath);
      final a = await MediaSyncService.alignAudio(referenceWav: refWav, targetWav: wav);
      if (a.confidence < 6.0 || a.peakR < 0.05) {
        _status = 'Media load warning: could not find a confident match in $vidLabel '
            '(r=${a.peakR.toStringAsFixed(2)}, z=${a.confidence.toStringAsFixed(1)}).';
        return;
      }
      final totalOff = vidOffset + a.lagSeconds;
      seg.offsetSeconds = totalOff;
      seg.alignmentSource = 'aligned to video';
      seg.syncNote = 'Aligned to $vidLabel ($tsSource): media starts '
          '${totalOff >= 0 ? '+' : '−'}${totalOff.abs().toStringAsFixed(2)} s relative to EEG '
          '(speech-envelope r=${a.peakR.toStringAsFixed(2)}, z=${a.confidence.toStringAsFixed(1)})';
      segments.sort((a, b) => a.offsetSeconds.compareTo(b.offsetSeconds));
      _activeIndex = segments.indexOf(seg);
      _status = seg.syncNote;
      unawaited(MediaSyncService.saveSyncOffset(
        mediaPath: seg.path,
        eegKey: _primaryKey,
        offsetSeconds: totalOff,
        alignmentSource: seg.alignmentSource,
        syncNote: seg.syncNote,
      ));
      await seekToEpoch(_cursorEpoch, notifyExternal: true);
    } catch (e) {
      _status = 'Media load warning: alignment with $vidLabel failed: $e';
    } finally {
      if (refWav != null && refWav != videoPath) {
        try {
          await File(refWav).parent.delete(recursive: true);
        } catch (_) {}
      }
      _busy = false;
      notifyListeners();
    }
  }

  /// Re-runs audio/waveform/envelope extraction for loaded segments whose
  /// waveform is empty (for instance, right after installing or locating FFmpeg).
  Future<void> refreshMissingAudioExtractions() async {
    compatibilityVideo =
        Platform.isMacOS && MediaSyncService.findTool('ffmpeg') != null;
    final missing = segments.where((s) => s.waveformMax.isEmpty).toList();
    if (missing.isEmpty) {
      notifyListeners();
      return;
    }
    _busy = true;
    _status = 'Extracting waveform & speech envelope…';
    notifyListeners();
    try {
      for (final seg in missing) {
        try {
          final wavPath = await MediaSyncService.ensureWavAudio(seg.path);
          final env = await MediaSyncService.extractEnvelope(wavPath);
          if (seg.isVideo) seg.extractedWavPath = wavPath;
          if (seg.durationSeconds <= 0 && env.durationSeconds > 0) {
            seg.durationSeconds = env.durationSeconds;
          }
          seg.waveformMin = env.displayMin;
          seg.waveformMax = env.displayMax;
          seg.envelopePreview = env.envelopePreview;
          seg.syncNote = seg.syncNote
              .replaceAll(
                RegExp(r'\.?\s*Playback ready \(install ffmpeg[^)]*\)\.?$'),
                '',
              )
              .trim();
          if (seg.syncNote.isEmpty) {
            seg.syncNote =
                'Media starts ${seg.offsetSeconds >= 0 ? '+' : '−'}${seg.offsetSeconds.abs().toStringAsFixed(1)} s relative to this EEG';
          }
        } catch (e) {
          _status = 'Media load warning: ${seg.label}: $e';
        }
      }
      if (!(_status?.startsWith('Media load warning:') ?? false)) {
        _status = '${segments.length} synced media file(s) ready';
      }
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  // ── Transport ──────────────────────────────────────────────────────────

  int _indexCovering(double epoch) {
    if (segments.isEmpty) return -1;
    bool covers(SyncedMediaSegment s) =>
        epoch >= segmentStartEpoch(s) &&
        (s.durationSeconds <= 0 || epoch <= segmentEndEpoch(s));
    final cur = activeSegment;
    if (cur != null && covers(cur)) return _activeIndex;
    var idx = segments.indexWhere((s) => s.isVideo && covers(s));
    if (idx < 0) idx = segments.indexWhere(covers);
    return idx;
  }

  Future<void> seekToEegTime(double sec, {bool notifyExternal = false}) =>
      seekToEpoch(primaryStartEpoch + sec, notifyExternal: notifyExternal);

  bool compatibilityVideo =
      Platform.isMacOS && MediaSyncService.findTool('ffmpeg') != null;
  bool _frameBusy = false;
  DateTime _lastFrameRequest = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void> _refreshPlaybackFrame(SyncedMediaSegment segment, double local) async {
    if (_frameBusy ||
        !compatibilityVideo ||
        !segment.isVideo ||
        _seeking ||
        _disposed ||
        MediaSyncService.findTool('ffmpeg') == null) {
      return;
    }
    if (DateTime.now().difference(_lastFrameRequest).inMilliseconds < 250) return;
    _frameBusy = true;
    _lastFrameRequest = DateTime.now();
    try {
      final frame = await MediaSyncService.videoFrame(segment.path, local);
      if (!_disposed && _playing && identical(segment, activeSegment) && !_seeking) {
        previewFrame = frame;
        notifyListeners();
      }
    } catch (e) {
      _status = 'Playback error: compatibility frame unavailable: $e';
      notifyListeners();
    } finally { _frameBusy = false; }
  }
  Uint8List? previewFrame;
  bool previewLoading = false;
  bool _seeking = false;
  double? _pendingSeekEpoch;

  Future<void> seekToEpoch(double epoch, {bool notifyExternal = false}) async {
    previewFrame = null;
    previewLoading = true;
    _cursorEpoch = epoch;
    notifyListeners();
    _lastSeek = DateTime.now();
    if (notifyExternal) onTimeChanged?.call(eegSec);
    _pendingSeekEpoch = epoch;
    if (_seeking) {
      notifyListeners();
      return;
    }
    _seeking = true;
    try {
      while (_pendingSeekEpoch != null) {
        final target = _pendingSeekEpoch!;
        _pendingSeekEpoch = null;
        final idx = _indexCovering(target);
        if (idx < 0) {
          _outOfRange = true;
          if (_playing) await _player.pause();
          notifyListeners();
          continue;
        }
        _outOfRange = false;
        if (idx != _activeIndex) await _openSegment(idx);
        final seg = activeSegment;
        if (seg != null) {
          final local = seg.durationSeconds > 0
              ? (target - segmentStartEpoch(seg))
                  .clamp(0.0, math.max(0.0, seg.durationSeconds - 0.05))
                  .toDouble()
              : math.max(0.0, target - segmentStartEpoch(seg)).toDouble();
          if (seg.isVideo &&
              compatibilityVideo &&
              !_playing &&
              _pendingSeekEpoch == null &&
              MediaSyncService.findTool('ffmpeg') != null) {
            // Render first: a blocked native seek must not leave an old frame
            // under the newly updated EEG cursor.
            try {
              final frame = await MediaSyncService.videoFrame(seg.path, local);
              if (_pendingSeekEpoch == null && !_disposed && !_playing) {
                previewFrame = frame;
                previewLoading = false;
                notifyListeners();
              }
            } catch (_) {
              previewLoading = false;
            }
          } else {
            previewLoading = false;
          }
          await _player.seek(Duration(microseconds: (local * 1e6).round()))
              .timeout(const Duration(seconds: 5));
          _lastSeek = DateTime.now();
        }
        notifyListeners();
      }
    } catch (e) {
      _status = 'Playback error: $e';
      notifyListeners();
    } finally {
      _seeking = false;
      previewLoading = false;
      notifyListeners();
    }
  }

  Future<void> _openSegment(int idx) async {
    final resumePlayback = _playing;
    _activeIndex = idx;
    notifyListeners(); // Mount the video surface before waiting for its texture.
    if (segments[idx].isVideo) {
      await _videoController.platform.future.timeout(const Duration(seconds: 10),
        onTimeout: () => throw StateError('Video display did not initialize. Close and reopen the media panel.'));
    }
    await _player.open(Media(segments[idx].path), play: false);
    // A seek issued before the demuxer reports a duration is silently dropped,
    // which left the video at 0:00 instead of the cursor.
    await Future<void>.delayed(const Duration(milliseconds: 120));
    for (var i = 0; i < 100 && _player.state.duration == Duration.zero; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (segments[idx].durationSeconds <= 0 && _player.state.duration > Duration.zero) {
      segments[idx].durationSeconds = _player.state.duration.inMicroseconds / 1e6;
      notifyListeners();
    }
    await _player.setRate(_rate);
    await _player.setVolume(_muted ? 0 : 100);
    if (resumePlayback) await _player.play();
  }

  void _onPlayerPosition(Duration pos) {
    final seg = activeSegment;
    if (seg == null || !_playing || _outOfRange) return;
    // Ignore stale position events that arrive right after a seek.
    if (DateTime.now().difference(_lastSeek).inMilliseconds < 350) return;
    unawaited(_refreshPlaybackFrame(seg, pos.inMicroseconds / 1e6));
    final t = segmentStartEpoch(seg) + pos.inMicroseconds / 1e6;
    if ((t - _cursorEpoch).abs() > 0.04) {
      _cursorEpoch = t;
      onTimeChanged?.call(eegSec);
      notifyListeners();
    }
  }

  Future<void> _onCompleted() async {
    final seg = activeSegment;
    if (seg == null) return;
    final startA = segmentStartEpoch(seg);
    SyncedMediaSegment? next;
    for (final s in segments) {
      final st = segmentStartEpoch(s);
      if (st > startA && (next == null || st < segmentStartEpoch(next))) next = s;
    }
    if (next == null) return;
    await seekToEpoch(segmentStartEpoch(next), notifyExternal: true);
    await _player.play();
  }

  Future<void> togglePlay() async {
    if (segments.isEmpty || _busy) return;
    try {
      if (_activeIndex < 0 || _outOfRange) await seekToEpoch(_cursorEpoch);
      if (_outOfRange || _activeIndex < 0) return;
      if (_playing) {
        await _player.pause();
        _playing = false;
        await seekToEpoch(_cursorEpoch);
      } else {
        previewFrame = null;
        await _player.play();
      }
    } catch (e) {
      _status = 'Playback error: $e';
      notifyListeners();
    }
  }

  Future<void> toggleMute() async {
    _muted = !_muted;
    await _player.setVolume(_muted ? 0 : 100);
    notifyListeners();
  }

  Future<void> setSpeed(double rate) async {
    _rate = rate;
    await _player.setRate(rate);
    notifyListeners();
  }

  /// Parses signed `seconds`, `mm:ss`, or `hh:mm:ss` into seconds; returns `null` if invalid.
  static double? parseFlexibleTimeSec(String raw) {
    var s = raw.trim().replaceAll('−', '-');
    if (s.isEmpty) return null;
    var sign = 1.0;
    if (s.startsWith('-')) {
      sign = -1.0;
      s = s.substring(1).trim();
    } else if (s.startsWith('+')) {
      s = s.substring(1).trim();
    }
    if (s.isEmpty) return null;
    final parts = s.split(':');
    if (parts.length == 1) {
      final v = double.tryParse(parts[0].trim());
      if (v == null || !v.isFinite || v < 0) return null;
      return sign * v;
    }
    if (parts.length == 2) {
      final m = int.tryParse(parts[0].trim());
      final sec = double.tryParse(parts[1].trim());
      if (m == null || sec == null || m < 0 || !sec.isFinite || sec < 0 || sec >= 60) {
        return null;
      }
      return sign * (m * 60.0 + sec);
    }
    if (parts.length == 3) {
      final h = int.tryParse(parts[0].trim());
      final m = int.tryParse(parts[1].trim());
      final sec = double.tryParse(parts[2].trim());
      if (h == null ||
          m == null ||
          sec == null ||
          h < 0 ||
          m < 0 ||
          m >= 60 ||
          !sec.isFinite ||
          sec < 0 ||
          sec >= 60) {
        return null;
      }
      return sign * (h * 3600.0 + m * 60.0 + sec);
    }
    return null;
  }

  /// Sets [seg]'s EEG-relative offset, persists `.ccssync.json`, and seeks.
  void setSegmentOffset(
    SyncedMediaSegment seg,
    double newOffset, {
    required String source,
    String? note,
    bool persist = true,
    bool seek = true,
  }) {
    final cur = activeSegment;
    seg.offsetSeconds = newOffset;
    seg.alignmentSource = source;
    seg.syncNote = note ??
        'Synced ($source): media starts '
        '${newOffset >= 0 ? '+' : '−'}${newOffset.abs().toStringAsFixed(2)} s relative to EEG';
    segments.sort((a, b) => a.offsetSeconds.compareTo(b.offsetSeconds));
    if (cur != null) {
      _activeIndex = segments.indexOf(cur);
    }
    notifyListeners();
    if (persist) {
      unawaited(MediaSyncService.saveSyncOffset(
        mediaPath: seg.path,
        eegKey: _primaryKey,
        offsetSeconds: newOffset,
        alignmentSource: source,
        syncNote: seg.syncNote,
      ));
    }
    if (seek) {
      unawaited(seekToEpoch(_cursorEpoch, notifyExternal: true));
    }
  }

  void shiftSegmentOffset(
    SyncedMediaSegment seg,
    double deltaSec, {
    bool persist = false,
    bool seek = false,
  }) {
    setSegmentOffset(
      seg,
      seg.offsetSeconds + deltaSec,
      source: 'manual slide',
      persist: persist,
      seek: seek,
    );
  }

  void commitSegmentOffset(SyncedMediaSegment seg) {
    setSegmentOffset(
      seg,
      seg.offsetSeconds,
      source: seg.alignmentSource,
      persist: true,
      seek: true,
    );
  }

  /// Shifts the active media later (+) or earlier (−) on the EEG timeline.
  void nudgeActiveOffset(double deltaSec) {
    final seg = activeSegment;
    if (seg == null) return;
    setSegmentOffset(
      seg,
      seg.offsetSeconds + deltaSec,
      source: 'manual nudge',
    );
  }

  // ── Neural Speech Tracking ─────────────────────────────────────────────

  /// Runs Neural Speech Tracking for the EEG session behind [sessionPath] against
  /// the media segment that overlaps it most (or [segment]). The result — including
  /// the sliding-window time series — is stored for the plots.
  double? trackingOverlap(String path, double duration) {
    final start = sessionStartEpoch(path);
    if (start == null) return null;
    var overlap = 0.0;
    for (final segment in segments.where((s) => s.audioPath != null)) {
      overlap = math.max(overlap, math.min(start + duration, segmentEndEpoch(segment)) - math.max(start, segmentStartEpoch(segment)));
    }
    return overlap;
  }

  Future<SpeechTrackingSummary> runTracking({
    required String sessionPath,
    required double sessionDurationSec,
    SyncedMediaSegment? segment,
  }) async {
    final key = MediaSyncService.stemKey(sessionPath);
    final start = sessionStartEpoch(sessionPath);
    if (start == null) {
      throw StateError(
        'The start time of ${sessionPath.split(RegExp(r'[\\/]')).last} is unknown, '
        'so it cannot be aligned to the media.',
      );
    }
    double overlapOf(SyncedMediaSegment s) {
      final a = math.max(start, segmentStartEpoch(s));
      final b = math.min(start + sessionDurationSec, segmentEndEpoch(s));
      return b - a;
    }

    SyncedMediaSegment? seg = segment != null && overlapOf(segment) >= 4.0 ? segment : null;
    if (seg == null) {
      for (final s in segments) {
        if (s.audioPath == null) continue;
        if (seg == null || overlapOf(s) > overlapOf(seg)) seg = s;
      }
    }
    if (seg == null || overlapOf(seg) < 4.0) {
      final noAudioSeg = segments
          .where((s) => s.audioPath == null && overlapOf(s) >= 4.0)
          .firstOrNull;
      if (noAudioSeg != null) {
        throw StateError(
          'Audio track could not be extracted from ${noAudioSeg.label} because FFmpeg is not installed. '
          'Click "Setup FFmpeg…" in the media panel (or use a .wav file).',
        );
      }
      throw StateError(
        'No loaded video/audio overlaps this EEG session. Load the media that was '
        'recorded during it (the media and EEG clocks must overlap).',
      );
    }
    final wav = seg.audioPath;
    if (wav == null) {
      throw StateError(
        'Audio track could not be extracted from ${seg.label} because FFmpeg is not installed. '
        'Click "Setup FFmpeg…" in the media panel (or use a .wav file).',
      );
    }
    final recPath = MediaSyncService.trackingRecordingPath(key == _primaryKey ? eegPath : sessionPath);
    _trackingBusy = true;
    _status = 'Neural Speech Tracking (${seg.label})…';
    notifyListeners();
    try {
      final res = await MediaSyncService.runSpeechTracking(
        eegPath: recPath,
        wavPath: wav,
        audioOffsetSeconds: segmentStartEpoch(seg) - start,
      );
      _tracking[key] = res;
      _status = 'Neural Speech Tracking done';
      return res;
    } finally {
      _trackingBusy = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _posSub?.cancel();
    _playSub?.cancel();
    _doneSub?.cancel();
    _errorSub?.cancel();
    unawaited(_player.dispose());
    super.dispose();
  }
}

String _hms(double sec) {
  final neg = sec < 0;
  var s = sec.abs().round();
  final h = s ~/ 3600;
  s -= h * 3600;
  final m = s ~/ 60;
  s -= m * 60;
  final t = h > 0
      ? '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}'
      : '$m:${s.toString().padLeft(2, '0')}';
  return neg ? '−$t' : t;
}

class SyncedMediaPanel extends StatefulWidget {
  const SyncedMediaPanel({
    super.key,
    required this.controller,
    required this.onAddFiles,
    this.onPickAlignVideo,
    required this.onClose,
    required this.onMove,
    required this.onResize,
  });

  final MediaSyncController controller;
  final VoidCallback onAddFiles;
  final Future<String?> Function()? onPickAlignVideo;
  final VoidCallback onClose;
  final ValueChanged<Offset> onMove;
  final ValueChanged<Offset> onResize;

  @override
  State<SyncedMediaPanel> createState() => _SyncedMediaPanelState();
}

class _SyncedMediaPanelState extends State<SyncedMediaPanel> {
  String? _trackingError;
  bool _showWaveform = false, _showEnvelope = true;
  double? _windowHalfSec; // null = Full recording, otherwise +/- seconds around cursor

  Future<void> _runSpeechTracking() async {
    final ctrl = widget.controller;
    setState(() => _trackingError = null);
    try {
      await ctrl.runTracking(
        sessionPath: ctrl.eegPath,
        sessionDurationSec: ctrl.eegDurationSec,
        segment: ctrl.activeSegment,
      );
    } catch (e) {
      if (mounted) setState(() => _trackingError = '$e');
    }
  }

  Future<void> _showFfmpegSetupDialog(BuildContext context, MediaSyncController ctrl) async {
    var installing = false;
    String? feedback;
    var ok = MediaSyncService.findTool('ffmpeg') != null;
    if (ok) {
      feedback = 'Detected FFmpeg at: ${MediaSyncService.findTool('ffmpeg')}';
    }
    final cmdText = Platform.isWindows
        ? 'winget install Gyan.FFmpeg'
        : Platform.isMacOS
            ? 'brew install ffmpeg'
            : 'sudo apt install ffmpeg';

    await showDialog<void>(
      context: context,
      builder: (dlgCtx) => StatefulBuilder(
        builder: (dlgCtx, setDlgState) => AlertDialog(
          title: const Text('Setup FFmpeg for Waveform & Speech Tracking', style: TextStyle(fontSize: 15)),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Native video/audio playback and .wav files work without FFmpeg. '
                    'FFmpeg is only needed to extract waveform/speech-envelope strips, '
                    'scrub frame previews, and Neural Speech Tracking from compressed '
                    'formats (.mp4, .mov, .m4a, .mp3, etc.).',
                    style: TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  if (Platform.isWindows) ...[
                    const Text(
                      'Option 1 — One-click install via Windows Package Manager (WinGet):',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        FilledButton.tonalIcon(
                          onPressed: installing
                              ? null
                              : () async {
                                  setDlgState(() {
                                    installing = true;
                                    feedback = 'Running winget install Gyan.FFmpeg…';
                                  });
                                  final res = await MediaSyncService.installFfmpegViaWinget();
                                  ok = res.ok;
                                  if (res.ok) {
                                    await ctrl.refreshMissingAudioExtractions();
                                  }
                                  if (dlgCtx.mounted) {
                                    setDlgState(() {
                                      installing = false;
                                      feedback = res.message;
                                    });
                                  }
                                },
                          icon: installing
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.download, size: 16),
                          label: Text(installing ? 'Installing…' : 'Install via WinGet (1-click)'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],
                  Text(
                    Platform.isWindows
                        ? 'Option 2 — Already downloaded ffmpeg.exe? Point the app directly to it:'
                        : 'Locate FFmpeg binary directly or install via package manager:',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: installing
                            ? null
                            : () async {
                                final res = await FilePicker.pickFiles(
                                  allowMultiple: false,
                                  type: Platform.isWindows ? FileType.custom : FileType.any,
                                  allowedExtensions: Platform.isWindows ? const ['exe'] : null,
                                );
                                final path = res == null || res.files.isEmpty
                                    ? null
                                    : res.files.first.path;
                                if (path == null || path.isEmpty) return;
                                MediaSyncService.setCustomToolPath('ffmpeg', path);
                                ok = MediaSyncService.findTool('ffmpeg') != null;
                                if (ok) {
                                  await ctrl.refreshMissingAudioExtractions();
                                }
                                if (dlgCtx.mounted) {
                                  setDlgState(() {
                                    feedback = ok
                                        ? 'FFmpeg configured: $path'
                                        : 'Selected file could not be used: $path';
                                  });
                                }
                              },
                        icon: const Icon(Icons.folder_open, size: 16),
                        label: Text(Platform.isWindows ? 'Locate ffmpeg.exe…' : 'Locate ffmpeg…'),
                      ),
                      OutlinedButton.icon(
                        onPressed: installing
                            ? null
                            : () async {
                                final found = MediaSyncService.findTool('ffmpeg');
                                ok = found != null;
                                if (ok) {
                                  await ctrl.refreshMissingAudioExtractions();
                                }
                                if (dlgCtx.mounted) {
                                  setDlgState(() {
                                    feedback = ok
                                        ? 'Detected FFmpeg at: $found'
                                        : 'FFmpeg still not found on PATH or standard folders.';
                                  });
                                }
                              },
                        icon: const Icon(Icons.refresh, size: 16),
                        label: const Text('Check again'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    Platform.isWindows
                        ? 'Option 3 — Manual install (Terminal command or ZIP download):'
                        : 'Terminal install command:',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8F9FB),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFFCBD5E1)),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: SelectableText(
                            cmdText,
                            style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Copy command',
                          icon: const Icon(Icons.copy, size: 15),
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: cmdText));
                            if (dlgCtx.mounted) {
                              setDlgState(() => feedback = 'Copied "$cmdText" to clipboard.');
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                  if (Platform.isWindows) ...[
                    const SizedBox(height: 6),
                    const SelectableText(
                      'Or download from https://www.gyan.dev/ffmpeg/builds/ (release-essentials ZIP) '
                      'and copy bin\\ffmpeg.exe + bin\\ffprobe.exe either onto PATH or into the '
                      'CCS EEG Studio folder next to ccs_eeg_app.exe.',
                      style: TextStyle(fontSize: 11, color: const Color(0xFF475569)),
                    ),
                  ],
                  if (feedback != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      feedback!,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: ok ? const Color(0xFF16A34A) : const Color(0xFFD97706),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dlgCtx),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _showSyncDialog(
    BuildContext context,
    MediaSyncController ctrl,
    SyncedMediaSegment seg,
  ) =>
      showDialog<void>(
        context: context,
        builder: (_) => _SyncMediaDialog(ctrl: ctrl, seg: seg),
      );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final ctrl = widget.controller;
        final seg = ctrl.activeSegment;
        final tracking = ctrl.trackingFor(ctrl.eegPath);
        return Material(
          elevation: 12,
          color: const Color(0xFFF8F9FB),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: Color(0xFFCBD5E1)),
          ),
          child: Column(
            children: [
              // Draggable Title Bar
              GestureDetector(
                onPanUpdate: (d) => widget.onMove(d.delta),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: const BoxDecoration(
                    color: Color(0xFFFFFFFF),
                    borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.ondemand_video, size: 15, color: const Color(0xFF0284C7)),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Tooltip(
                          message: seg?.path ?? '',
                          child: Text(
                            seg == null
                                ? 'Synced Video & Audio'
                                : '${seg.label} · ${seg.alignmentSource}',
                            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      if (ctrl.segments.length > 1)
                        PopupMenuButton<int>(
                          tooltip: 'Jump to loaded file',
                          icon: const Icon(Icons.list, size: 16),
                          padding: EdgeInsets.zero,
                          onSelected: (i) => ctrl.seekToEpoch(
                            ctrl.segmentStartEpoch(ctrl.segments[i]),
                            notifyExternal: true,
                          ),
                          itemBuilder: (_) => [
                            for (var i = 0; i < ctrl.segments.length; i++)
                              PopupMenuItem(
                                value: i,
                                child: Text(
                                  '${ctrl.segments[i].isVideo ? '🎬' : '🎧'} ${ctrl.segments[i].label}',
                                  style: const TextStyle(fontSize: 11),
                                ),
                              ),
                          ],
                        ),
                      IconButton(tooltip: ctrl.playing ? 'Pause media' : 'Play media',
                        icon: Icon(ctrl.playing ? Icons.pause : Icons.play_arrow),
                        onPressed: seg == null ? null : ctrl.togglePlay),
                      TextButton.icon(
                        onPressed: widget.onAddFiles,
                        icon: const Icon(Icons.add, size: 14),
                        label: const Text('Add Video/Audio', style: TextStyle(fontSize: 10)),
                        style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 15),
                        onPressed: widget.onClose,
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ),
                ),
              ),
              Row(children: [
                Checkbox(
                  value: MediaSyncService.findTool('ffmpeg') != null &&
                      ctrl.compatibilityVideo,
                  onChanged: MediaSyncService.findTool('ffmpeg') == null
                      ? null
                      : (v) {
                          ctrl.compatibilityVideo = v ?? true;
                          ctrl.notifyListeners();
                        },
                ),
                Expanded(
                  child: Text(
                    MediaSyncService.findTool('ffmpeg') == null
                        ? 'Compatibility video requires ffmpeg (native hardware playback active)'
                        : 'Compatibility video · up to 4 frames/s · audio stays continuous',
                    style: TextStyle(
                      fontSize: 10,
                      color: MediaSyncService.findTool('ffmpeg') == null
                          ? const Color(0xFF64748B)
                          : null,
                    ),
                  ),
                ),
              ]),
              if (MediaSyncService.findTool('ffmpeg') == null)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFFD97706).withValues(alpha: 0.35)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline, size: 13, color: const Color(0xFFD97706)),
                      const SizedBox(width: 6),
                      const Expanded(
                        child: Text(
                          'FFmpeg not found: playback & .wav work, but waveform/envelope & Speech Tracking for .mp4/.m4a/.mp3 need FFmpeg.',
                          style: TextStyle(fontSize: 9.5, color: const Color(0xFFD97706)),
                        ),
                      ),
                      TextButton(
                        onPressed: () => _showFfmpegSetupDialog(context, ctrl),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        ),
                        child: const Text('Setup FFmpeg…', style: TextStyle(fontSize: 10)),
                      ),
                    ],
                  ),
                ),
              if (ctrl.busy || ctrl.trackingBusy) const LinearProgressIndicator(minHeight: 2),
              if (ctrl.status != null &&
                  (ctrl.status!.startsWith('Playback error:') ||
                      ctrl.status!.startsWith('Media load warning:')))
                Padding(
                  padding: const EdgeInsets.all(6),
                  child: Text(
                    ctrl.status!,
                    style: const TextStyle(color: Colors.orange, fontSize: 11),
                  ),
                ),
              if (seg != null && seg.isVideo)
                Expanded(
                  flex: 3,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Container(
                        color: Colors.black,
                        child: Video(controller: ctrl.videoController),
                      ),
                      if ((!ctrl.playing || ctrl.compatibilityVideo) && ctrl.previewFrame != null)
                        Container(color: Colors.black, child: Image.memory(ctrl.previewFrame!, fit: BoxFit.contain, gaplessPlayback: false)),
                      if (!ctrl.playing && ctrl.previewLoading)
                        const ColoredBox(color: Colors.black, child: Center(child: Text('Loading video frame…'))),
                      if (ctrl.outOfRange)
                        Container(
                          color: Colors.black87,
                          alignment: Alignment.center,
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            'No loaded media covers this moment '
                            '(EEG ${_hms(ctrl.eegSec)}). Click inside a media range on the plot.',
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 11, color: const Color(0xFFD97706)),
                          ),
                        ),
                    ],
                  ),
                )
              else
                Expanded(
                  flex: 1,
                  child: Center(
                    child: Text(
                      seg == null
                          ? 'Click "Add Video/Audio" to load video or audio synced by timestamp.'
                          : ctrl.outOfRange
                              ? 'No loaded media covers this moment (EEG ${_hms(ctrl.eegSec)}).'
                              : '${seg.audioSourceKind} · ${seg.durationSeconds.toStringAsFixed(1)} s',
                      style: const TextStyle(fontSize: 11, color: const Color(0xFF475569)),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              if (seg != null) Wrap(spacing: 4, children: [
                FilterChip(label: const Text('Waveform'), selected: _showWaveform, onSelected: (v) => setState(() => _showWaveform = v)),
                FilterChip(label: const Text('Envelope'), selected: _showEnvelope, onSelected: (v) => setState(() => _showEnvelope = v)),
              ]),
              // Audio layers can be hidden independently.
              if (seg != null && seg.waveformMax.isNotEmpty && (_showWaveform || _showEnvelope)) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 4, 10, 0),
                  child: Row(
                    children: [
                      Icon(seg.isVideo ? Icons.movie : Icons.headphones,
                          size: 12, color: const Color(0xFFD97706)),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Tooltip(
                          message: '${seg.path}\n${seg.syncNote}',
                          child: Text(
                            'Blue: waveform · Yellow: speech envelope · ${seg.audioSourceDescription}',
                            style: const TextStyle(fontSize: 9.5, color: const Color(0xFF475569)),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      for (final opt in const <(String, double?)>[
                        ('Full', null),
                        ('±5m', 300.0),
                        ('±60s', 60.0),
                        ('±15s', 15.0),
                      ])
                        Padding(
                          padding: const EdgeInsets.only(left: 3),
                          child: InkWell(
                            onTap: () => setState(() => _windowHalfSec = opt.$2),
                            borderRadius: BorderRadius.circular(4),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                              decoration: BoxDecoration(
                                color: _windowHalfSec == opt.$2
                                    ? const Color(0xFF0284C7).withValues(alpha: 0.22)
                                    : const Color(0xFFE2E8F0),
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                  color: _windowHalfSec == opt.$2
                                      ? const Color(0xFF0284C7)
                                      : const Color(0xFFCBD5E1),
                                  width: 0.7,
                                ),
                              ),
                              child: Text(
                                opt.$1,
                                style: TextStyle(
                                  fontSize: 9,
                                  color: _windowHalfSec == opt.$2
                                      ? const Color(0xFF0284C7)
                                      : const Color(0xFF475569),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Container(
                  height: 62,
                  margin: const EdgeInsets.fromLTRB(8, 2, 8, 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8F9FB),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFFCBD5E1)),
                  ),
                  child: LayoutBuilder(
                    builder: (ctx, box) {
                      final dur = seg.durationSeconds;
                      final segStart = ctrl.segmentStartEpoch(seg);
                      final cursorLocal = (ctrl.cursorEpoch - segStart).clamp(0.0, dur);
                      final double winStartSec;
                      final double winEndSec;
                      if (_windowHalfSec == null || dur <= _windowHalfSec! * 2) {
                        winStartSec = 0.0;
                        winEndSec = dur;
                      } else {
                        final half = _windowHalfSec!;
                        var s0 = cursorLocal - half;
                        var s1 = cursorLocal + half;
                        if (s0 < 0) {
                          s1 = (s1 - s0).clamp(0.0, dur);
                          s0 = 0.0;
                        } else if (s1 > dur) {
                          s0 = (s0 - (s1 - dur)).clamp(0.0, dur);
                          s1 = dur;
                        }
                        winStartSec = s0;
                        winEndSec = s1;
                      }
                      final viewStartFrac = dur > 0 ? (winStartSec / dur).clamp(0.0, 1.0) : 0.0;
                      final viewEndFrac = dur > 0 ? (winEndSec / dur).clamp(0.0, 1.0) : 1.0;

                      double epochAt(double dx) {
                        final frac = (dx / box.maxWidth).clamp(0.0, 1.0);
                        return segStart + winStartSec + frac * (winEndSec - winStartSec);
                      }

                      return GestureDetector(
                        onTapDown: (d) {
                          if (box.maxWidth > 0) {
                            ctrl.seekToEpoch(epochAt(d.localPosition.dx), notifyExternal: true);
                          }
                        },
                        onHorizontalDragUpdate: (d) {
                          if (box.maxWidth > 0) {
                            ctrl.seekToEpoch(epochAt(d.localPosition.dx), notifyExternal: true);
                          }
                        },
                        child: CustomPaint(
                          painter: AudioWaveformEnvelopePainter(
                            minBins: seg.waveformMin,
                            maxBins: seg.waveformMax,
                            envelope: seg.envelopePreview,
                            showWaveform: _showWaveform,
                            showEnvelope: _showEnvelope,
                            cursorFrac: dur > 0 ? (cursorLocal / dur).clamp(0.0, 1.0) : 0.0,
                            viewStartFrac: viewStartFrac,
                            viewEndFrac: viewEndFrac,
                          ),
                          child: const SizedBox.expand(),
                        ),
                      );
                    },
                  ),
                ),
              ],
              // Transport, Sync Offset & Neural Speech Tracking Controls
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    IconButton(
                      icon: Icon(ctrl.playing ? Icons.pause : Icons.play_arrow, size: 18),
                      onPressed: seg == null ? null : ctrl.togglePlay,
                      visualDensity: VisualDensity.compact,
                    ),
                    IconButton(
                      icon: Icon(ctrl.muted ? Icons.volume_off : Icons.volume_up, size: 16),
                      onPressed: seg == null ? null : ctrl.toggleMute,
                      visualDensity: VisualDensity.compact,
                    ),
                    Text(
                      'EEG ${ctrl.eegSec.toStringAsFixed(1)}s',
                      style: const TextStyle(fontSize: 10, color: const Color(0xFF0284C7)),
                    ),
                    if (seg != null) ...[
                      TextButton(
                        onPressed: () => ctrl.nudgeActiveOffset(-10.0),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: const Text('−10s', style: TextStyle(fontSize: 10)),
                      ),
                      TextButton(
                        onPressed: () => ctrl.nudgeActiveOffset(-1.0),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: const Text('−1s', style: TextStyle(fontSize: 10)),
                      ),
                      TextButton(
                        onPressed: () => ctrl.nudgeActiveOffset(-0.1),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: const Text('−0.1', style: TextStyle(fontSize: 10)),
                      ),
                      Tooltip(
                        message:
                            'Click to adjust sync offset, match an audio/EEG landmark, or set recording start clock\n${seg.syncNote}',
                        child: OutlinedButton.icon(
                          onPressed: () => _showSyncDialog(context, ctrl, seg),
                          icon: const Icon(Icons.tune, size: 11),
                          label: Text(
                            'Off:${seg.offsetSeconds.toStringAsFixed(1)}s',
                            style: const TextStyle(fontSize: 10),
                          ),
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            side: const BorderSide(color: const Color(0xFFCBD5E1)),
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () => ctrl.nudgeActiveOffset(0.1),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: const Text('+0.1', style: TextStyle(fontSize: 10)),
                      ),
                      TextButton(
                        onPressed: () => ctrl.nudgeActiveOffset(1.0),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: const Text('+1s', style: TextStyle(fontSize: 10)),
                      ),
                      TextButton(
                        onPressed: () => ctrl.nudgeActiveOffset(10.0),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: const Text('+10s', style: TextStyle(fontSize: 10)),
                      ),
                      if (!seg.isVideo &&
                          (ctrl.segments.any((s) => s.isVideo) ||
                              widget.onPickAlignVideo != null))
                        TextButton.icon(
                          onPressed: ctrl.busy
                              ? null
                              : () async {
                                  if (ctrl.segments.any((s) => s.isVideo)) {
                                    await ctrl.autoAlignActiveToVideo();
                                  } else if (widget.onPickAlignVideo != null) {
                                    final picked = await widget.onPickAlignVideo!();
                                    if (picked != null && picked.isNotEmpty) {
                                      await ctrl.alignActiveToVideoFile(picked);
                                    }
                                  }
                                },
                          icon: const Icon(Icons.sync, size: 12),
                          label: Text(
                            ctrl.segments.any((s) => s.isVideo)
                                ? 'Align to video'
                                : 'Align to video…',
                            style: const TextStyle(fontSize: 10),
                          ),
                          style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                        ),
                      FilledButton.tonalIcon(
                        onPressed: ctrl.trackingBusy ? null : _runSpeechTracking,
                        icon: const Icon(Icons.graphic_eq, size: 13),
                        label: Text(
                          ctrl.trackingBusy ? 'TRF…' : 'Neural Speech Tracking',
                          style: const TextStyle(fontSize: 10),
                        ),
                        style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
                      ),
                    ],
                  ],
                ),
              ),
              if (seg != null && seg.syncNote.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Text(
                    seg.syncNote,
                    style: const TextStyle(fontSize: 9.5, color: const Color(0xFF64748B)),
                  ),
                ),
              if (_trackingError != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  child: Text(
                    _trackingError!,
                    style: const TextStyle(fontSize: 10, color: const Color(0xFFDC2626)),
                  ),
                ),
              if (tracking != null)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.fromLTRB(8, 2, 8, 6),
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: Colors.teal.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFF0F766E).withValues(alpha: 0.35)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'TRF Encoding Best: ${tracking.bestChannel} (r=${tracking.bestEncodingR.toStringAsFixed(3)}) · '
                        'Decoder Reconstruction r=${tracking.decoderReconstructionR.toStringAsFixed(3)} '
                        '(p≈${tracking.decoderPApprox.toStringAsExponential(1)}, ${tracking.overlapSeconds.toStringAsFixed(1)} s overlap) — '
                        'time series shown in Plots & Report',
                        style: const TextStyle(fontSize: 10, color: const Color(0xFF0F766E)),
                      ),
                    ],
                  ),
                ),
              if (tracking != null) const SpeechTrackingMethod(),
              // Bottom-right resize handle
              Align(
                alignment: Alignment.bottomRight,
                child: GestureDetector(
                  onPanUpdate: (d) => widget.onResize(d.delta),
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.drag_handle, size: 14, color: const Color(0xFF94A3B8)),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

String _formatMmSs(double sec) {
  final neg = sec < 0;
  final abs = sec.abs();
  final mins = abs ~/ 60;
  final rem = abs - mins * 60;
  final remStr = rem.toStringAsFixed(1).padLeft(4, '0');
  return '${neg ? '-' : ''}$mins:$remStr';
}

String _formatClockTime(DateTime dt) =>
    '${dt.hour.toString().padLeft(2, '0')}:'
    '${dt.minute.toString().padLeft(2, '0')}:'
    '${dt.second.toString().padLeft(2, '0')}';

DateTime? _parseWallClockNearestTime(String raw, DateTime reference) {
  final m = RegExp(r'^(\d{1,2}):(\d{2})(?::(\d{2})(?:\.(\d+))?)?$')
      .firstMatch(raw.trim());
  if (m == null) return null;
  final hh = int.parse(m.group(1)!);
  final mm = int.parse(m.group(2)!);
  final ss = int.tryParse(m.group(3) ?? '0') ?? 0;
  if (hh > 23 || mm > 59 || ss > 59) return null;
  final baseDay = DateTime(reference.year, reference.month, reference.day, hh, mm, ss);
  DateTime best = baseDay;
  var bestDiff = baseDay.difference(reference).abs();
  for (final deltaDay in const [-1, 1]) {
    final cand = baseDay.add(Duration(days: deltaDay));
    final diff = cand.difference(reference).abs();
    if (diff < bestDiff) {
      best = cand;
      bestDiff = diff;
    }
  }
  return best;
}

class _SyncMediaDialog extends StatefulWidget {
  const _SyncMediaDialog({required this.ctrl, required this.seg});
  final MediaSyncController ctrl;
  final SyncedMediaSegment seg;

  @override
  State<_SyncMediaDialog> createState() => _SyncMediaDialogState();
}

class _SyncMediaDialogState extends State<_SyncMediaDialog> {
  late final TextEditingController _audioCtrl;
  late final TextEditingController _eegCtrl;
  late final TextEditingController _offsetCtrl;
  late final TextEditingController _clockCtrl;
  String? _errorMsg;

  @override
  void initState() {
    super.initState();
    final ctrl = widget.ctrl;
    final seg = widget.seg;
    final initAudio = (ctrl.cursorEpoch - ctrl.segmentStartEpoch(seg))
        .clamp(0.0, seg.durationSeconds > 0 ? seg.durationSeconds : double.infinity)
        .toDouble();
    _audioCtrl = TextEditingController(text: _formatMmSs(initAudio));
    _eegCtrl = TextEditingController(text: _formatMmSs(ctrl.eegSec));
    _offsetCtrl = TextEditingController(text: seg.offsetSeconds.toStringAsFixed(2));
    final initClock = ctrl.eegStartTime == null
        ? ''
        : _formatClockTime(
            ctrl.eegStartTime!.add(Duration(microseconds: (seg.offsetSeconds * 1e6).round())),
          );
    _clockCtrl = TextEditingController(text: initClock);
  }

  @override
  void dispose() {
    _audioCtrl.dispose();
    _eegCtrl.dispose();
    _offsetCtrl.dispose();
    _clockCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.ctrl;
    final seg = widget.seg;
    return AlertDialog(
      title: Text('Sync "${seg.label}" with EEG', style: const TextStyle(fontSize: 15)),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Works for independent phone, recorder, or laptop files (no video required):',
                style: TextStyle(fontSize: 11.5, color: const Color(0xFF475569)),
              ),
              const SizedBox(height: 12),
              const Text(
                '1. Match Landmark (Audio time ↔ EEG time)',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              const Text(
                'Pick a shared moment you can hear/see in the media and locate on the EEG plot '
                '(e.g. a clap, bell, verbal cue, or bell silence). Accepts seconds or mm:ss.',
                style: TextStyle(fontSize: 11, color: const Color(0xFF475569)),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _audioCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Audio time (mm:ss or s)',
                        isDense: true,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      final cur = (ctrl.cursorEpoch - ctrl.segmentStartEpoch(seg))
                          .clamp(
                            0.0,
                            seg.durationSeconds > 0 ? seg.durationSeconds : double.infinity,
                          )
                          .toDouble();
                      _audioCtrl.text = _formatMmSs(cur);
                    },
                    child: const Text('Now', style: TextStyle(fontSize: 11)),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _eegCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Matching EEG time (mm:ss or s)',
                        isDense: true,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => _eegCtrl.text = _formatMmSs(ctrl.eegSec),
                    child: const Text('Now', style: TextStyle(fontSize: 11)),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonal(
                  onPressed: () {
                    final aSec = MediaSyncController.parseFlexibleTimeSec(_audioCtrl.text);
                    final eSec = MediaSyncController.parseFlexibleTimeSec(_eegCtrl.text);
                    if (aSec == null || eSec == null) {
                      setState(() => _errorMsg = 'Enter valid times (seconds, mm:ss, or hh:mm:ss).');
                      return;
                    }
                    final newOff = eSec - aSec;
                    ctrl.setSegmentOffset(
                      seg,
                      newOff,
                      source: 'landmark sync',
                      note: 'Landmark sync: audio ${_audioCtrl.text.trim()} → EEG ${_eegCtrl.text.trim()} '
                          '(offset ${newOff >= 0 ? '+' : '−'}${newOff.abs().toStringAsFixed(2)} s)',
                    );
                    Navigator.pop(context);
                  },
                  child: const Text('Apply landmark'),
                ),
              ),
              const Divider(height: 20),
              const Text(
                '2. Direct Offset (seconds relative to EEG start)',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final step in const [-60.0, -10.0, -1.0, 1.0, 10.0, 60.0])
                    ActionChip(
                      label: Text(
                        '${step > 0 ? '+' : '−'}${step.abs().toStringAsFixed(0)}s',
                        style: const TextStyle(fontSize: 10.5),
                      ),
                      visualDensity: VisualDensity.compact,
                      onPressed: () {
                        final cur = MediaSyncController.parseFlexibleTimeSec(_offsetCtrl.text) ??
                            seg.offsetSeconds;
                        _offsetCtrl.text = (cur + step).toStringAsFixed(2);
                      },
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _offsetCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Offset (s or mm:ss; negative = started before EEG)',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonal(
                    onPressed: () {
                      final v = MediaSyncController.parseFlexibleTimeSec(_offsetCtrl.text);
                      if (v == null) {
                        setState(() => _errorMsg = 'Invalid offset value.');
                        return;
                      }
                      ctrl.setSegmentOffset(seg, v, source: 'manual offset');
                      Navigator.pop(context);
                    },
                    child: const Text('Apply offset'),
                  ),
                ],
              ),
              if (ctrl.eegStartTime != null) ...[
                const Divider(height: 20),
                const Text(
                  '3. Device Start Wall-Clock (HH:MM:SS)',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  'EEG started at ${_formatClockTime(ctrl.eegStartTime!)}. Enter the true local '
                  'start time when the phone/recorder started:',
                  style: const TextStyle(fontSize: 11, color: const Color(0xFF475569)),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _clockCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Media start clock (HH:MM:SS)',
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonal(
                      onPressed: () {
                        final dt = _parseWallClockNearestTime(_clockCtrl.text, ctrl.eegStartTime!);
                        if (dt == null) {
                          setState(() => _errorMsg = 'Enter start clock as HH:MM:SS (24-hour).');
                          return;
                        }
                        final off = dt.difference(ctrl.eegStartTime!).inMicroseconds / 1e6;
                        ctrl.setSegmentOffset(
                          seg,
                          off,
                          source: 'manual wall-clock',
                          note: 'Manual wall-clock (${_clockCtrl.text.trim()}): media starts '
                              '${off >= 0 ? '+' : '−'}${off.abs().toStringAsFixed(2)} s relative to EEG',
                        );
                        Navigator.pop(context);
                      },
                      child: const Text('Apply clock'),
                    ),
                  ],
                ),
              ],
              if (_errorMsg != null) ...[
                const SizedBox(height: 10),
                Text(_errorMsg!, style: const TextStyle(color: const Color(0xFFDC2626), fontSize: 11)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

void _paintLabel(Canvas canvas, String text, Offset at, {Color color = const Color(0xFF475569), double size = 10, double maxWidth = 900}) {
  final tp = TextPainter(
    text: TextSpan(text: text, style: TextStyle(color: color, fontSize: size)),
    textDirection: TextDirection.ltr,
    maxLines: 1,
    ellipsis: '…',
  )..layout(maxWidth: maxWidth);
  tp.paint(canvas, at);
}

void _dashedHLine(Canvas canvas, double x0, double x1, double y, Paint paint) {
  const on = 4.0, off = 3.0;
  for (var x = x0; x < x1; x += on + off) {
    canvas.drawLine(Offset(x, y), Offset(math.min(x + on, x1), y), paint);
  }
}

/// Waveform + envelope of one media file mapped over its own full width
/// (used inside the floating media panel).
class AudioWaveformEnvelopePainter extends CustomPainter {
  const AudioWaveformEnvelopePainter({
    required this.minBins,
    required this.maxBins,
    required this.envelope,
    required this.cursorFrac,
    this.showWaveform = true,
    this.showEnvelope = true,
    this.viewStartFrac = 0.0,
    this.viewEndFrac = 1.0,
  });

  final bool showWaveform, showEnvelope;
  final List<double> minBins;
  final List<double> maxBins;
  final List<double> envelope;
  final double cursorFrac;
  final double viewStartFrac;
  final double viewEndFrac;

  @override
  void paint(Canvas canvas, Size size) {
    final n = minBins.length;
    final spanFrac = (viewEndFrac - viewStartFrac).clamp(1e-6, 1.0);
    if (n < 2) return;
    final midY = size.height / 2;
    var maxPeak = 1e-4;
    for (var i = 0; i < n; i++) {
      maxPeak = math.max(maxPeak, math.max(minBins[i].abs(), maxBins[i].abs()));
    }
    final wavePaint = Paint()
      ..color = const Color(0xFF3B6EA5).withValues(alpha: 0.45)
      ..strokeWidth = 1.0;
    for (var i = 0; showWaveform && i < n; i++) {
      final frac = i / (n - 1);
      if (frac < viewStartFrac || frac > viewEndFrac) continue;
      final x = (frac - viewStartFrac) / spanFrac * size.width;
      final y0 = midY - (maxBins[i] / maxPeak).clamp(-1.0, 1.0) * (midY - 4);
      final y1 = midY - (minBins[i] / maxPeak).clamp(-1.0, 1.0) * (midY - 4);
      canvas.drawLine(Offset(x, y0), Offset(x, y1), wavePaint);
    }

    if (showEnvelope && envelope.length >= 2) {
      var envMax = 1e-4;
      for (final e in envelope) {
        if (e > envMax) envMax = e;
      }
      final path = Path();
      var pen = false;
      for (var i = 0; i < envelope.length; i++) {
        final frac = i / (envelope.length - 1);
        if (frac < viewStartFrac || frac > viewEndFrac) continue;
        final x = (frac - viewStartFrac) / spanFrac * size.width;
        final y = size.height - 4 - (envelope[i] / envMax).clamp(0.0, 1.0) * (size.height - 10);
        if (!pen) {
          path.moveTo(x, y);
          pen = true;
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = const Color(0xFFD97706)
          ..strokeWidth = 1.4
          ..style = PaintingStyle.stroke,
      );
    }

    final cx = ((cursorFrac - viewStartFrac) / spanFrac).clamp(0.0, 1.0) * size.width;
    canvas.drawLine(
      Offset(cx, 0),
      Offset(cx, size.height),
      Paint()
        ..color = const Color(0xFFDC2626)
        ..strokeWidth = 1.8,
    );
  }

  @override
  bool shouldRepaint(covariant AudioWaveformEnvelopePainter old) =>
      old.showWaveform != showWaveform || old.showEnvelope != showEnvelope || old.cursorFrac != cursorFrac ||
      old.viewStartFrac != viewStartFrac ||
      old.viewEndFrac != viewEndFrac ||
      !identical(old.minBins, minBins) ||
      !identical(old.envelope, envelope);
}

/// Waveform + envelope drawn on a **session's own time axis**, inside the exact
/// horizontal span [left, right] of that session's feature line plot, so a
/// vertical line through both is the same instant. Media outside
/// [axisStartSec, axisEndSec] is clipped; the label names the audio source.
class SessionAlignedAudioPainter extends CustomPainter {
  const SessionAlignedAudioPainter({
    required this.minBins,
    required this.maxBins,
    required this.envelope,
    required this.segStartSec,
    required this.segDurationSec,
    required this.axisEndSec,
    required this.left,
    required this.right,
    required this.label,
    this.cursorSec,
    this.showWaveform = true,
    this.showEnvelope = true,
  });

  final bool showWaveform, showEnvelope;
  final List<double> minBins;
  final List<double> maxBins;
  final List<double> envelope;

  /// Where the media begins on the session axis (seconds; may be negative).
  final double segStartSec;
  final double segDurationSec;
  final double axisEndSec;
  final double left;
  final double right;
  final String label;
  final double? cursorSec;

  double _x(double t) => left + t / axisEndSec * (right - left);

  @override
  void paint(Canvas canvas, Size size) {
    if (axisEndSec <= 0 || right <= left) return;
    canvas.drawRect(
      Rect.fromLTRB(left, 0, right, size.height),
      Paint()..color = const Color(0xFF020617),
    );
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(left, 0, right, size.height));
    final n = minBins.length;
    if (n >= 2 && segDurationSec > 0) {
      final midY = size.height / 2;
      var maxPeak = 1e-4;
      for (var i = 0; i < n; i++) {
        maxPeak = math.max(maxPeak, math.max(minBins[i].abs(), maxBins[i].abs()));
      }
      final wave = Paint()
        ..color = const Color(0xFF3B6EA5).withValues(alpha: 0.5)
        ..strokeWidth = 1.0;
      for (var i = 0; showWaveform && i < n; i++) {
        final t = segStartSec + i / (n - 1) * segDurationSec;
        if (t < 0 || t > axisEndSec) continue;
        final x = _x(t);
        final y0 = midY - (maxBins[i] / maxPeak).clamp(-1.0, 1.0) * (midY - 4);
        final y1 = midY - (minBins[i] / maxPeak).clamp(-1.0, 1.0) * (midY - 4);
        canvas.drawLine(Offset(x, y0), Offset(x, y1), wave);
      }
      if (showEnvelope && envelope.length >= 2) {
        var envMax = 1e-4;
        for (final e in envelope) {
          if (e > envMax) envMax = e;
        }
        final path = Path();
        var pen = false;
        for (var i = 0; i < envelope.length; i++) {
          final t = segStartSec + i / (envelope.length - 1) * segDurationSec;
          if (t < 0 || t > axisEndSec) {
            pen = false;
            continue;
          }
          final x = _x(t);
          final y = size.height - 4 - (envelope[i] / envMax).clamp(0.0, 1.0) * (size.height - 10);
          if (!pen) {
            path.moveTo(x, y);
            pen = true;
          } else {
            path.lineTo(x, y);
          }
        }
        canvas.drawPath(
          path,
          Paint()
            ..color = const Color(0xFFD97706)
            ..strokeWidth = 1.4
            ..style = PaintingStyle.stroke,
        );
      }
    }
    final c = cursorSec;
    if (c != null && c >= 0 && c <= axisEndSec) {
      canvas.drawLine(
        Offset(_x(c), 0),
        Offset(_x(c), size.height),
        Paint()
          ..color = const Color(0xFFEF4444)
          ..strokeWidth = 1.6,
      );
    }
    _paintLabel(canvas, label, Offset(left + 6, 3), color: const Color(0xFFD97706), size: 10, maxWidth: math.max(1, right - left - 12));
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant SessionAlignedAudioPainter old) =>
      old.showWaveform != showWaveform || old.showEnvelope != showEnvelope || old.cursorSec != cursorSec ||
      old.segStartSec != segStartSec ||
      old.axisEndSec != axisEndSec ||
      old.left != left ||
      old.right != right ||
      old.label != label ||
      !identical(old.minBins, minBins);
}

/// Sliding-window Neural Speech Tracking drawn on a session's time axis, in the
/// same horizontal span as the feature plot. Correlation measures envelope
/// prediction, not speech presence or attention; inspect silence and artifacts.
class TrackingSeriesPainter extends CustomPainter {
  const TrackingSeriesPainter({
    required this.series,
    required this.axisStartSec,
    required this.axisEndSec,
    required this.left,
    required this.right,
    this.cursorSec,
    this.compact = false,
  });

  final SpeechTrackingSeries series;
  final double axisStartSec;
  final double axisEndSec;
  final double left;
  final double right;
  final double? cursorSec;
  final bool compact;

  @override
  void paint(Canvas canvas, Size size) {
    final span = axisEndSec - axisStartSec;
    if (span <= 0 || right <= left || series.timesSec.isEmpty) return;
    double xOf(double t) => left + (t - axisStartSec) / span * (right - left);

    var lo = 0.0, hi = 0.15;
    for (final v in [...series.decoderR, ...series.encodingR]) {
      if (v.isFinite) {
        lo = math.min(lo, v);
        hi = math.max(hi, v);
      }
    }
    hi = math.max(hi, math.max(series.decoderNull95, series.encodingNull95)) * 1.1;
    lo = lo < 0 ? lo * 1.1 : 0.0;
    double yOf(double v) => size.height - 3 - (v - lo) / (hi - lo) * (size.height - 6);

    canvas.drawRect(
      Rect.fromLTRB(left, 0, right, size.height),
      Paint()..color = const Color(0xFF020617),
    );
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(left, 0, right, size.height));
    canvas.drawLine(
      Offset(left, yOf(0)),
      Offset(right, yOf(0)),
      Paint()
        ..color = const Color(0xFFCBD5E1)
        ..strokeWidth = 1,
    );
    const decColor = const Color(0xFF0284C7);
    const encColor = const Color(0xFFD97706);
    _dashedHLine(canvas, left, right, yOf(series.decoderNull95),
        Paint()..color = decColor.withValues(alpha: 0.5)..strokeWidth = 1);
    _dashedHLine(canvas, left, right, yOf(series.encodingNull95),
        Paint()..color = encColor.withValues(alpha: 0.5)..strokeWidth = 1);

    Path line(List<double> v) {
      final p = Path();
      var pen = false;
      for (var i = 0; i < v.length && i < series.timesSec.length; i++) {
        if (!v[i].isFinite) {
          pen = false;
          continue;
        }
        final o = Offset(xOf(series.timesSec[i]), yOf(v[i]));
        if (!pen) {
          p.moveTo(o.dx, o.dy);
          pen = true;
        } else {
          p.lineTo(o.dx, o.dy);
        }
      }
      return p;
    }

    canvas.drawPath(
      line(series.encodingR),
      Paint()
        ..color = encColor
        ..strokeWidth = 1.4
        ..style = PaintingStyle.stroke,
    );
    canvas.drawPath(
      line(series.decoderR),
      Paint()
        ..color = decColor
        ..strokeWidth = 1.8
        ..style = PaintingStyle.stroke,
    );
    // Dots where the decoder beats chance
    final dot = Paint()..color = decColor;
    for (var i = 0; i < series.decoderR.length && i < series.timesSec.length; i++) {
      if (series.decoderR[i] > series.decoderNull95) {
        canvas.drawCircle(Offset(xOf(series.timesSec[i]), yOf(series.decoderR[i])), 1.8, dot);
      }
    }
    final c = cursorSec;
    if (c != null && c >= axisStartSec && c <= axisEndSec) {
      canvas.drawLine(
        Offset(xOf(c), 0),
        Offset(xOf(c), size.height),
        Paint()
          ..color = const Color(0xFFEF4444)
          ..strokeWidth = 1.6,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant TrackingSeriesPainter old) =>
      old.cursorSec != cursorSec ||
      !identical(old.series, series) ||
      old.axisEndSec != axisEndSec ||
      old.left != left ||
      old.right != right;
}
