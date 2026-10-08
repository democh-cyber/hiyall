import 'dart:async';
import 'dart:io';

import 'socket.dart';

Future<RealtimeSocket> connectSocket(Uri url, String token) async {
  final ws = await WebSocket.connect(
    url.toString(),
    headers: {'Authorization': 'Bearer $token'},
  ).timeout(const Duration(seconds: 10));
  // The server pings every 25s; this detects a dead link from our side too.
  ws.pingInterval = const Duration(seconds: 30);
  return _IoSocket(ws);
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
}
