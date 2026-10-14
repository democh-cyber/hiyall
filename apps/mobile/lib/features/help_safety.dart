import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/app_info.dart';
import '../core/legal_documents.dart';
import '../shared/widgets.dart';
import 'legal_screens.dart' show openLegal;

/// Contact addresses, set per build (`--dart-define=SUPPORT_EMAIL=...`). The
/// defaults are placeholders that end in `.example`; the release script
/// refuses to build with them for production.
abstract final class HelpContacts {
  static const support = String.fromEnvironment(
    'SUPPORT_EMAIL',
    defaultValue: 'support@hiyall.example',
  );
  static const safety = String.fromEnvironment(
    'SAFETY_EMAIL',
    defaultValue: 'safety@hiyall.example',
  );
  static const privacy = String.fromEnvironment(
    'PRIVACY_EMAIL',
    defaultValue: 'privacy@hiyall.example',
  );
  static bool isPlaceholder(String address) => address.endsWith('.example');
}

/// Help lines for someone in distress. A starting list: confirm every number
/// for the countries you launch in before release (docs/mobile/store-listing.md).
const crisisResources = <(String, String)>[
  (
    'Emergency services',
    'Call your local emergency number (911, 999, 112, 000).',
  ),
  ('United States', '988 Suicide & Crisis Lifeline: call or text 988.'),
  ('United Kingdom', 'Samaritans: 116 123. Childline (under 19): 0800 1111.'),
  (
    'Canada',
    'Talk Suicide Canada: 1-833-456-4566. Kids Help Phone: text 686868.',
  ),
  ('Australia', 'Lifeline: 13 11 14. Kids Helpline: 1800 55 1800.'),
  ('India', 'Tele-MANAS: 14416.'),
  ('Anywhere else', 'Find a helpline for your country at findahelpline.com.'),
];

const safetyTips = <(IconData, String, String)>[
  (
    Icons.lock_outline_rounded,
    'Keep it in Hiyall at first',
    'Don’t share your phone number, address, school or where you hang out with someone you just met.',
  ),
  (
    Icons.person_search_outlined,
    'People can pretend',
    'Someone may not be who they say. If it feels off, trust that feeling.',
  ),
  (
    Icons.photo_camera_back_outlined,
    'Think before you send a photo',
    'A photo can be saved or shared by the person who gets it, even in an encrypted chat.',
  ),
  (
    Icons.groups_outlined,
    'Meeting in person',
    'If you ever do, tell a parent or a friend, pick a busy public place and bring someone along. Under 18, check with a parent or guardian first.',
  ),
  (
    Icons.pause_circle_outline_rounded,
    'You can always stop',
    'Leave a chat, block or report. You never owe anyone a reply.',
  ),
];

/// Opens a mail draft. Replaced in tests, which have no mail app.
@visibleForTesting
Future<bool> Function(Uri uri) mailLauncher = (uri) => launchUrl(uri);

/// Opens a mail draft, or copies the address when no mail app answers.
Future<void> writeTo(
  BuildContext context,
  String address,
  String subject,
) async {
  final uri = Uri(
    scheme: 'mailto',
    path: address,
    queryParameters: {'subject': '$subject (Hiyall ${AppInfo.display})'},
  );
  var opened = false;
  try {
    opened = await mailLauncher(uri);
  } catch (_) {}
  if (opened || !context.mounted) return;
  await Clipboard.setData(ClipboardData(text: address));
  if (context.mounted) {
    showMessage(context, 'No mail app here. Copied $address instead.');
  }
}

class _Section extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _Section(this.title, this.children);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 22),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Semantics(
            header: true,
            child: Text(
              title.toUpperCase(),
              style: TextStyle(
                fontSize: 12,
                letterSpacing: 1.2,
                fontWeight: FontWeight.w800,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        VibePanel(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(children: children),
        ),
      ],
    ),
  );
}

class _ContactTile extends StatelessWidget {
  final IconData icon;
  final String title, address, subject;
  const _ContactTile(this.icon, this.title, this.address, this.subject);
  @override
  Widget build(BuildContext context) => ListTile(
    key: Key('help-contact-$title'),
    minTileHeight: 64,
    leading: Icon(icon),
    title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
    subtitle: SelectableText(address),
    trailing: IconButton(
      tooltip: 'Copy $address',
      icon: const Icon(Icons.copy_rounded),
      onPressed: () async {
        await Clipboard.setData(ClipboardData(text: address));
        if (context.mounted) showMessage(context, 'Copied $address');
      },
    ),
    onTap: () => writeTo(context, address, subject),
  );
}

