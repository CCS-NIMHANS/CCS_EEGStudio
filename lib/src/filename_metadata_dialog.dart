import 'package:flutter/material.dart';
import 'filename_metadata.dart';

/// An explicit, reviewed mapping from visible filename parts to metadata fields.
class FilenameMetadataDialog extends StatefulWidget {
  const FilenameMetadataDialog({super.key, required this.names});
  final List<String> names;

  @override
  State<FilenameMetadataDialog> createState() => _FilenameMetadataDialogState();
}

class _FilenameMetadataDialogState extends State<FilenameMetadataDialog> {
  late List<Map<String, String>> _rows;
  bool _automatic = true;
  String _separator = '_';
  final Map<int, String> _roles = {};
  int _page = 0;
  int _revision = 0;
  String _search = '';
  static const fields = ['Subject', 'Session', 'Condition', 'Group'];

  @override
  void initState() {
    super.initState();
    _rows = inferFilenameMetadata(widget.names);
  }

  void _preview() {
    _rows = _automatic
        ? inferFilenameMetadata(widget.names)
        : mapFilenameParts(widget.names, separator: _separator, roles: _roles);
    _page = 0;
    _revision++;
  }

  @override
  Widget build(BuildContext context) {
    final sample = widget.names.isEmpty ? '' : widget.names.first;
    final parts = filenameParts(sample, separator: _separator);
    final visible = _rows
        .where(
          (r) => r.values.any(
            (v) => v.toLowerCase().contains(_search.toLowerCase()),
          ),
        )
        .toList();
    final pageCount = (visible.length / 8).ceil().clamp(1, 100000);
    final page = _page.clamp(0, pageCount - 1);
    final shown = visible.skip(page * 8).take(8).toList();
    final identified = _rows
        .where((r) => (r['Subject'] ?? '').trim().isNotEmpty)
        .length;
    return AlertDialog(
      title: const Text('Identify participants and sessions from filenames'),
      content: SizedBox(
        width: 1050,
        height: 580,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Preview the labels before applying them. Participant = person; Session = visit; Condition = repeated task or stimulus; Group = a cohort label you explicitly supply. Group membership is never guessed.',
            ),
            const SizedBox(height: 12),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: true,
                  label: Text('Detect participant & session'),
                ),
                ButtonSegment(
                  value: false,
                  label: Text('Choose filename parts'),
                ),
              ],
              selected: {_automatic},
              onSelectionChanged: (v) => setState(() {
                _automatic = v.first;
                _preview();
              }),
            ),
            if (!_automatic) ...[
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: _separator,
                decoration: const InputDecoration(
                  labelText: 'Separate filename parts at',
                ),
                items: const [
                  DropdownMenuItem(value: '_', child: Text('Underscore (_)')),
                  DropdownMenuItem(value: '-', child: Text('Hyphen (-)')),
                  DropdownMenuItem(value: ' ', child: Text('Space')),
                ],
                onChanged: (v) => setState(() {
                  _separator = v!;
                  _roles.clear();
                  _preview();
                }),
              ),
              const SizedBox(height: 8),
              Text('Example: ${filenameBasename(sample)}'),
              SizedBox(
                height: 90,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: parts.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (_, i) => SizedBox(
                    width: 165,
                    child: DropdownButtonFormField<String>(
                      key: ValueKey('part_${_separator}_${i}_$_revision'),
                      initialValue: _roles[i] ?? 'Ignore',
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: parts[i],
                        helperText: 'Part ${i + 1}',
                      ),
                      items: ['Ignore', ...fields]
                          .map(
                            (f) => DropdownMenuItem(
                              value: f,
                              child: Text(
                                f == 'Subject' ? 'Participant ID' : f,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (v) => setState(() {
                        if (v != 'Ignore')
                          _roles.removeWhere((k, role) => k != i && role == v);
                        _roles[i] = v!;
                        _preview();
                      }),
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
            Text(
              '$identified of ${_rows.length} files have participant IDs. Every file needs an ID. Click a label below to correct it.',
            ),
            TextField(
              decoration: const InputDecoration(
                labelText: 'Find a filename or participant',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (v) => setState(() {
                _search = v;
                _page = 0;
              }),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          flex: 2,
                          child: Text('Recording filename'),
                        ),
                        for (final f in fields)
                          Expanded(
                            child: Text(f == 'Subject' ? 'Participant ID' : f),
                          ),
                      ],
                    ),
                    for (final row in shown)
                      Row(
                        children: [
                          Expanded(
                            flex: 2,
                            child: Tooltip(
                              message: row['filename']!,
                              child: Text(
                                filenameBasename(row['filename']!),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                          for (final field in fields)
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.all(3),
                                child: TextFormField(
                                  key: ValueKey(
                                    '${row['filename']}_${field}_$_revision',
                                  ),
                                  initialValue: row[field] ?? '',
                                  decoration: const InputDecoration(
                                    isDense: true,
                                  ),
                                  onChanged: (v) {
                                    row[field] = v.trim();
                                    setState(() {});
                                  },
                                ),
                              ),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
            Row(
              children: [
                IconButton(
                  onPressed: page > 0
                      ? () => setState(() => _page = page - 1)
                      : null,
                  icon: const Icon(Icons.chevron_left),
                ),
                Text(
                  'Page ${page + 1} of $pageCount · ${visible.length} recordings',
                ),
                IconButton(
                  onPressed: page + 1 < pageCount
                      ? () => setState(() => _page = page + 1)
                      : null,
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: identified == _rows.length && identified > 0
              ? () => Navigator.pop(context, _rows)
              : null,
          child: const Text('Use these reviewed labels'),
        ),
      ],
    );
  }
}
