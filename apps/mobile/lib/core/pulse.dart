part of 'api.dart';

class Person {
  final String userId, username, displayName;

  /// Signed thumbnail URL, or null when they have no photo.
  final String? avatarUrl;
  const Person(this.userId, this.username, this.displayName, {this.avatarUrl});
  factory Person.fromJson(Map json) => Person(
    json['userId'] as String,
    json['username'] as String,
    json['displayName'] as String? ?? '',
    avatarUrl: json['avatarUrl'] as String?,
  );

  /// Display name, or @username when there isn't one.
  String get name =>
      displayName.trim().isEmpty ? '@$username' : displayName.trim();
}

class PostMedia {
  final String mediaId, url, thumbUrl;
  final int width, height;
  const PostMedia(
    this.mediaId,
    this.url,
    this.thumbUrl,
    this.width,
    this.height,
  );
  factory PostMedia.fromJson(Map json) => PostMedia(
    json['mediaId'] as String,
    json['url'] as String? ?? '',
    json['thumbUrl'] as String? ?? '',
    json['width'] as int? ?? 0,
    json['height'] as int? ?? 0,
  );
  double get aspect => width > 0 && height > 0 ? width / height : 1;
}

/// The photo type from its first bytes, or null if it isn't one we accept.
/// Uploads are labelled by content, never by file name.
String? sniffImageType(Uint8List b) {
  if (b.length > 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
    return 'image/jpeg';
  }
  if (b.length > 8 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4E &&
      b[3] == 0x47) {
    return 'image/png';
  }
  if (b.length > 12 &&
      String.fromCharCodes(b.sublist(0, 4)) == 'RIFF' &&
      String.fromCharCodes(b.sublist(8, 12)) == 'WEBP') {
    return 'image/webp';
  }
  return null;
}

/// Reactions in the order the picker shows them.
const postReactions = {
  'heart': '❤️',
  'fire': '🔥',
  'laugh': '😂',
  'wow': '😮',
  'sad': '😢',
};

class Post {
  final String postId, body, audience;
  final Person author;
  final DateTime createdAt;
  final List<PostMedia> media;
  final int reactionCount, commentCount;
  final String? myReaction;
  final bool saved, mine;
  const Post({
    required this.postId,
    required this.author,
    required this.body,
    required this.audience,
    required this.createdAt,
    this.media = const [],
    this.reactionCount = 0,
    this.commentCount = 0,
    this.myReaction,
    this.saved = false,
    this.mine = false,
  });
  factory Post.fromJson(Map<String, dynamic> json) => Post(
    postId: json['postId'] as String,
    author: Person.fromJson(json['author'] as Map),
    body: json['body'] as String? ?? '',
    audience: json['audience'] as String? ?? 'public',
    createdAt: DateTime.parse(json['createdAt'] as String),
    media: [
      for (final m in json['media'] as List? ?? const [])
        PostMedia.fromJson(m as Map),
    ],
    reactionCount: json['reactionCount'] as int? ?? 0,
    commentCount: json['commentCount'] as int? ?? 0,
    myReaction: json['myReaction'] as String?,
    saved: json['saved'] as bool? ?? false,
    mine: json['mine'] as bool? ?? false,
  );
  Post copyWith({
    String? Function()? myReaction,
    int? reactionCount,
    int? commentCount,
    bool? saved,
  }) => Post(
    postId: postId,
    author: author,
    body: body,
    audience: audience,
    createdAt: createdAt,
    media: media,
    reactionCount: reactionCount ?? this.reactionCount,
    commentCount: commentCount ?? this.commentCount,
    myReaction: myReaction == null ? this.myReaction : myReaction(),
    saved: saved ?? this.saved,
    mine: mine,
  );
}

class PostComment {
  final String commentId, postId, body;
  final String? parentId;
  final Person author;
  final DateTime createdAt;
  final bool mine, canDelete;
  const PostComment({
    required this.commentId,
    required this.postId,
    required this.body,
    required this.author,
    required this.createdAt,
    this.parentId,
    this.mine = false,
    this.canDelete = false,
  });
  factory PostComment.fromJson(Map<String, dynamic> json) => PostComment(
    commentId: json['commentId'] as String,
    postId: json['postId'] as String,
    body: json['body'] as String,
    author: Person.fromJson(json['author'] as Map),
    createdAt: DateTime.parse(json['createdAt'] as String),
    parentId: json['parentId'] as String?,
    mine: json['mine'] as bool? ?? false,
    canDelete: json['canDelete'] as bool? ?? false,
  );
}

