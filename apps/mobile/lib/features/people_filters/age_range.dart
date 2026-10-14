import 'package:flutter/material.dart';

/// The age label and range slider. The top stop means "and over".
class AgeRange extends StatelessWidget {
  final double floor, ceiling, low, high;
  final String label;
  final ValueChanged<RangeValues> onChanged;
  const AgeRange({
    super.key,
    required this.floor,
    required this.ceiling,
    required this.low,
    required this.high,
    required this.label,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          key: const Key('filter-age-label'),
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: scheme.primary,
          ),
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTickMarkColor: Colors.transparent,
            inactiveTickMarkColor: Colors.transparent,
          ),
          child: RangeSlider(
            key: const Key('filter-age'),
            min: floor,
            max: ceiling,
            divisions: (ceiling - floor).round(),
            values: RangeValues(low, high),
            labels: RangeLabels(
              '${low.round()}',
              high >= ceiling ? '60+' : '${high.round()}',
            ),
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}
