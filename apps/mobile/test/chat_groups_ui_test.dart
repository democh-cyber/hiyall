import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/chat/chat_api.dart';
import 'package:hiyall/core/chat/chat_engine.dart';
import 'package:hiyall/core/chat/chat_groups.dart';
import 'package:hiyall/core/chat/chat_reactions.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/core/theme.dart';
import 'package:hiyall/features/chat.dart';
import 'package:hiyall/features/chat_format.dart';
import 'package:hiyall/features/chat_groups_data.dart';
import 'package:hiyall/features/chat_groups_info.dart';
import 'package:hiyall/features/chat_groups_new.dart';
import 'package:hiyall/features/chat_thread.dart' show NoticeChip;
import 'package:hiyall/features/people_lists/people_lists_actions.dart';

import 'chat_photo_helpers.dart' show meId;
import 'chat_ui_test.dart' show UiCloud, UiEngine, chat, fixedNow, msg, when;
import 'widget_test.dart' show SignedIn;

// Group chat screens (docs/mobile/19-group-chat.md): the invites and group rows of the Chats list, the New
// group picker, a group's thread and Group info. The engine is a double that records what the screens ask of it.

const gid = '00000000-0000-4000-8000-0000000000a1';
const gid2 = '00000000-0000-4000-8000-0000000000a2';
const samId = '019a4000-0000-7000-8000-000000000003';
const kaiId = '019a4000-0000-7000-8000-000000000004';
const miaId = '019a4000-0000-7000-8000-000000000005';
const zoeId = '019a4000-0000-7000-8000-000000000006';

GroupMember person(String id, String name, {bool owner = false}) => GroupMember(
  userId: id,
  username: name.split(' ').first.toLowerCase(),
  displayName: name,
  owner: owner,
);

final me = person(meId, 'Aditya Rao');
final sam = person(samId, 'Sam Rivera');
final kai = person(kaiId, 'Kai Tanaka');
final mia = person(miaId, 'Mia Okafor');

ChatMessage gmsg(
  String n,
  String from,
  String text,
  DateTime at, {
  bool notice = false,
}) => ChatMessage(
  messageId: '00000000-0000-4000-8000-0000000001${n.padLeft(2, '0')}',
  senderId: from,
  text: text,
  sentAt: at,
  serverAt: notice ? null : at.toUtc(),
  mine: from == meId,
  notice: notice,
);

GroupInfo grp({
  String id = gid,
  String name = 'Weekend crew',
  String owner = meId,
  List<GroupMember>? members,
  List<GroupPending> pending = const [],
  int unread = 0,
  ChatMessage? last,
  DateTime? pinnedAt,
  bool readOnly = false,
  bool closed = false,
  Set<String> unconfirmed = const {},
}) => GroupInfo(
  id: id,
  name: name,
  ownerId: owner,
  createdAt: DateTime(2026, 10, 1),
  members:
      members ??
      [
        person(meId, 'Aditya Rao', owner: owner == meId),
        person(samId, 'Sam Rivera', owner: owner == samId),
        kai,
        mia,
      ],
  pending: pending,
  unreadCount: unread,
  last: last,
  pinnedAt: pinnedAt,
  readOnly: readOnly,
  closed: closed,
  unconfirmed: unconfirmed,
);

GroupInvite invite({
  String id = gid,
  String name = 'Book club',
  GroupMember? by,
  int count = 3,
}) => GroupInvite(
  groupId: id,
  name: name,
  invitedBy: by ?? sam,
  invitedAt: DateTime(2026, 10, 12),
  expiresAt: DateTime(2026, 10, 19),
  memberCount: count,
  members: [by ?? sam, kai],
);

class GroupCloud extends UiCloud {
  final mutes = <String>[];
  @override
  Future<void> muteConversation(
    String id,
    bool muted, {
    DateTime? until,
  }) async {
    mutes.add('$id $muted');
  }
}

class GroupEngine extends UiEngine {
  GroupEngine(GroupCloud super.cloud);
  List<GroupInfo> groupList = [];
  List<GroupInvite> invites = [];
  final infos = <String, GroupInfo>{};
  final calls = <String>[];
  final sent = <String>[];
  Object? acceptError, declineError, createError, sendError;
  GroupInfo? created;

  @override
  bool isGroup(String id) =>
      groupList.any((g) => g.id == id) || infos.containsKey(id);
  @override
  Future<List<GroupInfo>> groups() async => List.of(groupList);

  /// People who left, by id, as the engine kept them.
  final former = <String, GroupMember>{};
  @override
  Map<String, GroupMember> groupDirectory(String groupId) => former;

  /// Groups deleted from the list.
  List<GroupInfo> hiddenList = [];
  @override
  Future<List<ChatConversation>> hiddenConversations() async => const [];
  @override
  Future<List<GroupInfo>> hiddenGroups() async => List.of(hiddenList);
  @override
  Future<void> restoreConversation(String id) async {
    calls.add('restore $id');
    hiddenList.removeWhere((g) => g.id == id);
  }

  @override
  Future<List<GroupInvite>> groupInvites() async => List.of(invites);
  @override
  Future<GroupInfo> group(String id) async {
    final found =
        infos[id] ??
        groupList.cast<GroupInfo?>().firstWhere(
          (g) => g!.id == id,
          orElse: () => null,
        );
    if (found == null) throw const ChatFailure('NOT_FOUND', '', 404);
    return found;
  }

  @override
  Future<GroupInfo> acceptGroupInvite(String id) async {
    calls.add('accept $id');
    final error = acceptError;
    if (error != null) {
      acceptError = null;
      throw error;
    }
    invites.removeWhere((i) => i.groupId == id);
    return grp(id: id);
  }

  @override
  Future<void> declineGroupInvite(String id) async {
    calls.add('decline $id');
    final error = declineError;
    if (error != null) {
      declineError = null;
      throw error;
    }
    invites.removeWhere((i) => i.groupId == id);
  }

  @override
  Future<GroupInfo> createGroup({
    String name = '',
    required List<String> memberIds,
  }) async {
    calls.add('create $name ${memberIds.join(',')}');
    final error = createError;
    if (error != null) {
      createError = null;
      throw error;
    }
    return created ?? grp(name: name);
  }

  @override
  Future<GroupInfo> inviteToGroup(String id, List<String> userIds) async {
    calls.add('invite $id ${userIds.join(',')}');
    return grp(id: id);
  }

  @override
  Future<GroupInfo> renameGroup(String id, String name) async {
    calls.add('rename $id $name');
    return grp(id: id, name: name);
  }

  @override
  Future<GroupInfo> removeFromGroup(String id, String userId) async {
    calls.add('remove $id $userId');
    return grp(id: id);
  }

  @override
  Future<void> leaveGroup(String id, {String? newOwnerId}) async {
    calls.add('leave $id ${newOwnerId ?? '-'}');
  }

  @override
  Future<void> confirmGroupMember(String id, String userId) async {
    calls.add('confirm $id $userId');
  }

  @override
  Future<void> pinConversation(String id, bool pinned) async {
    calls.add('pin $id $pinned');
  }

  @override
  Future<void> hideConversation(String id) async {
    calls.add('hide $id');
  }

  @override
  Future<SafetyInfo> safetyInfo(String peerId) async => SafetyInfo(
    number: '1234567890' * 6,
    verified: false,
    changedSinceVerified: false,
    newDevices: 0,
    peerFingerprint: 'p',
    myFingerprint: 'm',
  );

