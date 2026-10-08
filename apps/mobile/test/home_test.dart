import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kairova/app.dart';
import 'package:kairova/core/api.dart';
import 'package:kairova/core/state.dart';
import 'package:kairova/features/home.dart';

import 'widget_test.dart' show FakeApi, SignedIn;

class HomeApi extends FakeApi {
  final searches = <Map<String, dynamic>>[];
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
      ],
      'nextCursor': null,
    };
  }

  @override
  Future<Profile> profile(Session s) async => const Profile(
    userId: anjaliId,
    username: 'anjali',
    displayName: 'Anjali',
    bio: 'A new beginning',
    profession: '',
    version: '1',
    interests: ['Music'],
  );
}

void main() {
  test('Greeting follows the time of day', () {
    expect(greetingFor(DateTime(2026, 1, 1, 8)), 'GOOD MORNING');
    expect(greetingFor(DateTime(2026, 1, 1, 14)), 'GOOD AFTERNOON');
    expect(greetingFor(DateTime(2026, 1, 1, 20)), 'GOOD EVENING');
    expect(greetingFor(DateTime(2026, 1, 1, 2)), 'STILL UP');
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

  testWidgets('Home shows live counts, answers requests and suggests people', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final api = HomeApi()
      ..activity = [
        {
          'notificationId': 'n1',
          'type': 'friend_request',
          'actors': [
            {'userId': nikoId, 'username': 'niko', 'displayName': 'Niko'},
          ],
          'targetType': 'request',
          'targetId': 'fr1',
          'createdAt': DateTime.now().toUtc().toIso8601String(),
          'text': 'Niko sent you a friend request',
        },
      ];
    final container = ProviderContainer(
      overrides: [
        apiProvider.overrideWithValue(api),
        sessionProvider.overrideWith(SignedIn.new),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const KairovaApp(),
      ),
    );
    container.read(routerProvider).go('/home');
    await tester.pumpAndSettle();

    expect(find.text('Hey, Anjali.'), findsOneWidget);
    expect(find.bySemanticsLabel('1 request'), findsOneWidget);
    expect(find.bySemanticsLabel('1 activity'), findsOneWidget);
    expect(find.text('Niko sent you a friend request'), findsOneWidget);

    await tester.tap(find.byKey(const Key('home-accept-n1')));
    await tester.pumpAndSettle();
    expect(api.calls, contains('friend fr1 true'));
    expect(find.text('Niko sent you a friend request'), findsNothing);
    expect(find.bySemanticsLabel('0 requests'), findsOneWidget);

    final card = find.byKey(const Key('home-person-$nikoId'));
    await tester.scrollUntilVisible(
      card,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-person-$anjaliId')), findsNothing);
    // Home reuses Discover's unfiltered query rather than a wider one.
    expect(api.searches.single, {
      'interests': [],
      'languages': [],
      'country': '',
      'vibe': '',
    });
    expect(find.text('1 shared interest'), findsOneWidget);
    expect(find.text('Film photos and late trains'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
