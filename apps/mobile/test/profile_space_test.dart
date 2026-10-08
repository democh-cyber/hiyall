import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kairova/app.dart';
import 'package:kairova/core/api.dart';
import 'package:kairova/core/state.dart';
import 'package:kairova/features/profile_editor.dart';
import 'package:kairova/shared/profile_space.dart';

import 'widget_test.dart' show FakeApi, SignedIn;

const expressive = Profile(
  userId: anjaliId,
  username: 'anjali',
  displayName: 'Anjali',
  bio: 'coffee > meetings ☕',
  quote: 'A little curiosity goes a long way.',
  socialStats: ProfileSocialStats(friends: 0, following: 0, followers: 0),
  profession: 'Finance Operations',
  version: '5',
  headline: 'Finance girlie ✨',
  country: 'IN',
  pronouns: 'she / her',
  interests: ['Finance', 'Technology', 'Travel', 'Photography', 'Music'],
  languages: [
    ProfileLanguage('en', 'fluent'),
    ProfileLanguage('hi', 'native'),
    ProfileLanguage('ko', 'basic'),
  ],
  currentVibe: '☕ Coffee + work',
  profileAccent: 'lime',
  profilePattern: 'orbit',
);

class ProfileApi extends FakeApi {
  Profile current = expressive;
  bool profileConflict = false;
  @override
  Future<Profile> profile(Session s) async => current;
  @override
  Future<Profile> updateProfile(
    Session s,
    Profile p,
    Map<String, dynamic> patch,
  ) async {
    if (profileConflict) {
      throw const ApiFailure('Changed on another device.', 412);
    }
    if (failSave) {
      throw const ApiFailure('Offline');
    }
    saved = Map.of(patch);
    current = Profile.fromJson({'userId': p.userId, 'version': '6', ...patch});
    return current;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    for (final family in ['SpaceGrotesk', 'Manrope']) {
      await (FontLoader(
        family,
      )..addFont(rootBundle.load('assets/fonts/$family.ttf'))).load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  test('Profile normalization keeps legacy language level unspecified and drops account data', () {
    final p = Profile.fromJson({
      'userId': 'routing-id',
      'username': 'test',
      'displayName': 'Test',
      'languages': [
        'ko',
        {'code': 'en', 'level': 'fluent'},
      ],
      'email': 'secret',
      'coin': 900,
      'birthYear': 2004,
    });
    expect(p.languages.first.code, 'ko');
    expect(p.languages.first.level, '');
    expect(p.languages.last.level, 'fluent');
    expect(p.interests, isEmpty);
    expect(p.currentVibe, isEmpty);
    expect(p.socialStats, isNull);
    expect(p.quote, isEmpty);
  });

  testWidgets(
    'Owner and visitor profiles fit themes, phones, foldables and large text',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final capture = GlobalKey();
      for (final width in [320.0, 390.0, 430.0, 700.0, 1440.0]) {
        tester.view.physicalSize = Size(width, 900);
        for (final scale in [1.0, 2.0]) {
          for (final dark in [true, false]) {
            for (final owner in [true, false]) {
              await tester.pumpWidget(const SizedBox.shrink());
              await tester.pumpWidget(
                MaterialApp(
                  theme: ThemeData(
                    brightness: dark ? Brightness.dark : Brightness.light,
                    fontFamily: 'Manrope',
                  ),
                  home: MediaQuery(
                    data: MediaQueryData(
                      textScaler: TextScaler.linear(scale),
                      padding: const EdgeInsets.only(bottom: 34),
                    ),
                    child: RepaintBoundary(
                      key: capture,
                      child: Scaffold(
                        body: ProfileSpace(
                          profile: expressive,
                          isOwner: owner,
                          onEdit: () {},
                        ),
                      ),
                    ),
                  ),
                ),
              );
              await tester.pumpAndSettle();
              expect(
                tester.takeException(),
                isNull,
                reason: '$width / $scale / $dark / $owner',
              );
              expect(find.text('Finance girlie ✨'), findsOneWidget);
              expect(find.text('MY SPACE'), findsNothing);
              expect(
                find.text('“A little curiosity goes a long way.”'),
                findsOneWidget,
              );
              expect(
                find.byKey(const ValueKey('profile-social-stats')),
                findsOneWidget,
              );
              expect(
                find.text('Edit profile'),
                owner ? findsOneWidget : findsNothing,
              );
              if (owner &&
                  width == 390 &&
                  scale == 1 &&
                  const bool.fromEnvironment('CAPTURE_PROFILE')) {
                void repaint(RenderObject render) {
                  render.markNeedsPaint();
                  render.visitChildren(repaint);
                }

                repaint(capture.currentContext!.findRenderObject()!);
                await tester.pump();
                await tester.runAsync(() async {
                  final boundary =
                      capture.currentContext!.findRenderObject()!
                          as RenderRepaintBoundary;
                  final img = await boundary.toImage(pixelRatio: 1);
                  final data = await img.toByteData(
                    format: ui.ImageByteFormat.png,
                  );
                  final file = File(
                    '../../.runtime/profile-previews/identity-${dark ? 'dark' : 'light'}.png',
                  );
                  await file.parent.create(recursive: true);
                  await file.writeAsBytes(data!.buffer.asUint8List());
                  img.dispose();
                });
              }
              for (var i = 0; i < 4; i++) {
                await tester.drag(
                  find.byType(CustomScrollView),
                  const Offset(0, -350),
                );
                await tester.pumpAndSettle();
                expect(tester.takeException(), isNull);
              }
              expect(
                find.byKey(const ValueKey('collapsed-profile-identity')),
                findsOneWidget,
              );
              final vibes = find.text('Vibes');
              await tester.ensureVisible(vibes);
              await tester.tap(vibes);
              await tester.pumpAndSettle();
              expect(
                find.byKey(const ValueKey('saved-vibe-content')),
                findsOneWidget,
              );
              expect(tester.takeException(), isNull);
            }
          }
        }
      }
    },
  );

  testWidgets('Visitor sees no owner tools or invented private details', (
    tester,
  ) async {
    const hidden = Profile(
      userId: 'id',
      username: 'private',
      displayName: 'Private',
      bio: '',
      profession: '',
      version: '',
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: ProfileSpace(profile: hidden)),
      ),
    );
    await tester.pumpAndSettle();
    for (final text in [
      'Edit profile',
      'MY INTERESTS',
      'CURRENT VIBE',
      'ABOUT ME',
      'LANGUAGES',
      'Your space, your rules.',
      'Taking it as it comes',
    ]) {
      expect(find.text(text), findsNothing);
    }
    expect(find.byType(SwitchListTile), findsNothing);
  });

  Future<void> launchEditor(WidgetTester tester, ProfileApi api) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiProvider.overrideWithValue(api),
          sessionProvider.overrideWith(SignedIn.new),
        ],
        child: const KairovaApp(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Me'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit profile'));
    await tester.pumpAndSettle();
  }

  testWidgets('Profile edits persist structured data only after Save', (
    tester,
  ) async {
    final api = ProfileApi();
    await launchEditor(tester, api);
    await tester.scrollUntilVisible(
      find.widgetWithText(TextFormField, 'Headline'),
      350,
      scrollable: find
          .descendant(
            of: find.byType(ProfileForm),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Headline'),
      'A new little chapter',
    );
    expect(api.saved, isNull);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    final quoteField = find.widgetWithText(
      TextFormField,
      'A little quote (optional)',
    );
    await tester.scrollUntilVisible(
      quoteField,
      200,
      scrollable: find
          .descendant(
            of: find.byType(ProfileForm),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.enterText(quoteField, 'Small moments. Big world.');
    expect(api.saved, isNull);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Save profile'),
      500,
      scrollable: find
          .descendant(
            of: find.byType(ProfileForm),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save profile'));
    await tester.pumpAndSettle();
    expect(api.saved!['headline'], 'A new little chapter');
    expect(api.saved!['quote'], 'Small moments. Big world.');
    expect(find.text('“Small moments. Big world.”'), findsOneWidget);
    expect(api.saved!['bio'], expressive.bio);
    expect(api.saved!.keys, isNot(contains('socialStats')));
    expect(api.saved!['languages'], [
      {'code': 'en', 'level': 'fluent'},
      {'code': 'hi', 'level': 'native'},
      {'code': 'ko', 'level': 'basic'},
    ]);
    expect(api.saved!['interests'], expressive.interests);
    expect(api.saved!['profileAccent'], 'lime');
    expect(api.saved!['profilePattern'], 'orbit');
    expect(api.saved!.keys, isNot(contains('email')));
    expect(find.text('A new little chapter'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Failed or conflicting save keeps the draft and offers recovery',
    (tester) async {
      final api = ProfileApi()..profileConflict = true;
      await launchEditor(tester, api);
      await tester.scrollUntilVisible(
        find.text('Save profile'),
        500,
        scrollable: find
            .descendant(
              of: find.byType(ProfileForm),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save profile'));
      await tester.pumpAndSettle();
      expect(api.saved, isNull);
      expect(find.text('Profile saved.'), findsNothing);
      expect(find.text('Reload latest profile'), findsOneWidget);
      expect(find.byType(ProfileForm), findsOneWidget);
    },
  );
  testWidgets(
    'Settings stay reachable while scrolling and lead to privacy',
    (tester) async {
      final api = ProfileApi();
      await launchEditor(tester, api);
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ProfileForm)),
      );
      container.read(routerProvider).go('/profile');
      await tester.pumpAndSettle();
      expect(find.text('Sign out'), findsNothing);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -550));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('collapsed-profile-identity')),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Your space settings'));
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsWidgets);
      await tester.tap(find.byKey(const Key('settings-/profile/privacy')));
      await tester.pumpAndSettle();
      expect(find.text('Who can view my profile?'), findsOneWidget);
      // Privacy leads back to Settings, not straight to the profile.
      await tester.tap(find.widgetWithText(TextButton, 'Settings'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('sign-out')),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.byKey(const Key('sign-out')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Share copies the profile handle and preserves privacy', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
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
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProfileSpace(profile: expressive, isOwner: true, onEdit: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Share'));
    await tester.pumpAndSettle();
    expect(
      find.text('Your privacy settings still decide who can see your profile.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Copy username'));
    await tester.pumpAndSettle();
    expect(copied, '@anjali');
    expect(find.text('Username copied.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
