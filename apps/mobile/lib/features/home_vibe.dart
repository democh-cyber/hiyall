import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/state.dart';
import '../core/theme.dart';
import '../shared/press_scale.dart';

/// One mood on the vibe strip. What gets saved is [value], the same plain text
/// the profile editor's own vibe chips write, so the two always agree.
class HomeVibe {
  final String emoji, label;
  const HomeVibe(this.emoji, this.label);
  String get value => '$emoji $label';
}

const homeVibes = [
  HomeVibe('😴', 'Sleepy'),
  HomeVibe('🔥', 'On fire'),
  HomeVibe('🎧', 'Vibing'),
  HomeVibe('🌧️', 'Gloomy'),
  HomeVibe('🥳', 'Celebrating'),
  HomeVibe('💭', 'Thinking'),
  HomeVibe('✨', 'Main character'),
  HomeVibe('📚', 'Locked in'),
  HomeVibe('🍜', 'Hungry'),
];

/// "What's your vibe today?": one tap sets the member's current vibe, a second
/// tap on the chosen chip turns it off. Owns its own state so a tap repaints
/// this strip and nothing else on Home.
class HomeVibeStrip extends ConsumerStatefulWidget {
  /// Wraps onto several lines instead of scrolling sideways, for the wide rail.
  final bool wrap;
  const HomeVibeStrip({super.key, this.wrap = false});
  @override
  ConsumerState<HomeVibeStrip> createState() => _HomeVibeStripState();
}

enum _Status { idle, saving, saved, failed }

class _HomeVibeStripState extends ConsumerState<HomeVibeStrip> {
  /// What the member just picked, shown before the server has answered and
  /// until the refreshed profile carries it.
  String? pending;
  _Status status = _Status.idle;
  String? savedValue;
  Timer? reset;

  @override
  void dispose() {
    reset?.cancel();
    super.dispose();
  }

  void settleSoon() {
    reset?.cancel();
    reset = Timer(const Duration(milliseconds: 2200), () {
      if (mounted) {
        setState(() {
          status = _Status.idle;
          savedValue = null;
        });
      }
    });
  }

  Future<void> pick(String value, String current) async {
    if (status == _Status.saving) return;
    final profile = ref.read(profileProvider).value;
    final session = ref.read(sessionProvider).asData?.value;
    if (profile == null || session == null) return;
    final next = current == value ? '' : value;
    reset?.cancel();
    setState(() {
      pending = next;
      status = _Status.saving;
      savedValue = null;
    });
    try {
      await ref.read(apiProvider).updateProfile(session, profile, {
        'currentVibe': next,
      });
      ref.invalidate(profileProvider);
      try {
        await ref.read(profileProvider.future);
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        pending = null;
        status = _Status.saved;
        savedValue = next.isEmpty ? null : next;
      });
    } catch (_) {
      // A stale version or a dropped connection: show what the server has.
      ref.invalidate(profileProvider);
      if (!mounted) return;
      setState(() {
        pending = null;
        status = _Status.failed;
      });
    }
    settleSoon();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final profileVibe = ref.watch(
      profileProvider.select((p) => p.value?.currentVibe.trim()),
    );
    final selected = pending ?? profileVibe ?? '';
    final known = homeVibes.any((v) => v.value == selected);
    // A vibe typed in the editor leads the strip, already chosen.
    final chips = <Widget>[
      if (selected.isNotEmpty && !known)
        _VibeChip(
          key: const Key('vibe-custom'),
          emoji: '',
          label: selected,
          on: true,
          saved: savedValue == selected,
          onTap: () => pick(selected, selected),
        ),
      for (final v in homeVibes)
        _VibeChip(
          key: Key('vibe-${v.label.toLowerCase().replaceAll(' ', '-')}'),
          emoji: v.emoji,
          label: v.label,
          on: selected == v.value,
          saved: savedValue == v.value,
          onTap: () => pick(v.value, selected),
        ),
    ];
    final (text, color, icon) = switch (status) {
      _Status.saving => ('Saving…', scheme.onSurfaceVariant, null),
      _Status.saved => (
        savedValue == null ? 'Vibe cleared' : 'Vibe saved',
        scheme.onSurfaceVariant,
        Icons.check_circle_rounded,
      ),
      _Status.failed => (
        'Couldn’t save that. Try again?',
        scheme.error,
        Icons.error_outline_rounded,
      ),
      _ => ('What’s your vibe today?', scheme.onSurfaceVariant, null),
    };
    final scaler = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3);
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: scaler),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: widget.wrap ? 0 : 20),
            child: Semantics(
              liveRegion: true,
              child: Row(
                children: [
                  if (icon != null) ...[
                    Icon(
                      icon,
                      size: 15,
                      color: status == _Status.saved ? scheme.primary : color,
                    ),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Text(
                      text,
                      key: const Key('vibe-status'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: color,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          if (widget.wrap)
            Wrap(spacing: 8, children: chips)
          else
            SizedBox(
              height: 48 + scaler.scale(14) - 14,
              child: ScrollConfiguration(
                behavior: const DragAnywhereBehavior(),
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: chips.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (_, i) => chips[i],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _VibeChip extends StatelessWidget {
  final String emoji, label;
  final bool on, saved;
  final VoidCallback onTap;
  const _VibeChip({
    super.key,
    required this.emoji,
    required this.label,
    required this.on,
    required this.saved,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final duration = VibeMotion.duration(context);
    return PressScale(
      minHeight: 48,
      selected: on,
      semanticLabel: '$label vibe',
      semanticHint: on ? 'Selected. Tap to turn your vibe off.' : null,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: AnimatedContainer(
          duration: duration,
          curve: Curves.easeOutCubic,
          constraints: const BoxConstraints(minHeight: 40),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: on
                ? VibeColors.lime
                : (dark
                      ? scheme.surfaceContainerHigh
                      : scheme.surfaceContainerLowest),
            borderRadius: BorderRadius.circular(100),
            border: Border.all(
              color: on ? VibeColors.lime : scheme.outlineVariant,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (emoji.isNotEmpty) ...[
                Text(emoji, style: const TextStyle(fontSize: 16)),
                const SizedBox(width: 7),
              ],
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: math.min(220, MediaQuery.sizeOf(context).width / 2),
                ),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: on ? FontWeight.w800 : FontWeight.w600,
                    color: on ? VibeColors.ink : scheme.onSurface,
                  ),
                ),
              ),
              if (saved) ...[
                const SizedBox(width: 6),
                const Icon(
                  Icons.check_rounded,
                  size: 16,
                  color: VibeColors.ink,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
