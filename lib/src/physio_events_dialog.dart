import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'models.dart';
import 'physio_events.dart';
import 'theme.dart';

typedef RunPhysioExtractionFn =
    Future<PhysioExtractionResult> Function(PhysioEventOptions options);

Future<void> showPhysioEventsDialog({
  required BuildContext context,
  required EegRecording recording,
  required PhysioEventOptions initialOptions,
  required RunPhysioExtractionFn onExtract,
  required void Function(
    PhysioExtractionResult result,
    PhysioEventOptions options,
  )
  onApplyToRecording,
  VoidCallback? onRequestEpochEvents,
}) async {
  var opts = initialOptions;
  var running = false;
  String? error;
  PhysioExtractionResult? result;

  final eyeZCtrl = TextEditingController(text: opts.eyeMovementZ.toString());
  final emgZCtrl = TextEditingController(text: opts.emgZ.toString());
  final emgDurCtrl = TextEditingController(
    text: opts.emgMinDurationSec.toString(),
  );
  final artZCtrl = TextEditingController(text: opts.artifactZ.toString());

  final channelItems = <String>['', ...recording.labels];

  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) {
        PhysioEventOptions readOptions() => opts.copyWith(
          eyeMovementZ: double.tryParse(eyeZCtrl.text.trim()) ?? 3.5,
          emgZ: double.tryParse(emgZCtrl.text.trim()) ?? 3.5,
          emgMinDurationSec: double.tryParse(emgDurCtrl.text.trim()) ?? 0.25,
          artifactZ: double.tryParse(artZCtrl.text.trim()) ?? 5.0,
        );

        Future<void> runDetection() async {
          final currentOpts = readOptions();
          if (!currentOpts.anyEnabled) {
            setDialogState(
              () => error = 'Select at least one physiological event type.',
            );
            return;
          }
          setDialogState(() {
            running = true;
            error = null;
          });
          try {
            final res = await onExtract(currentOpts);
            if (!ctx.mounted) return;
            setDialogState(() {
              opts = currentOpts;
              result = res;
              running = false;
            });
          } catch (e) {
            if (!ctx.mounted) return;
            setDialogState(() {
              error = '$e';
              running = false;
            });
          }
        }

        Widget channelPicker(
          String label,
          String value,
          ValueChanged<String> onChanged,
        ) => DropdownButtonFormField<String>(
          key: ValueKey('$label-$value'),
          initialValue: channelItems.contains(value) ? value : '',
          isExpanded: true,
          decoration: InputDecoration(labelText: label, isDense: true),
          items: [
            for (final ch in channelItems)
              DropdownMenuItem(
                value: ch,
                child: Text(
                  ch.isEmpty ? 'Auto-detect' : ch,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
          ],
          onChanged: running ? null : (v) => onChanged(v ?? ''),
        );

        return AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.bolt, color: CcsTheme.accentBlue),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Extract Physiological & Artifact Events (HEP / Strain / EOG)',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 720,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Detect blinks, eye movements/saccades, EMG muscle surges (cognitive strain), ECG R-peaks (Heartbeat-Evoked Potential / HEP), and artifact bursts directly from ${recording.labels.length} channel(s) (${recording.sampleRate.toStringAsFixed(0)} Hz).',
                    style: const TextStyle(
                      fontSize: 12,
                      color: CcsTheme.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      FilterChip(
                        label: const Text('Eye Blinks (VEOG / Frontal)'),
                        selected: opts.detectBlinks,
                        onSelected: running
                            ? null
                            : (v) => setDialogState(
                                () => opts = opts.copyWith(detectBlinks: v),
                              ),
                      ),
                      FilterChip(
                        label: const Text('Eye Movements / Saccades'),
                        selected: opts.detectEyeMovements,
                        onSelected: running
                            ? null
                            : (v) => setDialogState(
                                () =>
                                    opts = opts.copyWith(detectEyeMovements: v),
                              ),
                      ),
                      FilterChip(
                        label: const Text('EMG Surges (Muscle Strain)'),
                        selected: opts.detectEmgSurges,
                        onSelected: running
                            ? null
                            : (v) => setDialogState(
                                () => opts = opts.copyWith(detectEmgSurges: v),
                              ),
                      ),
                      FilterChip(
                        label: const Text('ECG R-Peaks (HEP)'),
                        selected: opts.detectEcg,
                        onSelected: running
                            ? null
                            : (v) => setDialogState(
                                () => opts = opts.copyWith(detectEcg: v),
                              ),
                      ),
                      FilterChip(
                        label: const Text('Artifact Bursts (High-Amp)'),
                        selected: opts.detectArtifactBursts,
                        onSelected: running
                            ? null
                            : (v) => setDialogState(
                                () => opts = opts.copyWith(
                                  detectArtifactBursts: v,
                                ),
                              ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: channelPicker(
                          'Blink channel',
                          opts.blinkChannel,
                          (v) => setDialogState(
                            () => opts = opts.copyWith(blinkChannel: v),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: channelPicker(
                          'Eye movement / HEOG',
                          opts.eogChannel,
                          (v) => setDialogState(
                            () => opts = opts.copyWith(eogChannel: v),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: channelPicker(
                          'EMG channel',
                          opts.emgChannel,
                          (v) => setDialogState(
                            () => opts = opts.copyWith(emgChannel: v),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: channelPicker(
                          'ECG channel (HEP)',
                          opts.ecgChannel,
                          (v) => setDialogState(
                            () => opts = opts.copyWith(ecgChannel: v),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: eyeZCtrl,
                          enabled: !running,
                          decoration: const InputDecoration(
                            labelText: 'Eye move Z-thresh',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: emgZCtrl,
                          enabled: !running,
                          decoration: const InputDecoration(
                            labelText: 'EMG surge Z-thresh',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: emgDurCtrl,
                          enabled: !running,
                          decoration: const InputDecoration(
                            labelText: 'Min EMG dur (s)',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: artZCtrl,
                          enabled: !running,
                          decoration: const InputDecoration(
                            labelText: 'Artifact Z-thresh',
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 10),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: CcsTheme.accentRed.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: CcsTheme.accentRed.withValues(alpha: 0.35),
                        ),
                      ),
                      child: SelectableText(
                        error!,
                        style: const TextStyle(
                          color: CcsTheme.accentRed,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                  if (running) ...[
                    const SizedBox(height: 12),
                    const LinearProgressIndicator(),
                  ],
                  if (result != null) ...[
                    const SizedBox(height: 14),
                    _SummaryCards(summary: result!.summary),
                    if (result!.summary.notes.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: CcsTheme.accentAmber.withValues(alpha: 0.09),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: CcsTheme.accentAmber.withValues(alpha: 0.35),
                          ),
                        ),
                        child: Text(
                          result!.summary.notes.join('\n'),
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: CcsTheme.text,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    Text(
                      'Detected Events Preview (${result!.markers.length} total)',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: CcsTheme.text,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      height: 190,
                      decoration: BoxDecoration(
                        color: CcsTheme.panel,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: CcsTheme.border),
                      ),
                      child: result!.rawEvents.isEmpty
                          ? const Center(
                              child: Text(
                                'No physiological events detected with current thresholds.',
                                style: TextStyle(color: CcsTheme.textMuted),
                              ),
                            )
                          : ListView.separated(
                              itemCount: result!.rawEvents.length.clamp(0, 300),
                              separatorBuilder: (_, _) => const Divider(
                                height: 1,
                                color: CcsTheme.borderSubtle,
                              ),
                              itemBuilder: (_, idx) {
                                final ev = result!.rawEvents[idx];
                                final start =
                                    ((ev['start_seconds'] as num?)
                                                ?.toDouble() ??
                                            0.0)
                                        .toStringAsFixed(3);
                                final dur =
                                    ((ev['duration_seconds'] as num?)
                                                ?.toDouble() ??
                                            0.0)
                                        .toStringAsFixed(3);
                                final score =
                                    ((ev['score'] as num?)?.toDouble() ?? 0.0)
                                        .toStringAsFixed(1);
                                return Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 5,
                                  ),
                                  child: Row(
                                    children: [
                                      SizedBox(
                                        width: 130,
                                        child: Text(
                                          '${ev['description'] ?? ev['type']}',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 12,
                                            color: CcsTheme.text,
                                          ),
                                        ),
                                      ),
                                      SizedBox(
                                        width: 90,
                                        child: Text(
                                          '${start}s',
                                          style: const TextStyle(
                                            fontSize: 12,
                                            color: CcsTheme.textSecondary,
                                          ),
                                        ),
                                      ),
                                      SizedBox(
                                        width: 85,
                                        child: Text(
                                          'dur ${dur}s',
                                          style: const TextStyle(
                                            fontSize: 11.5,
                                            color: CcsTheme.textMuted,
                                          ),
                                        ),
                                      ),
                                      Expanded(
                                        child: Text(
                                          '${ev['channel'] ?? ''}',
                                          style: const TextStyle(
                                            fontSize: 11.5,
                                            color: CcsTheme.textSecondary,
                                          ),
                                        ),
                                      ),
                                      Text(
                                        'z=$score',
                                        style: const TextStyle(
                                          fontSize: 11.5,
                                          color: CcsTheme.accentBlue,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
            if (result != null && result!.markers.isNotEmpty) ...[
              OutlinedButton.icon(
                onPressed: () async {
                  final out = await FilePicker.saveFile(
                    dialogTitle: 'Export EEGLAB .evt sidecar',
                    fileName:
                        '${recording.path.split(RegExp(r'[\\/]')).last.replaceFirst(RegExp(r'\.[^.]+$'), '')}_physio.evt',
                    allowedExtensions: ['evt'],
                    type: FileType.custom,
                  );
                  if (out != null) {
                    await writeEeglabEvtSidecar(result!.markers, out);
                  }
                },
                icon: const Icon(Icons.download, size: 15),
                label: const Text('Export .evt'),
              ),
              OutlinedButton.icon(
                onPressed: () async {
                  final out = await FilePicker.saveFile(
                    dialogTitle: 'Export BIDS events.tsv',
                    fileName:
                        '${recording.path.split(RegExp(r'[\\/]')).last.replaceFirst(RegExp(r'\.[^.]+$'), '')}_physio_events.tsv',
                    allowedExtensions: ['tsv'],
                    type: FileType.custom,
                  );
                  if (out != null) {
                    await writeBidsEventsTsv(result!.rawEvents, out);
                  }
                },
                icon: const Icon(Icons.table_chart, size: 15),
                label: const Text('Export TSV'),
              ),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: CcsTheme.accentGreen,
                  foregroundColor: Colors.white,
                ),
                onPressed: () {
                  onApplyToRecording(result!, opts);
                  Navigator.pop(ctx);
                },
                icon: const Icon(Icons.add_task, size: 16),
                label: const Text('Add to Recording Markers'),
              ),
              if (onRequestEpochEvents != null)
                FilledButton.icon(
                  onPressed: () {
                    onApplyToRecording(result!, opts);
                    Navigator.pop(ctx);
                    onRequestEpochEvents();
                  },
                  icon: const Icon(Icons.cut, size: 15),
                  label: const Text('Add & Epoch Events…'),
                ),
            ],
            FilledButton.icon(
              onPressed: running ? null : runDetection,
              icon: const Icon(Icons.play_arrow, size: 16),
              label: Text(result == null ? 'Run Detection' : 'Re-run'),
            ),
          ],
        );
      },
    ),
  );
}

class _SummaryCards extends StatelessWidget {
  const _SummaryCards({required this.summary});
  final PhysioEventSummary summary;

  @override
  Widget build(BuildContext context) {
    Widget card(String title, String primary, String sub, Color accent) =>
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: CcsTheme.panel,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: accent.withValues(alpha: 0.35)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.bold,
                    color: accent,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  primary,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: CcsTheme.text,
                  ),
                ),
                Text(
                  sub,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 10.5,
                    color: CcsTheme.textMuted,
                  ),
                ),
              ],
            ),
          ),
        );

    return Row(
      children: [
        card(
          'BLINKS',
          '${summary.blinkCount}',
          '${summary.blinkRatePerMin.toStringAsFixed(1)}/min · ${summary.blinkChannel ?? 'none'}',
          CcsTheme.accentBlue,
        ),
        const SizedBox(width: 8),
        card(
          'EYE MOVEMENTS',
          '${summary.eyeMovementCount}',
          '${summary.eyeMovementRatePerMin.toStringAsFixed(1)}/min · ${summary.eyeMovementChannel ?? 'none'}',
          CcsTheme.accentCyan,
        ),
        const SizedBox(width: 8),
        card(
          'EMG SURGES',
          '${summary.emgSurgeCount}',
          '${summary.emgBurdenPct.toStringAsFixed(1)}% burden · mean ${summary.emgMeanDurationSec.toStringAsFixed(2)}s',
          CcsTheme.accentAmber,
        ),
        const SizedBox(width: 8),
        card(
          'ECG R-PEAKS (HEP)',
          '${summary.ecgRPeakCount}',
          summary.heartRateBpm != null
              ? '${summary.heartRateBpm!.toStringAsFixed(1)} bpm · RMSSD ${summary.rmssdMs?.toStringAsFixed(1) ?? '-'} ms'
              : (summary.ecgChannel ?? 'No ECG ch'),
          CcsTheme.accentRed,
        ),
      ],
    );
  }
}
