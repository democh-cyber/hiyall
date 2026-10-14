import 'package:flutter/foundation.dart' show visibleForTesting;

/// Build facts supplied as dart-defines by `scripts/build-release.sh`, with
/// development fallbacks so `flutter run` and tests work without them.
///
/// No package is needed to read the version: the release script passes the
/// same value to `--build-name` and to `APP_VERSION`, so they cannot drift.
abstract final class AppInfo {
  /// The marketing version, `MAJOR.MINOR.PATCH`. Sent on every API call as
  /// `X-Client-Version` so the server can retire a broken client (426).
  static const version = String.fromEnvironment(
    'APP_VERSION',
    defaultValue: '0.1.0',
  );

  /// The store build number; empty in development builds.
  static const buildNumber = String.fromEnvironment('APP_BUILD_NUMBER');

  /// `production`, `staging` or `development` (the default for local runs).
  static const environment = String.fromEnvironment(
    'APP_ENV',
    defaultValue: 'development',
  );

  /// Shown in Settings → About, e.g. "0.1.0 (42)".
  static String get display =>
      buildNumber.isEmpty ? version : '$version ($buildNumber)';

  /// Sentry's release name: `hiyall@0.1.0+42`.
  static String get release =>
      'hiyall@$version${buildNumber.isEmpty ? '' : '+$buildNumber'}';

  /// Store pages opened by the "Update Hiyall" screen. Placeholders until the
  /// listings exist; the release script passes the real ones.
  static const appStoreUrl = String.fromEnvironment(
    'APP_STORE_URL',
    defaultValue: 'https://apps.apple.com/app/idREPLACE_ME',
  );
  static const playStoreUrl = String.fromEnvironment(
    'PLAY_STORE_URL',
    defaultValue: 'https://play.google.com/store/apps/details?id=REPLACE_ME',
  );
}

/// Compile-time switches for features that are built but not offered yet.
abstract final class FeatureFlags {
  static const _events = bool.fromEnvironment('ENABLE_EVENTS');
  static bool? _override;

  /// Events and Moments. Off for V1 (`--dart-define=ENABLE_EVENTS=true` turns
  /// them back on): creation, discovery and the sub-space tabs are hidden, and
  /// an event or Moment someone links to still opens, read-only.
  static bool get events => _override ?? _events;

  /// Tests flip the flag; pass null to restore the build's value.
  @visibleForTesting
  static set eventsOverride(bool? value) => _override = value;
}
