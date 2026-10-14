import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme.dart';

void storyBuzz(Future<void> Function() haptic) {
  // Platforms without a motor, and tests, just do nothing.
  unawaited(haptic().catchError((_) {}));
}

/// A tap target with the app's press feel: a small scale, a ring for keyboard focus, no ink.
/// At least 48 × 48 whatever the look inside is.
class StoryTap extends StatefulWidget {
  final String label;
  final VoidCallback? onTap;
  final bool? selected;
  final double scale;
  final double radius;
  final Widget Function(bool pressed) builder;
  const StoryTap({
    super.key,
    required this.label,
    required this.onTap,
    required this.builder,
    this.selected,
    this.scale = .94,
    this.radius = 24,
  });
  @override
  State<StoryTap> createState() => _StoryTapState();
}

class _StoryTapState extends State<StoryTap> {
  bool _pressed = false, _focused = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final reduce = MediaQuery.disableAnimationsOf(context);
    final enabled = widget.onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      selected: widget.selected,
      label: widget.label,
      excludeSemantics: true,
      onTap: widget.onTap,
      child: FocusableActionDetector(
        enabled: enabled,
        mouseCursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap?.call();
              return null;
            },
          ),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          onTap: widget.onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            child: Center(
              widthFactor: 1,
              heightFactor: 1,
              child: AnimatedScale(
                scale: _pressed && !reduce ? widget.scale : 1,
                duration: const Duration(milliseconds: 90),
                child: Container(
                  foregroundDecoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(widget.radius),
                    border: Border.all(
                      color: _focused ? scheme.onSurface : Colors.transparent,
                      width: 2,
                    ),
                  ),
                  child: widget.builder(_pressed),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A pill: lime when [on], a quiet surface otherwise.
BoxDecoration storyPill(
  BuildContext context, {
  bool on = false,
  double radius = 24,
}) {
  final scheme = Theme.of(context).colorScheme;
  return BoxDecoration(
    color: on ? VibeColors.lime : scheme.surfaceContainerHigh,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(
      color: on ? VibeColors.lime : scheme.outlineVariant,
      width: 1.5,
    ),
  );
}

TextStyle storyPillText(
  BuildContext context, {
  bool on = false,
  double? size,
}) => TextStyle(
  fontFamily: 'Manrope',
  fontWeight: on ? FontWeight.w800 : FontWeight.w700,
  fontSize: size ?? 14,
  color: on ? VibeColors.ink : Theme.of(context).colorScheme.onSurface,
);

/// A horizontally scrolling row of controls, centred when it fits.
class StoryScrollRow extends StatelessWidget {
  final List<Widget> children;
  const StoryScrollRow({super.key, required this.children});
  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(children: children),
    ),
  );
}
