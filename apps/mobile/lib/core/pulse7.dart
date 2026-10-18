import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api.dart';
import 'state.dart';

// The Pulse additions of docs/api/27-stories-notices-support.md (topics, the Everyone stories list, search,
// voice notes, threaded comments, My activity), kept in their own client so the first Pulse code stays as it
// was. Calls go through [ApiClient.send], so sign-in, token refresh and error wording are the app's own.

/// One public story in the Everyone list or in a story search: the story with its author.
class ExploreStory {
  final Person author;
  final Story story;
  const ExploreStory(this.author, this.story);
  factory ExploreStory.fromJson(Map<String, dynamic> json) => ExploreStory(
    Person.fromJson(json['author'] as Map),
    Story.fromJson(json),
  );

  /// The one-story group the story viewer opens.
  StoryGroup get group => StoryGroup(author, [story], allSeen: story.seen);
}

enum SearchScope {
  posts,
  stories;

  String get wire => name;
}

/// One page of a Pulse search. [posts] is filled for [SearchScope.posts], [stories] for the other scope.
class PulseSearchPage {
  final SearchScope scope;
  final List<Post> posts;
  final List<ExploreStory> stories;
  final String? nextCursor;
  const PulseSearchPage(
    this.scope, {
    this.posts = const [],
    this.stories = const [],
    this.nextCursor,
  });
  int get length => scope == SearchScope.posts ? posts.length : stories.length;
}

/// The post a My activity row is about. [removed] when it is deleted or the member can no longer see it: the
/// card then carries nothing else.
class ActivityPost {
  final String postId;
  final bool removed, hasMedia, hasVoice;
  final Person? author;
  final String excerpt;
  final String? topic;
  const ActivityPost(
    this.postId, {
    this.removed = false,
    this.hasMedia = false,
    this.hasVoice = false,
    this.author,
    this.excerpt = '',
    this.topic,
  });
  factory ActivityPost.fromJson(Map json) {
    final removed = json['state'] == 'removed';
    final author = json['author'];
    return ActivityPost(
      json['postId'] as String,
      removed: removed,
      hasMedia: json['hasMedia'] as bool? ?? false,
      hasVoice: json['hasVoice'] as bool? ?? false,
      author: author is Map ? Person.fromJson(author) : null,
      excerpt: json['excerpt'] as String? ?? '',
      topic: json['topic'] is String ? json['topic'] as String : null,
    );
  }
}

/// A comment the member wrote, with the post it was on.
class MyComment {
  final String commentId, postId, body;
  final String? parentId;
  final DateTime createdAt;
  final ActivityPost post;
  const MyComment({
    required this.commentId,
    required this.postId,
    required this.body,
    required this.createdAt,
    required this.post,
    this.parentId,
  });
  factory MyComment.fromJson(Map<String, dynamic> json) => MyComment(
    commentId: json['commentId'] as String,
    postId: json['postId'] as String,
    body: json['body'] as String? ?? '',
    parentId: json['parentId'] as String?,
    createdAt: DateTime.parse(json['createdAt'] as String),
    post: ActivityPost.fromJson(json['post'] as Map),
  );
}

/// A reaction the member left, with the post it was on.
class MyReaction {
  final String postId, reaction;
  final DateTime createdAt;
  final ActivityPost post;
  const MyReaction({
    required this.postId,
    required this.reaction,
    required this.createdAt,
    required this.post,
  });
  factory MyReaction.fromJson(Map<String, dynamic> json) => MyReaction(
    postId: json['postId'] as String,
    reaction: json['reaction'] as String? ?? 'heart',
    createdAt: DateTime.parse(json['createdAt'] as String),
    post: ActivityPost.fromJson(json['post'] as Map),
  );
}

/// An uploaded and validated voice clip, ready to attach to a post or a story.
class VoiceUpload {
  final String mediaId;
  final int durationMs;
  final String url;
  const VoiceUpload(this.mediaId, this.durationMs, this.url);
}

/// The longest voice clip the server accepts, and the most bytes a clip may be.
const maxVoiceSeconds = 60;
const maxVoiceBytes = 4 * 1024 * 1024;

String _q(Map<String, String?> params) {
  final parts = [
    for (final e in params.entries)
      if (e.value != null && e.value!.isNotEmpty)
        '${e.key}=${Uri.encodeQueryComponent(e.value!)}',
  ];
  return parts.isEmpty ? '' : '?${parts.join('&')}';
}

