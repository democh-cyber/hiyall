import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/theme.dart';
import '../profile_stats.dart';
import 'profile_avatar.dart';
import 'profile_share.dart';

/// The avatar, name, headline, actions, stats and current vibe at the top of a
/// profile, over an optional accent glow and orbit pattern.
class ProfileHero extends StatelessWidget {
  final Profile profile;
  final bool isOwner;
  final VoidCallback? onEdit;
  final ProfileStatActions statActions;
  final ScrollController scroll;
  final Color accent, ink, muted;
  const ProfileHero({
    super.key,
    required this.profile,
    required this.isOwner,
    required this.onEdit,
    required this.statActions,
    required this.scroll,
    required this.accent,
    required this.ink,
    required this.muted,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final reduced = MediaQuery.disableAnimationsOf(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: reduced ? 1 : 0, end: 1),
      duration: Duration(milliseconds: reduced ? 0 : 260),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, 8 * (1 - value)),
          child: child,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: profile.profilePattern == 'plain'
                ? null
                : RadialGradient(
                    center: const Alignment(0, -.75),
                    radius: .8,
                    colors: [
                      accent.withValues(alpha: dark ? .07 : .16),
                      accent.withValues(alpha: 0),
                    ],
                  ),
          ),
          child: Stack(
            children: [
              if (profile.profilePattern == 'orbit')
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: ProfileOrbitPainter(
                        accent.withValues(alpha: .12),
                      ),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
                child: _HeroBody(
                  profile: profile,
                  isOwner: isOwner,
                  onEdit: onEdit,
                  statActions: statActions,
                  scroll: scroll,
                  accent: accent,
                  ink: ink,
                  muted: muted,
                  dark: dark,
                  reduced: reduced,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeroBody extends StatelessWidget {
  final Profile profile;
  final bool isOwner, dark, reduced;
  final VoidCallback? onEdit;
  final ProfileStatActions statActions;
  final ScrollController scroll;
  final Color accent, ink, muted;
  const _HeroBody({
    required this.profile,
    required this.isOwner,
    required this.onEdit,
    required this.statActions,
    required this.scroll,
    required this.accent,
    required this.ink,
    required this.muted,
    required this.dark,
    required this.reduced,
  });

  @override
  Widget build(BuildContext context) {
    final p = profile;
    return Column(
      children: [
        AnimatedBuilder(
          animation: scroll,
          builder: (context, child) {
            final progress = reduced || !scroll.hasClients
                ? 0.0
                : scroll.offset.clamp(0, 160) / 160;
            return SizedBox(
              height: 112 * (1 - progress * .18),
              child: Transform.scale(scale: 1 - progress * .18, child: child),
            );
          },
          child: ProfileAvatar(profile: p, accent: accent),
        ),
        const SizedBox(height: 12),
        _HeroIdentity(profile: p, isOwner: isOwner, ink: ink, muted: muted),
        const SizedBox(height: 12),
        _HeroActions(
          profile: p,
          isOwner: isOwner,
          onEdit: onEdit,
          accent: accent,
          ink: ink,
          dark: dark,
        ),
        if (p.socialStats != null) ...[
          const SizedBox(height: 12),
          ProfileStatsRow(
            stats: p.socialStats!,
            actions: statActions,
            ink: ink,
            muted: muted,
          ),
        ],
        if (isOwner || p.currentVibe.isNotEmpty) ...[
          const SizedBox(height: 12),
          _CurrentVibeCard(
            vibe: p.currentVibe,
            isOwner: isOwner,
            onEdit: onEdit,
            accent: accent,
            ink: ink,
            muted: muted,
            dark: dark,
          ),
        ],
      ],
    );
  }
}

class _HeroIdentity extends StatelessWidget {
  final Profile profile;
  final bool isOwner;
  final Color ink, muted;
  const _HeroIdentity({
    required this.profile,
    required this.isOwner,
    required this.ink,
    required this.muted,
  });

  @override
  Widget build(BuildContext context) {
    final p = profile;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          p.displayName,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: 'SpaceGrotesk',
            fontSize: 34,
            height: 1.08,
            fontWeight: FontWeight.w700,
            letterSpacing: -1,
            color: ink,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '@${p.username}',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12,
            height: 1.5,
            fontWeight: FontWeight.w600,
            letterSpacing: .4,
            color: muted,
          ),
        ),
        if (p.headline.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            p.headline,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              height: 1.4,
              fontWeight: FontWeight.w700,
              color: ink,
            ),
          ),
        ],
        if (p.bio.isNotEmpty || isOwner) ...[
          const SizedBox(height: 4),
          Text(
            p.bio.isEmpty ? 'Your story starts with a few words.' : p.bio,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              height: 1.5,
              color: ink.withValues(alpha: .85),
            ),
          ),
        ],
        if (p.quote.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            '“${p.quote}”',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, height: 1.5, color: muted),
          ),
        ],
      ],
    );
  }
}

