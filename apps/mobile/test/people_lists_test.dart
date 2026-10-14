import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/features/chat.dart' show chatEngineProvider;
import 'package:hiyall/features/people_lists.dart';
import 'package:hiyall/shared/story_canvas.dart';
import 'package:hiyall/features/pulse.dart';

import 'widget_test.dart' show FakeApi, launch;

const mira = Person('u-mira', 'mira', 'Mira');
const jun = Person('u-jun', 'jun_k', 'Jun');
const sol = Person('u-sol', 'sol', '');
const ravi = Person('u-ravi', 'ravi', 'Ravi');

DateTime ago(Duration d) => DateTime.now().subtract(d);

class ListsApi extends FakeApi {
  List<Connection> followingList = [
    Connection(mira, ago(const Duration(days: 1)), 'active'),
    Connection(jun, ago(const Duration(days: 3)), 'active'),
    Connection(sol, ago(const Duration(days: 9)), 'active'),
  ];
  List<Connection> followersList = [
    Connection(ravi, ago(const Duration(hours: 5)), 'none'),
    Connection(mira, ago(const Duration(days: 2)), 'active'),
  ];
  List<Connection> requests = [];
  List<Visitor> visitorList = [
    Visitor(ravi, ago(const Duration(hours: 3)), 'none'),
    Visitor(mira, ago(const Duration(days: 2)), 'active'),
  ];
  List<Story> storyList = [
    Story(
      storyId: 's1',
      body: 'sunset walk',
      background: 'pink',
      audience: 'followers',
      createdAt: ago(const Duration(hours: 2)),
      expiresAt: DateTime.now().add(const Duration(hours: 22, minutes: 5)),
      viewCount: 2,
    ),
    Story(
      storyId: 's2',
      body: 'hi',
      background: 'lime',
      audience: 'public',
      createdAt: ago(const Duration(hours: 20)),
      expiresAt: DateTime.now().add(const Duration(hours: 4, minutes: 5)),
      viewCount: 0,
    ),
  ];
  List<Map<String, dynamic>> viewerRows = [
    {
      'user': {'userId': 'u-ravi', 'username': 'ravi', 'displayName': 'Ravi'},
      'since': ago(const Duration(minutes: 30)).toUtc().toIso8601String(),
    },
  ];
  Object? listError, visitorsError, storiesError, viewersError;
  int? pageSize;
  final log = <String>[];
  int visitorLoads = 0;

  // Someone else's profile, as the server describes it to this viewer.
  bool canSeeConnections = true;
  int otherStories = 2;
  List<Story> otherStoryList = [];

  ApiPage<T> pageOf<T>(List<T> all, String? cursor) {
    final size = pageSize;
    if (size == null) return ApiPage(all, null);
    final start = cursor == null ? 0 : int.parse(cursor);
    final end = (start + size).clamp(0, all.length);
    return ApiPage(all.sublist(start, end), end < all.length ? '$end' : null);
  }

  @override
  Future<Profile> profile(Session s) async {
    profileReads++;
    return _mine();
  }

  Profile _mine() => Profile(
    userId: anjaliId,
    username: 'anjali',
    displayName: 'Anjali',
    bio: 'A new beginning',
    profession: '',
    version: '1',
    socialStats: ProfileSocialStats(
      following: followingList.length,
      followers: followersList.length,
      visitors: 14,
      stories: storyList.length,
    ),
  );

  @override
  Future<Profile> otherProfile(Session s, String userId) async => Profile(
    userId: userId,
    username: 'eshika',
    displayName: 'Eshika',
    bio: '',
    profession: '',
    version: '1',
    canSeeConnections: canSeeConnections,
    socialStats: ProfileSocialStats(
      following: 31,
      followers: 7,
      visitors: 50,
      stories: otherStories,
    ),
  );

  @override
  Future<ApiPage<Connection>> connections(
    Session s,
    String kind, {
    String? userId,
    String? cursor,
  }) async {
    log.add('connections $kind ${userId ?? 'me'}');
    if (listError != null) throw listError!;
    return pageOf(kind == 'followers' ? followersList : followingList, cursor);
  }

  @override
  Future<ApiPage<Connection>> followRequests(
    Session s, [
    String? cursor,
  ]) async => ApiPage(requests, null);

  @override
  Future<void> unfollow(Session s, String userId) async {
    log.add('unfollow $userId');
    followingList = [
      for (final c in followingList)
        if (c.user.userId != userId) c,
    ];
  }

