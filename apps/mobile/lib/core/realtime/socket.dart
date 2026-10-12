abstract class RealtimeSocket {
  Stream<String> get messages;
  void send(String message);
  Future<void> close();

  /// The server's WebSocket close code once [messages] is done, if any.
  /// 1008 means the session ended (revoked, expired, logged out, suspended);
  /// 1013 means "reconnect and resync".
  int? get closeCode;
}

/// The server refused the handshake because the token isn't accepted.
class RealtimeUnauthorized implements Exception {
  final int? status;
  const RealtimeUnauthorized([this.status]);
  @override
  String toString() => 'Realtime refused the session ($status)';
}
