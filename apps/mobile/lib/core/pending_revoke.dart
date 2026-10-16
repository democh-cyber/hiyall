import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api.dart';
import 'secure_storage.dart';

/// A server sign-out that could not be sent (offline, server down). Sign-out
/// always finishes on the device; the credential is kept here, in the
/// platform keystore, and the revoke is retried on the next launch.
///
/// Only the short-lived access token is kept, with the time it stops being
/// useful: an identity-provider token lasts about an hour, after which the
/// server session ends on its own and the entry is dropped unsent.
class RevokeQueue {
  static const _key = 'pending_server_revoke';
  static const keepFor = Duration(hours: 1);
  final FlutterSecureStorage _storage;
  final DateTime Function() _now;
  RevokeQueue({FlutterSecureStorage? storage, DateTime Function()? now})
    : _storage = storage ?? createSecureStorage(),
      _now = now ?? DateTime.now;

  Future<void> add(String token) async {
    try {
      await _storage.write(
        key: _key,
        value: jsonEncode({
          'token': token,
          'until': _now().add(keepFor).toUtc().toIso8601String(),
        }),
      );
    } catch (_) {
      // No keystore (tests, some desktops): the session expires on its own.
    }
  }

  /// Sends a queued revoke. Kept only when the server could not be reached.
  Future<void> flush(ApiClient api) async {
    Map<String, dynamic>? entry;
    try {
      final raw = await _storage.read(key: _key);
      if (raw == null) return;
      entry = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      await _clear();
      return;
    }
    final until = DateTime.tryParse(entry['until'] as String? ?? '');
    final token = entry['token'] as String?;
    if (token == null || until == null || _now().isAfter(until)) {
      await _clear();
      return;
    }
    if (await api.revokeQueuedSession(token) != RevokeOutcome.unreachable) {
      await _clear();
    }
  }

  Future<void> _clear() async {
    try {
      await _storage.delete(key: _key);
    } catch (_) {}
  }
}

final revokeQueueProvider = Provider<RevokeQueue>((ref) => RevokeQueue());
