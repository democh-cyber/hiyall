import 'package:flutter/material.dart';

import '../../core/theme.dart';

class ProfileSkeleton extends StatelessWidget {
  const ProfileSkeleton({super.key});
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final color = (dark ? Colors.white : VibeColors.ink).withValues(alpha: .08);
    Widget block(double width, double height, [double radius = 10]) =>
        Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(radius),
          ),
        );
    return Semantics(
      label: 'Loading profile',
      child: ExcludeSemantics(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 20),
            Center(child: block(108, 108, 54)),
            const SizedBox(height: 20),
            Center(child: block(140, 22)),
            const SizedBox(height: 12),
            Center(child: block(100, 14)),
            const SizedBox(height: 24),
            block(double.infinity, 16),
            const SizedBox(height: 8),
            block(double.infinity, 16),
            const SizedBox(height: 30),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [block(100, 38), block(110, 38), block(90, 38)],
            ),
            const SizedBox(height: 30),
            block(double.infinity, 150, 20),
          ],
        ),
      ),
    );
  }
}
