import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/app_info.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/features/spaces.dart';

import 'spaces_test.dart' show SpacesFake, circle, pump;
import 'widget_test.dart' show SignedIn;

/// A joined space whose reads can go offline, page, or wait on a gate.
class LiveSpace extends SpacesFake {
  LiveSpace() {
    current = circle(state: 'active', discuss: true);
    notes.add(entry('e1', 'Newest thought'));
  }
  bool offline = false;
  int spaceReads = 0, entryReads = 0;
  String? firstCursor;
  final gates = <String, Completer<void>>{};

  static SpaceEntry entry(String id, String text) => SpaceEntry(
    id,
    text,
    const Person(nikoId, 'niko', 'Niko'),
    DateTime.now(),
    false,
  );

  @override
  Future<SocialSpace> space(Session s, String id) async {
    spaceReads++;
    if (offline) throw const ApiFailure('Could not connect.');
    return current;
  }

  @override
  Future<ApiPage<SpaceEntry>> spaceEntries(
    Session s,
    String id, [
    String? cursor,
  ]) async {
    entryReads++;
    if (cursor != null) return ApiPage([entry('old', 'Older thought')], null);
    return ApiPage(notes, firstCursor);
  }

  @override
  Future<ApiPage<SocialSpace>> spaces(
    Session s,
    String kind, {
    String? cursor,
    String? parentId,
    bool mine = false,
  }) async {
    calls.add('spaces $kind');
    await gates[kind]?.future;
    return const ApiPage([], null);
  }

  @override
  Future<ApiPage<SpaceMember>> spaceMembers(
    Session s,
    String id, {
    String state = 'active',
    String? cursor,
  }) async {
    calls.add('members');
    return super.spaceMembers(s, id, state: state, cursor: cursor);
  }
}

Future<void> resume(WidgetTester t) async {
  t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await t.pumpAndSettle();
}

void main() {
  // These tests exercise Events and Moments, which are off in V1 builds.
  setUp(() => FeatureFlags.eventsOverride = true);
  tearDown(() => FeatureFlags.eventsOverride = null);
  testWidgets('A failed background reload keeps the space on screen', (
    t,
  ) async {
    final a = LiveSpace();
    await pump(t, a, const SpaceScreen(id: 'circle'));
    // Posts are built lazily, so scroll them into view first.
    await t.scrollUntilVisible(
      find.text('Newest thought'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Newest thought'), findsOneWidget);
    a.offline = true;
    await resume(t);
    expect(a.spaceReads, 2);
    expect(find.text('Newest thought'), findsOneWidget);
    expect(find.text('Could not connect.'), findsNothing);
    // An explicit refresh says what went wrong but still keeps the page.
    await t.tap(find.byKey(const Key('space-menu')));
    await t.pumpAndSettle();
    await t.tap(find.text('Refresh'));
    await t.pumpAndSettle();
    expect(find.text('Newest thought'), findsOneWidget);
    expect(find.text('Could not connect.'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('Returning to the app keeps older entries already loaded', (
    t,
  ) async {
    final a = LiveSpace()..firstCursor = 'older';
    await pump(t, a, const SpaceScreen(id: 'circle'));
    final more = find.text('Older thoughts');
    await t.scrollUntilVisible(
      more,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await t.pumpAndSettle();
    await t.tap(more);
    await t.pumpAndSettle();
    expect(find.text('Older thought', skipOffstage: false), findsOneWidget);
    final reads = a.spaceReads;
    await resume(t);
    expect(a.spaceReads, reads);
    expect(find.text('Older thought', skipOffstage: false), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('Opening Members while Events loads still loads members', (
    t,
  ) async {
    final a = LiveSpace();
    await pump(t, a, const SpaceScreen(id: 'circle'));
    a.gates['event'] = Completer();
    await t.ensureVisible(find.byKey(const Key('space-tab-events')));
    await t.tap(find.byKey(const Key('space-tab-events')));
    await t.pump();
    await t.tap(find.byKey(const Key('space-tab-members')));
    await t.pump();
    await t.pump();
    expect(a.calls, contains('members'));
    expect(find.text('Anjali'), findsWidgets);
    a.gates['event']!.complete();
    await t.pumpAndSettle();
    expect(find.text('Anjali'), findsWidgets);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('Closing the editor shows the saved details', (t) async {
    final a = LiveSpace()..current = circle(state: 'active', role: 'owner');
    final router = GoRouter(
      initialLocation: '/spaces/circle',
      routes: [
        GoRoute(
          path: '/spaces/:id',
          builder: (_, s) => SpaceScreen(id: s.pathParameters['id']!),
          routes: [
            GoRoute(
              path: 'edit',
              builder: (context, _) => Scaffold(
                body: TextButton(
                  onPressed: () {
                    a.current = SocialSpace(
                      spaceId: 'circle',
                      kind: 'community',
                      title: 'Renamed book club',
                      owner: const Person(anjaliId, 'anjali', 'Anjali'),
                      createdAt: DateTime.utc(2026, 10, 9),
                      myState: 'active',
                      myRole: 'owner',
                    );
                    context.pop();
                  },
                  child: const Text('Save'),
                ),
              ),
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          apiProvider.overrideWithValue(a),
          sessionProvider.overrideWith(SignedIn.new),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('space-menu')));
    await t.pumpAndSettle();
    await t.tap(find.text('Edit details & schedule'));
    await t.pumpAndSettle();
    await t.tap(find.text('Save'));
    await t.pumpAndSettle();
    expect(find.text('Renamed book club'), findsWidgets);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('Spaces never describe themselves as adults only', (t) async {
    await pump(t, SpacesFake(), const SpacesScreen());
    expect(find.textContaining('Adults only'), findsNothing);
    expect(find.textContaining('adults', findRichText: true), findsNothing);
  });
}
