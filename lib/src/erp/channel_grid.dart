import 'package:flutter/material.dart';
import 'workbench_figures.dart';
import 'review_math.dart';

/// Compute average waveform data across [targetChannels] with equal participant weighting.
Map<String, dynamic> buildErpChannelSelectionWaveData({
  required List<Map<String, dynamic>> files,
  required Map<String, dynamic> profile,
  required List<String> targetChannels,
  double smoothingMs = 0,
  Map<String, dynamic> axisLimits = const {},
}) {
  if (files.isEmpty) return {};
  final firstFile = files.first;
  final times = erpNumbers(firstFile['times']);
  final d = <String, dynamic>{
    'times': times,
    'profile': profile,
    ...axisLimits,
  };
  final condNames =
      (firstFile['condition_names'] as List?)?.cast<String>() ?? [];
  final targetUpper = targetChannels.map((c) => c.toUpperCase()).toSet();

  List<double>? averageRowsForChannels(
    List<String> fileLabels,
    List? rows,
    int nTimes,
  ) {
    if (rows == null) return null;
    final indices = <int>[
      for (var i = 0; i < fileLabels.length; i++)
        if (targetUpper.contains(fileLabels[i].toUpperCase()) &&
            i < rows.length)
          i,
    ];
    if (indices.isEmpty) return null;
    final out = List<double>.filled(nTimes, 0.0);
    var validCh = 0;
    for (final idx in indices) {
      final vals = erpNumbers(rows[idx]);
      if (vals.length == nTimes) {
        for (var t = 0; t < nTimes; t++) {
          out[t] += vals[t];
        }
        validCh++;
      }
    }
    if (validCh == 0) return null;
    for (var t = 0; t < nTimes; t++) {
      out[t] /= validCh;
    }
    return out;
  }

  if (condNames.isNotEmpty) {
    d['condition_names'] = condNames;
    final condWaves = <String, List<double>>{};
    final condSems = <String, List<double>>{};
    for (final cond in condNames) {
      final people = <String, List<List<double>>>{};
      for (final f in files) {
        final fileLabels = (f['labels'] as List? ?? []).cast<String>();
        List<double>? values;
        final chans = f['channel_conditions'] as Map?;
        if (chans != null && chans.containsKey(cond)) {
          values = averageRowsForChannels(
            fileLabels,
            chans[cond] as List?,
            times.length,
          );
        } else if (cond == condNames.first && f['channel_a'] != null) {
          values = averageRowsForChannels(
            fileLabels,
            f['channel_a'] as List?,
            times.length,
          );
        } else if (condNames.length > 1 &&
            cond == condNames[1] &&
            f['channel_b'] != null) {
          values = averageRowsForChannels(
            fileLabels,
            f['channel_b'] as List?,
            times.length,
          );
        }
        if (values != null && values.length == times.length) {
          people.putIfAbsent('${f['subject']}', () => []).add(values);
        }
      }
      final waves = [
        for (final p in people.values)
          smoothErp(reviewAverage(p), times, smoothingMs),
      ];
      condWaves[cond] = reviewAverage(waves);
      condSems[cond] = reviewSem(waves);
    }
    d['condition_waves'] = condWaves;
    d['condition_sems'] = condSems;
  }

  for (final key in ['a', 'b', 'difference']) {
    final people = <String, List<List<double>>>{};
    for (final f in files) {
      final fileLabels = (f['labels'] as List? ?? []).cast<String>();
      final values = averageRowsForChannels(
        fileLabels,
        f['channel_$key'] as List?,
        times.length,
      );
      if (values == null || values.length != times.length) continue;
      people.putIfAbsent('${f['subject']}', () => []).add(values);
    }
    final waves = [
      for (final p in people.values)
        smoothErp(reviewAverage(p), times, smoothingMs),
    ];
    d[key] = reviewAverage(waves);
    d['sem_$key'] = reviewSem(waves);
  }
  return d;
}

