import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/discover_prefs.dart';
import 'chat_tokens.dart';
import 'press_scale.dart';

/// A small dismissible tip card for the first time a feature is seen. [tipKey] names the tip: once the member
/// dismisses it (or takes its action), it never shows again on this device for this account; the choice is kept
/// per key by [discoverPrefsStoreProvider] and removed at sign-out. It shows nothing until the saved choice has
/// been read, so it never flashes up and vanishes. Collapses with a short animation, or at once when the
/// system asks to reduce motion.
///
/// A tip is quiet help, not a gate: nothing waits for it and it is never the only way to learn something.
class CoachTip extends ConsumerWidget {
  /// A stable id such as `discover.possible_matches`. Never change one that shipped.
  final String tipKey;
  final String title, message;
  final IconData icon;

  /// An optional single action (a button inside the card). Using it also dismisses the tip.
  final String? actionLabel;
  final VoidCallback? onAction;
  final EdgeInsetsGeometry margin;
  const CoachTip({
    super.key,
    required this.tipKey,
    required this.title,
    required this.message,
    this.icon = Icons.tips_and_updates_outlined,
    this.actionLabel,
    this.onAction,
    this.margin = const EdgeInsets.fromLTRB(16, 8, 16, 8),
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dismissed = ref.watch(dismissedTipsProvider);
    final show = dismissed != null && !dismissed.contains(tipKey);
    final still = MediaQuery.disableAnimationsOf(context);
    final content = show
        ? _TipCard(
            key: ValueKey('coach-tip-$tipKey'),
            title: title,
            message: message,
            icon: icon,
            margin: margin,
            actionLabel: actionLabel,
            onAction: onAction == null
                ? null
                : () {
                    ref.read(dismissedTipsProvider.notifier).dismiss(tipKey);
                    onAction!();
                  },
            onDismiss: () =>
                ref.read(dismissedTipsProvider.notifier).dismiss(tipKey),
          )
        : const SizedBox(width: double.infinity);
    // With reduced motion the tip just goes (a zero-length size animation is not allowed by the framework).
    if (still) return content;
    return AnimatedSize(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: content,
    );
  }
}

class _TipCard extends StatelessWidget {
  final String title, message;
  final IconData icon;
  final EdgeInsetsGeometry margin;
  final String? actionLabel;
  final VoidCallback? onAction;
  final VoidCallback onDismiss;
  const _TipCard({
    super.key,
    required this.title,
    required this.message,
    required this.icon,
    required this.margin,
    required this.onDismiss,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    return Padding(
      padding: margin,
      child: Semantics(
        container: true,
        label: 'Tip: $title. $message',
        child: Container(
          padding: const EdgeInsetsDirectional.fromSTEB(14, 12, 4, 12),
          decoration: BoxDecoration(
            color: t.elevated,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: t.hairline),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsetsDirectional.only(top: 2, end: 12),
                child: ExcludeSemantics(
                  child: Icon(icon, size: 22, color: t.accent),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ExcludeSemantics(
                      child: Text(
                        title,
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                          color: t.text,
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    ExcludeSemantics(
                      child: Text(
                        message,
                        style: TextStyle(
                          fontSize: 13.5,
                          height: 1.35,
                          color: t.textSecondary,
                        ),
                      ),
                    ),
                    if (actionLabel != null)
                      PressScale(
                        onTap: onAction,
                        minHeight: 48,
                        semanticLabel: actionLabel,
                        child: Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: Text(
                            actionLabel!,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: t.accent,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Semantics(
                button: true,
                label: 'Dismiss tip',
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: IconButton(
                    onPressed: onDismiss,
                    tooltip: 'Dismiss tip',
                    icon: ExcludeSemantics(
                      child: Icon(
                        Icons.close_rounded,
                        size: 18,
                        color: t.textSecondary,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
