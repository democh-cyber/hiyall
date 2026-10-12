import 'package:flutter/gestures.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/material.dart';

/// A tappable surface with the app's press feedback: no grey ink splash or
/// hover pill, a small scale while pressed, and a thin ring around it for
/// keyboard focus only (never after a mouse click or a tap, like CSS
/// `:focus-visible`). The same pattern as the story bubbles, as a reusable piece.
class PressScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Extra actions for TalkBack and VoiceOver (the "Actions" menu), for what a
  /// long press does. Only used when a [semanticLabel] or [semanticHint] is set.
  final Map<CustomSemanticsAction, VoidCallback>? semanticActions;

  /// Shapes the focus ring and the hit area; match the child's corners.
  final BorderRadius borderRadius;

  /// Read out by screen readers. Leave null to let the child describe itself.
  final String? semanticLabel;
  final String? semanticHint;

  /// Announced as selected or not; leave null for controls with no such state.
  final bool? selected;
  final double pressedScale;

  /// Keeps controls at least this tall, so a small pill is still easy to hit.
  final double minHeight;

  /// A surface tint behind the child while it is pressed (and, softer, while a
  /// pointer hovers it). Null keeps the stock look: no fill at all.
  final Color? highlight;
  const PressScale({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.semanticActions,
    this.borderRadius = const BorderRadius.all(Radius.circular(100)),
    this.semanticLabel,
    this.semanticHint,
    this.selected,
    this.pressedScale = .96,
    this.minHeight = 0,
    this.highlight,
  });
  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool _pressed = false, _focused = false, _hovered = false;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addHighlightModeListener(_modeChanged);
  }

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_modeChanged);
    super.dispose();
  }

  /// A key press switches the app to "traditional" highlighting, a pointer or
  /// touch back to "touch"; the ring follows it while the control has focus.
  void _modeChanged(FocusHighlightMode mode) {
    if (mounted && _focused) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final ringShown =
        _focused &&
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    final ring = Theme.of(context).colorScheme.onSurface;
    final enabled = widget.onTap != null || widget.onLongPress != null;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 90);
    Widget body = InkWell(
      // The stock hover and press highlight is a grey slab behind the card.
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      splashFactory: NoSplash.splashFactory,
      // The hand on the web and desktop, whatever the platform default is.
      mouseCursor: enabled
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      borderRadius: widget.borderRadius,
      onHighlightChanged: (v) => setState(() => _pressed = v),
      onFocusChange: (v) => setState(() => _focused = v),
      onHover: widget.highlight == null
          ? null
          : (v) => setState(() => _hovered = v),
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: AnimatedScale(
        scale: _pressed ? widget.pressedScale : 1,
        duration: duration,
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            borderRadius: widget.borderRadius,
            border: Border.all(
              color: ringShown ? ring : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: widget.highlight == null
              ? widget.child
              : AnimatedContainer(
                  duration: duration,
                  decoration: BoxDecoration(
                    borderRadius: widget.borderRadius,
                    color: _pressed
                        ? widget.highlight
                        : _hovered
                        ? widget.highlight!.withValues(
                            alpha: widget.highlight!.a * .5,
                          )
                        : Colors.transparent,
                  ),
                  child: widget.child,
                ),
        ),
      ),
    );
    if (widget.minHeight > 0) {
      body = ConstrainedBox(
        constraints: BoxConstraints(minHeight: widget.minHeight),
        child: body,
      );
    }
    if (widget.semanticLabel == null && widget.semanticHint == null) {
      return body;
    }
    return Semantics(
      button: true,
      enabled: enabled,
      selected: widget.selected,
      label: widget.semanticLabel,
      hint: widget.semanticHint,
      customSemanticsActions: widget.semanticActions,
      excludeSemantics: widget.semanticLabel != null,
      child: body,
    );
  }
}

/// Fades and lifts a section in once. [index] staggers neighbours by 50 ms,
/// capped so the whole page has settled within 400 ms. Does nothing when the
/// device asks for reduced motion.
class StaggerIn extends StatelessWidget {
  final int index;
  final Widget child;
  const StaggerIn({super.key, required this.index, required this.child});

  static const _step = 50, _base = 220, _maxDelay = 180;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    final delay = (index * _step).clamp(0, _maxDelay);
    final total = _base + delay;
    return TweenAnimationBuilder<double>(
      duration: Duration(milliseconds: total),
      curve: Interval(delay / total, 1, curve: Curves.easeOutCubic),
      tween: Tween(begin: 0, end: 1),
      builder: (context, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(
          offset: Offset(0, 14 * (1 - v)),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

/// A horizontal row of equal cards that settles on a card edge after a flick.
/// The leading and trailing space is [gutter]; every card is [cardWidth] wide
/// (or the row's width, if that is narrower) with [gap] after it.
class SnapRow extends StatelessWidget {
  final int count;
  final double height, cardWidth, gap, gutter;
  final IndexedWidgetBuilder itemBuilder;
  const SnapRow({
    super.key,
    required this.count,
    required this.height,
    required this.itemBuilder,
    this.cardWidth = 284,
    this.gap = 12,
    this.gutter = 16,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: LayoutBuilder(
      builder: (context, box) {
        final width = (cardWidth).clamp(0.0, box.maxWidth - gutter * 2);
        return ScrollConfiguration(
          behavior: const DragAnywhereBehavior(),
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            padding: EdgeInsets.symmetric(horizontal: gutter),
            itemCount: count,
            itemExtent: width + gap,
            physics: SnapPhysics(width + gap),
            itemBuilder: (context, i) => Padding(
              padding: EdgeInsets.only(right: gap),
              child: itemBuilder(context, i),
            ),
          ),
        );
      },
    ),
  );
}

/// Lets a mouse or trackpad drag a horizontal row on the web and desktop, where
/// the default behaviour only scrolls it with the wheel.
class DragAnywhereBehavior extends MaterialScrollBehavior {
  const DragAnywhereBehavior();
  @override
  Set<PointerDeviceKind> get dragDevices => PointerDeviceKind.values.toSet();
}

/// Settles on a multiple of [extent], like a page view without the page size.
class SnapPhysics extends ScrollPhysics {
  final double extent;
  const SnapPhysics(this.extent, {super.parent});

  @override
  SnapPhysics applyTo(ScrollPhysics? ancestor) =>
      SnapPhysics(extent, parent: buildParent(ancestor));

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    if ((velocity <= 0 && position.pixels <= position.minScrollExtent) ||
        (velocity >= 0 && position.pixels >= position.maxScrollExtent)) {
      return super.createBallisticSimulation(position, velocity);
    }
    final tol = toleranceFor(position);
    var page = position.pixels / extent;
    if (velocity < -tol.velocity) {
      page -= .5;
    } else if (velocity > tol.velocity) {
      page += .5;
    }
    final target = (page.roundToDouble() * extent).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if ((target - position.pixels).abs() < tol.distance) return null;
    return ScrollSpringSimulation(
      spring,
      position.pixels,
      target,
      velocity,
      tolerance: tol,
    );
  }

  @override
  bool get allowImplicitScrolling => false;
}