class Story {
  final String storyId, body, background, audience;

  /// How the words are drawn; stories from before text styles are clean.
  final String textStyle;
  final PostMedia? media;
  final DateTime createdAt, expiresAt;
  final bool seen;
  final int? viewCount;

  /// More than 99 members saw it: [viewCount] stops at 99, show "99+".
  final bool viewCountMore;
  const Story({
    required this.storyId,
    required this.body,
    required this.background,
    required this.audience,
    required this.createdAt,
    required this.expiresAt,
    this.textStyle = 'clean',
    this.media,
    this.seen = false,
    this.viewCount,
    this.viewCountMore = false,
  });

  /// "Seen by 3", or "Seen by 99+" once the server stops counting.
  String get viewsLabel => badgeLabel(viewCount ?? 0, more: viewCountMore);
  factory Story.fromJson(Map<String, dynamic> json) => Story(
    storyId: json['storyId'] as String,
    body: json['body'] as String? ?? '',
    background: json['background'] as String? ?? 'lime',
    textStyle: json['textStyle'] as String? ?? 'clean',
    audience: json['audience'] as String? ?? 'followers',
    createdAt: DateTime.parse(json['createdAt'] as String),
    expiresAt: DateTime.parse(json['expiresAt'] as String),
    media: json['media'] == null
        ? null
        : PostMedia.fromJson(json['media'] as Map),
    seen: json['seen'] as bool? ?? false,
    viewCount: json['viewCount'] as int?,
    viewCountMore: json['viewCountMore'] as bool? ?? false,
  );
}

class StoryGroup {
  final Person author;
  final List<Story> stories;
  final bool allSeen, mine;
  const StoryGroup(
    this.author,
    this.stories, {
    this.allSeen = false,
    this.mine = false,
  });
  factory StoryGroup.fromJson(Map<String, dynamic> json) => StoryGroup(
    Person.fromJson(json['author'] as Map),
    [
      for (final s in json['stories'] as List)
        Story.fromJson(Map<String, dynamic>.from(s as Map)),
    ],
    allSeen: json['allSeen'] as bool? ?? false,
    mine: json['mine'] as bool? ?? false,
  );
}

String _cursorQuery(String? cursor, [String join = '?']) =>
    cursor == null ? '' : '${join}cursor=${Uri.encodeQueryComponent(cursor)}';

