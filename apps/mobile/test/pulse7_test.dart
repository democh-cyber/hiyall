import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/features/pulse/post_screen.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/pulse7.dart';
import 'package:hiyall/core/topics.dart';
import 'package:hiyall/core/voice.dart';

import 'support/app_host.dart';
import 'support/fixtures.dart';
import 'support/scripted_api.dart';

// Wave 7 Pulse: topics, tabs, Everyone stories, search, threaded comments, My activity and voice notes
// (docs/api/27-stories-notices-support.md). The server is a script: every call is recorded.

const niko = Person(nikoId, 'niko', 'Niko');

Map<String, dynamic> personJson(Person p) => {
  'userId': p.userId,
  'username': p.username,
  'displayName': p.displayName,
  'avatarUrl': null,
};

Map<String, dynamic> postJson(String id, String body, {String? topic}) => {
  'postId': id,
  'author': personJson(niko),
  'body': body,
  'audience': 'public',
  'createdAt': DateTime.now().toIso8601String(),
  'editedAt': null,
  'media': <Object>[],
  'topic': topic,
  'voice': null,
  'reactionCount': 0,
  'commentCount': 2,
  'myReaction': null,
  'saved': false,
  'mine': false,
};

Map<String, dynamic> storyJson(String id, String body, {String? topic}) => {
  'storyId': id,
  'author': personJson(niko),
  'body': body,
  'background': 'lime',
  'textStyle': 'clean',
  'media': null,
  'topic': topic,
  'voice': null,
  'audience': 'public',
  'createdAt': DateTime.now().toIso8601String(),
  'expiresAt': DateTime.now().add(const Duration(hours: 5)).toIso8601String(),
  'seen': false,
};

Map<String, dynamic> commentJson(
  String id,
  String body, {
  String? parent,
  int replies = 0,
}) => {
  'commentId': id,
  'postId': 'p1',
  'author': personJson(niko),
  'parentId': parent,
  'body': body,
  'createdAt': DateTime.now().toIso8601String(),
  'mine': false,
  'canDelete': false,
  'replyCount': replies,
};

class P7Api extends ScriptedApi {
  final added = <Map<String, String?>>[];
  @override
  Future<PostComment> addComment(
    Session s,
    String postId,
    String body, {
    String? parentId,
  }) async {
    added.add({'body': body, 'parentId': parentId});
    return PostComment.fromJson(
      commentJson('new${added.length}', body, parent: parentId)
        ..['mine'] = true
        ..['canDelete'] = true,
    );
  }
}

