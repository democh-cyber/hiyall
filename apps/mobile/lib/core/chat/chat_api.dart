import 'package:dio/dio.dart';

import '../api_config.dart';

/// A chat API failure with the server's stable error code.
class ChatFailure implements Exception {
  final String code, message;
  final int? status;

  /// How long the server asked the caller to wait (Retry-After), when it did.
  final Duration? retryAfter;

  /// The server's `error.details` (what a spend costs and what the member has, for a 402), when it sent any.
  final Map<String, dynamic>? details;
  const ChatFailure(
    this.code,
    this.message, [
    this.status,
    this.retryAfter,
    this.details,
  ]);
  @override
  String toString() => message;
}

Duration? _retryAfter(String? header) {
  final seconds = int.tryParse(header?.trim() ?? '');
  return seconds == null || seconds < 0 ? null : Duration(seconds: seconds);
}

/// An upload slot for one encrypted blob: where to PUT the ciphertext and the
/// exact headers the signature covers. The URL is a credential, so it is never
/// printed or stored.
class BlobSlot {
  final String blobId, uploadUrl;
  final Map<String, String> headers;
  final DateTime? expiresAt;
  const BlobSlot(this.blobId, this.uploadUrl, this.headers, this.expiresAt);
  @override
  String toString() => 'BlobSlot($blobId)';
}

/// Thin client for the ciphertext relay. Pure Dart so tests and the command-line
/// peer can use it; it only ever carries public keys and ciphertext.
class ChatApi {
  final Dio _dio;
  final String token;

  /// Reads the newest token per request; Firebase rotates it hourly.
  final String Function()? tokenOf;

  /// Asks the identity provider for a brand-new token after a 401, as
  /// [ApiClient] does; a different token means the first was only stale.
  final Future<String?> Function()? tokenRefresher;

  /// Called when the relay still refuses the session after a refresh.
  final void Function()? onUnauthorized;

  /// Called after the relay accepted a message the member sent (push
  /// notifications ask for permission at that meaningful moment).
  void Function()? onSent;

  /// Sent on every request as `X-Client-Version` and `X-Client-Platform`, like
  /// the main API client does (this file stays free of Flutter, so the app
  /// passes them in). Left out when null.
  final String? clientVersion, clientPlatform;

  /// Called when the relay answers 401 APP_CHECK_REQUIRED (it cannot confirm this app build). Never a sign-out.
  final void Function()? onAppCheckRequired;

  /// Called when the relay refuses this app version (426 UPGRADE_REQUIRED);
  /// the app then shows only its "Update Hiyall" screen.
  final void Function()? onUpgradeRequired;
  ChatApi(
    String baseUrl,
    this.token, {
    this.tokenOf,
    this.tokenRefresher,
    this.onUnauthorized,
    this.onSent,
    this.clientVersion,
    this.clientPlatform,
    this.onUpgradeRequired,
    this.onAppCheckRequired,
    Dio? dio,
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               baseUrl: baseUrl,
               connectTimeout: const Duration(seconds: 8),
               receiveTimeout: const Duration(seconds: 15),
               contentType: 'application/json',
             ),
           );

  Future<dynamic> _call(
    String method,
    String path, [
    Object? body,
    String? retryToken,
    Map<String, String>? headers,
  ]) async {
    // The bearer token travels over https only (plain http to this machine in a debug build), like every
    // other client of the API (see isSecureTransport).
    if (!isSecureTransport(Uri.tryParse(_dio.options.baseUrl))) {
      throw const ChatFailure(
        'INSECURE_TRANSPORT',
        'The chat service is not configured yet.',
      );
    }
    final sent = retryToken ?? tokenOf?.call() ?? token;
    try {
      final response = await _dio.request<Map<String, dynamic>>(
        path,
        data: body,
        options: Options(
          method: method,
          headers: {
            'Authorization': 'Bearer $sent',
            'X-Client-Version': ?clientVersion,
            'X-Client-Platform': ?clientPlatform,
            ...?headers,
          },
        ),
      );
      return response.data!['data'];
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      final data = error.response?.data;
      final failure = data is Map ? data['error'] : null;
      final code = failure is Map ? failure['code'] : null;
      if (status == 401 && code == 'APP_CHECK_REQUIRED') {
        // The relay does not trust this app build, which says nothing about the credential: no token refresh,
        // no sign-out, nothing wiped. The app shows its own "confirm this app" screen.
        onAppCheckRequired?.call();
        throw ChatFailure(
          'APP_CHECK_REQUIRED',
          'Hiyall couldn’t confirm this app. Update it, or open the real app from the store.',
          status,
        );
      }
      if (status == 401) {
        if (retryToken == null) {
          final fresh = await tokenRefresher?.call();
          if (fresh != null && fresh != sent) {
            return _call(method, path, body, fresh, headers);
          }
        }
        // Only the relay's explicit "unauthenticated" ends the session; any other 401 (a proxy's, one without
        // the error envelope) proves nothing about the credential.
        if (code == 'UNAUTHENTICATED') onUnauthorized?.call();
        throw ChatFailure(
          'UNAUTHENTICATED',
          'Your session has expired. Sign in again.',
          status,
        );
      }
      if (status == 426 &&
          failure is Map &&
          failure['code'] == 'UPGRADE_REQUIRED') {
        onUpgradeRequired?.call();
        throw const ChatFailure(
          'UPGRADE_REQUIRED',
          'This version of Hiyall is no longer supported. Update to keep going.',
          426,
        );
      }
      throw ChatFailure(
        failure is Map ? '${failure['code']}' : 'NETWORK',
        failure is Map
            ? '${failure['message']}'
            : 'Could not reach the chat service. Check your connection.',
        status,
        _retryAfter(error.response?.headers.value('retry-after')),
        failure is Map && failure['details'] is Map
            ? Map<String, dynamic>.from(failure['details'] as Map)
            : null,
      );
    }
  }

