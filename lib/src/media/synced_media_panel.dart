import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'media_sync_service.dart';

/// Master controller syncing multiple timestamped video/audio files,
/// extracted audio waveform + envelope, and EEG/feature cursors.
class MediaSyncController extends ChangeNotifier {
  MediaSyncController({
    required this.eegPath,
    required this.eegDurationSec,
    this.eegStartTime,
    this.onTimeChanged,
  }) {
    _player = Player();
    _videoController = VideoController(_player);
    _posSub = _player.stream.position.listen((pos) {
      final seg = activeSegment;
      if (seg != null && _playing) {
        final t = (seg.offsetSeconds + pos.inMilliseconds / 1000.0)
            .clamp(0.0, eegDurationSec);
        if ((t - _eegSec).abs() > 0.04) {
          _eegSec = t;
          onTimeChanged?.call(_eegSec);
          notifyListeners();
        }
      }
    });
    _playSub = _player.stream.playing.listen((p) {
      if (_playing != p) {
        _playing = p;
        notifyListeners();
      }
    });
  }

  final String eegPath;
  final double eegDurationSec;
  final DateTime? eegStartTime;
  void Function(double eegSec)? onTimeChanged;

  late final Player _player;
  late final VideoController _videoController;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<bool>? _playSub;

  final List<SyncedMediaSegment> segments = [];
  int _activeIndex = -1;
  double _eegSec = 0.0;
  bool _playing = false;
  bool _muted = false;
  double _rate = 1.0;
  bool _busy = false;
  String? _status;

  VideoController get videoController => _videoController;
  double get eegSec => _eegSec;
  bool get playing => _playing;
  bool get muted => _muted;
  double get playbackRate => _rate;
  bool get busy => _busy;
  String? get status => _status;
  SyncedMediaSegment? get activeSegment =>
      (_activeIndex >= 0 && _activeIndex < segments.length)
          ? segments[_activeIndex]
          : null;

