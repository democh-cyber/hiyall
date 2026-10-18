import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/chat/chat_api.dart';
import 'package:hiyall/core/chat/chat_attachment.dart';
import 'package:hiyall/core/chat/chat_engine.dart';
import 'package:hiyall/core/chat/chat_groups.dart';
import 'package:hiyall/core/chat/chat_local_data.dart';
import 'package:hiyall/core/chat/chat_snapshot.dart';
import 'package:hiyall/core/chat/chat_store.dart';
import 'package:hiyall/src/rust/frb_generated.dart';

import 'chat_av_helpers.dart' show AvCloud, AvCodec, voiceClip;
import 'chat_groups_helpers.dart';
import 'chat_photo_helpers.dart' show FakeCloudProxy;

const heart = '❤️';
const thumbs = '\u{1F44D}';

/// A payload's relay metadata for the parser tests.
Map<String, dynamic> controlBody(
  String op, {
  String sender = bobId,
  Object? subject,
  Object? name,
  Object? owner,
  String conversation = groupId,
  String? messageId,
}) => {
  'v': 1,
  'kind': 'group',
  'text': '',
  'op': op,
  'subject': ?subject,
  'name': ?name,
  'owner': ?owner,
  'messageId': messageId ?? uuid(1),
  'conversationId': conversation,
  'senderId': sender,
  'sentAt': '2026-10-13T12:00:00Z',
};

Incoming parse(
  Map<String, dynamic> body, {
  bool aux = true,
  String sender = bobId,
  String? messageId,
}) => parseIncoming(
  body,
  messageId: messageId ?? uuid(1),
  conversationId: groupId,
  senderId: sender,
  me: aliceId,
  aux: aux,
);