/// Independent electrode panels with equal weighting of participants.
class ErpChannelGrid extends StatefulWidget {
  const ErpChannelGrid({
    super.key,
    required this.files,
    required this.profile,
    this.negativeUp = true,
    this.smoothingMs = 0,
    this.axisLimits = const {},
    this.selectedChannels,
    this.onSelectedChannelsChanged,
  });
  final List<Map<String, dynamic>> files;
  final Map<String, dynamic> profile;
  final bool negativeUp;
  final double smoothingMs;
  final Map<String, dynamic> axisLimits;
  final Set<String>? selectedChannels;
  final ValueChanged<Set<String>>? onSelectedChannelsChanged;
  @override
  State<ErpChannelGrid> createState() => _ErpChannelGridState();
}

class _ErpChannelGridState extends State<ErpChannelGrid> {
  int _columns = 3;
  Set<String>? _internalSelected;

  static Set<String> defaultChannelSubset(
    List<String> labels,
    List<String> roi,
  ) {
    final preferredOrder = <String>[
      ...roi,
      'Fz',
      'FCz',
      'Cz',
      'CPz',
      'Pz',
      'POz',
      'Oz',
      'PO7',
      'PO8',
      'C3',
      'C4',
    ];
    final out = <String>{};
    for (final pref in preferredOrder) {
      final match = labels.where(
        (l) => l.toUpperCase() == pref.toUpperCase(),
      );
      if (match.isNotEmpty) out.add(match.first);
      if (out.length >= 6) break;
    }
    for (final l in labels) {
      if (out.length >= 6) break;
      out.add(l);
    }
    return out;
  }

  void _updateSelected(Set<String> next) {
    setState(() => _internalSelected = next);
    widget.onSelectedChannelsChanged?.call(next);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.files.isEmpty) return const SizedBox.shrink();
    final files = widget.files;
    final labels = (files.first['labels'] as List? ?? [])
        .cast<String>()
        .where(
          (l) => files.every((f) => (f['labels'] as List? ?? []).contains(l)),
        )
        .toList();
    final roi = (widget.profile['roi'] as List? ?? []).cast<String>();
    final roiSet = roi.map((s) => s.toUpperCase()).toSet();
    final selected =
        widget.selectedChannels ??
        _internalSelected ??
        defaultChannelSubset(labels, roi);

    List<String> matchRegion(bool Function(String upper) pred) =>
        labels.where((l) => pred(l.toUpperCase())).toList();

    final midline = matchRegion((u) => u.endsWith('Z'));
    final frontal = matchRegion(
      (u) => u.startsWith('FP') || u.startsWith('AF') || u.startsWith('F'),
    );
    final central = matchRegion(
      (u) => u.startsWith('FC') || u.startsWith('C') || u.startsWith('CP'),
    );
    final posterior = matchRegion(
      (u) => u.startsWith('P') || u.startsWith('PO') || u.startsWith('O'),
    );

