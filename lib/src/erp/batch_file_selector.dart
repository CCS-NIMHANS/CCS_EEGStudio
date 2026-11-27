import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../filtered_file_picker.dart';
import 'workbench_service.dart';

/// Interactive dialog for selecting, filtering, and managing batch recordings
/// discovered from a folder or added via individual file selection.
class BatchFileSelectionDialog extends StatefulWidget {
  const BatchFileSelectionDialog({
    super.key,
    required this.initialFiles,
    this.rootDirectory,
    this.initiallySelected,
    this.existingPaths = const [],
    this.initialSubjectLimit = 0,
    this.allowedExtensions = const ['edf', 'fif', 'ccseeg', 'json'],
    this.title = 'Select Batch Recordings',
  });

  final List<String> initialFiles;
  final String? rootDirectory;
  final Set<String>? initiallySelected;
  final List<String> existingPaths;
  final int initialSubjectLimit;
  final List<String> allowedExtensions;
  final String title;

  /// Shows the dialog and returns the confirmed selection + replace/append mode,
  /// or `null` if cancelled.
  static Future<BatchFileSelectionResult?> show(
    BuildContext context, {
    required List<String> initialFiles,
    String? rootDirectory,
    Set<String>? initiallySelected,
    List<String> existingPaths = const [],
    int initialSubjectLimit = 0,
    List<String> allowedExtensions = const ['edf', 'fif', 'ccseeg', 'json'],
    String title = 'Select Batch Recordings',
  }) {
    return showDialog<BatchFileSelectionResult>(
      context: context,
      builder: (_) => BatchFileSelectionDialog(
        initialFiles: initialFiles,
        rootDirectory: rootDirectory,
        initiallySelected: initiallySelected,
        existingPaths: existingPaths,
        initialSubjectLimit: initialSubjectLimit,
        allowedExtensions: allowedExtensions,
        title: title,
      ),
    );
  }

  @override
  State<BatchFileSelectionDialog> createState() =>
      _BatchFileSelectionDialogState();
}

class BatchFileSelectionResult {
  const BatchFileSelectionResult({
    required this.selectedFiles,
    required this.replaceExisting,
    this.subjects = const {},
  });

  final Map<String, String> subjects;
  final List<String> selectedFiles;
  final bool replaceExisting;
}

