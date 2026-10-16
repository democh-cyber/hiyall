import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../secure_storage.dart';

/// Never ask again sooner than this after "Not now".
const pushAskEvery = Duration(days: 14);

/// What this device remembers about notifications, per account.
abstract class PushPrefsStore {
  /// When the member last chose "Not now", or null.
  Future<DateTime?> lastNotNow(String userId);
  Future<void> saveNotNow(String userId, DateTime at);

  /// The member switched notifications off in Settings on this device, so the
  /// token stays unregistered even though the system permission is granted.
  Future<bool> switchedOff(String userId);
  Future<void> saveSwitchedOff(String userId, bool off);

  /// Removes everything kept for [userId] (the sign-out wipe).
  Future<void> forget(String userId);
}

/// Kept in the platform keystore beside the other small per-device choices.
/// Where there is no platform storage nothing is kept and nothing fails.
class SecurePushPrefsStore implements PushPrefsStore {
  const SecurePushPrefsStore();
  static final _storage = createSecureStorage();
  static String _asked(String u) => 'push_not_now_$u';
  static String _off(String u) => 'push_switched_off_$u';

  @override
  Future<DateTime?> lastNotNow(String userId) async {
    try {
      final ms = int.tryParse(await _storage.read(key: _asked(userId)) ?? '');
      return ms == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> saveNotNow(String userId, DateTime at) async {
    try {
      await _storage.write(
        key: _asked(userId),
        value: '${at.toUtc().millisecondsSinceEpoch}',
      );
    } catch (_) {}
  }

  @override
  Future<bool> switchedOff(String userId) async {
    try {
      return await _storage.read(key: _off(userId)) == '1';
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> saveSwitchedOff(String userId, bool off) async {
    try {
      if (off) {
        await _storage.write(key: _off(userId), value: '1');
      } else {
        await _storage.delete(key: _off(userId));
      }
    } catch (_) {}
  }

  @override
  Future<void> forget(String userId) async {
    for (final key in [_asked(userId), _off(userId)]) {
      try {
        await _storage.delete(key: key);
      } catch (_) {}
    }
  }
}

class MemoryPushPrefsStore implements PushPrefsStore {
  final notNow = <String, DateTime>{};
  final off = <String>{};
  @override
  Future<DateTime?> lastNotNow(String userId) async => notNow[userId];
  @override
  Future<void> saveNotNow(String userId, DateTime at) async =>
      notNow[userId] = at;
  @override
  Future<bool> switchedOff(String userId) async => off.contains(userId);
  @override
  Future<void> saveSwitchedOff(String userId, bool v) async =>
      v ? off.add(userId) : off.remove(userId);
  @override
  Future<void> forget(String userId) async {
    notNow.remove(userId);
    off.remove(userId);
  }
}

final pushPrefsStoreProvider = Provider<PushPrefsStore>(
  (ref) => const SecurePushPrefsStore(),
);

/// The clock the nag cap reads. Replaced in tests.
final pushClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);
