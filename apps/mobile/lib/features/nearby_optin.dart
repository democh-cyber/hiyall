import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api.dart' show ApiClient, Session;
import '../core/location_service.dart';
import '../core/location_sync.dart';
import '../core/state.dart';
import '../shared/chat_tokens.dart';

/// "Show me in Nearby" is off for everyone until they turn it on. Location is
/// read only here, after this explainer, and never on app start or resume.
///
/// Opens the explainer and, if the person agrees, switches Nearby on at the
/// server and shares an approximate area. Returns true when the person is now
/// visible with an area shared. A refused permission or a failed read leaves
/// Nearby on without an area (nothing is shown about them) and reports why in
/// [locationProblemProvider].
Future<bool> turnOnNearby(BuildContext context, WidgetRef ref) async {
  final session = ref.read(sessionProvider).asData?.value;
  if (session == null) return false;
  final api = ref.read(apiProvider);
  final problem = ref.read(locationProblemProvider.notifier);
  final locator = ref.read(locationServiceProvider);
  final account = ref.read(sessionProvider.notifier);
  var minor = false;
  try {
    minor = (await api.nearbyStatus(session)).minor;
  } catch (_) {
    // Unknown: show the stronger wording rather than the lighter one.
    minor = true;
  }
  if (!context.mounted) return false;
  final agreed = await showNearbyExplainer(context, minor: minor);
  if (agreed != true) return false;
  return shareNearby(
    api: api,
    session: session,
    account: account,
    locator: locator,
    setProblem: problem.set,
  );
}

/// What follows the person's yes, wherever they said it (the explainer sheet, or the onboarding step): switches
/// Nearby on at the server, reads the position once (the system permission prompt appears here and only here) and
/// shares an approximate area. True when the area was shared; a refused permission or a failed read leaves Nearby
/// on without an area and reports why through [setProblem].
Future<bool> shareNearby({
  required ApiClient api,
  required Session session,
  required SessionController account,
  required LocationService locator,
  required void Function(LocationProblem? problem) setProblem,
}) async {
  final epoch = account.accountEpoch;
  await api.showMeInNearby(session);
  try {
    final fix = await locator.current();
    await account.shareLocation(
      epoch,
      () => api.shareLocation(session, fix.latitude, fix.longitude),
    );
    setProblem(null);
    return true;
  } on LocationFailure catch (failure) {
    setProblem(failure.problem);
    return false;
  }
}

/// The explainer sheet. True when the person chose "Show me in Nearby".
Future<bool?> showNearbyExplainer(
  BuildContext context, {
  required bool minor,
}) => showModalBottomSheet<bool>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  builder: (_) => NearbyExplainer(minor: minor),
);

class NearbyExplainer extends StatelessWidget {
  final bool minor;
  const NearbyExplainer({super.key, required this.minor});

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: SingleChildScrollView(
            key: const Key('nearby-explainer'),
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: NearbyExplanation(minor: minor),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FilledButton(
                key: const Key('nearby-explainer-confirm'),
                style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Show me in Nearby'),
              ),
              const SizedBox(height: 8),
              TextButton(
                key: const Key('nearby-explainer-cancel'),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Not now'),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// What Nearby is and what it shares: the words of the explainer sheet and of the onboarding step "Find people
/// near you", one source. [title] false leaves the heading to the caller.
class NearbyExplanation extends StatelessWidget {
  final bool minor;
  final bool title;
  const NearbyExplanation({super.key, required this.minor, this.title = true});

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    Widget point(IconData icon, String title, String body) => Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 22, color: t.textSecondary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: t.text,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.4,
                    color: t.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title) ...[
          Text(
            'Show me in Nearby?',
            style: TextStyle(
              fontFamily: 'SpaceGrotesk',
              fontSize: 24,
              height: 1.2,
              fontWeight: FontWeight.w700,
              color: t.text,
            ),
          ),
          const SizedBox(height: 6),
        ],
        Text(
          'Nearby lists people close to you. To use it, you also show up in it.',
          style: TextStyle(fontSize: 15, height: 1.4, color: t.textSecondary),
        ),
        const SizedBox(height: 18),
        point(
          Icons.place_outlined,
          'What’s shared',
          minor
              ? 'Only a rough area, about 10 km wide, moved a little each day. Never your exact spot.'
              : 'Only a rough area, about 1 km wide, moved a little each day. Never your exact spot.',
        ),
        point(
          Icons.visibility_outlined,
          'Who can see it',
          minor
              ? 'Only other people under 18 who have turned Nearby on. They see a distance like “within 10 km”, never a map or a position.'
              : 'Only other people who have turned Nearby on. They see a distance like “within 5 km”, never a map or a position.',
        ),
        point(
          Icons.schedule_rounded,
          'How long',
          'Your area expires after 24 hours. Hiyall reads your location only when you turn Nearby on or tap to refresh, only while the app is open, never in the background. Signing out removes it when the app can reach our server; otherwise it is deleted within 7 days.',
        ),
        point(
          Icons.toggle_off_outlined,
          'How to stop',
          'Turn it off any time in Settings under “Show me in Nearby”. Your area is deleted right away.',
        ),
        if (minor)
          Container(
            key: const Key('nearby-explainer-minor'),
            margin: const EdgeInsets.only(bottom: 14),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: t.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: t.hairline),
            ),
            child: Text(
              'You’re under 18, so this is off unless you choose it. Only turn it on if you’re comfortable with people your age nearby knowing roughly how close you are. If something feels off, block and report the person, or tell someone you trust.',
              style: TextStyle(fontSize: 14, height: 1.45, color: t.text),
            ),
          ),
      ],
    );
  }
}

/// Shown in Discover's Nearby view while the person has not turned Nearby on.
class NearbyOptInCard extends ConsumerWidget {
  final Future<void> Function() onEnable;
  const NearbyOptInCard({super.key, required this.onEnable});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ChatTokens.of(context);
    return Padding(
      key: const Key('nearby-optin'),
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Nearby is off',
            style: TextStyle(
              fontFamily: 'SpaceGrotesk',
              fontSize: 22,
              height: 1.2,
              fontWeight: FontWeight.w700,
              letterSpacing: -.5,
              color: t.text,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'To see people near you, you also show up for them, with a rough area and never your exact spot. You decide, and you can stop any time.',
            style: TextStyle(
              fontSize: 14.5,
              height: 1.4,
              color: t.textSecondary,
            ),
          ),
          const SizedBox(height: 14),
          FilledButton(
            key: const Key('nearby-optin-button'),
            style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: onEnable,
            child: const Text('Show me in Nearby'),
          ),
        ],
      ),
    );
  }
}
