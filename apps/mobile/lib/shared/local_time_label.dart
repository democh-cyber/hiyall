import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api.dart';
import '../core/local_time.dart';
import 'chat_tokens.dart';

/// "3:42 PM there" (compact, for a Discover row) or "It's 3:42 PM there · 3 hours ahead" (full, for a profile),
/// kept current by one timer that fires on the minute. The timer only runs while the widget is on screen: it is
/// off when the tab or route is covered ([TickerMode]) and when the app is in the background, and it restarts
/// with a fresh reading when it comes back. The member's offset comes from the server (see [LocalTimeInfo]).
class LocalTimeLabel extends ConsumerStatefulWidget {
  final LocalTimeInfo time;

  /// The long form for a profile; the compact form for a row.
  final bool full;
  const LocalTimeLabel({super.key, required this.time, this.full = false});

  @override
  ConsumerState<LocalTimeLabel> createState() => _LocalTimeLabelState();
}

class _LocalTimeLabelState extends ConsumerState<LocalTimeLabel>
    with WidgetsBindingObserver {
  Timer? _timer;
  bool _resumed = true;
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    _sync();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _visible = TickerMode.valuesOf(context).enabled;
    _sync();
  }

  /// Runs the timer exactly when the label can be seen.
  void _sync() {
    if (_visible && _resumed) {
      if (_timer == null) {
        setState(() {}); // a fresh reading after being away
        _schedule();
      }
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _schedule() {
    final now = ref.read(localTimeClockProvider)();
    _timer = Timer(untilNextMinute(now) + const Duration(milliseconds: 50), () {
      _timer = null;
      if (!mounted) return;
      setState(() {});
      if (_visible && _resumed) _schedule();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Whether a timer is running (for tests).
  @visibleForTesting
  bool get ticking => _timer != null;

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final now = ref.read(localTimeClockProvider)();
    final use24 = MediaQuery.alwaysUse24HourFormatOf(context);
    final clock = formatLocalTime(widget.time, now, use24Hour: use24);
    final difference = localTimeDifference(widget.time, now);
    final visible = widget.full
        ? 'It’s $clock there${difference == null ? '' : ' · $difference'}'
        : '$clock there';
    return Semantics(
      container: true,
      label: 'Local time there: $clock, ${widget.time.label}',
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.schedule_rounded, size: 14, color: t.textTertiary),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                visible,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: widget.full ? 13.5 : 12.5,
                  height: 1.3,
                  color: t.textTertiary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
