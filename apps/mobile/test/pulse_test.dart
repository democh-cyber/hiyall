import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:kairova/app.dart';
import 'package:kairova/core/api.dart';
import 'package:kairova/core/state.dart';
import 'package:kairova/features/pulse.dart';

import 'widget_test.dart' show FakeApi, SignedIn;

const niko = Person(nikoId, 'niko', 'Niko');
const me = Person(anjaliId, 'anjali', 'Anjali');
final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4]);

class PulseApi extends FakeApi {
  bool failReact = false;
  final comments_ = <PostComment>[];
  String? posted;
  List<String>? postedMedia;
  String? storyBody;

  @override
  Future<void> react(Session s, String postId, String? reaction) async {
    calls.add('react $postId $reaction');
    if (failReact) throw const ApiFailure('Could not connect.');
  }

  @override
  Future<void> setPostSaved(Session s, String postId, bool saved) async =>
      calls.add('save $postId $saved');

  @override
  Future<ApiPage<PostComment>> comments(
    Session s,
    String postId, [
    String? cursor,
  ]) async => ApiPage(comments_, null);

  @override
  Future<PostComment> addComment(
    Session s,
    String postId,
    String body, {
    String? parentId,
  }) async {
    calls.add('comment $postId $body');
    return PostComment(
      commentId: 'c${comments_.length + 1}',
      postId: postId,
      body: body,
      author: me,
      createdAt: DateTime.now(),
      mine: true,
      canDelete: true,
    );
  }

  @override
  Future<void> deletePost(Session s, String id) async =>
      calls.add('delete $id');

  @override
  Future<String> uploadPhoto(
    Session s,
    Uint8List bytes, {
    required String contentType,
    required String purpose,
    void Function(double progress)? onProgress,
  }) async {
    calls.add('upload $purpose $contentType ${bytes.length}');
    onProgress?.call(1);
    return 'media-${calls.length}';
  }

  @override
  Future<Post> createPost(
    Session s, {
    required String body,
    required String audience,
    List<String> mediaIds = const [],
  }) async {
    posted = '$audience:$body';
    postedMedia = mediaIds;
    return Post(
      postId: 'new',
      author: me,
      body: body,
      audience: audience,
      createdAt: DateTime.now(),
      mine: true,
    );
  }

  @override
  Future<void> viewStory(Session s, String id) async => calls.add('view $id');

  @override
  Future<void> createStory(
    Session s, {
    String body = '',
    String background = 'lime',
    String? mediaId,
    required String audience,
  }) async => storyBody = '$audience:$background:$body';
}

class FakePicker extends ImagePicker {
  @override
  Future<List<XFile>> pickMultiImage({
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    int? limit,
    bool requestFullMetadata = true,
  }) async => [
    XFile.fromData(jpeg, name: 'a.jpg'),
    XFile.fromData(jpeg, name: 'b.jpg'),
  ];
}

Post post(
  String id, {
  String body = 'hello',
  bool mine = false,
  int reactions = 0,
  int comments = 0,
}) => Post(
  postId: id,
  author: mine ? me : niko,
  body: body,
  audience: 'public',
  createdAt: DateTime.now().subtract(const Duration(hours: 3)),
  reactionCount: reactions,
  commentCount: comments,
  mine: mine,
);

Future<ProviderContainer> start(
  WidgetTester tester,
  PulseApi api,
  String at,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final container = ProviderContainer(
    overrides: [
      apiProvider.overrideWithValue(api),
      sessionProvider.overrideWith(SignedIn.new),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const KairovaApp()),
  );
  container.read(routerProvider).go(at);
  await tester.pumpAndSettle();
  return container;
}