  List<Map<String, dynamic>> _items(dynamic data) => [
    for (final item in (data as Map)['items'] as List)
      Map<String, dynamic>.from(item as Map),
  ];

  Future<void> registerDevice(Map<String, String> device) =>
      _call('POST', '/v1/devices', device);
  Future<int> uploadKeys(
    String deviceId,
    List<Map<String, String>> oneTimeKeys,
    Map<String, String>? fallbackKey,
  ) async =>
      ((await _call('POST', '/v1/devices/$deviceId/keys', {
            'oneTimeKeys': oneTimeKeys,
            'fallbackKey': ?fallbackKey,
          })) as Map)['oneTimeKeyCount']
          as int;
  Future<int> keyCount(String deviceId) async =>
      ((await _call('GET', '/v1/devices/$deviceId/keys'))
              as Map)['oneTimeKeyCount']
          as int;
  Future<List<Map<String, dynamic>>> devices(String userId) async => _items(
    await _call('GET', '/v1/users/${Uri.encodeComponent(userId)}/devices'),
  );
  Future<Map<String, dynamic>> claim(
    String userId,
    String deviceId,
  ) async => Map<String, dynamic>.from(
    await _call(
      'POST',
      '/v1/users/${Uri.encodeComponent(userId)}/devices/${Uri.encodeComponent(deviceId)}/claim',
    ) as Map,
  );

  /// Opens (or reopens) the direct conversation with [userId]. [confirmCost] is the price in coins the member
  /// confirmed for a conversation past the free allowance (the `Spend-Confirm` header; 402
  /// SPEND_CONFIRMATION_REQUIRED says the price when it is missing, docs/api/28-billing.md).
  Future<Map<String, dynamic>> openConversation(
    String userId, {
    int? confirmCost,
  }) async => Map<String, dynamic>.from(
    await _call(
      'POST',
      '/v1/conversations',
      {'userId': userId},
      null,
      confirmCost == null ? null : {'Spend-Confirm': '$confirmCost'},
    ) as Map,
  );
  Future<Map<String, dynamic>> conversation(String id) async =>
      Map<String, dynamic>.from(
        await _call('GET', '/v1/conversations/$id') as Map,
      );
  Future<List<Map<String, dynamic>>> conversations({int limit = 50}) async =>
      _items(await _call('GET', '/v1/conversations?limit=$limit'));

  /// Pins or unpins this chat in the caller's list (409 PIN_LIMIT past five).
  Future<void> pinConversation(String id, bool pinned) =>
      _call('PUT', '/v1/conversations/$id/pin', {'pinned': pinned});

  /// Deletes this chat from the caller's list (restorable for 30 days; nothing is removed anywhere).
  Future<void> hideConversation(String id) =>
      _call('POST', '/v1/conversations/$id/hide');

  /// Brings a deleted chat back.
  Future<void> restoreConversation(String id) =>
      _call('POST', '/v1/conversations/$id/restore');

  /// The Deleted chats, and the ids of chats closed for the caller whose local history is to be wiped.
  Future<({List<Map<String, dynamic>> items, List<String> closedIds})>
  hiddenConversations() async {
    final data = await _call('GET', '/v1/conversations/hidden') as Map;
    return (
      items: _items(data),
      closedIds: [
        for (final id in (data['closedIds'] as List? ?? const []))
          if (id is String) id,
      ],
    );
  }

  /// Mutes this chat for the caller only, until [until] or until unmuted.
  Future<void> muteConversation(String id, bool muted, {DateTime? until}) =>
      _call(
        muted ? 'POST' : 'DELETE',
        '/v1/conversations/$id/mute',
        muted && until != null
            ? {'until': until.toUtc().toIso8601String()}
            : null,
      );

