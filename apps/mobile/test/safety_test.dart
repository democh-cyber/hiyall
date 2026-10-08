import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kairova/app.dart';
import 'package:kairova/core/api.dart';
import 'package:kairova/core/chat/chat_engine.dart';
import 'package:kairova/core/state.dart';
import 'package:kairova/features/safety.dart';

import 'widget_test.dart' show FakeApi, SignedIn;

class SafetyApi extends FakeApi {
  bool muted = false, restricted = false;
  DateTime? mutedUntil;
  Map<String, dynamic>? reported;
  final lists = <String, List<Map<String, dynamic>>>{
    'blocked': [
      {
        'user': {'userId': nikoId, 'username': 'niko', 'displayName': 'Niko'},
        'since': '2026-10-01T10:00:00Z',
      },
    ],
    'muted': [],
    'restricted': [],
  };

  SafetyApi() {
    blocked = false;
  }

  @override
  Future<Profile> otherProfile(Session session, String userId) async => Profile(
    userId: userId,
    username: 'niko',
    displayName: 'Niko',
    bio: '',
    profession: '',
    version: '1',
    relationship: Relationship(muted: muted, restricted: restricted),
  );

  @override
  Future<void> setMuted(
    Session s,
    String userId,
    bool muted, {
    DateTime? until,
  }) async {
    this.muted = muted;
    mutedUntil = until;
    calls.add('mute $userId $muted');
  }

  @override
  Future<void> setRestricted(Session s, String userId, bool restricted) async {
    this.restricted = restricted;
    calls.add('restrict $userId $restricted');
  }

  @override
  Future<ApiPage<Map<String, dynamic>>> controls(
    Session s,
    String kind, [
    String? cursor,
  ]) async => ApiPage(lists[kind]!, null);

  @override
  Future<ReportReceipt> report(
    Session s, {
    required String targetType,
    required String targetId,
    required String reasonCode,
    String description = '',
    List<Map<String, dynamic>> evidence = const [],
    bool disclosureConsent = false,
    bool block = false,
  }) async {
    reported = {
      'targetType': targetType,
      'targetId': targetId,
      'reasonCode': reasonCode,
      'description': description,
      'evidence': evidence,
      'consent': disclosureConsent,
      'block': block,
    };
    return ReportReceipt(blocked: block);
  }
}

