import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hiyall/app.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/realtime/realtime_client.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/shared/navigation_dock.dart';

class SignedIn extends SessionController {
  @override
  AsyncValue<Session?> build() =>
      const AsyncData(Session('test-only-token', anjaliId));
}

class FakeApi extends ApiClient {
  Map<String, dynamic>? saved;
  bool failSave = false;
  bool blocked = true;
  bool? requestedBlock;
  int profileReads = 0;
  @override
  Future<Profile> otherProfile(Session session, String userId) async {
    if (blocked) throw const ApiFailure("This profile is unavailable.", 404);
    return Profile(
      userId: userId,
      username: "niko",
      displayName: "Niko",
      bio: "",
      profession: "",
      version: "",
    );
  }

  @override
  Future<void> block(Session session, String userId, bool value) async {
    requestedBlock = value;
    blocked = value;
  }

  // Widget tests never open network sockets.
  @override
  RealtimeClient? realtime(Session s) => null;

  List<Post> posts = [];
  List<StoryGroup> stories = [];
  @override
  Future<ApiPage<Post>> feed(Session s, String mode, [String? cursor]) async =>
      ApiPage(posts, null);
  @override
  Future<List<StoryGroup>> storyTray(Session s) async => stories;
  @override
  Future<ApiPage<Post>> userPosts(
    Session s,
    String userId, [
    String? cursor,
  ]) async => ApiPage([
    for (final p in posts)
      if (p.author.userId == userId) p,
  ], null);

  List<Map<String, dynamic>> activity = [];
  final calls = <String>[];
  @override
  Future<(ApiPage<Map<String, dynamic>>, int)> notifications(
    Session s, [
    String? cursor,
  ]) async => (
    ApiPage(activity, null),
    activity.where((i) => i['readAt'] == null).length,
  );
  @override
  Future<int> unreadNotifications(Session s) async =>
      activity.where((i) => i['readAt'] == null).length;
  @override
  Future<void> markNotificationRead(Session s, String id) async =>
      calls.add('read $id');
  @override
  Future<void> markAllNotificationsRead(Session s) async =>
      calls.add('read-all');
  @override
  Future<void> respondFriendRequest(
    Session s,
    String requestId,
    bool accept,
  ) async => calls.add('friend $requestId $accept');
  @override
  Future<void> respondFollowRequest(
    Session s,
    String followerId,
    bool accept,
  ) async => calls.add('follow $followerId $accept');

  @override
  Future<Map<String, dynamic>> searchPeople(
    Session s,
    Map<String, dynamic> filters,
  ) async => {'items': <Object>[], 'nextCursor': null};

  @override
  Future<Profile> profile(Session s) async {
    profileReads++;
    return const Profile(
      userId: anjaliId,
      username: 'anjali',
      displayName: 'Anjali',
      bio: 'A new beginning',
      socialStats: ProfileSocialStats(friends: 0, following: 0, followers: 0),
      profession: '',
      version: '1',
    );
  }

  @override
  Future<Privacy> privacy(Session s) async => Privacy({
    'version': '1',
    'profileAudience': 'friends',
    'messagesFrom': 'friends',
    'followPolicy': 'approval',
    'requestsFrom': 'everyone',
    'storyAudience': 'friends',
    'activityAudience': 'nobody',
    'onlineAudience': 'nobody',
    'lastSeenAudience': 'nobody',
    'locationAudience': 'nobody',
    'commentsFrom': 'friends',
    'mentionsFrom': 'friends',
    'discoverable': false,
    'showInterestOverlap': false,
    'readReceipts': false,
    'fieldAudiences': {
      for (final key in [
        'pronouns',
        'location',
        'profession',
        'education',
        'website',
        'timezone',
        'languages',
        'interests',
        'vibe',
        'connections',
      ])
        key: 'nobody',
    },
  });
  @override
  Future<Privacy> updatePrivacy(
    Session s,
    Privacy p,
    Map<String, dynamic> patch,
  ) async {
    if (failSave) throw const ApiFailure('Offline');
    saved = patch;
    return Privacy({...p.values, ...patch, 'version': '2'});
  }
}

Future<void> launch(
  WidgetTester tester,
  FakeApi api, {
  double textScale = 1,
  List<Override> overrides = const [],
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiProvider.overrideWithValue(api),
        sessionProvider.overrideWith(SignedIn.new),
        ...overrides,
      ],
      child: Builder(
        builder: (context) => MediaQuery(
          data: MediaQueryData(
            size: const Size(390, 844),
            textScaler: TextScaler.linear(textScale),
          ),
          child: const HiyallApp(),
        ),
      ),
    ),
  );
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
  testWidgets(
    'Five destinations; chat fails closed without the encryption core',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await launch(tester, FakeApi());
      expect(find.byType(DockDestination), findsNWidgets(5));
      await tester.tap(find.widgetWithText(DockDestination, 'Chats'));
      await tester.pumpAndSettle();
      // The native library isn't loaded in widget tests: no plaintext fallback, no composer.
      expect(find.textContaining('encryption'), findsWidgets);
      expect(find.byType(TextField), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('The online toggle saves only the online audience', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = FakeApi();
    await launch(tester, api);
    GoRouter.of(tester.element(find.byType(Scaffold).first))
        .go('/profile/settings');
    await tester.pumpAndSettle();
    final toggle = find.byKey(const Key('online-toggle'));
    expect(toggle, findsOneWidget);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(api.saved, {'onlineAudience': 'everyone'});
    expect(tester.takeException(), isNull);
  });
  testWidgets('A failed online change says so and leaves the switch alone', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = FakeApi()..failSave = true;
    await launch(tester, api);
    GoRouter.of(tester.element(find.byType(Scaffold).first))
        .go('/profile/settings');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('online-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('Offline'), findsOneWidget);
    expect(
      tester
          .widget<SwitchListTile>(find.byKey(const Key('online-toggle')))
          .value,
      isFalse,
    );
    expect(api.saved, isNull);
  });
  testWidgets('A hidden account can be unblocked from its profile screen', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = FakeApi();
    await launch(tester, api);
    await tester.tap(find.widgetWithText(DockDestination, 'Discover'));
    await tester.pumpAndSettle();
    final results = find
        .descendant(
          of: find.byKey(const Key('discovery-results-scroll')),
          matching: find.byType(Scrollable),
        )
        .first;
    final internal = find.text('Internal profile preview');
    await tester.scrollUntilVisible(internal, 300, scrollable: results);
    await tester.pumpAndSettle();
    await tester.tap(internal);
    await tester.pumpAndSettle();
    final view = find.text('View Niko’s profile');
    await tester.scrollUntilVisible(view, 300, scrollable: results);
    await tester.pumpAndSettle();
    await tester.ensureVisible(view);
    await tester.pumpAndSettle();
    await tester.tap(view);
    await tester.pumpAndSettle();
    expect(find.text('This profile is unavailable.'), findsOneWidget);
    final beforeUnblock = api.profileReads;
    final undo = find.text('Remove my block on this account');
    await tester.ensureVisible(undo);
    await tester.tap(undo);
    await tester.pumpAndSettle();
    expect(api.requestedBlock, false);
    expect(api.profileReads, greaterThan(beforeUnblock));
    expect(find.text('Niko'), findsAtLeastNWidgets(1));
    expect(tester.takeException(), isNull);
  }, skip: !devLoginEnabled);
  testWidgets('Home remains scrollable at double text size', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await launch(tester, FakeApi(), textScale: 2);
    expect(find.byKey(const Key('home-scroll')), findsOneWidget);
  });
}
