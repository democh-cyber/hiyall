import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/app.dart';
import 'package:hiyall/core/chat/chat_api.dart';
import 'package:hiyall/core/say_hi_prefs.dart';
import 'package:hiyall/features/chat_format.dart'
    show contrastRatio, isEmojiOnly;
import 'package:hiyall/features/discover_person.dart';
import 'package:hiyall/features/discover_style.dart';
import 'package:hiyall/features/say_hi.dart';
import 'package:hiyall/shared/chat_tokens.dart';

import 'discover_helpers.dart';
import 'support/fixtures.dart';

String pathOf(ProviderContainer c) => c
    .read(routerProvider)
    .routerDelegate
    .currentConfiguration
    .last
    .matchedLocation;

String uriOf(ProviderContainer c) =>
    c.read(routerProvider).routerDelegate.currentConfiguration.uri.toString();

SayHiState stateOf(WidgetTester tester, String id) =>
    tester.widget<SayHiButton>(find.byKey(Key('say-hi-$id'))).state;

/// Taps a row's Say hi and lets the first steps of the send run.
Future<void> tapHi(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(Key('say-hi-$id')));
  await tester.pump();
  await tester.pump();
}

/// A member who already answered the first-time sheet.
MemorySayHiPrefsStore confirmedStore() =>
    MemorySayHiPrefsStore()..confirmedBy.add(anjaliId);

Future<ProviderContainer> mount(
  WidgetTester tester, {
  HiLog? hi,
  MemorySayHiPrefsStore? store,
  HiClock? clock,
  Map<String, String>? peers,
  Size size = const Size(390, 844),
  double scale = 1,
  bool dark = true,
  bool chat = true,
  bool still = false,
  DiscoverFake? api,
}) => mountDiscover(
  tester,
  api ?? DiscoverFake(people: busyPeople()),
  hi: hi,
  sayHiStore: store ?? confirmedStore(),
  clock: clock,
  peers: peers,
  size: size,
  scale: scale,
  dark: dark,
  chat: chat,
  still: still,
);