class _BatchFileSelectionDialogState extends State<BatchFileSelectionDialog> {
  late final List<String> _allFiles;
  late final Set<String> _selected;
  late final TextEditingController _searchCtrl;
  late final TextEditingController _firstNCtrl;
  final Map<String, String> _subjects = {};
  String _subject(String path) => _subjects[path] ?? extractRecordingSubject(path);
  Future<void> _editSubject(String path) async {
    var draft = _subject(path);
    final value = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('Subject ID for this recording'),
      content: TextFormField(initialValue: draft, onChanged: (v) => draft = v, autofocus: true, decoration: const InputDecoration(labelText: 'Subject ID', helperText: 'Sessions with the same ID are plotted together.')),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')), FilledButton(onPressed: () { if (draft.trim().isNotEmpty) Navigator.pop(ctx, draft.trim()); }, child: const Text('Apply'))],
    ));
    if (value != null && mounted) setState(() => _subjects[path] = value);
  }
  bool _replaceExisting = true;

  @override
  void initState() {
    super.initState();
    _allFiles = List<String>.from(widget.initialFiles);
    _searchCtrl = TextEditingController();
    _firstNCtrl = TextEditingController(
      text: widget.initialSubjectLimit > 0
          ? '${widget.initialSubjectLimit}'
          : '0',
    );
    if (widget.initiallySelected != null) {
      _selected = Set<String>.from(widget.initiallySelected!);
    } else if (widget.initialSubjectLimit > 0) {
      _selected = <String>{};
      _applyFirstNSubjects(widget.initialSubjectLimit, notify: false);
    } else {
      _selected = Set<String>.from(_allFiles);
    }
    _replaceExisting = widget.existingPaths.isEmpty ? true : true;
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _firstNCtrl.dispose();
    super.dispose();
  }

  String _relativePath(String path) {
    final root = widget.rootDirectory;
    if (root != null && root.isNotEmpty && path.startsWith(root)) {
      var rel = path.substring(root.length);
      if (rel.startsWith(Platform.pathSeparator) || rel.startsWith('/')) {
        rel = rel.substring(1);
      }
      if (rel.isNotEmpty) return rel;
    }
    return path.split(RegExp(r'[/\\]')).last;
  }

  bool _matchesQuery(String path, String rawQuery) {
    final q = rawQuery.trim();
    if (q.isEmpty || q == '*') return true;
    final name = path.split(RegExp(r'[/\\]')).last;
    final rel = _relativePath(path);
    final parts = q
        .split(';')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (parts.isEmpty) return true;
    for (final part in parts) {
      if (part.contains('*') || part.contains('?')) {
        final escaped = RegExp.escape(
          part,
        ).replaceAll(r'\*', '.*').replaceAll(r'\?', '.');
        final re = RegExp('^$escaped\$', caseSensitive: false);
        if (re.hasMatch(name) || re.hasMatch(rel)) return true;
      } else {
        final lower = part.toLowerCase();
        if (name.toLowerCase().contains(lower) ||
            rel.toLowerCase().contains(lower)) {
          return true;
        }
      }
    }
    return false;
  }

  List<String> get _filteredFiles =>
      _allFiles.where((f) => _matchesQuery(f, _searchCtrl.text)).toList();

  void _applyFirstNSubjects(int n, {bool notify = true}) {
    if (n <= 0) {
      _selected
        ..clear()
        ..addAll(_filteredFiles);
    } else {
      final subjects = <String>{};
      _selected.clear();
      for (final p in _filteredFiles) {
        final subj = _subject(p);
        if (subjects.contains(subj)) {
          _selected.add(p);
        } else if (subjects.length < n) {
          subjects.add(subj);
          _selected.add(p);
        }
      }
    }
    if (notify && mounted) setState(() {});
  }

  Future<void> _addMoreFiles() async {
    final picked = await pickFilteredFiles(
      context,
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: widget.allowedExtensions,
      recordingsOnly: true,
    );
    if (picked == null || !mounted) return;
    setState(() {
      for (final f in picked.files) {
        final p = f.path;
        if (p != null && p.isNotEmpty) {
          if (!_allFiles.contains(p)) _allFiles.add(p);
          _selected.add(p);
        }
      }
    });
  }

  Future<void> _addAnotherFolder() async {
    final dir = await FilePicker.getDirectoryPath(
      dialogTitle: 'Add recordings from another folder',
    );
    if (dir == null || !mounted) return;
    final found = discoverErpRecordings(dir, firstSubjects: 0);
    setState(() {
      for (final p in found) {
        if (!_allFiles.contains(p)) _allFiles.add(p);
        _selected.add(p);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredFiles;
    final selectedSubjects = _selected.map(_subject).toSet();
    final totalSubjects = _allFiles.map(_subject).toSet();

    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.folder_copy_outlined, size: 20),
          const SizedBox(width: 8),
          Expanded(child: Text(widget.title)),
          Text(
            '${_selected.length} / ${_allFiles.length} files (${selectedSubjects.length} / ${totalSubjects.length} subjects)',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      content: SizedBox(
        width: 820,
        height: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.rootDirectory != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Folder: ${widget.rootDirectory}',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: const Color(0xFF475569)),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            Wrap(spacing: 8, children: [
                const Text('Subject tags: click a tag to edit; or assign all by'),
                TextButton(onPressed: () => setState(() { for (final p in _allFiles) _subjects[p] = extractRecordingSubject(p); }), child: const Text('Filename / automatic')),
                TextButton(onPressed: () => setState(() { for (final p in _allFiles) _subjects[p] = File(p).parent.uri.pathSegments.where((v) => v.isNotEmpty).last; }), child: const Text('Parent folder')),
              ]),
            Row(children: [
              Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search, size: 18),
                      labelText:
                          'Filter by filename, subfolder, or wildcard (*SESSION03*;*SKYMED*)',
                      isDense: true,
                      border: const OutlineInputBorder(),
                      suffixIcon: _searchCtrl.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear, size: 16),
                              onPressed: () {
                                _searchCtrl.clear();
                                setState(() {});
                              },
                            ),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 115,
                  child: TextField(
                    controller: _firstNCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'First N subj',
                      hintText: '0 = all',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                OutlinedButton(
                  onPressed: () {
                    final n = int.tryParse(_firstNCtrl.text.trim()) ?? 0;
                    _applyFirstNSubjects(n);
                  },
                  child: const Text('Apply N'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.tonalIcon(
                  onPressed: () => setState(() => _selected.addAll(filtered)),
                  icon: const Icon(Icons.select_all, size: 16),
                  label: Text('Select Shown (${filtered.length})'),
                ),
                OutlinedButton.icon(
                  onPressed: () =>
                      setState(() => _selected.removeAll(filtered)),
                  icon: const Icon(Icons.deselect, size: 16),
                  label: const Text('Deselect Shown'),
                ),
                OutlinedButton.icon(
                  onPressed: () => setState(() {
                    for (final f in filtered) {
                      if (_selected.contains(f)) {
                        _selected.remove(f);
                      } else {
                        _selected.add(f);
                      }
                    }
                  }),
                  icon: const Icon(Icons.swap_horiz, size: 16),
                  label: const Text('Invert Shown'),
                ),
                const VerticalDivider(width: 12),
                TextButton.icon(
                  onPressed: _addMoreFiles,
                  icon: const Icon(Icons.note_add_outlined, size: 16),
                  label: const Text('+ Files'),
                ),
                TextButton.icon(
                  onPressed: _addAnotherFolder,
                  icon: const Icon(Icons.create_new_folder_outlined, size: 16),
                  label: const Text('+ Folder'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: const Color(0xFFCBD5E1)),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: filtered.isEmpty
                    ? const Center(
                        child: Text('No recordings match the current filter.'),
                      )
                    : ListView.builder(
                        itemCount: filtered.length,
                        itemExtent: 46,
                        itemBuilder: (context, index) {
                          final path = filtered[index];
                          final name = path.split(RegExp(r'[/\\]')).last;
                          final rel = _relativePath(path);
                          final subj = _subject(path);
                          final checked = _selected.contains(path);
                          return CheckboxListTile(
                            dense: true,
                            value: checked,
                            controlAffinity: ListTileControlAffinity.leading,
                            onChanged: (v) {
                              setState(() {
                                if (v == true) {
                                  _selected.add(path);
                                } else {
                                  _selected.remove(path);
                                }
                              });
                            },
                            title: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    name,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 12.5),
                                  ),
                                ),
                                if (rel != name)
                                  Padding(
                                    padding: const EdgeInsets.only(left: 8),
                                    child: Text(
                                      rel,
                                      style: const TextStyle(
                                        fontSize: 10.5,
                                        color: Color(0xFF64748B),
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                const SizedBox(width: 8),
                                InkWell(onTap: () => _editSubject(path), child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.blueGrey.withValues(
                                      alpha: 0.25,
                                    ),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    '$subj ✎',
                                    style: const TextStyle(fontSize: 10.5),
                                  ),
                                )),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ),
            if (widget.existingPaths.isNotEmpty) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text(
                    'When applying to current batch:',
                    style: TextStyle(fontSize: 12),
                  ),
                  const SizedBox(width: 12),
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(
                        value: true,
                        label: Text('Replace existing', style: TextStyle(fontSize: 11)),
                      ),
                      ButtonSegment(
                        value: false,
                        label: Text('Append to existing', style: TextStyle(fontSize: 11)),
                      ),
                    ],
                    selected: {_replaceExisting},
                    onSelectionChanged: (s) =>
                        setState(() => _replaceExisting = s.first),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _selected.isEmpty
              ? null
              : () {
                  final ordered = _allFiles
                      .where((f) => _selected.contains(f))
                      .toList();
                  Navigator.pop(
                    context,
                    BatchFileSelectionResult(
                      selectedFiles: ordered,
                      subjects: {for (final p in ordered) p: _subject(p)},
                      replaceExisting: _replaceExisting,
                    ),
                  );
                },
          icon: const Icon(Icons.check, size: 16),
          label: Text('Use ${_selected.length} Recording(s)'),
        ),
      ],
    );
  }
}
