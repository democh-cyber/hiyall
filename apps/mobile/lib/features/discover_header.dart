import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/surprise.dart';
import '../core/theme.dart';
import '../shared/chat_tokens.dart';
import '../shared/press_scale.dart';
import '../shared/widgets.dart' show starPath;
import 'chat_parts.dart' show clampedChrome;
import 'discover_style.dart';

/// The page margin of the Discover screen, the same as Home and Chats.
const discoverPad = ChatMetrics.pagePadding;

/// "Find your people." with the compass that opens Circles and Moments beside it.
/// The compass is handed in by the hub, which owns the section switch.
class DiscoveryHeader extends StatelessWidget {
  final String title;
  final Widget? trailing;
  const DiscoveryHeader({super.key, required this.title, this.trailing});

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(discoverPad, 0, 8, 0),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              // Like the Chats heading, it grows with the system text size up to a point.
              child: clampedChrome(
                context,
                Text(
                  title,
                  key: const Key('discover-heading'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'SpaceGrotesk',
                    fontSize: 29,
                    height: 1.2,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -1,
                    color: t.text,
                  ),
                ),
                1.3,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// "Someone new is one hello away": the signature card of Discover.
///
/// It is presentation only. [onSurprise] is the single callback it calls; today
/// that opens the profile of a person picked from the loaded results, and it
/// never starts a chat. A future matching flow can replace what the callback
/// does without changing this widget. The card owns no state: [status] says
/// which of the four states to show.
class SurpriseCard extends StatelessWidget {
  final SurpriseStatus status;
  final VoidCallback onSurprise;
  const SurpriseCard({
    super.key,
    required this.status,
    required this.onSurprise,
  });

  @override
  Widget build(BuildContext context) {
    final s = DiscoverStyle.of(context);
    final t = s.t;
    final loading = status == SurpriseStatus.loading;
    final line = switch (status) {
      SurpriseStatus.nothing => 'No one new right now. Try again in a bit.',
      SurpriseStatus.error =>
        'Couldn’t find anyone just now. Check your connection.',
      _ => 'New faces. Unexpected conversations.',
    };
    final ctaText = switch (status) {
      SurpriseStatus.loading => 'Finding someone…',
      SurpriseStatus.error => 'Retry',
      SurpriseStatus.nothing => 'Try again',
      _ => 'Surprise me →',
    };
    final media = MediaQuery.of(context);
    // On a normal phone at normal text the line and the button share a row and
    // the card is about 86 px tall; narrower or larger, they stack.
    final stacked =
        media.size.width < 360 || media.textScaler.scale(14) / 14 > 1.1;
    final subtitle = Semantics(
      liveRegion: status != SurpriseStatus.ready,
      child: Text(
        line,
        key: const Key('surprise-line'),
        style: TextStyle(fontSize: 13, height: 1.3, color: t.textSecondary),
      ),
    );
    final cta = PressScale(
      key: const Key('surprise-cta'),
      onTap: loading ? null : onSurprise,
      semanticLabel: loading
          ? 'Finding someone'
          : 'Surprise me. Opens the profile of someone new. No chat starts.',
      pressedScale: .97,
      minHeight: 44,
      child: Align(
        alignment: Alignment.centerLeft,
        widthFactor: 1,
        heightFactor: 1,
        child: AnimatedContainer(
          duration: VibeMotion.duration(context),
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: loading ? s.ctaFill.withValues(alpha: .6) : s.ctaFill,
            borderRadius: BorderRadius.circular(22),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (loading) ...[
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: s.ctaInk,
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Text(
                  ctaText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w800,
                    color: s.ctaInk,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final title = Semantics(
      header: true,
      child: Text(
        'Someone new is one hello away',
        style: TextStyle(
          fontFamily: 'SpaceGrotesk',
          fontSize: 17,
          height: 1.2,
          fontWeight: FontWeight.w700,
          letterSpacing: -.4,
          color: t.text,
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(discoverPad, 4, discoverPad, 0),
      child: Container(
        key: const Key('surprise-card'),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [s.cardFrom, s.cardTo],
          ),
          border: Border.all(
            color: t.hairline.withValues(alpha: t.isDark ? .55 : .9),
          ),
        ),
        child: Stack(
          children: [
            Positioned(
              // Beside the title (the button sits below it) when the card is one
              // row, bottom right when it stacks.
              right: stacked ? 10 : 14,
              top: stacked ? null : 3,
              bottom: stacked ? 6 : null,
              child: ExcludeSemantics(
                child: SizedBox(
                  width: stacked ? 40 : 28,
                  height: stacked ? 40 : 28,
                  child: CustomPaint(painter: _StarburstPainter(t)),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
              child: clampedChrome(
                context,
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 48),
                      child: title,
                    ),
                    const SizedBox(height: 2),
                    if (stacked) ...[
                      Padding(
                        padding: const EdgeInsets.only(right: 48),
                        child: subtitle,
                      ),
                      const SizedBox(height: 6),
                      cta,
                    ] else
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(child: subtitle),
                          const SizedBox(width: 12),
                          cta,
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A small abstract starburst on two orbits: Hiyall's mark, as a quiet signature.
class _StarburstPainter extends CustomPainter {
  final ChatTokens t;
  const _StarburstPainter(this.t);
  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final accent = t.isDark ? t.lavender : t.accent;
    final line = Paint()
      ..color = accent.withValues(alpha: .5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(-.5);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset.zero,
        width: size.width * .98,
        height: size.width * .44,
      ),
      line,
    );
    canvas.rotate(1.05);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset.zero,
        width: size.width * .84,
        height: size.width * .4,
      ),
      line,
    );
    canvas.restore();
    canvas.drawPath(
      starPath(c, size.width * .22, size.width * .09),
      Paint()..color = t.lime,
    );
    canvas.drawCircle(
      c.translate(size.width * .3, -size.width * .24),
      size.width * .075,
      Paint()..color = accent,
    );
    canvas.drawCircle(
      c.translate(-size.width * .34, size.width * .2),
      size.width * .055,
      Paint()..color = t.lime.withValues(alpha: .8),
    );
  }

  @override
  bool shouldRepaint(_StarburstPainter old) => old.t != t;
}

/// "Explore people" with the filter button on the right: the count of filters
/// that are on, and a Reset when there are some. Below 360 px or at large text
/// the button keeps only its icon (and its label for screen readers).
class DiscoveryExploreRow extends StatelessWidget {
  final int activeCount;
  final VoidCallback onFilters, onReset;
  const DiscoveryExploreRow({
    super.key,
    required this.activeCount,
    required this.onFilters,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(discoverPad, 2, 12, 0),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: clampedChrome(
                context,
                Text(
                  'Explore people',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'SpaceGrotesk',
                    fontSize: 20,
                    height: 1.2,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -.5,
                    color: t.text,
                  ),
                ),
                1.3,
              ),
            ),
          ),
          if (activeCount > 0)
            clampedChrome(
              context,
              TextButton(
                key: const Key('discover-reset'),
                onPressed: onReset,
                style: TextButton.styleFrom(
                  minimumSize: const Size(48, 48),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  foregroundColor: t.textSecondary,
                  overlayColor: Colors.transparent,
                ),
                child: const Text(
                  'Reset',
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
                ),
              ),
            ),
          DiscoveryFilterButton(count: activeCount, onTap: onFilters),
        ],
      ),
    );
  }
}

/// The compact filter button: a tune icon, "Filters" and a lime count badge.
class DiscoveryFilterButton extends StatelessWidget {
  final int count;
  final VoidCallback onTap;
  const DiscoveryFilterButton({
    super.key,
    required this.count,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final s = DiscoverStyle.of(context);
    final t = s.t;
    final media = MediaQuery.of(context);
    final compact =
        media.size.width < 360 || media.textScaler.scale(14) / 14 > 1.5;
    final label = count > 0 ? 'Filters, $count active' : 'Filters';
    return Tooltip(
      message: 'Filter people',
      child: PressScale(
        key: const Key('discover-filters'),
        onTap: onTap,
        semanticLabel: label,
        pressedScale: .96,
        minHeight: 48,
        child: Center(
          widthFactor: 1,
          heightFactor: 1,
          child: Container(
            height: 40,
            constraints: const BoxConstraints(minWidth: 40),
            padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 14),
            decoration: BoxDecoration(
              color: count > 0 ? s.chipSelectedFill : t.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: count > 0
                    ? Colors.transparent
                    : t.hairline.withValues(alpha: .6),
              ),
            ),
            child: clampedChrome(
              context,
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.tune_rounded,
                    size: 18,
                    color: count > 0 ? s.chipSelectedInk : t.textSecondary,
                  ),
                  if (!compact) ...[
                    const SizedBox(width: 6),
                    Text(
                      'Filters',
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: count > 0 ? s.chipSelectedInk : t.textSecondary,
                      ),
                    ),
                  ],
                  if (count > 0) ...[
                    SizedBox(width: compact ? 4 : 6),
                    Container(
                      constraints: const BoxConstraints(minWidth: 20),
                      height: 20,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: s.badgeFill,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '$count',
                        key: const Key('filter-count'),
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                          color: s.badgeInk,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One category in [DiscoveryCategoryChips].
class DiscoveryCategory {
  final String label;
  final Key key;
  final bool selected;
  final VoidCallback onTap;
  const DiscoveryCategory({
    required this.label,
    required this.key,
    required this.selected,
    required this.onTap,
  });
}

/// The pinned row of category chips. It fades at both edges when it can scroll,
/// so a chip cut off by the screen reads as "more this way".
class DiscoveryChipsHeader extends SliverPersistentHeaderDelegate {
  final List<DiscoveryCategory> categories;
  const DiscoveryChipsHeader(this.categories);

  /// 48 dp touch targets around 36 px chips.
  static const extent = 52.0;

  @override
  double get minExtent => extent;
  @override
  double get maxExtent => extent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => Material(
    color: Theme.of(context).scaffoldBackgroundColor,
    child: SizedBox(
      height: extent,
      child: Align(
        alignment: Alignment.centerLeft,
        child: DiscoveryCategoryChips(categories: categories),
      ),
    ),
  );

  @override
  bool shouldRebuild(DiscoveryChipsHeader old) => true;
}

class DiscoveryCategoryChips extends StatefulWidget {
  final List<DiscoveryCategory> categories;
  const DiscoveryCategoryChips({super.key, required this.categories});
  @override
  State<DiscoveryCategoryChips> createState() => _DiscoveryCategoryChipsState();
}

class _DiscoveryCategoryChipsState extends State<DiscoveryCategoryChips> {
  final scroll = ScrollController();
  final _chipKeys = <GlobalKey>[];

  /// The chip the row was last scrolled to, so a rebuild that changes nothing
  /// never moves the row under the member's finger.
  Key? _revealed;
  bool _first = true;

  @override
  void initState() {
    super.initState();
    _scheduleReveal();
  }

  @override
  void didUpdateWidget(DiscoveryCategoryChips old) {
    super.didUpdateWidget(old);
    _scheduleReveal();
  }

  void _scheduleReveal() =>
      WidgetsBinding.instance.addPostFrameCallback((_) => _revealSelected());

  /// Brings the selected chip fully into view, centred when there is room, with
  /// a short glide (instant on first show, when a saved selection is restored,
  /// and under reduced motion). Only this row moves, never the page.
  void _revealSelected() {
    if (!mounted || !scroll.hasClients) return;
    final i = widget.categories.indexWhere((c) => c.selected);
    if (i < 0 || i >= _chipKeys.length) return;
    final key = widget.categories[i].key;
    if (key == _revealed) return;
    final box = _chipKeys[i].currentContext?.findRenderObject();
    // Not laid out (the screen is behind another page): try again next time.
    if (box is! RenderBox || !box.attached || !box.hasSize) return;
    if (!scroll.position.hasContentDimensions) return;
    _revealed = key;
    final instant = _first || MediaQuery.disableAnimationsOf(context);
    _first = false;
    scroll.position.ensureVisible(
      box,
      alignment: .5,
      duration: instant ? Duration.zero : const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    while (_chipKeys.length < widget.categories.length) {
      _chipKeys.add(GlobalKey());
    }
    return AnimatedBuilder(
      animation: scroll,
      builder: (context, child) {
        final pos = scroll.hasClients ? scroll.position : null;
        final canLeft = pos != null && pos.pixels > 4;
        final canRight =
            pos == null ||
            !pos.hasContentDimensions ||
            pos.pixels < pos.maxScrollExtent - 4;
        final rtl = Directionality.of(context) == TextDirection.rtl;
        final start = rtl ? canRight : canLeft, end = rtl ? canLeft : canRight;
        return ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (rect) => LinearGradient(
            colors: [
              start ? Colors.transparent : Colors.black,
              Colors.black,
              Colors.black,
              end ? Colors.transparent : Colors.black,
            ],
            stops: const [0, .06, .92, 1],
          ).createShader(rect),
          child: child,
        );
      },
      child: NotificationListener<ScrollMetricsNotification>(
        onNotification: (_) {
          // Edge fades follow the extents once they are known.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() {});
          });
          return false;
        },
        child: SingleChildScrollView(
          key: const Key('discover-chips'),
          controller: scroll,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: discoverPad),
          child: Row(
            children: [
              for (final (i, c) in widget.categories.indexed) ...[
                if (i > 0) const SizedBox(width: 8),
                KeyedSubtree(
                  key: _chipKeys[i],
                  child: _Chip(category: c, style: DiscoverStyle.of(context)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final DiscoveryCategory category;
  final DiscoverStyle style;
  const _Chip({required this.category, required this.style});

  @override
  Widget build(BuildContext context) {
    final c = category;
    final s = style;
    final t = s.t;
    return PressScale(
      key: c.key,
      onTap: c.onTap,
      semanticLabel: c.label,
      selected: c.selected,
      pressedScale: .96,
      minHeight: 48,
      child: Center(
        widthFactor: 1,
        heightFactor: 1,
        child: AnimatedContainer(
          duration: VibeMotion.duration(context),
          curve: Curves.easeOutCubic,
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: c.selected ? s.chipSelectedFill : s.chipFill,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: c.selected
                  ? t.lime.withValues(alpha: t.isDark ? .35 : .9)
                  : t.hairline.withValues(alpha: .5),
            ),
          ),
          child: Center(
            widthFactor: 1,
            child: clampedChrome(
              context,
              AnimatedDefaultTextStyle(
                duration: VibeMotion.duration(context),
                style: Theme.of(context).textTheme.labelLarge!.copyWith(
                  fontSize: 14,
                  fontWeight: c.selected ? FontWeight.w800 : FontWeight.w600,
                  color: c.selected ? s.chipSelectedInk : s.chipInk,
                ),
                child: Text(c.label, maxLines: 1),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

double discoverScaleOf(BuildContext context) =>
    math.max(1.0, MediaQuery.textScalerOf(context).scale(14) / 14);
