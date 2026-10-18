import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/features/visitor_profile.dart';
import 'package:hiyall/shared/presence_dot.dart';

const mine = Profile(
  userId: 'me',
  username: 'me',
  displayName: 'Me',
  bio: '',
  profession: '',
  version: '1',
  interests: ['Music', 'Art', 'Travel', 'Gaming'],
);

Profile other({
  List<String> interests = const ['K-pop', 'Gaming', 'Music', 'Study'],
  int? age = 19,
  String gender = 'woman',
  String? country = 'IN',
  String region = 'Bihar',
  bool? online,
  String vibe = 'Chill',
  List<ProfileLanguage> languages = const [
    ProfileLanguage('en', 4),
    ProfileLanguage('hi', 6),
  ],
  String headline = 'i am cute girl',
  String bio = '',
  ProfileSocialStats? stats = const ProfileSocialStats(
    following: 31,
    followers: 2,
    visitors: 50,
    stories: 1,
  ),
}) => Profile(
  userId: 'u1',
  username: 'eshika',
  displayName: 'Eshika',
  bio: bio,
  profession: '',
  version: '1',
  headline: headline,
  interests: interests,
  languages: languages,
  currentVibe: vibe,
  country: country,
  region: region,
  gender: gender,
  age: age,
  online: online,
  socialStats: stats,
);

