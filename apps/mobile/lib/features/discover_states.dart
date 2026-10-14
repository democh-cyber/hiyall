import 'package:flutter/material.dart';

import '../shared/chat_tokens.dart';
import '../shared/press_scale.dart';
import 'chat_parts.dart' show clampedChrome;
import 'discover_header.dart';
import 'discover_style.dart';

/// A small outlined or filled pill button used by the Discover states.
class _StateAction extends StatelessWidget {
  final String label;
  final bool primary;
  final VoidCallback onTap;
  const _StateAction({
    super.key,
    required this.label,
    required this.onTap,
    this.primary = true,
  });
  @override
  Widget build(BuildContext context) {
    final s = DiscoverStyle.of(context);
    final t = s.t;
    return PressScale(
      onTap: onTap,
      semanticLabel: label,
      pressedScale: .97,
      minHeight: 48,
      child: Center(
        widthFactor: 1,
        heightFactor: 1,
        child: Container(
          height: 40,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          decoration: BoxDecoration(
            color: primary ? s.ctaFill : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
            border: primary ? null : Border.all(color: t.hairline),
          ),
          child: Center(
            widthFactor: 1,
            child: clampedChrome(
              context,
              Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: primary ? s.ctaInk : t.text,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Nobody to show: a short heading, one line of help and up to two actions.
class DiscoveryEmptyState extends StatelessWidget {
  final String title, body;
  final String? primaryLabel, secondaryLabel;
  final VoidCallback? onPrimary, onSecondary;
  const DiscoveryEmptyState({
    super.key,
    this.title = 'No one here just yet.',
    this.body = 'Try another filter or explore more people.',
    this.primaryLabel,
    this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
  });

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    return Padding(
      key: const Key('discover-empty'),
      padding: const EdgeInsets.fromLTRB(discoverPad, 28, discoverPad, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              title,
              style: TextStyle(
                fontFamily: 'SpaceGrotesk',
                fontSize: 22,
                height: 1.2,
                fontWeight: FontWeight.w700,
                letterSpacing: -.5,
                color: t.text,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            body,
            style: TextStyle(
              fontSize: 14.5,
              height: 1.4,
              color: t.textSecondary,
            ),
          ),
          if (primaryLabel != null) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              children: [
                _StateAction(
                  key: const Key('discover-empty-primary'),
                  label: primaryLabel!,
                  onTap: onPrimary!,
                ),
                if (secondaryLabel != null)
                  _StateAction(
                    key: const Key('discover-empty-secondary'),
                    label: secondaryLabel!,
                    onTap: onSecondary!,
                    primary: false,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// A failed load, with a real retry. The copy tells a lost connection from
/// anything else and never shows the server's raw text.
class DiscoveryErrorCard extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const DiscoveryErrorCard({
    super.key,
    required this.message,
    required this.onRetry,
  });

  /// A message the person can act on is shown as the server wrote it (waiting
  /// out a limit, signing in again); anything else becomes a neutral line.
  static bool actionable(String message) =>
      message == connectionMessage ||
      message.contains('session') ||
      message.contains('wait') ||
      message.contains('entries') ||
      message.contains('Try again');

  static const connectionMessage =
      'Could not connect. Check your connection and retry.';

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final connection = message == connectionMessage;
    final show = actionable(message);
    return Padding(
      key: const Key('discover-error'),
      padding: const EdgeInsets.fromLTRB(discoverPad, 28, discoverPad, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            liveRegion: true,
            child: Text(
              connection
                  ? 'Couldn’t connect.'
                  : show
                  ? 'A little pause.'
                  : 'Something went wrong.',
              style: TextStyle(
                fontFamily: 'SpaceGrotesk',
                fontSize: 22,
                height: 1.2,
                fontWeight: FontWeight.w700,
                letterSpacing: -.5,
                color: t.text,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            show ? message : 'Your people are taking a little longer to load.',
            style: TextStyle(
              fontSize: 14.5,
              height: 1.4,
              color: t.textSecondary,
            ),
          ),
          const SizedBox(height: 10),
          _StateAction(
            key: const Key('discovery-retry'),
            label: 'Retry',
            onTap: onRetry,
          ),
        ],
      ),
    );
  }
}

/// Skeleton rows with the same rhythm as real rows, so the list does not jump
/// when it arrives, and no spinner over the whole screen.
class DiscoveryLoadingState extends StatelessWidget {
  final int rows;
  const DiscoveryLoadingState({super.key, this.rows = 6});

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final fill = t.surface;
    Widget bar(double w, double h) => Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(h / 2),
      ),
    );
    return Semantics(
      label: 'Finding people',
      liveRegion: true,
      child: ExcludeSemantics(
        child: Column(
          key: const Key('discover-loading'),
          children: [
            for (var i = 0; i < rows; i++)
              Container(
                height: 84,
                padding: const EdgeInsets.symmetric(horizontal: discoverPad),
                child: Row(
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: fill,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          bar(100.0 + (i % 3) * 32, 13),
                          const SizedBox(height: 9),
                          bar(170.0 - (i % 2) * 40, 10),
                          const SizedBox(height: 8),
                          bar(120, 9),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Container(
                      width: 72,
                      height: 36,
                      decoration: BoxDecoration(
                        color: fill,
                        borderRadius: BorderRadius.circular(18),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The lightweight loader under the list while the next page comes in.
class DiscoveryPagingLoader extends StatelessWidget {
  const DiscoveryPagingLoader({super.key});
  @override
  Widget build(BuildContext context) => Padding(
    key: const Key('discover-paging'),
    padding: const EdgeInsets.symmetric(vertical: 18),
    child: Center(
      child: SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(
          strokeWidth: 2.2,
          color: ChatTokens.of(context).textTertiary,
        ),
      ),
    ),
  );
}

/// The "Explore more people" control under the list.
class DiscoveryMoreButton extends StatelessWidget {
  final VoidCallback onTap;
  const DiscoveryMoreButton({super.key, required this.onTap});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(discoverPad, 12, discoverPad, 0),
    child: Align(
      alignment: AlignmentDirectional.centerStart,
      child: _StateAction(
        key: const Key('discover-more'),
        label: 'Explore more people',
        onTap: onTap,
        primary: false,
      ),
    ),
  );
}
