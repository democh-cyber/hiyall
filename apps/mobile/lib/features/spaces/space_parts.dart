import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/theme.dart';
import '../../shared/person_avatar.dart';
import '../../shared/widgets.dart';
import 'space_format.dart';

/// A rounded tile with the space kind's icon and colour.
class SpaceKindBadge extends StatelessWidget {
  final String kind;
  final double size;
  const SpaceKindBadge(this.kind, {super.key, this.size = 48});
  @override
  Widget build(BuildContext context) {
    final (icon, color) = spaceKindStyle(kind);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(size * .32),
      ),
      child: Icon(icon, color: VibeColors.ink, size: size * .5),
    );
  }
}

/// The space's visual identity: its accent, a small orbit and the kind icon.
/// With [animate], the orbiting dot sweeps into place once on entrance.
class SpaceEmblem extends StatelessWidget {
  final SocialSpace space;
  final double size;
  final bool animate;
  const SpaceEmblem(
    this.space, {
    super.key,
    this.size = 56,
    this.animate = false,
  });
  @override
  Widget build(BuildContext context) {
    final tint = spaceTint(space);
    final icon = spaceKindStyle(space.kind).$1;
    Widget frame(double t) => Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: tint,
        borderRadius: BorderRadius.circular(size * .3),
      ),
      child: CustomPaint(
        painter: _OrbitPainter(t, space.spaceId.hashCode),
        child: Center(
          child: Icon(icon, color: VibeColors.ink, size: size * .42),
        ),
      ),
    );
    if (!animate || MediaQuery.disableAnimationsOf(context)) return frame(1);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 900),
      curve: Curves.easeOutCubic,
      builder: (context, t, _) => frame(t),
    );
  }
}

class _OrbitPainter extends CustomPainter {
  final double t;
  final int seed;
  const _OrbitPainter(this.t, this.seed);
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final tilt = (seed % 7) / 7 * math.pi - math.pi / 2;
    final rx = size.width * .44, ry = size.height * .2;
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(tilt * .5);
    canvas.drawOval(
      Rect.fromCenter(center: Offset.zero, width: rx * 2, height: ry * 2),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = VibeColors.ink.withValues(alpha: .28),
    );
    final angle = (seed % 360) * math.pi / 180 + math.pi * 1.4 * (1 - t);
    canvas.drawCircle(
      Offset(rx * math.cos(angle), ry * math.sin(angle)),
      size.width * .045,
      Paint()..color = VibeColors.ink,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_OrbitPainter old) => old.t != t || old.seed != seed;
}

class SpacePersonAvatar extends StatelessWidget {
  final Person person;
  final double radius;
  const SpacePersonAvatar(this.person, {super.key, this.radius = 18});
  @override
  Widget build(BuildContext context) => PersonAvatar(
    name: person.name,
    avatarUrl: person.avatarUrl,
    userId: person.userId,
    radius: radius,
  );
}

/// A neutral metadata pill that follows the theme; [highlight] uses lime.
class SpaceMetaTag extends StatelessWidget {
  final String text;
  final IconData? icon;
  final bool highlight;
  const SpaceMetaTag(this.text, {super.key, this.icon, this.highlight = false});
  @override
  Widget build(BuildContext context) {
    if (highlight) return VibeTag(text, icon: icon);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(100),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: scheme.onSurfaceVariant),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              text.toUpperCase(),
              style: TextStyle(
                color: scheme.onSurface,
                fontSize: 10,
                fontFamily: 'Manrope',
                fontWeight: FontWeight.w800,
                letterSpacing: 1.1,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// An icon followed by wrapping secondary text.
class SpaceInfoLine extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool selectable;
  const SpaceInfoLine(
    this.icon,
    this.text, {
    super.key,
    this.selectable = false,
  });
  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final style = TextStyle(fontSize: 14, height: 1.5, color: muted);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 19, color: muted),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: selectable
                ? SelectableText(text, style: style)
                : Text(text, style: style),
          ),
        ],
      ),
    );
  }
}

/// Small uppercase label that opens a section ("UPCOMING", "MEMBERS · 2").
class SpaceEyebrow extends StatelessWidget {
  final String text;
  const SpaceEyebrow(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 10),
    child: Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.2,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

/// What a tab shows instead of rows: the failure, a spinner, or [empty].
class SpaceTabNotice extends StatelessWidget {
  final Object? error;
  final bool loading;
  final String empty;
  final VoidCallback retry;
  const SpaceTabNotice({
    super.key,
    required this.error,
    required this.loading,
    required this.empty,
    required this.retry,
  });
  @override
  Widget build(BuildContext context) {
    if (error != null) return FailureCard(error: error!, retry: retry);
    if (loading) return const VibeLoading();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Center(
        child: Text(
          empty,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            height: 1.5,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
