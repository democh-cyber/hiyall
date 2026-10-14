import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/app_info.dart';
import '../core/legal_documents.dart';
import '../l10n/l10n.dart';
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
    showMessage(context, context.l10n.helpNoMailApp(address));
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
          padding: const EdgeInsetsDirectional.only(start: 4, bottom: 8),
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

  /// Names the row's key (`help-contact-<keyName>`); not shown, so it does not
  /// change with the language.
  final String keyName;
  final String title, address, subject;
  const _ContactTile(
    this.icon,
    this.keyName,
    this.title,
    this.address,
    this.subject,
  );
  @override
  Widget build(BuildContext context) => ListTile(
    key: Key('help-contact-$keyName'),
    minTileHeight: 64,
    leading: Icon(icon),
    title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
    subtitle: SelectableText(address),
    trailing: IconButton(
      tooltip: context.l10n.helpCopyTooltip(address),
      icon: const Icon(Icons.copy_rounded),
      onPressed: () async {
        await Clipboard.setData(ClipboardData(text: address));
        if (context.mounted) {
          showMessage(context, context.l10n.helpCopied(address));
        }
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
    final l10n = context.l10n;
    final muted = _mutedStyle(context);
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
              label: Text(l10n.helpBack),
            ),
          ),
          Semantics(
            header: true,
            child: Text(
              l10n.helpTitle,
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          ),
          const SizedBox(height: 6),
          Text(l10n.helpIntro, style: muted),
          const _ContactSection(),
          const _SafetyTipsSection(),
          const _BlockReportSection(),
          const _UrgentHelpSection(),
          const _RulesSection(),
        ],
      ),
    );
  }
}

TextStyle _mutedStyle(BuildContext context) => TextStyle(
  color: Theme.of(context).colorScheme.onSurfaceVariant,
  height: 1.5,
);

const _bold = TextStyle(fontWeight: FontWeight.w700);

class _ContactSection extends StatelessWidget {
  const _ContactSection();
  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return _Section(l10n.helpSectionContact, [
      _ContactTile(
        Icons.mail_outline_rounded,
        'Help and feedback',
        l10n.helpContactHelp,
        HelpContacts.support,
        l10n.helpMailSubjectHelp,
      ),
      _ContactTile(
        Icons.shield_outlined,
        'Safety concerns',
        l10n.helpContactSafety,
        HelpContacts.safety,
        l10n.helpMailSubjectSafety,
      ),
      _ContactTile(
        Icons.privacy_tip_outlined,
        'Privacy and your data',
        l10n.helpContactPrivacy,
        HelpContacts.privacy,
        l10n.helpMailSubjectPrivacy,
      ),
    ]);
  }
}

class _SafetyTipsSection extends StatelessWidget {
  const _SafetyTipsSection();
  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final tips = <(IconData, String, String)>[
      (
        Icons.lock_outline_rounded,
        l10n.helpTipKeepInHiyallTitle,
        l10n.helpTipKeepInHiyallBody,
      ),
      (
        Icons.person_search_outlined,
        l10n.helpTipPeopleTitle,
        l10n.helpTipPeopleBody,
      ),
      (
        Icons.photo_camera_back_outlined,
        l10n.helpTipPhotoTitle,
        l10n.helpTipPhotoBody,
      ),
      (
        Icons.groups_outlined,
        l10n.helpTipMeetingTitle,
        l10n.helpTipMeetingBody,
      ),
      (
        Icons.pause_circle_outline_rounded,
        l10n.helpTipStopTitle,
        l10n.helpTipStopBody,
      ),
    ];
    return _Section(l10n.helpSectionStayingSafe, [
      for (final (icon, title, body) in tips)
        ListTile(
          leading: Icon(icon),
          title: Text(title, style: _bold),
          subtitle: Text(body),
        ),
    ]);
  }
}

class _BlockReportSection extends StatelessWidget {
  const _BlockReportSection();
  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return _Section(l10n.helpSectionBlockReport, [
      ListTile(
        leading: const Icon(Icons.block_rounded),
        title: Text(l10n.helpBlockTitle, style: _bold),
        subtitle: Text(l10n.helpBlockBody),
      ),
      ListTile(
        leading: const Icon(Icons.flag_outlined),
        title: Text(l10n.helpReportTitle, style: _bold),
        subtitle: Text(l10n.helpReportBody),
      ),
      ListTile(
        key: const Key('help-your-reports'),
        leading: const Icon(Icons.history_rounded),
        title: Text(l10n.helpYourReportsTitle, style: _bold),
        subtitle: Text(l10n.helpYourReportsBody),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () => context.go('/profile/reports'),
      ),
    ]);
  }
}

/// Help lines for someone in distress. A starting list: confirm every number
/// for the countries you launch in before release (docs/mobile/store-listing.md).
class _UrgentHelpSection extends StatelessWidget {
  const _UrgentHelpSection();
  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final resources = <(String, String)>[
      (l10n.helpCrisisEmergencyPlace, l10n.helpCrisisEmergencyLine),
      (l10n.helpCrisisUSPlace, l10n.helpCrisisUSLine),
      (l10n.helpCrisisUKPlace, l10n.helpCrisisUKLine),
      (l10n.helpCrisisCAPlace, l10n.helpCrisisCALine),
      (l10n.helpCrisisAUPlace, l10n.helpCrisisAULine),
      (l10n.helpCrisisINPlace, l10n.helpCrisisINLine),
      (l10n.helpCrisisElsePlace, l10n.helpCrisisElseLine),
    ];
    return _Section(l10n.helpSectionUrgent, [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Text(l10n.helpUrgentIntro, style: _mutedStyle(context)),
      ),
      for (final (place, line) in resources)
        ListTile(
          dense: true,
          title: Text(place, style: _bold),
          subtitle: SelectableText(line),
        ),
    ]);
  }
}

class _RulesSection extends StatelessWidget {
  const _RulesSection();
  @override
  Widget build(BuildContext context) =>
      _Section(context.l10n.helpSectionRules, [
        for (final doc in const [
          LegalDoc.guidelines,
          LegalDoc.teens,
          LegalDoc.privacy,
          LegalDoc.terms,
        ])
          ListTile(
            key: Key('help-legal-${doc.name}'),
            minTileHeight: 56,
            title: Text(doc.title, style: _bold),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => openLegal(context, doc),
          ),
      ]);
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
