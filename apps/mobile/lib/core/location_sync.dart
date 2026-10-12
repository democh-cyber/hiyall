import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'location_service.dart';
import 'state.dart';

/// Why the last position read failed, so Discover can explain an empty
/// "My surroundings" list. Null when the position was read or not yet tried.
final locationProblemProvider =
    NotifierProvider<LocationProblemState, LocationProblem?>(
      LocationProblemState.new,
    );

class LocationProblemState extends Notifier<LocationProblem?> {
  @override
  LocationProblem? build() => null;
  void set(LocationProblem? problem) => state = problem;
}

/// Reads the device's approximate position whenever the app opens or returns to
/// the foreground and sends it to the server. There is deliberately no switch:
/// the operating system's permission prompt is the only control, and signing
/// out stops the sharing. Failures are silent; the previous position (valid
/// for a day) keeps working.
class LocationSync extends ConsumerStatefulWidget {
  final Widget child;

  /// The shortest time between two reads. The server accepts a few updates and
  /// then one per two minutes, and refreshing faster gains nothing at a ~1 km
  /// grid.
  final Duration interval;
  const LocationSync({
    super.key,
    required this.child,
    this.interval = const Duration(minutes: 5),
  });
  @override
  ConsumerState<LocationSync> createState() => _LocationSyncState();
}

class _LocationSyncState extends ConsumerState<LocationSync>
    with WidgetsBindingObserver {
  DateTime? _last;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refresh();
  }

  Future<void> refresh() async {
    final session = ref.read(sessionProvider).asData?.value;
    if (!mounted || session == null || !session.onboarded || _busy) return;
    final now = DateTime.now();
    if (_last != null && now.difference(_last!) < widget.interval) return;
    _busy = true;
    _last = now;
    final account = ref.read(sessionProvider.notifier);
    final epoch = account.accountEpoch;
    final api = ref.read(apiProvider);
    try {
      final fix = await ref.read(locationServiceProvider).current();
      // Skipped if the person signed out while the position was being read.
      await account.shareLocation(
        epoch,
        () => api.shareLocation(session, fix.latitude, fix.longitude),
      );
      if (mounted) ref.read(locationProblemProvider.notifier).set(null);
    } on LocationFailure catch (failure) {
      if (mounted) {
        ref.read(locationProblemProvider.notifier).set(failure.problem);
      }
    } catch (_) {
      // Offline, rate-limited or no location plugin (tests): try again later.
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    // A new session (sign-in, or onboarding just finished) reads it at once.
    ref.listen(sessionProvider, (previous, next) {
      final was = previous?.asData?.value;
      final now = next.asData?.value;
      if (now != null && (was == null || was.onboarded != now.onboarded)) {
        _last = null;
        refresh();
      }
    });
    return widget.child;
  }
}
