import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/features/discovery.dart';

import 'widget_test.dart' show FakeApi, SignedIn;

class CursorApi extends FakeApi {
  final sentCursors = <Object?>[];
  bool expireCursor = true;
  final gone = <String>{};
  @override
  Future<Map<String, dynamic>> searchPeople(
    Session s,
    Map<String, dynamic> filters,
  ) async {
    sentCursors.add(filters['cursor']);
    final page = filters['cursor'] == null ? 0 : 1;
    if (page == 1 && expireCursor) {
      // Cursors last 15 minutes; the server answers 422 INVALID_CURSOR.
      throw const ApiFailure(
        'Results changed. Showing the newest.',
        422,
        'INVALID_CURSOR',
      );
    }
    return {
      'items': [
        for (var i = 0; i < 12; i++)
          {
            'userId': 'u$page-$i',
            'username': 'user$page$i',
            'displayName': 'User $page-$i',
          },
      ],
      'nextCursor': page == 0 ? 'page-2' : null,
    };
  }

  @override
  Future<Profile> otherProfile(Session session, String userId) async {
    if (gone.contains(userId)) {
      throw const ApiFailure('This profile is unavailable.', 404);
    }
    return Profile(
      userId: userId,
      username: userId,
      displayName: userId,
      bio: '',
      profession: '',
      version: '',
    );
  }
}

Future<void> pumpDiscovery(WidgetTester tester, CursorApi api) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  // As in the app: the list lives at /discover, profiles open below it.
  final router = GoRouter(
    initialLocation: '/discover',
    routes: [
      GoRoute(
        path: '/discover',
        builder: (_, _) => const Scaffold(body: PeopleDiscovery()),
      ),
      GoRoute(
        path: '/discover/person/:id',
        builder: (context, state) => Scaffold(
          body: TextButton(
            onPressed: () => context.pop(),
            child: Text('Leave ${state.pathParameters['id']}'),
          ),
        ),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiProvider.overrideWithValue(api),
        sessionProvider.overrideWith(SignedIn.new),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

Finder get results => find
    .descendant(
      of: find.byKey(const Key('discovery-results-scroll')),
      matching: find.byType(Scrollable),
    )
    .first;

void main() {
  testWidgets('An expired cursor starts a fresh search instead of resending', (
    tester,
  ) async {
    final api = CursorApi();
    await pumpDiscovery(tester, api);
    final more = find.text('Explore more people');
    await tester.scrollUntilVisible(more, 300, scrollable: results);
    await tester.pumpAndSettle();
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(api.sentCursors, [null, 'page-2', null]);
    expect(find.text('Try again'), findsNothing);
    expect(find.text('Results changed. Showing the newest.'), findsNothing);
    // The fresh first page offers a new, valid cursor.
    api.expireCursor = false;
    await tester.scrollUntilVisible(more, 300, scrollable: results);
    await tester.pumpAndSettle();
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(api.sentCursors.last, 'page-2');
    expect(find.text('User 1-0', skipOffstage: false), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Returning from a profile keeps the list and scroll position', (
    tester,
  ) async {
    final api = CursorApi()..expireCursor = false;
    await pumpDiscovery(tester, api);
    final more = find.text('Explore more people');
    await tester.scrollUntilVisible(more, 300, scrollable: results);
    await tester.pumpAndSettle();
    await tester.tap(more);
    await tester.pumpAndSettle();
    final target = find.text('User 1-3');
    await tester.scrollUntilVisible(target, 300, scrollable: results);
    await tester.pumpAndSettle();
    final offset = tester.state<ScrollableState>(results).position.pixels;
    final searches = api.sentCursors.length;
    await tester.tap(target);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Leave u1-3'));
    await tester.pumpAndSettle();
    expect(api.sentCursors.length, searches);
    expect(tester.state<ScrollableState>(results).position.pixels, offset);
    expect(find.text('User 1-3'), findsOneWidget);

    // Someone blocked or gone while open drops out of the list quietly.
    api.gone.add('u1-3');
    await tester.tap(find.text('User 1-3'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Leave u1-3'));
    await tester.pumpAndSettle();
    expect(find.text('User 1-3', skipOffstage: false), findsNothing);
    expect(api.sentCursors.length, searches);
    expect(tester.takeException(), isNull);
  });
}
