import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/chat/chat_attachment.dart';
import 'package:hiyall/core/chat/chat_engine.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/core/theme.dart';
import 'package:hiyall/features/chat.dart';
import 'package:hiyall/features/chat_format.dart';
import 'package:hiyall/features/chat_menu.dart';

import 'chat_photo_helpers.dart' show conv, peerId;
import 'chat_ui_test.dart' show UiCloud, UiEngine, fixedNow, msg, when;
import 'widget_test.dart' show SignedIn;

class Spy extends UiEngine {
  Spy(super.cloud);
  final retried = <String>[], discarded = <String>[], dismissed = <int>[];
  List<DeviceNotice> own = [];
  bool verified = false;
  @override
  Future<void> retryText(String c, String p, String id) async =>
      retried.add(id);
  @override
  Future<void> discardText(String c, String id) async => discarded.add(id);
  @override
  List<DeviceNotice> get ownDeviceNotices => own;
  @override
  Future<void> dismissOwnDeviceNotices() async {
    dismissed.add(1);
    own = [];
  }

  @override
  bool isVerified(String peerId) => verified;
  @override
  Future<void> showDeviceNotices(String c, String p) async {}
}

void main() {
  late Spy engine;

  Future<void> pump(WidgetTester tester, Widget screen) async {
    engine = Spy(UiCloud());
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatEngineProvider.overrideWith((ref) async => engine),
          sessionProvider.overrideWith(SignedIn.new),
          chatClockProvider.overrideWithValue(() => fixedNow),
        ],
        child: MaterialApp(
          theme: hiyallTheme(Brightness.light),
          home: Scaffold(body: screen),
        ),
      ),
    );
  }

  Future<void> open(WidgetTester tester, List<ChatMessage> messages) async {
    await pump(
      tester,
      ConversationScreen(id: conv, peerId: peerId, peerName: 'Niko'),
    );
    engine.messages = messages;
    await tester.pumpAndSettle();
    engine.ctrl.add(conv);
    await tester.pumpAndSettle();
  }

  group('first contact (U1)', () {
    testWidgets('after three unanswered messages the composer waits', (
      tester,
    ) async {
      await open(tester, [
        for (var i = 0; i < 3; i++)
          msg(
            '00000000-0000-4000-8000-00000000010$i',
            'hi $i',
            when(10, i),
            mine: true,
          ),
      ]);
      expect(find.text('Waiting for Niko to reply'), findsOneWidget);
      final field = tester.widget<TextField>(
        find.byKey(const Key('chat-input')),
      );
      expect(field.enabled, isFalse);
      expect(find.text('Message…'), findsNothing);
    });

    testWidgets('two messages, or a reply, leave it open', (tester) async {
      await open(tester, [
        msg(
          '00000000-0000-4000-8000-000000000101',
          'hi',
          when(10, 0),
          mine: true,
        ),
        msg(
          '00000000-0000-4000-8000-000000000102',
          'hi again',
          when(10, 1),
          mine: true,
        ),
      ]);
      expect(find.text('Message…'), findsOneWidget);
      expect(find.textContaining('Waiting for'), findsNothing);

      await open(tester, [
        for (var i = 0; i < 3; i++)
          msg(
            '00000000-0000-4000-8000-00000000020$i',
            'hi $i',
            when(10, i),
            mine: true,
          ),
        msg('00000000-0000-4000-8000-000000000210', 'hey', when(10, 9)),
      ]);
      expect(find.text('Message…'), findsOneWidget);
    });

    testWidgets('a message that failed does not count', (tester) async {
      await open(tester, [
        msg(
          '00000000-0000-4000-8000-000000000301',
          'a',
          when(10, 0),
          mine: true,
        ),
        msg(
          '00000000-0000-4000-8000-000000000302',
          'b',
          when(10, 1),
          mine: true,
        ),
        msg(
          '00000000-0000-4000-8000-000000000303',
          'c',
          when(10, 2),
          mine: true,
          status: SendStatus.failed,
        ),
      ]);
      expect(find.text('Message…'), findsOneWidget);
    });
  });

  group('text that was not sent (C9)', () {
    const id = '00000000-0000-4000-8000-000000000401';
    testWidgets('shows not sent with retry and delete', (tester) async {
      await open(tester, [
        msg(
          id,
          'lost words',
          when(10, 0),
          mine: true,
          status: SendStatus.failed,
        ),
      ]);
      expect(find.text('lost words'), findsOneWidget);
      expect(find.byKey(const Key('text-error-$id')), findsOneWidget);
      await tester.tap(find.byKey(const Key('text-send-retry-$id')));
      await tester.pump();
      expect(engine.retried, [id]);
      await tester.tap(find.byKey(const Key('text-delete-$id')));
      await tester.pump();
      expect(engine.discarded, [id]);
    });

    testWidgets('a delivered message has neither', (tester) async {
      await open(tester, [msg(id, 'fine', when(10, 0), mine: true)]);
      expect(find.byKey(const Key('text-send-retry-$id')), findsNothing);
    });
  });

  group('time and text on bubbles (C4, F23)', () {
    testWidgets('a hostile sender time shows the relay time', (tester) async {
      final m = ChatMessage(
        messageId: '00000000-0000-4000-8000-000000000501',
        senderId: peerId,
        text: 'from 2099',
        sentAt: DateTime(2099, 1, 1, 3, 33),
        serverAt: DateTime(2026, 10, 12, 10, 5),
        mine: false,
      );
      await open(tester, [m]);
      expect(find.text('from 2099'), findsOneWidget);
      expect(
        find.text(
          TimeOfDay(
            hour: 3,
            minute: 33,
          ).format(tester.element(find.byType(ConversationScreen))),
        ),
        findsNothing,
      );
    });

    testWidgets('direction controls never reach the bubble', (tester) async {
      await open(tester, [
        msg(
          '00000000-0000-4000-8000-000000000502',
          'exe\u202Egnp.txt',
          when(10, 0),
        ),
      ]);
      expect(find.text('exegnp.txt'), findsOneWidget);
      expect(find.text('exe\u202Egnp.txt'), findsNothing);
    });
  });

  group('device banner and safety menu (C3)', () {
    testWidgets(
      'the banner names the change, links to the devices and dismisses',
      (tester) async {
        engine = Spy(UiCloud())
          ..own = [DeviceNotice('d1', DateTime.utc(2026, 10, 13))];
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              chatEngineProvider.overrideWith((ref) async => engine),
              sessionProvider.overrideWith(SignedIn.new),
              chatClockProvider.overrideWithValue(() => fixedNow),
            ],
            child: MaterialApp(
              theme: hiyallTheme(Brightness.light),
              home: Scaffold(body: ChatsScreen()),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text('A new device was added to your account'),
          findsOneWidget,
        );
        expect(find.byKey(const Key('new-device-manage')), findsOneWidget);
        await tester.tap(find.byKey(const Key('new-device-dismiss')));
        await tester.pump();
        expect(engine.dismissed, [1]);
      },
    );

    testWidgets('the menu shows whether the safety number was verified', (
      tester,
    ) async {
      for (final verified in [false, true]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: hiyallTheme(Brightness.light),
            home: Scaffold(
              body: SingleChildScrollView(
                child: ChatSafetyMenu(
                  muted: false,
                  peerName: 'Niko',
                  verified: verified,
                ),
              ),
            ),
          ),
        );
        expect(find.byKey(const Key('chat-safety')), findsOneWidget);
        expect(
          find.textContaining(verified ? 'Verified' : 'Not verified'),
          findsOneWidget,
        );
      }
    });
  });
}
