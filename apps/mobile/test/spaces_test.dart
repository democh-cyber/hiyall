import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kairova/core/api.dart';
import 'package:kairova/core/state.dart';
import 'package:kairova/features/spaces.dart';

import 'widget_test.dart' show FakeApi, SignedIn;

SocialSpace circle({
  String state = '',
  String role = '',
  bool discuss = false,
  String kind = 'community',
}) => SocialSpace(
  spaceId: 'circle',
  kind: kind,
  title: 'After-hours book club',
  owner: const Person(nikoId, 'niko', 'Niko'),
  createdAt: DateTime.utc(2026, 10, 9),
  description: 'Bring one favourite book',
  myState: state,
  myRole: role,
  canDiscuss: discuss,
  myRsvp: 'going',
);

class SpacesFake extends FakeApi {
  SocialSpace current = circle();
  bool fail = false;
  final notes = <SpaceEntry>[];
  Map<String, dynamic>? created;
  @override
  Future<ApiPage<SocialSpace>> spaces(
    Session s,
    String kind, {
    String? cursor,
    String? parentId,
    bool mine = false,
  }) async {
    calls.add('spaces $kind $mine');
    if (fail) throw const ApiFailure('Offline');
    return ApiPage([current], null);
  }

  @override
  Future<SocialSpace> space(Session s, String id) async {
    if (fail) throw const ApiFailure('Access removed', 404);
    return current;
  }

  @override
  Future<SocialSpace> spaceMembership(
    Session s,
    String id, {
    bool join = true,
    String rsvp = 'going',
  }) async {
    calls.add('join $join $rsvp');
    current = circle(state: 'active', discuss: true);
    return current;
  }

  @override
  Future<ApiPage<SpaceEntry>> spaceEntries(
    Session s,
    String id, [
    String? cursor,
  ]) async => ApiPage(notes, null);
  @override
  Future<void> addSpaceEntry(Session s, String id, String text) async {
    calls.add('entry $text');
    notes.insert(
      0,
      SpaceEntry(
        'e',
        text,
        const Person(anjaliId, 'anjali', 'Anjali'),
        DateTime.now(),
        true,
      ),
    );
  }

  @override
  Future<void> deleteSpaceEntry(Session s, String id, String entry) async {
    notes.clear();
  }

  @override
  Future<SocialSpace> createSpace(Session s, Map<String, dynamic> body) async {
    created = body;
    throw const ApiFailure('Test creation acknowledged');
  }

  @override
  Future<ApiPage<SpaceMember>> spaceMembers(
    Session s,
    String id, {
    String state = 'active',
    String? cursor,
  }) async => ApiPage([
    const SpaceMember(
      Person(anjaliId, 'anjali', 'Anjali'),
      'owner',
      'active',
      'going',
    ),
    const SpaceMember(
      Person(nikoId, 'niko', 'Niko'),
      'member',
      'pending',
      'going',
    ),
  ], null);
  @override
  Future<void> spaceMemberAction(
    Session s,
    String id,
    String user,
    String action,
  ) async {
    calls.add('member $action');
  }
}

Future<void> pump(WidgetTester t, SpacesFake a, Widget child) async {
  await t.pumpWidget(
    ProviderScope(
      overrides: [
        apiProvider.overrideWithValue(a),
        sessionProvider.overrideWith(SignedIn.new),
      ],
      child: MaterialApp(home: child),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  testWidgets('Space browse changes kind and joined filter', (t) async {
    final a = SpacesFake();
    await pump(t, a, const SpacesScreen());
    expect(find.text('After-hours book club'), findsOneWidget);
    await t.tap(find.text('Moments'));
    await t.pumpAndSettle();
    expect(a.calls, contains('spaces moment false'));
    await t.tap(find.text('Joined'));
    await t.pumpAndSettle();
    expect(a.calls, contains('spaces moment true'));
  });
  testWidgets(
    'Community members cannot create child spaces without host role',
    (t) async {
      final a = SpacesFake()..current = circle(state: 'active', role: 'member');
      await pump(t, a, const SpacesScreen(parentId: 'circle'));
      expect(find.byKey(const Key('new-space')), findsNothing);
    },
  );
  testWidgets('Joining unlocks shared discussion and submits a thought', (
    t,
  ) async {
    final a = SpacesFake();
    await pump(t, a, const SpaceScreen(id: 'circle'));
    expect(find.byKey(const Key('space-entry')), findsNothing);
    await t.tap(find.byKey(const Key('join-space')));
    await t.pumpAndSettle();
    expect(a.calls, contains('join true going'));
    await t.ensureVisible(find.byKey(const Key('space-entry')));
    await t.enterText(
      find.byKey(const Key('space-entry')),
      'A book worth sharing',
    );
    await t.tap(find.byKey(const Key('send-space-entry')));
    await t.pumpAndSettle();
    expect(a.calls, contains('entry A book worth sharing'));
    expect(find.text('A book worth sharing'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('Revoked access clears previously visible discussion', (t) async {
    final a = SpacesFake()..current = circle(state: 'active', discuss: true);
    a.notes.add(
      SpaceEntry(
        'e',
        'Private circle thought',
        const Person(nikoId, 'niko', 'Niko'),
        DateTime.now(),
        false,
      ),
    );
    await pump(t, a, const SpaceScreen(id: 'circle'));
    expect(find.text('Private circle thought'), findsOneWidget);
    a.fail = true;
    await t.tap(find.byTooltip('Refresh'));
    await t.pumpAndSettle();
    expect(find.text('Private circle thought'), findsNothing);
    expect(find.text('Access removed'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('Composer validates capacity before API call', (t) async {
    final a = SpacesFake();
    await pump(t, a, const CreateSpaceScreen());
    await t.ensureVisible(find.byKey(const Key('publish-space')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('publish-space')));
    await t.pumpAndSettle();
    expect(a.created, isNull);
    expect(find.text('Add a title and capacity of 2–10000.'), findsOneWidget);
  });
  testWidgets('Members can browse but cannot see moderation controls', (
    t,
  ) async {
    final a = SpacesFake()..current = circle(state: 'active', role: 'member');
    await pump(t, a, const SpaceMembersScreen(id: 'circle'));
    expect(find.text('Niko'), findsOneWidget);
    expect(find.text('pending'), findsNothing);
    expect(find.byType(PopupMenuButton<String>), findsNothing);
  });
  test('Schedule labels show local time and retain host IANA zone', () {
    final x = SocialSpace(
      spaceId: 'x',
      kind: 'event',
      title: 'Language night',
      owner: const Person(nikoId, 'niko', 'Niko'),
      createdAt: DateTime.now(),
      startsAt: DateTime.utc(2026, 11, 1, 5),
      endsAt: DateTime.utc(2026, 11, 1, 6),
      timezone: 'America/New_York',
    );
    expect(spaceSchedule(x), contains('Host zone: America/New_York'));
    expect(spaceSchedule(x), contains('(your time)'));
  });
}