  @override
  Future<String> follow(Session s, String userId) async {
    log.add('follow $userId');
    return 'active';
  }

  @override
  Future<void> removeFollower(Session s, String userId) async {
    log.add('remove-follower $userId');
    followersList = [
      for (final c in followersList)
        if (c.user.userId != userId) c,
    ];
  }

  @override
  Future<void> respondFollowRequest(
    Session s,
    String followerId,
    bool accept,
  ) async {
    log.add('${accept ? 'approve' : 'decline'} $followerId');
    final who = requests.firstWhere((r) => r.user.userId == followerId);
    requests = [
      for (final r in requests)
        if (r.user.userId != followerId) r,
    ];
    if (accept) {
      followersList = [Connection(who.user, DateTime.now()), ...followersList];
    }
  }

  @override
  Future<ApiPage<Visitor>> visitors(Session s, [String? cursor]) async {
    visitorLoads++;
    if (visitorsError != null) throw visitorsError!;
    return pageOf(visitorList, cursor);
  }

  @override
  Future<ApiPage<Story>> myStories(Session s, [String? cursor]) async {
    if (storiesError != null) throw storiesError!;
    return ApiPage(storyList, null);
  }

  @override
  Future<ApiPage<Story>> userStories(
    Session s,
    String userId, [
    String? cursor,
  ]) async {
    log.add('user-stories $userId');
    return ApiPage(otherStoryList, null);
  }

  @override
  Future<void> deleteStory(Session s, String id) async {
    log.add('delete-story $id');
    storyList = [
      for (final st in storyList)
        if (st.storyId != id) st,
    ];
  }

  @override
  Future<ApiPage<Map<String, dynamic>>> storyViewers(
    Session s,
    String id, [
    String? cursor,
  ]) async {
    log.add('viewers $id');
    if (viewersError != null) throw viewersError!;
    return ApiPage(id == 's1' ? viewerRows : [], null);
  }

  @override
  Future<void> block(Session s, String userId, bool value) async {
    log.add('block $userId $value');
  }
}

/// Someone else's profile whose lists open only while the viewer actively follows them, as the server
/// decides: following (or a friendship) opens them, a pending request or no follow does not.
class FollowGatedApi extends ListsApi {
  String state = 'none';
  bool pendingOnFollow = false;
  int profileLoads = 0;

  @override
  Future<Profile> otherProfile(Session s, String userId) async {
    profileLoads++;
    return Profile(
      userId: userId,
      username: 'eshika',
      displayName: 'Eshika',
      bio: '',
      profession: '',
      version: '1',
      relationship: Relationship(following: state, canFollow: state == 'none'),
      canSeeConnections: state == 'active',
      socialStats: const ProfileSocialStats(
        following: 31,
        followers: 7,
        visitors: 50,
        stories: 2,
      ),
    );
  }

  @override
  Future<String> follow(Session s, String userId) async {
    log.add('follow $userId');
    return state = pendingOnFollow ? 'pending' : 'active';
  }

  @override
  Future<void> unfollow(Session s, String userId) async {
    log.add('unfollow $userId');
    state = 'none';
  }
}

Future<void> goTo(WidgetTester tester, String path) async {
  GoRouter.of(tester.element(find.byType(Scaffold).first)).go(path);
  await tester.pumpAndSettle();
}

Future<void> open(WidgetTester tester, ListsApi api, String path) async {
  await launch(
    tester,
    api,
    // No encryption core in widget tests: Message fails closed, as on the profile.
    overrides: [chatEngineProvider.overrideWith((ref) async => null)],
  );
  await goTo(tester, path);
}