/// Settings → Help & Safety: how to reach a person, how to stay safe, how to
/// block and report, and where to get urgent help.
class HelpSafetyScreen extends ConsumerWidget {
  const HelpSafetyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(color: scheme.onSurfaceVariant, height: 1.5);
    return ReadingWidth(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 48),
        children: [
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: () => context.canPop()
                  ? context.pop()
                  : context.go('/profile/settings'),
              icon: const Icon(Icons.arrow_back),
              label: const Text('Back'),
            ),
          ),
          Semantics(
            header: true,
            child: Text(
              'Help & Safety',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'A real person reads what you send. Tap an address to write to us, or copy it.',
            style: muted,
          ),
          _Section('Contact us', [
            const _ContactTile(
              Icons.mail_outline_rounded,
              'Help and feedback',
              HelpContacts.support,
              'Help',
            ),
            const _ContactTile(
              Icons.shield_outlined,
              'Safety concerns',
              HelpContacts.safety,
              'Safety',
            ),
            const _ContactTile(
              Icons.privacy_tip_outlined,
              'Privacy and your data',
              HelpContacts.privacy,
              'Privacy',
            ),
          ]),
          _Section('Staying safe', [
            for (final (icon, title, body) in safetyTips)
              ListTile(
                leading: Icon(icon),
                title: Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(body),
              ),
          ]),
          _Section('Block or report someone', [
            const ListTile(
              leading: Icon(Icons.block_rounded),
              title: Text(
                'Block',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                'Open their profile or chat, tap the three dots, then Block. They can’t message you or see you.',
              ),
            ),
            const ListTile(
              leading: Icon(Icons.flag_outlined),
              title: Text(
                'Report',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                'From the same menu, tap Report and pick a reason. They never see who reported them.',
              ),
            ),
            ListTile(
              key: const Key('help-your-reports'),
              leading: const Icon(Icons.history_rounded),
              title: const Text(
                'Your reports',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: const Text('See what happened to reports you sent'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => context.go('/profile/reports'),
            ),
          ]),
          _Section('If you need urgent help', [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Text(
                'If you or someone else is in danger, contact local emergency services first. Hiyall can’t send help.',
                style: muted,
              ),
            ),
            for (final (place, line) in crisisResources)
              ListTile(
                dense: true,
                title: Text(
                  place,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: SelectableText(line),
              ),
          ]),
          _Section('Our rules', [
            for (final doc in const [
              LegalDoc.guidelines,
              LegalDoc.teens,
              LegalDoc.privacy,
              LegalDoc.terms,
            ])
              ListTile(
                key: Key('help-legal-${doc.name}'),
                minTileHeight: 56,
                title: Text(
                  doc.title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => openLegal(context, doc),
              ),
          ]),
        ],
      ),
    );
  }
}

/// The Settings group that leads here, plus the open-source licence page.
/// Settings holds one line for it: `const HelpSettingsGroup()`.
class HelpSettingsGroup extends StatelessWidget {
  const HelpSettingsGroup({super.key});
  @override
  Widget build(BuildContext context) => _Section('Help', [
    ListTile(
      key: const Key('settings-help'),
      minTileHeight: 56,
      leading: const Icon(Icons.support_agent_rounded),
      title: const Text(
        'Help & Safety',
        style: TextStyle(fontWeight: FontWeight.w700),
      ),
      subtitle: const Text('Contact us, safety tips, block and report'),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => context.push('/profile/help'),
    ),
    ListTile(
      key: const Key('settings-licences'),
      minTileHeight: 56,
      leading: const Icon(Icons.code_rounded),
      title: const Text(
        'Open-source licences',
        style: TextStyle(fontWeight: FontWeight.w700),
      ),
      subtitle: const Text('Software and fonts Hiyall is built with'),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => showLicensePage(
        context: context,
        applicationName: 'Hiyall',
        applicationVersion: AppInfo.display,
        applicationIcon: const Padding(
          padding: EdgeInsets.all(12),
          child: BrandMark(),
        ),
      ),
    ),
  ]);
}