Future<ProviderContainer> start(
  WidgetTester tester,
  SafetyApi api,
  String at,
) async {
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
  container.read(routerProvider).go(at);
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('Profile options mute for a chosen time, restrict and undo', (
    tester,
  ) async {
    final api = SafetyApi();
    await start(tester, api, '/discover/person/$nikoId');

    await tester.tap(find.byKey(const Key('profile-options')).first);
    await tester.pumpAndSettle();
    expect(find.text('Mute Niko'), findsOneWidget);
    await tester.tap(find.byKey(const Key('person-mute')));
    await tester.pumpAndSettle();
    final before = DateTime.now();
    await tester.tap(find.byKey(const Key('mute-8h')));
    await tester.pumpAndSettle();
    expect(api.calls, contains('mute $nikoId true'));
    expect(
      api.mutedUntil!.difference(before).inMinutes,
      inInclusiveRange(479, 481),
    );
    expect(find.text('Niko is muted.'), findsOneWidget);

    // The refreshed profile offers the opposite action.
    await tester.tap(find.byKey(const Key('profile-options')).first);
    await tester.pumpAndSettle();
    expect(find.text('Unmute Niko'), findsOneWidget);
    await tester.tap(find.byKey(const Key('person-restrict')));
    await tester.pumpAndSettle();
    expect(api.calls, contains('restrict $nikoId true'));

    await tester.tap(find.byKey(const Key('profile-options')).first);
    await tester.pumpAndSettle();
    expect(find.text('Unrestrict Niko'), findsOneWidget);
    await tester.tap(find.byKey(const Key('person-mute')));
    await tester.pumpAndSettle();
    expect(api.calls, contains('mute $nikoId false'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Blocking from options asks first', (tester) async {
    final api = SafetyApi();
    await start(tester, api, '/discover/person/$nikoId');
    await tester.tap(find.byKey(const Key('profile-options')).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('person-block')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(api.requestedBlock, isNull);

    await tester.tap(find.byKey(const Key('profile-options')).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('person-block')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-block')));
    await tester.pumpAndSettle();
    expect(api.requestedBlock, isTrue);
  });

  testWidgets('A profile report needs a reason and can also block', (
    tester,
  ) async {
    final api = SafetyApi();
    await start(tester, api, '/discover/person/$nikoId');
    await tester.tap(find.byKey(const Key('profile-options')).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('person-report')));
    await tester.pumpAndSettle();

    final submit = find.byKey(const Key('report-submit'));
    final sheet = find.byType(Scrollable).last;
    await tester.scrollUntilVisible(submit, 300, scrollable: sheet);
    expect(tester.widget<FilledButton>(submit).onPressed, isNull);
    final scam = find.byKey(const Key('reason-scam'));
    await tester.scrollUntilVisible(scam, -300, scrollable: sheet);
    await tester.tap(scam);
    await tester.enterText(
      find.byKey(const Key('report-details')),
      ' fake shop ',
    );
    await tester.scrollUntilVisible(
      submit,
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.byKey(const Key('report-block')));
    await tester.pumpAndSettle();
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(api.reported, {
      'targetType': 'user',
      'targetId': nikoId,
      'reasonCode': 'scam',
      'description': ' fake shop ',
      'evidence': <Map<String, dynamic>>[],
      'consent': false,
      'block': true,
    });
    // Blocking through a report leaves the profile.
    expect(find.text('Thanks for reporting. Niko is blocked.'), findsOneWidget);
  });

  testWidgets('Chat evidence is shared only when picked and confirmed', (
    tester,
  ) async {
    final api = SafetyApi();
    final container = await start(tester, api, '/home');
    final at = DateTime.utc(2026, 10, 8, 9);
    final messages = [
      ChatMessage(
        messageId: 'm1',
        senderId: nikoId,
        text: 'hey',
        sentAt: at,
        mine: false,
      ),
      ChatMessage(
        messageId: 'm2',
        senderId: anjaliId,
        text: 'hi',
        sentAt: at,
        mine: true,
      ),
      ChatMessage(
        messageId: 'm3',
        senderId: nikoId,
        text: 'send money now',
        sentAt: at,
        serverAt: at.add(const Duration(seconds: 1)),
        mine: false,
      ),
      ChatMessage(
        messageId: 'n1',
        senderId: '',
        text: 'A new device was added',
        sentAt: at,
        mine: false,
        notice: true,
      ),
    ];
    // Open the sheet through a Consumer to get a WidgetRef.
    late WidgetRef widgetRef;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              widgetRef = ref;
              return const Scaffold(body: SizedBox());
            },
          ),
        ),
      ),
    );
    final sheet = showReportSheet(
      tester.element(find.byType(Scaffold)),
      widgetRef,
      targetType: 'conversation',
      targetId: 'c1',
      name: 'Niko',
      messages: messages,
    );
    await tester.pumpAndSettle();
    // Local notices are never offered as evidence.
    expect(find.byKey(const Key('evidence-n1')), findsNothing);
    await tester.tap(find.byKey(const Key('reason-scam')));
    await tester.pumpAndSettle();
    final evidence = find.byKey(const Key('evidence-m3'));
    await tester.scrollUntilVisible(
      evidence,
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(evidence);
    await tester.pumpAndSettle();
    final submit = find.byKey(const Key('report-submit'));
    await tester.scrollUntilVisible(
      submit,
      200,
      scrollable: find.byType(Scrollable).last,
    );
    expect(tester.widget<FilledButton>(submit).onPressed, isNull);
    await tester.tap(find.byKey(const Key('report-consent')));
    await tester.pumpAndSettle();
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect((await sheet)?.blocked, isFalse);
    expect(api.reported!['consent'], isTrue);
    expect(api.reported!['evidence'], [
      {
        'messageId': 'm3',
        'text': 'send money now',
        'sentAt': '2026-10-08T09:00:01.000Z',
        'fromMe': false,
      },
    ]);
  });

  testWidgets('Controls list each kind and undo in place', (tester) async {
    final api = SafetyApi();
    await start(tester, api, '/profile/controls');
    expect(find.text('Niko'), findsOneWidget);
    await tester.tap(find.text('Unblock'));
    await tester.pumpAndSettle();
    expect(api.requestedBlock, isFalse);
    expect(find.text('Niko'), findsNothing);
    expect(find.text('Nobody here'), findsOneWidget);

    api.lists['muted'] = [
      {
        'user': {'userId': nikoId, 'username': 'niko', 'displayName': 'Niko'},
        'since': '2026-10-01T10:00:00Z',
        'until': '2026-10-09T10:00:00Z',
      },
    ];
    await tester.tap(find.text('Muted'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Until'), findsOneWidget);
    await tester.tap(find.text('Unmute'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('mute $nikoId false'));
    expect(tester.takeException(), isNull);
  });
}
