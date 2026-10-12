import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/api.dart' show Profile;
import 'package:hiyall/core/chat/chat_engine.dart';
import 'package:hiyall/core/presence.dart';
import 'package:hiyall/core/realtime/realtime_client.dart';
import 'package:hiyall/core/state.dart' show sessionProvider;
import 'package:hiyall/core/theme.dart';
import 'package:hiyall/features/chat.dart';
import 'package:hiyall/features/chat_format.dart';
import 'package:hiyall/features/chat_header.dart';
import 'package:hiyall/features/chat_list.dart';
import 'package:hiyall/features/live_sync.dart';
import 'package:hiyall/shared/chat_tokens.dart';
import 'package:hiyall/shared/person_avatar.dart';
import 'package:hiyall/shared/presence_dot.dart';

import 'chat_photo_helpers.dart' show peerId;
import 'chat_ui_test.dart' show UiCloud, UiEngine, chat, fixedNow, msg, when;
import 'widget_test.dart' show SignedIn;

/// Online dots and last seen: the dot widget, the last-seen wording, the chats list, the conversation header
/// and the parsing of what the server sends.

String hm24(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
String hm12(DateTime t) {
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  return '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
}

void main() {
  group('lastSeenText (viewer local time, five-minute buckets)', () {
    // 15:30 on Monday 12 Oct 2026, the same clock the chat tests use.
    final now = DateTime(2026, 10, 12, 15, 30);
    String say(DateTime at, {DateTime? at2, String Function(DateTime)? f}) =>
        lastSeenText(at, at2 ?? now, f ?? hm24);

    test('under five minutes is just now (the current bucket)', () {
      expect(say(DateTime(2026, 10, 12, 15, 30)), 'last seen just now');
      expect(say(DateTime(2026, 10, 12, 15, 25, 1)), 'last seen just now');
    });

    test('within the hour it counts in steps of five, never finer', () {
      expect(say(DateTime(2026, 10, 12, 15, 25)), 'last seen 5 min ago');
      // 27 minutes after a 15:05 bucket: the bucket says 15:05-15:10, so 25.
      expect(
        say(DateTime(2026, 10, 12, 15, 5), at2: DateTime(2026, 10, 12, 15, 32)),
        'last seen 25 min ago',
      );
      expect(say(DateTime(2026, 10, 12, 15, 5)), 'last seen 25 min ago');
      expect(say(DateTime(2026, 10, 12, 14, 40)), 'last seen 50 min ago');
      expect(say(DateTime(2026, 10, 12, 14, 35)), 'last seen 55 min ago');
      // Never an odd number of minutes.
      for (var m = 5; m < 60; m++) {
        final text = say(now.subtract(Duration(minutes: m)));
        final n = int.parse(
          RegExp(r'(\d+) min').firstMatch(text)?.group(1) ?? '0',
        );
        if (m >= 5) expect(n % 5, 0, reason: text);
      }
    });

    test('later the same day is a time of day', () {
      expect(say(DateTime(2026, 10, 12, 14, 20)), 'last seen today at 14:20');
      expect(say(DateTime(2026, 10, 12, 0, 0)), 'last seen today at 00:00');
      expect(
        say(DateTime(2026, 10, 12, 14, 20), f: hm12),
        'last seen today at 2:20 PM',
      );
    });

    test('yesterday, by calendar day and not by 24 hours', () {
      expect(
        say(DateTime(2026, 10, 11, 21, 5)),
        'last seen yesterday at 21:05',
      );
      expect(
        say(DateTime(2026, 10, 11, 21, 5), f: hm12),
        'last seen yesterday at 9:05 PM',
      );
      // Midnight boundary: 23:55 yesterday seen at 00:05 is ten minutes ago, and from 01:00 it is yesterday.
      final lateNight = DateTime(2026, 10, 11, 23, 55);
      expect(
        say(lateNight, at2: DateTime(2026, 10, 12, 0, 5)),
        'last seen 10 min ago',
      );
      expect(
        say(lateNight, at2: DateTime(2026, 10, 12, 1, 0)),
        'last seen yesterday at 23:55',
      );
      // 28 hours ago but two calendar days back is a weekday.
      expect(
        say(DateTime(2026, 10, 10, 22, 0), at2: DateTime(2026, 10, 12, 2, 0)),
        'last seen Sat',
      );
    });

    test('within a week it is the weekday, then the date', () {
      expect(say(DateTime(2026, 10, 10, 9, 0)), 'last seen Sat');
      expect(say(DateTime(2026, 10, 6, 9, 0)), 'last seen Tue');
      // Seven calendar days back is a date, so a weekday is never ambiguous with today's.
      expect(say(DateTime(2026, 10, 5, 9, 0)), 'last seen 5 Oct');
      expect(say(DateTime(2026, 9, 12, 9, 0)), 'last seen 12 Sep');
      expect(say(DateTime(2025, 12, 31, 9, 0)), 'last seen 31 Dec 2025');
    });

    test('a time in the future (clock skew) is just now', () {
      expect(say(DateTime(2026, 10, 12, 15, 45)), 'last seen just now');
    });

    test('uses the viewer\'s zone: a UTC bucket is read in local time', () {
      final utcNow = DateTime.utc(2026, 10, 12, 15, 30);
      final seen = DateTime.utc(2026, 10, 12, 14, 20);
      // Whatever zone the machine is in, both are converted the same way, so the difference is 70 minutes.
      final text = lastSeenText(seen, utcNow, hm24);
      expect(
        text,
        anyOf(
          startsWith('last seen today at'),
          startsWith('last seen yesterday at'),
        ),
      );
      expect(text, contains(hm24(seen.toLocal())));
    });
  });

  group('parsing what the server sends', () {
    test('online is only ever the boolean true', () {
      expect(parsePresence({'online': true}).online, isTrue);
      for (final bad in [false, null, 'true', 1, [], {}]) {
        expect(parsePresence({'online': bad}).online, isFalse, reason: '$bad');
      }
      expect(parsePresence(null).online, isFalse);
      expect(parsePresence('x').online, isFalse);
      expect(parsePresence(const {}).lastSeenAt, isNull);
    });

    test('lastSeenAt is a UTC date or nothing, and not with online', () {
      final p = parsePresence({'lastSeenAt': '2026-10-12T14:20:00Z'});
      expect(p.online, isFalse);
      expect(p.lastSeenAt, DateTime.utc(2026, 10, 12, 14, 20));
      expect(p.lastSeenAt!.isUtc, isTrue);
      for (final bad in [null, '', 'yesterday', 12, true, [], {}]) {
        expect(
          parsePresence({'lastSeenAt': bad}).lastSeenAt,
          isNull,
          reason: '$bad',
        );
      }
      expect(
        parsePresence({'online': true, 'lastSeenAt': '2026-10-12T14:20:00Z'})
            .lastSeenAt,
        isNull,
      );
    });

    test('Profile carries both and survives malformed values', () {
      final base = {'userId': 'u', 'username': 'n', 'displayName': 'N'};
      final on = Profile.fromJson({...base, 'online': true});
      expect(on.online, isTrue);
      expect(on.lastSeenAt, isNull);
      final away = Profile.fromJson({
        ...base,
        'lastSeenAt': '2026-10-12T14:20:00Z',
      });
      expect(away.online, isNull);
      expect(away.lastSeenAt, DateTime.utc(2026, 10, 12, 14, 20));
      final plain = Profile.fromJson(base);
      expect(plain.online, isNull);
      expect(plain.lastSeenAt, isNull);
      final junk = Profile.fromJson({
        ...base,
        'online': 'yes',
        'lastSeenAt': 42,
      });
      expect(junk.online, isNull);
      expect(junk.lastSeenAt, isNull);
    });

    test('the conversation model defaults to hidden', () {
      const c = ChatConversation('c', 'p', 'Niko', 'niko', null);
      expect(c.online, isFalse);
      expect(c.lastSeenAt, isNull);
    });
  });

  group('PresenceDot', () {
    testWidgets('is a green circle with a ring in the surface colour', (
      tester,
    ) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: PresenceDot(
              key: Key('dot'),
              ringColor: Color(0xff112233),
              size: 20,
              ringWidth: 3,
            ),
          ),
        ),
      );
      final box = tester.widget<Container>(
        find.descendant(
          of: find.byKey(const Key('dot')),
          matching: find.byType(Container),
        ),
      );
      final decoration = box.decoration! as BoxDecoration;
      expect(decoration.color, PresenceDot.color);
      expect(decoration.shape, BoxShape.circle);
      expect((decoration.border! as Border).top.color, const Color(0xff112233));
      expect((decoration.border! as Border).top.width, 3);
      expect(tester.getSize(find.byKey(const Key('dot'))), const Size(20, 20));
    });

    testWidgets('is announced as online', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Center(child: PresenceDot(ringColor: Colors.black)),
        ),
      );
      expect(find.bySemanticsLabel('online'), findsOneWidget);
      handle.dispose();
    });

    test('the word online is readable on both surfaces', () {
      double contrast(Color a, Color b) {
        final la = a.computeLuminance(), lb = b.computeLuminance();
        return (la > lb ? la + .05 : lb + .05) /
            (la > lb ? lb + .05 : la + .05);
      }

      expect(
        contrast(PresenceDot.textColor(Brightness.dark), ChatTokens.dark.bg),
        greaterThan(4.5),
      );
      expect(
        contrast(PresenceDot.textColor(Brightness.light), ChatTokens.light.bg),
        greaterThan(4.5),
      );
    });
  });

  group('chat header', () {
    Future<void> pumpHeader(
      WidgetTester tester, {
      bool typing = false,
      bool online = false,
      DateTime? lastSeenAt,
      Size size = const Size(390, 200),
      bool dark = true,
      double scale = 1,
      bool use24 = true,
      String name = 'Niko',
    }) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: hiyallTheme(dark ? Brightness.dark : Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
              alwaysUse24HourFormat: use24,
            ),
            child: child!,
          ),
          home: Scaffold(
            body: Column(
              children: [
                ChatHeader(
                  name: name,
                  userId: 'u1',
                  avatarUrl: null,
                  typing: typing,
                  online: online,
                  lastSeenAt: lastSeenAt,
                  now: fixedNow,
                  muted: false,
                  canAct: true,
                  onBack: () {},
                  onSafety: () {},
                  onOptions: () {},
                  onProfile: () {},
                ),
              ],
            ),
          ),
        ),
      );
    }

    String subtitle(WidgetTester tester) {
      final box = find.byKey(const Key('chat-header-subtitle'));
      final texts = find.descendant(of: box, matching: find.byType(Text));
      return tester
          .widgetList<Text>(texts)
          .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
          .join('|');
    }

    testWidgets('typing wins over online, last seen and encryption', (
      tester,
    ) async {
      await pumpHeader(
        tester,
        typing: true,
        online: true,
        lastSeenAt: when(14, 20),
      );
      expect(subtitle(tester), 'typing…');
      // The avatar dot is presence, not typing: it stays while they type.
      expect(find.byKey(const Key('chat-online-dot')), findsOneWidget);
    });

    testWidgets('online shows the dot and a green "online"', (tester) async {
      await pumpHeader(tester, online: true, lastSeenAt: when(14, 20));
      expect(subtitle(tester), 'online');
      expect(find.byKey(const Key('chat-online-dot')), findsOneWidget);
      final label = tester.widget<Text>(
        find.byKey(const Key('chat-header-online')),
      );
      expect(label.style!.color, PresenceDot.textColor(Brightness.dark));
    });

    testWidgets('last seen when not online, with no dot', (tester) async {
      await pumpHeader(tester, lastSeenAt: when(14, 20));
      expect(subtitle(tester), 'last seen today at 14:20');
      expect(find.byKey(const Key('chat-online-dot')), findsNothing);
      expect(find.text('end-to-end encrypted'), findsNothing);
    });

    testWidgets('the device clock format is used: 12 hour', (tester) async {
      await pumpHeader(tester, lastSeenAt: when(14, 20), use24: false);
      expect(subtitle(tester), 'last seen today at 2:20 PM');
    });

    testWidgets('last seen is read against the injected clock', (tester) async {
      await pumpHeader(tester, lastSeenAt: when(14, 20, daysAgo: 1));
      expect(subtitle(tester), 'last seen yesterday at 14:20');
      await pumpHeader(tester, lastSeenAt: when(15, 5));
      expect(subtitle(tester), 'last seen 25 min ago');
    });

    testWidgets('nothing known falls back to the encryption line', (
      tester,
    ) async {
      await pumpHeader(tester);
      expect(subtitle(tester), 'end-to-end encrypted');
      expect(find.byKey(const Key('chat-online-dot')), findsNothing);
    });

    testWidgets('the header never changes height between variants', (
      tester,
    ) async {
      for (final size in [const Size(390, 200), const Size(320, 200)]) {
        for (final scale in [1.0, 2.0]) {
          final heights = <String, double>{};
          final variants = <String, Map<String, Object?>>{
            'encrypted': {},
            'typing': {'typing': true},
            'online': {'online': true},
            'last seen': {'lastSeenAt': when(14, 20, daysAgo: 1)},
            'long name': {
              'name': 'Alexandrina Montgomery-Featherstonehaugh the Third of Her Name',
              'lastSeenAt': when(14, 20, daysAgo: 1),
            },
          };
          for (final MapEntry(:key, :value) in variants.entries) {
            await pumpHeader(
              tester,
              size: size,
              scale: scale,
              typing: value['typing'] as bool? ?? false,
              online: value['online'] as bool? ?? false,
              lastSeenAt: value['lastSeenAt'] as DateTime?,
              name: value['name'] as String? ?? 'Niko',
            );
            heights[key] = tester.getSize(find.byType(ChatHeader)).height;
            expect(
              tester
                  .getSize(find.byKey(const Key('chat-header-subtitle')))
                  .height,
              18,
              reason: '$key at ${size.width} x$scale',
            );
            expect(tester.takeException(), isNull, reason: key);
          }
          expect(heights.values.toSet(), {
            ChatMetrics.headerHeight,
          }, reason: '$size x$scale: $heights');
        }
      }
    });
  });

  group('chats list and conversation', () {
    late UiCloud cloud;
    late UiEngine engine;

    Future<void> pumpScreen(
      WidgetTester tester,
      Widget screen, {
      bool dark = true,
    }) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            chatEngineProvider.overrideWith((ref) async => engine),
            sessionProvider.overrideWith(SignedIn.new),
            chatClockProvider.overrideWithValue(() => fixedNow),
          ],
          child: MaterialApp(
            theme: hiyallTheme(dark ? Brightness.dark : Brightness.light),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(disableAnimations: true, alwaysUse24HourFormat: true),
              child: child!,
            ),
            home: Scaffold(body: screen),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    setUp(() {
      cloud = UiCloud();
      engine = UiEngine(cloud);
    });

    testWidgets('a green dot only on rows whose peer is online', (
      tester,
    ) async {
      engine.list = [
        chat(1, 'Mira', 'mira', msg('a', 'hi', when(9, 0)), online: true),
        chat(
          2,
          'Niko',
          'niko',
          msg('b', 'yo', when(8, 0)),
          lastSeenAt: when(14, 20),
        ),
        chat(3, 'Dev', 'dev', null),
        chat(4, 'Zoya', 'zoya', msg('c', 'ok', when(7, 0)), online: true),
      ];
      await pumpScreen(tester, const ChatsScreen());
      for (final (n, expected) in [
        (1, true),
        (2, false),
        (3, false),
        (4, true),
      ]) {
        final id =
            '019a4000-0000-7000-8000-0000000001${n.toString().padLeft(2, '0')}';
        expect(
          find.byKey(Key('chat-row-online-$id')),
          expected ? findsOneWidget : findsNothing,
          reason: 'row $n',
        );
      }
      expect(find.byType(PresenceDot), findsNWidgets(2));
      // The row reads "online" to a screen reader.
      final handle = tester.ensureSemantics();
      expect(find.bySemanticsLabel(RegExp('^Mira, .*online')), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('^Niko, .*online')), findsNothing);
      handle.dispose();
    });

    testWidgets('the dot sits on the avatar inside its bounds, any theme', (
      tester,
    ) async {
      for (final dark in [true, false]) {
        engine.list = [
          chat(
            1,
            'Mira',
            'mira',
            msg('a', 'hi', when(9, 0)),
            online: true,
            unread: 2,
          ),
        ];
        await pumpScreen(tester, const ChatsScreen(), dark: dark);
        final dot = tester.getRect(find.byType(PresenceDot));
        final avatar = tester.getRect(
          find.descendant(
            of: find.byType(ChatRow),
            matching: find.byType(PersonAvatar),
          ),
        );
        expect(avatar.inflate(8).contains(dot.center), isTrue);
        expect(dot.center.dx, greaterThan(avatar.center.dx));
        expect(dot.center.dy, greaterThan(avatar.center.dy));
        // The ring matches the unread row fill, so it cuts cleanly out of the row.
        final t = dark ? ChatTokens.dark : ChatTokens.light;
        final ring =
            tester
                    .widget<Container>(
                      find.descendant(
                        of: find.byType(PresenceDot),
                        matching: find.byType(Container),
                      ),
                    )
                    .decoration!
                as BoxDecoration;
        expect((ring.border! as Border).top.color, t.unreadRow);
      }
    });

    testWidgets(
      'a list refresh carries presence changes without a rebuild of the screen',
      (tester) async {
        engine.list = [chat(1, 'Mira', 'mira', msg('a', 'hi', when(9, 0)))];
        await pumpScreen(tester, const ChatsScreen());
        expect(find.byType(PresenceDot), findsNothing);
        engine.list = [
          chat(1, 'Mira', 'mira', msg('a', 'hi', when(9, 0)), online: true),
        ];
        engine.ctrl.add('x');
        await tester.pumpAndSettle();
        expect(find.byType(PresenceDot), findsOneWidget);
        engine.list = [chat(1, 'Mira', 'mira', msg('a', 'hi', when(9, 0)))];
        engine.ctrl.add('x');
        await tester.pumpAndSettle();
        expect(find.byType(PresenceDot), findsNothing);
      },
    );

    Future<void> openChat(WidgetTester tester) async {
      engine.messages = [msg('a', 'hi', when(10, 0))];
      await pumpScreen(
        tester,
        const ConversationScreen(id: 'c1', peerId: peerId, peerName: 'Niko'),
      );
    }

    testWidgets('the header reads the peer\'s presence from the conversation', (
      tester,
    ) async {
      cloud.receipt = {
        'peer': {
          'userId': peerId,
          'displayName': 'Niko',
          'username': 'niko',
          'online': true,
        },
      };
      await openChat(tester);
      expect(find.byKey(const Key('chat-online-dot')), findsOneWidget);
      expect(find.byKey(const Key('chat-header-online')), findsOneWidget);
    });

    testWidgets("last seen, and then hidden, as the server's answer changes", (
      tester,
    ) async {
      cloud.receipt = {
        'peer': {
          'userId': peerId,
          'displayName': 'Niko',
          'username': 'niko',
          'lastSeenAt': when(14, 20).toUtc().toIso8601String(),
        },
      };
      await openChat(tester);
      expect(find.byKey(const Key('chat-online-dot')), findsNothing);
      expect(find.text('last seen today at 14:20'), findsOneWidget);
      // The peer hides presence: the server just leaves both keys out.
      cloud.receipt = {
        'peer': {'userId': peerId, 'displayName': 'Niko', 'username': 'niko'},
      };
      engine.ctrl.add('x');
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ConversationScreen)),
      );
      container.read(chatSignalProvider.notifier).bump();
      await tester.pumpAndSettle();
      expect(find.byType(PresenceDot), findsNothing);
      expect(find.textContaining('last seen'), findsNothing);
      expect(find.text('end-to-end encrypted'), findsOneWidget);
    });
  });

  group('freshness', () {
    testWidgets('a live socket gets a slow refresh signal, once a minute', (
      tester,
    ) async {
      final client = _LiveClient()..connected.value = true;
      final container = ProviderContainer(
        overrides: [
          realtimeProvider.overrideWithValue(client),
          sessionProvider.overrideWith(SignedIn.new),
          chatEngineProvider.overrideWith((ref) async => null),
        ],
      );
      addTearDown(container.dispose);
      var bumps = 0;
      container.listen(chatSignalProvider, (_, _) => bumps++);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const LiveSync(child: SizedBox()),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 59));
      expect(bumps, 0, reason: 'nothing tight: no signal within the minute');
      await tester.pump(const Duration(seconds: 2));
      expect(bumps, 1);
      await tester.pump(const Duration(seconds: 60));
      expect(bumps, 2);
      await tester.pumpWidget(const SizedBox());
    });
  });
}

class _LiveClient extends RealtimeClient {
  _LiveClient() : super('http://127.0.0.1:8080', 't');
  @override
  void start() {}
  @override
  void stop() {}
}
