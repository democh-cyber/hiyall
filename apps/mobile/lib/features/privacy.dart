import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api.dart';
import '../core/state.dart';
import '../core/theme.dart';
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

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
          onPressed: busy ? null : () => context.go('/profile'),
          icon: const Icon(Icons.arrow_back),
          label: const Text('Profile'),
        ),
      ),
      const VibePanel(
        color: VibeColors.lilac,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            VibeTag(
              'Your boundaries',
              color: Colors.white,
              icon: Icons.tune_rounded,
            ),
            SizedBox(height: 22),
            Text(
              'Good vibes.\nClear boundaries.',
              style: TextStyle(
                fontFamily: 'SpaceGrotesk',
                fontSize: 36,
                height: 1.08,
                letterSpacing: -1.5,
                fontWeight: FontWeight.w700,
                color: VibeColors.ink,
              ),
            ),
            SizedBox(height: 16),
            Text(
              'Choose who gets a window into your world. Changes take effect only after you save.',
              style: TextStyle(color: VibeColors.ink, height: 1.6),
            ),
          ],
        ),
      ),
      const SectionTitle('Who gets to see you?', label: '01 / VISIBILITY'),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Profile visibility',
                style: Theme.of(context).textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              const Text(
                'Public profiles can be viewed by other signed-in people. Friends and follower access will open when those connections are available.',
              ),
              const SizedBox(height: 24),
              picker('Who can view my profile?', 'profileAudience', {
                'public': 'Public',
                'friends': 'Friends',
                'followers': 'Followers',
                'private': 'Only me',
              }),
              for (final entry in {
                'pronouns': 'Pronouns',
                'location': 'Country',
                'profession': 'Profession',
                'education': 'Education',
                'website': 'Website',
                'timezone': 'Time zone',
                'languages': 'Languages',
                'interests': 'Interests',
                'vibe': 'Current Vibe',
                'connections': 'Social counts',
              }.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 18),
                  child: DropdownButtonFormField<String>(
                    initialValue: fields[entry.key] as String? ?? 'nobody',
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: '${entry.value} visibility',
                    ),
                    items: audiences.entries
                        .map(
                          (e) => DropdownMenuItem(
                            value: e.key,
                            child: Text(e.value),
                          ),
                        )
                        .toList(),
                    onChanged: busy
                        ? null
                        : (value) {
                            if (value != null) {
                              setState(() {
                                fields[entry.key] = value;
                                dirty = true;
                              });
                            }
                          },
                  ),
                ),
            ],
          ),
        ),
      ),
      const SectionTitle('Keep your circle comfy', label: '02 / CONNECTIONS'),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Connection preferences',
                style: Theme.of(context).textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              const Text(
                'Set your preferences ahead of discovery, sharing, and chat becoming available.',
              ),
              const SizedBox(height: 20),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Include me in discovery'),
                value: draft['discoverable'] as bool,
                onChanged: busy
                    ? null
                    : (value) => change('discoverable', value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Show shared interests'),
                value: draft['showInterestOverlap'] as bool,
                onChanged: busy
                    ? null
                    : (value) => change('showInterestOverlap', value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Read receipts'),
                value: draft['readReceipts'] as bool,
                onChanged: busy
                    ? null
                    : (value) => change('readReceipts', value),
              ),
              const SizedBox(height: 16),
              picker('Who can message me?', 'messagesFrom', audiences),
              picker('Follow requests', 'followPolicy', {
                'everyone': 'Allow everyone',
                'approval': 'Ask me first',
                'nobody': 'Allow nobody',
              }),
              picker('Connection requests', 'requestsFrom', audiences),
              picker('Who can comment?', 'commentsFrom', audiences),
              picker('Who can mention me?', 'mentionsFrom', audiences),
              picker('Stories', 'storyAudience', {
                'public': 'Public',
                'friends': 'Friends',
                'followers': 'Followers',
                'private': 'Only me',
              }),
              picker('Activity', 'activityAudience', audiences),
              picker('Online status', 'onlineAudience', audiences),
              picker('Last seen', 'lastSeenAudience', audiences),
              picker('Location sharing', 'locationAudience', audiences),
            ],
          ),
        ),
      ),
      const SizedBox(height: 20),
      if (error != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      if (conflict)
        TextButton(
          onPressed: () => ref.invalidate(privacyProvider),
          child: const Text('Reload latest settings'),
        ),
      FilledButton(
        onPressed: busy || !dirty || conflict ? null : save,
        child: Text(busy ? 'Saving…' : 'Save privacy settings'),
      ),
      const SizedBox(height: 32),
    ],
  );
}