  /// Returns the server's createdAt for the stored message. [blobIds] claims
  /// uploaded attachment blobs for it; sending the same message id again is
  /// answered with the first result, so a retry never duplicates.
  ///
  /// [aux] marks the message as a reaction for the relay (`aux: "reaction"`):
  /// the relay then neither counts it unread nor pushes it. A reaction is not
  /// a member "sending a message", so it does not trigger [onSent].
  Future<DateTime?> send(
    String conversationId,
    Map<String, dynamic> message, {
    List<String> blobIds = const [],
    bool aux = false,
  }) async {
    final data = await _call(
      'POST',
      '/v1/conversations/$conversationId/messages',
      {
        ...message,
        if (blobIds.isNotEmpty) 'blobIds': blobIds,
        if (aux) 'aux': 'reaction',
      },
    );
    if (!aux) onSent?.call();
    return DateTime.tryParse((data as Map)['createdAt'] as String? ?? '');
  }

  /// Asks for a slot to upload one ciphertext blob of [sizeBytes] whose
  /// SHA-256 is [ctSha256] (base64). Refusals the app explains: 403
  /// ATTACHMENTS_NOT_ALLOWED (the peer has not replied), 413 TOO_LARGE, 429
  /// RATE_LIMITED or QUOTA, 503 CHAT_MEDIA_UNAVAILABLE.
  Future<BlobSlot> createBlobSlot(
    String conversationId,
    String role,
    int sizeBytes,
    String ctSha256,
  ) async {
    final data = await _call(
      'POST',
      '/v1/conversations/$conversationId/blobs',
      {'role': role, 'sizeBytes': sizeBytes, 'ctSha256': ctSha256},
    ) as Map;
    final id = data['blobId'],
        url = data['uploadUrl'],
        headers = data['headers'];
    final uri = url is String ? Uri.tryParse(url) : null;
    // Ciphertext may travel over plain http only in a debug build, to this machine's own storage.
    if (id is! String ||
        headers is! Map ||
        !isSecureTransport(uri) ||
        (data['method'] ?? 'PUT') != 'PUT') {
      throw const ChatFailure(
        'BAD_SLOT',
        'The photo couldn’t be uploaded. Try again.',
      );
    }
    return BlobSlot(id, url as String, {
      for (final e in headers.entries) '${e.key}': '${e.value}',
    }, DateTime.tryParse('${data['expiresAt']}'));
  }

  /// Tells the server the PUT is done; it checks the stored size. Safe to repeat.
  Future<void> completeBlob(String blobId) =>
      _call('POST', '/v1/blobs/$blobId/complete');

  /// A short-lived signed GET for a member of the conversation. 404 means the
  /// blob is gone or not for this caller, 410 BLOB_EXPIRED that it aged out.
  Future<({String url, int? sizeBytes})> blobDownloadUrl(
    String conversationId,
    String blobId,
  ) async {
    final data = await _call(
      'GET',
      '/v1/conversations/$conversationId/blobs/$blobId/url',
    ) as Map;
    final url = data['url'], uri = url is String ? Uri.tryParse(url) : null;
    // The same rule as the upload: https, or this machine's own storage in a debug build.
    if (!isSecureTransport(uri)) {
      throw const ChatFailure(
        'BAD_SLOT',
        'The photo couldn’t be opened. Try again.',
      );
    }
    return (url: url as String, sizeBytes: data['sizeBytes'] as int?);
  }

  /// Removes a blob this device uploaded (best effort; held evidence stays).
  Future<void> deleteBlob(String blobId) =>
      _call('DELETE', '/v1/blobs/$blobId');

  Future<void> markRead(String conversationId, DateTime upTo) => _call(
    'POST',
    '/v1/conversations/$conversationId/read',
    {'readAt': upTo.toUtc().toIso8601String()},
  );
  Future<int> unreadMessages() async =>
      ((await _call('GET', '/v1/conversations/unread')) as Map)['messages']
          as int;
  Future<List<Map<String, dynamic>>> myDevices() async =>
      _items(await _call('GET', '/v1/me/devices'));

  /// Devices of this account that another session removed in the last 30 days (`removed` of the same
  /// route as [myDevices]): `{deviceId, removedAt}`, newest first.
  Future<List<Map<String, dynamic>>> removedDevices() async {
    final data = await _call('GET', '/v1/me/devices');
    final raw = data is Map ? data['removed'] : null;
    return [
      if (raw is List)
        for (final item in raw)
          if (item is Map) Map<String, dynamic>.from(item),
    ];
  }

  Future<void> revokeDevice(String deviceId) =>
      _call('DELETE', '/v1/devices/$deviceId');
  Future<void> setPushToken(String deviceId, String provider, String token) =>
      _call('PUT', '/v1/devices/$deviceId/push', {
        'provider': provider,
        'token': token,
      });
  Future<void> clearPushToken(String deviceId) =>
      _call('DELETE', '/v1/devices/$deviceId/push');

