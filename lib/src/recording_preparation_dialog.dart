import 'recording_storage.dart';
import 'recording_save_dialog.dart';
import 'dart:math' as math;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'models.dart';
import 'recording_loader.dart';
import 'recording_transform.dart';

class RecordingPreparationDialog extends StatefulWidget {
  const RecordingPreparationDialog({super.key, required this.recording});
  final EegRecording recording;
  @override
  State<RecordingPreparationDialog> createState() => _PreparationState();
}

class _PreparationState extends State<RecordingPreparationDialog> {
  late final TextEditingController start, end;
  final window = TextEditingController(text: '2'),
      overlap = TextEditingController(text: '0');
  bool crop = true,
      subepoch = false,
      durationMode = false,
      markers = false,
      busy = false;
  String scope = 'within';
  int? startMarker, endMarker;
  String? error;
  final List<(double, double)> badSegments = [];
  double? _dragStartSec;
  double? _dragCurrentSec;
  bool get epoched => widget.recording.pointsPerEpoch != null;
  double get timeOrigin =>
      epoched && scope == 'within' ? (widget.recording.epochTmin ?? 0) : 0;
  double get limit => epoched && scope == 'within'
      ? widget.recording.pointsPerEpoch! / widget.recording.sampleRate
      : widget.recording.durationSeconds;
  @override
  void initState() {
    super.initState();
    start = TextEditingController(text: timeOrigin.toStringAsFixed(3));
    end = TextEditingController(text: (timeOrigin + limit).toStringAsFixed(3));
    window.text = math.min(2, limit).toString();
  }

  @override
  void dispose() {
    for (final c in [start, end, window, overlap]) {
      c.dispose();
    }
    super.dispose();
  }

