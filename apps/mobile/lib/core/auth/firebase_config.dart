import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

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

  static bool get isConfigured =>
      apiKey.isNotEmpty && projectId.isNotEmpty && appId.isNotEmpty;

  static FirebaseOptions get options => FirebaseOptions(
    apiKey: apiKey,
    appId: appId,
    messagingSenderId: senderId,
    projectId: projectId,
    authDomain: authDomain.isEmpty ? null : authDomain,
    storageBucket: storageBucket.isEmpty ? null : storageBucket,
    iosBundleId: iosBundleId.isEmpty ? null : iosBundleId,
  );

  /// Starts Firebase when keys were supplied. Safe to call once at startup.
  static Future<void> initialize() async {
    if (!isConfigured) return;
    await Firebase.initializeApp(options: options);
  }
}

/// Sign-in methods offered on the screens. Facebook is built but switched off
/// until a Meta app is connected; build with `--dart-define=ENABLE_FACEBOOK_LOGIN=true`
/// to show it.
abstract final class AuthProviders {
  static const facebook = bool.fromEnvironment('ENABLE_FACEBOOK_LOGIN');
}

/// Legal pages, supplied per build. Without them the sign-up screens still
/// name the documents but cannot link to them.
abstract final class LegalLinks {
  static const terms = String.fromEnvironment('TERMS_URL');
  static const privacy = String.fromEnvironment('PRIVACY_URL');
}
