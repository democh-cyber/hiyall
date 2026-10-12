import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../shared/chat_tokens.dart';
import '../shared/press_scale.dart';

/// The widest the conversation (and its header and composer) grows. Past this
/// the thread stays a centred column instead of hugging both window edges.
const conversationMaxWidth = 720.0;

/// The text scale chat chrome (header, chips, meta) keeps; the bubbles
/// themselves follow the system scale in full.
Widget clampedChrome(BuildContext context, Widget child, [double max = 1.3]) =>
    MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: MediaQuery.textScalerOf(context).clamp(maxScaleFactor: max),
      ),
      child: child,
    );

/// Light haptic for a sent message; a failure to buzz is never a failure to send.
Future<void> sendHaptic() async {
  try {
    await HapticFeedback.lightImpact();
  } catch (_) {}
}

/// The "midnight atmosphere" behind a conversation: the page colour with two
/// ambient highlights (lavender top right, lime bottom left) so faint they
/// read as depth, not as a pattern. Static, no dots, no noise, no animation.
class ChatAtmosphere extends StatelessWidget {
  final Widget child;
  const ChatAtmosphere({super.key, required this.child});
  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final strength = t.isDark ? 1.0 : 1.6;
    return DecoratedBox(
      key: const Key('chat-atmosphere'),
      decoration: BoxDecoration(color: t.bg),
      child: Stack(
        fit: StackFit.expand,
        children: [
          RepaintBoundary(
            child: ExcludeSemantics(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: const Alignment(1.15, -1.05),
                        radius: 1.05,
                        colors: [
                          t.lavender.withValues(alpha: .05 * strength),
                          t.lavender.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: const Alignment(-1.15, 1.1),
                        radius: 1.0,
                        colors: [
                          t.lime.withValues(alpha: .04 * strength),
                          t.lime.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

/// A quiet "End-to-end encrypted" chip.
class EncryptedChip extends StatelessWidget {
  final String text;
  const EncryptedChip({super.key, this.text = 'End-to-end encrypted'});
  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(100),
        border: Border.all(color: t.hairline.withValues(alpha: .55)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lock_rounded, size: 12, color: t.textSecondary),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: t.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A round icon control with the app's press feedback and a 48 dp target.
class ChatIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final Color? color;
  final Color? fill;
  final Color? border;
  final double size;
  final double iconSize;
  const ChatIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onTap,
    this.color,
    this.fill,
    this.border,
    this.size = ChatMetrics.hit,
    this.iconSize = 22,
  });
  @override
  Widget build(BuildContext context) {
    final c = color ?? ChatTokens.of(context).text;
    return Tooltip(
      message: tooltip,
      child: PressScale(
        onTap: onTap,
        semanticLabel: tooltip,
        borderRadius: BorderRadius.circular(size / 2),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: fill,
            border: border == null ? null : Border.all(color: border!),
          ),
          child: Icon(
            icon,
            size: iconSize,
            color: onTap == null ? c.withValues(alpha: .4) : c,
          ),
        ),
      ),
    );
  }
}
