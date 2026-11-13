import 'package:flutter/material.dart';

/// Select retained recording channels without entering electrode names manually.
class ReferenceChannelPicker extends StatelessWidget {
  const ReferenceChannelPicker({
    super.key,
    required this.channels,
    required this.selected,
    required this.onChanged,
  });
  final List<String> channels, selected;
  final ValueChanged<List<String>> onChanged;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      OutlinedButton.icon(
        icon: const Icon(Icons.checklist, size: 18),
        label: Text(
          selected.isEmpty
              ? 'Choose reference channels…'
              : 'Edit reference channels (${selected.length})…',
        ),
        onPressed: channels.isEmpty
            ? null
            : () async {
                final result = await showDialog<List<String>>(
                  context: context,
                  builder: (_) =>
                      _ChannelDialog(channels: channels, selected: selected),
                );
                if (result != null) onChanged(result);
              },
      ),
      Wrap(
        spacing: 4,
        children: [
          for (final name in selected)
            InputChip(
              label: Text(name),
              onDeleted: () =>
                  onChanged(selected.where((s) => s != name).toList()),
            ),
        ],
      ),
      const Text(
        'Choose one electrode or a linked reference. Only retained EEG channels can be used; adjust Channel setup to retain an auxiliary reference electrode.',
        style: TextStyle(fontSize: 11),
      ),
      if (selected.any((s) => !channels.contains(s)))
        const Text(
          'Some selected electrodes are not retained in this recording.',
          style: TextStyle(color: Colors.orange),
        ),
    ],
  );
}

class _ChannelDialog extends StatefulWidget {
  const _ChannelDialog({required this.channels, required this.selected});
  final List<String> channels, selected;
  @override
  State<_ChannelDialog> createState() => _ChannelDialogState();
}

class _ChannelDialogState extends State<_ChannelDialog> {
  late final Set<String> chosen = widget.selected.toSet();
  String query = '';
  @override
  Widget build(BuildContext context) {
    final filtered = widget.channels
        .where((s) => s.toLowerCase().contains(query.toLowerCase()))
        .toList();
    return AlertDialog(
      title: const Text('Choose reference channels'),
      content: SizedBox(
        width: 420,
        height: 400,
        child: Column(
          children: [
            TextField(
              decoration: const InputDecoration(
                labelText: 'Search channels',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (v) => setState(() => query = v),
            ),
            Expanded(
              child: ListView(
                children: [
                  for (final label in filtered)
                    CheckboxListTile(
                      title: Text(label),
                      value: chosen.contains(label),
                      onChanged: (v) => setState(() {
                        if (v == true) {
                          chosen.add(label);
                        } else {
                          chosen.remove(label);
                        }
                      }),
                    ),
                ],
              ),
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
          onPressed: chosen.any(widget.channels.contains)
              ? () => Navigator.pop(
                  context,
                  widget.channels.where(chosen.contains).toList(),
                )
              : null,
          child: const Text('Use selected channels'),
        ),
      ],
    );
  }
}
