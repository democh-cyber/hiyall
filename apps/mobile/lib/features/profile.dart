import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/state.dart';
import '../shared/widgets.dart';
import '../shared/profile_space.dart';
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

class EditProfileScreen extends ConsumerWidget {
  const EditProfileScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => ReadingWidth(
    child: ref
        .watch(profileProvider)
        .when(
          data: (profile) => ProfileForm(
            key: ValueKey('${profile.userId}:${profile.version}'),
            profile: profile,
          ),
          loading: () => const VibeLoading(),
          error: (e, s) => FailureCard(
            error: e,
            retry: () => ref.invalidate(profileProvider),
          ),
        ),
  );
}
