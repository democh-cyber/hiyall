import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/local_time.dart';
import 'package:hiyall/shared/profile_space.dart';
import 'package:hiyall/shared/profile_space/profile_gallery.dart';

import 'avatar_helpers.dart';

Profile profile({
  List<String> tags = const [],
  String aboutMe = '',
  String hometown = '',
  LocalTimeInfo? localTime,
  Birthday? birthday,
  List<GalleryPhoto> photos = const [],
  bool visitorsVisible = false,
  List<ProfileLanguage> languages = const [],
  List<String> interests = const [],
}) => Profile(
  userId: 'u1',
  username: 'mira',
  displayName: 'Mira',
  bio: 'Hello',
  profession: '',
  version: '1',
  personalityTags: tags,
  aboutMe: aboutMe,
  hometown: hometown,
  localTime: localTime,
  birthday: birthday,
  photos: photos,
  visitorsVisible: visitorsVisible,
  languages: languages,
  interests: interests,
);

Widget host(
  Profile p, {
  bool owner = false,
  TextDirection dir = TextDirection.ltr,
  double scale = 1,
  ThemeMode mode = ThemeMode.light,
}) => ProviderScope(
  overrides: [
    localTimeClockProvider.overrideWithValue(
      () => DateTime.utc(2026, 10, 18, 10, 12),
    ),
  ],
  child: MaterialApp(
    themeMode: mode,
    theme: ThemeData(brightness: Brightness.light),
    darkTheme: ThemeData(brightness: Brightness.dark),
    builder: (context, app) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(scale)),
      child: Directionality(textDirection: dir, child: app!),
    ),
    home: Scaffold(
      body: ProfileSpace(profile: p, isOwner: owner, onEdit: () {}),
    ),
  ),
);

List<GalleryPhoto> photos(int n) => [
  for (var i = 1; i <= n; i++)
    GalleryPhoto(
      'm$i',
      'https://cdn.test/m$i/f.jpg',
      'https://cdn.test/m$i/t.jpg',
      800,
      600,
    ),
];

void main() {
  setUp(() => AvatarRequests(() => const BrokenImage()));
  tearDown(AvatarRequests.restore);

  Future<void> scrollTo(WidgetTester tester, Finder f) => tester
      .scrollUntilVisible(f, 300, scrollable: find.byType(Scrollable).first);

  testWidgets('everything the server sent is shown, in words', (tester) async {
    tester.view.physicalSize = const Size(390, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      host(
        profile(
          tags: ['curious', 'maker', 'foodie'],
          aboutMe: 'Slow mornings and loud music',
          hometown: 'Lisbon',
          localTime: const LocalTimeInfo(330, 'UTC+5:30'),
          birthday: const Birthday(5, 17),
          photos: photos(3),
          languages: const [ProfileLanguage('en', 4), ProfileLanguage('ko', 2)],
          interests: ['Music', 'Art'],
        ),
      ),
    );
    expect(find.byKey(const Key('profile-about-me')), findsOneWidget);
    expect(find.text('Slow mornings and loud music'), findsOneWidget);
    expect(find.textContaining('Lisbon'), findsOneWidget);
    expect(find.textContaining('It’s 3:42 PM there'), findsOneWidget);
    expect(find.text('Birthday · '), findsNothing);
    expect(find.textContaining('May 17'), findsOneWidget);
    expect(find.text('Curious'), findsOneWidget);
    expect(find.text('Fluent'), findsOneWidget);
    expect(find.text('Beginner'), findsOneWidget);
    expect(find.byKey(const Key('profile-gallery')), findsOneWidget);
    // The year of birth appears nowhere.
    expect(find.textContaining('19'), findsNothing);
    expect(find.textContaining('null'), findsNothing);
  });

  testWidgets('nothing the server did not send is drawn', (tester) async {
    await tester.pumpWidget(host(profile()));
    for (final key in [
      'profile-about-me',
      'profile-hometown',
      'profile-local-time',
      'profile-birthday',
      'profile-gallery',
      'recent-visitors-entry',
    ]) {
      expect(find.byKey(Key(key)), findsNothing, reason: key);
    }
    expect(find.text('PERSONALITY'), findsNothing);
  });

  testWidgets(
    'the recent visitors entry is for others, and says visiting adds you',
    (tester) async {
      tester.view.physicalSize = const Size(390, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(host(profile(visitorsVisible: true)));
      expect(find.byKey(const Key('recent-visitors-entry')), findsOneWidget);
      expect(find.textContaining('show up here for 30 days'), findsOneWidget);
      await tester.pumpWidget(
        host(profile(visitorsVisible: true), owner: true),
      );
      expect(find.byKey(const Key('recent-visitors-entry')), findsNothing);
    },
  );

  testWidgets(
    'interest, personality and language chips are drill-downs on a profile',
    (tester) async {
      tester.view.physicalSize = const Size(390, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        host(
          profile(
            tags: ['curious', 'maker', 'foodie'],
            languages: const [ProfileLanguage('en', 4)],
            interests: ['Music'],
          ),
        ),
      );
      expect(find.byKey(const Key('interest-Music')), findsOneWidget);
      expect(find.byKey(const Key('profile-language-en')), findsOneWidget);
      expect(find.text('Curious'), findsOneWidget);
    },
  );

  group('the photo viewer from a profile', () {
    testWidgets(
      'a tap opens it, it says "Photo 2 of 3", closes with the button',
      (tester) async {
        tester.view.physicalSize = const Size(390, 2400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final handle = tester.ensureSemantics();
        await tester.pumpWidget(host(profile(photos: photos(3))));
        await tester.tap(find.byKey(const Key('gallery-photo-1')));
        await tester.pumpAndSettle();
        expect(find.byType(PhotoViewer), findsOneWidget);
        expect(find.bySemanticsLabel('Photo 2 of 3'), findsWidgets);
        await tester.tap(find.byKey(const Key('photo-viewer-close')));
        await tester.pumpAndSettle();
        expect(find.byType(PhotoViewer), findsNothing);
        handle.dispose();
      },
    );
  });

  for (final dir in [TextDirection.ltr, TextDirection.rtl]) {
    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      testWidgets('320 px at text scale 2.0 with everything on ($dir, $mode)', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(320, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          host(
            profile(
              tags: ['curious', 'maker', 'deep_thinker'],
              aboutMe: 'Slow mornings and loud music, long walks',
              hometown: 'São Paulo',
              localTime: const LocalTimeInfo(-180, 'UTC-3'),
              birthday: const Birthday(12, 31),
              photos: photos(8),
              visitorsVisible: true,
              languages: const [
                ProfileLanguage('pt', 6),
                ProfileLanguage('en', 3),
              ],
              interests: ['Music', 'Art', 'Travel'],
            ),
            dir: dir,
            scale: 2,
            mode: mode,
          ),
        );
        await scrollTo(tester, find.byKey(const Key('profile-gallery')));
        expect(tester.takeException(), isNull);
      });
    }
  }
}
