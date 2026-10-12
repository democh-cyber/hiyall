import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/app.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/chat_peers.dart';
import 'package:hiyall/core/discovery.dart';
import 'package:hiyall/core/say_hi_prefs.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/features/say_hi.dart';

import 'widget_test.dart' show FakeApi, SignedIn;

/// One person of the fake people list, as the server would send it.
Map<String, dynamic> person(
  String id,
  String name, {
  String? headline,
  String? bio,
  String? vibe,
  List<String>? interests,
  List<String>? shared,
  List<Object>? languages,
  String? country,
  bool? online,
  int? distanceKm,
  String? avatarUrl,
}) => {
  'userId': id,
  'username': id,
  'displayName': name,
  'headline': ?headline,
  'bio': ?bio,
  'currentVibe': ?vibe,
  'interests': ?interests,
  'sharedInterests': ?shared,
  'languages': ?languages,
  'country': ?country,
  'online': ?online,
  'distanceKm': ?distanceKm,
  'avatarUrl': ?avatarUrl,
};

/// A fake server for Discover: pages of people, with the filters it was sent.
class DiscoverFake extends FakeApi {
  /// Everyone the server knows, in order. `online: true` is honoured as a filter.
  List<Map<String, dynamic>> people;
  int pageSize;
  final searches = <Map<String, dynamic>>[];
  final nearbyCalls = <PeopleFilters?>[];
  Completer<void>? hold;
  ApiFailure? failure;
  Object? failureOnce;
  int followingReads = 0;
  Set<String> following = {};
  Profile? own = const Profile(
    userId: anjaliId,
    username: 'anjali',
    displayName: 'Anjali',
    bio: '',
    profession: '',
    version: '1',
    languages: [ProfileLanguage('en')],
    interests: ['Music', 'Photography'],
    currentVibe: 'Chill',
  );
  final opened = <String>[];

  /// Blocks and reports the screen sent; a block or a report that blocks also
  /// removes the person from what the "server" returns next time.
  final blockCalls = <String>[];
  final reports = <Map<String, dynamic>>[];
  ApiFailure? blockFailure, reportFailure;

  DiscoverFake({this.people = const [], this.pageSize = 20});

  @override
  Future<Profile> profile(Session s) async => own!;

  @override
  Future<Profile> otherProfile(Session session, String userId) async {
    opened.add(userId);
    final json = people.firstWhere(
      (p) => p['userId'] == userId,
      orElse: () => person(userId, userId),
    );
    return Profile.fromJson(json);
  }

  @override
  Future<void> block(Session session, String userId, bool value) async {
    if (blockFailure != null) throw blockFailure!;
    blockCalls.add(userId);
    people = [
      for (final p in people)
        if (p['userId'] != userId) p,
    ];
  }

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
    if (reportFailure != null) throw reportFailure!;
    reports.add({
      'targetType': targetType,
      'targetId': targetId,
      'reason': reasonCode,
      'block': block,
    });
    if (block) {
      people = [
        for (final p in people)
          if (p['userId'] != targetId) p,
      ];
    }
    return ReportReceipt(blocked: block);
  }

  List<Map<String, dynamic>> _filtered(bool online) => [
    for (final p in people)
      if (!online || p['online'] == true) p,
  ];

  Map<String, dynamic> _page(List<Map<String, dynamic>> all, String? cursor) {
    final start = cursor == null ? 0 : int.parse(cursor);
    final end = (start + pageSize).clamp(0, all.length);
    return {
      'items': all.sublist(start, end),
      'nextCursor': end < all.length ? '$end' : null,
    };
  }

  @override
  Future<Map<String, dynamic>> searchPeople(
    Session s,
    Map<String, dynamic> filters,
  ) async {
    searches.add(Map.from(filters));
    if (hold != null) await hold!.future;
    if (failureOnce != null) {
      final e = failureOnce!;
      failureOnce = null;
      throw e;
    }
    if (failure != null) throw failure!;
    return _page(
      _filtered(filters['online'] == true),
      filters['cursor'] as String?,
    );
  }

  @override
  Future<ApiPage<Profile>> nearby(
    Session s, {
    PeopleFilters? filters,
    int radiusKm = 50,
    String? cursor,
  }) async {
    nearbyCalls.add(filters);
    if (failure != null) throw failure!;
    final page = _page([
      for (final p in _filtered(filters?.online == true))
        if (p['distanceKm'] != null) p,
    ], cursor);
    return ApiPage.fromJson(page, Profile.fromJson);
  }

  @override
  Future<ApiPage<Connection>> connections(
    Session s,
    String kind, {
    String? userId,
    String? cursor,
  }) async {
    followingReads++;
    return ApiPage([
      for (final id in following)
        Connection(Person(id, id, id), DateTime(2026), 'active'),
    ], null);
  }

  @override
  Future<ApiPage<SocialSpace>> spaces(
    Session s,
    String kind, {
    String? cursor,
    String? parentId,
    bool mine = false,
  }) async => const ApiPage([], null);
}

