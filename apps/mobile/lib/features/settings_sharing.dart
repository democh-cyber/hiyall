import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api.dart';
import '../core/state.dart';
import '../core/user_error.dart';
import '../shared/widgets.dart';
import 'nearby_setting.dart' show nearbyStatusProvider;
import 'profile_editor/audience_picker.dart';

/// What the member shows about themselves beyond the profile fields: their local time, their distance in Nearby,
/// who visited their profile and their birthday, and the way into their own visit history. Each is its own switch
/// on the privacy settings (`showLocalTime`, `showDistance`, `visitorsVisibleToOthers`, `showBirthday`).
///
/// Sharing who visited and the birthday are for adults only: for a member under 18 they are off, disabled and
/// say why, and the server refuses to turn them on (422 MINOR_SETTING_LOCKED) whatever a client sends.
class ProfileSharingSettingsGroup extends ConsumerStatefulWidget {
  const ProfileSharingSettingsGroup({super.key});
  @override
  ConsumerState<ProfileSharingSettingsGroup> createState() =>
      _ProfileSharingState();
}

class _ProfileSharingState extends ConsumerState<ProfileSharingSettingsGroup> {
  /// What is being saved, by setting, so the switch shows the new value at once.
  final pending = <String, bool>{};
  bool busy = false;

  Future<void> change(Privacy current, Map<String, dynamic> patch) async {
    final session = ref.read(sessionProvider).asData?.value;
    if (session == null || busy) return;
    // Held past the awaits: the tile may be gone when the answer arrives.
    final container = ProviderScope.containerOf(context, listen: false);
    setState(() {
      busy = true;
      for (final e in patch.entries) {
        if (e.value is bool) pending[e.key] = e.value as bool;
      }
    });
    try {
      await container.read(apiProvider).updatePrivacy(session, current, patch);
      container.invalidate(privacyProvider);
      await container.read(privacyProvider.future);
    } catch (e) {
      // Re-read the settings: another device may have changed them, and the switch must show what is saved.
      container.invalidate(privacyProvider);
      if (mounted) showFailure(context, e);
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          pending.clear();
        });
      }
    }
  }

  Widget toggle(
    Privacy? current,
    String key, {
    required IconData icon,
    required String title,
    required String subtitle,
    bool enabled = true,
  }) {
    final on = pending[key] ?? (current?.values[key] == true);
    return SwitchListTile(
      key: Key('sharing-$key'),
      secondary: Icon(icon),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(subtitle),
      value: enabled && on,
      onChanged: current == null || busy || !enabled
          ? null
          : (v) => change(current, {key: v}),
    );
  }

  @override
  Widget build(BuildContext context) {
    final privacy = ref.watch(privacyProvider);
    final current = privacy.asData?.value;
    final minor = ref.watch(nearbyStatusProvider).asData?.value.minor ?? false;
    final scheme = Theme.of(context).colorScheme;
    final audiences =
        current?.values['fieldAudiences'] as Map<String, dynamic>? ?? const {};
    final birthdayAudience =
        (audiences['birthday'] as String?) ?? (minor ? 'nobody' : 'friends');
    final birthdayOn =
        !minor &&
        (pending['showBirthday'] ?? current?.values['showBirthday'] == true);
    const adultsOnly = 'Not available for members under 18.';
    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: Column(
        key: const Key('sharing-group'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 4, bottom: 8),
            child: Text(
              'WHAT YOU SHOW',
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
            child: Column(
              children: [
                if (privacy.hasError)
                  const ListTile(title: Text('Couldn’t load these settings.')),
                toggle(
                  current,
                  'showLocalTime',
                  icon: Icons.schedule_rounded,
                  title: 'Show my local time',
                  subtitle: 'Profiles and Discover can say what time it is for you. Only the time, never where you are.',
                ),
                toggle(
                  current,
                  'showDistance',
                  icon: Icons.near_me_outlined,
                  title: 'Show my distance in Nearby',
                  subtitle: 'People who find you in Nearby see a rough distance. Off hides it; you still show up if Nearby is on.',
                ),
                toggle(
                  current,
                  'visitorsVisibleToOthers',
                  icon: Icons.visibility_outlined,
                  title: 'Let people see who visited me',
                  subtitle: minor ? adultsOnly : 'People who can open your profile see who visited it in the last 30 days. You always have your own visitors list.',
                  enabled: !minor,
                ),
                toggle(
                  current,
                  'showBirthday',
                  icon: Icons.cake_outlined,
                  title: 'Show my birthday',
                  subtitle: minor ? adultsOnly : 'Month and day only, never the year. If you also show your age, people can work out your birth date.',
                  enabled: !minor,
                ),
                if (birthdayOn && current != null)
                  Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(72, 0, 16, 8),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: AudienceRow(
                        key: const Key('sharing-birthday-audience'),
                        subject: 'your birthday',
                        value: birthdayAudience,
                        options: audienceOptions(minor: false),
                        enabled: !busy,
                        onChanged: (v) => change(current, {
                          'fieldAudiences': {'birthday': v},
                        }),
                      ),
                    ),
                  ),
                ListTile(
                  key: const Key('settings-/profile/places'),
                  leading: const Icon(Icons.history_rounded),
                  title: const Text(
                    'Places I’ve visited',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: const Text(
                    'Profiles you opened in the last 30 days. Only you can see this.',
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => context.go('/profile/places'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
