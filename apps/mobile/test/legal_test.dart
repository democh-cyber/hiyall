import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/app.dart' show routerProvider;
import 'package:hiyall/core/api.dart' show OnboardingStatus, Session;
import 'package:hiyall/core/auth/auth_gateway.dart';
import 'package:hiyall/core/legal_documents.dart';
import 'package:hiyall/core/theme.dart';
import 'package:hiyall/features/legal_screens.dart';
import 'package:hiyall/shared/chat_tokens.dart';

import 'auth_test.dart'
    show AuthApi, FakeGateway, fillOnboarding, launch, location, next;

const banner =
    'DRAFT for legal review. Not legal advice. Placeholders in [BRACKETS] must be filled by the operator.';

String asset(LegalDoc doc) => File(doc.asset).readAsStringSync();

double contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (la > lb ? la + .05 : lb + .05) / (la > lb ? lb + .05 : la + .05);
}

void main() {
  group('the terms version', () {
    test('every bundled document carries the version this build presents', () {
      for (final doc in LegalDoc.values) {
        expect(
          legalVersionOf(asset(doc)),
          kTermsVersion,
          reason: '${doc.asset} has a different Version: header',
        );
      }
    });

    test('the server constant is the same version', () {
      final go = File('../../services/api/internal/domain/onboarding.go')
          .readAsStringSync();
      final match = RegExp(r'TermsVersion\s*=\s*"([^"]+)"').firstMatch(go);
      expect(match, isNotNull, reason: 'domain.TermsVersion not found');
      expect(
        match!.group(1),
        kTermsVersion,
        reason: 'bump domain.TermsVersion, kTermsVersion and every Version: header together',
      );
    });

    test(
      'the reviewed drafts in docs/legal and the bundled copies are identical',
      () {
        for (final doc in LegalDoc.values) {
          final name = doc.asset.split('/').last;
          final source = File('../../docs/legal/$name');
          expect(source.existsSync(), isTrue, reason: 'docs/legal/$name');
          expect(
            asset(doc),
            source.readAsStringSync(),
            reason: '$name differs from docs/legal/$name: copy it over',
          );
        }
      },
    );

    test(
      'every document opens with the draft banner until it is finalised',
      () {
        for (final doc in LegalDoc.values) {
          expect(
            asset(doc).trimLeft(),
            startsWith('> **$banner**'),
            reason: doc.name,
          );
        }
      },
    );

    test('the version line is found only in the header', () {
      expect(legalVersionOf('# T\n\nVersion: 2026-10-01\n'), '2026-10-01');
      expect(legalVersionOf('Version:2027-01-01'), '2027-01-01');
      expect(legalVersionOf('# no version here'), isNull);
      expect(legalVersionOf('The Version: 1 is in prose'), isNull);
    });
  });

  group('the markdown subset', () {
    test(
      'headings, paragraphs that keep their line breaks, bullets and quotes',
      () {
        final blocks = parseLegal('''
> **Draft**

# Title

Version: 1

## Section

First line
Second line

- one
- two
  continues

### Small
''');
        expect(blocks.length, 7);
        expect((blocks[0] as LegalCallout).text, '**Draft**');
        expect((blocks[1] as LegalHeading).level, 1);
        expect((blocks[2] as LegalParagraph).text, 'Version: 1');
        expect((blocks[3] as LegalHeading).text, 'Section');
        expect((blocks[4] as LegalParagraph).text, 'First line\nSecond line');
        expect((blocks[5] as LegalBullets).items, ['one', 'two continues']);
        expect((blocks[6] as LegalHeading).level, 3);
      },
    );

    test('tables become headers and rows without the separator line', () {
      final blocks = parseLegal('''
| What | How long |
|---|---|
| Stories | **1 day** |
| Photos | Until deleted |
''');
      final table = blocks.single as LegalTable;
      expect(table.headers, ['What', 'How long']);
      expect(table.rows, [
        ['Stories', '**1 day**'],
        ['Photos', 'Until deleted'],
      ]);
    });

    test('bold runs are split out and an unclosed marker stays literal', () {
      expect(legalSpans('a **b** c'), [
        (text: 'a ', bold: false),
        (text: 'b', bold: true),
        (text: ' c', bold: false),
      ]);
      expect(legalSpans('**all**'), [(text: 'all', bold: true)]);
      expect(legalSpans('a **b'), [(text: 'a **b', bold: false)]);
    });

    test('every real document parses to something and keeps its sections', () {
      for (final doc in LegalDoc.values) {
        final blocks = parseLegal(asset(doc));
        expect(blocks.first, isA<LegalCallout>(), reason: doc.name);
        expect(
          blocks.whereType<LegalHeading>().first.text,
          doc.title,
          reason: doc.name,
        );
        expect(blocks.whereType<LegalHeading>().length, greaterThan(4));
      }
      // The retention table survives as a table with a row per kind of data.
      final table = parseLegal(asset(LegalDoc.retention))
          .whereType<LegalTable>()
          .single;
      expect(table.headers.length, 3);
      expect(table.rows.length, greaterThan(15));
      expect(table.rows.every((r) => r.length == 3), isTrue);
    });
  });

  group('the pages', () {
    Future<ProviderContainer> signedOut(WidgetTester tester) =>
        launch(tester, api: AuthApi(), gateway: FakeGateway());

    testWidgets('are readable signed out, outside the sign-in redirect', (
      tester,
    ) async {
      final container = await signedOut(tester);
      expect(location(container), '/welcome');
      for (final doc in LegalDoc.values) {
        container.read(routerProvider).go(doc.path);
        await tester.pumpAndSettle();
        expect(location(container), doc.path, reason: doc.path);
        expect(find.byKey(Key('legal-${doc.name}')), findsOneWidget);
        expect(find.byKey(const Key('legal-callout')), findsOneWidget);
        expect(find.textContaining('DRAFT for legal review'), findsOneWidget);
        expect(find.text('Version: $kTermsVersion'), findsOneWidget);
      }
    });

    testWidgets('are readable while onboarding and then return to it', (
      tester,
    ) async {
      final container = await launch(
        tester,
        api: AuthApi(),
        gateway: FakeGateway(
          const AuthUser(
            uid: 'u',
            method: AuthMethod.google,
            email: 'sam@example.com',
            emailVerified: true,
          ),
        ),
      );
      expect(location(container), '/onboarding');
      await tester.tap(find.byKey(const Key('legal-link-terms')));
      await tester.pumpAndSettle();
      // A pushed page sits above onboarding; Back returns to it.
      expect(find.byKey(const Key('legal-terms')), findsOneWidget);
      await tester.tap(find.byKey(const Key('legal-back')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('legal-terms')), findsNothing);
      expect(find.text('First, the basics'), findsOneWidget);
      expect(location(container), '/onboarding');
    });

    testWidgets('the Welcome, log in and sign up footers link to them', (
      tester,
    ) async {
      final container = await signedOut(tester);
      for (final path in ['/welcome', '/login', '/signup']) {
        container.read(routerProvider).go(path);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('legal-footer')),
          findsOneWidget,
          reason: path,
        );
        for (final doc in [
          LegalDoc.terms,
          LegalDoc.privacy,
          LegalDoc.guidelines,
          LegalDoc.teens,
        ]) {
          expect(
            find.byKey(Key('legal-link-${doc.name}')),
            findsOneWidget,
            reason: '$path ${doc.name}',
          );
        }
      }
      container.read(routerProvider).go('/welcome');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('legal-link-privacy')));
      await tester.tap(find.byKey(const Key('legal-link-privacy')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('legal-privacy')), findsOneWidget);
      await tester.tap(find.byKey(const Key('legal-back')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('legal-privacy')), findsNothing);
      expect(location(container), '/welcome');
    });

    testWidgets('their links are at least 48 dp tall', (tester) async {
      final container = await signedOut(tester);
      container.read(routerProvider).go('/login');
      await tester.pumpAndSettle();
      for (final doc in [LegalDoc.terms, LegalDoc.privacy, LegalDoc.teens]) {
        final finder = find.byKey(Key('legal-link-${doc.name}'));
        await tester.ensureVisible(finder);
        expect(tester.getSize(finder).height, greaterThanOrEqualTo(48));
      }
    });

    testWidgets('one document leads to the others and back out', (
      tester,
    ) async {
      final container = await signedOut(tester);
      container.read(routerProvider).go('/legal/guidelines');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('legal-more-guidelines')), findsNothing);
      await tester.dragUntilVisible(
        find.byKey(const Key('legal-more-teens')),
        find.byKey(const Key('legal-scroll')),
        const Offset(0, -400),
      );
      await tester.tap(find.byKey(const Key('legal-more-teens')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('legal-teens')), findsOneWidget);
      expect(find.byKey(const Key('legal-guidelines')), findsNothing);
    });

    testWidgets('back from a page opened directly goes home', (tester) async {
      final container = await signedOut(tester);
      container.read(routerProvider).go('/legal/terms');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('legal-back')));
      await tester.pumpAndSettle();
      // Signed out, home is Welcome.
      expect(location(container), '/welcome');
    });
  });

  group('settings', () {
    testWidgets('lists every document and opens it above Settings', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 2400);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final container = await launch(
        tester,
        api: AuthApi()..onboarded = true,
        gateway: FakeGateway(
          const AuthUser(
            uid: 'u',
            method: AuthMethod.google,
            email: 'sam@example.com',
            emailVerified: true,
          ),
        ),
      );
      container.read(routerProvider).go('/profile/settings');
      await tester.pumpAndSettle();
      for (final doc in LegalDoc.values) {
        final row = find.byKey(Key('settings-legal-${doc.name}'));
        await tester.scrollUntilVisible(
          row,
          300,
          scrollable: find.byType(Scrollable).first,
        );
        expect(row, findsOneWidget, reason: doc.name);
        expect(tester.getSize(row).height, greaterThanOrEqualTo(48));
      }
      // The floating dock can sit over the last rows; call the row's own handler.
      tester
          .widget<ListTile>(find.byKey(const Key('settings-legal-teens')))
          .onTap!();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('legal-teens')), findsOneWidget);
      await tester.tap(find.byKey(const Key('legal-back')));
      await tester.pumpAndSettle();
      expect(location(container), '/profile/settings');
    });
  });

  group('onboarding consent', () {
    testWidgets('names the accepted version and links every document', (
      tester,
    ) async {
      final container = await launch(
        tester,
        api: AuthApi(),
        gateway: FakeGateway(
          const AuthUser(
            uid: 'u',
            method: AuthMethod.google,
            emailVerified: true,
          ),
        ),
      );
      expect(location(container), '/onboarding');
      expect(find.text('Terms version $kTermsVersion'), findsOneWidget);
      for (final doc in [
        LegalDoc.terms,
        LegalDoc.privacy,
        LegalDoc.guidelines,
        LegalDoc.teens,
      ]) {
        expect(find.byKey(Key('legal-link-${doc.name}')), findsOneWidget);
      }
    });

    testWidgets('sends the version the page showed', (tester) async {
      final api = AuthApi();
      await launch(
        tester,
        api: api,
        gateway: FakeGateway(
          const AuthUser(
            uid: 'u',
            method: AuthMethod.google,
            email: 'sam@example.com',
            emailVerified: true,
          ),
        ),
      );
      await fillOnboarding(tester);
      await next(tester, 'onb-finish');
      expect(api.completed?['termsVersion'], kTermsVersion);
    });

    testWidgets('refuses to accept a revision this build never showed', (
      tester,
    ) async {
      final api = _NewerTermsApi();
      final container = await launch(
        tester,
        api: api,
        gateway: FakeGateway(
          const AuthUser(
            uid: 'u',
            method: AuthMethod.google,
            email: 'sam@example.com',
            emailVerified: true,
          ),
        ),
      );
      await fillOnboarding(tester);
      await next(tester, 'onb-finish');
      expect(api.completed, isNull);
      expect(find.textContaining('Update the app'), findsOneWidget);
      expect(location(container), '/onboarding');
    });
  });

  group('look and feel', () {
    Widget host(
      LegalDoc doc, {
      required Brightness brightness,
      double scale = 1,
      bool reduceMotion = false,
    }) => ProviderScope(
      child: MaterialApp(
        theme: hiyallTheme(brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: reduceMotion,
          ),
          child: child!,
        ),
        home: LegalScreen(doc: doc),
      ),
    );

    for (final brightness in Brightness.values) {
      testWidgets(
        'every page fits 320 px at text scale 2 (${brightness.name})',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(320, 640);
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          for (final doc in LegalDoc.values) {
            await tester.pumpWidget(
              host(doc, brightness: brightness, scale: 2, reduceMotion: true),
            );
            await tester.pumpAndSettle();
            final scroll = find.byKey(const Key('legal-scroll'));
            expect(scroll, findsOneWidget);
            // Read to the end; any overflow would be reported as an exception.
            for (var i = 0; i < 400; i++) {
              if (find
                  .text('More from Hiyall')
                  .hitTestable()
                  .evaluate()
                  .isNotEmpty) {
                break;
              }
              await tester.drag(scroll, const Offset(0, -500));
              await tester.pump();
            }
            expect(find.text('More from Hiyall').hitTestable(), findsOneWidget);
            expect(tester.takeException(), isNull, reason: doc.name);
          }
        },
      );
    }

    for (final brightness in Brightness.values) {
      test(
        'text keeps AA contrast on every surface it sits on (${brightness.name})',
        () {
          final t = brightness == Brightness.dark
              ? ChatTokens.dark
              : ChatTokens.light;
          for (final text in [t.text, t.textSecondary]) {
            for (final surface in [t.bg, t.surface, t.elevated]) {
              expect(contrast(text, surface), greaterThanOrEqualTo(4.5));
            }
          }
          // The footer and consent copy sit on the page behind the sign-in forms.
          final theme = hiyallTheme(brightness);
          expect(
            contrast(
              theme.colorScheme.onSurfaceVariant,
              theme.scaffoldBackgroundColor,
            ),
            greaterThanOrEqualTo(4.5),
          );
          expect(
            contrast(theme.colorScheme.onSurface, theme.colorScheme.surface),
            greaterThanOrEqualTo(4.5),
          );
        },
      );
    }

    testWidgets(
      'long text can be read to the end and nothing animates when motion is reduced',
      (tester) async {
        await tester.pumpWidget(
          host(
            LegalDoc.privacy,
            brightness: Brightness.light,
            reduceMotion: true,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Privacy Policy'), findsWidgets);
        expect(find.text('The short version'), findsOneWidget);
        expect(tester.hasRunningAnimations, isFalse);
      },
    );

    testWidgets('a missing asset shows a retry instead of a blank page', (
      tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            legalTextProvider.overrideWith(
              (ref, doc) => throw StateError('gone'),
            ),
          ],
          child: MaterialApp(
            theme: hiyallTheme(Brightness.light),
            home: const LegalScreen(doc: LegalDoc.terms),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('legal-retry')), findsOneWidget);
      expect(find.text('This page couldn’t be opened.'), findsOneWidget);
    });
  });
}

/// The service has moved on to a revision this build does not contain.
class _NewerTermsApi extends AuthApi {
  @override
  Future<OnboardingStatus> onboarding(Session s) async =>
      OnboardingStatus(false, '2099-01-01');
}
