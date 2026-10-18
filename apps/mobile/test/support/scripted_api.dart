import 'dart:async';

import 'package:hiyall/core/api.dart';

import '../widget_test.dart' show FakeApi;

/// A fake API for the calls that go through `ApiClient.send` (notification choices, notices, support).
/// Each route is `'METHOD /path'` (no query); a route with no handler answers like an unreachable server.
class ScriptedApi extends FakeApi {
  final routes =
      <String, FutureOr<dynamic> Function(Object? body, String path)>{};

  /// Every call as `'METHOD /full/path?query'`, and its body.
  final sent = <String>[];
  final bodies = <Object?>[];

  void on(
    String route,
    FutureOr<dynamic> Function(Object? body, String path) handler,
  ) => routes[route] = handler;

  int count(String route) =>
      sent.where((c) => c.split('?').first == route).length;

  @override
  Future<dynamic> send(
    Session s,
    String method,
    String path, {
    Object? body,
  }) async {
    sent.add('$method $path');
    bodies.add(body);
    final handler = routes['$method ${path.split('?').first}'];
    if (handler == null) {
      throw const ApiFailure(
        'You’re offline. Check your connection and try again.',
        null,
        'OFFLINE',
      );
    }
    return handler(body, path);
  }
}