  @override
  Future<void> send(
    String conversationId,
    String peerId,
    String text, {
    ChatMessage? replyTo,
  }) async {
    final error = sendError;
    if (error != null) {
      sendError = null;
      throw error;
    }
    sent.add('$conversationId|$peerId|$text');
  }
}

/// Following list of the picker: a page of people, no cursor.
class FakePeopleLists extends PeopleListsActions {
  FakePeopleLists(super.ref, this.people);
  final List<Person> people;
  @override
  Future<ApiPage<Connection>> connections(
    String kind, {
    String? userId,
    String? cursor,
  }) async => ApiPage([
    for (final p in people) Connection(p, DateTime(2026, 9, 1), 'active'),
  ], null);
}

void main() {
  late GroupCloud cloud;
  late GroupEngine engine;
  final opened = <String>[];

  void spec(String name, Future<void> Function(WidgetTester tester) body) =>
      testWidgets(name, (tester) async {
        cloud = GroupCloud();
        engine = GroupEngine(cloud);
        opened.clear();
        await body(tester);
      });

  List<Override> overrides({List<Person> following = const []}) => [
    chatEngineProvider.overrideWith((ref) async => engine),
    sessionProvider.overrideWith(SignedIn.new),
    chatClockProvider.overrideWithValue(() => fixedNow),
    peopleListsActionsProvider.overrideWith(
      (ref) => FakePeopleLists(ref, following),
    ),
  ];

  /// The app's chat routes on a router: the list, a thread, Group info, and a page to push the picker from.
  GoRouter router(String initial) => GoRouter(
    initialLocation: initial,
    routes: [
      GoRoute(
        path: '/chats',
        builder: (context, state) => const Scaffold(body: ChatsScreen()),
        routes: [
          GoRoute(
            path: ':id',
            builder: (context, state) => Scaffold(
              body: ConversationScreen(
                id: state.pathParameters['id']!,
                peerId: state.uri.queryParameters['peer'] ?? '',
                peerName: state.uri.queryParameters['name'] ?? 'Chat',
              ),
            ),
            routes: [
              GoRoute(
                path: 'info',
                builder: (context, state) => GroupInfoScreen(
                  id: state.pathParameters['id']!,
                  openProfile: (context, id) => opened.add(id),
                ),
              ),
            ],
          ),
        ],
      ),
    ],
  );

  Future<GoRouter> pump(
    WidgetTester tester,
    String initial, {
    Size size = const Size(390, 844),
    double textScale = 1,
    TextDirection? direction,
    List<Person> following = const [],
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final r = router(initial);
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides(following: following),
        child: MaterialApp.router(
          theme: hiyallTheme(Brightness.dark),
          routerConfig: r,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(textScale),
              disableAnimations: true,
            ),
            child: direction == null
                ? child!
                : Directionality(textDirection: direction, child: child!),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return r;
  }

  /// One screen without a router.
  Future<void> pumpScreen(
    WidgetTester tester,
    Widget screen, {
    Size size = const Size(390, 844),
    double textScale = 1,
    TextDirection? direction,
    List<Person> following = const [],
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides(following: following),
        child: MaterialApp(
          theme: hiyallTheme(Brightness.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(textScale),
              disableAnimations: true,
            ),
            child: direction == null
                ? child!
                : Directionality(textDirection: direction, child: child!),
          ),
          home: screen,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  String chatPath(String id, {String name = 'Weekend crew'}) =>
      '/chats/$id?peer=&name=${Uri.encodeQueryComponent(name)}';

  // ------------------------------------------------------------ the data layer

  group('wording and ordering', () {
    test('CANNOT_ADD_MEMBER names the person and never says why', () {
      final text = groupFailureText(
        const ChatFailure('CANNOT_ADD_MEMBER', 'blocked by them', 409),
        name: 'Sam',
      )!;
      expect(text, 'Sam can’t be added to this group.');
      final anon = groupFailureText(
        const ChatFailure('CANNOT_ADD_MEMBER', 'age band', 409),
      )!;
      expect(anon, 'That person can’t be added to this group.');
      for (final reason in ['block', 'age', 'privacy', 'limit']) {
        expect(text.toLowerCase(), isNot(contains(reason)));
        expect(anon.toLowerCase(), isNot(contains(reason)));
      }
    });

    test('every group refusal has calm words, and others have none', () {
      for (final code in [
        'GROUP_FULL',
        'GROUP_LIMIT',
        'DAILY_LIMIT',
        'GROUP_NOT_OWNER',
        'GROUP_WAITING',
        'GROUP_UNCONFIRMED_MEMBER',
        'GROUP_OUT_OF_SYNC',
      ]) {
        expect(
          groupFailureText(ChatFailure(code, '')),
          isNotEmpty,
          reason: code,
        );
      }
      expect(groupFailureText(const ChatFailure('NETWORK', '')), isNull);
      expect(groupFailureText(StateError('x')), isNull);
      expect(
        chatError(const ChatFailure('GROUP_WAITING', '')),
        'Waiting for others to join.',
      );
    });

    test('groups sit among the chats: pinned first, then by activity', () {
      final one = [
        chat(1, 'Mira', 'mira', msg('a', 'hi', when(12, 0))),
        chat(2, 'Dev', 'dev', msg('b', 'yo', when(9, 0))),
      ];
      // As the relay lists them: pinned first.
      final groups = [
        grp(
          id: gid2,
          name: 'Old pinned',
          pinnedAt: DateTime(2026, 10, 1),
          last: gmsg('2', samId, 'old', when(8, 0, daysAgo: 3)),
        ),
        grp(id: gid, last: gmsg('1', samId, 'hello', when(10, 0))),
      ];
      final merged = mergeChats(one, groups, meId);
      expect([for (final c in merged) c.id], [gid2, one[0].id, gid, one[1].id]);
      expect(merged.first.peerId, '');
    });

    test('titles: the name, else first names', () {
      expect(groupTitle(grp(), meId), 'Weekend crew');
      expect(groupTitle(grp(name: ''), meId), 'Sam, Kai, Mia');
      expect(groupTitle(grp(name: '  '), samId), 'Aditya, Kai, Mia');
      expect(memberCountText(1), '1 member');
      expect(memberCountText(7), '7 members');
    });
  });

  // ----------------------------------------------------------- pending invites

  group('pending invites', () {
    spec('shows each invite with who invited, how many, Accept and Decline', (
      tester,
    ) async {
      engine.invites = [invite()];
      await pump(tester, '/chats');
      expect(find.text('Pending invites'), findsOneWidget);
      expect(find.text('Book club'), findsOneWidget);
      expect(find.text('Invited by Sam Rivera'), findsOneWidget);
      expect(find.text('3 members'), findsOneWidget);
      expect(find.byKey(const Key('invite-accept-$gid')), findsOneWidget);
      expect(find.byKey(const Key('invite-decline-$gid')), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const Key('invite-accept-$gid'))).height,
        greaterThanOrEqualTo(48),
      );
    });

    spec('no section without invites', (tester) async {
      await pump(tester, '/chats');
      expect(find.text('Pending invites'), findsNothing);
      expect(find.byKey(const Key('pending-invites')), findsNothing);
    });

    spec('Accept joins and the invite goes', (tester) async {
      engine.invites = [invite()];
      engine.infos[gid] = grp(name: 'Book club');
      await pump(tester, '/chats');
      await tester.tap(find.byKey(const Key('invite-accept-$gid')));
      await tester.pumpAndSettle();
      expect(engine.calls, ['accept $gid']);
      expect(find.text('Pending invites'), findsNothing);
      expect(find.text('You joined Book club.'), findsOneWidget);
    });

    spec('Decline asks nothing and tells nobody', (tester) async {
      engine.invites = [invite(), invite(id: gid2, name: 'Hikers')];
      await pump(tester, '/chats');
      await tester.tap(find.byKey(const Key('invite-decline-$gid')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(engine.calls, ['decline $gid']);
      expect(find.text('Book club'), findsNothing);
      expect(find.text('Hikers'), findsOneWidget);
    });

    spec('a failure is shown on the invite and can be tried again', (
      tester,
    ) async {
      engine.invites = [invite()];
      engine.acceptError = const ChatFailure('GROUP_FULL', '', 409);
      await pump(tester, '/chats');
      await tester.tap(find.byKey(const Key('invite-accept-$gid')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('invite-error-$gid')), findsOneWidget);
      expect(find.textContaining('This group is full'), findsOneWidget);
      // Both buttons are back.
      await tester.tap(find.byKey(const Key('invite-accept-$gid')));
      await tester.pumpAndSettle();
      expect(engine.calls, ['accept $gid', 'accept $gid']);
      expect(find.byKey(const Key('invite-error-$gid')), findsNothing);
    });

    spec('an expired invite says so and disappears on refresh', (tester) async {
      engine.invites = [invite()];
      engine.acceptError = const ChatFailure('NOT_FOUND', '', 404);
      await pump(tester, '/chats');
      // The relay no longer lists it by the time the list reads again.
      engine.invites = [];
      await tester.tap(find.byKey(const Key('invite-accept-$gid')));
      await tester.pumpAndSettle();
      expect(find.text('Pending invites'), findsNothing);
    });
  });

  // ------------------------------------------------------------------ group rows

  group('group rows', () {
    final last = gmsg('1', samId, 'see you at 8', when(11, 0));
    spec('a group is a row among the chats: stack, mark, preview, unread', (
      tester,
    ) async {
      engine.list = [
        chat(
          1,
          'Mira Kapoor',
          'mira',
          msg('a', 'old news', when(9, 0)),
          online: true,
        ),
      ];
      engine.groupList = [grp(unread: 3, last: last)];
      await pump(tester, '/chats');
      // The group is the newer chat, so it is first.
      final groupY = tester.getTopLeft(find.text('Weekend crew')).dy;
      expect(groupY, lessThan(tester.getTopLeft(find.text('Mira Kapoor')).dy));
      expect(find.byKey(const Key('group-avatar-stack')), findsOneWidget);
      expect(find.byKey(const Key('group-mark')), findsOneWidget);
      expect(find.text('Sam: see you at 8'), findsOneWidget);
      expect(find.byKey(const Key('unread-$gid')), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      // Only the one-to-one chat has an online dot; the group never does.
      expect(
        find.byKey(Key('chat-row-online-${chat(1, '', '', null).peerId}')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('chat-row-online-')), findsNothing);
    });

    spec('a row says what it is to a screen reader', (tester) async {
      final handle = tester.ensureSemantics();
      engine.groupList = [grp(unread: 2, last: last)];
      await pump(tester, '/chats');
      final label = tester.getSemantics(find.byKey(const ValueKey(gid))).label;
      expect(label, contains('Weekend crew'));
      expect(label, contains('group, 4 members'));
      expect(label, contains('2 unread'));
      expect(label, contains('Sam: see you at 8'));
      // The photo stack is decoration: nothing of it is read out.
      expect(label, isNot(contains('Sam Rivera')));
      handle.dispose();
    });

    spec('the stack shows at most three member photos', (tester) async {
      engine.groupList = [
        grp(
          members: [me, sam, kai, mia, person(zoeId, 'Zoe Park')],
          last: last,
        ),
      ];
      await pump(tester, '/chats');
      final stack = find.byKey(const Key('group-avatar-stack'));
      // Three faces (Sam, Kai, Mia): the people other than you, in order, and no more.
      for (final initial in ['S', 'K', 'M']) {
        expect(
          find.descendant(of: stack, matching: find.text(initial)),
          findsOneWidget,
          reason: initial,
        );
      }
      for (final initial in ['Z', 'A']) {
        expect(
          find.descendant(of: stack, matching: find.text(initial)),
          findsNothing,
          reason: initial,
        );
      }
    });

    spec(
      'Unread filter includes groups; search finds a group by who is in it',
      (tester) async {
        engine.list = [
          chat(1, 'Mira Kapoor', 'mira', msg('a', 'hey', when(9, 0))),
        ];
        engine.groupList = [grp(unread: 4, last: last)];
        await pump(tester, '/chats');
        await tester.tap(find.byKey(const Key('chat-filter-unread')));
        await tester.pumpAndSettle();
        expect(find.text('Weekend crew'), findsOneWidget);
        expect(find.text('Mira Kapoor'), findsNothing);
        await tester.tap(find.byKey(const Key('chat-filter-all')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const Key('chat-search')), 'kai');
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();
        expect(find.text('Weekend crew'), findsOneWidget);
        expect(find.text('Mira Kapoor'), findsNothing);
      },
    );

    spec('edit mode can pin and delete a group like any chat', (tester) async {
      engine.groupList = [grp(last: last)];
      await pump(tester, '/chats');
      await tester.tap(find.byKey(const Key('chats-edit')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Weekend crew'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('edit-pin')));
      await tester.pumpAndSettle();
      expect(engine.calls, ['pin $gid true']);
      await tester.tap(find.byKey(const Key('edit-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-yes')));
      await tester.pumpAndSettle();
      expect(engine.calls, ['pin $gid true', 'hide $gid']);
    });

    spec('a deleted group is in Deleted chats and can be restored', (
      tester,
    ) async {
      engine.hiddenList = [
        GroupInfo(
          id: gid2,
          name: 'Old crew',
          ownerId: samId,
          createdAt: DateTime(2026, 9, 1),
          members: [me, sam, kai],
          hiddenAt: DateTime(2026, 10, 10),
          restoreUntil: DateTime(2026, 11, 9),
        ),
      ];
      await pump(tester, '/chats');
      await tester.tap(find.byKey(const Key('chats-deleted-link')));
      await tester.pumpAndSettle();
      expect(find.text('Old crew'), findsOneWidget);
      expect(find.byKey(const Key('deleted-left-$gid2')), findsOneWidget);
      await tester.tap(find.byKey(const Key('restore-$gid2')));
      await tester.pumpAndSettle();
      expect(engine.calls, ['restore $gid2']);
      expect(find.byKey(const Key('deleted-empty')), findsOneWidget);
    });

    spec('tapping a group opens its thread', (tester) async {
      engine.groupList = [grp(last: last)];
      engine.infos[gid] = grp(last: last);
      engine.messages = [last];
      await pump(tester, '/chats');
      await tester.tap(find.text('Weekend crew'));
      await tester.pumpAndSettle();
      expect(find.byType(ConversationScreen), findsOneWidget);
      expect(find.byKey(const Key('chat-header-members')), findsOneWidget);
    });

    spec('New group opens the picker; creating opens the new thread', (
      tester,
    ) async {
      engine.list = [
        chat(1, 'Mira Kapoor', 'mira', msg('a', 'hey', when(9, 0))),
        chat(2, 'Dev Shah', 'dev', msg('b', 'yo', when(8, 0))),
      ];
      engine.created = grp(id: gid2, name: 'Fresh', unread: 0);
      engine.infos[gid2] = engine.created!;
      await pump(tester, '/chats');
      await tester.tap(find.byKey(const Key('chats-new-group')));
      await tester.pumpAndSettle();
      expect(find.byType(NewGroupScreen), findsOneWidget);
      await tester.tap(find.byKey(Key('pick-${chat(1, '', '', null).peerId}')));
      await tester.tap(find.byKey(Key('pick-${chat(2, '', '', null).peerId}')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('group-create')));
      await tester.pumpAndSettle();
      expect(find.byType(NewGroupScreen), findsNothing);
      expect(find.byType(ConversationScreen), findsOneWidget);
      expect(engine.calls.single, startsWith('create '));
    });
  });

  // ---------------------------------------------------------------- the picker

  group('new group picker', () {
    final people = [
      for (var n = 1; n <= 11; n++)
        chat(n, 'Person $n', 'person$n', msg('m$n', 'hello', when(9, n))),
    ];
    String idOf(int n) => chat(n, '', '', null).peerId;

    Future<void> openPicker(
      WidgetTester tester, {
      List<Person> following = const [],
      double textScale = 1,
      Size size = const Size(390, 844),
      TextDirection? direction,
    }) async {
      await pumpScreen(
        tester,
        const NewGroupScreen(),
        following: following,
        textScale: textScale,
        size: size,
        direction: direction,
      );
    }

    spec('Create waits for two people; the count reads "n of 9"', (
      tester,
    ) async {
      engine.list = people;
      await openPicker(tester);
      expect(find.text('0 of 9'), findsOneWidget);
      expect(find.text('Pick at least 2'), findsOneWidget);
      FilledButton create() =>
          tester.widget(find.byKey(const Key('group-create')));
      expect(create().onPressed, isNull);
      await tester.tap(find.byKey(Key('pick-${idOf(1)}')));
      await tester.pump();
      expect(find.text('1 of 9'), findsOneWidget);
      expect(create().onPressed, isNull);
      await tester.tap(find.byKey(Key('pick-${idOf(2)}')));
      await tester.pump();
      expect(find.text('2 of 9'), findsOneWidget);
      expect(find.text('Pick at least 2'), findsNothing);
      expect(create().onPressed, isNotNull);
      // A picked person is a chip; the chip takes them out again.
      expect(find.byKey(Key('chip-${idOf(1)}')), findsOneWidget);
      await tester.tap(find.byKey(Key('chip-${idOf(1)}')));
      await tester.pump();
      expect(find.text('1 of 9'), findsOneWidget);
      expect(create().onPressed, isNull);
    });

    spec('nine is the most; the tenth cannot be picked', (tester) async {
      engine.list = people;
      await openPicker(tester);
      for (var n = 1; n <= 9; n++) {
        await tester.ensureVisible(find.byKey(Key('pick-${idOf(n)}')));
        await tester.tap(find.byKey(Key('pick-${idOf(n)}')));
        await tester.pump();
      }
      expect(find.text('9 of 9'), findsOneWidget);
      await tester.ensureVisible(find.byKey(Key('pick-${idOf(10)}')));
      await tester.tap(
        find.byKey(Key('pick-${idOf(10)}')),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(find.text('9 of 9'), findsOneWidget);
      expect(find.byKey(Key('chip-${idOf(10)}')), findsNothing);
      // Taking one out makes room again.
      await tester.tap(find.byKey(Key('chip-${idOf(1)}')));
      await tester.pump();
      await tester.tap(find.byKey(Key('pick-${idOf(10)}')));
      await tester.pump();
      expect(find.text('9 of 9'), findsOneWidget);
      expect(find.byKey(Key('chip-${idOf(10)}')), findsOneWidget);
    });

    spec('the name takes 40 characters, counts them and is optional', (
      tester,
    ) async {
      engine.list = people;
      await openPicker(tester);
      expect(find.text('0/40'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('group-name-field')),
        'weekend',
      );
      await tester.pump();
      expect(find.text('7/40'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('group-name-field')),
        'x' * 60,
      );
      await tester.pump();
      expect(find.text('40/40'), findsOneWidget);
      // With a name typed, Create sends it (after the usual text clean-up); without, an empty name.
      await tester.enterText(
        find.byKey(const Key('group-name-field')),
        '  weekend crew  ',
      );
      await tester.tap(find.byKey(Key('pick-${idOf(1)}')));
      await tester.tap(find.byKey(Key('pick-${idOf(2)}')));
      await tester.pump();
      engine.created = grp(name: 'weekend crew');
      await tester.tap(find.byKey(const Key('group-create')));
      await tester.pumpAndSettle();
      expect(engine.calls.single, 'create weekend crew ${idOf(1)},${idOf(2)}');
    });

    spec('people you follow are listed too, and search narrows both', (
      tester,
    ) async {
      engine.list = people.take(2).toList();
      await openPicker(
        tester,
        following: const [
          Person(zoeId, 'zoe', 'Zoe Park'),
          Person(kaiId, 'kai', 'Kai Tanaka'),
        ],
      );
      expect(find.byKey(const Key('picker-chatting')), findsOneWidget);
      expect(find.byKey(const Key('picker-following')), findsOneWidget);
      expect(find.byKey(const Key('pick-$zoeId')), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('group-picker-search')),
        '@kai',
      );
      await tester.pump();
      expect(find.byKey(const Key('pick-$kaiId')), findsOneWidget);
      expect(find.byKey(const Key('pick-$zoeId')), findsNothing);
      expect(find.byKey(Key('pick-${idOf(1)}')), findsNothing);
    });

    spec('someone who cannot be added is named, and never explained', (
      tester,
    ) async {
      engine.list = people;
      await openPicker(tester);
      await tester.tap(find.byKey(Key('pick-${idOf(1)}')));
      await tester.tap(find.byKey(Key('pick-${idOf(3)}')));
      await tester.pump();
      engine.createError = ChatFailure(
        'CANNOT_ADD_MEMBER',
        'You are blocked by them (age band)',
        409,
        null,
        {'userId': idOf(3)},
      );
      await tester.tap(find.byKey(const Key('group-create')));
      await tester.pumpAndSettle();
      expect(
        find.text('Person 3 can’t be added to this group.'),
        findsOneWidget,
      );
      expect(find.textContaining('blocked'), findsNothing);
      expect(find.textContaining('age'), findsNothing);
      // Nothing was lost: the picks stay and it can be tried again.
      expect(find.text('2 of 9'), findsOneWidget);
    });

    spec('other refusals read calmly (full, limits)', (tester) async {
      engine.list = people;
      await openPicker(tester);
      await tester.tap(find.byKey(Key('pick-${idOf(1)}')));
      await tester.tap(find.byKey(Key('pick-${idOf(2)}')));
      await tester.pump();
      engine.createError = const ChatFailure('DAILY_LIMIT', '', 429);
      await tester.tap(find.byKey(const Key('group-create')));
      await tester.pumpAndSettle();
      expect(find.textContaining('today’s limit'), findsOneWidget);
      engine.createError = const ChatFailure('GROUP_LIMIT', '', 409);
      await tester.tap(find.byKey(const Key('group-create')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('as many groups as you can be'),
        findsOneWidget,
      );
    });

    spec('Add people is limited by the room left and skips who is in', (
      tester,
    ) async {
      engine.list = people.take(5).toList();
      await pumpScreen(
        tester,
        AddToGroupScreen(groupId: gid, exclude: {idOf(1)}, room: 2),
      );
      expect(find.text('0 of 2'), findsOneWidget);
      expect(find.byKey(Key('pick-${idOf(1)}')), findsNothing);
      await tester.tap(find.byKey(Key('pick-${idOf(2)}')));
      await tester.pump();
      FilledButton add() =>
          tester.widget(find.byKey(const Key('group-create')));
      expect(add().onPressed, isNotNull);
      await tester.tap(find.byKey(Key('pick-${idOf(3)}')));
      await tester.pump();
      await tester.tap(find.byKey(Key('pick-${idOf(4)}')), warnIfMissed: false);
      await tester.pump();
      expect(find.text('2 of 2'), findsOneWidget);
      await tester.tap(find.byKey(const Key('group-create')));
      await tester.pumpAndSettle();
      expect(engine.calls.single, 'invite $gid ${idOf(2)},${idOf(3)}');
    });
  });

  // ------------------------------------------------------------------- thread

  group('group thread', () {
    List<ChatMessage> thread() => [
      gmsg('1', samId, 'Sam joined', when(9, 0), notice: true),
      gmsg('2', samId, 'who is in for Saturday?', when(9, 5)),
      gmsg('3', samId, 'I can drive', when(9, 6)),
      gmsg('4', kaiId, 'count me in', when(9, 7)),
      gmsg('5', meId, 'me too', when(9, 8)),
    ];

    spec('header: photo stack, title, member count, no presence or shield', (
      tester,
    ) async {
      engine.messages = thread();
      engine.groupList = [grp()];
      await pump(tester, chatPath(gid));
      expect(
        tester.widget<Text>(find.byKey(const Key('chat-header-name'))).data,
        'Weekend crew',
      );
      expect(
        tester.widget<Text>(find.byKey(const Key('chat-header-members'))).data,
        '4 members',
      );
      expect(find.byKey(const Key('group-avatar-stack')), findsOneWidget);
      expect(find.byKey(const Key('safety-number-button')), findsNothing);
      expect(find.byKey(const Key('chat-online-dot')), findsNothing);
      expect(find.byKey(const Key('chat-header-online')), findsNothing);
      expect(find.byKey(const Key('chat-header-last-seen')), findsNothing);
      expect(find.text('end-to-end encrypted'), findsNothing);
      expect(find.byKey(const Key('seen')), findsNothing);
      expect(find.text('Seen'), findsNothing);
    });

    spec('the header is read out with the member count', (tester) async {
      final handle = tester.ensureSemantics();
      engine.messages = thread();
      engine.groupList = [grp()];
      await pump(tester, chatPath(gid));
      expect(
        find.bySemanticsLabel('Group info, Weekend crew, 4 members'),
        findsOneWidget,
      );
      handle.dispose();
    });

    spec('an untitled group shows the first names of its members', (
      tester,
    ) async {
      engine.groupList = [grp(name: '')];
      await pump(tester, chatPath(gid, name: 'Sam, Kai, Mia'));
      expect(
        tester.widget<Text>(find.byKey(const Key('chat-header-name'))).data,
        'Sam, Kai, Mia',
      );
    });

    spec('sender names sit above the first bubble of a run, not above yours', (
      tester,
    ) async {
      engine.messages = thread();
      engine.groupList = [grp()];
      await pump(tester, chatPath(gid));
      // Sam's run of two: the name once, above the first. Kai's run has its own.
      expect(find.text('Sam Rivera'), findsOneWidget);
      expect(find.text('Kai Tanaka'), findsOneWidget);
      expect(
        find.byKey(Key('sender-${thread()[1].messageId}')),
        findsOneWidget,
      );
      expect(find.byKey(Key('sender-${thread()[2].messageId}')), findsNothing);
      expect(find.byKey(Key('sender-${thread()[4].messageId}')), findsNothing);
      // The name is above its bubble.
      expect(
        tester.getTopLeft(find.text('Sam Rivera')).dy,
        lessThan(tester.getTopLeft(find.text('who is in for Saturday?')).dy),
      );
      // Neutral: not the accent colour of a quote or a link.
      final style = tester.widget<Text>(find.text('Sam Rivera')).style!;
      expect(style.color, isNot(equals(const Color(0xFFFFFFFF))));
    });

    spec('a long name ends in an ellipsis instead of overflowing', (
      tester,
    ) async {
      engine.messages = [gmsg('1', samId, 'hello there', when(9, 5))];
      engine.groupList = [
        grp(members: [me, person(samId, 'Sam ${'Longname' * 12}'), kai]),
      ];
      await pump(tester, chatPath(gid), size: const Size(320, 640));
      expect(tester.takeException(), isNull);
      final text = tester.widget<Text>(
        find.byKey(
          Key('sender-${gmsg('1', samId, '', DateTime.now()).messageId}'),
        ),
      );
      expect(text.overflow, TextOverflow.ellipsis);
      expect(text.maxLines, 1);
    });

    spec('notices render as chips and a joiner shows no sender name', (
      tester,
    ) async {
      engine.messages = [
        gmsg('1', samId, 'Sam joined', when(9, 0), notice: true),
        gmsg('2', kaiId, 'Kai left', when(9, 1), notice: true),
        gmsg('3', meId, 'You were removed', when(9, 2), notice: true),
      ];
      engine.groupList = [grp()];
      await pump(tester, chatPath(gid));
      expect(find.byType(NoticeChip), findsNWidgets(3));
      expect(find.text('Sam joined'), findsOneWidget);
      expect(find.text('Kai left'), findsOneWidget);
      expect(find.text('Sam Rivera'), findsNothing);
    });

    spec(
      'a person who left keeps their name; one nobody knows is "Former member"',
      (tester) async {
        engine.former[zoeId] = person(zoeId, 'Zoe Park');
        engine.messages = [
          gmsg('1', zoeId, 'bye all', when(9, 5)),
          gmsg(
            '2',
            '019a4000-0000-7000-8000-000000000099',
            'who am i',
            when(9, 6),
          ),
        ];
        engine.groupList = [grp()];
        await pump(tester, chatPath(gid));
        expect(find.text('Zoe Park'), findsOneWidget);
        expect(find.text(GroupDirectory.former), findsOneWidget);
      },
    );

    spec('sending goes to the group with the engine\'s group peer', (
      tester,
    ) async {
      engine.messages = thread();
      engine.groupList = [grp()];
      await pump(tester, chatPath(gid));
      await tester.enterText(find.byKey(const Key('chat-input')), 'on my way');
      await tester.pump();
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pumpAndSettle();
      expect(engine.sent, ['$gid|$groupPeer|on my way']);
    });

    spec('a read-only group has a calm line instead of a composer', (
      tester,
    ) async {
      engine.messages = thread();
      engine.groupList = [grp(readOnly: true)];
      await pump(tester, chatPath(gid));
      expect(
        find.text('You can’t send messages to this group anymore.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('chat-composer-dock')), findsNothing);
      expect(find.byKey(const Key('chat-input')), findsNothing);
    });

    spec('a closed group is read-only too', (tester) async {
      engine.groupList = [grp(readOnly: true, closed: true)];
      await pump(tester, chatPath(gid));
      expect(find.byKey(const Key('group-composer-notice')), findsOneWidget);
      expect(find.byKey(const Key('group-empty')), findsOneWidget);
    });

    spec('GROUP_WAITING swaps the composer for "Waiting for others to join."', (
      tester,
    ) async {
      engine.messages = thread();
      engine.groupList = [grp()];
      engine.sendError = const ChatFailure('GROUP_WAITING', '', 409);
      await pump(tester, chatPath(gid));
      await tester.enterText(find.byKey(const Key('chat-input')), 'hello?');
      await tester.pump();
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pumpAndSettle();
      expect(find.text('Waiting for others to join.'), findsOneWidget);
      expect(find.byKey(const Key('chat-input')), findsNothing);
    });

    spec('a group with nobody else yet waits for them', (tester) async {
      engine.groupList = [
        grp(
          members: [me],
          pending: [
            GroupPending(userId: samId, username: 'sam', displayName: 'Sam'),
          ],
        ),
      ];
      await pump(tester, chatPath(gid));
      expect(find.text('Waiting for others to join.'), findsOneWidget);
    });

    spec('GROUP_UNCONFIRMED_MEMBER offers Group info', (tester) async {
      engine.messages = thread();
      engine.groupList = [
        grp(unconfirmed: {kaiId}),
      ];
      engine.sendError = const ChatFailure('GROUP_UNCONFIRMED_MEMBER', '', 409);
      await pump(tester, chatPath(gid));
      await tester.enterText(find.byKey(const Key('chat-input')), 'hi');
      await tester.pump();
      await tester.tap(find.byKey(const Key('chat-send')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('group-unconfirmed-message')),
        findsOneWidget,
      );
      // The text is back in the composer for another try.
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('chat-input')))
            .controller!
            .text,
        'hi',
      );
      await tester.tap(find.text('Group info'));
      await tester.pumpAndSettle();
      expect(find.byType(GroupInfoScreen), findsOneWidget);
    });

    spec('tapping the header opens Group info', (tester) async {
      engine.messages = thread();
      engine.groupList = [grp()];
      await pump(tester, chatPath(gid));
      await tester.tap(find.byKey(const Key('chat-header-profile')));
      await tester.pumpAndSettle();
      expect(find.byType(GroupInfoScreen), findsOneWidget);
    });

    spec('the menu is a group menu: info, mute, pin; no block or safety', (
      tester,
    ) async {
      engine.messages = thread();
      engine.groupList = [grp()];
      await pump(tester, chatPath(gid));
      await tester.tap(find.byKey(const Key('chat-options')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chat-group-info')), findsOneWidget);
      expect(find.byKey(const Key('chat-mute')), findsOneWidget);
      expect(find.byKey(const Key('chat-pin')), findsOneWidget);
      expect(find.byKey(const Key('chat-auto-translate')), findsOneWidget);
      expect(find.byKey(const Key('chat-block')), findsNothing);
      expect(find.byKey(const Key('chat-safety')), findsNothing);
      expect(find.byKey(const Key('chat-profile')), findsNothing);
    });

    spec('a conversation opened by id alone (a push) becomes the group', (
      tester,
    ) async {
      // Not in the list yet: only the relay knows it.
      engine.infos[gid] = grp();
      engine.messages = thread();
      await pump(tester, '/chats/$gid');
      expect(find.byKey(const Key('chat-header-members')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('chat-header-name'))).data,
        'Weekend crew',
      );
    });

    spec('a message of someone else can be reported from its menu', (
      tester,
    ) async {
      engine.messages = thread();
      engine.groupList = [grp()];
      await pump(tester, chatPath(gid));
      await tester.longPress(find.text('count me in'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('menu-report')), findsOneWidget);
      await tester.tap(find.byKey(const Key('menu-report')));
      await tester.pumpAndSettle();
      expect(find.text('Report Kai Tanaka’s message'), findsOneWidget);
      // The evidence list names each sender, not one peer.
      expect(find.textContaining('Sam Rivera'), findsWidgets);
    });

    spec('your own messages have no Report', (tester) async {
      engine.messages = thread();
      engine.groupList = [grp()];
      await pump(tester, chatPath(gid));
      await tester.longPress(find.text('me too'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('menu-reply')), findsOneWidget);
      expect(find.byKey(const Key('menu-report')), findsNothing);
    });

    spec('a reaction chip names who reacted', (tester) async {
      final handle = tester.ensureSemantics();
      final base = thread()[1];
      engine.messages = [
        ChatMessage(
          messageId: base.messageId,
          senderId: base.senderId,
          text: base.text,
          sentAt: base.sentAt,
          serverAt: base.serverAt,
          mine: false,
          reactionStates: {
            kaiId: ReactionState(
              emoji: '👍',
              at: DateTime(2026, 10, 12, 9, 6),
              id: 'r1',
            ),
            miaId: ReactionState(
              emoji: '👍',
              at: DateTime(2026, 10, 12, 9, 6),
              id: 'r2',
            ),
          },
        ),
      ];
      engine.groupList = [grp()];
      await pump(tester, chatPath(gid));
      expect(find.text('2'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Kai Tanaka and Mia Okafor reacted with 👍'),
        findsOneWidget,
      );
      handle.dispose();
    });
  });

  // ---------------------------------------------------------------- group info

  group('group info', () {
    Future<void> openInfo(
      WidgetTester tester, {
      // Tall, so the whole page is built and every control can be found.
      Size size = const Size(390, 1800),
      double textScale = 1,
      TextDirection? direction,
    }) => pumpScreen(
      tester,
      GroupInfoScreen(id: gid, openProfile: (context, id) => opened.add(id)),
      size: size,
      textScale: textScale,
      direction: direction,
    );

    spec('the owner: members with roles, rename, add, remove', (tester) async {
      engine.infos[gid] = grp(
        pending: [
          GroupPending(userId: zoeId, username: 'zoe', displayName: 'Zoe Park'),
        ],
      );
      await openInfo(tester);
      expect(find.byKey(const Key('group-info-title')), findsOneWidget);
      expect(find.text('Weekend crew'), findsOneWidget);
      expect(find.text('4 members'), findsOneWidget);
      expect(find.text('Owner'), findsOneWidget);
      expect(find.text('You'), findsOneWidget);
      expect(find.text('Invited, waiting'), findsWidgets);
      expect(find.text('Zoe Park'), findsOneWidget);
      expect(find.byKey(const Key('group-rename')), findsOneWidget);
      expect(find.byKey(const Key('group-add-people')), findsOneWidget);
      expect(find.text('Room for 5 more people.'), findsOneWidget);
      expect(find.byKey(const Key('group-e2ee')), findsOneWidget);
      expect(find.textContaining('end-to-end encrypted'), findsOneWidget);
      // Remove sits in each other member's menu.
      await tester.tap(find.byKey(const Key('member-menu-$kaiId')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('member-remove')), findsOneWidget);
      expect(find.byKey(const Key('member-safety')), findsOneWidget);
    });

    spec('a member does not get the owner\'s actions', (tester) async {
      engine.infos[gid] = grp(owner: samId);
      await openInfo(tester);
      expect(find.byKey(const Key('group-rename')), findsNothing);
      expect(find.byKey(const Key('group-add-people')), findsNothing);
      await tester.tap(find.byKey(const Key('member-menu-$kaiId')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('member-safety')), findsOneWidget);
      expect(find.byKey(const Key('member-remove')), findsNothing);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      // Mute, pin, delete and leave are everyone's.
      expect(find.byKey(const Key('group-mute')), findsOneWidget);
      expect(find.byKey(const Key('group-pin')), findsOneWidget);
      expect(find.byKey(const Key('group-delete')), findsOneWidget);
      expect(find.byKey(const Key('group-leave')), findsOneWidget);
    });

    spec('tapping a member opens their profile; you open nothing', (
      tester,
    ) async {
      engine.infos[gid] = grp();
      await openInfo(tester);
      await tester.tap(find.byKey(const Key('member-$kaiId')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('member-$meId')));
      await tester.pump();
      expect(opened, [kaiId]);
    });

    spec('rename: a dialog with the 40 limit and its counter', (tester) async {
      engine.infos[gid] = grp();
      await openInfo(tester);
      await tester.tap(find.byKey(const Key('group-rename')));
      await tester.pumpAndSettle();
      expect(find.text('12/40'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('rename-field')), 'y' * 55);
      await tester.pump();
      expect(find.text('40/40'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('rename-field')), 'Hikers');
      await tester.tap(find.byKey(const Key('rename-save')));
      await tester.pumpAndSettle();
      expect(engine.calls, ['rename $gid Hikers']);
    });

    spec('remove asks first', (tester) async {
      engine.infos[gid] = grp();
      await openInfo(tester);
      await tester.tap(find.byKey(const Key('member-menu-$kaiId')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('member-remove')));
      await tester.pumpAndSettle();
      expect(find.text('Remove Kai Tanaka?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm-cancel')));
      await tester.pumpAndSettle();
      expect(engine.calls, isEmpty);
      await tester.tap(find.byKey(const Key('member-menu-$kaiId')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('member-remove')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-yes')));
      await tester.pumpAndSettle();
      expect(engine.calls, ['remove $gid $kaiId']);
    });

    spec('Add people opens the picker for the room left', (tester) async {
      engine.list = [
        chat(1, 'Person 1', 'p1', msg('a', 'hi', when(9, 0))),
        chat(2, 'Person 2', 'p2', msg('b', 'hi', when(9, 1))),
      ];
      engine.infos[gid] = grp(
        pending: [
          GroupPending(userId: zoeId, username: 'zoe', displayName: 'Zoe Park'),
        ],
      );
      await openInfo(tester);
      await tester.tap(find.byKey(const Key('group-add-people')));
      await tester.pumpAndSettle();
      expect(find.byType(AddToGroupScreen), findsOneWidget);
      expect(find.text('0 of 5'), findsOneWidget);
    });

    spec('a full group says so instead of opening the picker', (tester) async {
      engine.infos[gid] = grp(
        members: [
          me,
          sam,
          kai,
          mia,
          person(zoeId, 'Zoe Park'),
          for (var n = 7; n <= 11; n++)
            person(
              '019a4000-0000-7000-8000-0000000000${n.toString().padLeft(2, '0')}',
              'P$n',
            ),
        ],
      );
      await openInfo(tester);
      expect(find.text('This group is full.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('group-add-people')));
      await tester.pumpAndSettle();
      expect(find.byType(AddToGroupScreen), findsNothing);
    });

    spec('an unconfirmed member is labelled and can be confirmed', (
      tester,
    ) async {
      engine.infos[gid] = grp(unconfirmed: {miaId});
      await openInfo(tester);
      expect(find.text('Not confirmed'), findsOneWidget);
      await tester.tap(find.byKey(const Key('member-confirm-$miaId')));
      await tester.pumpAndSettle();
      expect(find.text('Confirm Mia Okafor?'), findsOneWidget);
      expect(
        find.textContaining('hasn’t seen Mia Okafor join'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('confirm-yes')));
      await tester.pumpAndSettle();
      expect(engine.calls, ['confirm $gid $miaId']);
    });

    spec('safety number per member opens the existing dialog', (tester) async {
      engine.infos[gid] = grp();
      await openInfo(tester);
      await tester.tap(find.byKey(const Key('member-menu-$samId')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('member-safety')));
      await tester.pumpAndSettle();
      expect(find.text('Verify safety number'), findsOneWidget);
      expect(find.byKey(const Key('safety-number')), findsOneWidget);
      expect(
        find.textContaining('only you and Sam Rivera can read'),
        findsOneWidget,
      );
    });

    spec('mute and pin work on the group', (tester) async {
      engine.infos[gid] = grp();
      await openInfo(tester);
      await tester.tap(find.byKey(const Key('group-mute')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('mute-8h')));
      await tester.pumpAndSettle();
      expect(cloud.mutes, ['$gid true']);
      await tester.tap(find.byKey(const Key('group-pin')));
      await tester.pumpAndSettle();
      expect(engine.calls, ['pin $gid true']);
    });

    spec('a member leaves after one question', (tester) async {
      engine.infos[gid] = grp(owner: samId);
      await openInfo(tester);
      await tester.tap(find.byKey(const Key('group-leave')));
      await tester.pumpAndSettle();
      expect(find.text('Leave this group?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm-yes')));
      await tester.pumpAndSettle();
      expect(engine.calls, ['leave $gid -']);
    });

    spec('the owner chooses who takes over before leaving', (tester) async {
      engine.infos[gid] = grp();
      await openInfo(tester);
      await tester.tap(find.byKey(const Key('group-leave')));
      await tester.pumpAndSettle();
      expect(find.text('Who takes over?'), findsOneWidget);
      // The one who leaves is not on the list, and Leave waits for a choice.
      expect(find.byKey(const Key('successor-$meId')), findsNothing);
      FilledButton leave() =>
          tester.widget(find.byKey(const Key('successor-leave')));
      expect(leave().onPressed, isNull);
      await tester.tap(find.byKey(const Key('successor-$miaId')));
      await tester.pump();
      expect(leave().onPressed, isNotNull);
      await tester.tap(find.byKey(const Key('successor-leave')));
      await tester.pumpAndSettle();
      expect(engine.calls, ['leave $gid $miaId']);
    });

    spec('an owner with one other person left just leaves (the group closes)', (
      tester,
    ) async {
      engine.infos[gid] = grp(
        members: [person(meId, 'Aditya Rao', owner: true), sam],
      );
      await openInfo(tester);
      await tester.tap(find.byKey(const Key('group-leave')));
      await tester.pumpAndSettle();
      expect(find.text('Who takes over?'), findsNothing);
      expect(find.textContaining('closes'), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm-yes')));
      await tester.pumpAndSettle();
      expect(engine.calls, ['leave $gid -']);
    });

    spec('delete from the list uses the hide flow', (tester) async {
      engine.infos[gid] = grp();
      await openInfo(tester);
      await tester.tap(find.byKey(const Key('group-delete')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-yes')));
      await tester.pumpAndSettle();
      expect(engine.calls, ['hide $gid']);
    });

    spec('a group you were removed from or that closed is read-only', (
      tester,
    ) async {
      engine.infos[gid] = grp(
        owner: samId,
        readOnly: true,
        members: [sam, kai],
      );
      await openInfo(tester);
      expect(find.byKey(const Key('group-readonly')), findsOneWidget);
      expect(find.textContaining('no longer in this group'), findsOneWidget);
      expect(find.byKey(const Key('group-leave')), findsNothing);
      expect(find.byKey(const Key('group-add-people')), findsNothing);
      expect(find.byKey(const Key('group-rename')), findsNothing);
      expect(find.byKey(const Key('group-mute')), findsNothing);
      expect(find.byKey(const Key('group-delete')), findsOneWidget);
      engine.infos[gid] = grp(readOnly: true, closed: true);
    });

    spec('a closed group says it closed', (tester) async {
      engine.infos[gid] = grp(readOnly: true, closed: true);
      await openInfo(tester);
      expect(find.textContaining('This group has closed'), findsOneWidget);
    });

    spec('a group that is gone says so and can be tried again', (tester) async {
      await openInfo(tester);
      expect(find.byKey(const Key('group-info-error')), findsOneWidget);
      expect(find.text('This group isn’t available.'), findsOneWidget);
    });
  });

  // ----------------------------------------------- narrow screens, big text, RTL

  group('layout', () {
    const narrow = Size(320, 640);

    void noOverflow(WidgetTester tester) {
      expect(tester.takeException(), isNull);
    }

    void tapTargets(WidgetTester tester, Finder buttons) {
      for (final e in buttons.evaluate()) {
        final size = tester.getSize(find.byWidget(e.widget));
        expect(size.height, greaterThanOrEqualTo(48 - .01));
      }
    }

    spec('the list at 320 dp and text 2.0', (tester) async {
      engine.list = [
        chat(1, 'Mira Kapoor', 'mira', msg('a', 'hey', when(9, 0))),
      ];
      engine.groupList = [
        grp(
          name: 'A group with a really long name that cannot fit',
          unread: 120,
          last: gmsg('1', samId, 'a long message ' * 8, when(11, 0)),
        ),
      ];
      engine.invites = [
        invite(name: 'An invite with another very long group name'),
      ];
      await pump(tester, '/chats', size: narrow, textScale: 2);
      noOverflow(tester);
      expect(find.text('Pending invites'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const Key('invite-accept-$gid')),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      noOverflow(tester);
    });

    spec('the picker at 320 dp and text 2.0', (tester) async {
      engine.list = [
        for (var n = 1; n <= 4; n++)
          chat(
            n,
            'A person with a long name $n',
            'user$n',
            msg('m$n', 'hi', when(9, n)),
          ),
      ];
      await pumpScreen(
        tester,
        const NewGroupScreen(),
        size: narrow,
        textScale: 2,
      );
      await tester.enterText(
        find.byKey(const Key('group-name-field')),
        'a name that is forty characters long ok!',
      );
      await tester.pump();
      noOverflow(tester);
      for (var n = 1; n <= 3; n++) {
        final id = chat(n, '', '', null).peerId;
        await tester.scrollUntilVisible(
          find.byKey(Key('pick-$id')),
          80,
          scrollable: find
              .descendant(
                of: find.byKey(const Key('group-picker-list')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.tap(find.byKey(Key('pick-$id')));
        await tester.pump();
      }
      await tester.pump();
      noOverflow(tester);
      tapTargets(tester, find.byKey(const Key('group-create')));
      engine.createError = const ChatFailure('GROUP_FULL', '', 409);
      await tester.tap(find.byKey(const Key('group-create')));
      await tester.pumpAndSettle();
      noOverflow(tester);
    });

    spec('the thread at 320 dp and text 2.0', (tester) async {
      engine.messages = [
        gmsg('1', samId, 'Sam joined the group', when(9, 0), notice: true),
        gmsg('2', samId, 'a message that goes on and on ' * 3, when(9, 5)),
        gmsg('3', kaiId, 'short', when(9, 7)),
        gmsg('4', meId, 'me too', when(9, 8)),
      ];
      engine.groupList = [grp(name: 'A group with a really long name indeed')];
      await pump(tester, chatPath(gid), size: narrow, textScale: 2);
      noOverflow(tester);
      engine.groupList = [grp(readOnly: true)];
      await pump(tester, chatPath(gid), size: narrow, textScale: 2);
      noOverflow(tester);
      expect(find.byKey(const Key('group-composer-notice')), findsOneWidget);
    });

    spec('Group info at 320 dp and text 2.0, owner and member', (tester) async {
      engine.infos[gid] = grp(
        name: 'A group with a really long name indeed',
        unconfirmed: {miaId},
        pending: [
          GroupPending(
            userId: zoeId,
            username: 'zoe',
            displayName: 'Zoe with a very long display name',
          ),
        ],
      );
      await pumpScreen(
        tester,
        GroupInfoScreen(id: gid, openProfile: (context, id) {}),
        size: narrow,
        textScale: 2,
      );
      noOverflow(tester);
      await tester.drag(
        find.byKey(const Key('group-info-list')),
        const Offset(0, -2000),
      );
      await tester.pumpAndSettle();
      noOverflow(tester);
      engine.infos[gid] = grp(owner: samId);
      await pumpScreen(
        tester,
        GroupInfoScreen(id: gid, openProfile: (context, id) {}),
        size: narrow,
        textScale: 2,
      );
      noOverflow(tester);
    });

    spec('every control in Group info has a label and a 48 dp target', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      engine.infos[gid] = grp(unconfirmed: {miaId});
      await pumpScreen(
        tester,
        GroupInfoScreen(id: gid, openProfile: (context, id) {}),
        size: const Size(390, 1800),
      );
      for (final key in [
        'group-rename',
        'group-add-people',
        'group-mute',
        'group-pin',
        'group-delete',
        'group-leave',
        'member-menu-$kaiId',
        'member-confirm-$miaId',
      ]) {
        final finder = find.byKey(Key(key));
        expect(finder, findsOneWidget, reason: key);
        expect(
          tester.getSize(finder).height,
          greaterThanOrEqualTo(48 - .01),
          reason: key,
        );
        expect(
          tester.getSemantics(finder).label.trim(),
          isNotEmpty,
          reason: key,
        );
      }
      // The photo stack is decoration: the title block carries the count.
      expect(find.bySemanticsLabel('Weekend crew, 4 members'), findsOneWidget);
      handle.dispose();
    });

    spec('RTL: the list, the thread, the picker and Group info mirror', (
      tester,
    ) async {
      engine.list = [
        chat(1, 'Mira Kapoor', 'mira', msg('a', 'hey', when(9, 0))),
      ];
      engine.groupList = [
        grp(unread: 2, last: gmsg('1', samId, 'hello', when(11, 0))),
      ];
      engine.invites = [invite()];
      engine.infos[gid] = grp();
      engine.messages = [
        gmsg('2', samId, 'who is in?', when(9, 5)),
        gmsg('3', meId, 'me', when(9, 8)),
      ];
      // The list: the avatar stack is on the right in right-to-left.
      await pump(tester, '/chats', direction: TextDirection.rtl);
      noOverflow(tester);
      expect(
        tester.getCenter(find.byKey(const Key('group-avatar-stack')).first).dx,
        greaterThan(195),
      );
      // The thread: others' bubbles and their names start at the right, yours at the left.
      await pump(tester, chatPath(gid), direction: TextDirection.rtl);
      noOverflow(tester);
      final name = tester.getTopRight(find.text('Sam Rivera')).dx;
      final theirs = tester.getTopRight(find.text('who is in?')).dx;
      final mine = tester.getTopLeft(find.text('me')).dx;
      expect(name, greaterThan(195));
      expect(theirs, greaterThan(195));
      expect(mine, lessThan(195));
      // The picker.
      engine.list = [
        chat(1, 'Mira Kapoor', 'mira', msg('a', 'hey', when(9, 0))),
      ];
      await pumpScreen(
        tester,
        const NewGroupScreen(),
        direction: TextDirection.rtl,
        size: narrow,
        textScale: 2,
      );
      noOverflow(tester);
      // Group info.
      await pumpScreen(
        tester,
        GroupInfoScreen(id: gid, openProfile: (context, id) {}),
        direction: TextDirection.rtl,
        size: narrow,
      );
      noOverflow(tester);
      expect(
        tester.getCenter(find.byKey(const Key('group-info-title'))).dx,
        closeTo(160, 40),
      );
    });
  });
}
