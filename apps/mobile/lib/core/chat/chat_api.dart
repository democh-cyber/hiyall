import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kDebugMode;

/// A chat API failure with the server's stable error code.
class ChatFailure implements Exception {
  final String code, message;
  final int? status;

  /// How long the server asked the caller to wait (Retry-After), when it did.
  final Duration? retryAfter;
  const ChatFailure(this.code, this.message, [this.status, this.retryAfter]);
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
  ]) async {
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
          },
        ),
      );
      return response.data!['data'];
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      if (status == 401) {
        if (retryToken == null) {
          final fresh = await tokenRefresher?.call();
          if (fresh != null && fresh != sent) {
            return _call(method, path, body, fresh);
          }
        }
        onUnauthorized?.call();
        throw ChatFailure(
          'UNAUTHENTICATED',
          'Your session has expired. Sign in again.',
          status,
        );
      }
      final data = error.response?.data;
      final failure = data is Map ? data['error'] : null;
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
  Future<Map<String, dynamic>> openConversation(String userId) async =>
      Map<String, dynamic>.from(
        await _call('POST', '/v1/conversations', {'userId': userId}) as Map,
      );
  Future<Map<String, dynamic>> conversation(String id) async =>
      Map<String, dynamic>.from(
        await _call('GET', '/v1/conversations/$id') as Map,
      );
  Future<List<Map<String, dynamic>>> conversations({int limit = 50}) async =>
      _items(await _call('GET', '/v1/conversations?limit=$limit'));

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
    final secure =
        uri?.scheme == 'https' ||
        (uri?.scheme == 'http' &&
            kDebugMode &&
            const ['localhost', '127.0.0.1', '10.0.2.2'].contains(uri?.host));
    if (id is! String ||
        headers is! Map ||
        !secure ||
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
    if (uri == null || !(uri.scheme == 'https' || uri.scheme == 'http')) {
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
}