  Future<void> addMediaFiles(List<String> paths) async {
    _busy = true;
    _status = 'Probing media timestamps & extracting waveform/envelope…';
    notifyListeners();
    try {
      for (final path in paths) {
        final isVid = MediaSyncService.isVideoPath(path);
        final (startDt, probedDur, tsSource) =
            await MediaSyncService.probeMediaMetadata(path);
        double offset = 0.0;
        if (eegStartTime != null && startDt != null) {
          offset = startDt.difference(eegStartTime!).inMilliseconds / 1000.0;
        } else if (segments.isNotEmpty) {
          final last = segments.last;
          offset = last.offsetSeconds + last.durationSeconds;
        }

        final wavPath = await MediaSyncService.ensureWavAudio(path);
        final env = await MediaSyncService.extractEnvelope(wavPath);
        final dur = probedDur > 0 ? probedDur : env.durationSeconds;

        final seg = SyncedMediaSegment(
          path: path,
          label: path.split(RegExp(r'[\\/]')).last,
          isVideo: isVid,
          offsetSeconds: offset,
          durationSeconds: dur,
          extractedWavPath: isVid ? wavPath : null,
          timestampSource: tsSource,
          waveformMin: env.displayMin,
          waveformMax: env.displayMax,
          envelopePreview: env.envelopePreview,
        );
        segments.add(seg);
      }
      segments.sort((a, b) => a.offsetSeconds.compareTo(b.offsetSeconds));
      await _selectSegmentForTime(_eegSec, forceOpen: true);
      _status = '${segments.length} synced media file(s) ready';
    } catch (e) {
      _status = 'Media load warning: $e';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> seekToEegTime(double sec, {bool notifyExternal = false}) async {
    _eegSec = sec.clamp(0.0, math.max(0.0, eegDurationSec));
    if (notifyExternal) onTimeChanged?.call(_eegSec);
    await _selectSegmentForTime(_eegSec);
    final seg = activeSegment;
    if (seg != null) {
      final localMs = ((_eegSec - seg.offsetSeconds) * 1000)
          .round()
          .clamp(0, (seg.durationSeconds * 1000).round());
      await _player.seek(Duration(milliseconds: localMs));
    }
    notifyListeners();
  }

  Future<void> _selectSegmentForTime(
    double sec, {
    bool forceOpen = false,
  }) async {
    if (segments.isEmpty) return;
    var targetIdx = segments.indexWhere(
      (s) => sec >= s.offsetSeconds && sec <= s.offsetSeconds + s.durationSeconds,
    );
    if (targetIdx < 0) targetIdx = 0;
    if (forceOpen || targetIdx != _activeIndex) {
      _activeIndex = targetIdx;
      await _player.open(Media(segments[targetIdx].path), play: _playing);
      await _player.setRate(_rate);
      await _player.setVolume(_muted ? 0 : 100);
    }
  }

  Future<void> togglePlay() async {
    if (segments.isEmpty) return;
    if (_activeIndex < 0) await _selectSegmentForTime(_eegSec, forceOpen: true);
    if (_playing) {
      await _player.pause();
    } else {
      await _player.play();
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

  void nudgeActiveOffset(double deltaSec) {
    final seg = activeSegment;
    if (seg == null) return;
    seg.offsetSeconds += deltaSec;
    notifyListeners();
    unawaited(seekToEegTime(_eegSec));
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _playSub?.cancel();
    unawaited(_player.dispose());
    super.dispose();
  }
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
  SpeechTrackingSummary? _tracking;
  bool _runningTracking = false;
  String? _trackingError;

  Future<void> _runSpeechTracking() async {
    final seg = widget.controller.activeSegment;
    final wav = seg?.audioPath;
    if (seg == null || wav == null) return;
    setState(() {
      _runningTracking = true;
      _trackingError = null;
    });
    try {
      final res = await MediaSyncService.runSpeechTracking(
        eegPath: widget.controller.eegPath,
        wavPath: wav,
        audioOffsetSeconds: seg.offsetSeconds,
      );
      if (mounted) setState(() => _tracking = res);
    } catch (e) {
      if (mounted) setState(() => _trackingError = '$e');
    } finally {
      if (mounted) setState(() => _runningTracking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final ctrl = widget.controller;
        final seg = ctrl.activeSegment;
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
                        child: Text(
                          seg == null
                              ? 'Synced Video & Audio'
                              : '${seg.label} (${seg.timestampSource})',
                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
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
              if (ctrl.busy) const LinearProgressIndicator(minHeight: 2),
              if (seg != null && seg.isVideo)
                Expanded(
                  flex: 3,
                  child: Container(
                    color: Colors.black,
                    child: Video(controller: ctrl.videoController),
                  ),
                )
              else
                Expanded(
                  flex: 1,
                  child: Center(
                    child: Text(
                      seg == null
                          ? 'Click "Add Video/Audio" to load video or WAV audio synced by timestamp.'
                          : 'Audio file synced (${seg.durationSeconds.toStringAsFixed(1)} s @ offset ${seg.offsetSeconds.toStringAsFixed(2)} s)',
                      style: const TextStyle(fontSize: 11, color: Colors.white70),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              // Audio Waveform + Envelope Strip with time-locked cursor
              if (seg != null && seg.waveformMax.isNotEmpty)
                GestureDetector(
                  onTapDown: (d) {
                    final box = context.findRenderObject() as RenderBox?;
                    if (box == null) return;
                    final frac = (d.localPosition.dx / box.size.width).clamp(0.0, 1.0);
                    ctrl.seekToEegTime(
                      seg.offsetSeconds + frac * seg.durationSeconds,
                      notifyExternal: true,
                    );
                  },
                  child: Container(
                    height: 62,
                    margin: const EdgeInsets.fromLTRB(8, 4, 8, 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFF020617),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: CustomPaint(
                      painter: _AudioWaveformEnvelopePainter(
                        minBins: seg.waveformMin,
                        maxBins: seg.waveformMax,
                        envelope: seg.envelopePreview,
                        cursorFrac: seg.durationSeconds > 0
                            ? ((ctrl.eegSec - seg.offsetSeconds) / seg.durationSeconds)
                                .clamp(0.0, 1.0)
                            : 0.0,
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
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
                      Text(
                        'Off:${seg.offsetSeconds.toStringAsFixed(1)}s',
                        style: const TextStyle(fontSize: 10, color: Colors.white70),
                      ),
                      TextButton(
                        onPressed: () => ctrl.nudgeActiveOffset(1.0),
                        style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                        child: const Text('+1s', style: TextStyle(fontSize: 10)),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: _runningTracking ? null : _runSpeechTracking,
                        icon: const Icon(Icons.graphic_eq, size: 13),
                        label: Text(
                          _runningTracking ? 'TRF…' : 'Neural Speech Tracking',
                          style: const TextStyle(fontSize: 10),
                        ),
                        style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
                      ),
                    ],
                  ],
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
              if (_tracking != null)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.fromLTRB(8, 2, 8, 6),
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: Colors.teal.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.tealAccent.withValues(alpha: 0.35)),
                  ),
                  child: Text(
                    'TRF Encoding Best: ${_tracking!.bestChannel} (r=${_tracking!.bestEncodingR.toStringAsFixed(3)}) · '
                    'Decoder Reconstruction r=${_tracking!.decoderReconstructionR.toStringAsFixed(3)} '
                    '(p≈${_tracking!.decoderPApprox.toStringAsExponential(1)}, ${_tracking!.overlapSeconds.toStringAsFixed(1)} s overlap)',
                    style: const TextStyle(fontSize: 10, color: Colors.tealAccent),
                  ),
                ),
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

class _AudioWaveformEnvelopePainter extends CustomPainter {
  const _AudioWaveformEnvelopePainter({
    required this.minBins,
    required this.maxBins,
    required this.envelope,
    required this.cursorFrac,
  });

  final List<double> minBins;
  final List<double> maxBins;
  final List<double> envelope;
  final double cursorFrac;

  @override
  void paint(Canvas canvas, Size size) {
    final n = minBins.length;
    if (n < 2) return;
    final midY = size.height / 2;
    var maxPeak = 1e-4;
    for (var i = 0; i < n; i++) {
      maxPeak = math.max(maxPeak, math.max(minBins[i].abs(), maxBins[i].abs()));
    }
    final wavePaint = Paint()
      ..color = Colors.lightBlueAccent.withValues(alpha: 0.45)
      ..strokeWidth = 1.0;
    for (var i = 0; i < n; i++) {
      final x = i / (n - 1) * size.width;
      final y0 = midY - (maxBins[i] / maxPeak).clamp(-1.0, 1.0) * (midY - 4);
      final y1 = midY - (minBins[i] / maxPeak).clamp(-1.0, 1.0) * (midY - 4);
      canvas.drawLine(Offset(x, y0), Offset(x, y1), wavePaint);
    }

    if (envelope.length >= 2) {
      var envMax = 1e-4;
      for (final e in envelope) {
        if (e > envMax) envMax = e;
      }
      final path = Path();
      for (var i = 0; i < envelope.length; i++) {
        final x = i / (envelope.length - 1) * size.width;
        final y = size.height - 4 - (envelope[i] / envMax).clamp(0.0, 1.0) * (size.height - 10);
        if (i == 0) {
          path.moveTo(x, y);
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

    final cx = cursorFrac.clamp(0.0, 1.0) * size.width;
    canvas.drawLine(
      Offset(cx, 0),
      Offset(cx, size.height),
      Paint()
        ..color = Colors.redAccent
        ..strokeWidth = 1.8,
    );
  }

  @override
  bool shouldRepaint(covariant _AudioWaveformEnvelopePainter old) =>
      old.cursorFrac != cursorFrac || old.minBins != minBins;
}
