import 'package:flutter/material.dart';

import '../core/theme.dart';

/// A pill-shaped segmented control with a sliding selection indicator.
///
/// Segments share the width equally; at large text sizes they keep their
/// natural width and the row scrolls horizontally instead of clipping labels.
class VibeSegmented<T> extends StatelessWidget {
  final List<(T, String)> segments;
  final T selected;
  final ValueChanged<T> onChanged;
  final Key? Function(T value)? keyFor;
  const VibeSegmented({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
    this.keyFor,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final duration = VibeMotion.duration(context);
    final index = segments.indexWhere((s) => s.$1 == selected);
    final large = MediaQuery.textScalerOf(context).scale(1) > 1.3;

    Widget segment((T, String) s) {
      final on = s.$1 == selected;
      return Semantics(
        selected: on,
        button: true,
        child: InkWell(
          key: keyFor?.call(s.$1),
          // The pill slides to the choice; no grey highlight on top of it.
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          splashFactory: NoSplash.splashFactory,
          borderRadius: BorderRadius.circular(100),
          onTap: on ? null : () => onChanged(s.$1),
          child: Container(
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
            alignment: Alignment.center,
            child: AnimatedDefaultTextStyle(
              duration: duration,
              style: TextStyle(
                fontFamily: 'Manrope',
                fontSize: 14,
                fontWeight: on ? FontWeight.w800 : FontWeight.w600,
                color: on ? VibeColors.ink : scheme.onSurfaceVariant,
              ),
              // Shrinks rather than clips when a label is wider than its share.
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(s.$2, maxLines: 1),
              ),
            ),
          ),
        ),
      );
    }

    final track = BoxDecoration(
      color: dark
          ? scheme.surfaceContainerHigh
          : scheme.surfaceContainerHighest.withValues(alpha: .7),
      borderRadius: BorderRadius.circular(100),
    );

    if (large) {
      // Natural widths: no sliding indicator, just highlighted pills.
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Container(
          padding: const EdgeInsets.all(4),
          decoration: track,
          child: Row(
            children: [
              for (final s in segments)
                AnimatedContainer(
                  duration: duration,
                  decoration: BoxDecoration(
                    color: s.$1 == selected
                        ? VibeColors.lime
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(100),
                  ),
                  child: segment(s),
                ),
            ],
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: track,
      child: LayoutBuilder(
        builder: (context, box) {
          final width = box.maxWidth / segments.length;
          return Stack(
            children: [
              AnimatedPositionedDirectional(
                duration: duration,
                curve: Curves.easeOutCubic,
                start: width * (index < 0 ? 0 : index),
                top: 0,
                bottom: 0,
                width: width,
                child: Container(
                  decoration: BoxDecoration(
                    color: VibeColors.lime,
                    borderRadius: BorderRadius.circular(100),
                  ),
                ),
              ),
              Row(
                children: [
                  for (final s in segments) Expanded(child: segment(s)),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Scales its child down slightly while pressed, for tactile card feedback.
class Pressable extends StatefulWidget {
  final Widget child;
  const Pressable({super.key, required this.child});
  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool down = false;
  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (_) => setState(() => down = true),
    onPointerUp: (_) => setState(() => down = false),
    onPointerCancel: (_) => setState(() => down = false),
    child: AnimatedScale(
      scale: down ? .98 : 1,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 110),
      child: widget.child,
    ),
  );
}

/// Fades and lifts its child in once, the first time it is built.
class EntranceFade extends StatelessWidget {
  final Widget child;
  final int delayMs;
  const EntranceFade({super.key, required this.child, this.delayMs = 0});
  @override
  Widget build(BuildContext context) => MediaQuery.disableAnimationsOf(context)
      ? child
      : TweenAnimationBuilder<double>(
          duration: Duration(milliseconds: 220 + delayMs),
          curve: Interval(
            delayMs / (220 + delayMs),
            1,
            curve: Curves.easeOutCubic,
          ),
          tween: Tween(begin: 0, end: 1),
          builder: (context, v, child) => Opacity(
            opacity: v,
            child: Transform.translate(
              offset: Offset(0, 8 * (1 - v)),
              child: child,
            ),
          ),
          child: child,
        );
}