Future<void> reveal(WidgetTester tester, Finder f) async {
  await tester.scrollUntilVisible(
    f,
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  test('Photo types come from content, not names', () {
    expect(sniffImageType(jpeg), 'image/jpeg');
    expect(
      sniffImageType(
        Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0, 0]),
      ),
      'image/png',
    );
    expect(
      sniffImageType(
        Uint8List.fromList('RIFF\x00\x00\x00\x00WEBPVP8 '.codeUnits),
      ),
      'image/webp',
    );
    expect(
      sniffImageType(Uint8List.fromList('GIF89a........'.codeUnits)),
      isNull,
    );
  });

  test('Card times and default audiences', () {
    final now = DateTime(2026, 10, 8, 12);
    expect(shortAgo(now.subtract(const Duration(seconds: 20)), now), 'now');
    expect(shortAgo(now.subtract(const Duration(minutes: 5)), now), '5m');
    expect(shortAgo(now.subtract(const Duration(hours: 3)), now), '3h');
    expect(shortAgo(now.subtract(const Duration(days: 2)), now), '2d');
    expect(defaultAudience('public'), 'public');
    expect(defaultAudience('private'), 'friends');
    expect(defaultAudience(null), 'friends');
  });

  testWidgets('Reacting and saving update at once and roll back on failure', (
    tester,
  ) async {
    final api = PulseApi()..posts = [post('p1', reactions: 2)];
    await start(tester, api, '/home');
    final react = find.byKey(const Key('react-p1'));
    await reveal(tester, react);
    expect(
      find.descendant(of: react, matching: find.text('2')),
      findsOneWidget,
    );

    await tester.tap(react);
    await tester.pumpAndSettle();
    expect(api.calls, contains('react p1 heart'));
    expect(
      find.descendant(of: react, matching: find.text('3')),
      findsOneWidget,
    );

    // Changing the reaction keeps the count.
    await tester.longPress(react);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('reaction-fire')));
    await tester.pumpAndSettle();
    expect(api.calls, contains('react p1 fire'));
    expect(
      find.descendant(of: react, matching: find.text('3')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: react, matching: find.text('🔥')),
      findsOneWidget,
    );

    api.failReact = true;
    await tester.tap(react);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: react, matching: find.text('🔥')),
      findsOneWidget,
    );
    expect(find.text('Could not connect.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('save-p1')));
    await tester.pumpAndSettle();
    expect(api.calls, contains('save p1 true'));
    expect(find.byTooltip('Remove from saved'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Comments open, post and count', (tester) async {
    final api = PulseApi()..posts = [post('p1', comments: 1)];
    api.comments_.add(
      PostComment(
        commentId: 'c0',
        postId: 'p1',
        body: 'first!',
        author: niko,
        createdAt: DateTime.now(),
      ),
    );
    await start(tester, api, '/home');
    final open = find.byKey(const Key('comments-p1'));
    await reveal(tester, open);
    await tester.tap(open);
    await tester.pumpAndSettle();
    expect(find.text('first!'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('comment-input')), 'so good');
    await tester.tap(find.byKey(const Key('comment-send')));
    await tester.pumpAndSettle();
    expect(api.calls, contains('comment p1 so good'));
    expect(find.text('so good'), findsOneWidget);
    Navigator.of(tester.element(find.text('so good'))).pop();
    await tester.pumpAndSettle();
    expect(find.descendant(of: open, matching: find.text('2')), findsOneWidget);
  });

  testWidgets('Deleting your own post asks first and removes it', (
    tester,
  ) async {
    final api = PulseApi()
      ..posts = [post('mine', body: 'my words', mine: true)];
    await start(tester, api, '/home');
    final menu = find.byKey(const Key('post-menu-mine'));
    await reveal(tester, menu);
    await tester.tap(menu);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('report-post')), findsNothing);
    await tester.tap(find.byKey(const Key('delete-post')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-delete-post')));
    await tester.pumpAndSettle();
    expect(api.calls, contains('delete mine'));
    expect(find.text('my words'), findsNothing);
  });

  testWidgets('Profiles list the person’s own posts', (tester) async {
    final api = PulseApi()
      ..posts = [
        post('mine', body: 'from my profile', mine: true),
        post('p2', body: 'not mine'),
      ];
    await start(tester, api, '/profile');
    final row = find.byKey(const Key('profile-post-mine'));
    await tester.scrollUntilVisible(
      row,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('from my profile'), findsOneWidget);
    expect(find.text('not mine'), findsNothing);
  });

  testWidgets('The composer uploads photos before sharing', (tester) async {
    final api = PulseApi();
    final container = await start(tester, api, '/home');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: ComposePostScreen(picker: FakePicker())),
      ),
    );
    await tester.pumpAndSettle();
    final share = find.byKey(const Key('share-post'));
    expect(tester.widget<FilledButton>(share).onPressed, isNull);
    await tester.tap(find.byKey(const Key('add-photos')));
    await tester.pumpAndSettle();
    expect(
      api.calls.where((c) => c.startsWith('upload post image/jpeg')),
      hasLength(2),
    );
    await tester.enterText(find.byKey(const Key('post-body')), 'two pics');
    await tester.tap(find.text('Everyone'));
    await tester.pump();
    await tester.tap(share);
    await tester.pumpAndSettle();
    expect(api.posted, 'public:two pics');
    expect(api.postedMedia, hasLength(2));
  });

  testWidgets('Stories: tray, viewer marks seen, and a text story shares', (
    tester,
  ) async {
    final now = DateTime.now();
    Story story(String id, String body, {bool seen = false, int? views}) =>
        Story(
          storyId: id,
          body: body,
          background: 'pink',
          audience: 'followers',
          createdAt: now,
          expiresAt: now.add(const Duration(hours: 20)),
          seen: seen,
          viewCount: views,
        );
    final api = PulseApi()
      ..stories = [
        StoryGroup(
          me,
          [story('m1', 'mine', views: 4)],
          mine: true,
          allSeen: true,
        ),
        StoryGroup(niko, [story('n1', 'gm'), story('n2', 'coffee')]),
      ];
    final container = await start(tester, api, '/home');
    await tester.tap(find.byKey(const Key('story-$nikoId')));
    // Stories run on a timer, so step time instead of settling.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('gm'), findsOneWidget);
    expect(api.calls, contains('view n1'));
    // Tap the right side to move on.
    await tester.tapAt(const Offset(350, 400));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('coffee'), findsOneWidget);
    expect(api.calls, contains('view n2'));
    await tester.tap(find.byKey(const Key('close-stories')));
    await tester.pumpAndSettle();

    // Your own story shows its views and isn't counted as a view.
    await tester.tap(find.byKey(const Key('story-mine')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Seen by 4'), findsOneWidget);
    expect(api.calls, isNot(contains('view m1')));
    await tester.tap(find.byKey(const Key('close-stories')));
    await tester.pumpAndSettle();

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: StoryComposerScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('story-text')), 'hello world');
    await tester.tap(find.bySemanticsLabel('mint background'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('share-story')));
    await tester.pumpAndSettle();
    // The fixture's story audience setting is friends.
    expect(api.storyBody, 'friends:mint:hello world');
  });
}
