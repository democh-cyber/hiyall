import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/theme.dart';
import 'avatar_gradient.dart';
import 'chat_tokens.dart';

enum DockStoryState { none, viewed, unseen }

/// The only navigation chrome shared by the app and its screen previews.
/// Counts and story state default to absent until supplied by their real sources.
class NavigationDock extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final String profileName;
  final ImageProvider? profilePhoto;
  final int unreadChats;
  final bool newActivity;
  final DockStoryState storyState;
  const NavigationDock({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
    required this.profileName,
    this.profilePhoto,
    this.unreadChats = 0,
    this.newActivity = false,
    this.storyState = DockStoryState.none,
  }) : assert(selectedIndex >= 0 && selectedIndex < 5),
       assert(unreadChats >= 0);
  static const labels = ['Home', 'Chats', 'Discover', 'Activity', 'Me'];

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final scale = MediaQuery.textScalerOf(context).scale(1);
    final largeText = scale > 1.15;
    final height = largeText ? 50 + 23 * scale : 68.0;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
        child: Align(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(26),
                boxShadow: [
                  BoxShadow(
                    color: t.shadow.withValues(alpha: t.isDark ? .22 : .08),
                    blurRadius: 22,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(26),
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: t.dockSurface.withValues(alpha: .92),
                      borderRadius: BorderRadius.circular(26),
                      border: Border.all(
                        color: t.hairline.withValues(alpha: t.isDark ? .8 : 1),
                        width: .8,
                      ),
                    ),
                    child: Material(
                      type: MaterialType.transparency,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: SizedBox(
                          height: height,
                          child: Row(
                            children: [
                              for (var i = 0; i < labels.length; i++)
                                if (largeText && i != selectedIndex)
                                  SizedBox(
                                    width: 48,
                                    height: height,
                                    child: item(context, i, largeText),
                                  )
                                else
                                  Expanded(child: item(context, i, largeText)),
                            ],
                          ),
                        ),
                      ),
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

  Widget item(BuildContext context, int index, bool largeText) =>
      DockDestination(
        index: index,
        label: labels[index],
        selected: index == selectedIndex,
        showLabel: !largeText || index == selectedIndex,
        profileName: profileName,
        profilePhoto: profilePhoto,
        unreadCount: index == 1 ? unreadChats : 0,
        activityDot: index == 3 && newActivity,
        storyState: storyState,
        onTap: () {
          if (index == selectedIndex) return;
          HapticFeedback.selectionClick();
          onSelected(index);
        },
      );
}

class DockDestination extends StatefulWidget {
  final int index, unreadCount;
  final String label, profileName;
  final bool selected, showLabel, activityDot;
  final VoidCallback onTap;
  final ImageProvider? profilePhoto;
  final DockStoryState storyState;
  const DockDestination({
    super.key,
    required this.index,
    required this.label,
    required this.profileName,
    required this.selected,
    required this.showLabel,
    required this.onTap,
    required this.storyState,
    this.profilePhoto,
    this.unreadCount = 0,
    this.activityDot = false,
  });
  @override
  State<DockDestination> createState() => _DockDestinationState();
}

class _DockDestinationState extends State<DockDestination>
    with SingleTickerProviderStateMixin {
  bool _pressed = false;
  late final controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    value: widget.selected ? 1 : 0,
  );
  @override
  void didUpdateWidget(covariant DockDestination oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected != widget.selected) {
      if (MediaQuery.disableAnimationsOf(context)) {
        controller.value = widget.selected ? 1 : 0;
      } else {
        controller.animateTo(
          widget.selected ? 1 : 0,
          curve: const _DockSpring(),
        );
      }
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final dark = t.isDark;
    final muted = t.textSecondary;
    final bright = dark ? t.text : VibeColors.ink;
    final label = dark ? t.accent : VibeColors.ink;
    final badgeLabel = widget.unreadCount > 0
        ? ', ${widget.unreadCount} unread messages'
        : widget.activityDot
        ? ', new activity'
        : '';
    final storyLabel = widget.index == 4
        ? switch (widget.storyState) {
            DockStoryState.unseen => ', new story',
            DockStoryState.viewed => ', story viewed',
            _ => '',
          }
        : '';
    return Semantics(
      label:
          '${widget.label}, tab ${widget.index + 1} of 5$badgeLabel$storyLabel',
      button: true,
      selected: widget.selected,
      onTap: widget.onTap,
      excludeSemantics: true,
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(20),
        // No grey hover or press rectangle behind a tab: feedback is a small press
        // scale, and keyboard focus keeps a soft lime ring.
        splashFactory: NoSplash.splashFactory,
        onHighlightChanged: (value) => setState(() => _pressed = value),
        overlayColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.focused)
              ? VibeColors.lime.withValues(alpha: .18)
              : Colors.transparent,
        ),
        child: AnimatedScale(
          scale: _pressed ? .94 : 1,
          duration: const Duration(milliseconds: 90),
          child: AnimatedBuilder(
            animation: controller,
            builder: (context, _) {
              final progress = controller.value;
              final color = Color.lerp(muted, bright, progress)!;
              final reduced = MediaQuery.disableAnimationsOf(context);
              return Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 56,
                    height: 34,
                    child: Stack(
                      alignment: Alignment.center,
                      clipBehavior: Clip.none,
                      children: [
                        // The selected pill: a soft lime tint that grows in.
                        Opacity(
                          opacity: progress,
                          child: Transform.scale(
                            scale: .8 + .2 * progress,
                            child: Container(
                              key: ValueKey('dock-pill-${widget.index}'),
                              width: 52,
                              height: 32,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(16),
                                color: VibeColors.lime.withValues(
                                  alpha: dark ? .17 : .55,
                                ),
                              ),
                            ),
                          ),
                        ),
                        Transform.scale(
                          scale: .98 + .06 * progress,
                          child: Transform.rotate(
                            angle: widget.index == 2 && !reduced
                                ? math.sin(progress * math.pi) * .1
                                : 0,
                            child: widget.index == 4
                                ? _avatar(dark, progress)
                                : SizedBox(
                                    width: 24,
                                    height: 24,
                                    child: CustomPaint(
                                      painter: _DockIconPainter(
                                        widget.index,
                                        color,
                                        progress,
                                      ),
                                    ),
                                  ),
                          ),
                        ),
                        if (widget.unreadCount > 0)
                          Positioned(
                            right: 1,
                            top: -3,
                            child: Container(
                              key: const ValueKey('chat-unread-badge'),
                              constraints: const BoxConstraints(minWidth: 18),
                              height: 18,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                              ),
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: dark ? VibeColors.lime : VibeColors.ink,
                                borderRadius: BorderRadius.circular(9),
                                border: Border.all(
                                  color: t.dockSurface,
                                  width: 1.5,
                                ),
                              ),
                              child: Text(
                                widget.unreadCount > 99
                                    ? '99+'
                                    : '${widget.unreadCount}',
                                textScaler: TextScaler.noScaling,
                                style: TextStyle(
                                  fontFamily: 'Manrope',
                                  fontSize: 10,
                                  height: 1.1,
                                  fontWeight: FontWeight.w800,
                                  color: dark
                                      ? VibeColors.ink
                                      : VibeColors.lime,
                                ),
                              ),
                            ),
                          ),
                        if (widget.activityDot)
                          Positioned(
                            right: 10,
                            top: 2,
                            child: Container(
                              key: const ValueKey('activity-unread-dot'),
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: dark
                                    ? VibeColors.lime
                                    : const Color(0xff58781b),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: t.dockSurface,
                                  width: 1.5,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (widget.showLabel)
                    Padding(
                      padding: const EdgeInsets.only(top: 2, left: 2, right: 2),
                      child: Text(
                        widget.label,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        style: TextStyle(
                          fontFamily: 'Manrope',
                          fontSize: 11,
                          height: 1.15,
                          fontWeight: FontWeight.lerp(
                            FontWeight.w500,
                            FontWeight.w800,
                            progress,
                          ),
                          color: Color.lerp(muted, label, progress),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _avatar(bool dark, double progress) {
    final initial = widget.profileName.trim().isEmpty
        ? 'K'
        : widget.profileName.trim().characters.first;
    final fallback = Container(
      decoration: BoxDecoration(
        gradient: avatarGradient(widget.profileName.trim()),
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        textScaler: TextScaler.noScaling,
        style: TextStyle(
          fontFamily: 'Manrope',
          fontSize: 12,
          fontWeight: FontWeight.w800,
          color: VibeColors.ink,
        ),
      ),
    );
    return SizedBox(
      width: 32,
      height: 32,
      child: CustomPaint(
        foregroundPainter: _AvatarRingPainter(
          widget.storyState,
          dark,
          progress,
        ),
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: ClipOval(
            child: widget.profilePhoto == null
                ? fallback
                : Image(
                    image: widget.profilePhoto!,
                    fit: BoxFit.cover,
                    width: 26,
                    height: 26,
                    errorBuilder: (_, error, stack) => fallback,
                  ),
          ),
        ),
      ),
    );
  }
}

/// A critically damped spring, normalized at 220ms; it has no bounce/overshoot.
class _DockSpring extends Curve {
  const _DockSpring();
  @override
  double transformInternal(double t) =>
      (1 - (1 + 7 * t) * math.exp(-7 * t)) / (1 - 8 * math.exp(-7));
}

class _AvatarRingPainter extends CustomPainter {
  final DockStoryState state;
  final bool dark;
  final double selection;
  const _AvatarRingPainter(this.state, this.dark, this.selection);
  @override
  void paint(Canvas canvas, Size size) {
    if (state == DockStoryState.none) return;
    final rect = Rect.fromLTWH(1, 1, size.width - 2, size.height - 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    if (state == DockStoryState.unseen) {
      paint.shader = SweepGradient(
        colors: const [
          VibeColors.lime,
          Color(0xffaa94ed),
          Color(0xff8bcccb),
          VibeColors.lime,
        ],
        transform: GradientRotation(selection * .15),
      ).createShader(rect);
    } else {
      paint.color = (dark ? Colors.white : VibeColors.ink).withValues(
        alpha: .3,
      );
    }
    canvas.drawOval(rect, paint);
  }

  @override
  bool shouldRepaint(_AvatarRingPainter old) =>
      old.state != state || old.dark != dark || old.selection != selection;
}

class _DockIconPainter extends CustomPainter {
  final int index;
  final Color color;
  final double selection;
  const _DockIconPainter(this.index, this.color, this.selection);
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    final pen = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.75 + .3 * selection
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    switch (index) {
      case 0:
        final home = Path()
          ..moveTo(3.3, 10.3)
          ..lineTo(12, 3.5)
          ..lineTo(20.7, 10.3)
          ..moveTo(5.8, 9.3)
          ..lineTo(5.8, 18.2)
          ..quadraticBezierTo(5.8, 20, 7.6, 20)
          ..lineTo(9.4, 20)
          ..lineTo(9.4, 14.4)
          ..quadraticBezierTo(9.4, 13.4, 10.5, 13.4)
          ..lineTo(13.5, 13.4)
          ..quadraticBezierTo(14.6, 13.4, 14.6, 14.4)
          ..lineTo(14.6, 20)
          ..lineTo(16.4, 20)
          ..quadraticBezierTo(18.2, 20, 18.2, 18.2)
          ..lineTo(18.2, 9.3);
        canvas.drawPath(home, pen);
      case 1:
        final chat = Path()
          ..moveTo(7.3, 4.8)
          ..lineTo(17.3, 4.8)
          ..quadraticBezierTo(21, 4.8, 21, 8.5)
          ..lineTo(21, 14)
          ..quadraticBezierTo(21, 17.7, 17.3, 17.7)
          ..lineTo(10.1, 17.7)
          ..lineTo(5.2, 20)
          ..lineTo(5.8, 16.9)
          ..quadraticBezierTo(3.6, 16.1, 3.6, 13.5)
          ..lineTo(3.6, 8.5)
          ..quadraticBezierTo(3.6, 4.8, 7.3, 4.8);
        canvas.drawPath(chat, pen);
        canvas.drawLine(const Offset(8, 10), const Offset(16.4, 10), pen);
        canvas.drawLine(const Offset(8, 13.4), const Offset(13, 13.4), pen);
      case 2:
        final orbit = Path()
          ..moveTo(12, 2.9)
          ..quadraticBezierTo(14.1, 9.2, 21.1, 12)
          ..quadraticBezierTo(14.1, 14.3, 12, 21.1)
          ..quadraticBezierTo(9.7, 14.3, 2.9, 12)
          ..quadraticBezierTo(9.7, 9.2, 12, 2.9)
          ..close();
        canvas.drawPath(orbit, pen);
        canvas.drawCircle(const Offset(12, 12), 1.4, Paint()..color = color);
        canvas.drawLine(
          const Offset(18.5, 4),
          const Offset(20.5, 2),
          pen..strokeWidth = 1.5,
        );
      case 3:
        final pulse = Path()
          ..moveTo(2.5, 12.5)
          ..lineTo(6.5, 12.5)
          ..quadraticBezierTo(7, 12.5, 7.2, 11.9)
          ..lineTo(9.4, 5.6)
          ..quadraticBezierTo(9.8, 4.5, 10.2, 5.8)
          ..lineTo(13.5, 18)
          ..quadraticBezierTo(13.9, 19.2, 14.3, 18)
          ..lineTo(16.3, 11.4)
          ..quadraticBezierTo(16.6, 10.7, 17.1, 10.7)
          ..lineTo(21.5, 10.7);
        canvas.drawPath(pulse, pen);
    }
  }

  @override
  bool shouldRepaint(_DockIconPainter old) =>
      old.index != index || old.color != color || old.selection != selection;
}
