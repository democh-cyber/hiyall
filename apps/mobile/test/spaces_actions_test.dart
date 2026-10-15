import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/state.dart' show apiProvider;
import 'package:hiyall/features/spaces/spaces_actions.dart';

import 'spaces_test.dart' show SpacesFake;
import 'support/fixtures.dart';

/// Records the arguments each Spaces call receives.
class _Recording extends SpacesFake {
  final seen = <String>[];

  @override
  Future<ApiPage<SocialSpace>> spaces(
    Session s,
    String kind, {
    String? cursor,
    String? parentId,
    bool mine = false,
  }) {
    seen.add('spaces $kind $cursor $parentId $mine');
    return super.spaces(
      s,
      kind,
      cursor: cursor,
      parentId: parentId,
      mine: mine,
    );
  }

  @override
  Future<SocialSpace> updateSpace(
    Session s,
    String id,
    Map<String, dynamic> body,
  ) async {
    seen.add('update $id ${body['title']}');
    return current;
  }

  @override
  Future<SocialSpace> spaceStatus(Session s, String id, String status) async {
    seen.add('status $id $status');
    return current;
  }

  @override
  Future<void> inviteSpaceUser(Session s, String id, String username) async {
    seen.add('invite $id $username');
  }

  @override
  Future<ApiPage<SpaceEntry>> spaceEntries(
    Session s,
    String id, [
    String? cursor,
  ]) async {
    seen.add('entries $id $cursor');
    return const ApiPage([], null);
  }

  @override
  Future<void> addSpaceEntry(Session s, String id, String text) async {
    seen.add('add $id $text');
  }

  @override
  Future<void> deleteSpaceEntry(Session s, String id, String entry) async {
    seen.add('delete $id $entry');
  }

  @override
  Future<SocialSpace> spaceMembership(
    Session s,
    String id, {
    bool join = true,
    String rsvp = 'going',
  }) async {
    seen.add('membership $id $join $rsvp');
    return current;
  }
}

void main() {
  const session = Session('test-only-token', anjaliId);

  test('SpaceActions forwards each call to the current apiProvider', () async {
    final api = _Recording();
    final c = ProviderContainer(
      overrides: [apiProvider.overrideWithValue(api)],
    );
    addTearDown(c.dispose);
    final a = c.read(spaceActionsProvider);

    await a.list(session, 'event', parentId: 'p', cursor: 'c', mine: true);
    await a.get(session, 'circle');
    await a.update(session, 'circle', {'title': 'New name'});
    await a.membership(session, 'circle', join: false);
    await a.membership(session, 'circle', rsvp: 'interested');
    await a.setStatus(session, 'circle', 'closed');
    await a.members(session, 'circle', state: 'pending');
    await a.invite(session, 'circle', 'niko');
    await a.memberAction(session, 'circle', 'u1', 'ban');
    await a.entries(session, 'circle', 'older');
    await a.addEntry(session, 'circle', 'hello');
    await a.deleteEntry(session, 'circle', 'e1');

    expect(api.seen, [
      'spaces event c p true',
      'update circle New name',
      'membership circle false going',
      'membership circle true interested',
      'status circle closed',
      'invite circle niko',
      'entries circle older',
      'add circle hello',
      'delete circle e1',
    ]);
    expect(api.calls, contains('member ban'));
  });
}
