import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'discovery.dart';
import 'secure_storage.dart';
import 'state.dart';

/// Where Discover keeps two small per-device choices, one set per account: the filters used last, and which
/// first-use tips were put away. Nothing here goes to the server. Like the Home and Say hi choices it lives in
/// the platform keystore, is removed at sign-out ([forget]), and where there is no platform storage (tests,
/// some desktops) nothing is kept and nothing fails.
abstract class DiscoverPrefsStore {
  /// The filters last used on this device for [userId], or null when none were saved.
  Future<PeopleFilters?> savedFilters(String userId);
  Future<void> saveFilters(String userId, PeopleFilters filters);

  /// The keys of the tips [userId] dismissed on this device.
  Future<Set<String>> dismissedTips(String userId);
  Future<void> dismissTip(String userId, String key);

  /// Removes everything kept for [userId] (the sign-out wipe).
  Future<void> forget(String userId);
}

class SecureDiscoverPrefsStore implements DiscoverPrefsStore {
  const SecureDiscoverPrefsStore();
  static final _storage = createSecureStorage();
  static String _filtersKey(String userId) => 'discover_filters_$userId';
  static String _tipsKey(String userId) => 'coach_tips_$userId';

  @override
  Future<PeopleFilters?> savedFilters(String userId) async {
    try {
      final raw = await _storage.read(key: _filtersKey(userId));
      if (raw == null || raw.isEmpty) return null;
      return PeopleFilters.fromSaved(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> saveFilters(String userId, PeopleFilters filters) async {
    try {
      if (filters.isEmpty) {
        await _storage.delete(key: _filtersKey(userId));
      } else {
        await _storage.write(
          key: _filtersKey(userId),
          value: jsonEncode(filters.toSaved()),
        );
      }
    } catch (_) {}
  }

  @override
  Future<Set<String>> dismissedTips(String userId) async {
    try {
      final raw = await _storage.read(key: _tipsKey(userId));
      if (raw == null || raw.isEmpty) return {};
      return {
        for (final v in jsonDecode(raw) as List)
          if (v is String) v,
      };
    } catch (_) {
      return {};
    }
  }

  @override
  Future<void> dismissTip(String userId, String key) async {
    try {
      final all = await dismissedTips(userId)
        ..add(key);
      await _storage.write(
        key: _tipsKey(userId),
        value: jsonEncode(all.toList()),
      );
    } catch (_) {}
  }

  @override
  Future<void> forget(String userId) async {
    try {
      await _storage.delete(key: _filtersKey(userId));
      await _storage.delete(key: _tipsKey(userId));
    } catch (_) {}
  }
}

/// A store that lives only in memory (tests, and the default where nothing is kept).
class MemoryDiscoverPrefsStore implements DiscoverPrefsStore {
  final filters = <String, PeopleFilters>{};
  final tips = <String, Set<String>>{};
  @override
  Future<PeopleFilters?> savedFilters(String userId) async => filters[userId];
  @override
  Future<void> saveFilters(String userId, PeopleFilters value) async {
    if (value.isEmpty) {
      filters.remove(userId);
    } else {
      filters[userId] = value;
    }
  }

  @override
  Future<Set<String>> dismissedTips(String userId) async => {...?tips[userId]};
  @override
  Future<void> dismissTip(String userId, String key) async =>
      (tips[userId] ??= {}).add(key);
  @override
  Future<void> forget(String userId) async {
    filters.remove(userId);
    tips.remove(userId);
  }
}

final discoverPrefsStoreProvider = Provider<DiscoverPrefsStore>(
  (ref) => const SecureDiscoverPrefsStore(),
);

/// The tips the signed-in member has dismissed on this device. Null until the saved set has been read, so a
/// tip never flashes up and vanishes. Dismissing is immediate and persists.
final dismissedTipsProvider = NotifierProvider<DismissedTips, Set<String>?>(
  DismissedTips.new,
);

class DismissedTips extends Notifier<Set<String>?> {
  @override
  Set<String>? build() {
    final userId = ref.watch(
      sessionProvider.select((s) => s.asData?.value?.userId),
    );
    if (userId == null) return null;
    final store = ref.read(discoverPrefsStoreProvider);
    unawaited(
      store.dismissedTips(userId).then((tips) {
        if (ref.mounted) state = {...tips, ...?state};
      }),
    );
    return null;
  }

  Future<void> dismiss(String key) async {
    final userId = ref.read(sessionProvider).asData?.value?.userId;
    state = {...?state, key};
    if (userId != null) {
      await ref.read(discoverPrefsStoreProvider).dismissTip(userId, key);
    }
  }
}
