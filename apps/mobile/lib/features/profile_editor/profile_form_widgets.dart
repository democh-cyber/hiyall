import 'package:flutter/material.dart';

/// A section title inside the form.
class ProfileHeading extends StatelessWidget {
  final String text;
  const ProfileHeading(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 16),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 21),
    ),
  );
}

/// A text field with its counter, for the form.
class ProfileTextField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final int max;
  final bool enabled;
  final String? Function(String?)? validator;
  final String? prefix;
  final int lines;
  const ProfileTextField(
    this.controller,
    this.label,
    this.max, {
    super.key,
    required this.enabled,
    this.validator,
    this.prefix,
    this.lines = 1,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: TextFormField(
      controller: controller,
      enabled: enabled,
      maxLength: max,
      minLines: lines,
      maxLines: lines == 1 ? 1 : 6,
      decoration: InputDecoration(labelText: label, prefixText: prefix),
      validator: validator,
    ),
  );
}

/// A drop-down of fixed choices, for the form.
class ProfileChoice extends StatelessWidget {
  final String label;
  final String value;
  final Map<String, String> values;
  final bool enabled;
  final ValueChanged<String> onChanged;
  const ProfileChoice({
    super.key,
    required this.label,
    required this.value,
    required this.values,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: DropdownButtonFormField<String>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: values.entries
          .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
          .toList(),
      onChanged: enabled
          ? (v) {
              if (v != null) onChanged(v);
            }
          : null,
    ),
  );
}
