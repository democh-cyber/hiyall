import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kairova/app.dart';
import 'package:kairova/core/api.dart';
import 'package:kairova/core/state.dart';

import 'widget_test.dart' show FakeApi, SignedIn;

/// A server stand-in that keeps one relationship and applies each action to it.
class GraphApi extends FakeApi {
  Relationship relationship;
  bool private;
  GraphApi(this.relationship, {this.private = false});
  final log = <String>[];

  @override
  Future<Profile> otherProfile(Session session, String userId) async {
    final friends = relationship.friendship == 'accepted';
    return Profile(
      userId: userId,
      username: 'niko',
      displayName: 'Niko',
      bio: 'hello there',
      profession: '',
      version: '',
      relationship: relationship,
      locked: private && !friends,
    );
  }

  @override
  Future<String> sendFriendRequest(Session s, String userId) async {
    log.add('friend-request');
    relationship = relationship.copyWith(
      friendship: 'pending_outgoing',
      friendRequestId: () => 'req-1',
    );
    return 'req-1';
  }

  @override
  Future<void> cancelFriendRequest(Session s, String requestId) async {
    log.add('cancel $requestId');
    relationship = relationship.copyWith(
      friendship: 'none',
      friendRequestId: () => null,
    );
  }

  @override
  Future<void> respondFriendRequest(
    Session s,
    String requestId,
    bool accept,
  ) async {
    log.add('respond $requestId $accept');
    relationship = relationship.copyWith(
      friendship: accept ? 'accepted' : 'none',
      friendRequestId: () => null,
    );
  }

  @override
  Future<String> follow(Session s, String userId) async {
    log.add('follow');
    relationship = relationship.copyWith(following: 'pending');
    return 'pending';
  }
}

Future<ProviderContainer> open(WidgetTester tester, GraphApi api) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final container = ProviderContainer(
    overrides: [
      apiProvider.overrideWithValue(api),
      sessionProvider.overrideWith(SignedIn.new),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const KairovaApp()),
  );
  container.read(routerProvider).go('/discover/person/$nikoId');
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('A locked profile shows identity only and lets you ask in', (
    tester,
  ) async {
    final api = GraphApi(
      const Relationship(canFollow: true, canFriendRequest: true),
      private: true,
    );
    await open(tester, api);
    expect(find.text('This space is private'), findsOneWidget);
    expect(find.text('hello there'), findsNothing);
    expect(find.text('@niko'), findsOneWidget);

    await tester.tap(find.byKey(const Key('add-friend')));
    await tester.pumpAndSettle();
    expect(api.log, ['friend-request']);
    expect(find.byKey(const Key('cancel-friend')), findsOneWidget);
    expect(find.text('Friend request sent.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('follow')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('follow-requested')), findsOneWidget);
    expect(find.text('Follow request sent.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('cancel-friend')));
    await tester.pumpAndSettle();
    expect(api.log.last, 'cancel req-1');
    expect(find.byKey(const Key('add-friend')), findsOneWidget);
  });

  testWidgets(
    'An incoming request is answered from the profile and unlocks it',
    (tester) async {
      final api = GraphApi(
        const Relationship(
          friendship: 'pending_incoming',
          friendRequestId: 'req-9',
          followedBy: true,
          canFollow: true,
        ),
        private: true,
      );
      await open(tester, api);
      expect(find.text('This space is private'), findsOneWidget);
      expect(find.text('Follow back'), findsOneWidget);
      await tester.tap(find.byKey(const Key('accept-friend')));
      await tester.pumpAndSettle();
      expect(api.log, ['respond req-9 true']);
      expect(find.text('This space is private'), findsNothing);
      expect(find.byKey(const Key('friends')), findsOneWidget);
      expect(find.byKey(const Key('message-person')), findsOneWidget);
    },
  );
}
