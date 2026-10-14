part of 'api.dart';

/// Whether the account is scheduled for deletion, and until when it can be kept
/// (docs/api/22-account-deletion-and-export.md).
class DeletionStatus {
  final bool pending;
  final DateTime? scheduledAt, dueAt;

  /// True while pending and before [dueAt].
  final bool canCancel;
  const DeletionStatus({
    this.pending = false,
    this.scheduledAt,
    this.dueAt,
    this.canCancel = false,
  });
  factory DeletionStatus.fromJson(Map<String, dynamic> json) => DeletionStatus(
    pending: json['pending'] as bool? ?? false,
    scheduledAt: json['scheduledAt'] == null
        ? null
        : DateTime.parse(json['scheduledAt'] as String),
    dueAt: json['dueAt'] == null
        ? null
        : DateTime.parse(json['dueAt'] as String),
    canCancel: json['canCancel'] as bool? ?? false,
  );
}

/// The member's own data export and account deletion. A member whose account is
/// scheduled for deletion can reach only [deletionStatus], [cancelDeletion]
/// and [logout]; the server refuses everything else.
mixin AccountApi {
  Future<dynamic> _request(
    String method,
    String path, {
    String? token,
    Object? body,
    // ignore: unused_element_parameter
    String? version,
  });

  Dio get _dio;

  Future<DeletionStatus> deletionStatus(Session s) async =>
      DeletionStatus.fromJson(
        await _request('GET', '/v1/me/deletion', token: s.token)
            as Map<String, dynamic>,
      );

  /// Schedules deletion in 30 days. Throws [ApiFailure] with code
  /// `REAUTH_REQUIRED` when the sign-in is older than five minutes. Apple accounts send the one-time
  /// [appleAuthorizationCode] from their Apple re-sign-in so the server can revoke Apple's token.
  Future<DeletionStatus> scheduleDeletion(
    Session s,
    String confirmUsername, {
    String? appleAuthorizationCode,
  }) async => DeletionStatus.fromJson(
    await _request(
      'POST',
      '/v1/me/deletion',
      token: s.token,
      body: {
        'confirmUsername': confirmUsername,
        'appleAuthorizationCode': ?appleAuthorizationCode,
      },
    ) as Map<String, dynamic>,
  );

  /// Keeps the account. Throws code `DELETION_WINDOW_CLOSED` once the 30 days passed.
  Future<DeletionStatus> cancelDeletion(Session s) async {
    try {
      return DeletionStatus.fromJson(
        await _request('DELETE', '/v1/me/deletion', token: s.token)
            as Map<String, dynamic>,
      );
    } on ApiFailure catch (error) {
      if (error.status == 404) {
        throw const ApiFailure(
          'Your account is not scheduled for deletion.',
          404,
          'NOT_FOUND',
        );
      }
      rethrow;
    }
  }

  /// The JSON export as bytes. The server allows one a day: that refusal is an
  /// [ApiFailure] with code `RATE_LIMITED` and the wait in `retryAfter`.
  Future<List<int>> exportData(Session s) async {
    if (_dio.options.baseUrl.isEmpty) {
      throw const ApiFailure('The service is not configured yet.');
    }
    try {
      final response = await _dio.get<List<int>>(
        '/v1/me/export',
        options: Options(
          responseType: ResponseType.bytes,
          receiveTimeout: const Duration(minutes: 2),
          headers: {'Authorization': 'Bearer ${s.token}'},
        ),
      );
      return response.data ?? const <int>[];
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      var code = '', message = '';
      try {
        final body = error.response?.data;
        if (body is List<int>) {
          final reply = jsonDecode(utf8.decode(body));
          if (reply is Map && reply['error'] is Map) {
            code = (reply['error'] as Map)['code'] as String? ?? '';
            message = (reply['error'] as Map)['message'] as String? ?? '';
          }
        }
      } catch (_) {
        // Not JSON: fall through to the generic copy.
      }
      final wait = int.tryParse(
        error.response?.headers.value('retry-after') ?? '',
      );
      if (status == 429) {
        throw ApiFailure(
          message.isEmpty
              ? 'You can download your data once a day. Try again later.'
              : message,
          status,
          code.isEmpty ? 'RATE_LIMITED' : code,
          wait == null || wait < 1 ? null : Duration(seconds: wait),
        );
      }
      if (status == 401) {
        throw const ApiFailure('Your session has expired. Sign in again.', 401);
      }
      throw ApiFailure(
        'Could not prepare your data. Check your connection and try again.',
        status,
        code.isEmpty ? null : code,
      );
    }
  }
}
