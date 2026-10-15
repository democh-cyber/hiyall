import 'package:flutter/foundation.dart';

/// Hosts that mean "this machine" in a debug build: the host itself, and the
/// Android emulator's alias for it.
const _loopbackHosts = ['localhost', '127.0.0.1', '10.0.2.2'];

/// True for plain http to this machine's own services.
bool isLoopbackHttp(Uri? url) =>
    url != null && url.scheme == 'http' && _loopbackHosts.contains(url.host);

/// The one transport rule every network client follows: https, or plain http
/// to this machine in a debug build. Release builds require https. [debug]
/// defaults to [kDebugMode]; tests pass it to exercise both modes.
bool isSecureTransport(Uri? url, {bool? debug}) {
  if (url == null || url.host.isEmpty) return false;
  if (url.scheme == 'https') return true;
  return (debug ?? kDebugMode) && isLoopbackHttp(url);
}