Future<void> tapKey(WidgetTester tester, Key key) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(key));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    for (final family in ['SpaceGrotesk', 'Manrope']) {
      await (FontLoader(
        family,
      )..addFont(rootBundle.load('assets/fonts/$family.ttf'))).load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  void teardownView(WidgetTester tester) {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  group('The stats row on your own profile', () {
    testWidgets('every stat is a labelled button at least 48 dp tall', (
      tester,
    ) async {
      teardownView(tester);
      final semantics = tester.ensureSemantics();
      await open(tester, ListsApi(), '/profile');
      for (final label in [
        '3 following, opens the list',
        '2 followers, opens the list',
        '14 visitors, opens the list',
        '2 stories, opens the stories',
      ]) {
        expect(find.bySemanticsLabel(label), findsOneWidget, reason: label);
      }
      for (final stat in ['following', 'followers', 'visitors', 'stories']) {
        final cell = find.byKey(ValueKey('stat-open-$stat'));
        expect(cell, findsOneWidget);
        expect(tester.getSize(cell).height, greaterThanOrEqualTo(48));
        // A whole-cell tap target: an InkWell that can take keyboard focus.
        expect(tester.widget<InkWell>(cell).canRequestFocus, isTrue);
      }
      semantics.dispose();
    });

    testWidgets('each stat opens its own screen', (tester) async {
      teardownView(tester);
      await open(tester, ListsApi(), '/profile');
      for (final (stat, title, screen) in [
        ('following', 'Following', ConnectionsScreen),
        ('followers', 'Followers', ConnectionsScreen),
        ('visitors', 'Visitors', VisitorsScreen),
        ('stories', 'My stories', MyStoriesScreen),
      ]) {
        await tapKey(tester, ValueKey('stat-open-$stat'));
        expect(find.byType(screen), findsOneWidget, reason: stat);
        expect(find.text(title), findsWidgets);
        await tester.tap(find.byKey(const Key('list-back')));
        await tester.pumpAndSettle();
        expect(find.byType(screen), findsNothing);
      }
      expect(tester.takeException(), isNull);
    });
  });

  group('Following', () {
    testWidgets('lists people newest first with name and @username', (
      tester,
    ) async {
      teardownView(tester);
      await open(tester, ListsApi(), '/profile/following');
      expect(find.text('Mira'), findsOneWidget);
      expect(find.text('@mira'), findsOneWidget);
      expect(find.text('@jun_k'), findsOneWidget);
      // A member without a display name shows as their @username.
      expect(find.text('@sol'), findsNWidgets(2));
      final order = [
        for (final id in ['u-mira', 'u-jun', 'u-sol'])
          tester.getTopLeft(find.byKey(ValueKey('connection-$id'))).dy,
      ];
      expect(order, [...order]..sort());
      expect(find.text('Message'), findsNWidgets(3));
    });

    testWidgets('Unfollow asks first; cancel keeps the row', (tester) async {
      teardownView(tester);
      final api = ListsApi();
      await open(tester, api, '/profile/following');
      await tapKey(tester, const Key('unfollow-u-jun'));
      expect(find.text('Unfollow Jun?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm-cancel')));
      await tester.pumpAndSettle();
      expect(api.log, isNot(contains('unfollow u-jun')));
      expect(find.byKey(const ValueKey('connection-u-jun')), findsOneWidget);
    });

    testWidgets('confirming unfollows, drops the row and updates the stat', (
      tester,
    ) async {
      teardownView(tester);
      final api = ListsApi();
      await open(tester, api, '/profile');
      await tapKey(tester, const ValueKey('stat-open-following'));
      final reads = api.profileReads;
      await tapKey(tester, const Key('unfollow-u-jun'));
      await tester.tap(find.byKey(const Key('confirm-ok')));
      await tester.pumpAndSettle();
      expect(api.log, contains('unfollow u-jun'));
      expect(find.byKey(const ValueKey('connection-u-jun')), findsNothing);
      expect(find.byKey(const ValueKey('connection-u-mira')), findsOneWidget);
      expect(api.profileReads, greaterThan(reads));
      await tester.tap(find.byKey(const Key('list-back')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('profile-social-stats')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Semantics>(find.byKey(const ValueKey('stat-following')))
            .properties
            .label,
        '2 following, opens the list',
      );
    });

    testWidgets('Message tells you when chat is not available here', (
      tester,
    ) async {
      teardownView(tester);
      await open(tester, ListsApi(), '/profile/following');
      await tapKey(tester, const Key('message-u-mira'));
      expect(find.textContaining('encryption'), findsOneWidget);
    });

    testWidgets('tapping the row opens their profile', (tester) async {
      teardownView(tester);
      await open(tester, ListsApi(), '/profile/following');
      await tester.tap(find.byKey(const ValueKey('connection-u-mira')));
      await tester.pumpAndSettle();
      expect(find.text('Eshika'), findsWidgets);
      expect(find.byType(ConnectionsScreen), findsNothing);
    });

    testWidgets('shows the empty state', (tester) async {
      teardownView(tester);
      await open(tester, ListsApi()..followingList = [], '/profile/following');
      expect(find.text('You’re not following anyone'), findsOneWidget);
      expect(find.text('Find people'), findsOneWidget);
    });

    testWidgets('shows an error and retries', (tester) async {
      teardownView(tester);
      final api = ListsApi()
        ..listError = const ApiFailure('Could not connect.');
      await open(tester, api, '/profile/following');
      expect(find.text('Could not connect.'), findsOneWidget);
      api.listError = null;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('connection-u-mira')), findsOneWidget);
    });

    testWidgets('pages with Show more and refreshes by pulling', (
      tester,
    ) async {
      teardownView(tester);
      final api = ListsApi()..pageSize = 2;
      await open(tester, api, '/profile/following');
      expect(find.byKey(const ValueKey('connection-u-sol')), findsNothing);
      await tapKey(tester, const Key('list-more'));
      expect(find.byKey(const ValueKey('connection-u-sol')), findsOneWidget);
      expect(find.byKey(const Key('list-more')), findsNothing);
      api.followingList = api.followingList.sublist(1);
      await tester.fling(
        find.byType(CustomScrollView).first,
        const Offset(0, 400),
        1000,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('connection-u-mira')), findsNothing);
    });
  });

  group('Followers', () {
    testWidgets('offers Follow back only to people you do not follow', (
      tester,
    ) async {
      teardownView(tester);
      final api = ListsApi();
      await open(tester, api, '/profile/followers');
      expect(find.byKey(const Key('follow-back-u-ravi')), findsOneWidget);
      expect(find.byKey(const Key('follow-back-u-mira')), findsNothing);
      expect(find.byKey(const Key('follows-u-mira')), findsOneWidget);
      await tapKey(tester, const Key('follow-back-u-ravi'));
      expect(api.log, contains('follow u-ravi'));
      expect(find.byKey(const Key('follow-back-u-ravi')), findsNothing);
      expect(find.text('You follow Ravi now.'), findsOneWidget);
    });

    testWidgets('Remove follower asks first', (tester) async {
      teardownView(tester);
      final api = ListsApi();
      await open(tester, api, '/profile/followers');
      await tapKey(tester, const Key('remove-follower-u-ravi'));
      expect(find.text('Remove Ravi as a follower?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm-cancel')));
      await tester.pumpAndSettle();
      expect(api.log, isNot(contains('remove-follower u-ravi')));
      expect(find.byKey(const ValueKey('connection-u-ravi')), findsOneWidget);
      await tapKey(tester, const Key('remove-follower-u-ravi'));
      await tester.tap(find.byKey(const Key('confirm-ok')));
      await tester.pumpAndSettle();
      expect(api.log, contains('remove-follower u-ravi'));
      expect(find.byKey(const ValueKey('connection-u-ravi')), findsNothing);
    });

    testWidgets('pending requests come first and can be approved', (
      tester,
    ) async {
      teardownView(tester);
      final api = ListsApi()
        ..requests = [Connection(jun, ago(const Duration(hours: 1)), 'none')];
      await open(tester, api, '/profile/followers');
      expect(find.byKey(const Key('follow-requests')), findsOneWidget);
      expect(find.text('Follow requests'), findsOneWidget);
      final requestTop = tester
          .getTopLeft(find.byKey(const Key('follow-requests')))
          .dy;
      expect(
        requestTop,
        lessThan(
          tester.getTopLeft(find.byKey(const ValueKey('connection-u-ravi'))).dy,
        ),
      );
      await tapKey(tester, const Key('approve-u-jun'));
      expect(api.log, contains('approve u-jun'));
      expect(find.byKey(const Key('follow-requests')), findsNothing);
      // The newest follower is now in the list.
      expect(find.byKey(const ValueKey('connection-u-jun')), findsOneWidget);
    });

    testWidgets('a request can be declined', (tester) async {
      teardownView(tester);
      final api = ListsApi()
        ..requests = [Connection(jun, ago(const Duration(hours: 1)), 'none')];
      await open(tester, api, '/profile/followers');
      await tapKey(tester, const Key('decline-u-jun'));
      expect(api.log, contains('decline u-jun'));
      expect(find.byKey(const Key('follow-requests')), findsNothing);
      expect(find.byKey(const ValueKey('connection-u-jun')), findsNothing);
    });

    testWidgets('shows the empty state', (tester) async {
      teardownView(tester);
      await open(tester, ListsApi()..followersList = [], '/profile/followers');
      expect(find.text('No followers yet'), findsOneWidget);
    });
  });

  group('Visitors', () {
    testWidgets('says plainly that visits can be seen, and lists visitors', (
      tester,
    ) async {
      teardownView(tester);
      await open(tester, ListsApi(), '/profile/visitors');
      expect(
        tester.widget<Text>(find.byKey(const Key('visitors-note'))).data,
        'People can see that you visited their profile.',
      );
      expect(find.text('Ravi'), findsOneWidget);
      expect(find.textContaining('@ravi · visited 3 h ago'), findsOneWidget);
      expect(find.textContaining('@mira · visited 2 days ago'), findsOneWidget);
    });

    testWidgets('tapping a visitor opens their profile', (tester) async {
      teardownView(tester);
      await open(tester, ListsApi(), '/profile/visitors');
      await tester.tap(
        find.byKey(const ValueKey('visitor-u-ravi')).hitTestable().first,
      );
      await tester.pumpAndSettle();
      expect(find.byType(VisitorsScreen), findsNothing);
    });

    testWidgets('the row menu has Message, Follow and Block', (tester) async {
      teardownView(tester);
      final api = ListsApi();
      await open(tester, api, '/profile/visitors');
      await tester.tap(find.byKey(const Key('visitor-menu-u-ravi')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('visitor-message-u-ravi')), findsOneWidget);
      expect(find.byKey(const Key('visitor-follow-u-ravi')), findsOneWidget);
      expect(find.byKey(const Key('visitor-block-u-ravi')), findsOneWidget);
      await tester.tap(find.byKey(const Key('visitor-follow-u-ravi')));
      await tester.pumpAndSettle();
      expect(api.log, contains('follow u-ravi'));
      // Someone you follow already is shown as such, not offered again.
      await tester.tap(find.byKey(const Key('visitor-menu-u-mira')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const Key('visitor-follow-u-mira')),
          matching: find.text('Following'),
        ),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      // After following, the same row says so.
      await tester.tap(find.byKey(const Key('visitor-menu-u-ravi')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const Key('visitor-follow-u-ravi')),
          matching: find.text('Following'),
        ),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      // Message
      await tester.tap(find.byKey(const Key('visitor-menu-u-ravi')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('visitor-message-u-ravi')));
      await tester.pumpAndSettle();
      expect(find.textContaining('encryption'), findsOneWidget);
    });

    testWidgets('Block asks first and removes the visitor', (tester) async {
      teardownView(tester);
      final api = ListsApi();
      await open(tester, api, '/profile/visitors');
      await tester.tap(find.byKey(const Key('visitor-menu-u-ravi')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('visitor-block-u-ravi')));
      await tester.pumpAndSettle();
      expect(find.text('Block Ravi?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm-cancel')));
      await tester.pumpAndSettle();
      expect(api.log, isNot(contains('block u-ravi true')));
      await tester.tap(find.byKey(const Key('visitor-menu-u-ravi')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('visitor-block-u-ravi')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-ok')));
      await tester.pumpAndSettle();
      expect(api.log, contains('block u-ravi true'));
      expect(find.byKey(const ValueKey('visitor-u-ravi')), findsNothing);
      expect(find.byKey(const ValueKey('visitor-u-mira')), findsOneWidget);
    });

    testWidgets('empty state, with the honesty line still there', (
      tester,
    ) async {
      teardownView(tester);
      await open(tester, ListsApi()..visitorList = [], '/profile/visitors');
      expect(find.text('No visitors yet'), findsOneWidget);
      expect(find.byKey(const Key('visitors-note')), findsOneWidget);
    });

    testWidgets('error state retries', (tester) async {
      teardownView(tester);
      final api = ListsApi()
        ..visitorsError = const ApiFailure('Could not connect.');
      await open(tester, api, '/profile/visitors');
      expect(find.text('Could not connect.'), findsOneWidget);
      api.visitorsError = null;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('visitor-u-ravi')), findsOneWidget);
      expect(api.visitorLoads, 2);
    });

    testWidgets('pulling down reloads the list', (tester) async {
      teardownView(tester);
      final api = ListsApi();
      await open(tester, api, '/profile/visitors');
      api.visitorList = api.visitorList.sublist(1);
      await tester.fling(
        find.byType(CustomScrollView).first,
        const Offset(0, 400),
        1000,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('visitor-u-ravi')), findsNothing);
    });
  });

  group('My stories', () {
    testWidgets('lists active stories with time left, audience and viewers', (
      tester,
    ) async {
      teardownView(tester);
      await open(tester, ListsApi(), '/profile/stories');
      expect(find.text('sunset walk'), findsWidgets);
      expect(find.textContaining('22h left'), findsOneWidget);
      expect(find.textContaining('4h left'), findsOneWidget);
      expect(find.text('Followers'), findsOneWidget);
      expect(find.text('Everyone'), findsOneWidget);
      expect(find.text('Seen by 2'), findsOneWidget);
      expect(find.text('Seen by 0'), findsOneWidget);
      expect(find.byKey(const Key('add-story')), findsOneWidget);
      // Newest first.
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('story-s1'))).dy,
        lessThan(tester.getTopLeft(find.byKey(const ValueKey('story-s2'))).dy),
      );
    });

    testWidgets('thumbnails draw each story as it was made', (tester) async {
      teardownView(tester);
      final api = ListsApi()
        ..storyList = [
          Story(
            storyId: 's1',
            body: 'glow up',
            background: 'aurora',
            textStyle: 'glow',
            audience: 'public',
            createdAt: ago(const Duration(hours: 1)),
            expiresAt: DateTime.now().add(const Duration(hours: 5, minutes: 5)),
            viewCount: 0,
          ),
          Story(
            storyId: 's2',
            body: 'old one',
            background: 'from-the-future',
            audience: 'public',
            createdAt: ago(const Duration(hours: 3)),
            expiresAt: DateTime.now().add(
              const Duration(hours: 20, minutes: 5),
            ),
            viewCount: 0,
          ),
        ];
      await open(tester, api, '/profile/stories');
      final canvases = tester
          .widgetList<StoryCanvas>(find.byType(StoryCanvas))
          .toList();
      expect(
        [for (final c in canvases) (c.background, c.textStyle)],
        [('aurora', 'glow'), ('from-the-future', 'clean')],
      );
      // The time left comes from the server's expiry, whatever length was chosen.
      expect(find.textContaining('5h left'), findsOneWidget);
      expect(find.textContaining('20h left'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping a story shows who saw it', (tester) async {
      teardownView(tester);
      final api = ListsApi();
      await open(tester, api, '/profile/stories');
      await tapKey(tester, const Key('story-open-s1'));
      expect(api.log, contains('viewers s1'));
      expect(find.byKey(const Key('viewers-title')), findsOneWidget);
      expect(find.byKey(const ValueKey('viewer-u-ravi')), findsOneWidget);
      expect(find.text('@ravi · 30 min ago'), findsOneWidget);
    });

    testWidgets('a story nobody saw says so', (tester) async {
      teardownView(tester);
      await open(tester, ListsApi(), '/profile/stories');
      await tapKey(tester, const Key('story-open-s2'));
      expect(find.byKey(const Key('viewers-empty')), findsOneWidget);
    });

    testWidgets('the viewers sheet reports a failure and retries', (
      tester,
    ) async {
      teardownView(tester);
      final api = ListsApi()..viewersError = const ApiFailure('Offline');
      await open(tester, api, '/profile/stories');
      await tapKey(tester, const Key('story-open-s1'));
      expect(find.text('Couldn’t load viewers.'), findsOneWidget);
      api.viewersError = null;
      await tester.tap(find.byKey(const Key('viewers-retry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('viewer-u-ravi')), findsOneWidget);
    });

    testWidgets(
      'Delete asks first; confirming removes it and the count drops',
      (tester) async {
        teardownView(tester);
        final api = ListsApi();
        await open(tester, api, '/profile/stories');
        await tapKey(tester, const Key('story-delete-s1'));
        expect(find.text('Delete this story?'), findsOneWidget);
        await tester.tap(find.byKey(const Key('confirm-cancel')));
        await tester.pumpAndSettle();
        expect(api.log, isNot(contains('delete-story s1')));
        expect(find.byKey(const ValueKey('story-s1')), findsOneWidget);
        final reads = api.profileReads;
        await tapKey(tester, const Key('story-delete-s1'));
        await tester.tap(find.byKey(const Key('confirm-ok')));
        await tester.pumpAndSettle();
        expect(api.log, contains('delete-story s1'));
        expect(find.byKey(const ValueKey('story-s1')), findsNothing);
        expect(find.byKey(const ValueKey('story-s2')), findsOneWidget);
        expect(api.profileReads, greaterThan(reads));
      },
    );

    testWidgets('Add story opens the story composer', (tester) async {
      teardownView(tester);
      await open(tester, ListsApi(), '/profile/stories');
      await tapKey(tester, const Key('add-story'));
      expect(find.byType(StoryComposerScreen), findsOneWidget);
    });

    testWidgets('empty state offers to add one', (tester) async {
      teardownView(tester);
      await open(tester, ListsApi()..storyList = [], '/profile/stories');
      expect(find.text('No stories up right now'), findsOneWidget);
      await tapKey(tester, const Key('add-story-empty'));
      expect(find.byType(StoryComposerScreen), findsOneWidget);
    });

    testWidgets('error state retries', (tester) async {
      teardownView(tester);
      final api = ListsApi()
        ..storiesError = const ApiFailure('Could not connect.');
      await open(tester, api, '/profile/stories');
      expect(find.text('Could not connect.'), findsOneWidget);
      api.storiesError = null;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('story-s1')), findsOneWidget);
    });
  });

  group('Someone else\'s profile', () {
    testWidgets(
      'Followers and Following open read-only when the server allows',
      (tester) async {
        teardownView(tester);
        final api = ListsApi();
        await open(tester, api, '/discover/person/u-eshika');
        final semantics = tester.ensureSemantics();
        expect(
          find.bySemanticsLabel('7 followers, opens the list'),
          findsOneWidget,
        );
        expect(
          find.bySemanticsLabel('31 following, opens the list'),
          findsOneWidget,
        );
        semantics.dispose();
        await tapKey(tester, const ValueKey('stat-open-followers'));
        expect(api.log, contains('connections followers u-eshika'));
        expect(find.byType(ConnectionsScreen), findsOneWidget);
        expect(find.byKey(const ValueKey('connection-u-ravi')), findsOneWidget);
        // No management buttons on someone else's list.
        expect(find.text('Follow back'), findsNothing);
        expect(find.text('Remove'), findsNothing);
        expect(find.text('Unfollow'), findsNothing);
        expect(find.text('Message'), findsNothing);
        expect(find.byKey(const Key('follow-requests')), findsNothing);
        await tester.tap(find.byKey(const Key('list-back')));
        await tester.pumpAndSettle();
        await tapKey(tester, const ValueKey('stat-open-following'));
        expect(api.log, contains('connections following u-eshika'));
      },
    );

    testWidgets(
      'the lists are plain numbers with a calm note when not shared',
      (tester) async {
        teardownView(tester);
        final api = ListsApi()..canSeeConnections = false;
        await open(tester, api, '/discover/person/u-eshika');
        final semantics = tester.ensureSemantics();
        expect(find.bySemanticsLabel('7 followers'), findsOneWidget);
        semantics.dispose();
        expect(find.byKey(const ValueKey('stat-open-followers')), findsNothing);
        expect(find.byKey(const ValueKey('stat-open-following')), findsNothing);
        expect(
          find.text('Their followers and following lists are private.'),
          findsOneWidget,
        );
        expect(find.text('31'), findsOneWidget);
      },
    );

    testWidgets(
      'following someone opens their lists at once, unfollowing closes them',
      (tester) async {
        teardownView(tester);
        final api = FollowGatedApi();
        await open(tester, api, '/discover/person/u-eshika');
        const note = 'Their followers and following lists are private.';
        // Not following: plain numbers and the calm note.
        expect(find.byKey(const ValueKey('stat-open-followers')), findsNothing);
        expect(find.byKey(const ValueKey('stat-open-following')), findsNothing);
        expect(find.text(note), findsOneWidget);
        final loads = api.profileLoads;

        // Follow: the profile reloads and the cells open, the note is gone.
        await tapKey(tester, const Key('follow'));
        expect(api.log, contains('follow u-eshika'));
        expect(api.profileLoads, greaterThan(loads));
        expect(
          find.byKey(const ValueKey('stat-open-followers')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('stat-open-following')),
          findsOneWidget,
        );
        expect(find.text(note), findsNothing);
        // Visitors stays a plain number even for a follower.
        expect(find.byKey(const ValueKey('stat-open-visitors')), findsNothing);
        await tapKey(tester, const ValueKey('stat-open-followers'));
        expect(api.log, contains('connections followers u-eshika'));
        await tester.tap(find.byKey(const Key('list-back')));
        await tester.pumpAndSettle();

        // Unfollow: reloaded again, back to plain numbers and the note.
        final loadsAfterFollow = api.profileLoads;
        await tapKey(tester, const Key('following'));
        await tester.tap(find.widgetWithText(FilledButton, 'Unfollow'));
        await tester.pumpAndSettle();
        expect(api.log, contains('unfollow u-eshika'));
        expect(api.profileLoads, greaterThan(loadsAfterFollow));
        expect(find.byKey(const ValueKey('stat-open-followers')), findsNothing);
        expect(find.byKey(const ValueKey('stat-open-following')), findsNothing);
        expect(find.text(note), findsOneWidget);
      },
    );

    testWidgets('a pending follow request does not open the lists', (
      tester,
    ) async {
      teardownView(tester);
      final api = FollowGatedApi()..pendingOnFollow = true;
      await open(tester, api, '/discover/person/u-eshika');
      await tapKey(tester, const Key('follow'));
      expect(find.byKey(const Key('follow-requested')), findsOneWidget);
      expect(find.byKey(const ValueKey('stat-open-followers')), findsNothing);
      expect(find.byKey(const ValueKey('stat-open-following')), findsNothing);
      expect(
        find.text('Their followers and following lists are private.'),
        findsOneWidget,
      );
    });

    testWidgets('Visitors is never tappable on someone else\'s profile', (
      tester,
    ) async {
      teardownView(tester);
      await open(tester, ListsApi(), '/discover/person/u-eshika');
      expect(find.byKey(const ValueKey('stat-open-visitors')), findsNothing);
      expect(find.text('50'), findsOneWidget);
    });

    testWidgets('Stories opens the story viewer for what you may watch', (
      tester,
    ) async {
      teardownView(tester);
      final api = ListsApi()
        ..otherStoryList = [
          Story(
            storyId: 'o1',
            body: 'their story',
            background: 'mint',
            audience: 'public',
            createdAt: ago(const Duration(hours: 1)),
            expiresAt: DateTime.now().add(const Duration(hours: 23)),
          ),
        ];
      await open(tester, api, '/discover/person/u-eshika');
      await tester.tap(find.byKey(const ValueKey('stat-open-stories')));
      // The viewer runs a timer, so settle by hand rather than to the end.
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(api.log, contains('user-stories u-eshika'));
      expect(find.byType(StoryViewer), findsOneWidget);
      expect(find.text('their story'), findsOneWidget);
      await tester.tap(find.byKey(const Key('close-stories')));
      await tester.pump(const Duration(milliseconds: 500));
    });

    testWidgets('Stories is a plain number when there is nothing to watch', (
      tester,
    ) async {
      teardownView(tester);
      final api = ListsApi()..otherStories = 0;
      await open(tester, api, '/discover/person/u-eshika');
      expect(find.byKey(const ValueKey('stat-open-stories')), findsNothing);
    });

    testWidgets('a private list the server refuses reads as not shared', (
      tester,
    ) async {
      teardownView(tester);
      final api = ListsApi()
        ..listError = const ApiFailure(
          'This list is private',
          403,
          'CONNECTIONS_PRIVATE',
        );
      await open(tester, api, '/person/u-eshika/followers');
      expect(find.text('Not shared'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
    });
  });

  group('Layout and parsing', () {
    testWidgets('lists hold at double text size without overflow', (
      tester,
    ) async {
      teardownView(tester);
      final api = ListsApi()
        ..requests = [Connection(jun, ago(const Duration(hours: 1)), 'none')];
      await launch(
        tester,
        api,
        textScale: 2,
        overrides: [chatEngineProvider.overrideWith((ref) async => null)],
      );
      for (final path in [
        '/profile/followers',
        '/profile/following',
        '/profile/visitors',
        '/profile/stories',
        '/profile',
      ]) {
        await goTo(tester, path);
        expect(tester.takeException(), isNull, reason: path);
      }
    });

    test('rows and the profile parse what the server sends', () {
      final c = Connection.fromJson({
        'user': {
          'userId': 'u1',
          'username': 'a',
          'displayName': 'A',
          'avatarUrl': null,
        },
        'since': '2026-10-01T10:00:00Z',
        'following': 'pending',
      });
      expect(c.following, 'pending');
      // Story viewer rows have no follow state.
      expect(
        Connection.fromJson({
          'user': {'userId': 'u1', 'username': 'a', 'displayName': 'A'},
          'since': '2026-10-01T10:00:00Z',
        }).following,
        'none',
      );
      final v = Visitor.fromJson({
        'user': {'userId': 'u1', 'username': 'a', 'displayName': 'A'},
        'firstVisitedAt': '2026-10-01T10:00:00Z',
        'following': 'active',
      });
      expect(v.following, 'active');
      expect(v.withFollowing('none').firstVisitedAt, v.firstVisitedAt);
      Profile profile(Map<String, dynamic> extra) => Profile.fromJson({
        'userId': 'u1',
        'username': 'a',
        'displayName': 'A',
        ...extra,
      });
      expect(profile({'canSeeConnections': true}).canSeeConnections, isTrue);
      // Fails closed when the server did not say.
      expect(profile({}).canSeeConnections, isFalse);
    });
  });
}