  /// Push choices (`chat`, `social`), enforced by the server when it decides to push.
  Future<Map<String, bool>> notificationPrefs() async =>
      _prefs(await _call('GET', '/v1/me/notifications'));
  Future<Map<String, bool>> setNotificationPrefs(
    Map<String, bool> patch,
  ) async => _prefs(await _call('PATCH', '/v1/me/notifications', patch));
  Map<String, bool> _prefs(dynamic data) => {
    'chat': (data as Map)['chat'] != false,
    'social': data['social'] != false,
  };
  Future<List<Map<String, dynamic>>> inbox(String deviceId) async =>
      _items(await _call('GET', '/v1/devices/$deviceId/inbox?limit=100'));
  Future<void> ack(String deviceId, List<String> messageIds) => _call(
    'POST',
    '/v1/devices/$deviceId/inbox/ack',
    {'messageIds': messageIds},
  );

  // ------------------------------------------------------------ groups
  // docs/api/29-group-chat.md. A group's messages, blobs, read pointer, mute, pin, hide and restore use the
  // conversation routes above with the group id. A membership change that has others to tell carries its
  // encrypted control message inside the request, as `control: {messageId, senderDeviceId, envelopes}`.

  static String _g(String groupId) =>
      '/v1/groups/${Uri.encodeComponent(groupId)}';

  Map<String, dynamic> _map(dynamic data) =>
      Map<String, dynamic>.from(data as Map);

  /// Creates a group and invites [memberIds] (2 to 9). 409 CANNOT_ADD_MEMBER names one person in `details`.
  Future<Map<String, dynamic>> createGroup(
    String name,
    List<String> memberIds,
  ) async => _map(
    await _call('POST', '/v1/groups', {
      if (name.isNotEmpty) 'name': name,
      'memberIds': memberIds,
    }),
  );

  /// The caller's groups (active and closed), pinned first, then the most recent.
  Future<List<Map<String, dynamic>>> groups() async =>
      _items(await _call('GET', '/v1/groups'));

  /// The groups the caller deleted from their list and can still restore.
  Future<List<Map<String, dynamic>>> hiddenGroups() async =>
      _items(await _call('GET', '/v1/groups/hidden'));

  /// Invitations the caller has not answered.
  Future<List<Map<String, dynamic>>> groupInvites() async =>
      _items(await _call('GET', '/v1/groups/invites'));

  /// One group with its members, pending invites and the last membership events (404 for a non-member).
  Future<Map<String, dynamic>> group(String groupId) async =>
      _map(await _call('GET', _g(groupId)));

  /// Owner: invites 1 to 9 more people (409 GROUP_FULL, 409 CANNOT_ADD_MEMBER).
  Future<Map<String, dynamic>> inviteToGroup(
    String groupId,
    List<String> userIds,
  ) async =>
      _map(await _call('POST', '${_g(groupId)}/members', {'userIds': userIds}));

  /// An invited person joins; [control] is the encrypted `join` message for everyone already in the group
  /// (409 DEVICES_CHANGED when the device set no longer matches).
  Future<Map<String, dynamic>> acceptGroupInvite(
    String groupId,
    Map<String, dynamic> control,
  ) async =>
      _map(await _call('POST', '${_g(groupId)}/accept', {'control': control}));

  /// Declines an invitation; nobody is told.
  Future<void> declineGroupInvite(String groupId) =>
      _call('POST', '${_g(groupId)}/decline');

  /// Owner: renames the group; [control] is the encrypted `rename` message.
  Future<Map<String, dynamic>> renameGroup(
    String groupId,
    String name,
    Map<String, dynamic> control,
  ) async => _map(
    await _call('PATCH', _g(groupId), {'name': name, 'control': control}),
  );

  /// Owner: removes an active member ([control] is the encrypted `remove` message, which also goes to the
  /// removed person) or, with no [control], cancels a pending invite.
  Future<Map<String, dynamic>> removeGroupMember(
    String groupId,
    String userId, {
    Map<String, dynamic>? control,
  }) async => _map(
    await _call(
      'POST',
      '${_g(groupId)}/members/${Uri.encodeComponent(userId)}/remove',
      control == null ? null : {'control': control},
    ),
  );

  /// Leaves the group. [control] is the encrypted `leave` message (omitted when nobody else is in the group);
  /// the owner names [newOwnerId] when two or more other members remain.
  Future<void> leaveGroup(
    String groupId, {
    Map<String, dynamic>? control,
    String? newOwnerId,
  }) => _call('POST', '${_g(groupId)}/leave', {
    'control': ?control,
    'newOwnerId': ?newOwnerId,
  });
}
