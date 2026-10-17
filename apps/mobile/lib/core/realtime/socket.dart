abstract class RealtimeSocket {
  Stream<String> get messages;
  void send(String message);
  Future<void> close();

  /// The server's WebSocket close code once [messages] is done, if any.
  /// 1008 means the session ended (revoked, expired, logged out, suspended);
  /// 1013 means "reconnect and resync".
  int? get closeCode;
}

/// The server refused the handshake (HTTP [status]). [code] is the error code of its answer when it could
/// be read (`UNAUTHENTICATED`: the token is not accepted; `APP_CHECK_REQUIRED`: the app, not the session,
/// is refused), null when it could not.
class RealtimeUnauthorized implements Exception {
  final int? status;
  final String? code;
  const RealtimeUnauthorized([this.status, this.code]);
  @override
  String toString() =>
      'Realtime refused the session ($status${code == null ? '' : ' $code'})';
}
