import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// How long a person stays "Hi sent" in Discover after a wave went to them.
const sayHiSentFor = Duration(hours: 24);

/// Where Say hi remembers, per account and per device, that the member
/// confirmed the first-time "Send a 👋?" sheet, and whom they waved at and when,
/// so the control stays "sent" for [sayHiSentFor] even after the app restarts.
abstract class SayHiPrefsStore {
  Future<bool> confirmed(String userId);
  Future<void> markConfirmed(String userId);

  /// When each person (by id) was last sent a wave, for this account.
  Future<Map<String, DateTime>> sent(String userId);
  Future<void> saveSent(String userId, Map<String, DateTime> sent);
}

/// The stored form of the sent waves: `{"<peer id>": <UTC milliseconds>}`. Anything that does not
/// parse is dropped.
Map<String, DateTime> decodeSent(String? raw) {
  if (raw == null || raw.isEmpty) return {};
  try {
    final data = jsonDecode(raw);
    if (data is! Map) return {};
    final out = <String, DateTime>{};
    data.forEach((peer, ms) {
      if (peer is! String || ms is! int) return;
      out[peer] = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
    });
    return out;
  } catch (_) {
    return {};
  }
}

/// The waves still inside [sayHiSentFor] at [now].
Map<String, DateTime> freshSent(Map<String, DateTime> sent, DateTime now) => {
  for (final e in sent.entries)
    if (now.difference(e.value) < sayHiSentFor) e.key: e.value,
};

String encodeSent(Map<String, DateTime> sent) => jsonEncode({
  for (final e in sent.entries) e.key: e.value.toUtc().millisecondsSinceEpoch,
});

/// Kept in the platform keystore beside the other small per-device choices (see
/// `home_prefs.dart`). Where there is no platform storage (tests, some
/// desktops) nothing is kept and nothing fails.
class SecureSayHiPrefsStore implements SayHiPrefsStore {
  const SecureSayHiPrefsStore();
  static const _storage = FlutterSecureStorage();
  static String _confirmedKey(String userId) =>
      'discover_say_hi_confirmed_$userId';
  static String _sentKey(String userId) => 'discover_say_hi_sent_$userId';

  @override
  Future<bool> confirmed(String userId) async {
    try {
      return await _storage.read(key: _confirmedKey(userId)) == '1';
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> markConfirmed(String userId) async {
    try {
      await _storage.write(key: _confirmedKey(userId), value: '1');
    } catch (_) {}
  }

  @override
  Future<Map<String, DateTime>> sent(String userId) async {
    try {
      return decodeSent(await _storage.read(key: _sentKey(userId)));
    } catch (_) {
      return {};
    }
  }

  @override
  Future<void> saveSent(String userId, Map<String, DateTime> sent) async {
    try {
      await _storage.write(key: _sentKey(userId), value: encodeSent(sent));
    } catch (_) {}
  }
}

/// A store that lives only in memory.
class MemorySayHiPrefsStore implements SayHiPrefsStore {
  final confirmedBy = <String>{};
  final sentBy = <String, Map<String, DateTime>>{};
  @override
  Future<bool> confirmed(String userId) async => confirmedBy.contains(userId);
  @override
  Future<void> markConfirmed(String userId) async => confirmedBy.add(userId);
  @override
  Future<Map<String, DateTime>> sent(String userId) async =>
      Map.of(sentBy[userId] ?? const {});
  @override
  Future<void> saveSent(String userId, Map<String, DateTime> sent) async =>
      sentBy[userId] = Map.of(sent);
}

/// The clock Say hi reads when it stamps a wave and decides whether one is still
/// "sent". Replaced in tests.
final sayHiClockProvider = Provider<DateTime Function()>(
  (ref) =>
      () => DateTime.now(),
);

final sayHiPrefsStoreProvider = Provider<SayHiPrefsStore>(
  (ref) => const SecureSayHiPrefsStore(),
);