    return Card(
      margin: const EdgeInsets.only(top: 10),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.grid_view_rounded, size: 16, color: Colors.cyanAccent),
                const SizedBox(width: 8),
                Text(
                  'Multi-Channel Waveform Grid (${selected.length}/${labels.length} channels)',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                const Spacer(),
                SizedBox(
                  height: 28,
                  child: DropdownButton<int>(
                    value: _columns,
                    underline: const SizedBox.shrink(),
                    items: [
                      for (final n in [2, 3, 4])
                        DropdownMenuItem(
                          value: n,
                          child: Text(
                            '$n cols',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                    ],
                    onChanged: (v) => setState(() => _columns = v!),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Quick region presets
            Wrap(
              spacing: 6,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text(
                  'Presets:',
                  style: TextStyle(fontSize: 11, color: Colors.white60),
                ),
                if (roi.isNotEmpty)
                  ActionChip(
                    visualDensity: VisualDensity.compact,
                    label: Text('Task ROI (${roi.join(", ")})', style: const TextStyle(fontSize: 11)),
                    onPressed: () => _updateSelected(
                      labels
                          .where((l) => roiSet.contains(l.toUpperCase()))
                          .toSet(),
                    ),
                  ),
                if (midline.isNotEmpty)
                  ActionChip(
                    visualDensity: VisualDensity.compact,
                    label: const Text('Midline', style: TextStyle(fontSize: 11)),
                    onPressed: () => _updateSelected(midline.toSet()),
                  ),
                if (frontal.isNotEmpty)
                  ActionChip(
                    visualDensity: VisualDensity.compact,
                    label: const Text('Frontal', style: TextStyle(fontSize: 11)),
                    onPressed: () => _updateSelected(frontal.toSet()),
                  ),
                if (central.isNotEmpty)
                  ActionChip(
                    visualDensity: VisualDensity.compact,
                    label: const Text('Central', style: TextStyle(fontSize: 11)),
                    onPressed: () => _updateSelected(central.toSet()),
                  ),
                if (posterior.isNotEmpty)
                  ActionChip(
                    visualDensity: VisualDensity.compact,
                    label: const Text('Parieto-Occipital', style: TextStyle(fontSize: 11)),
                    onPressed: () => _updateSelected(posterior.toSet()),
                  ),
                ActionChip(
                  visualDensity: VisualDensity.compact,
                  label: const Text('All', style: TextStyle(fontSize: 11)),
                  onPressed: () => _updateSelected(labels.toSet()),
                ),
                ActionChip(
                  visualDensity: VisualDensity.compact,
                  label: const Text('None', style: TextStyle(fontSize: 11)),
                  onPressed: () => _updateSelected({}),
                ),
              ],
            ),
            const SizedBox(height: 6),
            // Always-visible channel chips
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final l in labels)
                  FilterChip(
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    label: Text(
                      l,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: roiSet.contains(l.toUpperCase())
                            ? FontWeight.bold
                            : FontWeight.normal,
                      ),
                    ),
                    selected: selected.contains(l),
                    onSelected: (v) {
                      final next = {...selected};
                      v ? next.add(l) : next.remove(l);
                      _updateSelected(next);
                    },
                  ),
              ],
            ),
            if (selected.isNotEmpty) ...[
              const SizedBox(height: 10),
              LayoutBuilder(
                builder: (context, constraints) {
                  final cols = constraints.maxWidth < 620 ? 1 : _columns;
                  return Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final l in labels.where(selected.contains))
                        SizedBox(
                          width: (constraints.maxWidth - 8 * (cols - 1)) / cols,
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: roiSet.contains(l.toUpperCase())
                                    ? const Color(0xFF0284C7)
                                    : const Color(0xFFCBD5E1),
                                width: roiSet.contains(l.toUpperCase()) ? 1.5 : 1.0,
                              ),
                            ),
                            child: Column(
                              children: [
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    color: roiSet.contains(l.toUpperCase())
                                        ? const Color(0xFFE0F2FE)
                                        : const Color(0xFFF1F5F9),
                                    borderRadius: const BorderRadius.vertical(
                                      top: Radius.circular(5),
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(
                                        roiSet.contains(l.toUpperCase())
                                            ? '$l (ROI)'
                                            : l,
                                        style: const TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                          color: Color(0xFF0F172A),
                                        ),
                                      ),
                                      InkWell(
                                        onTap: () {
                                          final next = {...selected}..remove(l);
                                          _updateSelected(next);
                                        },
                                        child: const Icon(
                                          Icons.close,
                                          size: 13,
                                          color: Color(0xFF64748B),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                SizedBox(
                                  height: 185,
                                  child: ClipRRect(
                                    borderRadius: const BorderRadius.vertical(
                                      bottom: Radius.circular(5),
                                    ),
                                    child: CustomPaint(
                                      size: const Size(double.infinity, 185),
                                      painter: ErpWorkbenchWavePainter(
                                        buildErpChannelSelectionWaveData(
                                          files: files,
                                          profile: widget.profile,
                                          targetChannels: [l],
                                          smoothingMs: widget.smoothingMs,
                                          axisLimits: widget.axisLimits,
                                        ),
                                        negativeUp: widget.negativeUp,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ] else
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'Select one or more electrode chips above to compare individual channel waveforms.',
                  style: TextStyle(fontSize: 11, color: Colors.white60),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
