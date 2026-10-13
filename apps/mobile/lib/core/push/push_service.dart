import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/firebase_config.dart';

/// Where the system's notification permission stands.
enum PushPermission { notAsked, granted, denied }

/// A tap on a notification: a conversation, or Activity for everything social.
class PushTap {
  final String kind;
  final String? conversationId;
  const PushTap.chat(String this.conversationId) : kind = 'chat';
  const PushTap.social() : kind = 'social', conversationId = null;

  static final _id = RegExp(r'^[0-9a-fA-F-]{36}$');

  /// The payload the server sends is `{kind: chat, conversationId}` or
  /// `{kind: social, event}`; anything else is ignored.
  static PushTap? fromData(Map<String, dynamic> data) {
    switch (data['kind']) {
      case 'chat':
        final id = data['conversationId'];
        return id is String && _id.hasMatch(id) ? PushTap.chat(id) : null;
      case 'social':
        return const PushTap.social();
    }
    return null;
  }

  /// Where the app goes. A conversation loads its own peer from the id.
  String get location =>
      kind == 'chat' ? '/chats/$conversationId' : '/notifications';
}

/// What the app needs from the platform's push stack. A fake stands in for it
/// in tests; web and desktop get [NoopPushService].
abstract class PushService {
  /// False where push cannot work (web, desktop, Firebase keys not supplied).
  bool get supported;
  Future<PushPermission> permission();

  /// Shows the system's permission dialog (once; later calls just report).
  Future<PushPermission> requestPermission();

  /// The FCM registration token, null when there is none yet (for example
  /// iOS before Apple has issued its token; [tokenRefresh] then fires).
  Future<String?> token();
  Stream<String> get tokenRefresh;

  /// Invalidates the token on this device, so a signed-out phone is not woken.
  Future<void> deleteToken();

  /// Notifications tapped while the app was in the background.
  Stream<PushTap> get taps;

  /// The notification whose tap started the app from closed, once.
  Future<PushTap?> initialTap();
}

class NoopPushService implements PushService {
  const NoopPushService();
  @override
  bool get supported => false;
  @override
  Future<PushPermission> permission() async => PushPermission.denied;
  @override
  Future<PushPermission> requestPermission() async => PushPermission.denied;
  @override
  Future<String?> token() async => null;
  @override
  Stream<String> get tokenRefresh => const Stream.empty();
  @override
  Future<void> deleteToken() async {}
  @override
  Stream<PushTap> get taps => const Stream.empty();
  @override
  Future<PushTap?> initialTap() async => null;
}

/// Android and iOS builds that carry Firebase keys. Every Firebase call is
/// behind this check, so web, desktop and key-less builds never touch the plugin.
bool get pushPlatformSupported =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) &&
    FirebaseConfig.isConfigured;

/// The handler for messages that arrive while the app is in the background or
/// closed. The system already shows the notification, so there is nothing to do:
/// it must stay a top-level function, and it never touches chat keys or storage.
@pragma('vm:entry-point')
Future<void> hiyallBackgroundMessage(RemoteMessage message) async {}

/// Registers [hiyallBackgroundMessage]; call once after Firebase starts.
void registerPushBackgroundHandler() {
  if (!pushPlatformSupported) return;
  FirebaseMessaging.onBackgroundMessage(hiyallBackgroundMessage);
}

class FirebasePushService implements PushService {
  FirebasePushService() {
    // A message that arrives with the app open is not shown as a banner: live
    // sync already updates the screen.
    unawaited(
      _messaging
          .setForegroundNotificationPresentationOptions(
            alert: false,
            badge: false,
            sound: false,
          )
          .catchError((_) {}),
    );
  }
  FirebaseMessaging get _messaging => FirebaseMessaging.instance;

  PushPermission _map(AuthorizationStatus status) => switch (status) {
    AuthorizationStatus.authorized ||
    AuthorizationStatus.provisional => PushPermission.granted,
    AuthorizationStatus.denied ||
    AuthorizationStatus.deniedPermanently => PushPermission.denied,
    AuthorizationStatus.notDetermined => PushPermission.notAsked,
  };

  @override
  bool get supported => true;

  @override
  Future<PushPermission> permission() async =>
      _map((await _messaging.getNotificationSettings()).authorizationStatus);

  @override
  Future<PushPermission> requestPermission() async =>
      _map((await _messaging.requestPermission()).authorizationStatus);

  @override
  Future<String?> token() async {
    try {
      return await _messaging.getToken();
    } catch (_) {
      // iOS: the APNs token is not there yet; tokenRefresh fires when it is.
      return null;
    }
  }

  @override
  Stream<String> get tokenRefresh => _messaging.onTokenRefresh;

  @override
  Future<void> deleteToken() => _messaging.deleteToken().catchError((_) {});

  @override
  Stream<PushTap> get taps => FirebaseMessaging.onMessageOpenedApp
      .map((m) => PushTap.fromData(m.data))
      .where((t) => t != null)
      .cast<PushTap>();

  @override
  Future<PushTap?> initialTap() async {
    final message = await _messaging.getInitialMessage();
    return message == null ? null : PushTap.fromData(message.data);
  }
}

/// The platform service, or the no-op where push cannot work. Replaced in tests.
final pushServiceProvider = Provider<PushService>(
  (ref) =>
      pushPlatformSupported ? FirebasePushService() : const NoopPushService(),
);
