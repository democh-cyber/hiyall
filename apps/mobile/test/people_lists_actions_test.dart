import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/features/people_lists.dart';

import 'people_lists_test.dart' show ListsApi, mira;
import 'widget_test.dart' show SignedIn;

ProviderContainer containerWith(ListsApi api, {bool signedIn = true}) {
  final container = ProviderContainer(
    overrides: [
      apiProvider.overrideWithValue(api),
      if (signedIn) sessionProvider.overrideWith(SignedIn.new),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('reads lists and acts through the overridden api', () async {
    final api = ListsApi();
    final actions = containerWith(api).read(peopleListsActionsProvider);

    expect(actions.hasSession, isTrue);
    final following = await actions.connections('following');
    expect(following.items.map((c) => c.user.userId), contains('u-mira'));
    expect((await actions.visitors(null)).items, hasLength(2));
    expect((await actions.myStories(null)).items, hasLength(2));

    await actions.unfollow(mira.userId);
    expect(await actions.follow(mira.userId), 'active');
    await actions.removeFollower(mira.userId);
    expect(
      api.log,
      containsAllInOrder([
        'connections following me',
        'unfollow u-mira',
        'follow u-mira',
        'remove-follower u-mira',
      ]),
    );
  });

  test('story viewers come back as people', () async {
    final actions = containerWith(ListsApi()).read(peopleListsActionsProvider);
    final page = await actions.storyViewers('s1', null);
    expect(page.items.single.user.userId, 'u-ravi');
    expect(page.nextCursor, isNull);
  });

  test('signed out: hasSession is false and calls fail plainly', () async {
    final actions = containerWith(
      ListsApi(),
      signedIn: false,
    ).read(peopleListsActionsProvider);
    expect(actions.hasSession, isFalse);
    expect(() => actions.visitors(null), throwsA(isA<ApiFailure>()));
  });
}