  Widget number(TextEditingController c, String label) => Expanded(
    child: TextField(
      controller: c,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(labelText: label),
    ),
  );
  Widget markerSelector(bool first) => DropdownButtonFormField<int>(
    initialValue: first ? startMarker : endMarker,
    isExpanded: true,
    decoration: InputDecoration(
      labelText: first ? 'Start annotation' : 'End annotation',
    ),
    items: [
      for (var i = 0; i < widget.recording.markers.length; i++)
        DropdownMenuItem(
          value: i,
          child: Text(
            '${widget.recording.markers[i].description} [${widget.recording.markers[i].startSeconds.toStringAsFixed(3)} s]',
            overflow: TextOverflow.ellipsis,
          ),
        ),
    ],
    onChanged: (v) => setState(() {
      if (first) {
        startMarker = v;
      } else {
        endMarker = v;
      }
    }),
  );
  Future<void> save() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      var prepared = await RecordingLoader().loadFull(widget.recording);
      final a = !crop
          ? 0.0
          : markers
          ? (startMarker == null
                ? throw ArgumentError('Choose the start annotation.')
                : widget.recording.markers[startMarker!].startSeconds)
          : double.parse(start.text);
      final b = !crop
          ? limit
          : durationMode
          ? a + double.parse(end.text)
          : markers
          ? (endMarker == null
                ? throw ArgumentError('Choose the end annotation.')
                : widget.recording.markers[endMarker!].startSeconds)
          : double.parse(end.text);
      if (crop)
        prepared = scope == 'across'
            ? RecordingTransform.cropEpochRange(prepared, a, b)
            : RecordingTransform.crop(prepared, a - timeOrigin, b - timeOrigin);
      if (badSegments.isNotEmpty) {
        final cropOrigin = crop ? a : 0.0;
        final cropEnd = crop ? b : prepared.durationSeconds;
        final keptBad = <(double, double)>[];
        final updatedMarkers = List<EegMarker>.from(prepared.markers);
        for (final seg in badSegments) {
          final s0 = math.max(seg.$1, cropOrigin) - cropOrigin;
          final s1 = math.min(seg.$2, cropEnd) - cropOrigin;
          if (s1 > s0 + 0.01) {
            keptBad.add((s0, s1));
            updatedMarkers.add(
              EegMarker(
                type: 'Bad',
                description: 'Bad segment',
                startSeconds: s0,
                durationSeconds: s1 - s0,
              ),
            );
          }
        }
        updatedMarkers.sort((x, y) => x.startSeconds.compareTo(y.startSeconds));
        prepared = EegRecording(
          path: prepared.path,
          sampleRate: prepared.sampleRate,
          labels: prepared.labels,
          preview: prepared.preview,
          sampleCount: prepared.sampleCount,
          format: prepared.format,
          markers: updatedMarkers,
          epochCount: prepared.epochCount,
          pointsPerEpoch: prepared.pointsPerEpoch,
          epochLabels: prepared.epochLabels,
          epochStartSeconds: prepared.epochStartSeconds,
          sourceDurationSeconds: prepared.sourceDurationSeconds,
          epochTmin: prepared.epochTmin,
          provenance: {
            ...prepared.provenance,
            if (keptBad.isNotEmpty)
              'manual_bad_segments': [
                for (final s in keptBad) [s.$1, s.$2],
              ],
          },
        );
      }
      if (subepoch)
        prepared = RecordingTransform.subepoch(
          prepared,
          double.parse(window.text),
          double.parse(overlap.text),
        );
      if (!mounted) return;
      final path = await saveRecordingDialog(
        context,
        dialogTitle: 'Save prepared recording',
        fileName:
            '${recordingDialogStem(widget.recording.path.split(RegExp(r'[\\/]')).last)}_prepared.${RecordingStorage.extension}',
        type: FileType.custom,
        allowedExtensions: [RecordingStorage.extension],
      );
      if (path == null) return;
      final output = RecordingStorage.withExtension(path);
      await RecordingTransform.save(
        prepared,
        output,
        sourcePath: widget.recording.path,
        operations: {
          'crop': crop,
          'start_seconds': a,
          'end_seconds': b,
          'subepoch': subepoch,
          'window_seconds': double.tryParse(window.text),
          'overlap_seconds': double.tryParse(overlap.text),
        },
      );
      final loaded = await RecordingLoader().load(output);
      if (mounted) Navigator.of(context).pop(loaded);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      epoched ? 'Crop / subepoch existing trials' : 'Crop / epoch recording',
    ),
    content: SizedBox(
      width: 500,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              epoched
                  ? 'Times are relative to each parent epoch. New windows never cross trial boundaries.'
                  : 'Cropping is applied before sliding epochs. Endpoints are in recording seconds.',
            ),
            CheckboxListTile(
              title: const Text('Crop data'),
              value: crop,
              onChanged: busy ? null : (v) => setState(() => crop = v!),
            ),
            if (crop) ...[
              if (epoched)
                DropdownButtonFormField<String>(
                  initialValue: scope,
                  decoration: const InputDecoration(labelText: 'Crop domain'),
                  items: const [
                    DropdownMenuItem(
                      value: 'within',
                      child: Text('Within every parent epoch'),
                    ),
                    DropdownMenuItem(
                      value: 'across',
                      child: Text(
                        'Across stitched recording (complete epochs)',
                      ),
                    ),
                  ],
                  onChanged: (value) => setState(() {
                    scope = value!;
                    start.text = timeOrigin.toStringAsFixed(3);
                    end.text = (timeOrigin + limit).toStringAsFixed(3);
                  }),
                ),
              if (epoched &&
                  scope == 'within' &&
                  widget.recording.epochTmin != null)
                Text(
                  'Endpoints are event-relative: ${timeOrigin.toStringAsFixed(3)} to ${(timeOrigin + limit).toStringAsFixed(3)} s.',
                ),

              if (!epoched && widget.recording.markers.isNotEmpty)
                SwitchListTile(
                  title: const Text('Use annotations'),
                  value: markers,
                  onChanged: (v) => setState(() => markers = v),
                ),
              SwitchListTile(
                title: const Text('Start + duration (instead of start / end)'),
                value: durationMode,
                onChanged: (v) => setState(() => durationMode = v),
              ),
              if (markers)
                markerSelector(true)
              else
                Row(children: [number(start, 'Start (s)')]),
              if (markers && !durationMode)
                markerSelector(false)
              else
                Row(
                  children: [
                    number(end, durationMode ? 'Duration (s)' : 'End (s)'),
                  ],
                ),
            ],
            const SizedBox(height: 10),
            const Text(
              'Interactive Signal Overview & Bad Segment Marking (drag to mark bad segments):',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            LayoutBuilder(
              builder: (ctx, box) {
                final dur = math.max(0.01, limit);
                double xToSec(double dx) =>
                    timeOrigin + (dx / box.maxWidth).clamp(0.0, 1.0) * dur;
                return GestureDetector(
                  onHorizontalDragStart: (d) => setState(() {
                    _dragStartSec = xToSec(d.localPosition.dx);
                    _dragCurrentSec = _dragStartSec;
                  }),
                  onHorizontalDragUpdate: (d) => setState(() {
                    _dragCurrentSec = xToSec(d.localPosition.dx);
                  }),
                  onHorizontalDragEnd: (_) => setState(() {
                    if (_dragStartSec != null && _dragCurrentSec != null) {
                      final lo = math.min(_dragStartSec!, _dragCurrentSec!);
                      final hi = math.max(_dragStartSec!, _dragCurrentSec!);
                      if (hi - lo >= 0.05) {
                        badSegments.add((lo, hi));
                      }
                    }
                    _dragStartSec = null;
                    _dragCurrentSec = null;
                  }),
                  child: Container(
                    height: 64,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: CustomPaint(
                      painter: _CropOverviewPainter(
                        recording: widget.recording,
                        timeOrigin: timeOrigin,
                        limit: dur,
                        cropStart: crop ? double.tryParse(start.text) : null,
                        cropEnd: crop
                            ? (durationMode
                                  ? (double.tryParse(start.text) ?? 0) +
                                        (double.tryParse(end.text) ?? 0)
                                  : double.tryParse(end.text))
                            : null,
                        badSegments: badSegments,
                        activeDrag: _dragStartSec != null && _dragCurrentSec != null
                            ? (
                                math.min(_dragStartSec!, _dragCurrentSec!),
                                math.max(_dragStartSec!, _dragCurrentSec!),
                              )
                            : null,
                      ),
                    ),
                  ),
                );
              },
            ),
            if (badSegments.isNotEmpty) ...[
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (var i = 0; i < badSegments.length; i++)
                    InputChip(
                      label: Text(
                        'Bad ${badSegments[i].$1.toStringAsFixed(2)}–${badSegments[i].$2.toStringAsFixed(2)} s',
                        style: const TextStyle(fontSize: 10),
                      ),
                      onDeleted: () => setState(() => badSegments.removeAt(i)),
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ],
            CheckboxListTile(
              title: Text(
                epoched ? 'Subepoch each trial' : 'Create sliding epochs',
              ),
              value: subepoch,
              onChanged: busy ? null : (v) => setState(() => subepoch = v!),
            ),
            if (subepoch) ...[
              Row(
                children: [
                  number(window, 'Window (s)'),
                  const SizedBox(width: 12),
                  number(overlap, 'Overlap (s)'),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'Incomplete windows are dropped. Overlapping windows share samples and are not independent observations.',
              ),
            ],
            if (error != null)
              Text(error!, style: const TextStyle(color: Colors.redAccent)),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: busy ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: busy || (!crop && !subepoch) ? null : save,
        child: Text(busy ? 'Saving…' : 'Save and open'),
      ),
    ],
  );
}

