import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/features/spaces.dart' show SpaceCard;

import 'people_lists_test.dart' show ListsApi, ago;
import 'reliability_ui_test.dart' show open;
import 'spaces_test.dart' show SpacesFake, circle;

import 'package:hiyall/shared/person_avatar.dart';

class _ManyPeople extends ListsApi {
  _ManyPeople() {
    followersList = [
      for (var i = 0; i < 300; i++)
        Connection(
          Person('u-$i', 'user$i', 'Person $i'),
          ago(Duration(hours: i)),
          'none',
        ),
    ];
  }
}

class _ManySpaces extends SpacesFake {
  @override
  Future<ApiPage<SocialSpace>> spaces(
    Session s,
    String kind, {
    String? cursor,
    String? parentId,
    bool mine = false,
  }) async => ApiPage([
    for (var i = 0; i < 300; i++)
      SocialSpace(
        spaceId: 's$i',
        kind: 'community',
        title: 'Circle $i',
        owner: const Person('u-o', 'owner', 'Owner'),
        createdAt: DateTime.utc(2026, 10, 9),
      ),
  ], null);
}

void main() {
  testWidgets('a long people list builds only the rows near the screen', (
    tester,
  ) async {
    await open(tester, _ManyPeople(), '/profile/followers');
    expect(find.text('Person 0'), findsOneWidget);
    final built = find.byType(PersonAvatar).evaluate().length;
    expect(built, lessThan(40), reason: 'not all 300 rows');
    // Scrolling reaches the rest.
    await tester.scrollUntilVisible(
      find.text('Person 120'),
      600,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Person 120'), findsOneWidget);
    expect(find.text('Person 0'), findsNothing, reason: 'rows scroll away');
  });

  testWidgets('a long Spaces list builds only the cards near the screen', (
    tester,
  ) async {
    final api = _ManySpaces()..blocked = false;
    await open(tester, api, '/spaces');
    expect(find.text('Circle 0'), findsOneWidget);
    expect(find.byType(SpaceCard).evaluate().length, lessThan(30));
    await tester.scrollUntilVisible(
      find.text('Circle 150'),
      600,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Circle 150'), findsOneWidget);
    expect(circle().spaceId, 'circle');
  });
}
