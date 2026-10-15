import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/api.dart' hide PulseApi;
import 'package:hiyall/core/state.dart';
import 'package:hiyall/features/pulse/pulse_actions.dart';

import 'pulse_test.dart' show PulseApi;
import 'widget_test.dart' show SignedIn;
import 'support/fixtures.dart';

class SignedOut extends SessionController {
  @override
  AsyncValue<Session?> build() => const AsyncData(null);
}

class ActionsApi extends PulseApi {
  Session? lastSession;
  String? mutedUser;
  String? deletedStory;
  String? deletedComment;

  @override
  Future<ApiPage<PostComment>> comments(
    Session s,
    String postId, [
    String? cursor,
  ]) async {
    lastSession = s;
    calls.add('comments $postId $cursor');
    return const ApiPage([], null);
  }

  @override
  Future<void> deleteComment(Session s, String id) async => deletedComment = id;

  @override
  Future<void> setMuted(
    Session s,
    String userId,
    bool muted, {
    DateTime? until,
  }) async => mutedUser = '$userId:$muted';

  @override
  Future<void> deleteStory(Session s, String id) async => deletedStory = id;
}

ProviderContainer make(ActionsApi api, {bool signedIn = true}) {
  final c = ProviderContainer(
    overrides: [
      apiProvider.overrideWithValue(api),
      sessionProvider.overrideWith(signedIn ? SignedIn.new : SignedOut.new),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  test(
    'calls go through the overridden API with the current session',
    () async {
      final api = ActionsApi();
      final actions = make(api).read(pulseActionsProvider);
      expect(actions.hasSession, isTrue);

      await actions.comments('p1', 'cur');
      expect(api.calls, contains('comments p1 cur'));
      expect(api.lastSession?.userId, anjaliId);

      await actions.addComment('p1', 'hi', parentId: 'c0');
      expect(api.calls, contains('comment p1 hi'));
      await actions.deleteComment('c9');
      expect(api.deletedComment, 'c9');
      await actions.deletePost('p1');
      expect(api.calls, contains('delete p1'));
      await actions.setMuted('u1', true);
      expect(api.mutedUser, 'u1:true');
      await actions.deleteStory('s1');
      expect(api.deletedStory, 's1');
      await actions.viewStory('s1');
      expect(api.calls, contains('view s1'));
    },
  );

  test('posts and uploads carry their arguments', () async {
    final api = ActionsApi();
    final actions = make(api).read(pulseActionsProvider);
    final post = await actions.createPost(
      body: 'hello',
      audience: 'friends',
      mediaIds: const ['m1'],
    );
    expect(post.postId, 'new');
    expect(api.posted, 'friends:hello');
    expect(api.postedMedia, ['m1']);

    final progress = <double>[];
    final id = await actions.uploadPhoto(
      Uint8List.fromList([1, 2, 3]),
      contentType: 'image/jpeg',
      purpose: 'post',
      onProgress: progress.add,
    );
    expect(id, startsWith('media-'));
    expect(progress, [1]);
    expect(api.calls, contains('upload post image/jpeg 3'));
  });

  test('signed out, there is no session and calls refuse', () async {
    final api = ActionsApi();
    final actions = make(api, signedIn: false).read(pulseActionsProvider);
    expect(actions.hasSession, isFalse);
    await expectLater(actions.comments('p1', null), throwsA(isA<ApiFailure>()));
    await expectLater(actions.deletePost('p1'), throwsA(isA<ApiFailure>()));
    expect(api.calls, isEmpty);
  });
}
