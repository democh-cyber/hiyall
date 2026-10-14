import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/profile_labels.dart';

// Prefer the shortest standard tag when the ISO inventory has aliases with
// the same display name; do not show duplicate English/Hindi/etc. choices.
final languageOptions = () {
  final entries = languageNames.entries.toList()
    ..sort((a, b) => a.key.length.compareTo(b.key.length));
  final names = <String>{};
  return Map<String, String>.fromEntries(
    entries.where((e) => names.add(e.value)),
  );
}();

class LabelPicker extends StatefulWidget {
  final String title;
  final Map<String, String> labels;
  final Set<String> selected;
  final bool multiple;
  const LabelPicker({
    super.key,
    required this.title,
    required this.labels,
    required this.selected,
    required this.multiple,
  });
  @override
  State<LabelPicker> createState() => _LabelPickerState();
}

class _LabelPickerState extends State<LabelPicker> {
  late final selected = {...widget.selected};
  final search = TextEditingController();
  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Widget tile(BuildContext context, MapEntry<String, String> entry) {
    final checked = selected.contains(entry.key);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
      title: Text(entry.value),
      selected: checked,
      trailing: Icon(
        checked ? Icons.check_circle_rounded : Icons.circle_outlined,
        color: checked
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.outlineVariant,
      ),
      onTap: widget.multiple && selected.length >= 10 && !checked
          ? null
          : () {
              HapticFeedback.selectionClick();
              if (widget.multiple) {
                setState(
                  () => checked
                      ? selected.remove(entry.key)
                      : selected.add(entry.key),
                );
              } else {
                Navigator.of(context).pop({entry.key});
              }
            },
    );
  }

  @override
  Widget build(BuildContext context) {
    final entries =
        widget.labels.entries
            .where(
              (e) => e.value.toLowerCase().contains(
                search.text.trim().toLowerCase(),
              ),
            )
            .toList()
          ..sort((a, b) => a.value.compareTo(b.value));
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: math.max(
          56,
          MediaQuery.textScalerOf(context).scale(18) * 2.8 + 16,
        ),
        leading: IconButton(
          tooltip: 'Cancel selection',
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.arrow_back_rounded),
        ),
        title: Text(widget.title, style: const TextStyle(fontSize: 18)),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
                  child: TextField(
                    controller: search,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: widget.multiple
                          ? 'Search languages'
                          : 'Search countries',
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: search.text.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Clear search',
                              onPressed: () => setState(search.clear),
                              icon: const Icon(Icons.close_rounded),
                            ),
                    ),
                  ),
                ),
                Expanded(
                  child: entries.isEmpty
                      ? const Center(
                          child: Text('No matches. Try another name.'),
                        )
                      : ListView.builder(
                          keyboardDismissBehavior:
                              ScrollViewKeyboardDismissBehavior.onDrag,
                          itemCount: entries.length,
                          itemBuilder: (context, index) =>
                              tile(context, entries[index]),
                        ),
                ),
                if (widget.multiple)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () => Navigator.of(context).pop(selected),
                        child: Text(
                          'Use ${selected.length} ${selected.length == 1 ? 'language' : 'languages'}',
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
