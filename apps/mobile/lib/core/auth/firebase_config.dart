import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import '../error_reporting.dart';

/// Firebase project keys, supplied per build so no key is committed.
/// `scripts/firebase-setup.sh` writes them all to `config/firebase.local.json`,
/// which `scripts/dev-mobile.sh` passes with `--dart-define-from-file`.
///
/// Android, iOS and web each have their own app id and API key; the one for the
/// platform being built is used, falling back to FIREBASE_APP_ID and
/// FIREBASE_API_KEY when a single value should apply everywhere.
///
///   flutter run --dart-define-from-file=../../config/firebase.local.json
///
/// or, by hand:
///
///   flutter run \
///     --dart-define=FIREBASE_API_KEY_ANDROID=...   (or _IOS / _WEB / FIREBASE_API_KEY) \
///     --dart-define=FIREBASE_PROJECT_ID=... \
///     --dart-define=FIREBASE_MESSAGING_SENDER_ID=... \
///     --dart-define=FIREBASE_APP_ID_ANDROID=...   (or _IOS / _WEB / FIREBASE_APP_ID)
///     --dart-define=FIREBASE_AUTH_DOMAIN=`<project>.firebaseapp.com`   (web)
abstract final class FirebaseConfig {
  static const _apiKey = String.fromEnvironment('FIREBASE_API_KEY');
  static const _apiKeyAndroid = String.fromEnvironment(
    'FIREBASE_API_KEY_ANDROID',
  );
  static const _apiKeyIos = String.fromEnvironment('FIREBASE_API_KEY_IOS');
  static const _apiKeyWeb = String.fromEnvironment('FIREBASE_API_KEY_WEB');
  static const projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
  static const iosBundleId = String.fromEnvironment('FIREBASE_IOS_BUNDLE_ID');
  static const senderId = String.fromEnvironment(
    'FIREBASE_MESSAGING_SENDER_ID',
  );
  static const authDomain = String.fromEnvironment('FIREBASE_AUTH_DOMAIN');
  static const storageBucket = String.fromEnvironment(
    'FIREBASE_STORAGE_BUCKET',
  );
  static const _appId = String.fromEnvironment('FIREBASE_APP_ID');
  static const _appIdAndroid = String.fromEnvironment(
    'FIREBASE_APP_ID_ANDROID',
  );
  static const _appIdIos = String.fromEnvironment('FIREBASE_APP_ID_IOS');
  static const _appIdWeb = String.fromEnvironment('FIREBASE_APP_ID_WEB');

  static String get appId =>
      _forPlatform(web: _appIdWeb, android: _appIdAndroid, ios: _appIdIos) ??
      _appId;

  static String get apiKey =>
      _forPlatform(web: _apiKeyWeb, android: _apiKeyAndroid, ios: _apiKeyIos) ??
      _apiKey;

  /// The platform's own value, or null when it wasn't supplied.
  static String? _forPlatform({
    required String web,
    required String android,
    required String ios,
  }) {
    final specific = kIsWeb
        ? web
        : switch (defaultTargetPlatform) {
            TargetPlatform.android => android,
            TargetPlatform.iOS || TargetPlatform.macOS => ios,
            _ => '',
          };
    return specific.isNotEmpty ? specific : null;
  }

  /// Set when [initialize] threw (a malformed key, a missing platform file).
  /// The app then behaves as if Firebase were not configured: Welcome says
  /// sign-in isn't available instead of the app failing to open.
  static bool initFailed = false;

  static bool get isConfigured =>
      !initFailed &&
      apiKey.isNotEmpty &&
      projectId.isNotEmpty &&
      appId.isNotEmpty;

  static FirebaseOptions get options => FirebaseOptions(
    apiKey: apiKey,
    appId: appId,
    messagingSenderId: senderId,
    projectId: projectId,
    authDomain: authDomain.isEmpty ? null : authDomain,
    storageBucket: storageBucket.isEmpty ? null : storageBucket,
    iosBundleId: iosBundleId.isEmpty ? null : iosBundleId,
  );

  /// Starts Firebase when keys were supplied. Safe to call once at startup;
  /// never throws, so a bad configuration cannot blank the first screen.
  /// Returns false when Firebase was configured but failed to start.
  ///
  /// [start] and [configured] exist for tests.
  static Future<bool> initialize({
    Future<Object?> Function(FirebaseOptions options)? start,
    bool? configured,
  }) async {
    if (!(configured ?? isConfigured)) return true;
    try {
      await (start ?? (o) => Firebase.initializeApp(options: o))(options)
          .timeout(const Duration(seconds: 15));
      return true;
    } catch (error, stack) {
      initFailed = true;
      debugPrint('Firebase failed to start: ${error.runtimeType}');
      ErrorReporting.capture(error, stack);
      return false;
    }
  }
}

/// Sign-in methods offered on the screens. Facebook is built but switched off
/// until a Meta app is connected; build with `--dart-define=ENABLE_FACEBOOK_LOGIN=true`
/// to show it.
///
/// Sign in with Apple is always offered on iOS and macOS (App Store guideline 4.8).
/// On the web it needs an Apple Services ID configured in Firebase, so it only
/// shows when the build says so with `--dart-define=APPLE_SIGN_IN_WEB=true`.
/// It is never offered on Android, where Firebase would also need a Services ID.
abstract final class AuthProviders {
  static const facebook = bool.fromEnvironment('ENABLE_FACEBOOK_LOGIN');
  static const appleWeb = bool.fromEnvironment('APPLE_SIGN_IN_WEB');

  /// Whether the Apple button is shown. The arguments exist so tests can inject a
  /// platform; the screens call it with none and get the running platform.
  static bool appleAvailable({
    bool? web,
    TargetPlatform? platform,
    bool? webEnabled,
  }) {
    if (web ?? kIsWeb) return webEnabled ?? appleWeb;
    return switch (platform ?? defaultTargetPlatform) {
      TargetPlatform.iOS || TargetPlatform.macOS => true,
      _ => false,
    };
  }
}