/// Pulse endpoints, mixed into [ApiClient] so tests can override them.
mixin PulseApi {
  Future<dynamic> _request(
    String method,
    String path, {
    String? token,
    Object? body,
    // ignore: unused_element_parameter
    String? version,
  });
  Dio get _uploads;

  Future<ApiPage<Post>> feed(Session s, String mode, [String? cursor]) async =>
      ApiPage.fromJson(
        await _request(
          'GET',
          '/v1/feed?mode=$mode${_cursorQuery(cursor, '&')}',
          token: s.token,
        ) as Map<String, dynamic>,
        Post.fromJson,
      );

  Future<ApiPage<Post>> userPosts(
    Session s,
    String userId, [
    String? cursor,
  ]) async => ApiPage.fromJson(
    await _request(
      'GET',
      '/v1/users/$userId/posts${_cursorQuery(cursor)}',
      token: s.token,
    ) as Map<String, dynamic>,
    Post.fromJson,
  );

  Future<ApiPage<Post>> savedPosts(Session s, [String? cursor]) async =>
      ApiPage.fromJson(
        await _request(
          'GET',
          '/v1/me/saved${_cursorQuery(cursor)}',
          token: s.token,
        ) as Map<String, dynamic>,
        Post.fromJson,
      );

  Future<Post> createPost(
    Session s, {
    required String body,
    required String audience,
    List<String> mediaIds = const [],
  }) async => Post.fromJson(
    await _request(
      'POST',
      '/v1/posts',
      token: s.token,
      body: {'body': body, 'audience': audience, 'mediaIds': mediaIds},
    ) as Map<String, dynamic>,
  );

  Future<void> deletePost(Session s, String id) async =>
      await _request('DELETE', '/v1/posts/$id', token: s.token);

  Future<void> react(Session s, String postId, String? reaction) async =>
      await _request(
        reaction == null ? 'DELETE' : 'PUT',
        '/v1/posts/$postId/reaction',
        token: s.token,
        body: reaction == null ? null : {'reaction': reaction},
      );

  Future<void> setPostSaved(Session s, String postId, bool saved) async =>
      await _request(
        saved ? 'PUT' : 'DELETE',
        '/v1/posts/$postId/save',
        token: s.token,
      );

  Future<ApiPage<PostComment>> comments(
    Session s,
    String postId, [
    String? cursor,
  ]) async => ApiPage.fromJson(
    await _request(
      'GET',
      '/v1/posts/$postId/comments${_cursorQuery(cursor)}',
      token: s.token,
    ) as Map<String, dynamic>,
    PostComment.fromJson,
  );

  Future<PostComment> addComment(
    Session s,
    String postId,
    String body, {
    String? parentId,
  }) async => PostComment.fromJson(
    await _request(
      'POST',
      '/v1/posts/$postId/comments',
      token: s.token,
      body: {'body': body, 'parentId': ?parentId},
    ) as Map<String, dynamic>,
  );

  Future<void> deleteComment(Session s, String id) async =>
      await _request('DELETE', '/v1/comments/$id', token: s.token);

  /// Uploads one photo: opens an upload, sends the bytes straight to storage
  /// with the signed URL, then asks the API to process it. Returns its id.
  Future<String> uploadPhoto(
    Session s,
    Uint8List bytes, {
    required String contentType,
    required String purpose,
    void Function(double progress)? onProgress,
  }) async {
    final made = await _request(
      'POST',
      '/v1/media/uploads',
      token: s.token,
      body: {
        'purpose': purpose,
        'contentType': contentType,
        'sizeBytes': bytes.length,
      },
    ) as Map<String, dynamic>;
    final headers = Map<String, String>.from(made['headers'] as Map);
    try {
      await _uploads.put<void>(
        made['uploadUrl'] as String,
        // The bytes themselves, so the body is exactly the declared size: Dio derives the
        // Content-Length from them and the signed URL refuses any other length.
        data: bytes,
        options: Options(headers: headers),
        onSendProgress: onProgress == null
            ? null
            : (sent, total) => onProgress(total > 0 ? sent / total : 0),
      );
    } on DioException {
      throw const ApiFailure(
        'That photo didn’t upload. Check your connection and try again.',
      );
    }
    final id = made['mediaId'] as String;
    await _request('POST', '/v1/media/$id/complete', token: s.token);
    return id;
  }

  Future<List<StoryGroup>> storyTray(Session s) async => [
    for (final g
        in (await _request('GET', '/v1/stories/tray', token: s.token)
                as Map<String, dynamic>)['items']
            as List)
      StoryGroup.fromJson(Map<String, dynamic>.from(g as Map)),
  ];

  Future<void> createStory(
    Session s, {
    String body = '',
    String background = 'lime',
    String textStyle = 'clean',
    int lifetimeHours = 24,
    String? mediaId,
    required String audience,
  }) async => await _request(
    'POST',
    '/v1/stories',
    token: s.token,
    body: {
      'body': body,
      'background': background,
      'textStyle': textStyle,
      'lifetimeHours': lifetimeHours,
      'audience': audience,
      'mediaId': ?mediaId,
    },
  );

  Future<void> viewStory(Session s, String id) async =>
      await _request('POST', '/v1/stories/$id/view', token: s.token);

  Future<void> deleteStory(Session s, String id) async =>
      await _request('DELETE', '/v1/stories/$id', token: s.token);

  Future<ApiPage<Map<String, dynamic>>> storyViewers(
    Session s,
    String id, [
    String? cursor,
  ]) async => ApiPage.fromJson(
    await _request(
      'GET',
      '/v1/stories/$id/viewers${_cursorQuery(cursor)}',
      token: s.token,
    ) as Map<String, dynamic>,
    (v) => v,
  );
}
