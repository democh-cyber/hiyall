import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/app_info.dart' show FeatureFlags;
import 'package:hiyall/app.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/home_prefs.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/core/theme.dart';
import 'package:hiyall/features/home.dart';
import 'package:hiyall/features/live_sync.dart';
import 'package:hiyall/features/discovery.dart' show FindPeopleScreen;
import 'package:hiyall/features/pulse.dart'
    show ComposePostScreen, postPhotoFactory;
import 'package:hiyall/shared/person_avatar.dart';
import 'package:hiyall/shared/press_scale.dart';

import 'widget_test.dart' show FakeApi, SignedIn;
import 'support/fixtures.dart';

const miraId = '019a4000-0000-7000-8000-0000000000b1';
const niko = Person(nikoId, 'niko', 'Niko');
const mira = Person(miraId, 'mira', 'Mira');
const me = Person(anjaliId, 'anjali', 'Anjali');

class HomeApi extends FakeApi {
  final searches = <Map<String, dynamic>>[];
  final patches = <Map<String, dynamic>>[];
  final feedModes = <String>[];
  String vibe = '';
  bool failVibe = false;

  /// Holds a vibe save open until the test lets it go.
  Completer<void>? gate;

  /// A profile with all six parts filled in.
  bool complete = false;
  List<Post> everyone = [];

  @override
  Future<ApiPage<Post>> feed(Session s, String mode, [String? cursor]) async {
    feedModes.add(mode);
    return ApiPage(mode == 'everyone' ? everyone : posts, null);
  }

  @override
  Future<Map<String, dynamic>> searchPeople(
    Session s,
    Map<String, dynamic> filters,
  ) async {
    searches.add(filters);
    return {
      'items': [
        // The server never returns the viewer, but Home must not show them.
        {'userId': anjaliId, 'username': 'anjali', 'displayName': 'Anjali'},
        {
          'userId': nikoId,
          'username': 'niko',
          'displayName': 'Niko',
          'currentVibe': 'Film photos and late trains',
          'interests': ['Music', 'Photography'],
        },
        {
          'userId': miraId,
          'username': 'mira',
          'displayName': 'Mira',
          'headline': 'Illustrator',
          'interests': ['Art', 'Music'],
        },
      ],
      'nextCursor': null,
    };
  }

  @override
  Future<String> follow(Session s, String userId) async {
    calls.add('follow-user $userId');
    return 'active';
  }

  @override
  Future<Profile> profile(Session s) async => Profile(
    userId: anjaliId,
    username: 'anjali',
    displayName: 'Anjali',
    bio: 'A new beginning',
    profession: '',
    version: '1',
    // A complete profile has a vibe too.
    currentVibe: vibe.isEmpty && complete ? '🎧 Vibing' : vibe,
    interests: const ['Music'],
    headline: complete ? 'Hi' : '',
    pronouns: complete ? 'she/her' : '',
    languages: complete ? const [ProfileLanguage('en')] : const [],
  );

  @override
  Future<Profile> updateProfile(
    Session s,
    Profile p,
    Map<String, dynamic> patch,
  ) async {
    patches.add(patch);
    await gate?.future;
    if (failVibe) throw const ApiFailure('Offline');
    vibe = patch['currentVibe'] as String? ?? vibe;
    return p;
  }
}

class FixedUnread extends ChatUnread {
  final int count;
  FixedUnread(this.count);
  @override
  int build() => count;
}

Map<String, dynamic> request(
  String id, {
  String type = 'friend_request',
  String userId = nikoId,
  String username = 'niko',
  String name = 'Niko',
  bool read = false,
}) => {
  'notificationId': id,
  'type': type,
  'actors': [
    {'userId': userId, 'username': username, 'displayName': name},
  ],
  'targetType': 'request',
  'targetId': 'fr-$id',
  'createdAt': DateTime.now().toUtc().toIso8601String(),
  'readAt': read ? DateTime.now().toUtc().toIso8601String() : null,
  'text': '$name sent you a request',
};