class Pulse7Client {
  final ApiClient _api;
  final Dio _uploads;
  Pulse7Client(this._api, {Dio? uploads})
    : _uploads =
          uploads ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              sendTimeout: const Duration(minutes: 2),
            ),
          );

  Future<Map<String, dynamic>> _get(Session s, String path) async =>
      await _api.send(s, 'GET', path) as Map<String, dynamic>;

  /// The names of the topics, in the server's order.
  Future<List<String>> topics(Session s) async => [
    for (final t in (await _get(s, '/v1/topics'))['items'] as List)
      if (t is String) t,
  ];

  /// The Pulse feed narrowed to one topic.
  Future<ApiPage<Post>> feedTopic(
    Session s,
    String mode,
    String topic, [
    String? cursor,
  ]) async => ApiPage.fromJson(
    await _get(
      s,
      '/v1/feed${_q({'mode': mode, 'topic': topic, 'cursor': cursor})}',
    ),
    Post.fromJson,
  );

  /// The story tray narrowed to one topic.
  Future<List<StoryGroup>> storyTrayTopic(Session s, String topic) async => [
    for (final g
        in (await _get(s, '/v1/stories/tray${_q({'topic': topic})}'))['items']
            as List)
      StoryGroup.fromJson(Map<String, dynamic>.from(g as Map)),
  ];

  /// Public stories from people outside the tray, newest first.
  Future<ApiPage<ExploreStory>> storyExplore(
    Session s, {
    String? topic,
    String? cursor,
  }) async => ApiPage.fromJson(
    await _get(
      s,
      '/v1/stories/explore${_q({'topic': topic, 'cursor': cursor})}',
    ),
    ExploreStory.fromJson,
  );

  Future<PulseSearchPage> search(
    Session s, {
    required String q,
    required SearchScope scope,
    String? topic,
    String? cursor,
  }) async {
    final json = await _get(
      s,
      '/v1/search/pulse${_q({'q': q, 'scope': scope.wire, 'topic': topic, 'cursor': cursor})}',
    );
    final items = json['items'] as List? ?? const [];
    final next = json['nextCursor'] as String?;
    return scope == SearchScope.posts
        ? PulseSearchPage(
            scope,
            posts: [
              for (final p in items)
                Post.fromJson(Map<String, dynamic>.from(p as Map)),
            ],
            nextCursor: next,
          )
        : PulseSearchPage(
            scope,
            stories: [
              for (final p in items)
                ExploreStory.fromJson(Map<String, dynamic>.from(p as Map)),
            ],
            nextCursor: next,
          );
  }

  Future<Post> post(Session s, String postId) async =>
      Post.fromJson(await _get(s, '/v1/posts/$postId'));

  /// Makes a post with a topic and/or a voice note (see `PulseActions.createPost`, which uses the older call
  /// when there is neither).
  Future<Post> createPost(
    Session s, {
    required String body,
    required String audience,
    List<String> mediaIds = const [],
    String? topic,
    String? voiceMediaId,
  }) async => Post.fromJson(
    await _api.send(
      s,
      'POST',
      '/v1/posts',
      body: {
        'body': body,
        'audience': audience,
        'mediaIds': mediaIds,
        'topic': ?topic,
        'voiceMediaId': ?voiceMediaId,
      },
    ) as Map<String, dynamic>,
  );

  Future<void> createStory(
    Session s, {
    String body = '',
    String background = 'lime',
    String textStyle = 'clean',
    int lifetimeHours = 24,
    String? mediaId,
    required String audience,
    String? topic,
    String? voiceMediaId,
  }) async => await _api.send(
    s,
    'POST',
    '/v1/stories',
    body: {
      'body': body,
      'background': background,
      'textStyle': textStyle,
      'lifetimeHours': lifetimeHours,
      'audience': audience,
      'mediaId': ?mediaId,
      'topic': ?topic,
      'voiceMediaId': ?voiceMediaId,
    },
  );

  /// The top-level comments of a post, each with its reply count.
  Future<ApiPage<PostComment>> topComments(
    Session s,
    String postId, [
    String? cursor,
  ]) async => ApiPage.fromJson(
    await _get(
      s,
      '/v1/posts/$postId/comments${_q({'parent': 'none', 'cursor': cursor})}',
    ),
    PostComment.fromJson,
  );

  /// The replies to one top-level comment, oldest first.
  Future<ApiPage<PostComment>> replies(
    Session s,
    String postId,
    String commentId, [
    String? cursor,
  ]) async => ApiPage.fromJson(
    await _get(
      s,
      '/v1/posts/$postId/comments${_q({'parent': commentId, 'cursor': cursor})}',
    ),
    PostComment.fromJson,
  );

  Future<ApiPage<MyComment>> myComments(Session s, [String? cursor]) async =>
      ApiPage.fromJson(
        await _get(s, '/v1/me/activity/comments${_q({'cursor': cursor})}'),
        MyComment.fromJson,
      );

  Future<ApiPage<MyReaction>> myReactions(Session s, [String? cursor]) async =>
      ApiPage.fromJson(
        await _get(s, '/v1/me/activity/reactions${_q({'cursor': cursor})}'),
        MyReaction.fromJson,
      );

  /// Uploads one voice clip (an AAC `.m4a`): opens an upload, sends the bytes straight to storage, then asks
  /// the server to check it. The server reads the file's own header and refuses what is not a voice clip of at
  /// most 60 seconds; failures come back worded for people.
  Future<VoiceUpload> uploadVoice(
    Session s,
    Uint8List bytes, {
    void Function(double progress)? onProgress,
  }) async {
    if (bytes.length > maxVoiceBytes) {
      throw const ApiFailure(
        'That recording is too large to send. Record a shorter one.',
        413,
        'TOO_LARGE',
      );
    }
    try {
      final made = await _api.send(
        s,
        'POST',
        '/v1/media/uploads',
        body: {
          'purpose': 'voice',
          'contentType': 'audio/mp4',
          'sizeBytes': bytes.length,
        },
      ) as Map<String, dynamic>;
      final headers = Map<String, String>.from(made['headers'] as Map);
      final uploadUrl = checkedUploadUrl(made['uploadUrl'] as String);
      try {
        await _uploads.put<void>(
          uploadUrl,
          // The bytes themselves: the signed URL pins this exact length.
          data: bytes,
          options: Options(headers: headers),
          onSendProgress: onProgress == null
              ? null
              : (sent, total) => onProgress(total > 0 ? sent / total : 0),
        );
      } on DioException {
        throw const ApiFailure(
          'That recording didn’t upload. Check your connection and try again.',
        );
      }
      final id = made['mediaId'] as String;
      final done = await _api.send(
        s,
        'POST',
        '/v1/media/$id/complete',
      ) as Map<String, dynamic>;
      return VoiceUpload(
        done['mediaId'] as String? ?? id,
        (done['durationMs'] as num?)?.toInt() ?? 0,
        done['url'] as String? ?? '',
      );
    } on ApiFailure catch (e) {
      throw voiceFailure(e);
    }
  }
}

