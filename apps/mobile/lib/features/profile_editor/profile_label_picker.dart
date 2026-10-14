import 'package:flutter/material.dart';

Future<String?> pickProfileLabel(
  BuildContext context,
  String title,
  Map<String, String> labels, {
  bool allowClear = false,
}) => showModalBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (sheet) {
    var query = '';
    final entries = labels.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    return StatefulBuilder(
      builder: (context, setState) {
        final shown = entries
            .where((e) => e.value.toLowerCase().contains(query))
            .toList();
        return SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: SizedBox(
              height: MediaQuery.sizeOf(context).height * .65,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: TextField(
                      decoration: const InputDecoration(
                        labelText: 'Search',
                        prefixIcon: Icon(Icons.search_rounded),
                      ),
                      onChanged: (value) =>
                          setState(() => query = value.trim().toLowerCase()),
                    ),
                  ),
                  if (allowClear)
                    TextButton(
                      onPressed: () => Navigator.pop(sheet, ''),
                      child: const Text('Remove country'),
                    ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: shown.length,
                      itemBuilder: (context, i) => ListTile(
                        title: Text(shown[i].value),
                        onTap: () => Navigator.pop(sheet, shown[i].key),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  },
);