Map<String, dynamic> reaction(String id) => {
  'notificationId': id,
  'type': 'post_reaction',
  'actors': [
    {'userId': nikoId, 'username': 'niko', 'displayName': 'Niko'},
  ],
  'targetType': 'post',
  'targetId': 'p1',
  'createdAt': DateTime.now().toUtc().toIso8601String(),
  'readAt': null,
  'text': 'Niko reacted to your post',
};

Post post(
  String id, {
  String body = 'hello there',
  Person author = niko,
  bool photo = false,
  int reactions = 0,
  int comments = 0,
}) => Post(
  postId: id,
  author: author,
  body: body,
  audience: 'public',
  createdAt: DateTime.now().subtract(const Duration(hours: 3)),
  reactionCount: reactions,
  commentCount: comments,
  media: photo
      ? [PostMedia('m-$id', 'https://media.test/$id.jpg', '', 800, 1000)]
      : const [],
);

class Launched {
  final ProviderContainer container;
  final HomeApi api;
  final MemoryHomePrefsStore prefs;
  Launched(this.container, this.api, this.prefs);
}

Future<Launched> launch(
  WidgetTester tester,
  HomeApi api, {
  Size size = const Size(390, 844),
  double textScale = 1,
  DateTime? now,
  int unread = 0,
  MemoryHomePrefsStore? prefs,
  Widget Function(Widget app)? wrap,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  if (textScale != 1) {
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }
  final store = prefs ?? MemoryHomePrefsStore();
  final container = ProviderContainer(
    overrides: [
      apiProvider.overrideWithValue(api),
      sessionProvider.overrideWith(SignedIn.new),
      homePrefsStoreProvider.overrideWithValue(store),
      homeClockProvider.overrideWithValue(
        () => now ?? DateTime(2026, 10, 12, 9),
      ),
      if (unread > 0)
        chatUnreadProvider.overrideWith(() => FixedUnread(unread)),
    ],
  );
  addTearDown(container.dispose);
  final app = UncontrolledProviderScope(
    container: container,
    child: const HiyallApp(),
  );
  await tester.pumpWidget(wrap == null ? app : wrap(app));
  container.read(routerProvider).go('/home');
  await tester.pumpAndSettle();
  return Launched(container, api, store);
}

String location(ProviderContainer c) =>
    c.read(routerProvider).routerDelegate.currentConfiguration.uri.path;

Finder get homeScrollable => find
    .descendant(
      of: find.byKey(const Key('home-scroll')),
      matching: find.byType(Scrollable),
    )
    .first;

Future<void> reveal(WidgetTester tester, Finder f) async {
  await tester.scrollUntilVisible(f, 250, scrollable: homeScrollable);
  await tester.pumpAndSettle();
}

Color chipColor(WidgetTester tester, String key) {
  final box = tester.widget<AnimatedContainer>(
    find.descendant(
      of: find.byKey(Key(key)),
      matching: find.byType(AnimatedContainer),
    ),
  );
  return (box.decoration! as BoxDecoration).color!;
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

  group('Greeting', () {
    test('follows the time of day and uses the first name', () {
      expect(homeGreeting(DateTime(2026, 1, 1, 8), 'Mira Rao'), 'gm Mira ☀️');
      expect(homeGreeting(DateTime(2026, 1, 1, 14), 'Mira'), 'hey Mira 🌤️');
      expect(homeGreeting(DateTime(2026, 1, 1, 20), 'Mira'), 'hey Mira 🌙');
      expect(
        homeGreeting(DateTime(2026, 1, 1, 2), 'Mira'),
        'still up, Mira? 👀',
      );
      expect(
        homeGreeting(DateTime(2026, 1, 1, 23), 'Mira'),
        'still up, Mira? 👀',
      );
      expect(homeGreeting(DateTime(2026, 1, 1, 8), null), 'gm ☀️');
      expect(homeGreeting(DateTime(2026, 1, 1, 2), '  '), 'still up? 👀');
    });

    testWidgets('shows on the page for the injected hour', (tester) async {
      for (final (hour, text) in [
        (8, 'gm Anjali ☀️'),
        (20, 'hey Anjali 🌙'),
        (2, 'still up, Anjali? 👀'),
      ]) {
        await launch(tester, HomeApi(), now: DateTime(2026, 10, 12, hour));
        expect(find.byKey(const Key('home-greeting')), findsOneWidget);
        expect(find.text(text), findsOneWidget, reason: 'at $hour:00');
      }
    });
  });

  test('Profile progress lists what is missing', () {
    const done = Profile(
      userId: 'u',
      username: 'u',
      displayName: 'U',
      bio: 'b',
      profession: '',
      version: '1',
      headline: 'h',
      currentVibe: 'v',
      pronouns: 'they/them',
      interests: ['Music'],
      languages: [ProfileLanguage('en')],
    );
    expect(missingProfileParts(done), isEmpty);
    expect(
      missingProfileParts(
        const Profile(
          userId: 'u',
          username: 'u',
          displayName: 'U',
          bio: ' ',
          profession: '',
          version: '1',
        ),
      ),
      ['Bio', 'Headline', 'Current vibe', 'Interests', 'Languages', 'Pronouns'],
    );
  });

  group('Vibe check', () {
    testWidgets('the current vibe is preselected', (tester) async {
      await launch(tester, HomeApi()..vibe = '🎧 Vibing');
      expect(chipColor(tester, 'vibe-vibing'), VibeColors.lime);
      expect(chipColor(tester, 'vibe-sleepy'), isNot(VibeColors.lime));
      expect(find.text('What’s your vibe today?'), findsOneWidget);
    });

    testWidgets('one tap saves currentVibe and highlights the chip', (
      tester,
    ) async {
      final api = HomeApi()..gate = Completer<void>();
      await launch(tester, api);
      expect(chipColor(tester, 'vibe-sleepy'), isNot(VibeColors.lime));

      await tester.tap(find.byKey(const Key('vibe-sleepy')));
      await tester.pump();
      // Highlighted before the server has answered.
      expect(find.text('Saving…'), findsOneWidget);
      expect(chipColor(tester, 'vibe-sleepy'), VibeColors.lime);
      api.gate!.complete();
      await tester.pumpAndSettle();
      expect(api.patches.single, {'currentVibe': '😴 Sleepy'});
      expect(chipColor(tester, 'vibe-sleepy'), VibeColors.lime);
      // An inline check, not a snackbar.
      expect(find.text('Vibe saved'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('vibe-sleepy')),
          matching: find.byIcon(Icons.check_rounded),
        ),
        findsOneWidget,
      );
      expect(find.byType(SnackBar), findsNothing);

      // The check goes away on its own and the question comes back.
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('What’s your vibe today?'), findsOneWidget);
      expect(chipColor(tester, 'vibe-sleepy'), VibeColors.lime);

      // Choosing another moves the highlight.
      await tester.tap(find.byKey(const Key('vibe-on-fire')));
      await tester.pumpAndSettle();
      expect(api.patches.last, {'currentVibe': '🔥 On fire'});
      expect(chipColor(tester, 'vibe-on-fire'), VibeColors.lime);
      expect(chipColor(tester, 'vibe-sleepy'), isNot(VibeColors.lime));

      // And the chosen one again turns it off.
      await tester.tap(find.byKey(const Key('vibe-on-fire')));
      await tester.pumpAndSettle();
      expect(api.patches.last, {'currentVibe': ''});
      expect(chipColor(tester, 'vibe-on-fire'), isNot(VibeColors.lime));
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('a vibe typed in the editor leads the strip', (tester) async {
      await launch(tester, HomeApi()..vibe = '🌿 Taking it slow');
      expect(chipColor(tester, 'vibe-custom'), VibeColors.lime);
      expect(find.text('🌿 Taking it slow'), findsOneWidget);
    });

    testWidgets('a failed save puts the highlight back and says so', (
      tester,
    ) async {
      final api = HomeApi()
        ..vibe = '🎧 Vibing'
        ..failVibe = true;
      await launch(tester, api);
      await tester.tap(find.byKey(const Key('vibe-sleepy')));
      await tester.pumpAndSettle();
      expect(find.text('Couldn’t save that. Try again?'), findsOneWidget);
      expect(chipColor(tester, 'vibe-vibing'), VibeColors.lime);
      expect(chipColor(tester, 'vibe-sleepy'), isNot(VibeColors.lime));
      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('For you', () {
    testWidgets('is not there when nothing is waiting', (tester) async {
      await launch(tester, HomeApi());
      expect(find.byKey(const Key('home-for-you')), findsNothing);
      expect(find.text('For you'), findsNothing);
      // The old always-on counters are gone for good.
      expect(find.bySemanticsLabel('0 requests'), findsNothing);
      expect(find.byKey(const Key('home-pulse-chats')), findsNothing);
    });

    testWidgets('accepting a request answers it and the row folds away', (
      tester,
    ) async {
      final api = HomeApi()..activity = [request('n1')];
      await launch(tester, api);
      expect(find.text('Niko wants to be friends 💚'), findsOneWidget);
      expect(find.text('For you'), findsOneWidget);
      // The request has its own card, so it is not also counted as activity.
      expect(find.byKey(const Key('home-card-activity')), findsNothing);

      await tester.tap(find.byKey(const Key('home-accept-n1')));
      await tester.pumpAndSettle();
      expect(api.calls, contains('friend fr-n1 true'));
      expect(find.text('Niko wants to be friends 💚'), findsNothing);
      expect(find.byKey(const Key('home-for-you')), findsNothing);
      expect(find.text('For you'), findsNothing);
    });

    testWidgets('a follow request can be declined', (tester) async {
      final api = HomeApi()
        ..activity = [
          request(
            'n2',
            type: 'follow',
            userId: miraId,
            username: 'mira',
            name: 'Mira',
          ),
        ];
      await launch(tester, api);
      expect(find.text('Mira wants to follow you 👋'), findsOneWidget);
      await tester.tap(find.byKey(const Key('home-decline-n2')));
      await tester.pumpAndSettle();
      expect(api.calls, contains('follow $miraId false'));
      expect(find.byKey(const Key('home-for-you')), findsNothing);
    });

    testWidgets('chats and activity get a card only when there is some', (
      tester,
    ) async {
      final api = HomeApi()
        ..activity = [request('n1'), reaction('a1'), reaction('a2')];
      await launch(tester, api, unread: 2);
      expect(find.text('2 chats waiting 💬'), findsOneWidget);
      // Three unread, one of them the request that has its own card.
      await reveal(tester, find.byKey(const Key('home-for-you')));
      await tester.drag(
        find.byKey(const Key('home-for-you')),
        const Offset(-600, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('2 new activity'), findsOneWidget);
    });

    testWidgets('a single unread chat reads naturally', (tester) async {
      await launch(tester, HomeApi(), unread: 1);
      expect(find.text('1 chat waiting 💬'), findsOneWidget);
    });
  });

  group('Finish your profile', () {
    testWidgets('is a slim pill that opens the editor', (tester) async {
      final launched = await launch(tester, HomeApi());
      expect(find.text('Finish your profile · 2/6'), findsOneWidget);
      await tester.tap(find.byKey(const Key('home-profile-nudge')));
      await tester.pumpAndSettle();
      expect(location(launched.container), '/profile/edit');
    });

    testWidgets('can be put away and stays away for that account', (
      tester,
    ) async {
      final prefs = MemoryHomePrefsStore();
      await launch(tester, HomeApi(), prefs: prefs);
      await tester.tap(find.byKey(const Key('home-profile-nudge-hide')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Finish your profile'), findsNothing);
      expect(prefs.hidden, {anjaliId});

      // A fresh start on the same device still has it put away.
      await tester.pumpWidget(const SizedBox());
      await launch(tester, HomeApi(), prefs: prefs);
      expect(find.textContaining('Finish your profile'), findsNothing);

      // Another account on this device is asked as usual.
      await tester.pumpWidget(const SizedBox());
      await launch(tester, HomeApi(), prefs: MemoryHomePrefsStore());
      expect(find.text('Finish your profile · 2/6'), findsOneWidget);
    });

    testWidgets('is gone once the profile is complete', (tester) async {
      await launch(tester, HomeApi()..complete = true);
      expect(find.textContaining('Finish your profile'), findsNothing);
    });
  });

  group('Pulse', () {
    testWidgets('switches between Your people and Everyone', (tester) async {
      final api = HomeApi()
        ..posts = [post('p1', body: 'from my people')]
        ..everyone = [post('e1', body: 'from everyone')];
      await launch(tester, api);
      expect(find.byKey(const Key('feed-mode')), findsOneWidget);
      expect(find.text('from my people'), findsOneWidget);
      expect(find.text('from everyone'), findsNothing);

      await tester.tap(find.byKey(const Key('feed-mode-everyone')));
      await tester.pumpAndSettle();
      expect(api.feedModes, contains('everyone'));
      expect(find.text('from everyone'), findsOneWidget);
      expect(find.text('from my people'), findsNothing);

      await tester.tap(find.byKey(const Key('feed-mode-following')));
      await tester.pumpAndSettle();
      expect(find.text('from my people'), findsOneWidget);
    });

    testWidgets('a quiet feed offers two ways to change that', (tester) async {
      final launched = await launch(tester, HomeApi());
      expect(find.text('Your Pulse is quiet 🌙'), findsOneWidget);
      expect(find.byKey(const Key('feed-empty')), findsOneWidget);

      await reveal(tester, find.byKey(const Key('feed-empty-share')));
      await tester.tap(find.byKey(const Key('feed-empty-share')));
      await tester.pumpAndSettle();
      expect(find.byType(ComposePostScreen), findsOneWidget);
      launched.container.read(routerProvider).go('/home');
      await tester.pumpAndSettle();

      await reveal(tester, find.byKey(const Key('feed-empty-find')));
      await tester.tap(find.byKey(const Key('feed-empty-find')));
      await tester.pumpAndSettle();
      expect(find.byType(FindPeopleScreen), findsOneWidget);
    });

    testWidgets('a feed that cannot load says so and retries', (tester) async {
      final api = _FlakyFeed();
      await launch(tester, api);
      expect(find.text('Let’s try that again'), findsOneWidget);
      api.fail = false;
      api.posts = [post('p1', body: 'back online')];
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('back online'), findsOneWidget);
    });

    testWidgets('suggestions land after the third post', (tester) async {
      final api = HomeApi()
        ..posts = [for (var i = 1; i <= 5; i++) post('p$i', body: 'post $i')];
      await launch(tester, api, size: const Size(390, 3600));
      double y(String key) => tester.getTopLeft(find.byKey(Key(key))).dy;
      expect(y('post-p3'), lessThan(y('home-suggestions')));
      expect(y('home-suggestions'), lessThan(y('post-p4')));
      expect(find.text('People you might vibe with'), findsOneWidget);
      // Home reuses Discover's unfiltered query rather than a wider one.
      expect(api.searches.single, {
        'interests': [],
        'languages': [],
        'country': '',
        'vibe': '',
      });
      // Never the viewer.
      expect(find.byKey(const Key('home-person-$anjaliId')), findsNothing);
      expect(find.text('1 in common'), findsNWidgets(2));
      expect(find.text('Film photos and late trains'), findsOneWidget);
    });

    testWidgets('a short feed ends with them', (tester) async {
      final api = HomeApi()
        ..posts = [post('p1', body: 'one'), post('p2', body: 'two')];
      await launch(tester, api, size: const Size(390, 3000));
      double y(String key) => tester.getTopLeft(find.byKey(Key(key))).dy;
      expect(y('post-p2'), lessThan(y('home-suggestions')));
    });

    testWidgets('Follow on a suggestion follows them', (tester) async {
      final api = HomeApi();
      await launch(tester, api);
      final follow = find.byKey(const Key('home-follow-$nikoId'));
      await reveal(tester, follow);
      await tester.tap(follow);
      await tester.pumpAndSettle();
      expect(api.calls, contains('follow-user $nikoId'));
      expect(
        find.descendant(of: follow, matching: find.text('Following')),
        findsOneWidget,
      );
    });
  });

  group('Create', () {
    testWidgets('one pill opens the create sheet and folds on scroll', (
      tester,
    ) async {
      final api = HomeApi()
        ..posts = [for (var i = 1; i <= 8; i++) post('p$i', photo: i.isOdd)];
      await launch(tester, api);
      final create = find.byKey(const Key('home-create'));
      expect(create, findsOneWidget);
      // The hint names only what exists: Moments are off for V1 (the events flag).
      expect(FeatureFlags.events, isFalse);
      expect(
        tester.widget<PressScale>(create).semanticHint,
        'Post, story or circle',
      );
      expect(
        find.descendant(of: create, matching: find.text('Create')),
        findsOneWidget,
      );

      await tester.drag(homeScrollable, const Offset(0, -500));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: create, matching: find.text('Create')),
        findsNothing,
      );
      await tester.drag(homeScrollable, const Offset(0, 200));
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: create, matching: find.text('Create')),
        findsOneWidget,
      );

      await tester.tap(create);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('create-post')), findsOneWidget);
      expect(find.byKey(const Key('create-story')), findsOneWidget);
    });
  });

  group('Layout', () {
    testWidgets('wide screens get a feed column and a right rail', (
      tester,
    ) async {
      final api = HomeApi()
        ..activity = [request('n1')]
        ..posts = [post('p1', body: 'hello feed')];
      await launch(tester, api, size: const Size(1280, 800));
      final rail = find.byKey(const Key('home-rail'));
      expect(rail, findsOneWidget);
      final feedX = tester.getTopLeft(find.byKey(const Key('post-p1'))).dx;
      final railX = tester.getTopLeft(rail).dx;
      expect(feedX, lessThan(railX));
      // The feed column is capped; the rail holds the vibe strip, For you and
      // the suggestions.
      expect(
        tester.getSize(find.byKey(const Key('post-p1'))).width,
        lessThan(641),
      );
      expect(
        find.descendant(
          of: rail,
          matching: find.byKey(const Key('vibe-sleepy')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: rail,
          matching: find.byKey(const Key('home-for-you')),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: rail,
          matching: find.byKey(const Key('home-suggestions')),
        ),
        findsOneWidget,
      );
      // Suggestions are not also dropped into the feed.
      expect(find.byKey(const Key('home-suggestions')), findsOneWidget);
      // The shell header carries the greeting here, so it is said once.
      expect(find.byKey(const Key('home-greeting')), findsNothing);
      expect(find.text('gm Anjali ☀️'), findsOneWidget);
    });

    testWidgets('phones are a single column', (tester) async {
      await launch(tester, HomeApi());
      expect(find.byKey(const Key('home-rail')), findsNothing);
      expect(find.byKey(const Key('home-greeting')), findsOneWidget);
    });
  });

  group('Motion', () {
    testWidgets('reduced motion shows sections without entrance animation', (
      tester,
    ) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await launch(tester, HomeApi()..posts = [post('p1')]);
      expect(
        find.descendant(
          of: find.byType(StaggerIn),
          matching: find.byType(TweenAnimationBuilder<double>),
        ),
        findsNothing,
      );
      expect(find.byKey(const Key('home-greeting')), findsOneWidget);
    });

    testWidgets('normally sections ease in', (tester) async {
      await launch(tester, HomeApi());
      expect(
        find.descendant(
          of: find.byType(StaggerIn),
          matching: find.byType(TweenAnimationBuilder<double>),
        ),
        findsWidgets,
      );
    });
  });

  group('Appearance', () {
    testWidgets('light theme renders the busy Home', (tester) async {
      final api = busyApi();
      final launched = await launch(tester, api, unread: 2);
      launched.container.read(themeProvider.notifier).toggle(false);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('home-for-you')), findsOneWidget);
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
      expect(
        scaffold.backgroundColor ??
            Theme.of(tester.element(find.byType(Scaffold).first))
                .scaffoldBackgroundColor,
        VibeColors.cream,
      );
      await reveal(tester, find.byKey(const Key('post-p3')));
      expect(tester.takeException(), isNull);
    });

    for (final (size, scale) in [
      (const Size(390, 844), 1.3),
      (const Size(320, 640), 2.0),
    ]) {
      testWidgets('text at $scale on $size does not overflow', (tester) async {
        final launched = await launch(
          tester,
          busyApi(),
          size: size,
          textScale: scale,
          unread: 12,
        );
        for (final dark in [true, false]) {
          launched.container.read(themeProvider.notifier).toggle(dark);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          for (var i = 0; i < 6; i++) {
            await tester.drag(homeScrollable, Offset(0, -size.height * .6));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          }
          await tester.drag(homeScrollable, const Offset(0, 20000));
          await tester.pumpAndSettle();
        }
      });
    }
  });

  if (const bool.fromEnvironment('CAPTURE_HOME')) {
    group('Preview renders', () {
      testWidgets('dark, busy account', (tester) async {
        await capture(tester, 'dark-busy-390x844', busyApi(), unread: 2);
      });
      testWidgets('dark, busy account, scrolled', (tester) async {
        await capture(
          tester,
          'dark-busy-390x844-scrolled',
          busyApi(),
          unread: 2,
          scroll: 640,
        );
      });
      testWidgets('dark, busy account, suggestions', (tester) async {
        await capture(
          tester,
          'dark-busy-390x844-suggestions',
          busyApi(),
          unread: 2,
          scroll: 1950,
        );
      });
      testWidgets('dark, empty account', (tester) async {
        await capture(tester, 'dark-empty-390x844', emptyApi());
      });
      testWidgets('light, busy account', (tester) async {
        await capture(
          tester,
          'light-busy-390x844',
          busyApi(),
          unread: 2,
          dark: false,
        );
      });
      testWidgets('light, busy account, scrolled', (tester) async {
        await capture(
          tester,
          'light-busy-390x844-scrolled',
          busyApi(),
          unread: 2,
          dark: false,
          scroll: 640,
        );
      });
      testWidgets('wide, busy account', (tester) async {
        await capture(
          tester,
          'dark-busy-1280x800',
          busyApi(),
          unread: 2,
          size: const Size(1280, 800),
        );
      });
      testWidgets('wide, light, empty account', (tester) async {
        await capture(
          tester,
          'light-empty-1280x800',
          emptyApi(),
          dark: false,
          size: const Size(1280, 800),
        );
      });
    });
  }
}

