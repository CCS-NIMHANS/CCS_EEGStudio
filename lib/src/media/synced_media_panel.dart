import 'dart:async';
import 'dart:typed_data';
import 'dart:math' as math;

import 'package:flutter/material.dart';
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
    final wavPath = await MediaSyncService.ensureWavAudio(path);
    final env = await MediaSyncService.extractEnvelope(wavPath);
    final dur = probedDur > 0 ? probedDur : env.durationSeconds;

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

    final seg = SyncedMediaSegment(
      path: path,
      label: label,
      isVideo: isVid,
      offsetSeconds: offset ?? 0.0,
      durationSeconds: dur,
      extractedWavPath: isVid ? wavPath : null,
      timestampSource: source,
      syncNote: note,
      waveformMin: env.displayMin,
      waveformMax: env.displayMax,
      envelopePreview: env.envelopePreview,
    );

    if (offset == null) {
      // No usable clock: align by speech envelope to a loaded video, else assume.
      final ok = !isVid && await _autoAlign(seg, wavPath);
      if (!ok) {
        final last = segments.isEmpty
            ? null
            : segments.reduce((a, b) => a.offsetSeconds > b.offsetSeconds ? a : b);
        seg.offsetSeconds = last == null ? 0.0 : last.offsetSeconds + last.durationSeconds;
        seg.syncNote = '${seg.syncNote.isEmpty ? '' : '${seg.syncNote}. '}'
            'No clock: placed ${last == null ? 'at the EEG start' : 'after the previous file'}. '
            'Add the matching video to auto-align, or use −/+ to nudge.';
        seg.alignmentSource = 'assumed (no timestamp)';
      }
    }
    segments.add(seg);
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
    seg.offsetSeconds = bestRef.offsetSeconds + best.lagSeconds;
    seg.alignmentSource = 'auto-aligned to video audio';
    seg.syncNote = 'Auto-aligned to the audio of ${bestRef.label}: starts '
        '${best.lagSeconds >= 0 ? '+' : '−'}${best.lagSeconds.abs().toStringAsFixed(2)} s '
        '(speech-envelope r=${best.peakR.toStringAsFixed(2)}, z=${best.confidence.toStringAsFixed(1)})';
    return true;
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
      _status = ok ? seg.syncNote : 'Could not find a confident match in the loaded video audio.';
      await seekToEpoch(_cursorEpoch);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  // ── Transport ──────────────────────────────────────────────────────────

  int _indexCovering(double epoch) {
    if (segments.isEmpty) return -1;
    bool covers(SyncedMediaSegment s) =>
        epoch >= segmentStartEpoch(s) && epoch <= segmentEndEpoch(s);
    final cur = activeSegment;
    if (cur != null && covers(cur)) return _activeIndex;
    var idx = segments.indexWhere((s) => s.isVideo && covers(s));
    if (idx < 0) idx = segments.indexWhere(covers);
    return idx;
  }

  Future<void> seekToEegTime(double sec, {bool notifyExternal = false}) =>
      seekToEpoch(primaryStartEpoch + sec, notifyExternal: notifyExternal);

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
          final local = (target - segmentStartEpoch(seg)).clamp(0.0, math.max(0.0, seg.durationSeconds - 0.05)).toDouble();
          if (seg.isVideo && !_playing && _pendingSeekEpoch == null) {
            // Render first: a blocked native seek must not leave an old frame
            // under the newly updated EEG cursor.
            final frame = await MediaSyncService.videoFrame(seg.path, local);
            if (_pendingSeekEpoch == null && !_disposed && !_playing) {
              previewFrame = frame;
              previewLoading = false;
              notifyListeners();
            }
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
    await _player.setRate(_rate);
    await _player.setVolume(_muted ? 0 : 100);
    if (resumePlayback) await _player.play();
  }

  void _onPlayerPosition(Duration pos) {
    final seg = activeSegment;
    if (seg == null || !_playing || _outOfRange) return;
    // Ignore stale position events that arrive right after a seek.
    if (DateTime.now().difference(_lastSeek).inMilliseconds < 350) return;
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

  /// Shifts the active media later (+) or earlier (−) on the EEG timeline.
  void nudgeActiveOffset(double deltaSec) {
    final seg = activeSegment;
    if (seg == null) return;
    seg.offsetSeconds += deltaSec;
    seg.alignmentSource = 'manual nudge';
    notifyListeners();
    unawaited(seekToEpoch(_cursorEpoch));
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
      throw StateError(
        'No loaded video/audio overlaps this EEG session. Load the media that was '
        'recorded during it (the media and EEG clocks must overlap).',
      );
    }
    final wav = seg.audioPath;
    if (wav == null) throw StateError('No audio is available for ${seg.label}.');
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
    required this.onClose,
    required this.onMove,
    required this.onResize,
  });

  final MediaSyncController controller;
  final VoidCallback onAddFiles;
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
          color: const Color(0xFF0F172A),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: Color(0xFF334155)),
          ),
          child: Column(
            children: [
              // Draggable Title Bar
              GestureDetector(
                onPanUpdate: (d) => widget.onMove(d.delta),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: const BoxDecoration(
                    color: Color(0xFF1E293B),
                    borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.ondemand_video, size: 15, color: Colors.cyanAccent),
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
              if (ctrl.busy || ctrl.trackingBusy) const LinearProgressIndicator(minHeight: 2),
              if (ctrl.status?.startsWith('Playback error:') == true)
                Padding(padding: const EdgeInsets.all(6), child: Text(ctrl.status!, style: const TextStyle(color: Colors.orange, fontSize: 11))),
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
                      if (!ctrl.playing && ctrl.previewFrame != null)
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
                            style: const TextStyle(fontSize: 11, color: Colors.amberAccent),
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
                      style: const TextStyle(fontSize: 11, color: Colors.white70),
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
                          size: 12, color: Colors.amberAccent),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Tooltip(
                          message: '${seg.path}\n${seg.syncNote}',
                          child: Text(
                            'Blue: waveform · Yellow: speech envelope · ${seg.audioSourceDescription}',
                            style: const TextStyle(fontSize: 9.5, color: Colors.white70),
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
                                    ? Colors.cyanAccent.withValues(alpha: 0.22)
                                    : Colors.white10,
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                  color: _windowHalfSec == opt.$2
                                      ? Colors.cyanAccent
                                      : Colors.white24,
                                  width: 0.7,
                                ),
                              ),
                              child: Text(
                                opt.$1,
                                style: TextStyle(
                                  fontSize: 9,
                                  color: _windowHalfSec == opt.$2
                                      ? Colors.cyanAccent
                                      : Colors.white70,
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
                    color: const Color(0xFF020617),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.white12),
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
                      style: const TextStyle(fontSize: 10, color: Colors.cyanAccent),
                    ),
                    if (seg != null) ...[
                      TextButton(
                        onPressed: () => ctrl.nudgeActiveOffset(-1.0),
                        style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                        child: const Text('−1s', style: TextStyle(fontSize: 10)),
                      ),
                      TextButton(
                        onPressed: () => ctrl.nudgeActiveOffset(-0.1),
                        style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                        child: const Text('−0.1', style: TextStyle(fontSize: 10)),
                      ),
                      Tooltip(
                        message: 'Media start relative to this EEG recording\n${seg.syncNote}',
                        child: Text(
                          'Off:${seg.offsetSeconds.toStringAsFixed(1)}s',
                          style: const TextStyle(fontSize: 10, color: Colors.white70),
                        ),
                      ),
                      TextButton(
                        onPressed: () => ctrl.nudgeActiveOffset(0.1),
                        style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                        child: const Text('+0.1', style: TextStyle(fontSize: 10)),
                      ),
                      TextButton(
                        onPressed: () => ctrl.nudgeActiveOffset(1.0),
                        style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                        child: const Text('+1s', style: TextStyle(fontSize: 10)),
                      ),
                      if (!seg.isVideo && ctrl.segments.any((s) => s.isVideo))
                        TextButton.icon(
                          onPressed: ctrl.busy ? null : ctrl.autoAlignActiveToVideo,
                          icon: const Icon(Icons.sync, size: 12),
                          label: const Text('Align to video', style: TextStyle(fontSize: 10)),
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
                    style: const TextStyle(fontSize: 9.5, color: Colors.white54),
                  ),
                ),
              if (_trackingError != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  child: Text(
                    _trackingError!,
                    style: const TextStyle(fontSize: 10, color: Colors.redAccent),
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
                    border: Border.all(color: Colors.tealAccent.withValues(alpha: 0.35)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'TRF Encoding Best: ${tracking.bestChannel} (r=${tracking.bestEncodingR.toStringAsFixed(3)}) · '
                        'Decoder Reconstruction r=${tracking.decoderReconstructionR.toStringAsFixed(3)} '
                        '(p≈${tracking.decoderPApprox.toStringAsExponential(1)}, ${tracking.overlapSeconds.toStringAsFixed(1)} s overlap) — '
                        'time series shown in Plots & Report',
                        style: const TextStyle(fontSize: 10, color: Colors.tealAccent),
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
                    child: Icon(Icons.drag_handle, size: 14, color: Colors.white38),
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

void _paintLabel(Canvas canvas, String text, Offset at, {Color color = Colors.white70, double size = 10, double maxWidth = 900}) {
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
      ..color = Colors.lightBlueAccent.withValues(alpha: 0.45)
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
          ..color = Colors.amberAccent
          ..strokeWidth = 1.4
          ..style = PaintingStyle.stroke,
      );
    }

    final cx = ((cursorFrac - viewStartFrac) / spanFrac).clamp(0.0, 1.0) * size.width;
    canvas.drawLine(
      Offset(cx, 0),
      Offset(cx, size.height),
      Paint()
        ..color = Colors.redAccent
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
        ..color = Colors.lightBlueAccent.withValues(alpha: 0.5)
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
            ..color = Colors.amberAccent
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
    _paintLabel(canvas, label, Offset(left + 6, 3), color: Colors.amberAccent, size: 10, maxWidth: math.max(1, right - left - 12));
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
        ..color = Colors.white24
        ..strokeWidth = 1,
    );
    const decColor = Colors.cyanAccent;
    const encColor = Colors.amberAccent;
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
