import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// Fades a tab's slivers in when the tab changes (the old tab is replaced at
/// once). With [animate] false the tab simply appears, as on first load.
class SpaceTabFade extends StatefulWidget {
  final bool animate;
  final Widget sliver;
  const SpaceTabFade({super.key, required this.animate, required this.sliver});
  @override
  State<SpaceTabFade> createState() => _SpaceTabFadeState();
}

class _SpaceTabFadeState extends State<SpaceTabFade>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    value: widget.animate ? 0 : 1,
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    _c.duration = VibeMotion.duration(context);
    if (widget.animate) _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      SliverFadeTransition(opacity: _c, sliver: widget.sliver);
}