class _CropOverviewPainter extends CustomPainter {
  const _CropOverviewPainter({
    required this.recording,
    required this.timeOrigin,
    required this.limit,
    this.cropStart,
    this.cropEnd,
    this.badSegments = const [],
    this.activeDrag,
  });

  final EegRecording recording;
  final double timeOrigin;
  final double limit;
  final double? cropStart;
  final double? cropEnd;
  final List<(double, double)> badSegments;
  final (double, double)? activeDrag;

  @override
  void paint(Canvas canvas, Size size) {
    final samples = recording.preview.isNotEmpty ? recording.preview.first : null;
    if (samples != null && samples.length > 2) {
      final step = math.max(1, samples.length ~/ 240);
      var maxAbs = 1e-6;
      for (var i = 0; i < samples.length; i += step) {
        final v = samples[i].abs();
        if (v.isFinite && v > maxAbs) maxAbs = v;
      }
      final path = Path();
      final midY = size.height / 2;
      for (var i = 0; i < samples.length; i += step) {
        final x = (i / (samples.length - 1)) * size.width;
        final y = midY - (samples[i] / maxAbs).clamp(-1.0, 1.0) * (midY - 6);
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = Colors.cyanAccent.withValues(alpha: 0.55)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0,
      );
    }

    double secToX(double s) =>
        ((s - timeOrigin) / math.max(0.01, limit)).clamp(0.0, 1.0) * size.width;

    if (cropStart != null && cropEnd != null && cropEnd! > cropStart!) {
      final x0 = secToX(cropStart!);
      final x1 = secToX(cropEnd!);
      canvas.drawRect(
        Rect.fromLTRB(x0, 0, x1, size.height),
        Paint()..color = Colors.amberAccent.withValues(alpha: 0.14),
      );
    }

    for (final seg in [...badSegments, ?activeDrag]) {
      final x0 = secToX(seg.$1);
      final x1 = secToX(seg.$2);
      canvas.drawRect(
        Rect.fromLTRB(x0, 0, math.max(x0 + 2, x1), size.height),
        Paint()..color = Colors.redAccent.withValues(alpha: 0.42),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CropOverviewPainter old) =>
      old.cropStart != cropStart ||
      old.cropEnd != cropEnd ||
      old.badSegments.length != badSegments.length ||
      old.activeDrag != activeDrag;
}
