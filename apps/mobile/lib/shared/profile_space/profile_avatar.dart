import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/theme.dart';
import '../person_avatar.dart';

/// The profile photo inside the accent frame. Without one, an original
/// code-generated monogram: a static orbital composition, not a story or
/// verification signal.
class ProfileAvatar extends StatelessWidget {
  final Profile profile;
  final Color accent;
  final double size;
  const ProfileAvatar({
    super.key,
    required this.profile,
    required this.accent,
    this.size = 112,
  });
  @override
  Widget build(BuildContext context) => Semantics(
    label: '${profile.displayName} profile avatar',
    child: SizedBox(
      width: size,
      height: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: accent.withValues(alpha: .45),
            width: profile.avatarFrame == 'orbit' ? 2 : .7,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: PersonAvatar(
            name: profile.displayName.trim().isEmpty
                ? 'K'
                : profile.displayName,
            avatarUrl: profile.avatarFor(size),
            userId: profile.userId,
            radius: (size - 10) / 2,
            // Without a photo the generated monogram stays.
            fallback: CustomPaint(
              painter: IdentityAvatarPainter(accent, profile.username),
              child: Center(
                child: Text(
                  profile.displayName.trim().isEmpty
                      ? 'K'
                      : profile.displayName
                            .trim()
                            .characters
                            .first
                            .toUpperCase(),
                  textScaler: TextScaler.noScaling,
                  style: TextStyle(
                    fontFamily: 'SpaceGrotesk',
                    fontSize: size * .36,
                    fontWeight: FontWeight.w700,
                    color: VibeColors.ink,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class IdentityAvatarPainter extends CustomPainter {
  final Color accent;
  final String identity;
  const IdentityAvatarPainter(this.accent, this.identity);
  @override
  void paint(Canvas canvas, Size size) {
    final bounds = Offset.zero & size;
    canvas.drawRect(
      bounds,
      Paint()
        ..shader = LinearGradient(
          // RTL: physical (artwork)
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.lerp(accent, Colors.white, .35)!,
            accent,
            Color.lerp(accent, VibeColors.lilac, .6)!,
          ],
        ).createShader(bounds),
    );
    final seed = identity.codeUnits.fold<int>(0, (sum, c) => sum + c);
    canvas.save();
    canvas.translate(size.width * .5, size.height * .5);
    canvas.rotate((seed % 12) * math.pi / 12);
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * .12
      ..color = Colors.white.withValues(alpha: .16);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(size.width * .23, 0),
        width: size.width * .95,
        height: size.height * 1.4,
      ),
      line,
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(-size.width * .3, 0),
        width: size.width * .7,
        height: size.height * 1.2,
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = VibeColors.ink.withValues(alpha: .1),
    );
    canvas.restore();
    canvas.drawCircle(
      Offset(size.width * .77, size.height * .22),
      size.width * .035,
      Paint()..color = VibeColors.ink.withValues(alpha: .35),
    );
  }

  @override
  bool shouldRepaint(IdentityAvatarPainter oldDelegate) =>
      oldDelegate.accent != accent || oldDelegate.identity != identity;
}
