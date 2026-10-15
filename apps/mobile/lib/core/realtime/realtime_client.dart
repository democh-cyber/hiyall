import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../api_config.dart';
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

  /// Reads the newest token on every (re)connect; Firebase rotates it hourly.
  final String Function()? tokenOf;

  /// Asks the identity provider for a brand-new token, after the server said
  /// the session ended. Without it, [tokenOf] is read again.
  final Future<String?> Function()? refreshToken;

  /// Called once the server keeps refusing the session after a fresh token:
  /// the session really ended, so the app should sign out rather than retry.
  final void Function()? onSessionEnded;
  final Future<RealtimeSocket> Function(Uri, String) _connect;
  RealtimeClient(
    String apiBase,
    this.token, {
    this.tokenOf,
    this.refreshToken,
    this.onSessionEnded,
    Future<RealtimeSocket> Function(Uri, String)? connect,

    /// Overrides [kDebugMode] for the transport check (tests).
    bool? debugBuild,
  }) : url = _socketUrl(apiBase),
       _secure = isSecureTransport(Uri.tryParse(apiBase), debug: debugBuild),
       _connect = connect ?? connectSocket;

  /// False when the API address is not https (or this machine's own http in a
  /// debug build): the token is then never sent and the client does not run.
  final bool _secure;

  /// WebSocket close code for "policy violation": the session ended.
  static const sessionEndedCode = 1008;

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

  /// Bumped by every start and stop; a handshake that finishes under an older
  /// generation belongs to a connection nobody wants any more.
  int _generation = 0;
  bool _running = false, _disposed = false;

  /// Set after the server ended the session and one reconnect with a fresh
  /// token is under way; a second refusal stops the client.
  bool _retryingEndedSession = false;

  /// "ready" arrives on every (re)connect; treat it as "resync now".
  Stream<RealtimeEvent> get events => _events.stream;

  void start() {
    if (_running || _disposed || !_secure) return;
    _running = true;
    _generation++;
    _retryingEndedSession = false;
    _open();
  }

  /// Closes the socket, e.g. when the app goes to the background.
  void stop() {
    _running = false;
    _generation++;
    _retry?.cancel();
    _subscription?.cancel();
    _subscription = null;
    _socket?.close();
    _socket = null;
    _setConnected(false);
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

  Future<void> _open({String? freshToken}) async {
    final generation = _generation;
    bool current() => _running && !_disposed && generation == _generation;
    try {
      final socket = await _connect(
        url,
        freshToken ?? tokenOf?.call() ?? token,
      );
      if (!current()) {
        await socket.close();
        return;
      }
      // A retry timer and a fresh start can overlap; keep only the newest.
      _subscription?.cancel();
      _socket?.close();
      _socket = socket;
      _attempt = 0;
      _setConnected(true);
      _subscription = socket.messages.listen(
        _receive,
        onDone: () => _lost(socket),
        onError: (_) => _lost(socket),
        cancelOnError: true,
      );
    } on UnsupportedError {
      if (generation == _generation) _running = false;
    } on RealtimeUnauthorized {
      if (current()) _sessionEnded();
    } catch (_) {
      if (current()) _schedule();
    }
  }

  /// The server refused this session. Try once more with a fresh token (the
  /// old one may simply have expired); if that is refused too, stop and let
  /// the session layer sign out instead of reconnecting with a dead token.
  Future<void> _sessionEnded() async {
    _setConnected(false);
    if (_retryingEndedSession) {
      stop();
      onSessionEnded?.call();
      return;
    }
    _retryingEndedSession = true;
    _retry?.cancel();
    final generation = _generation;
    String? fresh;
    try {
      fresh = await refreshToken?.call();
    } catch (_) {
      // Fall back to whatever tokenOf reports now.
    }
    if (!_running || _disposed || generation != _generation) return;
    await _open(freshToken: fresh);
  }

  void _setConnected(bool value) {
    if (!_disposed) connected.value = value;
  }

  void _receive(String raw) {
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      // The server accepted the session again.
      if (json['type'] == 'ready') _retryingEndedSession = false;
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

  void _lost(RealtimeSocket socket) {
    if (!identical(socket, _socket)) return;
    _socket = null;
    _subscription = null;
    _setConnected(false);
    if (socket.closeCode == sessionEndedCode) {
      _sessionEnded();
    } else {
      _schedule();
    }
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