/// Answers every request with a canned envelope and remembers what was asked.
class _Recorder implements HttpClientAdapter {
  final seen = <RequestOptions>[];
  Object? answer = <String, dynamic>{};
  int status = 200;
  Map<String, dynamic>? error;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    seen.add(options);
    return ResponseBody.fromString(
      jsonEncode(error != null ? {'error': error} : {'data': answer}),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  group('group routes (no Olm)', () {
    late _Recorder wire;
    late ChatApi api;
    setUp(() {
      wire = _Recorder();
      api = ChatApi(
        'http://127.0.0.1:1',
        't',
        dio: Dio(BaseOptions(baseUrl: 'http://127.0.0.1:1'))
          ..httpClientAdapter = wire,
      );
    });
    String route(int i) => '${wire.seen[i].method} ${wire.seen[i].path}';

    test('every route, its method, path and body', () async {
      final control = {
        'messageId': uuid(1),
        'senderDeviceId': uuid(2),
        'envelopes': [],
      };
      wire.answer = {'groupId': groupId};
      await api.createGroup('crew', [bobId, carolId]);
      await api.createGroup('', [bobId, carolId]);
      await api.group(groupId);
      await api.inviteToGroup(groupId, [daveId]);
      await api.acceptGroupInvite(groupId, control);
      await api.renameGroup(groupId, 'new', control);
      await api.removeGroupMember(groupId, bobId, control: control);
      await api.removeGroupMember(groupId, daveId);
      wire.answer = {'left': true};
      await api.leaveGroup(groupId, control: control, newOwnerId: bobId);
      await api.leaveGroup(groupId);
      wire.answer = {'declined': true};
      await api.declineGroupInvite(groupId);
      wire.answer = {'items': []};
      await api.groups();
      await api.hiddenGroups();
      await api.groupInvites();
      expect(
        [for (var i = 0; i < wire.seen.length; i++) route(i)],
        [
          'POST /v1/groups',
          'POST /v1/groups',
          'GET /v1/groups/$groupId',
          'POST /v1/groups/$groupId/members',
          'POST /v1/groups/$groupId/accept',
          'PATCH /v1/groups/$groupId',
          'POST /v1/groups/$groupId/members/$bobId/remove',
          'POST /v1/groups/$groupId/members/$daveId/remove',
          'POST /v1/groups/$groupId/leave',
          'POST /v1/groups/$groupId/leave',
          'POST /v1/groups/$groupId/decline',
          'GET /v1/groups',
          'GET /v1/groups/hidden',
          'GET /v1/groups/invites',
        ],
      );
      expect(wire.seen[0].data, {
        'name': 'crew',
        'memberIds': [bobId, carolId],
      });
      expect(wire.seen[1].data, {
        'memberIds': [bobId, carolId],
      });
      expect(wire.seen[3].data, {
        'userIds': [daveId],
      });
      expect(wire.seen[4].data, {'control': control});
      expect(wire.seen[5].data, {'name': 'new', 'control': control});
      expect(wire.seen[6].data, {'control': control});
      expect(
        wire.seen[7].data,
        isNull,
        reason: 'a pending invite is cancelled with no body',
      );
      expect(wire.seen[8].data, {'control': control, 'newOwnerId': bobId});
      expect(wire.seen[9].data, isEmpty);
    });

    test('a refusal keeps its code and the person it names', () async {
      wire
        ..status = 409
        ..error = {
          'code': 'CANNOT_ADD_MEMBER',
          'message': 'That person cannot be added.',
          'details': {'userId': carolId},
        };
      await expectLater(
        api.createGroup('x', [bobId, carolId]),
        throwsA(
          isA<ChatFailure>()
              .having((e) => e.code, 'code', 'CANNOT_ADD_MEMBER')
              .having((e) => e.status, 'status', 409)
              .having((e) => e.details?['userId'], 'who', carolId),
        ),
      );
    });

    test('the relay\'s Group reads into GroupInfo, events included', () {
      final info = GroupInfo.parse({
        'groupId': groupId,
        'ownerId': aliceId,
        'name': 'crew',
        'status': 'closed',
        'myState': 'invited',
        'createdAt': '2026-10-13T12:00:00Z',
        'members': [
          {
            'userId': aliceId,
            'username': 'alice',
            'displayName': 'Alice',
            'role': 'owner',
          },
        ],
        'events': [
          {
            'eventId': uuid(3),
            'kind': 'removed',
            'subjectId': bobId,
            'at': '2026-10-13T12:01:00Z',
          },
        ],
      })!;
      expect(info.closed, isTrue);
      expect(info.readOnly, isTrue);
      expect(info.invited, isTrue);
      expect(info.members.single.owner, isTrue);
      expect(info.events.single.subjectId, bobId);
    });
  });

  group('group payloads (no Olm)', () {
    test('a membership message is read only when the relay flagged it aux', () {
      expect(
        parse(controlBody('join', subject: bobId)),
        isA<IncomingGroupEvent>(),
      );
      // aux and kind must agree: a `group` kind without the flag is dropped, never an error.
      expect(
        parse(controlBody('join', subject: bobId), aux: false),
        isA<IncomingIgnored>(),
      );
      // ... and the flag on anything but reaction, noop and group still drops it.
      final text = {...controlBody('join', subject: bobId), 'kind': 'text'};
      expect(parse(text), isA<IncomingIgnored>());
      final image = {...controlBody('join', subject: bobId), 'kind': 'image'};
      expect(parse(image), isA<IncomingIgnored>());
    });

    test('each op accepts only its own shape', () {
      IncomingGroupEvent ok(Map<String, dynamic> b) =>
          parse(b) as IncomingGroupEvent;
      expect(ok(controlBody('join', subject: bobId)).subject, bobId);
      expect(ok(controlBody('leave', subject: bobId)).owner, isNull);
      expect(
        ok(controlBody('leave', subject: bobId, owner: carolId)).owner,
        carolId,
      );
      expect(ok(controlBody('remove', subject: carolId)).subject, carolId);
      expect(
        ok(controlBody('rename', name: 'weekend crew')).name,
        'weekend crew',
      );
      expect(ok(controlBody('rename', name: '')).name, '');

      final bad = <String, Map<String, dynamic>>{
        'join for someone else': controlBody('join', subject: carolId),
        'leave for someone else': controlBody('leave', subject: carolId),
        'join without subject': controlBody('join'),
        'remove of the sender': controlBody('remove', subject: bobId),
        'remove without subject': controlBody('remove'),
        'remove of a non id': controlBody('remove', subject: 'sam'),
        'rename too long': controlBody('rename', name: 'x' * 41),
        'rename not text': controlBody('rename', name: 5),
        'rename with a control character': controlBody(
          'rename',
          name: 'a\u202Eb',
        ),
        'rename with a line break': controlBody('rename', name: 'a\nb'),
        'unknown op': controlBody('promote', subject: bobId),
        'no op': {...controlBody('join', subject: bobId)}..remove('op'),
      };
      bad.forEach((why, body) {
        expect(parse(body), isA<IncomingIgnored>(), reason: why);
      });
      // A leave that names a bad new owner is still a leave; the owner field is dropped.
      expect(
        ok(controlBody('leave', subject: bobId, owner: 'nobody')).owner,
        isNull,
      );
      expect(
        ok(controlBody('leave', subject: bobId, owner: bobId)).owner,
        isNull,
      );
    });

    test(
      'the relay metadata binding still rejects a forged membership message',
      () {
        for (final change in <void Function(Map<String, dynamic>)>[
          (b) => b['senderId'] = aliceId,
          (b) => b['conversationId'] = uuid(77),
          (b) => b['messageId'] = uuid(2),
          (b) => b['v'] = 2,
          (b) => b.remove('text'),
        ]) {
          final b = controlBody('remove', subject: carolId);
          change(b);
          expect(
            () => parse(b),
            throwsA(
              isA<ChatFailure>().having((e) => e.code, 'code', 'MISMATCH'),
            ),
          );
        }
      },
    );

    test('a group quote may name any member the phone has seen', () {
      Incoming read(Set<String>? members) => parseIncoming(
        {
          'v': 1,
          'kind': 'text',
          'text': 'yes',
          'messageId': uuid(5),
          'conversationId': groupId,
          'senderId': carolId,
          'sentAt': '2026-10-13T12:00:00Z',
          're': {'id': uuid(4), 'by': bobId, 'snip': 'idea', 'k': 'text'},
        },
        messageId: uuid(5),
        conversationId: groupId,
        senderId: carolId,
        me: aliceId,
        members: members,
      );
      expect(
        (read({aliceId, bobId, carolId}) as IncomingMessage).message.reply?.by,
        bobId,
      );
      expect(
        (read({aliceId, carolId}) as IncomingMessage).message.reply,
        isNull,
        reason: 'a quote of someone outside the group is dropped',
      );
    });
  });

  group('group chat over the real Olm core', skip: _coreMissing(), () {
    setUpAll(() async {
      await RustLib.init(externalLibrary: ExternalLibrary.open(_corePath));
    });

    var tick = 0;
    late GroupRelay relay;
    final engines = <ChatEngine>[];
    final temp = <Directory>[];

    Future<ChatEngine> device(
      String user, {
      ChatStore? store,
      AvCloud? cloud,
      Duration ttl = Duration.zero,
      DateTime Function()? clock,
    }) async {
      Directory? root;
      if (cloud != null) {
        root = Directory.systemTemp.createTempSync('hiyall_group_$user');
        temp.add(root);
      }
      final e = ChatEngine(
        userId: user,
        api: GroupApi(relay, user, cloud: cloud),
        store: store ?? MemoryChatStore(),
        platform: 'test',
        codec: cloud == null ? null : AvCodec(),
        transport: cloud == null ? null : FakeCloudProxy(cloud),
        mediaRoot: root,
        reactionRetryDelays: const [Duration.zero],
        groupRosterTtl: ttl,
        clock:
            clock ?? () => DateTime.utc(2026, 10, 13, 12, 0, 0, 0, tick++ * 10),
      );
      await e.start(poll: Duration.zero);
      engines.add(e);
      return e;
    }

    setUp(() {
      relay = GroupRelay();
      engines.clear();
      tick = 0;
    });
    tearDown(() async {
      for (final e in engines) {
        await e.dispose();
      }
      for (final d in temp) {
        if (d.existsSync()) d.deleteSync(recursive: true);
      }
      temp.clear();
    });

    Future<void> settle() async {
      for (var round = 0; round < 3; round++) {
        for (final e in engines) {
          await e.pollNow();
        }
      }
    }

    Set<String> ids(String user) => relay.deviceIds(user).toSet();

    Future<List<String>> texts(ChatEngine e) async => [
      for (final m in await e.history(groupId))
        if (!m.notice) m.text,
    ];
    Future<List<String>> notices(ChatEngine e) async => [
      for (final m in await e.history(groupId))
        if (m.notice) m.text,
    ];

    /// Alice (a phone and a tablet), Bob and Carol, in one group Alice made, all joined and caught up.
    Future<
      ({ChatEngine alice, ChatEngine tablet, ChatEngine bob, ChatEngine carol})
    >
    crew({bool join = true}) async {
      final alice = await device(aliceId);
      final tablet = await device(aliceId);
      final bob = await device(bobId);
      final carol = await device(carolId);
      await alice.createGroup(name: '', memberIds: [bobId, carolId]);
      if (join) {
        await bob.acceptGroupInvite(groupId);
        await settle();
        await carol.acceptGroupInvite(groupId);
        await settle();
      }
      return (alice: alice, tablet: tablet, bob: bob, carol: carol);
    }

    Future<ChatMessage> settled(ChatEngine e, String id) async {
      for (var i = 0; i < 400; i++) {
        final m = (await e.history(groupId))
            .where((m) => m.messageId == id)
            .firstOrNull;
        if (m != null && m.status != SendStatus.sending) return m;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      fail('message $id did not settle');
    }

    Matcher failure(String code) =>
        throwsA(isA<ChatFailure>().having((e) => e.code, 'code', code));

    group('creating, joining and sending', () {
      test(
        'an invitation, a join and a text that reaches all three people',
        () async {
          final alice = await device(aliceId);
          final tablet = await device(aliceId);
          final bob = await device(bobId);
          final carol = await device(carolId);
          final made = await alice.createGroup(
            name: 'friday',
            memberIds: [bobId, carolId],
          );
          expect(made.id, groupId);
          expect(made.members.map((m) => m.userId), [aliceId]);
          expect(
            made.pending.map((p) => p.userId),
            unorderedEquals([bobId, carolId]),
          );
          expect(alice.isGroup(groupId), isTrue);
          expect(
            bob.isGroup(groupId),
            isFalse,
            reason: 'an invitation is no group yet',
          );

          final invites = await bob.groupInvites();
          expect(invites.single.groupId, groupId);
          expect(invites.single.invitedBy.userId, aliceId);
          expect(invites.single.name, 'friday');

          await bob.acceptGroupInvite(groupId);
          await carol.acceptGroupInvite(groupId);
          await settle();

          // Everyone is in the group; no control message was unread or counted.
          expect(relay.unread, isEmpty);
          expect(
            relay.wire.where((w) => w.kind == 'accept').every((w) => w.aux),
            isTrue,
          );

          await alice.send(groupId, groupPeer, 'hello crew');
          await settle();
          for (final e in [bob, carol, tablet, alice]) {
            expect(await texts(e), ['hello crew'], reason: e.userId);
          }
          // One envelope per device of Bob and Carol, and the tablet: nothing for the sending phone.
          final sent = relay.wire.lastWhere((w) => w.kind == 'message');
          expect(sent.devices.toSet(), {
            ...ids(bobId),
            ...ids(carolId),
            tablet.deviceId,
          });
          expect(sent.aux, isFalse);

          await bob.send(groupId, groupPeer, 'hi alice');
          await settle();
          for (final e in [alice, carol, tablet, bob]) {
            expect(await texts(e), [
              'hello crew',
              'hi alice',
            ], reason: e.userId);
          }
          // Each reader sees who sent what.
          final seen = (await carol.history(groupId))
              .where((m) => !m.notice)
              .toList();
          expect(seen.map((m) => m.senderId), [aliceId, bobId]);
          expect(seen.map((m) => m.mine), [false, false]);
        },
      );

      test('joins show as notices, once, from the relay events or the message alike', () async {
        final c = await crew();
        expect(await notices(c.alice), ['Bob joined', 'Carol joined']);
        expect(await notices(c.tablet), ['Bob joined', 'Carol joined']);
        expect(await notices(c.bob), ['You joined', 'Carol joined']);
        expect(await notices(c.carol), ['You joined']);
        // Reading the relay's events again shows nothing twice.
        await c.alice.group(groupId);
        await c.alice.group(groupId);
        await c.bob.group(groupId);
        expect(await notices(c.alice), ['Bob joined', 'Carol joined']);
        expect(await notices(c.bob), ['You joined', 'Carol joined']);
      });

      test('the creator accounts only for themself until a join message proves the rest', () async {
        final c = await crew(join: false);
        await c.bob.acceptGroupInvite(groupId);
        // Bob is listed but his join has not arrived on Alice's phone.
        var info = await c.alice.group(groupId);
        expect(info.members.map((m) => m.userId), contains(bobId));
        expect(info.unconfirmed, {bobId});
        // Bob, who joined from the relay's first snapshot, accounts for Alice.
        info = await c.bob.group(groupId);
        expect(info.unconfirmed, isEmpty);
        await c.alice.pollNow();
        info = await c.alice.group(groupId);
        expect(info.unconfirmed, isEmpty);
        // The join notice came from the relay event first and the message did not add another.
        expect(await notices(c.alice), ['Bob joined']);
      });

      test('a join in flight is waited for: the inbox is read once and the send retried', () async {
        final c = await crew(join: false);
        await c.bob.acceptGroupInvite(groupId);
        await settle();
        await c.carol.acceptGroupInvite(groupId);
        // Alice has not read Carol's join yet: the relay lists her, Alice does not account for her.
        final before = relay.wire.length;
        await c.alice.send(groupId, groupPeer, 'are you there?');
        final requests = relay.wire.skip(before).toList();
        expect(requests.length, 3, reason: 'two refusals, then the send');
        expect(requests[0].devices.toSet().intersection(ids(carolId)), isEmpty);
        expect(requests[1].devices.toSet().intersection(ids(carolId)), isEmpty);
        expect(requests[2].devices.toSet(), containsAll(ids(carolId)));
        await settle();
        expect(await texts(c.carol), ['are you there?']);
      });

      test(
        'a send is retried once on DEVICES_CHANGED with the roster read again',
        () async {
          final c = await crew();
          // Bob gets a second phone Alice does not know about yet.
          final bob2 = await device(bobId);
          await c.alice.send(groupId, groupPeer, 'both phones');
          await settle();
          for (final e in [c.bob, bob2, c.carol]) {
            expect(await texts(e), ['both phones'], reason: e.deviceId);
          }
        },
      );

      test('a new device of a member is announced in the group', () async {
        final c = await crew();
        await c.alice.send(groupId, groupPeer, 'a');
        final bob2 = await device(bobId);
        await c.alice.send(groupId, groupPeer, 'b');
        await settle();
        expect(
          await notices(c.alice),
          contains('A new device was added to this account.'),
        );
        expect(await texts(bob2), ['b']);
      });

      test(
        'the member list is used for the cache time and read again after',
        () async {
          final fixed = DateTime.utc(2026, 10, 13, 12);
          final alice = await device(
            aliceId,
            ttl: const Duration(seconds: 30),
            clock: () => fixed,
          );
          final bob = await device(bobId);
          final carol = await device(carolId);
          await alice.createGroup(memberIds: [bobId, carolId]);
          await bob.acceptGroupInvite(groupId);
          await carol.acceptGroupInvite(groupId);
          await alice.pollNow();
          await alice.send(groupId, groupPeer, 'one');
          final reads = relay.count('group ');
          await alice.send(groupId, groupPeer, 'two');
          expect(
            relay.count('group '),
            reads,
            reason: 'the cached list was used',
          );
        },
      );

      test('nobody to send to: GROUP_WAITING, and nothing is kept', () async {
        final c = await crew();
        relay.devices[bobId]!.clear();
        relay.devices[carolId]!.clear();
        await expectLater(
          c.alice.send(groupId, groupPeer, 'anyone?'),
          throwsA(
            isA<ChatFailure>()
                .having((e) => e.code, 'code', 'GROUP_WAITING')
                .having((e) => e.status, 'status', 409),
          ),
        );
        expect(await texts(c.alice), isEmpty);
      });

      test(
        'an empty peer id still fails for a chat that is not a group',
        () async {
          final alice = await device(aliceId);
          await expectLater(
            alice.send(uuid(800), '', 'hi'),
            throwsA(isA<ChatFailure>()),
          );
          expect((await alice.history(uuid(800))), isEmpty);
        },
      );

      test(
        'the relay refuses someone: CANNOT_ADD_MEMBER names the person',
        () async {
          final alice = await device(aliceId);
          relay.cannotAdd.add(carolId);
          await expectLater(
            alice.createGroup(memberIds: [bobId, carolId]),
            throwsA(
              isA<ChatFailure>()
                  .having((e) => e.code, 'code', 'CANNOT_ADD_MEMBER')
                  .having((e) => e.details?['userId'], 'who', carolId),
            ),
          );
          expect(relay.groups, isEmpty);
          expect(alice.groupDirectory(groupId), isEmpty);
        },
      );

      test(
        'declining tells nobody; the last invite ends a group of one',
        () async {
          final alice = await device(aliceId);
          final bob = await device(bobId);
          final carol = await device(carolId);
          await alice.createGroup(memberIds: [bobId, carolId]);
          await bob.declineGroupInvite(groupId);
          expect(await bob.groupInvites(), isEmpty);
          expect(await carol.groupInvites(), hasLength(1));
          expect(relay.groups[groupId]!.status, 'active');
          await carol.declineGroupInvite(groupId);
          expect(relay.groups[groupId]!.status, 'closed');
          final info = await alice.group(groupId);
          expect(info.closed, isTrue);
          expect(info.readOnly, isTrue);
          await expectLater(
            alice.send(groupId, groupPeer, 'hello?'),
            failure('CONVERSATION_CLOSED'),
          );
        },
      );
    });

    group('attachments and reactions', () {
      test('a voice message and a photo reach every member with the key inside the payload', () async {
        final cloud = AvCloud();
        final alice = await device(aliceId, cloud: cloud);
        final tablet = await device(aliceId, cloud: cloud);
        final bob = await device(bobId, cloud: cloud);
        final carol = await device(carolId, cloud: cloud);
        await alice.createGroup(memberIds: [bobId, carolId]);
        await bob.acceptGroupInvite(groupId);
        await settle();
        await carol.acceptGroupInvite(groupId);
        await settle();

        final clip = voiceClip(bytes: 4000, durationMs: 7000);
        final voice = await bob.sendVoice(groupId, groupPeer, clip);
        expect((await settled(bob, voice.messageId)).status, SendStatus.sent);
        // One blob was uploaded once; the relay was told which, not what.
        expect(cloud.live.map((s) => s.role), ['voice']);
        await settle();
        for (final e in [alice, tablet, carol]) {
          final got = (await e.history(groupId)).where((m) => m.isVoice).single;
          expect(got.voice!.durationMs, 7000, reason: e.deviceId);
          expect(
            await e.media!.plaintextBlob(groupId, got.voice!.spec),
            clip.bytes,
          );
        }

        final photo = await carol.sendPhoto(
          groupId,
          groupPeer,
          Uint8List.fromList([1, 2, 3]),
          caption: 'view',
        );
        final done = await settled(carol, photo.messageId);
        expect(done.status, SendStatus.sent);
        await settle();
        for (final e in [alice, tablet, bob]) {
          final got = (await e.history(groupId)).where((m) => m.isPhoto).single;
          expect(got.attachment!.key, done.attachment!.key, reason: e.deviceId);
          expect(got.attachment!.caption, 'view');
        }
        // The photo went out in one request to everyone's devices.
        final sent = relay.wire.lastWhere((w) => w.kind == 'message');
        expect(sent.devices.toSet(), {...ids(aliceId), ...ids(bobId)});
      });

      test('reactions: one per member per message, seen by everyone', () async {
        final c = await crew();
        await c.alice.send(groupId, groupPeer, 'good morning');
        await settle();
        final target = (await c.bob.history(groupId))
            .where((m) => !m.notice)
            .single;
        await c.carol.react(groupId, groupPeer, target.messageId, heart);
        await c.bob.react(groupId, groupPeer, target.messageId, thumbs);
        await c.carol.react(groupId, groupPeer, target.messageId, thumbs);
        await settle();
        for (final e in [c.alice, c.tablet, c.bob, c.carol]) {
          final m = (await e.history(groupId)).where((m) => !m.notice).single;
          expect(m.reactions, {
            carolId: thumbs,
            bobId: thumbs,
          }, reason: e.userId);
        }
        expect(
          relay.wire.where((w) => w.aux && w.kind == 'message'),
          hasLength(3),
        );
        expect(relay.unread[bobId], 1, reason: 'only the text was unread');
      });

      test('a reply may quote any member of the group', () async {
        final c = await crew();
        await c.bob.send(groupId, groupPeer, 'pizza?');
        await settle();
        final idea = (await c.carol.history(groupId))
            .where((m) => !m.notice)
            .single;
        await c.carol.send(groupId, groupPeer, 'yes!', replyTo: idea);
        await settle();
        final reply = (await c.alice.history(groupId))
            .where((m) => m.text == 'yes!')
            .single;
        expect(reply.reply?.by, bobId);
        expect(reply.reply?.snippet, 'pizza?');
      });
    });

    group('membership', () {
      test('a new member sees only what is sent after they join', () async {
        final c = await crew(join: false);
        await c.bob.acceptGroupInvite(groupId);
        await settle();
        await c.alice.send(groupId, groupPeer, 'before carol');
        await settle();
        await c.carol.acceptGroupInvite(groupId);
        await settle();
        await c.alice.send(groupId, groupPeer, 'after carol');
        await settle();
        expect(await texts(c.carol), ['after carol']);
        expect(await texts(c.bob), ['before carol', 'after carol']);
        expect(await notices(c.carol), ['You joined']);
        // Nothing of the earlier message was ever sealed for Carol's devices.
        final first = relay.wire.firstWhere(
          (w) => w.kind == 'message' && w.from == aliceId,
        );
        expect(first.devices.toSet().intersection(ids(carolId)), isEmpty);
      });

      test('a removed member sees it and stops; the others stop sealing for them even if the relay still lists them', () async {
        final c = await crew();
        await c.alice.send(groupId, groupPeer, 'one');
        await settle();

        await c.alice.removeFromGroup(groupId, carolId);
        await settle();
        expect(
          await notices(c.carol),
          contains('You were removed from this group'),
        );
        expect(c.carol.isGroupReadOnly(groupId), isTrue);
        expect(await notices(c.bob), contains('Alice removed Carol'));
        expect(await notices(c.alice), contains('You removed Carol'));
        expect(await notices(c.tablet), contains('You removed Carol'));
        // She keeps what she had, and can send nothing more.
        expect(await texts(c.carol), ['one']);
        await expectLater(
          c.carol.send(groupId, groupPeer, 'wait'),
          failure('CONVERSATION_CLOSED'),
        );
        // The removal went to her phone too.
        final removal = relay.wire.lastWhere((w) => w.kind == 'remove');
        expect(removal.devices.toSet(), containsAll(ids(carolId)));
        expect(removal.aux, isTrue);

        // The relay "forgets" the removal and keeps listing her.
        relay.groups[groupId]!.members.add(carolId);
        final before = relay.wire.length;
        await expectLater(
          c.bob.send(groupId, groupPeer, 'two'),
          failure('GROUP_OUT_OF_SYNC'),
        );
        await expectLater(
          c.alice.send(groupId, groupPeer, 'three'),
          failure('GROUP_OUT_OF_SYNC'),
        );
        for (final w in relay.wire.skip(before)) {
          expect(
            w.devices.toSet().intersection(ids(carolId)),
            isEmpty,
            reason:
                '${w.kind} from ${w.from} must not carry an envelope for her',
          );
        }
        expect(await texts(c.carol), ['one']);
        expect(relay.inboxes[c.carol.deviceId], isEmpty);
        final info = await c.bob.group(groupId);
        expect(info.outOfSync, {carolId});
        expect(info.unconfirmed, isEmpty);
        // The message that could not go is not left in the thread.
        expect(await texts(c.bob), ['one']);

        // The relay is honest again and sending works for the rest.
        relay.groups[groupId]!.members.remove(carolId);
        await c.bob.send(groupId, groupPeer, 'four');
        await settle();
        expect(await texts(c.alice), ['one', 'four']);
        expect(await texts(c.carol), ['one']);
      });

      test('a removal mark survives a restart', () async {
        final store = MemoryChatStore();
        final alice = await device(aliceId);
        var bob = await device(bobId, store: store);
        final carol = await device(carolId);
        await alice.createGroup(memberIds: [bobId, carolId]);
        await bob.acceptGroupInvite(groupId);
        await settle();
        await carol.acceptGroupInvite(groupId);
        await settle();
        await alice.removeFromGroup(groupId, carolId);
        await settle();
        await bob.dispose();
        bob = await device(bobId, store: store);
        expect(bob.isGroup(groupId), isTrue);
        expect(
          bob.groupDirectory(groupId).keys,
          containsAll([aliceId, bobId, carolId]),
        );
        relay.groups[groupId]!.members.add(carolId);
        await expectLater(
          bob.send(groupId, groupPeer, 'still?'),
          failure('GROUP_OUT_OF_SYNC'),
        );
      });

      test('a member who leaves is gone from the rest, and read-only on their own phone', () async {
        final c = await crew();
        await c.bob.leaveGroup(groupId);
        await settle();
        expect(await notices(c.bob), contains('You left'));
        expect(c.bob.isGroupReadOnly(groupId), isTrue);
        expect(await notices(c.alice), contains('Bob left'));
        expect(await notices(c.carol), contains('Bob left'));
        final leave = relay.wire.lastWhere((w) => w.kind == 'leave');
        expect(leave.devices.toSet(), {
          ...ids(carolId),
          c.alice.deviceId,
          c.tablet.deviceId,
        });
        await c.alice.send(groupId, groupPeer, 'just us');
        await settle();
        expect(await texts(c.carol), ['just us']);
        expect(await texts(c.bob), isEmpty);
        final sent = relay.wire.lastWhere((w) => w.kind == 'message');
        expect(sent.devices.toSet().intersection(ids(bobId)), isEmpty);
      });

      test('the owner leaving names who takes over, and that person can then rename', () async {
        final c = await crew();
        await expectLater(c.alice.leaveGroup(groupId), failure('VALIDATION'));
        await expectLater(
          c.alice.leaveGroup(groupId, newOwnerId: daveId),
          failure('VALIDATION'),
        );
        expect(relay.wire.where((w) => w.kind == 'leave'), isEmpty);
        await c.alice.leaveGroup(groupId, newOwnerId: bobId);
        await settle();
        expect(relay.groups[groupId]!.ownerId, bobId);
        expect(await notices(c.carol), contains('Alice left'));
        // Carol learnt the new owner from the message, not only from the relay.
        await c.bob.renameGroup(groupId, 'bob and carol');
        await settle();
        expect(
          await notices(c.carol),
          contains('Bob renamed the group to “bob and carol”'),
        );
      });

      test('a group of two is left when one of three goes; the last one leaving closes it', () async {
        final c = await crew();
        await c.carol.leaveGroup(groupId);
        await settle();
        expect(relay.groups[groupId]!.status, 'active');
        await c.bob.leaveGroup(groupId);
        await settle();
        expect(relay.groups[groupId]!.status, 'closed');
        final info = await c.alice.group(groupId);
        expect(info.readOnly, isTrue);
      });

      test('the owner renames the group and every phone shows it', () async {
        final c = await crew();
        final info = await c.alice.renameGroup(groupId, 'weekend crew');
        expect(info.name, 'weekend crew');
        await settle();
        for (final e in [c.bob, c.carol]) {
          expect(
            await notices(e),
            contains('Alice renamed the group to “weekend crew”'),
            reason: e.userId,
          );
        }
        // Her other phone says it from her point of view.
        expect(
          await notices(c.tablet),
          contains('You renamed the group to “weekend crew”'),
        );
        expect(
          await notices(c.alice),
          contains('You renamed the group to “weekend crew”'),
        );
        final rename = relay.wire.lastWhere((w) => w.kind == 'rename');
        expect(rename.devices.toSet(), {
          ...ids(bobId),
          ...ids(carolId),
          c.tablet.deviceId,
        });
        await c.alice.renameGroup(groupId, '');
        await settle();
        expect(await notices(c.bob), contains('Alice removed the group name'));
        await expectLater(
          c.alice.renameGroup(groupId, 'x' * 41),
          failure('VALIDATION'),
        );
        // A member who is not the owner is refused by the relay.
        await expectLater(
          c.bob.renameGroup(groupId, 'mine'),
          failure('GROUP_NOT_OWNER'),
        );
      });

      test('the owner invites more people; a pending invite is cancelled without a message', () async {
        final c = await crew();
        await device(daveId);
        final info = await c.alice.inviteToGroup(groupId, [daveId]);
        expect(info.pending.map((p) => p.userId), [daveId]);
        final before = relay.wire.length;
        final after = await c.alice.removeFromGroup(groupId, daveId);
        expect(after.pending, isEmpty);
        expect(
          relay.wire.length,
          before,
          reason: 'no control message for a pending invite',
        );
        await expectLater(
          c.alice.removeFromGroup(groupId, aliceId),
          failure('VALIDATION'),
        );
      });

      test('a member the relay lists but no join accounts for is not sealed for until confirmed', () async {
        final c = await crew();
        final dave = await device(daveId);
        // The relay invents a member.
        relay.groups[groupId]!.members.add(daveId);
        final before = relay.wire.length;
        await expectLater(
          c.alice.send(groupId, groupPeer, 'secret plans'),
          failure('GROUP_UNCONFIRMED_MEMBER'),
        );
        for (final w in relay.wire.skip(before)) {
          expect(w.devices.toSet().intersection(ids(daveId)), isEmpty);
        }
        expect(relay.inboxes[dave.deviceId] ?? [], isEmpty);
        final info = await c.alice.group(groupId);
        expect(info.unconfirmed, {daveId});
        expect(info.outOfSync, isEmpty);

        await c.alice.confirmGroupMember(groupId, daveId);
        await c.alice.send(groupId, groupPeer, 'now with dave');
        final sent = relay.wire.lastWhere((w) => w.kind == 'message');
        expect(sent.devices.toSet(), containsAll(ids(daveId)));
        expect((await c.alice.group(groupId)).unconfirmed, isEmpty);
        // Confirming someone the relay does not list does nothing.
        await expectLater(
          c.alice.confirmGroupMember(groupId, malloryId),
          failure('NOT_FOUND'),
        );
      });

      test('an account the relay says was deleted becomes a notice and a removal mark', () async {
        final c = await crew();
        relay.deleteAccount(carolId);
        var info = await c.alice.group(groupId);
        expect(info.members.map((m) => m.userId), isNot(contains(carolId)));
        expect(
          await notices(c.alice),
          contains('A member deleted their account'),
        );
        // Reading the same events again changes nothing.
        await c.alice.group(groupId);
        expect(
          (await notices(c.alice))
              .where((n) => n.startsWith('A member deleted')),
          hasLength(1),
        );
        // The mark is on the id: a relay that lists her again is not believed.
        relay.devices[carolId] = {};
        relay.groups[groupId]!.members.add(carolId);
        info = await c.alice.group(groupId);
        expect(info.outOfSync, {carolId});
        // Her name is still known for the messages she sent.
        expect(c.alice.groupDirectory(groupId)[carolId]?.name, 'Carol');
      });

      test('a membership event the message did not reach is shown from the relay, and not twice', () async {
        final c = await crew();
        await c.alice.removeFromGroup(groupId, bobId);
        // Carol has not read the message yet: the relay's event already tells her.
        final info = await c.carol.group(groupId);
        expect(
          info.outOfSync,
          isEmpty,
          reason: 'the relay no longer lists Bob',
        );
        expect(await notices(c.carol), contains('Alice removed Bob'));
        await c.carol.pollNow();
        expect(
          (await notices(c.carol)).where((n) => n == 'Alice removed Bob'),
          hasLength(1),
        );
        // The authenticated message is what lets the phone trust it: Bob stays marked on a lying relay.
        relay.groups[groupId]!.members.add(bobId);
        await expectLater(
          c.carol.send(groupId, groupPeer, 'x'),
          failure('GROUP_OUT_OF_SYNC'),
        );
      });

      test('after a block the relay leaves a member out of the list and senders stop sealing for them', () async {
        final c = await crew();
        // The relay hides Carol from Bob (a block between them): she is simply not in Bob's list.
        // Modelled by the relay listing members per caller.
        relay.groups[groupId]!.members.remove(carolId);
        await c.bob.send(groupId, groupPeer, 'only alice');
        final sent = relay.wire.lastWhere((w) => w.kind == 'message');
        expect(sent.devices.toSet().intersection(ids(carolId)), isEmpty);
        relay.groups[groupId]!.members.add(carolId);
      });
    });

    group('what a phone refuses to believe', () {
      Future<RawDevice> mallory(ChatEngine alice) async {
        relay.groups[groupId]!.members.add(malloryId);
        return RawDevice(relay, malloryId);
      }

      test('a membership message the relay did not flag aux is dropped without a trace', () async {
        final c = await crew();
        relay.stripControlAux = true;
        await c.alice.renameGroup(groupId, 'hidden');
        await settle();
        expect(await notices(c.bob), [
          'You joined',
          'Carol joined',
        ], reason: 'no rename notice, no "could not be decrypted"');
        // And the same in reverse: aux on a text is dropped.
        final m = await mallory(c.alice);
        m.inject(
          c.bob,
          groupId,
          {
            'v': 1,
            'kind': 'text',
            'text': 'sneaky',
            'messageId': uuid(300),
            'conversationId': groupId,
            'senderId': malloryId,
            'sentAt': '2026-10-13T12:00:01Z',
          },
          messageId: uuid(300),
          aux: true,
        );
        await c.bob.pollNow();
        expect(await texts(c.bob), isEmpty);
        expect(
          relay.inboxes[c.bob.deviceId],
          isEmpty,
          reason: 'it was acknowledged',
        );
      });

      test('a rename or removal from someone who is not the owner is ignored', () async {
        final c = await crew();
        final m = await mallory(c.alice);
        final reads = relay.count('group ');
        m.inject(
          c.alice,
          groupId,
          m.control(groupId, uuid(301), 'rename', name: 'pwned'),
          messageId: uuid(301),
          aux: true,
        );
        m.inject(
          c.alice,
          groupId,
          m.control(groupId, uuid(302), 'remove', subject: bobId),
          messageId: uuid(302),
          aux: true,
        );
        await c.alice.pollNow();
        expect(await notices(c.alice), ['Bob joined', 'Carol joined']);
        expect(
          relay.count('group ') - reads,
          lessThanOrEqualTo(2),
          reason:
              'the owner is checked against the relay once per message at most',
        );
        // Bob is not marked: the relay lists him and Alice would still seal for him.
        final info = await c.alice.group(groupId);
        expect(info.outOfSync, isEmpty);
        expect(info.name, '');
      });

      test('a join or leave for someone else is ignored', () async {
        final c = await crew();
        final m = await mallory(c.alice);
        m.inject(
          c.alice,
          groupId,
          m.control(groupId, uuid(303), 'leave', subject: bobId),
          messageId: uuid(303),
          aux: true,
        );
        await c.alice.pollNow();
        expect(await notices(c.alice), ['Bob joined', 'Carol joined']);
        expect((await c.alice.group(groupId)).outOfSync, isEmpty);
      });

      test(
        'a forged removal that names another sender in its payload is rejected',
        () async {
          final c = await crew();
          final m = await mallory(c.alice);
          // Mallory claims, inside the encryption, to be the owner.
          m.inject(
            c.carol,
            groupId,
            m.control(
              groupId,
              uuid(304),
              'remove',
              subject: bobId,
              senderId: aliceId,
            ),
            messageId: uuid(304),
            aux: true,
          );
          await c.carol.pollNow();
          expect(
            (await notices(c.carol)).where((n) => n.contains('removed')),
            isEmpty,
          );
          expect((await c.carol.group(groupId)).outOfSync, isEmpty);
          expect(relay.inboxes[c.carol.deviceId], isEmpty);
        },
      );

      test('a replayed membership message changes nothing twice', () async {
        final c = await crew();
        await c.alice.renameGroup(groupId, 'once');
        final copy = {...relay.inboxes[c.bob.deviceId]!.single};
        await c.bob.pollNow();
        expect(
          await notices(c.bob),
          contains('Alice renamed the group to “once”'),
        );
        relay.inboxes[c.bob.deviceId]!.add(copy);
        await c.bob.pollNow();
        expect(
          (await notices(c.bob)).where((n) => n.contains('renamed')),
          hasLength(1),
        );
      });
    });

    group('atomic commits', () {
      test('a failing history write leaves nothing of a membership message applied, and it comes again', () async {
        final store = AtomicStore();
        final alice = await device(aliceId);
        final bob = await device(bobId, store: store);
        final carol = await device(carolId);
        await alice.createGroup(memberIds: [bobId, carolId]);
        await bob.acceptGroupInvite(groupId);
        await carol.acceptGroupInvite(groupId);
        await settle();
        List<String> idsOf(List<ChatMessage> h) => [
          for (final m in h) m.messageId,
        ];
        final before = idsOf(await bob.history(groupId));
        await alice.renameGroup(groupId, 'late');
        store.failOn = '.history.';
        await bob.pollNow();
        expect(idsOf(await bob.history(groupId)), before);
        expect(
          relay.inboxes[bob.deviceId],
          hasLength(1),
          reason: 'not acknowledged',
        );
        await bob.pollNow();
        expect(
          (await notices(bob)).where((n) => n.contains('renamed')),
          hasLength(1),
        );
        expect(relay.inboxes[bob.deviceId], isEmpty);
      });

      test('a failing write of the ratchet rolls the group record back with the notice', () async {
        final store = AtomicStore();
        final alice = await device(aliceId);
        final bob = await device(bobId);
        final carol = await device(carolId, store: store);
        await alice.createGroup(memberIds: [bobId, carolId]);
        await bob.acceptGroupInvite(groupId);
        await carol.acceptGroupInvite(groupId);
        await settle();
        await alice.removeFromGroup(groupId, carolId);
        store.failOn = '.state';
        await carol.pollNow();
        // Not read-only, no notice, still on the relay: all or nothing.
        expect(carol.isGroupReadOnly(groupId), isFalse);
        expect(
          await notices(carol),
          isNot(contains('You were removed from this group')),
        );
        expect(relay.inboxes[carol.deviceId], isNotEmpty);
        await carol.pollNow();
        expect(carol.isGroupReadOnly(groupId), isTrue);
        expect(
          (await notices(carol)).where((n) => n.startsWith('You were removed')),
          hasLength(1),
        );
      });
    });

    group('keeping, listing and wiping', () {
      test('the record is under the account\'s groups key and is wiped with the rest', () async {
        final store = MemoryChatStore();
        final alice = await device(aliceId, store: store);
        final bob = await device(bobId);
        final carol = await device(carolId);
        await alice.createGroup(memberIds: [bobId, carolId]);
        await bob.acceptGroupInvite(groupId);
        await carol.acceptGroupInvite(groupId);
        await settle();
        await alice.send(groupId, groupPeer, 'keep me');
        expect(store.values.keys, contains('hiyall.chat.$aliceId.groups'));
        // A restart reads it back.
        await alice.dispose();
        final again = await device(aliceId, store: store);
        expect(again.isGroup(groupId), isTrue);
        expect(await texts(again), ['keep me']);

        final root = Directory.systemTemp.createTempSync('hiyall_group_wipe');
        addTearDown(() => root.deleteSync(recursive: true));
        await ChatLocalData.wipeAccount(
          root: root,
          store: store,
          userId: aliceId,
        );
        expect(
          store.values.keys.where((k) => k.startsWith('hiyall.chat.$aliceId.')),
          isEmpty,
        );
      });

      test('over the real sealed snapshot the record is sealed, restarts and is wiped', () async {
        final root = Directory.systemTemp.createTempSync('hiyall_group_snap');
        addTearDown(() => root.deleteSync(recursive: true));
        final secure = MemoryChatStore();
        Future<SnapshotChatStore> open() => SnapshotChatStore.open(
          secure: secure,
          userId: aliceId,
          files: DirectorySnapshotFiles(Directory('${root.path}/chat_state')),
        );
        final first = await open();
        final alice = await device(aliceId, store: first);
        final bob = await device(bobId);
        final carol = await device(carolId);
        await alice.createGroup(
          name: 'confidential crew',
          memberIds: [bobId, carolId],
        );
        await bob.acceptGroupInvite(groupId);
        await carol.acceptGroupInvite(groupId);
        await settle();
        await alice.removeFromGroup(groupId, carolId);
        await alice.send(groupId, groupPeer, 'a private sentence');
        await alice.dispose();

        final file = File(
          '${root.path}/chat_state/${(await open()).snapshotName}',
        ).readAsBytesSync();
        final raw = utf8.decode(file, allowMalformed: true);
        expect(raw, isNot(contains('confidential')));
        expect(raw, isNot(contains('private sentence')));

        final again = await device(aliceId, store: await open());
        expect(again.isGroup(groupId), isTrue);
        expect(
          again.groupDirectory(groupId).keys,
          containsAll([aliceId, carolId]),
        );
        expect(await texts(again), ['a private sentence']);
        relay.groups[groupId]!.members.add(carolId);
        await expectLater(
          again.send(groupId, groupPeer, 'x'),
          failure('GROUP_OUT_OF_SYNC'),
        );
        await ChatLocalData.wipeAccount(
          root: root,
          store: secure,
          userId: aliceId,
        );
        expect(Directory('${root.path}/chat_state').existsSync(), isFalse);
      });

      test('the chat list shows groups with their last message; a group deleted for 30 days is wiped', () async {
        final c = await crew();
        await c.alice.send(groupId, groupPeer, 'last words');
        await settle();
        final listed = await c.bob.groups();
        expect(listed.single.id, groupId);
        expect(listed.single.last?.text, 'last words');
        expect(
          listed.single.members.map((m) => m.userId),
          containsAll([aliceId, bobId, carolId]),
        );
        expect(listed.single.unconfirmed, isEmpty);
        expect(listed.single.readOnly, isFalse);

        // The relay reports the group closed for Bob after 30 days.
        relay.closedIds = [groupId];
        await c.bob.hiddenConversations();
        expect(c.bob.isGroup(groupId), isFalse);
        expect(await c.bob.history(groupId), isEmpty);
        expect(c.bob.groupDirectory(groupId), isEmpty);

        // An expired entry of the hidden list does the same.
        relay.closedIds = [];
        final item = relay.groupJson(relay.groups[groupId]!, carolId)
          ..['hiddenAt'] = '2026-09-01T00:00:00Z'
          ..['restoreUntil'] = '2026-10-01T00:00:00Z';
        relay.hiddenGroupItems[carolId] = [item];
        expect(await c.carol.hiddenGroups(), isEmpty);
        expect(c.carol.isGroup(groupId), isFalse);
      });

      test('clearing the history of a group keeps who is in it and who was removed', () async {
        final c = await crew();
        await c.alice.send(groupId, groupPeer, 'forget me');
        await settle();
        await c.alice.removeFromGroup(groupId, carolId);
        await settle();
        await c.bob.clearHistory(groupId);
        expect(await c.bob.history(groupId), isEmpty);
        expect(c.bob.isGroup(groupId), isTrue);
        relay.groups[groupId]!.members.add(carolId);
        await expectLater(
          c.bob.send(groupId, groupPeer, 'x'),
          failure('GROUP_OUT_OF_SYNC'),
        );
      });

      test('a group the relay no longer shows stays in the list, read-only, and can be deleted from it', () async {
        final c = await crew();
        await c.alice.removeFromGroup(groupId, carolId);
        await settle();
        final g = relay.groups[groupId]!;
        g.members.remove(carolId);
        // Carol is not a member any more as far as the relay is concerned.
        final info = await c.carol.group(groupId);
        expect(info.readOnly, isTrue);
        expect(info.id, groupId);
        // The list has it too (the relay no longer does).
        final listed = await c.carol.groups();
        expect(listed.single.id, groupId);
        expect(listed.single.readOnly, isTrue);
        await c.carol.hideConversation(groupId);
        expect(await c.carol.groups(), isEmpty);
        expect((await c.carol.hiddenGroups()).single.id, groupId);
        await c.carol.restoreConversation(groupId);
        expect((await c.carol.groups()).single.id, groupId);
      });

      test(
        'pin, hide, restore, read and receipts work by id for a group',
        () async {
          final c = await crew();
          await c.alice.send(groupId, groupPeer, 'hi');
          await settle();
          await c.bob.pinConversation(groupId, true);
          await c.bob.hideConversation(groupId);
          await c.bob.restoreConversation(groupId);
          await c.bob.markRead(groupId);
          expect(
            relay.calls,
            containsAll([
              'pin $groupId true',
              'hide $groupId',
              'restore $groupId',
              'read $groupId',
            ]),
          );
          expect(await c.bob.peerReadAt(groupId), isNull);
          expect(
            relay.calls.where((c) => c.startsWith('conversation ')),
            isEmpty,
          );
          // Search works with group ids.
          final hits = await c.bob.searchHistory('hi', [groupId]);
          expect(hits[groupId]!.count, 1);
        },
      );
    });

    group('unwedging', () {
      test('a message that cannot be opened is answered with a quiet noop sealed for the whole group', () async {
        final c = await crew();
        await c.alice.send(groupId, groupPeer, 'to be damaged');
        final item = relay.inboxes[c.bob.deviceId]!.single;
        final ct = item['ciphertext'] as String;
        item['ciphertext'] =
            '${ct.substring(0, 12)}${ct[12] == 'A' ? 'B' : 'A'}${ct.substring(13)}';
        final before = relay.wire.length;
        await c.bob.pollNow();
        expect(
          await notices(c.bob),
          contains('This message couldn’t be decrypted on this device.'),
        );
        final noop = relay.wire.skip(before).where((w) => w.kind == 'message');
        expect(noop, hasLength(1));
        expect(noop.single.aux, isTrue);
        expect(noop.single.from, bobId);
        expect(noop.single.devices.toSet(), {...ids(aliceId), ...ids(carolId)});
        expect(
          relay.calls.where((c) => c.startsWith('conversation ')),
          isEmpty,
        );
        // It is not a message anywhere.
        await settle();
        expect(await texts(c.carol), ['to be damaged']);
        expect(await texts(c.alice), ['to be damaged']);
      });
    });

    test('the group directory keeps names of people who left', () async {
      final c = await crew();
      await c.carol.send(groupId, groupPeer, 'bye');
      await settle();
      await c.carol.leaveGroup(groupId);
      await settle();
      final dir = c.alice.groupDirectory(groupId);
      expect(dir[carolId]?.name, 'Carol');
      expect(dir.keys, containsAll([aliceId, bobId, carolId]));
      // A reaction or quote naming her is still understood.
      final info = await c.alice.group(groupId);
      expect(info.members.map((m) => m.userId), isNot(contains(carolId)));
      expect(utf8.decode(utf8.encode(dir[carolId]!.username)), 'carol');
    });
  });
}

/// The debug Rust core for the host: `.dylib` on macOS, `.so` on Linux (CI).
final _corePath =
    'rust/target/debug/libhiyall_e2ee.${Platform.isMacOS ? 'dylib' : 'so'}';

/// Skips the real-Olm groups when the core is not built locally; CI sets REQUIRE_RUST_CORE=1 so a missing
/// library fails there instead.
String? _coreMissing() {
  if (File(_corePath).existsSync()) return null;
  if (Platform.environment['REQUIRE_RUST_CORE'] == '1') {
    throw StateError('REQUIRE_RUST_CORE=1 but $_corePath is missing');
  }
  return 'the debug Rust core is not built (cargo build in apps/mobile/rust)';
}
