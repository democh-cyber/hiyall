import 'package:dio/dio.dart';

/// A chat API failure with the server's stable error code.
class ChatFailure implements Exception {
  final String code, message;
  final int? status;
  const ChatFailure(this.code, this.message, [this.status]);
  @override
  String toString() => message;
}

/// Thin client for the ciphertext relay. Pure Dart so tests and the command-line
/// peer can use it; it only ever carries public keys and ciphertext.
class ChatApi {
  final Dio _dio;
  final String token;
  ChatApi(String baseUrl, this.token, {Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: baseUrl,
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 15),
              contentType: 'application/json',
            ),
          );

  Future<dynamic> _call(String method, String path, [Object? body]) async {
    try {
      final response = await _dio.request<Map<String, dynamic>>(
        path,
        data: body,
        options: Options(
          method: method,
          headers: {'Authorization': 'Bearer $token'},
        ),
      );
      return response.data!['data'];
    } on DioException catch (error) {
      final data = error.response?.data;
      final failure = data is Map ? data['error'] : null;
      throw ChatFailure(
        failure is Map ? '${failure['code']}' : 'NETWORK',
        failure is Map
            ? '${failure['message']}'
            : 'Could not reach the chat service. Check your connection.',
        error.response?.statusCode,
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
  Future<List<Map<String, dynamic>>> conversations() async =>
      _items(await _call('GET', '/v1/conversations?limit=50'));
  Future<void> send(String conversationId, Map<String, dynamic> message) =>
      _call('POST', '/v1/conversations/$conversationId/messages', message);
  Future<List<Map<String, dynamic>>> inbox(String deviceId) async =>
      _items(await _call('GET', '/v1/devices/$deviceId/inbox?limit=100'));
  Future<void> ack(String deviceId, List<String> messageIds) => _call(
    'POST',
    '/v1/devices/$deviceId/inbox/ack',
    {'messageIds': messageIds},
  );
}