void main() {
  group('sending', () {
    testWidgets(
      'one tap opens the conversation and sends exactly the wave, once, without leaving the list',
      (tester) async {
        final hi = HiLog()..sendHold = Completer<void>();
        final container = await mount(tester, hi: hi);
        expect(stateOf(tester, 'mira'), SayHiState.idle);
        await tapHi(tester, 'mira');
        // On its way: a spinner, the engine used once, nothing sent yet.
        expect(stateOf(tester, 'mira'), SayHiState.pending);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(hi.opened, ['mira']);
        hi.sendHold!.complete();
        await tester.pumpAndSettle();
        expect(hi.opened, ['mira']);
        expect(hi.sent, [('conv-1', 'mira', '👋')]);
        expect(stateOf(tester, 'mira'), SayHiState.done);
        expect(find.byIcon(Icons.check_rounded), findsOneWidget);
        // No navigation, no sheet: still on Discover.
        expect(pathOf(container), '/discover');
        expect(find.byKey(const Key('say-hi-sheet')), findsNothing);
        // The text is the one the thread draws as a large emoji.
        expect(sayHiText, '👋');
        expect(isEmojiOnly(hi.sent.single.$3), isTrue);
      },
    );

    testWidgets(
      'the list keeps its place and does not rebuild around the row',
      (tester) async {
        final api = DiscoverFake(
          people: [for (var i = 0; i < 30; i++) person('p$i', 'Person $i')],
        );
        final hi = HiLog();
        await mount(tester, hi: hi, api: api);
        final scrollable = find.byType(Scrollable).first;
        await tester.scrollUntilVisible(
          find.byKey(const Key('say-hi-p10')),
          300,
          scrollable: scrollable,
        );
        await tester.pumpAndSettle();
        double offset() =>
            tester.state<ScrollableState>(scrollable).position.pixels;
        final before = offset();
        expect(before, greaterThan(0));
        final tile = tester.widget(find.byKey(const Key('person-p10')));
        final neighbour = tester.widget(find.byKey(const Key('person-p9')));
        await tapHi(tester, 'p10');
        await tester.pumpAndSettle();
        expect(hi.sent, hasLength(1));
        expect(offset(), before);
        // The rows themselves were not rebuilt: only their controls change.
        expect(
          identical(tester.widget(find.byKey(const Key('person-p10'))), tile),
          isTrue,
        );
        expect(
          identical(
            tester.widget(find.byKey(const Key('person-p9'))),
            neighbour,
          ),
          isTrue,
        );
      },
    );

    testWidgets(
      'a double tap sends one wave, and so does a tap on the sent control',
      (tester) async {
        final hi = HiLog()..sendHold = Completer<void>();
        await mount(tester, hi: hi);
        await tester.tap(find.byKey(const Key('say-hi-mira')));
        await tester.tap(find.byKey(const Key('say-hi-mira')));
        await tester.pump();
        await tester.pump();
        await tester.tap(find.byKey(const Key('say-hi-mira')));
        await tester.pump();
        expect(hi.opened, ['mira']);
        hi.sendHold!.complete();
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('say-hi-mira')));
        await tester.pumpAndSettle();
        expect(hi.opened, ['mira']);
        expect(hi.sent, hasLength(1));
      },
    );

    testWidgets(
      'while one is on its way every other control is disabled, and only one spinner shows',
      (tester) async {
        final hi = HiLog()..sendHold = Completer<void>();
        await mount(tester, hi: hi);
        await tapHi(tester, 'mira');
        expect(stateOf(tester, 'arjun'), SayHiState.disabled);
        await tester.tap(find.byKey(const Key('say-hi-arjun')));
        await tester.pump();
        expect(hi.opened, ['mira']);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        hi.sendHold!.complete();
        await tester.pumpAndSettle();
        // Free again: the next person can be greeted in a row.
        expect(stateOf(tester, 'arjun'), SayHiState.idle);
        await tapHi(tester, 'arjun');
        await tester.pumpAndSettle();
        expect(hi.sent.map((m) => m.$2), ['mira', 'arjun']);
        expect(stateOf(tester, 'mira'), SayHiState.done);
        expect(stateOf(tester, 'arjun'), SayHiState.done);
      },
    );

    testWidgets('a long press on the control sends nothing', (tester) async {
      final hi = HiLog();
      await mount(tester, hi: hi);
      await tester.longPress(find.byKey(const Key('say-hi-mira')));
      await tester.pumpAndSettle();
      expect(hi.opened, isEmpty);
      expect(hi.sent, isEmpty);
    });

    testWidgets('without chat (the web) it opens the profile instead', (
      tester,
    ) async {
      final hi = HiLog();
      final container = await mount(tester, hi: hi, chat: false);
      await tester.tap(find.byKey(const Key('say-hi-mira')));
      await tester.pumpAndSettle();
      expect(hi.connects, 0);
      expect(hi.opened, isEmpty);
      expect(pathOf(container), '/discover/person/mira');
    });

    testWidgets('a conversation that already holds messages opens instead', (
      tester,
    ) async {
      final hi = HiLog();
      final handle = tester.ensureSemantics();
      final container = await mount(tester, hi: hi, peers: {'mira': 'conv-77'});
      expect(stateOf(tester, 'mira'), SayHiState.message);
      expect(find.bySemanticsLabel('Message Mira Kapoor'), findsOneWidget);
      expect(find.byTooltip('Message Mira Kapoor'), findsOneWidget);
      expect(find.byIcon(Icons.chat_bubble_outline_rounded), findsOneWidget);
      // Everyone else still gets the wave.
      expect(stateOf(tester, 'arjun'), SayHiState.idle);
      await tester.tap(find.byKey(const Key('say-hi-mira')));
      await tester.pumpAndSettle();
      expect(
        uriOf(container),
        startsWith('/chats/conv-77?peer=mira&name=Mira+Kapoor'),
      );
      expect(hi.opened, isEmpty);
      expect(hi.sent, isEmpty);
      handle.dispose();
    });

    testWidgets(
      'with the chat list not loaded yet nobody counts as a conversation',
      (tester) async {
        await mount(tester, peers: null);
        expect(stateOf(tester, 'mira'), SayHiState.idle);
      },
    );
  });

  group('the first time', () {
    testWidgets('asks once, sends only on "Send hi", and never asks again', (
      tester,
    ) async {
      final hi = HiLog();
      final store = MemorySayHiPrefsStore();
      await mount(tester, hi: hi, store: store);
      // Two quick taps open one sheet.
      await tester.tap(find.byKey(const Key('say-hi-mira')));
      await tester.tap(find.byKey(const Key('say-hi-mira')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('say-hi-sheet')), findsOneWidget);
      expect(find.text('Send a 👋 to Mira Kapoor?'), findsOneWidget);
      expect(
        find.text('They’ll get it as a message. You can’t unsend it.'),
        findsOneWidget,
      );
      expect(hi.opened, isEmpty);
      // Cancel: nothing sent, nothing remembered.
      await tester.tap(find.byKey(const Key('say-hi-cancel')));
      await tester.pumpAndSettle();
      expect(hi.opened, isEmpty);
      expect(store.confirmedBy, isEmpty);
      expect(stateOf(tester, 'mira'), SayHiState.idle);
      // Ask again, then agree.
      await tester.tap(find.byKey(const Key('say-hi-mira')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('say-hi-send')));
      await tester.pumpAndSettle();
      expect(hi.sent, [('conv-1', 'mira', '👋')]);
      expect(store.confirmedBy, {anjaliId});
      // From now on a tap sends at once.
      await tester.tap(find.byKey(const Key('say-hi-arjun')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('say-hi-sheet')), findsNothing);
      expect(hi.sent.map((m) => m.$2), ['mira', 'arjun']);
    });

    testWidgets('a member who confirmed before is never asked', (tester) async {
      final hi = HiLog();
      await mount(tester, hi: hi);
      await tester.tap(find.byKey(const Key('say-hi-mira')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('say-hi-sheet')), findsNothing);
      expect(hi.sent, hasLength(1));
    });

    testWidgets('the sheet is read out and its buttons reach 48 dp', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await mount(tester, store: MemorySayHiPrefsStore());
      await tester.tap(find.byKey(const Key('say-hi-mira')));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Send hi'), findsOneWidget);
      expect(find.bySemanticsLabel('Cancel'), findsOneWidget);
      for (final key in ['say-hi-send', 'say-hi-cancel']) {
        expect(
          tester.getSize(find.byKey(Key(key))).height,
          greaterThanOrEqualTo(40),
        );
      }
      handle.dispose();
    });

    testWidgets(
      'there is never a word on the control, before or after a wave',
      (tester) async {
        final hi = HiLog();
        await mount(tester, hi: hi);
        expect(find.text('Say hi'), findsNothing);
        await tapHi(tester, 'mira');
        await tester.pumpAndSettle();
        expect(stateOf(tester, 'mira'), SayHiState.done);
        expect(find.text('Say hi'), findsNothing);
        // Still named for a screen reader and in the tooltip.
        expect(find.byTooltip('Hi sent to Mira Kapoor'), findsOneWidget);
        expect(find.byTooltip('Say hi to Noor'), findsOneWidget);
      },
    );
  });

  group('failures', () {
    testWidgets(
      'a person who does not take messages says so under the row and stays disabled for the session',
      (tester) async {
        final hi = HiLog()
          ..failure = const ChatFailure(
            'MESSAGES_NOT_ALLOWED',
            'This account isn\'t accepting messages from you',
            403,
          );
        final container = await mount(tester, hi: hi);
        await tapHi(tester, 'mira');
        await tester.pumpAndSettle();
        expect(
          find.text('Mira Kapoor isn’t accepting messages from you.'),
          findsOneWidget,
        );
        expect(stateOf(tester, 'mira'), SayHiState.notAllowed);
        expect(pathOf(container), '/discover');
        await tester.tap(find.byKey(const Key('say-hi-mira')));
        await tester.pumpAndSettle();
        expect(hi.opened, ['mira']);
        // Others are unaffected.
        hi.failure = null;
        await tester.tap(find.byKey(const Key('say-hi-arjun')));
        await tester.pumpAndSettle();
        expect(hi.sent.map((m) => m.$2), ['arjun']);
        expect(stateOf(tester, 'mira'), SayHiState.notAllowed);
      },
    );

    testWidgets(
      'a rate limit shows the server’s message and the wait, rests every control and marks nothing sent',
      (tester) async {
        final hi = HiLog()
          ..failure = const ChatFailure(
            'RATE_LIMITED',
            'You have started a lot of new conversations.',
            429,
            Duration(seconds: 45),
          );
        final store = confirmedStore();
        final container = await mount(tester, hi: hi, store: store);
        await tapHi(tester, 'mira');
        await tester.pumpAndSettle();
        expect(
          find.textContaining('You have started a lot of new conversations.'),
          findsOneWidget,
        );
        expect(find.textContaining('45 seconds'), findsOneWidget);
        expect(pathOf(container), '/discover');
        expect(stateOf(tester, 'mira'), SayHiState.disabled);
        expect(store.sentBy, isEmpty);
        // Resting: a tap right after does not call the server again.
        await tester.tap(find.byKey(const Key('say-hi-arjun')));
        await tester.pump();
        expect(hi.opened, ['mira']);
        // After the wait it works again, and the note is gone.
        hi.failure = null;
        await tester.pump(const Duration(seconds: 46));
        expect(find.textContaining('45 seconds'), findsNothing);
        expect(stateOf(tester, 'mira'), SayHiState.idle);
        await tester.tap(find.byKey(const Key('say-hi-arjun')));
        await tester.pumpAndSettle();
        expect(hi.opened, ['mira', 'arjun']);
      },
    );

    testWidgets(
      'the daily limit for starting chats says when to try again, and rests at most a minute',
      (tester) async {
        final hi = HiLog()
          ..failure = const ChatFailure(
            'QUOTA',
            'You’ve reached today’s limit for starting new chats. Try again later.',
            429,
            Duration(seconds: 3412),
          );
        await mount(tester, hi: hi);
        await tapHi(tester, 'mira');
        await tester.pumpAndSettle();
        expect(
          find.text(
            'You’ve reached today’s limit for starting new chats. Try again in about 57 minutes.',
          ),
          findsOneWidget,
        );
        expect(stateOf(tester, 'mira'), SayHiState.disabled);
        expect(sayHiRetryAfter(hi.failure!), const Duration(minutes: 1));
        hi.failure = null;
        await tester.pump(const Duration(seconds: 61));
        expect(stateOf(tester, 'mira'), SayHiState.idle);
        expect(hi.sent, isEmpty);
      },
    );

    testWidgets(
      'any other failure is calm, keeps the list and offers a retry on the same control',
      (tester) async {
        final hi = HiLog()
          ..sendFailure = const ChatFailure(
            'NETWORK',
            'Couldn’t reach the chat service. Check your connection.',
          );
        final handle = tester.ensureSemantics();
        final container = await mount(tester, hi: hi);
        await tapHi(tester, 'mira');
        await tester.pumpAndSettle();
        expect(
          find.text('Couldn’t reach the chat service. Check your connection.'),
          findsOneWidget,
        );
        expect(stateOf(tester, 'mira'), SayHiState.retry);
        expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
        expect(
          find.bySemanticsLabel('Try again: say hi to Mira Kapoor'),
          findsOneWidget,
        );
        expect(pathOf(container), '/discover');
        // Other rows are free meanwhile; retrying on the same control works.
        expect(stateOf(tester, 'arjun'), SayHiState.idle);
        hi.sendFailure = null;
        await tester.tap(find.byKey(const Key('say-hi-mira')));
        await tester.pumpAndSettle();
        expect(stateOf(tester, 'mira'), SayHiState.done);
        expect(hi.sent, hasLength(1));
        expect(
          find.text('Couldn’t reach the chat service. Check your connection.'),
          findsNothing,
        );
        handle.dispose();
      },
    );

    testWidgets('an unexpected error shows the generic encryption message', (
      tester,
    ) async {
      final hi = HiLog()..failure = StateError('boom');
      await mount(tester, hi: hi);
      await tapHi(tester, 'mira');
      await tester.pumpAndSettle();
      expect(
        find.text('Something went wrong with encryption on this device.'),
        findsOneWidget,
      );
      expect(stateOf(tester, 'mira'), SayHiState.retry);
    });

    testWidgets(
      'while the engine sets up its keys the row says so, then the wave goes',
      (tester) async {
        final hi = HiLog()
          ..ready = false
          ..engineUp = Completer<void>();
        await mount(tester, hi: hi);
        await tapHi(tester, 'mira');
        expect(find.text('Setting up encryption…'), findsOneWidget);
        expect(stateOf(tester, 'mira'), SayHiState.pending);
        expect(hi.sent, isEmpty);
        hi.engineUp!.complete();
        await tester.pumpAndSettle();
        expect(find.text('Setting up encryption…'), findsNothing);
        expect(hi.sent, [('conv-1', 'mira', '👋')]);
        expect(stateOf(tester, 'mira'), SayHiState.done);
      },
    );

    testWidgets('an engine that cannot start offers a retry', (tester) async {
      final hi = HiLog()
        ..ready = false
        ..connectFailure = StateError('keys');
      await mount(tester, hi: hi);
      await tapHi(tester, 'mira');
      await tester.pumpAndSettle();
      expect(stateOf(tester, 'mira'), SayHiState.retry);
      expect(find.text('Setting up encryption…'), findsNothing);
      hi.connectFailure = null;
      await tester.tap(find.byKey(const Key('say-hi-mira')));
      await tester.pumpAndSettle();
      expect(hi.sent, hasLength(1));
    });
  });

  group('sent for 24 hours', () {
    testWidgets('it stays sent for a day, per account, and then goes back', (
      tester,
    ) async {
      final clock = HiClock();
      final store = confirmedStore();
      final hi = HiLog();
      await mount(tester, hi: hi, store: store, clock: clock);
      await tapHi(tester, 'mira');
      await tester.pumpAndSettle();
      expect(store.sentBy[anjaliId], {'mira': clock.now});
      await tester.pumpWidget(const SizedBox());

      // Reopened 23 h 59 min later: still sent, and still no second wave.
      clock.now = clock.now.add(const Duration(hours: 23, minutes: 59));
      await mount(tester, hi: hi, store: store, clock: clock);
      expect(stateOf(tester, 'mira'), SayHiState.done);
      expect(find.byTooltip('Hi sent to Mira Kapoor'), findsOneWidget);
      await tester.tap(find.byKey(const Key('say-hi-mira')));
      await tester.pumpAndSettle();
      expect(hi.sent, hasLength(1));
      await tester.pumpWidget(const SizedBox());

      // Two minutes on it is a day: back to the wave.
      clock.now = clock.now.add(const Duration(minutes: 2));
      await mount(tester, hi: hi, store: store, clock: clock);
      expect(stateOf(tester, 'mira'), SayHiState.idle);
    });

    testWidgets('after a day a person you wrote to shows Message', (
      tester,
    ) async {
      final clock = HiClock();
      final store = confirmedStore()
        ..sentBy[anjaliId] = {
          'mira': clock.now.subtract(const Duration(hours: 25)),
        };
      await mount(tester, store: store, clock: clock, peers: {'mira': 'c1'});
      expect(stateOf(tester, 'mira'), SayHiState.message);
    });

    testWidgets('another account on the same phone does not see them', (
      tester,
    ) async {
      final clock = HiClock();
      final store = confirmedStore()
        ..sentBy['someone-else'] = {'mira': clock.now}
        ..sentBy[anjaliId] = {'arjun': clock.now};
      await mount(tester, store: store, clock: clock);
      expect(stateOf(tester, 'mira'), SayHiState.idle);
      expect(stateOf(tester, 'arjun'), SayHiState.done);
    });

    test('the stored waves round-trip, drop what does not parse and keep only the last day', () {
      final now = DateTime.utc(2026, 10, 13, 12);
      final sent = {
        'a': now.subtract(const Duration(hours: 1)),
        'b': now.subtract(const Duration(hours: 24)),
      };
      final back = decodeSent(encodeSent(sent));
      expect(back, sent);
      expect(freshSent(back, now).keys, ['a']);
      expect(decodeSent('nonsense'), isEmpty);
      expect(decodeSent('{"a":"x","b":5}').keys, ['b']);
      expect(decodeSent(null), isEmpty);
    });
  });

  group('feedback', () {
    testWidgets(
      'a short toast says who got it, replaces the last one and goes after two seconds',
      (tester) async {
        final handle = tester.ensureSemantics();
        await mount(tester, hi: HiLog());
        await tapHi(tester, 'mira');
        await tester.pumpAndSettle();
        expect(find.text('👋 sent to Mira Kapoor'), findsOneWidget);
        expect(
          tester
              .getSemantics(find.byKey(const Key('say-hi-toast')))
              .flagsCollection
              .isLiveRegion,
          isTrue,
        );
        // The next one takes its place; they never stack.
        await tester.pump(const Duration(milliseconds: 1500));
        await tapHi(tester, 'arjun');
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('say-hi-toast')), findsOneWidget);
        expect(find.text('👋 sent to Mira Kapoor'), findsNothing);
        expect(find.textContaining('👋 sent to Arjun'), findsOneWidget);
        // The first one's two seconds are over; the second's are not.
        await tester.pump(const Duration(milliseconds: 1500));
        expect(find.textContaining('👋 sent to Arjun'), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('say-hi-toast')), findsNothing);
        handle.dispose();
      },
    );

    testWidgets('the toast takes no taps and the list under it still scrolls', (
      tester,
    ) async {
      await mount(tester, hi: HiLog());
      await tapHi(tester, 'mira');
      await tester.pumpAndSettle();
      final toast = find.ancestor(
        of: find.byKey(const Key('say-hi-toast')),
        matching: find.byType(IgnorePointer),
      );
      expect(toast, findsWidgets);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('a light haptic on success, none on failure', (tester) async {
      final haptics = <String?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add(call.arguments as String?);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final hi = HiLog()..failure = const ChatFailure('NETWORK', 'offline');
      await mount(tester, hi: hi);
      await tapHi(tester, 'mira');
      await tester.pumpAndSettle();
      expect(haptics, isEmpty);
      hi.failure = null;
      await tester.tap(find.byKey(const Key('say-hi-mira')));
      await tester.pumpAndSettle();
      expect(haptics, ['HapticFeedbackType.lightImpact']);
    });

    testWidgets(
      'the check animates for about 180 ms, and with reduced motion it just appears',
      (tester) async {
        await mount(tester, hi: HiLog());
        await tester.tap(find.byKey(const Key('say-hi-mira')));
        await tester.pump();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 40));
        // Mid-way both the wave and the check are on screen.
        final row = find.byKey(const Key('say-hi-mira'));
        expect(
          find.descendant(of: row, matching: find.byIcon(Icons.check_rounded)),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: row,
            matching: find.byType(CircularProgressIndicator),
          ),
          findsNothing,
        );
        await tester.pump(const Duration(milliseconds: 220));
        expect(
          find.descendant(of: row, matching: find.byType(FadeTransition)),
          findsWidgets,
        );
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());

        await mount(tester, hi: HiLog(), still: true);
        await tester.tap(find.byKey(const Key('say-hi-mira')));
        await tester.pump();
        await tester.pump();
        // One frame is enough: nothing is still fading out.
        final switcher = find.descendant(
          of: find.byKey(const Key('say-hi-mira')),
          matching: find.byType(AnimatedSwitcher),
        );
        expect(
          tester.widget<AnimatedSwitcher>(switcher).duration,
          Duration.zero,
        );
        expect(
          find.descendant(
            of: find.byKey(const Key('say-hi-mira')),
            matching: find.byIcon(Icons.waving_hand_rounded),
          ),
          findsNothing,
        );
      },
    );

    testWidgets(
      'the control changes its words for a screen reader in every state',
      (tester) async {
        final handle = tester.ensureSemantics();
        final hi = HiLog()..sendHold = Completer<void>();
        await mount(tester, hi: hi);
        expect(find.bySemanticsLabel('Say hi to Mira Kapoor'), findsOneWidget);
        await tapHi(tester, 'mira');
        expect(
          find.bySemanticsLabel('Sending hi to Mira Kapoor'),
          findsOneWidget,
        );
        hi.sendHold!.complete();
        await tester.pumpAndSettle();
        expect(find.bySemanticsLabel('Hi sent to Mira Kapoor'), findsOneWidget);
        expect(find.byTooltip('Hi sent to Mira Kapoor'), findsOneWidget);
        // A sent control is announced as disabled.
        expect(
          tester
              .getSemantics(find.bySemanticsLabel('Hi sent to Mira Kapoor'))
              .flagsCollection
              .isEnabled,
          ui.Tristate.isFalse,
        );
        handle.dispose();
      },
    );
  });

  group('large text and narrow screens', () {
    for (final dark in [true, false]) {
      testWidgets(
        'at 320 px and text x2 every state fits (${dark ? 'dark' : 'light'})',
        (tester) async {
          final hi = HiLog();
          await mount(
            tester,
            hi: hi,
            size: const Size(320, 640),
            scale: 2,
            dark: dark,
            peers: {'jules': 'c9'},
          );
          // Message, sent (with the toast up), refused, and the rest of the rows idle.
          Future<void> reveal(String id) => tester.scrollUntilVisible(
            find.byKey(Key('say-hi-$id')),
            200,
            scrollable: find.byType(Scrollable).first,
          );
          await reveal('mira');
          await tapHi(tester, 'mira');
          await tester.pumpAndSettle();
          hi.failure = const ChatFailure('MESSAGES_NOT_ALLOWED', 'no', 403);
          await reveal('arjun');
          await tapHi(tester, 'arjun');
          await tester.pumpAndSettle();
          expect(find.text('👋 sent to Mira Kapoor'), findsOneWidget);
          expect(
            find.text(
              'Arjun Venkataraghavan-Krishnamurthy isn’t accepting messages from you.',
            ),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          final toast = tester.getRect(find.byKey(const Key('say-hi-toast')));
          expect(toast.left, greaterThanOrEqualTo(0));
          expect(toast.right, lessThanOrEqualTo(320));
          await tester.fling(
            find.byType(Scrollable).first,
            const Offset(0, 3000),
            3000,
          );
          await tester.pumpAndSettle();
          for (final id in ['mira', 'arjun', 'jules']) {
            await reveal(id);
            final r = tester.getRect(find.byKey(Key('say-hi-$id')));
            expect(r.right, lessThanOrEqualTo(320), reason: id);
            expect(r.height, greaterThanOrEqualTo(48), reason: id);
          }
          await tester.pump(const Duration(seconds: 3));
        },
      );
    }
  });

  group('contrast', () {
    for (final tokens in [ChatTokens.dark, ChatTokens.light]) {
      test(
        'the sent, disabled, note and toast colours are AA in the ${tokens.isDark ? 'dark' : 'light'} theme',
        () {
          final s = DiscoverStyle(tokens);
          for (final (name, fg, bg) in [
            ('sent', s.hiDoneInk, s.hiDoneFill),
            ('sent on page', s.hiDoneInk, tokens.bg),
            ('disabled', s.hiOffInk, s.hiOffFill),
            ('disabled on page', s.hiOffInk, tokens.bg),
            ('idle', s.hiInk, s.hiFill),
            ('note', s.noteInk, tokens.bg),
            ('toast', s.toastInk, s.toastFill),
          ]) {
            expect(
              contrastRatio(fg, bg),
              greaterThanOrEqualTo(4.5),
              reason: name,
            );
          }
          expect(
            s.pairs.map((p) => p.$1),
            containsAll([
              'say hi sent',
              'say hi disabled',
              'say hi note',
              'say hi toast',
            ]),
          );
        },
      );
    }
  });
}
