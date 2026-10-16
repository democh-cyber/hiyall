import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/app.dart';
import 'package:hiyall/core/account_state.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/auth/auth_gateway.dart';
import 'package:hiyall/core/auth/reauth.dart';
import 'package:hiyall/core/data_delivery.dart';
import 'package:hiyall/core/error_reporting.dart';
import 'package:hiyall/features/help_safety.dart'
    show HelpContacts, mailLauncher;
import 'package:url_launcher/url_launcher.dart' show launchUrl;
import 'package:hiyall/core/state.dart';
import 'package:hiyall/features/account_data.dart';

import 'auth_test.dart' show AuthApi, FakeGateway, launch, location;
import 'widget_test.dart' show FakeApi, SignedIn;
import 'support/fixtures.dart';

/// An API whose account routes can be scripted.
class AccountFake extends FakeApi {
  final scheduled = <String>[];
  final appleCodes = <String?>[];
  final unavailableFlags = <bool>[];
  var cancelled = 0, exports = 0;
  final scheduleFailures = <ApiFailure>[];
  ApiFailure? exportFailure, cancelFailure;
  List<int> exportBytes = const [123, 125];

  @override
  Future<OnboardingStatus> onboarding(Session s) async =>
      const OnboardingStatus(true, '2026-10-01');

  @override
  Future<DeletionStatus> scheduleDeletion(
    Session s,
    String name, {
    String? appleAuthorizationCode,
    bool appleCodeUnavailable = false,
  }) async {
    if (scheduleFailures.isNotEmpty) throw scheduleFailures.removeAt(0);
    scheduled.add(name);
    appleCodes.add(appleAuthorizationCode);
    unavailableFlags.add(appleCodeUnavailable);
    return DeletionStatus(
      pending: true,
      scheduledAt: DateTime.utc(2026, 10, 13),
      dueAt: DateTime.utc(2026, 11, 12, 12),
      canCancel: true,
    );
  }

  @override
  Future<DeletionStatus> cancelDeletion(Session s) async {
    if (cancelFailure != null) throw cancelFailure!;
    cancelled++;
    return const DeletionStatus();
  }

  @override
  Future<List<int>> exportData(Session s) async {
    exports++;
    if (exportFailure != null) throw exportFailure!;
    return exportBytes;
  }
}

class FakeReauth extends Reauthenticator {
  AuthMethod? kind;
  AuthFailure? failure;
  final passwords = <String?>[];
  final withAppleCalls = <bool>[];
  String? appleCode;

  /// Apple is among the providers although [kind] says otherwise (Google first).
  bool alsoApple = false;

  /// Hands out [appleCode] on every Apple sign-in, like a platform that returns one.
  String? codeOnApple;
  FakeReauth(this.kind);
  @override
  bool get linksApple => alsoApple || kind == AuthMethod.apple;
  @override
  String? takeAppleAuthorizationCode() {
    final code = appleCode;
    appleCode = null;
    return code;
  }

  @override
  AuthMethod? get method => kind;
  @override
  Future<void> reauthenticate({
    String? password,
    bool withApple = false,
  }) async {
    passwords.add(password);
    withAppleCalls.add(withApple);
    if (failure != null) throw failure!;
    if (withApple && codeOnApple != null) appleCode = codeOnApple;
  }
}

class Delivered {
  final files = <String, List<int>>{};
  Delivery how = Delivery.shared;
  Future<Delivery> call(String name, List<int> bytes, {Rect? origin}) async {
    files[name] = bytes;
    return how;
  }
}

Future<ProviderContainer> openAccount(
  WidgetTester tester,
  AccountFake api, {
  AuthMethod? method,
  Delivered? delivery,
  FakeReauth? reauth,
  Size size = const Size(390, 900),
  double textScale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final container = ProviderContainer(
    overrides: [
      apiProvider.overrideWithValue(api),
      sessionProvider.overrideWith(SignedIn.new),
      reauthenticatorProvider.overrideWithValue(reauth ?? FakeReauth(method)),
      if (delivery != null)
        dataDeliveryProvider.overrideWithValue(delivery.call),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const HiyallApp()),
  );
  container.read(routerProvider).go('/profile/settings');
  await tester.pumpAndSettle();
  // The group sits below the fold.
  await tester.scrollUntilVisible(
    find.byKey(const Key('delete-account')),
    300,
    scrollable: find.byType(Scrollable).first,
  );
  // Out from under the header.
  await tester.drag(find.byType(Scrollable).first, const Offset(0, 200));
  await tester.pumpAndSettle();
  return container;
}

/// Taps a control that may sit below the fold of a scrolling page.
Future<void> press(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(Key(key)));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(Key(key)));
  await tester.pumpAndSettle();
}

