import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hiyall/app.dart';
import 'package:hiyall/core/activity_state.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/auth/firebase_config.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/features/auth/auth_screens.dart';
import 'package:hiyall/features/help_safety.dart'
    show HelpContacts, mailLauncher;
import 'package:hiyall/features/live_sync.dart';
import 'package:url_launcher/url_launcher.dart' show launchUrl;
import 'package:hiyall/features/pulse.dart' show photoDecodeWidth;

import 'widget_test.dart' show FakeApi, SignedIn;

Future<ProviderContainer> open(
  WidgetTester tester,
  FakeApi api,
  String at, {
  Size size = const Size(390, 844),
  List<Override> overrides = const [],
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final container = ProviderContainer(
    overrides: [
      apiProvider.overrideWithValue(api),
      sessionProvider.overrideWith(SignedIn.new),
      ...overrides,
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const HiyallApp()),
  );
  container.read(routerProvider).go(at);
  await tester.pumpAndSettle();
  return container;
}

/// Counts how often the live-sync safety net asks the server for news.
class _CountingActivity extends ActivityController {
  static int syncs = 0;
  @override
  Future<ActivityState> build() async => const ActivityState([]);
  @override
  Future<void> syncUnread() async => syncs++;
}

/// Counts the automatic "is it verified yet?" checks.
class _CountingSession extends SessionController {
  static int checks = 0;
  @override
  AsyncValue<Session?> build() => const AsyncData(null);
  @override
  Future<void> refreshAuth() async => checks++;
}

void lifecycle(WidgetTester tester, List<AppLifecycleState> steps) {
  for (final s in steps) {
    tester.binding.handleAppLifecycleStateChanged(s);
  }
}

const toBackground = [
  AppLifecycleState.inactive,
  AppLifecycleState.hidden,
  AppLifecycleState.paused,
];
const toForeground = [
  AppLifecycleState.hidden,
  AppLifecycleState.inactive,
  AppLifecycleState.resumed,
];

void main() {
  group('verify-email polling', () {
    test('backs off 5 s, 15 s, then 30 s', () {
      expect(
        [for (var i = 0; i < 5; i++) verifyPollDelay(i).inSeconds],
        [5, 15, 30, 30, 30],
      );
    });

    testWidgets(
      'checks on that schedule and stops while the app is in the background',
      (tester) async {
        _CountingSession.checks = 0;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [sessionProvider.overrideWith(_CountingSession.new)],
            child: const MaterialApp(home: VerifyEmailScreen()),
          ),
        );
        await tester.pump(const Duration(seconds: 4));
        expect(_CountingSession.checks, 0);
        await tester.pump(const Duration(seconds: 1));
        expect(_CountingSession.checks, 1);
        await tester.pump(const Duration(seconds: 14));
        expect(_CountingSession.checks, 1);
        await tester.pump(const Duration(seconds: 1));
        expect(_CountingSession.checks, 2);
        await tester.pump(const Duration(seconds: 29));
        expect(_CountingSession.checks, 2);
        await tester.pump(const Duration(seconds: 1));
        expect(_CountingSession.checks, 3);

        lifecycle(tester, toBackground);
        await tester.pump(const Duration(minutes: 5));
        expect(
          _CountingSession.checks,
          3,
          reason: 'nothing runs in the background',
        );

        lifecycle(tester, toForeground);
        await tester.pump();
        expect(
          _CountingSession.checks,
          4,
          reason: 'coming back checks at once',
        );
        await tester.pump(const Duration(seconds: 5));
        expect(
          _CountingSession.checks,
          5,
          reason: 'and the schedule starts over',
        );

        await tester.pumpWidget(const SizedBox());
      },
    );
  });

  testWidgets(
    'LiveSync stops its safety-net poll in the background and resumes with the app',
    (tester) async {
      _CountingActivity.syncs = 0;
      final container = ProviderContainer(
        overrides: [
          apiProvider.overrideWithValue(FakeApi()),
          sessionProvider.overrideWith(SignedIn.new),
          activityProvider.overrideWith(_CountingActivity.new),
          realtimeProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: LiveSync(child: SizedBox())),
        ),
      );
      await tester.pump(const Duration(seconds: 61));
      final foreground = _CountingActivity.syncs;
      expect(foreground, greaterThan(0), reason: 'the poll runs while visible');

      lifecycle(tester, toBackground);
      await tester.pump();
      final atPause = _CountingActivity.syncs;
      await tester.pump(const Duration(minutes: 10));
      expect(
        _CountingActivity.syncs,
        atPause,
        reason: 'no timers in the background',
      );

      lifecycle(tester, toForeground);
      await tester.pump();
      final atResume = _CountingActivity.syncs;
      expect(atResume, greaterThan(atPause), reason: 'resume syncs at once');
      await tester.pump(const Duration(seconds: 31));
      expect(
        _CountingActivity.syncs,
        greaterThan(atResume),
        reason: 'and the poll restarts',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  group('Firebase start-up', () {
    tearDown(() => FirebaseConfig.initFailed = false);

    test('a failing start is reported as false, never thrown, and disables Firebase', () async {
      final ok = await FirebaseConfig.initialize(
        configured: true,
        start: (_) async => throw StateError('malformed api key'),
      );
      expect(ok, isFalse);
      expect(FirebaseConfig.initFailed, isTrue);
      expect(FirebaseConfig.isConfigured, isFalse);
    });

    test('a start that never answers is cut off', () async {
      // Fake time is not available here; a throwing start covers the catch path
      // and a quick success covers the happy one.
      final ok = await FirebaseConfig.initialize(
        configured: true,
        start: (_) async => null,
      );
      expect(ok, isTrue);
      expect(FirebaseConfig.initFailed, isFalse);
    });

    test('an unconfigured build skips Firebase quietly', () async {
      var called = false;
      final ok = await FirebaseConfig.initialize(
        configured: false,
        start: (_) async => called = true,
      );
      expect(ok, isTrue);
      expect(called, isFalse);
    });
  });

  group('photo decode size', () {
    test(
      'follows layout width times pixel ratio in 64 px steps, capped at 2048',
      () {
        expect(photoDecodeWidth(360, 3), 1088);
        expect(photoDecodeWidth(360, 1), 384);
        expect(photoDecodeWidth(1200, 3), 2048);
        expect(photoDecodeWidth(10, 1), 64);
        expect(photoDecodeWidth(double.infinity, 3), 2048);
        expect(photoDecodeWidth(0, 3), 2048);
      },
    );

    test('a phone photo decodes far smaller than the 2048 px upload', () {
      expect(
        photoDecodeWidth(390, 2) * photoDecodeWidth(390, 2),
        lessThan(2048 * 2048 / 2),
      );
    });
  });

  group('compose asks before discarding', () {
    Future<(ProviderContainer, GoRouter)> compose(WidgetTester tester) async {
      final container = await open(tester, FakeApi(), '/home');
      final router = container.read(routerProvider);
      router.push('/compose');
      await tester.pumpAndSettle();
      return (container, router);
    }

    testWidgets('an empty post closes without asking', (tester) async {
      final (_, router) = await compose(tester);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Discard this post?'), findsNothing);
      expect(router.state.uri.path, '/home');
    });

    testWidgets('a post with text asks; Keep editing stays, Discard leaves', (
      tester,
    ) async {
      final (_, router) = await compose(tester);
      await tester.enterText(
        find.byKey(const Key('post-body')),
        'half a thought',
      );
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Discard this post?'), findsOneWidget);

      await tester.tap(find.byKey(const Key('keep-editing')));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/compose');
      expect(find.text('half a thought'), findsOneWidget);

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('discard-post')));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/home');
    });

    testWidgets('system Back asks too', (tester) async {
      final (_, router) = await compose(tester);
      await tester.enterText(find.byKey(const Key('post-body')), 'draft');
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Discard this post?'), findsOneWidget);
      expect(router.state.uri.path, '/compose');
    });

    testWidgets('whitespace alone is not a draft', (tester) async {
      final (_, router) = await compose(tester);
      await tester.enterText(find.byKey(const Key('post-body')), '   ');
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/home');
    });
  });

  group('Help & Safety', () {
    String? copied;
    setUp(() {
      copied = null;
      TestWidgetsFlutterBinding.ensureInitialized();
      // The addresses in a test build are placeholders; the rows are tested as if real.
      HelpContacts.showPlaceholders = true;
    });
    tearDown(() => HelpContacts.showPlaceholders = false);

    testWidgets(
      'placeholder addresses are hidden: it says contacts are being set up and points at Block and Report',
      (tester) async {
        HelpContacts.showPlaceholders = false;
        await open(tester, FakeApi(), '/profile/help');
        expect(
          find.byKey(const Key('help-contact-Help and feedback')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('help-contact-Safety concerns')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('help-contact-Privacy and your data')),
          findsNothing,
        );
        expect(find.text('support@hiyall.example'), findsNothing);
        expect(find.text('Contact details are being set up'), findsOneWidget);
        expect(
          find.textContaining('use Block and Report in the app'),
          findsOneWidget,
        );
      },
    );

    testWidgets('real addresses are listed and no notice shows', (
      tester,
    ) async {
      HelpContacts.showPlaceholders = false;
      final (support, safety, privacy) = (
        HelpContacts.support,
        HelpContacts.safety,
        HelpContacts.privacy,
      );
      HelpContacts.support = 'help@hiyall.app';
      HelpContacts.safety = 'safety@hiyall.app';
      HelpContacts.privacy = 'privacy@hiyall.app';
      addTearDown(() {
        HelpContacts.support = support;
        HelpContacts.safety = safety;
        HelpContacts.privacy = privacy;
      });
      await open(tester, FakeApi(), '/profile/help');
      expect(
        find.byKey(const Key('help-contact-Help and feedback')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('help-contact-Safety concerns')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('help-contact-setting-up')), findsNothing);
    });

    testWidgets(
      'one real address keeps its row and the notice covers the rest',
      (tester) async {
        HelpContacts.showPlaceholders = false;
        final support = HelpContacts.support;
        HelpContacts.support = 'help@hiyall.app';
        addTearDown(() => HelpContacts.support = support);
        await open(tester, FakeApi(), '/profile/help');
        expect(
          find.byKey(const Key('help-contact-Help and feedback')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('help-contact-Safety concerns')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('help-contact-setting-up')),
          findsOneWidget,
        );
      },
    );

    void captureClipboard(WidgetTester tester) {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
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
    }

    testWidgets(
      'Settings leads to it, and it shows contacts, tips, block and report, and crisis lines',
      (tester) async {
        await open(tester, FakeApi(), '/profile/settings');
        final row = find.byKey(const Key('settings-help'));
        await tester.scrollUntilVisible(
          row,
          300,
          scrollable: find.byType(Scrollable).first,
        );
        // The row may be built (in the cache extent) yet below the screen: bring it into view.
        await tester.ensureVisible(row);
        await tester.pumpAndSettle();
        await tester.tap(row);
        await tester.pumpAndSettle();
        expect(find.text('Help & Safety'), findsWidgets);
        expect(find.byType(SelectableText), findsWidgets);
        expect(find.text('support@hiyall.example'), findsOneWidget);
        expect(find.text('safety@hiyall.example'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text('Staying safe'.toUpperCase()),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text('Staying safe'.toUpperCase()), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text('Block or report someone'.toUpperCase()),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.scrollUntilVisible(
          find.textContaining('988'),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.textContaining('988'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.byKey(const Key('help-legal-guidelines')),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.byKey(const Key('help-legal-terms')), findsOneWidget);
      },
    );

    testWidgets(
      'an address can be copied, and a missing mail app falls back to copying',
      (tester) async {
        captureClipboard(tester);
        await open(tester, FakeApi(), '/profile/help');
        await tester.scrollUntilVisible(
          find.byTooltip('Copy support@hiyall.example'),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(
          find.byTooltip('Copy support@hiyall.example'),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Copy support@hiyall.example'));
        await tester.pump();
        expect(copied, 'support@hiyall.example');
        expect(find.text('Copied support@hiyall.example'), findsOneWidget);

        // A mail app that opens: nothing is copied.
        Uri? opened;
        mailLauncher = (uri) async {
          opened = uri;
          return true;
        };
        addTearDown(() => mailLauncher = (uri) => launchUrl(uri));
        copied = null;
        await tester.ensureVisible(
          find.byKey(const Key('help-contact-Safety concerns')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('help-contact-Safety concerns')));
        await tester.pumpAndSettle();
        expect(opened?.scheme, 'mailto');
        expect(opened?.path, 'safety@hiyall.example');
        expect(copied, isNull);

        // No mail app: the address is copied instead.
        mailLauncher = (uri) async => false;
        await tester.ensureVisible(
          find.byKey(const Key('help-contact-Safety concerns')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('help-contact-Safety concerns')));
        await tester.pumpAndSettle();
        expect(copied, 'safety@hiyall.example');
        expect(find.textContaining('No mail app here'), findsOneWidget);

        // A platform error counts the same.
        copied = null;
        mailLauncher = (uri) async => throw PlatformException(code: 'x');
        await tester.ensureVisible(
          find.byKey(const Key('help-contact-Help and feedback')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('help-contact-Help and feedback')),
        );
        await tester.pumpAndSettle();
        expect(copied, 'support@hiyall.example');
      },
    );

    testWidgets('it fits a 320 px screen at the largest text size', (
      tester,
    ) async {
      await open(
        tester,
        FakeApi(),
        '/profile/help',
        size: const Size(320, 640),
      );
      tester.platformDispatcher.textScaleFactorTestValue = 2.0;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpAndSettle();
      for (var i = 0; i < 12; i++) {
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -500));
        await tester.pump();
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('the licence page opens from Settings', (tester) async {
      await open(tester, FakeApi(), '/profile/settings');
      final row = find.byKey(const Key('settings-licences'));
      await tester.scrollUntilVisible(
        row,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      // The row may be built (in the cache extent) yet below the screen: bring it into view.
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(find.byType(LicensePage), findsOneWidget);
    });
  });
}
