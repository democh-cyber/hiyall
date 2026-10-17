import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'socket.dart';

Future<RealtimeSocket> connectSocket(Uri url, String token) async {
  final WebSocket ws;
  try {
    ws = await WebSocket.connect(
      url.toString(),
      headers: {'Authorization': 'Bearer $token'},
    ).timeout(const Duration(seconds: 10));
  } on WebSocketException catch (error) {
    final status = error.httpStatusCode;
    if (status == 401 || status == 403) {
      // The handshake carries no body, so the reason is asked for with a plain request: the same address,
      // the same token.
      throw RealtimeUnauthorized(status, await refusalCode(url, token));
    }
    rethrow;
  }
  // The server pings every 25s; this detects a dead link from our side too.
  ws.pingInterval = const Duration(seconds: 30);
  return _IoSocket(ws);
}

/// The `error.code` the server answers [url] with when the token is refused, or null when that cannot be
/// read (offline, not JSON). A plain GET without the upgrade headers gets the same checks (App Check, then
/// the token) and answers with the JSON error instead of a bare refusal.
Future<String?> refusalCode(Uri url, String token) async {
  final plain = url.replace(scheme: url.scheme == 'wss' ? 'https' : 'http');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final request = await client
        .getUrl(plain)
        .timeout(const Duration(seconds: 5));
    request.headers.set('Authorization', 'Bearer $token');
    final response = await request.close().timeout(const Duration(seconds: 5));
    final body = StringBuffer();
    await for (final chunk in response.transform(utf8.decoder)) {
      body.write(chunk);
      if (body.length > 4096) return null;
    }
    final json = jsonDecode(body.toString());
    final error = json is Map ? json['error'] : null;
    final code = error is Map ? error['code'] : null;
    return code is String ? code : null;
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

class _IoSocket implements RealtimeSocket {
  final WebSocket ws;
  _IoSocket(this.ws);
  @override
  Stream<String> get messages => ws.where((m) => m is String).cast<String>();
  @override
  void send(String message) => ws.add(message);
  @override
  Future<void> close() => ws.close();
  @override
  int? get closeCode => ws.closeCode;
}