class _FlakyFeed extends HomeApi {
  bool fail = true;
  @override
  Future<ApiPage<Post>> feed(Session s, String mode, [String? cursor]) async {
    if (fail) throw const ApiFailure('No connection.', 400);
    return super.feed(s, mode, cursor);
  }
}

HomeApi busyApi() => HomeApi()
  ..vibe = '🎧 Vibing'
  ..activity = [
    request('n1', name: 'Mira', userId: miraId, username: 'mira'),
    request('n2', type: 'follow'),
    reaction('a1'),
    reaction('a2'),
    reaction('a3'),
  ]
  ..stories = [
    StoryGroup(me, [
      Story(
        storyId: 'm1',
        body: 'mine',
        background: 'sunset',
        audience: 'friends',
        createdAt: DateTime.now(),
        expiresAt: DateTime.now().add(const Duration(hours: 20)),
      ),
    ], mine: true),
    for (final (i, p) in [
      (0, niko),
      (1, mira),
      (2, const Person('u3', 'dev', 'Dev')),
      (3, const Person('u4', 'ines', 'Inès')),
      (4, const Person('u5', 'kai', 'Kai')),
    ])
      StoryGroup(p, [
        Story(
          storyId: 's$i',
          body: 'gm',
          background: 'aurora',
          audience: 'friends',
          createdAt: DateTime.now(),
          expiresAt: DateTime.now().add(const Duration(hours: 20)),
        ),
      ], allSeen: i == 2),
  ]
  ..posts = [
    post(
      'p1',
      body: 'Golden hour on the roof, no filter needed.',
      author: mira,
      photo: true,
      reactions: 24,
      comments: 6,
    ),
    post(
      'p2',
      body: 'Anyone else obsessed with this album right now?',
      reactions: 8,
    ),
    post(
      'p3',
      body: 'Sunday reset: laundry, long walk, one good playlist.',
      photo: true,
      reactions: 41,
      comments: 12,
    ),
    post(
      'p4',
      body:
          'Trying to learn guitar again. Any tips for a beginner who keeps '
          'quitting after two weeks?',
      author: mira,
      reactions: 5,
      comments: 9,
    ),
    post('p5', body: 'new fit', photo: true, reactions: 3),
  ];