/// What Say hi did, for assertions: a fake chat engine. It records the conversations opened and the
/// messages sent through it, and can hold or fail either call.
class HiLog implements HiChat {
  final opened = <String>[];

  /// (conversation id, peer id, text) of each message sent.
  final sent = <(String, String, String)>[];

  /// Holds `open` until completed (with the conversation id).
  Completer<String>? hold;

  /// Holds `send` until completed.
  Completer<void>? sendHold;

  /// Thrown by `open` / by `send`.
  Object? failure, sendFailure;

  /// Whether the engine is already up; [engineUp] holds `connect` while it is not.
  bool ready = true;
  Completer<void>? engineUp;
  Object? connectFailure;
  int connects = 0;
  int next = 1;

  HiChatLink get link => HiChatLink(
    ready: () => ready,
    connect: () async {
      connects++;
      if (engineUp != null) await engineUp!.future;
      ready = true;
      if (connectFailure != null) throw connectFailure!;
      return this;
    },
  );

  @override
  Future<String> open(String peerId) async {
    opened.add(peerId);
    if (hold != null) return hold!.future;
    if (failure != null) throw failure!;
    return 'conv-${next++}';
  }

  @override
  Future<void> send(String conversationId, String peerId, String text) async {
    if (sendHold != null) await sendHold!.future;
    if (sendFailure != null) throw sendFailure!;
    sent.add((conversationId, peerId, text));
  }
}

/// A clock a test can move.
class HiClock {
  DateTime now = DateTime.utc(2026, 10, 13, 12);
  DateTime call() => now;
}

/// Mounts the real app on Discover, signed in, with the chat call faked.
Future<ProviderContainer> mountDiscover(
  WidgetTester tester,
  DiscoverFake api, {
  Size size = const Size(390, 844),
  double scale = 1,
  bool dark = true,
  bool chat = true,
  HiLog? hi,
  SayHiPrefsStore? sayHiStore,
  HiClock? clock,

  /// What the chat list last said (peer id -> conversation id), or null for "not loaded".
  Map<String, String>? peers,
  bool still = false,
  List<Override> extra = const [],
  Widget Function(Widget app)? wrap,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final log = hi ?? HiLog();
  final container = ProviderContainer(
    overrides: [
      apiProvider.overrideWithValue(api),
      sessionProvider.overrideWith(SignedIn.new),
      sayHiAvailableProvider.overrideWithValue(chat),
      // The platform keystore never answers in tests.
      sayHiPrefsStoreProvider.overrideWithValue(
        sayHiStore ?? MemorySayHiPrefsStore(),
      ),
      hiChatLinkProvider.overrideWithValue(log.link),
      if (clock != null) sayHiClockProvider.overrideWithValue(clock.call),
      ...extra,
    ],
  );
  addTearDown(container.dispose);
  final app = MediaQuery(
    data: MediaQueryData(
      size: size,
      textScaler: TextScaler.linear(scale),
      disableAnimations: still,
      padding: size.width < 500
          ? const EdgeInsets.only(top: 47, bottom: 34)
          : EdgeInsets.zero,
      viewPadding: size.width < 500
          ? const EdgeInsets.only(top: 47, bottom: 34)
          : EdgeInsets.zero,
    ),
    child: const HiyallApp(),
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: wrap == null ? app : wrap(app),
    ),
  );
  container.read(themeProvider.notifier).toggle(dark);
  // Home asks for suggestions first; count only what Discover sends.
  await tester.pumpAndSettle();
  api.searches.clear();
  api.nearbyCalls.clear();
  api.followingReads = 0;
  if (peers != null) container.read(chatPeersProvider.notifier).load(peers);
  container.read(routerProvider).go('/discover');
  await tester.pumpAndSettle();
  return container;
}

