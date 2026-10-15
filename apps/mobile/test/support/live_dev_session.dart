import 'package:dio/dio.dart';
import 'package:hiyall/core/api.dart';

/// Signs in through the local API's development-only endpoint, for the live
/// tests that run against a server started on this machine. The shipped app
/// has no such call; this helper is the only client of it.
Future<Session> liveDevSession(String userId) async {
  const base = String.fromEnvironment('API_BASE_URL');
  final response = await Dio(BaseOptions(baseUrl: base))
      .post<Map>('/dev/session', data: {'userId': userId});
  // The API wraps its answers in {"data": ...}.
  final body = response.data!;
  final data = (body['data'] ?? body) as Map;
  return Session(data['accessToken'] as String, data['userId'] as String);
}
