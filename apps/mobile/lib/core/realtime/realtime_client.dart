import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'connect_stub.dart' if (dart.library.io) 'connect_io.dart';
import 'socket.dart';

class RealtimeEvent {
  final String type;
  final Map<String, String> data;
  const RealtimeEvent(this.type, [this.data = const {}]);
}

/// One authenticated socket to /v1/realtime. Events are wake-up signals only;
/// callers fetch the actual state over HTTP. Reconnects with jittered
/// exponential backoff so a server restart doesn't cause a reconnect storm.
class RealtimeClient {
  final Uri url;
  final String token;
  final Future<RealtimeSocket> Function(Uri, String) _connect;
  RealtimeClient(
    String apiBase,
    this.token, {
    Future<RealtimeSocket> Function(Uri, String)? connect,
  }) : url = _socketUrl(apiBase),
       _connect = connect ?? connectSocket;

  static Uri _socketUrl(String base) {
    final api = Uri.parse(base);
    return api.replace(
      scheme: api.scheme == 'https' ? 'wss' : 'ws',
      path: '${api.path.replaceAll(RegExp(r'/$'), '')}/v1/realtime',
    );
  }

  final _events = StreamController<RealtimeEvent>.broadcast();
  final connected = ValueNotifier(false);
  final _random = Random();
  RealtimeSocket? _socket;
  StreamSubscription<String>? _subscription;
  Timer? _retry;
  int _attempt = 0;
  bool _running = false, _disposed = false;

  /// "ready" arrives on every (re)connect; treat it as "resync now".
  Stream<RealtimeEvent> get events => _events.stream;

  void start() {
    if (_running || _disposed) return;
    _running = true;
    _open();
  }

  /// Closes the socket, e.g. when the app goes to the background.
  void stop() {
    _running = false;
    _retry?.cancel();
    _subscription?.cancel();
    _socket?.close();
    _socket = null;
    connected.value = false;
  }

  void dispose() {
    stop();
    _disposed = true;
    _events.close();
    connected.dispose();
  }

  void sendTyping(String conversationId) {
    _socket?.send(
      jsonEncode({'type': 'typing', 'conversationId': conversationId}),
    );
  }

  Future<void> _open() async {
    try {
      final socket = await _connect(url, token);
      if (!_running) {
        await socket.close();
        return;
      }
      _socket = socket;
      _attempt = 0;
      connected.value = true;
      _subscription = socket.messages.listen(
        _receive,
        onDone: _lost,
        onError: (_) => _lost(),
        cancelOnError: true,
      );
    } on UnsupportedError {
      _running = false;
    } catch (_) {
      _schedule();
    }
  }

  void _receive(String raw) {
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final data =
          (json['data'] as Map?)?.map(
            (k, v) => MapEntry(k as String, v.toString()),
          ) ??
          const <String, String>{};
      if (!_events.isClosed) {
        _events.add(RealtimeEvent(json['type'] as String, data));
      }
    } catch (_) {
      // Ignore malformed frames; the next signal or poll catches up.
    }
  }

  void _lost() {
    _socket = null;
    connected.value = false;
    _schedule();
  }

  void _schedule() {
    if (!_running) return;
    final cap = min(30, 1 << min(_attempt, 5));
    _attempt++;
    final delay = Duration(
      milliseconds: (cap * 500) + _random.nextInt(cap * 500 + 1),
    );
    _retry?.cancel();
    _retry = Timer(delay, _open);
  }
}