/// A list busy enough to judge the design: online people, shared and own
/// interests, long, Arabic and Japanese names, and people with nothing filled in.
List<Map<String, dynamic>> busyPeople({bool scripts = false}) => [
  person(
    'mira',
    'Mira Kapoor',
    headline: 'Film photos and late night ramen',
    interests: ['Photography', 'Music', 'Travel', 'Art'],
    shared: ['Music', 'Photography'],
    languages: [
      {'code': 'en', 'level': 'native'},
      {'code': 'hi', 'level': 'fluent'},
      {'code': 'es'},
    ],
    country: 'IN',
    online: true,
  ),
  person(
    'arjun',
    'Arjun Venkataraghavan-Krishnamurthy',
    bio: 'Building tiny games on weekends and learning to cook properly',
    interests: ['Gaming', 'Tech', 'Food'],
    languages: [
      {'code': 'en', 'level': 'fluent'},
      {'code': 'ta', 'level': 'native'},
    ],
    country: 'IN',
    online: true,
  ),
  person(
    'sara',
    'سارة المنصوري',
    headline: 'أحب القراءة والقهوة والمشي في الصباح',
    interests: ['Books', 'Coffee'],
    shared: ['Photography'],
    languages: [
      {'code': 'ar', 'level': 'native'},
      {'code': 'en', 'level': 'fluent'},
    ],
    country: 'AE',
  ),
  person(
    'hinata',
    '田中 ひなた',
    headline: '写真と映画と散歩が好きです',
    interests: ['映画', '写真', '音楽'],
    languages: [
      {'code': 'ja', 'level': 'native'},
    ],
    country: 'JP',
    online: true,
  ),
  person(
    'jules',
    'Jules',
    interests: ['Movies'],
    languages: [
      {'code': 'en'},
    ],
    country: 'FR',
  ),
  person('noor', 'Noor'),
  person(
    'kai',
    'Kai Nakamura',
    vibe: 'Night owl',
    languages: [
      {'code': 'en', 'level': 'fluent'},
      {'code': 'ja', 'level': 'basic'},
    ],
    country: 'JP',
  ),
  person(
    'rey',
    'Rey',
    headline: 'Learning Korean through dramas',
    interests: ['Learning', 'Music'],
    shared: ['Music'],
    languages: [
      {'code': 'en'},
      {'code': 'ko'},
      {'code': 'tl'},
      {'code': 'fr'},
    ],
    country: 'PH',
  ),
  person(
    'ana',
    'Ana Souza',
    bio: 'Quiet mornings and good books',
    interests: ['Books', 'Hiking'],
    languages: [
      {'code': 'pt', 'level': 'native'},
      {'code': 'en', 'level': 'conversational'},
    ],
    country: 'BR',
    online: true,
  ),
].where((p) => scripts || !['sara', 'hinata'].contains(p['userId'])).toList();