P7Api scripted() {
  final api = P7Api();
  api.on('GET /v1/topics', (_, _) => {'items': topicNames});
  return api;
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
  group('topics', () {
    test(
      'every topic has words and an icon, and an unknown one is shown as sent',
      () {
        for (final name in topicNames) {
          expect(
            topicLabel(name),
            isNot(name.toLowerCase() == name ? '' : name),
          );
          expect(topicIcon(name), isNot(Icons.tag_rounded));
        }
        expect(topicLabel('cooking'), 'cooking');
        expect(topicIcon('cooking'), Icons.tag_rounded);
      },
    );

    testWidgets(
      'choosing a chip asks the feed for that topic and No topic clears it',
      (tester) async {
        final api = scripted();
        api.on(
          'GET /v1/feed',
          (_, _) => {
            'items': [postJson('p1', 'guitar notes', topic: 'music')],
            'nextCursor': null,
          },
        );
        await launchApp(tester, api, '/home');
        final chip = find.byKey(const Key('topic-chip-music'));
        await reveal(tester, chip);
        await tester.tap(chip);
        await tester.pumpAndSettle();
        expect(api.sent, contains('GET /v1/feed?mode=following&topic=music'));
        expect(find.text('guitar notes'), findsOneWidget);
        expect(find.byKey(const Key('post-topic-p1')), findsOneWidget);
        // The chip stays chosen for the Following tab only; Everyone starts on All.
        await tester.tap(find.byKey(const Key('feed-mode-everyone')));
        await tester.pumpAndSettle();
        expect(
          api.sent.where((c) => c.contains('mode=everyone&topic')),
          isEmpty,
        );
      },
    );
  });

  group('Everyone stories', () {
    testWidgets('the Everyone tab shows public stories and narrows by topic', (
      tester,
    ) async {
      final api = scripted();
      api.on(
        'GET /v1/stories/explore',
        (_, path) => {
          'items': [
            storyJson(
              path.contains('topic=food') ? 'sf' : 's1',
              'hello world',
              topic: path.contains('topic=food') ? 'food' : null,
            ),
          ],
          'nextCursor': null,
        },
      );
      api.on('GET /v1/feed', (_, _) => {'items': [], 'nextCursor': null});
      await launchApp(tester, api, '/home');
      expect(find.byKey(const Key('story-explore')), findsNothing);
      await tester.tap(find.byKey(const Key('feed-mode-everyone')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('explore-s1')), findsOneWidget);
      final row = find.byKey(const Key('topic-chips-everyone'));
      await reveal(tester, row);
      await tester.drag(row, const Offset(-300, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('topic-chip-food')));
      await tester.pumpAndSettle();
      expect(api.sent, contains('GET /v1/stories/explore?topic=food'));
      // The strip is above the chips: scroll back up to see it.
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 800));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('explore-sf')), findsOneWidget);
      expect(find.byKey(const Key('explore-s1')), findsNothing);
    });

    testWidgets('an empty or failed Everyone list says so', (tester) async {
      final api = scripted();
      api.on('GET /v1/feed', (_, _) => {'items': [], 'nextCursor': null});
      api.on(
        'GET /v1/stories/explore',
        (_, _) => {'items': [], 'nextCursor': null},
      );
      await launchApp(tester, api, '/home');
      await tester.tap(find.byKey(const Key('feed-mode-everyone')));
      await tester.pumpAndSettle();
      expect(find.text('No public stories right now.'), findsOneWidget);
    });
  });

  group('search', () {
    testWidgets(
      'waits for a pause, needs two letters, switches scope and shows the daily limit',
      (tester) async {
        final api = scripted();
        api.on('GET /v1/search/pulse', (_, path) {
          if (path.contains('q=limit')) {
            throw const ApiFailure(
              'You’ve searched a lot today. Try again tomorrow.',
              429,
              'DAILY_LIMIT',
            );
          }
          return path.contains('scope=stories')
              ? {
                  'items': [storyJson('s9', 'story about guitars')],
                  'nextCursor': null,
                  'scope': 'stories',
                }
              : {
                  'items': [postJson('p1', 'learning guitar chords')],
                  'nextCursor': 'next-1',
                  'scope': 'posts',
                };
        });
        await launchApp(tester, api, '/search');
        final input = find.byKey(const Key('pulse-search-input'));
        await tester.enterText(input, 'g');
        await tester.pump(const Duration(seconds: 1));
        expect(api.count('GET /v1/search/pulse'), 0);
        await tester.enterText(input, 'gu');
        await tester.enterText(input, 'guitar');
        await tester.pump(const Duration(milliseconds: 200));
        expect(
          api.count('GET /v1/search/pulse'),
          0,
          reason: 'typing has not paused yet',
        );
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pumpAndSettle();
        expect(api.count('GET /v1/search/pulse'), 1);
        expect(api.sent, contains('GET /v1/search/pulse?q=guitar&scope=posts'));
        expect(find.byKey(const Key('search-post-p1')), findsOneWidget);
        // A page at a time, asked for.
        await tester.tap(find.byKey(const Key('pulse-search-more')));
        await tester.pumpAndSettle();
        expect(
          api.sent,
          contains('GET /v1/search/pulse?q=guitar&scope=posts&cursor=next-1'),
        );
        await tester.tap(find.text('Stories'));
        await tester.pumpAndSettle();
        expect(api.sent.last, 'GET /v1/search/pulse?q=guitar&scope=stories');
        expect(find.byKey(const Key('search-story-s9')), findsOneWidget);
        // The topic narrows the search.
        await tester.tap(find.byKey(const Key('search-topic-music')));
        await tester.pumpAndSettle();
        expect(api.sent.last, contains('topic=music'));
        // The daily limit is explained and not offered a retry.
        await tester.enterText(input, 'limit');
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        expect(find.textContaining('searched a lot today'), findsOneWidget);
        expect(find.text('Try again'), findsNothing);
      },
    );

    testWidgets('a search with no matches says so', (tester) async {
      final api = scripted();
      api.on(
        'GET /v1/search/pulse',
        (_, _) => {'items': [], 'nextCursor': null, 'scope': 'posts'},
      );
      await launchApp(tester, api, '/search');
      await tester.enterText(
        find.byKey(const Key('pulse-search-input')),
        'zzzz',
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('pulse-search-empty')), findsOneWidget);
    });
  });

  group('threaded comments', () {
    Post card() => Post.fromJson(postJson('p1', 'discuss'));

    testWidgets(
      'replies load on demand and a reply to a reply is sent under its own id',
      (tester) async {
        final api = scripted()..posts = [card()];
        api.on('GET /v1/posts/p1/comments', (_, path) {
          if (path.contains('parent=none')) {
            return {
              'items': [commentJson('c1', 'top comment', replies: 2)],
              'nextCursor': null,
            };
          }
          return {
            'items': [
              commentJson('r1', 'first reply', parent: 'c1'),
              commentJson('r2', 'second reply', parent: 'c1'),
            ],
            'nextCursor': null,
          };
        });
        await launchApp(tester, api, '/home');
        final open = find.byKey(const Key('comments-p1'));
        await reveal(tester, open);
        await tester.tap(open);
        await tester.pumpAndSettle();
        expect(api.sent, contains('GET /v1/posts/p1/comments?parent=none'));
        expect(find.text('top comment'), findsOneWidget);
        expect(find.text('first reply'), findsNothing);
        expect(find.text('View 2 replies'), findsOneWidget);
        await tester.tap(find.byKey(const Key('replies-c1')));
        await tester.pumpAndSettle();
        expect(api.sent, contains('GET /v1/posts/p1/comments?parent=c1'));
        expect(find.text('first reply'), findsOneWidget);
        expect(find.text('Hide replies'), findsOneWidget);
        // Reply to a reply: the banner names its author and the id sent is that reply's.
        await tester.tap(find.byKey(const Key('reply-r2')));
        await tester.pumpAndSettle();
        expect(find.text('Replying to Niko'), findsOneWidget);
        await tester.enterText(
          find.byKey(const Key('comment-input')),
          'agreed',
        );
        await tester.tap(find.byKey(const Key('comment-send')));
        await tester.pumpAndSettle();
        expect(api.added.single, {'body': 'agreed', 'parentId': 'r2'});
        expect(find.text('agreed'), findsOneWidget);
        expect(find.text('Replying to Niko'), findsNothing);
        // Closing a thread hides its replies.
        await tester.tap(find.byKey(const Key('replies-c1')));
        await tester.pumpAndSettle();
        expect(find.text('first reply'), findsNothing);
      },
    );
  });

  group('My activity', () {
    testWidgets('lists comments and likes; a removed post is not opened', (
      tester,
    ) async {
      final api = scripted();
      api.on(
        'GET /v1/me/activity/comments',
        (_, _) => {
          'items': [
            {
              'commentId': 'c1',
              'postId': 'p1',
              'parentId': null,
              'body': 'my kind comment',
              'createdAt': DateTime.now().toIso8601String(),
              'post': {
                'postId': 'p1',
                'state': 'available',
                'author': personJson(niko),
                'excerpt': 'the post text',
                'topic': null,
                'hasMedia': false,
                'hasVoice': false,
              },
            },
            {
              'commentId': 'c2',
              'postId': 'p2',
              'parentId': 'c0',
              'body': 'a reply on a gone post',
              'createdAt': DateTime.now().toIso8601String(),
              'post': {'postId': 'p2', 'state': 'removed'},
            },
          ],
          'nextCursor': null,
        },
      );
      api.on(
        'GET /v1/me/activity/reactions',
        (_, _) => {
          'items': [
            {
              'postId': 'p3',
              'reaction': 'fire',
              'createdAt': DateTime.now().toIso8601String(),
              'post': {'postId': 'p3', 'state': 'removed'},
            },
          ],
          'nextCursor': null,
        },
      );
      api.on('GET /v1/posts/p1', (_, _) => postJson('p1', 'the post text'));
      await launchApp(tester, api, '/profile/activity');
      expect(find.textContaining('You commented'), findsOneWidget);
      expect(find.textContaining('You replied'), findsOneWidget);
      expect(find.text('This post was removed'), findsOneWidget);
      // A removed post does not open.
      await tester.tap(find.byKey(const Key('activity-row-c2')));
      await tester.pumpAndSettle();
      expect(find.byType(PostScreen), findsNothing);
      // An available one jumps to the post.
      await tester.tap(find.byKey(const Key('activity-row-c1')));
      await tester.pumpAndSettle();
      expect(find.byType(PostScreen), findsOneWidget);
      expect(api.sent, contains('GET /v1/posts/p1'));
      expect(find.text('the post text'), findsWidgets);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('activity-tab-likes')));
      await tester.pumpAndSettle();
      expect(find.textContaining('You reacted'), findsOneWidget);
      expect(find.text('This post was removed'), findsOneWidget);
    });

    testWidgets('an empty list says so', (tester) async {
      final api = scripted();
      api.on(
        'GET /v1/me/activity/comments',
        (_, _) => {'items': [], 'nextCursor': null},
      );
      await launchApp(tester, api, '/profile/activity');
      expect(find.byKey(const Key('activity-empty-comments')), findsOneWidget);
    });

    testWidgets('a post that is gone reads as unavailable', (tester) async {
      final api = scripted();
      api.on('GET /v1/posts/p9', (_, _) {
        throw const ApiFailure(
          'This resource is unavailable',
          404,
          'NOT_FOUND',
        );
      });
      await launchApp(tester, api, '/post/p9');
      expect(find.text('This post isn’t available'), findsOneWidget);
    });
  });

  group('voice notes', () {
    test(
      'the client reads topic, voice and replyCount and keeps an unknown topic',
      () {
        final post = Post.fromJson({
          ...postJson('p1', 'x', topic: 'cooking'),
          'voice': {
            'mediaId': 'm1',
            'url': 'https://x/voice.m4a',
            'durationMs': 12500,
          },
        });
        expect(post.topic, 'cooking');
        expect(post.voice!.duration, const Duration(milliseconds: 12500));
        expect(Post.fromJson(postJson('p2', 'y')).voice, isNull);
        expect(
          PostComment.fromJson(commentJson('c', 'b', replies: 3)).replyCount,
          3,
        );
      },
    );

    test(
      'uploading refuses a recording over 4 MiB before asking the server',
      () async {
        final api = scripted();
        final client = Pulse7Client(api);
        await expectLater(
          client.uploadVoice(
            const Session('t', anjaliId),
            Uint8List(maxVoiceBytes + 1),
          ),
          throwsA(isA<ApiFailure>()),
        );
        expect(api.sent, isEmpty);
      },
    );

    test('the server’s voice refusals are worded for a recording', () {
      expect(
        voiceFailure(const ApiFailure('x', 422, 'VOICE_TOO_LONG')).message,
        contains('longer than a minute'),
      );
    });
  });
}

/// A recorder that does what it is told: no microphone, no files.
class FakeRecorder implements NoteRecorder {
  MicAccess access = MicAccess.granted;
  bool started = false, cancelled = false;
  final path = '/tmp/note.m4a';
  @override
  Future<MicAccess> permission() async => access;
  @override
  Future<void> start(String p) async => started = true;
  @override
  Future<String?> stop() async => path;
  @override
  Future<void> cancel() async => cancelled = true;
  @override
  Stream<double> levels(Duration every) => const Stream.empty();
  @override
  Future<void> dispose() async {}
}

class FakeFiles implements NoteFiles {
  final deleted = <String>[];
  bool present = true;
  @override
  Future<bool> exists(String path) async => present;
  @override
  Future<Uint8List> read(String path) async => Uint8List.fromList([1, 2, 3]);
  @override
  Future<void> delete(String path) async => deleted.add(path);
}