/// The server's voice refusals in this app's words (the photo wording does not fit a recording).
ApiFailure voiceFailure(ApiFailure e) => switch (e.code) {
  'VOICE_TOO_LONG' => ApiFailure(
    'That voice note is longer than a minute. Record a shorter one.',
    e.status,
    e.code,
  ),
  'MEDIA_BUSY' => ApiFailure(
    'Voice uploads are busy right now. Your recording is still here.${ApiFailure.busyLater}',
    e.status,
    e.code,
    e.retryAfter,
  ),
  'UNSUPPORTED_MEDIA' when e.status == 415 => ApiFailure(
    'Hiyall couldn’t use that recording. Record it again.',
    e.status,
    e.code,
  ),
  _ => e,
};

/// The Pulse additions' client. Tests override this with a fake.
final pulse7Provider = Provider<Pulse7Client>(
  (ref) => Pulse7Client(ref.watch(apiProvider)),
);

/// The signed-in session for these calls, or a failure that reads well.
Session pulse7Session(Ref ref) {
  final session = ref.read(sessionProvider).asData?.value;
  if (session == null) throw const ApiFailure('Sign in to continue.');
  return session;
}

/// [pulse7Session] for widgets.
Session pulse7SessionOf(WidgetRef ref) {
  final session = ref.read(sessionProvider).asData?.value;
  if (session == null) throw const ApiFailure('Sign in to continue.');
  return session;
}
