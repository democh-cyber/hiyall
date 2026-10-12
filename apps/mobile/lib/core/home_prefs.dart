import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'state.dart';

/// Where Home keeps its small per-device choices, one set per account.
abstract class HomePrefsStore {
  Future<bool> profileNudgeHidden(String userId);
  Future<void> hideProfileNudge(String userId);
}

/// Kept in the platform keystore beside the story draft. Where there is no
/// platform storage (tests, some desktops) nothing is kept and nothing fails.
class SecureHomePrefsStore implements HomePrefsStore {
  const SecureHomePrefsStore();
  static const _storage = FlutterSecureStorage();
  static String _key(String userId) => 'home_profile_nudge_hidden_$userId';

  @override
  Future<bool> profileNudgeHidden(String userId) async {
    try {
      return await _storage.read(key: _key(userId)) == '1';
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> hideProfileNudge(String userId) async {
    try {
      await _storage.write(key: _key(userId), value: '1');
    } catch (_) {}
  }
}

/// A store that lives only in memory.
class MemoryHomePrefsStore implements HomePrefsStore {
  final hidden = <String>{};
  @override
  Future<bool> profileNudgeHidden(String userId) async =>
      hidden.contains(userId);
  @override
  Future<void> hideProfileNudge(String userId) async => hidden.add(userId);
}

final homePrefsStoreProvider = Provider<HomePrefsStore>(
  (ref) => const SecureHomePrefsStore(),
);

/// What time it is, for greetings. Replaced in tests to pin the hour.
final homeClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Whether the "Finish your profile" pill was put away on this device for the
/// signed-in account. Null until the saved choice has been read, so the pill
/// never flashes up and vanishes.
final profileNudgeHiddenProvider = NotifierProvider<ProfileNudgeHidden, bool?>(
  ProfileNudgeHidden.new,
);

class ProfileNudgeHidden extends Notifier<bool?> {
  @override
  bool? build() {
    final userId = ref.watch(
      sessionProvider.select((s) => s.asData?.value?.userId),
    );
    if (userId == null) return null;
    final store = ref.read(homePrefsStoreProvider);
    unawaited(
      store.profileNudgeHidden(userId).then((hidden) {
        if (ref.mounted) state = hidden;
      }),
    );
    return null;
  }

  Future<void> hide() async {
    final userId = ref.read(sessionProvider).asData?.value?.userId;
    state = true;
    if (userId != null) {
      await ref.read(homePrefsStoreProvider).hideProfileNudge(userId);
    }
  }
}
