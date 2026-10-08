import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api.dart';
import '../core/state.dart';
import '../shared/widgets.dart';

class PrivacyScreen extends ConsumerWidget {
  const PrivacyScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => ReadingWidth(
    child: ref
        .watch(privacyProvider)
        .when(
          data: (p) => PrivacyForm(key: ValueKey(p.version), privacy: p),
          loading: () => const VibeLoading(),
          error: (e, s) => FailureCard(
            error: e,
            retry: () => ref.invalidate(privacyProvider),
          ),
        ),
  );
}

class PrivacyForm extends ConsumerStatefulWidget {
  final Privacy privacy;
  const PrivacyForm({super.key, required this.privacy});
  @override
  ConsumerState<PrivacyForm> createState() => _PrivacyFormState();
}

class _PrivacyFormState extends ConsumerState<PrivacyForm> {
  late final draft = Map<String, dynamic>.from(widget.privacy.values);
  late final fields = Map<String, dynamic>.from(
    widget.privacy.values['fieldAudiences'] as Map,
  );
  bool busy = false, dirty = false, conflict = false;
  String? error;
  void change(String key, dynamic value) => setState(() {
    draft[key] = value;
    dirty = true;
  });
  static const audiences = {
    'everyone': 'Everyone',
    'friends': 'Friends',
    'followers': 'Followers',
    'nobody': 'Only me',
  };
  Widget picker(String label, String key, Map<String, String> choices) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 18),
        child: DropdownButtonFormField<String>(
          initialValue: draft[key] as String,
          isExpanded: true,
          decoration: InputDecoration(labelText: label),
          items: choices.entries
              .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
              .toList(),
          onChanged: busy
              ? null
              : (value) {
                  if (value != null) change(key, value);
                },
        ),
      );
  Future<void> save() async {
    if (busy || !dirty || conflict) return;
    setState(() {
      busy = true;
      error = null;
    });
    final patch = <String, dynamic>{};
    for (final key in [
      'profileAudience',
      'messagesFrom',
      'followPolicy',
      'requestsFrom',
      'storyAudience',
      'activityAudience',
      'onlineAudience',
      'lastSeenAudience',
      'locationAudience',
      'commentsFrom',
      'mentionsFrom',
      'discoverable',
      'showInterestOverlap',
      'readReceipts',
    ]) {
      if (draft[key] != widget.privacy.values[key]) patch[key] = draft[key];
    }
    final fieldPatch = <String, dynamic>{};
    final original = widget.privacy.values['fieldAudiences'] as Map;
    for (final key in fields.keys) {
      if (fields[key] != original[key]) fieldPatch[key] = fields[key];
    }
    if (fieldPatch.isNotEmpty) patch['fieldAudiences'] = fieldPatch;
    if (patch.isEmpty) {
      setState(() {
        busy = false;
        dirty = false;
      });
      return;
    }
    try {
      await ref
          .read(apiProvider)
          .updatePrivacy(
            ref.read(sessionProvider).asData!.value!,
            widget.privacy,
            patch,
          );
      ref.invalidate(privacyProvider);
      ref.invalidate(profileProvider);
      if (mounted) showMessage(context, 'Privacy settings saved.');
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e.toString();
          conflict = e is ApiFailure && e.status == 412;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void discard() => setState(() {
    draft
      ..clear()
      ..addAll(widget.privacy.values);
    fields
      ..clear()
      ..addAll(
        Map<String, dynamic>.from(
          widget.privacy.values['fieldAudiences'] as Map,
        ),
      );
    dirty = false;
    error = null;
  });

  Widget toggle(String key, String title, String subtitle) => SwitchListTile(
    key: Key('privacy-$key'),
    contentPadding: EdgeInsets.zero,
    title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
    subtitle: Text(subtitle),
    value: draft[key] as bool,
    onChanged: busy ? null : (value) => change(key, value),
  );

  Widget fieldPicker(String key, String label) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: DropdownButtonFormField<String>(
      initialValue: fields[key] as String? ?? 'nobody',
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: audiences.entries
          .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
          .toList(),
      onChanged: busy
          ? null
          : (value) {
              if (value != null) {
                setState(() {
                  fields[key] = value;
                  dirty = true;
                });
              }
            },
    ),
  );

  static const profileAudiences = {
    'public': 'Public',
    'friends': 'Friends',
    'followers': 'Followers',
    'private': 'Only me',
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hiddenFromDiscover =
        draft['discoverable'] == true && draft['profileAudience'] != 'public';
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            children: [
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: busy
                      ? null
                      : () => context.go('/profile/settings'),
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('Settings'),
                ),
              ),
              Text(
                'Privacy',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 6),
              Text(
                'Choose who gets a window into your world. Nothing changes until you save.',
                style: TextStyle(color: scheme.onSurfaceVariant, height: 1.5),
              ),
              _Section(
                title: 'Your profile',
                children: [
                  picker(
                    'Who can view my profile?',
                    'profileAudience',
                    profileAudiences,
                  ),
                  Theme(
                    data: Theme.of(context)
                        .copyWith(dividerColor: Colors.transparent),
                    child: ExpansionTile(
                      key: const Key('privacy-fields'),
                      tilePadding: EdgeInsets.zero,
                      childrenPadding: const EdgeInsets.only(top: 8),
                      title: const Text(
                        'Field by field',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      subtitle: const Text(
                        'Hide details even from people who can see your profile.',
                      ),
                      children: [
                        for (final entry in {
                          'pronouns': 'Pronouns',
                          'location': 'Country',
                          'profession': 'Profession',
                          'education': 'Education',
                          'website': 'Website',
                          'timezone': 'Time zone',
                          'languages': 'Languages',
                          'interests': 'Interests',
                          'vibe': 'Current vibe',
                          'connections': 'Friends and follower lists',
                        }.entries)
                          fieldPicker(entry.key, '${entry.value} visibility'),
                      ],
                    ),
                  ),
                ],
              ),
              _Section(
                title: 'Connections',
                children: [
                  picker('Follow requests', 'followPolicy', {
                    'everyone': 'Anyone can follow me',
                    'approval': 'Ask me first',
                    'nobody': 'Nobody can follow me',
                  }),
                  picker('Who can send me friend requests?', 'requestsFrom', {
                    'everyone': 'Everyone',
                    'followers': 'People who follow me',
                    'friends': 'Friends of friends',
                    'nobody': 'Nobody',
                  }),
                  picker('Who can message me?', 'messagesFrom', audiences),
                ],
              ),
              _Section(
                title: 'Discover',
                children: [
                  toggle(
                    'discoverable',
                    'Show me in Discover',
                    'Other adults can find you by interests and language.',
                  ),
                  if (hiddenFromDiscover)
                    Padding(
                      key: const Key('discover-needs-public'),
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.info_outline_rounded,
                            size: 18,
                            color: scheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Discover only shows public profiles, so you won’t appear until your profile is Public.',
                              style: TextStyle(color: scheme.onSurfaceVariant),
                            ),
                          ),
                        ],
                      ),
                    ),
                  toggle(
                    'showInterestOverlap',
                    'Show shared interests',
                    'Let people see which interests you have in common.',
                  ),
                ],
              ),
              _Section(
                title: 'Posts and stories',
                children: [
                  picker(
                    'Who can comment on my posts?',
                    'commentsFrom',
                    audiences,
                  ),
                  picker('New stories are shared with', 'storyAudience', {
                    'public': 'Everyone',
                    'followers': 'Followers',
                    'friends': 'Friends',
                    // Older accounts may hold this; stories then go to friends.
                    if (widget.privacy.values['storyAudience'] == 'private')
                      'private': 'Only me (stories go to friends)',
                  }),
                ],
              ),
              _Section(
                title: 'Chats',
                children: [
                  toggle(
                    'readReceipts',
                    'Read receipts and typing',
                    'It works both ways: you see when people read and type only if they can see yours.',
                  ),
                ],
              ),
              _Section(
                title: 'Safety',
                children: [
                  ListTile(
                    key: const Key('open-controls'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.shield_outlined),
                    title: const Text(
                      'Blocked, muted and restricted',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: const Text(
                      'Only you can see who’s on these lists.',
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: busy ? null : () => context.go('/profile/controls'),
                  ),
                  ListTile(
                    key: const Key('open-reports'),
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.flag_outlined),
                    title: const Text(
                      'Your reports',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: const Text(
                      'See what happened with reports you sent.',
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: busy ? null : () => context.go('/profile/reports'),
                  ),
                ],
              ),
              Theme(
                data: Theme.of(context)
                    .copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  key: const Key('privacy-upcoming'),
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(top: 8),
                  title: const Text(
                    'For features on the way',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: const Text(
                    'Mentions and presence aren’t live yet. Choices you save here apply when they launch.',
                  ),
                  children: [
                    picker('Who can mention me?', 'mentionsFrom', audiences),
                    picker('Activity status', 'activityAudience', audiences),
                    picker('Online status', 'onlineAudience', audiences),
                    picker('Last seen', 'lastSeenAudience', audiences),
                    picker('Location sharing', 'locationAudience', audiences),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (dirty || error != null || conflict)
          Material(
            color: scheme.surface,
            elevation: 6,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          error!,
                          style: TextStyle(color: scheme.error),
                        ),
                      ),
                    Row(
                      children: [
                        if (conflict)
                          TextButton(
                            onPressed: () => ref.invalidate(privacyProvider),
                            child: const Text('Reload latest settings'),
                          )
                        else
                          TextButton(
                            key: const Key('privacy-discard'),
                            onPressed: busy || !dirty ? null : discard,
                            child: const Text('Discard'),
                          ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: FilledButton(
                            onPressed: busy || !dirty || conflict ? null : save,
                            child: Text(
                              busy ? 'Saving…' : 'Save privacy settings',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _Section({required this.title, required this.children});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(title, style: Theme.of(context).textTheme.titleLarge),
        ),
        VibePanel(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ],
    ),
  );
}
