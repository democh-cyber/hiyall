import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/state.dart';
import '../shared/widgets.dart';
import '../shared/profile_space.dart';
import 'people_lists.dart';
import 'profile_editor.dart';
import 'pulse.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});
  @override
  ConsumerState<ProfileScreen> createState() => _ProfileState();
}

class _ProfileState extends ConsumerState<ProfileScreen> {
  void openSettings() => context.go('/profile/settings');

  @override
  Widget build(BuildContext context) => ref
      .watch(profileProvider)
      .when(
        data: (profile) => ProfileSpace(
          profile: profile,
          isOwner: true,
          onEdit: () => context.go('/profile/edit'),
          onSettings: openSettings,
          statActions: ownStatActions(context),
          contentFor: (tab) => profileContent(ref, profile.userId, tab),
        ),
        loading: () => const ProfileSkeleton(),
        error: (e, s) => ReadingWidth(
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              FailureCard(
                error: e,
                retry: () => ref.invalidate(profileProvider),
              ),
            ],
          ),
        ),
      );
}

class EditProfileScreen extends ConsumerStatefulWidget {
  const EditProfileScreen({super.key});
  @override
  ConsumerState<EditProfileScreen> createState() => _EditProfileState();
}

class _EditProfileState extends ConsumerState<EditProfileScreen> {
  /// Bumped to start the form over from the newest profile. The version isn't
  /// part of the form's identity: a photo change moves it on, and that must
  /// not throw away what has been typed.
  int generation = 0;

  void reload() {
    setState(() => generation++);
    ref.invalidate(profileProvider);
  }

  @override
  Widget build(BuildContext context) => ReadingWidth(
    child: ref
        .watch(profileProvider)
        .when(
          data: (profile) => ProfileForm(
            key: ValueKey('${profile.userId}:$generation'),
            profile: profile,
            onReload: reload,
          ),
          loading: () => const VibeLoading(),
          error: (e, s) => FailureCard(
            error: e,
            retry: () => ref.invalidate(profileProvider),
          ),
        ),
  );
}
