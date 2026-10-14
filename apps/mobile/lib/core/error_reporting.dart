import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'app_info.dart';

/// Crash and error reporting through Sentry, switched on only when the build
/// sets `--dart-define=SENTRY_DSN=...`. Without it nothing is initialised and
/// [ErrorReporting.capture] only logs in debug builds.
///
/// Privacy rules (the app holds end-to-end encrypted chats and signed photo
/// URLs): no default PII, no request bodies or headers, URL query strings
/// removed, ids in paths collapsed, tokens and emails masked, and every
/// console or chat breadcrumb dropped. See [scrubEvent] and [scrubBreadcrumb].
abstract final class ErrorReporting {
  static const dsn = String.fromEnvironment('SENTRY_DSN');
  static bool get enabled => dsn.isNotEmpty && _started;
  static bool _started = false;

  /// Starts Sentry (when configured) and installs the global error handlers,
  /// then runs [app]. Never throws: a reporting failure must not stop launch.
  static Future<void> start(FutureOr<void> Function() app) async {
    if (dsn.isNotEmpty) {
      try {
        await SentryFlutter.init(configure);
        _started = true;
      } catch (error) {
        debugPrint('Error reporting unavailable: ${error.runtimeType}');
      }
    }
    installHandlers();
    await app();
  }

  /// The Sentry options. Public so tests can check them.
  static void configure(SentryFlutterOptions o) {
    o
      ..dsn = dsn
      ..environment = AppInfo.environment
      ..release = AppInfo.release
      ..dist = AppInfo.buildNumber.isEmpty ? null : AppInfo.buildNumber
      ..sendDefaultPii = false
      ..attachScreenshot = false
      ..enablePrintBreadcrumbs = false
      ..maxRequestBodySize = MaxRequestBodySize.never
      ..tracesSampleRate = 0
      ..beforeSend = scrubEvent
      ..beforeBreadcrumb = scrubBreadcrumb;
  }

  /// Routes framework and uncaught async errors to [capture]. Replaces the
  /// handlers Sentry's own integrations set, so each error is reported once,
  /// through [scrubEvent] like everything else.
  static void installHandlers() {
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      capture(details.exception, details.stack, fatal: !details.silent);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      capture(error, stack, fatal: true);
      return true;
    };
  }

  /// Reports one error. Details stay out of the UI: screens show
  /// `friendlyError` text and the specifics land here.
  static void capture(Object error, StackTrace? stack, {bool fatal = false}) {
    if (kDebugMode) {
      debugPrint(
        'Captured ${fatal ? 'fatal ' : ''}error: ${scrubText('$error')}',
      );
    }
    if (!enabled) return;
    unawaited(
      Sentry.captureException(
        error,
        stackTrace: stack,
        withScope: (scope) =>
            scope.level = fatal ? SentryLevel.fatal : SentryLevel.error,
      ).then((_) {}, onError: (_) {}),
    );
  }
}

final _url = RegExp(r'''[a-zA-Z][a-zA-Z0-9+.-]*://[^\s"'<>]+''');

/// An in-app route with a query, such as `/discover?q=x`.
final _routeQuery = RegExp(r'''(\B/[A-Za-z0-9_\-./:]+)\?[^\s"'<>]*''');
final _uuid = RegExp(
  r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}',
);
final _bearer = RegExp(r'Bearer\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false);
final _jwt = RegExp(r'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+');
final _email = RegExp(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}');

/// Drops a URL's query string and fragment (signed URLs carry their signature
/// there; chat routes carry the peer's name) and collapses ids in the path.
String scrubUrl(String url) {
  var cut = url;
  final q = cut.indexOf('?');
  if (q >= 0) cut = cut.substring(0, q);
  final h = cut.indexOf('#');
  if (h >= 0) cut = cut.substring(0, h);
  return cut.replaceAll(_uuid, ':id');
}

/// Masks credentials, emails and URL queries anywhere in free text.
String scrubText(String text) => text
    .replaceAllMapped(_url, (m) => scrubUrl(m[0]!))
    .replaceAllMapped(_routeQuery, (m) => m[1]!)
    .replaceAll(_bearer, 'Bearer [redacted]')
    .replaceAll(_jwt, '[token]')
    .replaceAll(_email, '[email]')
    .replaceAll(_uuid, ':id');

/// An app route such as `/chats/<id>?peer=…&name=Niko` becomes `/chats/:id`.
String scrubRoute(String route) => scrubUrl(route);

bool _fromChat(Breadcrumb b) {
  bool chatty(Object? v) =>
      v is String && (v.contains('/chats') || v.contains('conversation'));
  if ((b.category ?? '').toLowerCase().contains('chat')) return true;
  if (chatty(b.message)) return true;
  return b.data?.values.any(chatty) ?? false;
}

/// Keeps navigation and lifecycle crumbs, without query strings; drops every
/// console line and anything about a chat.
Breadcrumb? scrubBreadcrumb(Breadcrumb? crumb, Hint hint) {
  if (crumb == null) return null;
  final category = (crumb.category ?? '').toLowerCase();
  if (category == 'console' || category == 'print' || category == 'log') {
    return null;
  }
  if (_fromChat(crumb)) return null;
  crumb.message = crumb.message == null ? null : scrubText(crumb.message!);
  final data = crumb.data;
  if (data != null) {
    crumb.data = {
      for (final e in data.entries)
        // HTTP crumbs may carry bodies or headers; keep only plain facts.
        if (!const {
          'request_body',
          'response_body',
          'headers',
          'request_headers',
          'response_headers',
          'http.query',
          'http.fragment',
        }.contains(e.key))
          e.key: e.value is String ? scrubText(e.value as String) : e.value,
    };
  }
  return crumb;
}

/// Last stop before an event leaves the device.
SentryEvent? scrubEvent(SentryEvent event, Hint hint) {
  event.user = null;
  event.serverName = null;
  final request = event.request;
  if (request != null) {
    event.request = SentryRequest(
      url: request.url == null ? null : scrubUrl(request.url!),
      method: request.method,
      headers: {
        for (final h in request.headers.entries)
          if (const {
            'content-type',
            'x-client-platform',
            'x-client-version',
          }.contains(h.key.toLowerCase()))
            h.key: h.value,
      },
    );
  }
  final message = event.message;
  if (message != null) {
    event.message = SentryMessage(scrubText(message.formatted));
  }
  for (final e in event.exceptions ?? const <SentryException>[]) {
    if (e.value != null) e.value = scrubText(e.value!);
  }
  final crumbs = event.breadcrumbs;
  if (crumbs != null) {
    event.breadcrumbs = [for (final b in crumbs) ?scrubBreadcrumb(b, hint)];
  }
  if (event.transaction != null) {
    event.transaction = scrubRoute(event.transaction!);
  }
  return event;
}