HomeApi emptyApi() => HomeApi();

/// Draws a soft gradient "photo" so previews have something to look at.
Future<ImageProvider> photoOf(List<Color> colors, int w, int h) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final rect = Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble());
  canvas.drawRect(
    rect,
    Paint()
      ..shader = ui.Gradient.linear(rect.topLeft, rect.bottomRight, colors, [
        for (var i = 0; i < colors.length; i++) i / (colors.length - 1),
      ]),
  );
  canvas.drawCircle(
    Offset(w * .72, h * .3),
    w * .16,
    Paint()..color = Colors.white.withValues(alpha: .55),
  );
  final image = await recorder.endRecording().toImage(w, h);
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
  image.dispose();
  return MemoryImage(Uint8List.view(bytes.buffer));
}

Future<void> capture(
  WidgetTester tester,
  String name,
  HomeApi api, {
  Size size = const Size(390, 844),
  bool dark = true,
  int unread = 0,
  double scroll = 0,
}) async {
  final photos = (await tester.runAsync(
    () async => [
      await photoOf(
        const [Color(0xffff9a62), Color(0xffff5c8a), Color(0xff8a4fd6)],
        800,
        1000,
      ),
      await photoOf(
        const [Color(0xff2dd4bf), Color(0xff6366f1), Color(0xffa855f7)],
        800,
        1000,
      ),
      await photoOf(
        const [Color(0xfffde047), Color(0xfffb923c), Color(0xffef4444)],
        800,
        1000,
      ),
    ],
  ))!;
  final saved = postPhotoFactory;
  postPhotoFactory = (url, key) => photos[url.hashCode.abs() % photos.length];
  addTearDown(() => postPhotoFactory = saved);
  final savedAvatars = PersonAvatar.imageFactory;
  addTearDown(() => PersonAvatar.imageFactory = savedAvatars);

  final capture = GlobalKey();
  final launched = await launch(
    tester,
    api,
    size: size,
    unread: unread,
    wrap: (app) => RepaintBoundary(key: capture, child: app),
  );
  launched.container.read(themeProvider.notifier).toggle(dark);
  await tester.pumpAndSettle();
  // Let the generated photos decode, which needs real time.
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 300)),
  );
  await tester.pumpAndSettle();
  if (scroll > 0) {
    await tester.drag(homeScrollable, Offset(0, -scroll));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();
  }
  expect(tester.takeException(), isNull);
  void repaint(RenderObject render) {
    render.markNeedsPaint();
    render.visitChildren(repaint);
  }

  repaint(capture.currentContext!.findRenderObject()!);
  await tester.pump();
  await tester.runAsync(() async {
    final boundary =
        capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final img = await boundary.toImage(pixelRatio: 2);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    final file = File('../../.runtime/home-previews/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    img.dispose();
  });
}
