import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/translate/fake_translation_service.dart';
import 'package:hiyall/features/chat_av_providers.dart'
    show translationServiceProvider;
import 'package:hiyall/features/pulse/translate_button.dart';

import 'pulse7_test.dart' show niko, personJson, postJson, scripted;
import 'support/app_host.dart';

// The translate button on posts, comments and stories (on the phone, TranslationService), and the new Pulse
// screens at text scale 2.0 on a 320 px screen, right to left and dark.

Future<void> pumpScope(
  WidgetTester tester,
  FakeTranslationService service,
  String text,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [translationServiceProvider.overrideWithValue(service)],
      child: MaterialApp(
        locale: const Locale('en'),
        home: Scaffold(
          body: TranslateScope(
            id: 'x1',
            text: text,
            builder: (context, shown, button) => Column(
              children: [
                Text(shown, key: const Key('shown')),
                ?button,
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('translate button', () {
    testWidgets(
      'appears for text in another language and shows the translation in place',
      (tester) async {
        final service = FakeTranslationService(
          installed: {'es'},
          detects: {'hola amigos': 'es'},
        );
        await pumpScope(tester, service, 'hola amigos');
        expect(find.byKey(const Key('translate-x1')), findsOneWidget);
        expect(
          service.translated,
          isEmpty,
          reason: 'nothing is translated until asked',
        );
        await tester.tap(find.byKey(const Key('translate-x1')));
        await tester.pumpAndSettle();
        expect(find.text('[en] hola amigos'), findsOneWidget);
        expect(find.byKey(const Key('show-original-x1')), findsOneWidget);
        await tester.tap(find.byKey(const Key('show-original-x1')));
        await tester.pumpAndSettle();
        expect(find.text('hola amigos'), findsOneWidget);
      },
    );

    testWidgets(
      'is hidden for text already in the reader’s language and when the phone cannot translate',
      (tester) async {
        await pumpScope(tester, FakeTranslationService(), 'hello friends');
        expect(find.byKey(const Key('translate-x1')), findsNothing);
        await pumpScope(
          tester,
          FakeTranslationService(isSupported: false, detects: {'hola': 'es'}),
          'hola',
        );
        expect(find.byKey(const Key('translate-x1')), findsNothing);
        expect(find.text('hola'), findsOneWidget);
      },
    );

    testWidgets('asks before downloading a language pack', (tester) async {
      final service = FakeTranslationService(detects: {'hola amigos': 'es'});
      await pumpScope(tester, service, 'hola amigos');
      await tester.tap(find.byKey(const Key('translate-x1')));
      // The button shows a spinner while the question is open, so settle by hand.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Download a language?'), findsOneWidget);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      expect(service.downloads, isEmpty);
      expect(find.text('hola amigos'), findsOneWidget);
    });
  });

  group('layout', () {
    for (final (name, scale, direction, brightness) in [
      ('text scale 2.0', 2.0, null, Brightness.light),
      ('right to left', 1.0, TextDirection.rtl, Brightness.light),
      ('dark', 1.0, null, Brightness.dark),
    ]) {
      testWidgets('search and My activity fit 320 px wide at $name', (
        tester,
      ) async {
        final api = scripted();
        api.on(
          'GET /v1/search/pulse',
          (_, _) => {
            'items': [
              postJson(
                'p1',
                'learning guitar chords with friends every week',
                topic: 'music',
              ),
            ],
            'nextCursor': 'n',
            'scope': 'posts',
          },
        );
        api.on(
          'GET /v1/me/activity/comments',
          (_, _) => {
            'items': [
              {
                'commentId': 'c1',
                'postId': 'p1',
                'parentId': null,
                'body': 'a long comment that has to wrap over several lines at a large text size',
                'createdAt': DateTime.now().toIso8601String(),
                'post': {
                  'postId': 'p1',
                  'state': 'available',
                  'author': personJson(niko),
                  'excerpt': 'the post text, which is also fairly long to check wrapping',
                  'topic': null,
                  'hasMedia': false,
                  'hasVoice': true,
                },
              },
            ],
            'nextCursor': null,
          },
        );
        await launchApp(
          tester,
          api,
          '/search',
          size: const Size(320, 640),
          textScale: scale,
          direction: direction,
          brightness: brightness,
        );
        await tester.enterText(
          find.byKey(const Key('pulse-search-input')),
          'guitar',
        );
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('search-post-p1')), findsOneWidget);
        expect(tester.takeException(), isNull);
        final more = tester.getRect(find.byKey(const Key('pulse-search-more')));
        expect(more.height, greaterThanOrEqualTo(48));
        final chip = tester.getRect(find.byKey(const Key('search-topic-all')));
        expect(chip.height, greaterThanOrEqualTo(48));
        expect(chip.left, greaterThanOrEqualTo(0));
      });
    }
  });
}
