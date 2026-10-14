import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api.dart';
import '../core/user_error.dart';
import '../shared/profile_stats.dart';
import '../shared/widgets.dart';
import 'people_lists/people_lists_actions.dart';
import 'pulse.dart';

export 'people_lists/connections_screen.dart' show ConnectionsScreen;
export 'people_lists/message_person.dart' show messagePerson;
export 'people_lists/my_stories_screen.dart' show MyStoriesScreen;
export 'people_lists/paged_list.dart' show PagedList;
export 'people_lists/people_lists_actions.dart'
    show PeopleListsActions, peopleListsActionsProvider;
export 'people_lists/story_time.dart' show storyTimeLeft;
export 'people_lists/visitors_screen.dart' show VisitorsScreen;

/// Where each tappable stat leads on your own profile.
ProfileStatActions ownStatActions(BuildContext context) => {
  ProfileStat.following: () => context.push('/profile/following'),
  ProfileStat.followers: () => context.push('/profile/followers'),
  ProfileStat.visitors: () => context.push('/profile/visitors'),
  ProfileStat.stories: () => context.push('/profile/stories'),
};

/// Where each tappable stat leads on someone else's profile: their lists when
/// the server says you may open them, their stories when there are some you may
/// watch, and never the visitors (those are for them alone).
ProfileStatActions otherStatActions(
  BuildContext context,
  WidgetRef ref,
  Profile profile,
) {
  final stats = profile.socialStats;
  return {
    if (profile.canSeeConnections) ...{
      ProfileStat.following: () =>
          context.push('/person/${profile.userId}/following'),
      ProfileStat.followers: () =>
          context.push('/person/${profile.userId}/followers'),
    },
    if (stats != null && stats.stories > 0)
      ProfileStat.stories: () => watchStories(context, ref, profile),
  };
}

/// Opens someone's stories you may watch in the story viewer.
Future<void> watchStories(
  BuildContext context,
  WidgetRef ref,
  Profile profile,
) async {
  final actions = ref.read(peopleListsActionsProvider);
  if (!actions.hasSession) return;
  try {
    final page = await actions.userStories(profile.userId);
    if (!context.mounted) return;
    if (page.items.isEmpty) {
      showMessage(context, 'No stories to watch right now.');
      return;
    }
    openStories(context, [
      StoryGroup(
        Person(
          profile.userId,
          profile.username,
          profile.displayName,
          avatarUrl: profile.avatarUrl,
        ),
        // Played oldest first, as in the tray.
        page.items.reversed.toList(),
      ),
    ], 0);
  } catch (e) {
    if (context.mounted) showFailure(context, e);
  }
}
