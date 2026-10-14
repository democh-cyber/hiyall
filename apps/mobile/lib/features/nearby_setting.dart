import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api.dart';
import '../core/state.dart';
import '../core/user_error.dart';
import '../shared/widgets.dart';
import 'nearby_optin.dart';

/// The member's Nearby switch, read from the server. Not cached across
/// accounts: it is re-read when the session changes.
final nearbyStatusProvider = FutureProvider.autoDispose<NearbyStatus>((ref) {
  final session = ref.watch(sessionProvider).asData?.value;
  if (session == null) return const NearbyStatus();
  return ref.watch(apiProvider).nearbyStatus(session);
});

/// Settings group with the "Show me in Nearby" switch. Off by default.
/// Switching it on shows the explainer first; switching it off deletes the
/// shared area on the server at once.
class NearbySettingsGroup extends ConsumerStatefulWidget {
  const NearbySettingsGroup({super.key});
  @override
  ConsumerState<NearbySettingsGroup> createState() => _NearbySettingsState();
}

class _NearbySettingsState extends ConsumerState<NearbySettingsGroup> {
  bool busy = false;
  bool? pending;

  Future<void> change(bool on) async {
    final session = ref.read(sessionProvider).asData?.value;
    if (session == null || busy) return;
    final container = ProviderScope.containerOf(context, listen: false);
    setState(() {
      busy = true;
      pending = on;
    });
    try {
      if (on) {
        await turnOnNearby(context, ref);
      } else {
        await container.read(apiProvider).hideFromNearby(session);
      }
    } catch (e) {
      if (mounted) showFailure(context, e);
    } finally {
      container.invalidate(nearbyStatusProvider);
      if (mounted) {
        setState(() {
          busy = false;
          pending = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(nearbyStatusProvider);
    final on = pending ?? status.asData?.value.visible ?? false;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              'NEARBY',
              style: TextStyle(
                fontSize: 12,
                letterSpacing: 1.2,
                fontWeight: FontWeight.w800,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          VibePanel(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: SwitchListTile(
              key: const Key('nearby-toggle'),
              secondary: const Icon(Icons.place_outlined),
              title: const Text(
                'Show me in Nearby',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                status.hasError
                    ? 'Couldn’t load this setting.'
                    : on
                    ? 'People who also use Nearby can see you’re within a few km. Turn off to delete your area.'
                    : 'Off. Nobody sees where you are, and Nearby stays closed to you.',
              ),
              value: on,
              onChanged: status.hasValue && !busy ? change : null,
            ),
          ),
        ],
      ),
    );
  }
}