Future<void> show(
  WidgetTester tester,
  Profile profile, {
  VoidCallback? onBack,
  VoidCallback? onOptions,
  Widget? Function(int)? contentFor,
  Size size = const Size(390, 844),
  double textScale = 1,
  Profile? own = mine,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (own != null) profileProvider.overrideWith((ref) async => own),
      ],
      child: MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(textScale),
          ),
          child: Scaffold(
            body: VisitorProfile(
              profile: profile,
              actions: const SizedBox(
                key: Key('stub-actions'),
                height: 48,
                child: Center(child: Text('actions')),
              ),
              onBack: onBack ?? () {},
              onOptions: onOptions,
              contentFor: contentFor ?? (_) => null,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('The header shows who they are at a glance', (tester) async {
    await show(tester, other(online: true));
    expect(find.text('Eshika'), findsOneWidget);
    expect(find.text('@eshika'), findsOneWidget);
    expect(find.byKey(const Key('visitor-country')), findsOneWidget);
    expect(find.text('IN'), findsWidgets);
    expect(find.byKey(const Key('visitor-place-header')), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const Key('visitor-place-header'))).data,
      'India · Bihar',
    );
    // Gender is a quiet mark beside the name, labelled for screen readers.
    expect(find.byIcon(Icons.female_rounded), findsOneWidget);
    expect(find.text('EN'), findsOneWidget);
    expect(find.text('HI'), findsOneWidget);
    expect(find.byKey(const Key('online-dot-u1')), findsOneWidget);
    expect(find.byType(PresenceDot), findsOneWidget);
    expect(find.text('i am cute girl'), findsOneWidget);
    expect(find.byKey(const Key('stub-actions')), findsOneWidget);
  });

  testWidgets('No online dot unless they chose to show it', (tester) async {
    await show(tester, other());
    expect(find.byKey(const Key('online-dot-u1')), findsNothing);
  });

  testWidgets('Following, followers, visitors and stories are shown', (
    tester,
  ) async {
    await show(tester, other());
    for (final label in ['Following', 'Followers', 'Visitors', 'Stories']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(find.text('31'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('50'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    // Friends are no longer a headline number.
    expect(find.text('Friends'), findsNothing);
  });

  testWidgets(
    'The detailed profile shows age and location, never a birth date',
    (tester) async {
      await show(tester, other());
      expect(find.text('Detailed profile'), findsOneWidget);
      expect(find.text('Age'), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('visitor-age'))).data,
        '19',
      );
      expect(find.text('Current location'), findsOneWidget);
      expect(find.textContaining('Date of birth'), findsNothing);
      expect(find.textContaining('Birth'), findsNothing);
    },
  );

  testWidgets('Age is left out when the server did not send it', (
    tester,
  ) async {
    await show(tester, other(age: null));
    expect(find.text('Age'), findsNothing);
    expect(find.byKey(const Key('visitor-age')), findsNothing);
    expect(find.text('Current location'), findsOneWidget);
  });

  testWidgets('Interests you share come first and are counted', (tester) async {
    await show(tester, other());
    expect(
      tester.widget<Text>(find.byKey(const Key('visitor-in-common'))).data,
      '2 in common',
    );
    // Music and Gaming are shared; they lead the list.
    final order = tester
        .widgetList<Text>(
          find.descendant(of: find.byType(Wrap), matching: find.byType(Text)),
        )
        .map((t) => t.data)
        .whereType<String>()
        .toList();
    final interests = order.where(
      (t) => ['Music', 'Gaming', 'K-pop', 'Study'].contains(t),
    );
    expect(interests.take(2).toSet(), {'Music', 'Gaming'});
    expect(find.text('K-pop'), findsOneWidget);
  });

  testWidgets('With nothing in common no count is shown', (tester) async {
    await show(tester, other(interests: const ['Chess', 'Baking']));
    expect(find.byKey(const Key('visitor-in-common')), findsNothing);
    expect(find.text('Chess'), findsOneWidget);
  });

  testWidgets('Vibe and languages with levels are listed', (tester) async {
    await show(tester, other());
    await tester.scrollUntilVisible(find.text('Languages'), 300);
    expect(find.text('Current vibe'), findsOneWidget);
    expect(find.text('Chill'), findsOneWidget);
    expect(find.textContaining('English'), findsOneWidget);
    expect(find.textContaining('Fluent'), findsOneWidget);
    expect(find.textContaining('Native'), findsOneWidget);
  });

  testWidgets('A profile with nothing to show says so kindly', (tester) async {
    await show(
      tester,
      other(
        interests: const [],
        age: null,
        gender: '',
        country: null,
        region: '',
        vibe: '',
        languages: const [],
        headline: '',
        stats: null,
      ),
    );
    expect(find.byKey(const Key('visitor-empty-details')), findsOneWidget);
    expect(find.textContaining('hasn’t added details yet'), findsOneWidget);
  });

  testWidgets('The posts tab shows their posts or an empty note', (
    tester,
  ) async {
    await show(tester, other());
    await tester.tap(find.byKey(const Key('visitor-tab-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('visitor-empty-posts')), findsOneWidget);
    expect(find.text('Detailed profile'), findsNothing);
    await tester.tap(find.byKey(const Key('visitor-tab-0')));
    await tester.pumpAndSettle();
    expect(find.text('Detailed profile'), findsOneWidget);
  });

  testWidgets('Their posts appear on the posts tab', (tester) async {
    await show(
      tester,
      other(),
      contentFor: (tab) => tab == 0 ? const Text('a post of theirs') : null,
    );
    await tester.tap(find.byKey(const Key('visitor-tab-1')));
    await tester.pumpAndSettle();
    expect(find.text('a post of theirs'), findsOneWidget);
    expect(find.byKey(const Key('visitor-empty-posts')), findsNothing);
  });

  testWidgets('Back and options reach their callbacks', (tester) async {
    var back = 0, options = 0;
    await show(
      tester,
      other(),
      onBack: () => back++,
      onOptions: () => options++,
    );
    await tester.tap(find.byKey(const Key('visitor-back')));
    await tester.tap(find.byKey(const Key('profile-options')));
    expect((back, options), (1, 1));
  });

  testWidgets('Options are hidden when there are none to offer', (
    tester,
  ) async {
    await show(tester, other());
    expect(find.byKey(const Key('profile-options')), findsNothing);
  });

  testWidgets('Nothing here talks about "my" profile, only theirs', (
    tester,
  ) async {
    await show(tester, other());
    expect(find.textContaining('MY '), findsNothing);
    expect(find.textContaining('My '), findsNothing);
  });

  testWidgets('It fits a small phone with large text', (tester) async {
    await show(
      tester,
      other(
        headline: 'A long headline that needs more than a single line to read',
        bio:
            'And a longer bio that goes on for a while so we can see wrapping.',
      ),
      size: const Size(320, 640),
      textScale: 2,
    );
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.text('Languages'), 300);
    expect(tester.takeException(), isNull);
  });

  testWidgets('It works without your own profile having loaded', (
    tester,
  ) async {
    await show(tester, other(), own: null);
    expect(find.text('Eshika'), findsOneWidget);
    expect(find.byKey(const Key('visitor-in-common')), findsNothing);
  });
}
