import 'socket.dart';

/// Web keeps polling: browsers cannot attach an Authorization header to a
/// WebSocket, and bearer tokens are never put in URLs.
Future<RealtimeSocket> connectSocket(Uri url, String token) => Future.error(
  UnsupportedError('Realtime is not available on this platform'),
);