class _HeroActions extends StatelessWidget {
  final Profile profile;
  final bool isOwner, dark;
  final VoidCallback? onEdit;
  final Color accent, ink;
  const _HeroActions({
    required this.profile,
    required this.isOwner,
    required this.onEdit,
    required this.accent,
    required this.ink,
    required this.dark,
  });

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    alignment: WrapAlignment.center,
    children: [
      if (isOwner)
        FilledButton.icon(
          onPressed: onEdit,
          style: FilledButton.styleFrom(
            backgroundColor: accent,
            foregroundColor: VibeColors.ink,
            minimumSize: const Size(128, 48),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            visualDensity: VisualDensity.standard,
          ),
          icon: const Icon(Icons.edit_outlined, size: 16),
          label: const Text('Edit profile'),
        ),
      OutlinedButton.icon(
        onPressed: () => shareProfile(context, profile),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(100, 48),
          foregroundColor: ink,
          side: BorderSide(
            color: VibeColors.lilac.withValues(alpha: dark ? .25 : .6),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          visualDensity: VisualDensity.standard,
        ),
        icon: const Icon(Icons.north_east_rounded, size: 16),
        label: const Text('Share'),
      ),
    ],
  );
}

class _CurrentVibeCard extends StatelessWidget {
  final String vibe;
  final bool isOwner, dark;
  final VoidCallback? onEdit;
  final Color accent, ink, muted;
  const _CurrentVibeCard({
    required this.vibe,
    required this.isOwner,
    required this.onEdit,
    required this.accent,
    required this.ink,
    required this.muted,
    required this.dark,
  });

  @override
  Widget build(BuildContext context) => Material(
    color: accent.withValues(alpha: dark ? .045 : .12),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
      side: BorderSide(color: accent.withValues(alpha: .12)),
    ),
    child: InkWell(
      onTap: isOwner ? onEdit : null,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'CURRENT VIBE',
                    style: TextStyle(
                      fontSize: 9,
                      letterSpacing: 1.4,
                      fontWeight: FontWeight.w800,
                      color: muted,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    vibe.isEmpty ? 'What’s your vibe?' : vibe,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.5,
                      fontWeight: FontWeight.w600,
                      color: ink,
                    ),
                  ),
                ],
              ),
            ),
            if (isOwner) Icon(Icons.north_east_rounded, size: 16, color: muted),
          ],
        ),
      ),
    ),
  );
}

/// A faint tilted orbit behind the avatar for the "orbit" profile pattern.
class ProfileOrbitPainter extends CustomPainter {
  final Color color;
  const ProfileOrbitPainter(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    // RTL: physical (artwork)
    final pen = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = .7;
    canvas.save();
    canvas.translate(size.width / 2, 68);
    canvas.rotate(-math.pi / 9);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset.zero,
        width: size.width * .93,
        height: 110,
      ),
      pen,
    );
    canvas.drawCircle(
      Offset(size.width * .38, -24),
      2.5,
      Paint()..color = color,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(ProfileOrbitPainter oldDelegate) =>
      oldDelegate.color != color;
}