void main() {
  group('helpers', () {
    test('Dates and waits read naturally', () {
      expect(deletionDate(DateTime(2026, 11, 2, 12)), '2 Nov 2026');
      expect(waitWords(const Duration(seconds: 20)), 'a minute');
      expect(waitWords(const Duration(minutes: 40)), '40 minutes');
      expect(waitWords(const Duration(hours: 5, minutes: 10)), '5 hours');
      expect(waitWords(const Duration(hours: 1, minutes: 20)), '80 minutes');
    });
    test('The export file is named for the UTC day', () {
      expect(
        exportFilename(DateTime.utc(2026, 3, 9, 23, 59)),
        'hiyall-data-2026-03-09.json',
      );
    });
    test('The status reads the server\'s fields', () {
      final s = DeletionStatus.fromJson({
        'pending': true,
        'scheduledAt': '2026-10-13T10:00:00Z',
        'dueAt': '2026-11-12T10:00:00Z',
        'canCancel': true,
      });
      expect(s.pending && s.canCancel, isTrue);
      expect(s.dueAt!.isUtc, isTrue);
      expect(DeletionStatus.fromJson({'pending': false}).dueAt, isNull);
    });
  });

  group('Settings, Your data', () {
    testWidgets('Download hands the export to the platform', (tester) async {
      final api = AccountFake();
      final delivery = Delivered();
      await openAccount(tester, api, delivery: delivery);
      expect(find.text('YOUR DATA'), findsOneWidget);
      await press(tester, 'download-data');
      expect(api.exports, 1);
      expect(
        delivery.files.keys.single,
        matches(r'^hiyall-data-\d{4}-\d{2}-\d{2}\.json$'),
      );
      expect(delivery.files.values.single, [123, 125]);
      expect(find.textContaining('Your data is ready'), findsOneWidget);
    });

    testWidgets('A browser download says so', (tester) async {
      final delivery = Delivered()..how = Delivery.downloaded;
      await openAccount(tester, AccountFake(), delivery: delivery);
      await press(tester, 'download-data');
      expect(find.text('Your data was downloaded.'), findsOneWidget);
    });

    testWidgets('The daily limit says when the next export is possible', (
      tester,
    ) async {
      final api = AccountFake()
        ..exportFailure = const ApiFailure(
          'You can download your data once a day. Try again later.',
          429,
          'RATE_LIMITED',
          Duration(hours: 5, minutes: 10),
        );
      final delivery = Delivered();
      await openAccount(tester, api, delivery: delivery);
      await press(tester, 'download-data');
      expect(find.textContaining('Try again in about 5 hours'), findsOneWidget);
      expect(delivery.files, isEmpty);
    });

    testWidgets(
      'Rows are at least 48 dp and fit a narrow screen at double text',
      (tester) async {
        await openAccount(
          tester,
          AccountFake(),
          size: const Size(320, 640),
          textScale: 2,
        );
        for (final key in ['download-data', 'delete-account']) {
          expect(
            tester.getSize(find.byKey(Key(key))).height,
            greaterThanOrEqualTo(48),
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('Delete account', () {
    Future<void> start(WidgetTester tester) async {
      await press(tester, 'delete-account');
    }

    testWidgets('Explains the 30 days and the chat messages first', (
      tester,
    ) async {
      final api = AccountFake();
      await openAccount(tester, api);
      await start(tester);
      expect(find.text('Delete your account?'), findsOneWidget);
      expect(find.textContaining('30 days'), findsWidgets);
      expect(find.textContaining('Keep my account'), findsWidgets);
      expect(find.textContaining('end-to-end encrypted'), findsOneWidget);
      // Nothing has been asked of the server yet, and leaving costs nothing.
      await press(tester, 'delete-keep');
      expect(find.text('Delete your account?'), findsNothing);
      expect(api.scheduled, isEmpty);
    });

    testWidgets('The username must be typed before the button works', (
      tester,
    ) async {
      final api = AccountFake();
      final container = await openAccount(tester, api);
      await container.read(profileProvider.future);
      await start(tester);
      await press(tester, 'delete-continue');
      FilledButton confirm() =>
          tester.widget<FilledButton>(find.byKey(const Key('delete-confirm')));
      expect(confirm().onPressed, isNull);
      await tester.enterText(find.byKey(const Key('delete-username')), 'niko');
      await tester.pump();
      expect(confirm().onPressed, isNull);
      await tester.enterText(
        find.byKey(const Key('delete-username')),
        ' @Anjali ',
      );
      await tester.pump();
      expect(confirm().onPressed, isNotNull);
      await press(tester, 'delete-confirm');
      expect(api.scheduled, ['anjali']);
      // Done: the date, and the app has signed out.
      expect(find.byKey(const Key('delete-done-date')), findsOneWidget);
      expect(find.textContaining('12 Nov 2026'), findsOneWidget);
      expect(container.read(sessionProvider).asData?.value, isNull);
      expect(location(container), '/account-deleted');
      await press(tester, 'delete-done');
      expect(location(container), '/welcome');
      expect(container.read(deletionScheduledProvider), isNull);
    });

    testWidgets(
      'A recent sign-in is asked for when the server wants one (password)',
      (tester) async {
        final api = AccountFake()
          ..scheduleFailures.add(
            const ApiFailure(
              'Confirm it\'s you by signing in again.',
              403,
              'REAUTH_REQUIRED',
            ),
          );
        final reauth = FakeReauth(AuthMethod.password);
        final container = await openAccount(tester, api, reauth: reauth);
        await container.read(profileProvider.future);
        await start(tester);
        await press(tester, 'delete-continue');
        await tester.enterText(
          find.byKey(const Key('delete-username')),
          'anjali',
        );
        await tester.pump();
        await press(tester, 'delete-confirm');
        expect(find.text('Confirm it’s you'), findsOneWidget);
        expect(api.scheduled, isEmpty);

        // A wrong password stays on the step with the reason.
        reauth.failure = const AuthFailure('That password doesn’t match.');
        await tester.enterText(
          find.byKey(const Key('delete-password')),
          'nope',
        );
        await press(tester, 'delete-reauth');
        expect(find.text('That password doesn’t match.'), findsOneWidget);
        expect(api.scheduled, isEmpty);

        // The right one confirms, then the deletion is retried by itself.
        reauth.failure = null;
        await tester.enterText(
          find.byKey(const Key('delete-password')),
          'right',
        );
        await press(tester, 'delete-reauth');
        expect(reauth.passwords, ['nope', 'right']);
        expect(api.scheduled, ['anjali']);
        expect(find.byKey(const Key('delete-done-date')), findsOneWidget);
      },
    );

    testWidgets(
      'A social account confirms with its provider, and cancelling is quiet',
      (tester) async {
        final api = AccountFake()
          ..scheduleFailures.add(
            const ApiFailure('again', 403, 'REAUTH_REQUIRED'),
          );
        final reauth = FakeReauth(AuthMethod.google)
          ..failure = const AuthFailure('', cancelled: true);
        final container = await openAccount(tester, api, reauth: reauth);
        await container.read(profileProvider.future);
        await start(tester);
        await press(tester, 'delete-continue');
        await tester.enterText(
          find.byKey(const Key('delete-username')),
          'anjali',
        );
        await tester.pump();
        await press(tester, 'delete-confirm');
        expect(find.text('Continue with Google'), findsOneWidget);
        // The sheet was closed: no message, nothing deleted.
        await press(tester, 'delete-reauth');
        expect(find.byKey(const Key('auth-error')), findsNothing);
        expect(api.scheduled, isEmpty);
        reauth.failure = null;
        await press(tester, 'delete-reauth');
        expect(api.scheduled, ['anjali']);
      },
    );

    testWidgets(
      'An Apple account signs in with Apple first and sends the one-time code',
      (tester) async {
        final api = AccountFake();
        final reauth = FakeReauth(AuthMethod.apple);
        final container = await openAccount(tester, api, reauth: reauth);
        await container.read(profileProvider.future);
        await start(tester);
        await press(tester, 'delete-continue');
        await tester.enterText(
          find.byKey(const Key('delete-username')),
          'anjali',
        );
        await tester.pump();
        // Even with a fresh sign-in the server has not been asked yet: Apple comes first.
        await press(tester, 'delete-confirm');
        expect(find.text('Continue with Apple'), findsOneWidget);
        expect(api.scheduled, isEmpty);
        reauth.appleCode = 'apple-code-1';
        await press(tester, 'delete-reauth');
        expect(api.scheduled, ['anjali']);
        expect(api.appleCodes, ['apple-code-1']);
      },
    );

    Future<void> toApplePrompt(
      WidgetTester tester,
      AccountFake api,
      FakeReauth reauth,
    ) async {
      final container = await openAccount(tester, api, reauth: reauth);
      await container.read(profileProvider.future);
      await start(tester);
      await press(tester, 'delete-continue');
      await tester.enterText(
        find.byKey(const Key('delete-username')),
        'anjali',
      );
      await tester.pump();
      await press(tester, 'delete-confirm');
      expect(find.text('Continue with Apple'), findsOneWidget);
    }

    testWidgets(
      'Apple returning no code shows an explanation with two ways out, then stops asking after two tries',
      (tester) async {
        final reported = <String>[];
        ErrorReporting.onCapture = (error, fatal) => reported.add('$error');
        addTearDown(() => ErrorReporting.onCapture = null);
        final api = AccountFake();
        final reauth = FakeReauth(AuthMethod.apple);
        await toApplePrompt(tester, api, reauth);

        // First miss: explained, with a retry and support. Not another prompt.
        await press(tester, 'delete-reauth');
        expect(find.byKey(const Key('delete-apple-explain')), findsOneWidget);
        expect(find.text('Try Apple again'), findsOneWidget);
        expect(find.text('Contact support'), findsOneWidget);
        expect(find.text('Continue with Apple'), findsNothing);
        expect(reauth.passwords, hasLength(1));
        expect(api.scheduled, isEmpty);

        // Second miss: only support is left.
        await press(tester, 'delete-apple-retry');
        expect(reauth.passwords, hasLength(2));
        expect(find.byKey(const Key('delete-apple-explain')), findsOneWidget);
        expect(find.text('Try Apple again'), findsNothing);
        expect(find.text('Contact support'), findsOneWidget);

        // Back and Delete again goes straight to the explanation: no third Apple sheet.
        await tester.tap(find.text('Back'));
        await tester.pumpAndSettle();
        await press(tester, 'delete-confirm');
        expect(find.byKey(const Key('delete-apple-explain')), findsOneWidget);
        expect(reauth.passwords, hasLength(2));
        expect(api.scheduled, isEmpty);

        // Logged twice, with no personal data in it.
        expect(reported, hasLength(2));
        for (final line in reported) {
          expect(line, contains('no authorization code'));
          expect(line, isNot(contains('anjali')));
        }
      },
    );

    testWidgets(
      'An Apple retry that does return a code finishes the deletion',
      (tester) async {
        final api = AccountFake();
        final reauth = FakeReauth(AuthMethod.apple);
        await toApplePrompt(tester, api, reauth);
        await press(tester, 'delete-reauth');
        expect(find.byKey(const Key('delete-apple-explain')), findsOneWidget);
        reauth.appleCode = 'apple-code-2';
        await press(tester, 'delete-apple-retry');
        expect(api.scheduled, ['anjali']);
        expect(api.appleCodes, ['apple-code-2']);
      },
    );

    testWidgets('APPLE_CODE_REQUIRED from the server opens the same screen', (
      tester,
    ) async {
      final api = AccountFake()
        ..scheduleFailures.add(
          const ApiFailure(
            'Check your entries and try again.',
            422,
            'APPLE_CODE_REQUIRED',
          ),
        );
      final reauth = FakeReauth(AuthMethod.apple);
      await toApplePrompt(tester, api, reauth);
      reauth.appleCode = 'stale-code';
      await press(tester, 'delete-reauth');
      expect(find.byKey(const Key('delete-apple-explain')), findsOneWidget);
      expect(find.text('Try Apple again'), findsOneWidget);
      expect(find.text('Contact support'), findsOneWidget);
      expect(api.scheduled, isEmpty);
    });

    Future<ProviderContainer> toDelete(
      WidgetTester tester,
      AccountFake api,
      FakeReauth reauth,
    ) async {
      final container = await openAccount(tester, api, reauth: reauth);
      await container.read(profileProvider.future);
      await start(tester);
      await press(tester, 'delete-continue');
      await tester.enterText(
        find.byKey(const Key('delete-username')),
        'anjali',
      );
      await tester.pump();
      await press(tester, 'delete-confirm');
      return container;
    }

    testWidgets(
      'A Google account that also lists Apple signs in with Apple, not Google (multi-provider)',
      (tester) async {
        final api = AccountFake();
        final reauth = FakeReauth(AuthMethod.google)
          ..alsoApple = true
          ..codeOnApple = 'apple-code-g';
        await toDelete(tester, api, reauth);
        expect(find.text('Continue with Apple'), findsOneWidget);
        expect(find.text('Continue with Google'), findsNothing);
        expect(api.scheduled, isEmpty, reason: 'Apple comes before the server');
        await press(tester, 'delete-reauth');
        expect(reauth.withAppleCalls, [true]);
        expect(api.appleCodes, ['apple-code-g']);
        expect(api.unavailableFlags, [false]);
      },
    );

    testWidgets(
      'A password account that lists Apple is asked for Apple, with no password field',
      (tester) async {
        final api = AccountFake();
        final reauth = FakeReauth(AuthMethod.password)
          ..alsoApple = true
          ..codeOnApple = 'c';
        await toDelete(tester, api, reauth);
        expect(find.byKey(const Key('delete-password')), findsNothing);
        await press(tester, 'delete-reauth');
        expect(reauth.withAppleCalls, [true]);
        expect(api.appleCodes, ['c']);
      },
    );

    testWidgets(
      'APPLE_CODE_REQUIRED for a Google-only account makes the retry an Apple sign-in',
      (tester) async {
        final api = AccountFake()
          ..scheduleFailures.add(
            const ApiFailure('Check', 422, 'APPLE_CODE_REQUIRED'),
          );
        final reauth = FakeReauth(AuthMethod.google)..codeOnApple = 'late-code';
        await toDelete(tester, api, reauth);
        // The server was asked first (Google accounts list no Apple) and refused.
        expect(find.byKey(const Key('delete-apple-explain')), findsOneWidget);
        expect(reauth.withAppleCalls, isEmpty);
        await press(tester, 'delete-apple-retry');
        expect(reauth.withAppleCalls, [true]);
        expect(api.appleCodes, ['late-code']);
        expect(api.unavailableFlags, [false]);
      },
    );

    testWidgets(
      'Two empty Apple answers (a web popup returns no code) end in an honest, optional way out that sends appleCodeUnavailable',
      (tester) async {
        final api = AccountFake();
        final reauth = FakeReauth(AuthMethod.apple);
        await toDelete(tester, api, reauth);
        await press(tester, 'delete-reauth');
        // First miss: no way to skip yet.
        expect(find.byKey(const Key('delete-apple-continue')), findsNothing);
        await press(tester, 'delete-apple-retry');
        expect(reauth.withAppleCalls, [true, true]);
        // Second miss: the explanation says what will happen, and the member chooses.
        expect(find.byKey(const Key('delete-apple-explain')), findsOneWidget);
        expect(find.textContaining('by hand'), findsOneWidget);
        expect(find.text('Try Apple again'), findsNothing);
        expect(api.scheduled, isEmpty, reason: 'nothing is sent on its own');
        await press(tester, 'delete-apple-continue');
        expect(api.scheduled, ['anjali']);
        expect(api.appleCodes, [null]);
        expect(api.unavailableFlags, [true]);
      },
    );

    testWidgets('The miss count survives leaving the screen and coming back', (
      tester,
    ) async {
      final api = AccountFake();
      final reauth = FakeReauth(AuthMethod.apple);
      final container = await toDelete(tester, api, reauth);
      await press(tester, 'delete-reauth');
      await press(tester, 'delete-apple-retry');
      expect(reauth.withAppleCalls, hasLength(2));
      expect(
        container.read(appleDeletionMissesProvider)[anjaliId],
        2,
        reason: 'kept per user',
      );
      await press(tester, 'delete-close');
      await start(tester);
      await press(tester, 'delete-continue');
      await tester.enterText(
        find.byKey(const Key('delete-username')),
        'anjali',
      );
      await tester.pump();
      await press(tester, 'delete-confirm');
      // No third Apple sheet: straight to the way out.
      expect(reauth.withAppleCalls, hasLength(2));
      expect(find.byKey(const Key('delete-apple-continue')), findsOneWidget);
    });

    testWidgets(
      'A server that still says APPLE_CODE_REQUIRED after the choice shows its message and does not loop',
      (tester) async {
        final api = AccountFake();
        final reauth = FakeReauth(AuthMethod.apple);
        await toDelete(tester, api, reauth);
        await press(tester, 'delete-reauth');
        await press(tester, 'delete-apple-retry');
        api.scheduleFailures.add(
          const ApiFailure('Apple needs a code.', 422, 'APPLE_CODE_REQUIRED'),
        );
        await press(tester, 'delete-apple-continue');
        expect(api.scheduled, isEmpty);
        expect(find.text('Apple needs a code.'), findsOneWidget);
        expect(reauth.withAppleCalls, hasLength(2));
      },
    );

    testWidgets(
      'Contact support opens a mail draft to the Help & Safety address',
      (tester) async {
        HelpContacts.showPlaceholders = true;
        addTearDown(() => HelpContacts.showPlaceholders = false);
        Uri? opened;
        mailLauncher = (uri) async {
          opened = uri;
          return true;
        };
        addTearDown(() => mailLauncher = (uri) => launchUrl(uri));
        final api = AccountFake();
        final reauth = FakeReauth(AuthMethod.apple);
        await toApplePrompt(tester, api, reauth);
        await press(tester, 'delete-reauth');
        await press(tester, 'delete-apple-support');
        expect(opened?.scheme, 'mailto');
        expect(opened?.path, HelpContacts.support);
      },
    );

    testWidgets(
      'Contact support without a real address says it is being set up',
      (tester) async {
        final api = AccountFake();
        final reauth = FakeReauth(AuthMethod.apple);
        await toApplePrompt(tester, api, reauth);
        await press(tester, 'delete-reauth');
        await press(tester, 'delete-apple-support');
        expect(
          find.textContaining('Contact details are being set up'),
          findsOneWidget,
        );
      },
    );

    testWidgets('A refusal is shown and nothing is signed out', (tester) async {
      final api = AccountFake()
        ..scheduleFailures.add(
          const ApiFailure('that is not your username', 422, 'VALIDATION'),
        );
      final container = await openAccount(tester, api);
      await container.read(profileProvider.future);
      await start(tester);
      await press(tester, 'delete-continue');
      await tester.enterText(
        find.byKey(const Key('delete-username')),
        'anjali',
      );
      await tester.pump();
      await press(tester, 'delete-confirm');
      expect(find.text('that is not your username'), findsOneWidget);
      expect(container.read(sessionProvider).asData?.value, isNotNull);
    });

    testWidgets('The steps fit 320 wide at double text with reduced motion', (
      tester,
    ) async {
      final api = AccountFake();
      final container = await openAccount(
        tester,
        api,
        size: const Size(320, 640),
        textScale: 2,
      );
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await container.read(profileProvider.future);
      await start(tester);
      expect(tester.takeException(), isNull);
      await press(tester, 'delete-continue');
      expect(tester.takeException(), isNull);
      for (final key in ['delete-confirm', 'delete-username']) {
        expect(
          tester.getSize(find.byKey(Key(key))).height,
          greaterThanOrEqualTo(48),
        );
      }
    });
  });

  group('A member whose account is scheduled for deletion', () {
    PendingAccount pending({bool open = true}) => PendingAccount(
      const Session('tok', ''),
      DeletionStatus(
        pending: true,
        scheduledAt: DateTime.utc(2026, 10, 13),
        dueAt: open
            ? DateTime.utc(2026, 11, 12, 12)
            : DateTime.utc(2026, 10, 13),
        canCancel: open,
      ),
    );

    Future<ProviderContainer> land(
      WidgetTester tester,
      AccountFake api,
      PendingAccount account,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 800);
      addTearDown(tester.view.reset);
      final container = ProviderContainer(
        overrides: [
          apiProvider.overrideWithValue(api),
          sessionProvider.overrideWith(_SignedOut.new),
          pendingAccountProvider.overrideWith(() => _Pending(account)),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const HiyallApp(),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('lands on the date and Keep my account, then goes home', (
      tester,
    ) async {
      final api = AccountFake();
      final container = await land(tester, api, pending());
      expect(location(container), '/account-deletion');
      expect(
        find.text('Your account is scheduled for deletion'),
        findsOneWidget,
      );
      expect(find.textContaining('12 Nov 2026'), findsOneWidget);
      await tester.tap(find.byKey(const Key('keep-account')));
      await tester.pump(const Duration(seconds: 1));
      expect(api.cancelled, 1);
      expect(container.read(pendingAccountProvider), isNull);
      expect(container.read(sessionProvider).asData?.value?.userId, anjaliId);
      expect(location(container), '/home');
    });

    testWidgets('cannot be sent anywhere else, and signing out leaves', (
      tester,
    ) async {
      final api = AccountFake();
      final container = await land(tester, api, pending());
      container.read(routerProvider).go('/home');
      await tester.pumpAndSettle();
      expect(location(container), '/account-deletion');
      container.read(routerProvider).go('/profile/settings');
      await tester.pumpAndSettle();
      expect(location(container), '/account-deletion');
      await tester.tap(find.byKey(const Key('pending-sign-out')));
      await tester.pumpAndSettle();
      expect(container.read(pendingAccountProvider), isNull);
      expect(location(container), '/welcome');
    });

    testWidgets('after the 30 days there is nothing to keep', (tester) async {
      final api = AccountFake();
      await land(tester, api, pending(open: false));
      expect(find.byKey(const Key('keep-account')), findsNothing);
      expect(find.textContaining('can no longer be undone'), findsOneWidget);
    });

    testWidgets('a refused cancel is explained', (tester) async {
      final api = AccountFake()
        ..cancelFailure = const ApiFailure(
          'The 30 days to keep this account have passed.',
          409,
          'DELETION_WINDOW_CLOSED',
        );
      final container = await land(tester, api, pending());
      await tester.tap(find.byKey(const Key('keep-account')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('30 days to keep this account'),
        findsOneWidget,
      );
      expect(container.read(pendingAccountProvider), isNotNull);
    });

    testWidgets('fits 320 wide at double text', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 640);
      addTearDown(tester.view.reset);
      final container = ProviderContainer(
        overrides: [
          apiProvider.overrideWithValue(AccountFake()),
          sessionProvider.overrideWith(_SignedOut.new),
          pendingAccountProvider.overrideWith(() => _Pending(pending())),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const HiyallApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byKey(const Key('keep-account'))).height,
        greaterThanOrEqualTo(48),
      );
    });
  });

  group('Signing in', () {
    testWidgets('an account scheduled for deletion is sent to its own screen', (
      tester,
    ) async {
      final api = _PendingAuthApi()..pending = true;
      final gateway = FakeGateway(
        const AuthUser(
          uid: 'u',
          method: AuthMethod.google,
          emailVerified: true,
        ),
      );
      final container = await launch(tester, api: api, gateway: gateway);
      expect(location(container), '/account-deletion');
      expect(container.read(sessionProvider).asData?.value, isNull);
      expect(container.read(pendingAccountProvider)?.status.pending, isTrue);
    });

    testWidgets('an ordinary account is not held back', (tester) async {
      final api = _PendingAuthApi()..onboarded = true;
      final gateway = FakeGateway(
        const AuthUser(
          uid: 'u',
          method: AuthMethod.google,
          emailVerified: true,
        ),
      );
      final container = await launch(tester, api: api, gateway: gateway);
      expect(container.read(pendingAccountProvider), isNull);
      expect(container.read(sessionProvider).asData?.value, isNotNull);
    });
  });
}

class _SignedOut extends SessionController {
  @override
  AsyncValue<Session?> build() => const AsyncData(null);
}

class _Pending extends PendingAccountController {
  final PendingAccount account;
  _Pending(this.account);
  @override
  PendingAccount? build() => account;
}

class _PendingAuthApi extends AuthApi {
  bool pending = false;
  // The server refuses everything but the deletion routes to a pending member.
  @override
  Future<Profile> profile(Session s) async => pending
      ? throw const ApiFailure(
          'Your session has expired.',
          401,
          'UNAUTHENTICATED',
        )
      : super.profile(s);

  @override
  Future<DeletionStatus> deletionStatus(Session s) async => DeletionStatus(
    pending: pending,
    dueAt: DateTime.utc(2026, 11, 12, 12),
    canCancel: pending,
  );
}
