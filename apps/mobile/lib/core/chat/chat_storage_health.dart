import 'dart:convert';
import 'dart:io';

import 'chat_store.dart';

/// How many launches in a row could not open the platform keystore, kept in a small plain file in the app's
/// private folder (the keystore is the thing that is failing, so it cannot hold this). Holds a number and a
/// time, nothing secret. Once [ChatStorageUnavailable.attemptsBeforeReset] launches have failed the app offers
/// the explicit "Reset chat on this phone" action; a successful open puts the count back to zero.
class ChatStorageHealth {
  static const fileName = 'chat_storage_health';
  final Directory dir;
  final DateTime Function() _clock;
  ChatStorageHealth(this.dir, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  File get _file => File('${dir.path}/$fileName');

  /// Consecutive failed launches recorded so far (0 when unreadable).
  Future<int> failedLaunches() async {
    try {
      final j = jsonDecode(await _file.readAsString());
      final n = j is Map ? j['failedLaunches'] : null;
      return n is int && n > 0 ? n : 0;
    } catch (_) {
      return 0;
    }
  }

  /// Counts one more failed launch and returns the new count. Call it once per launch, however many times
  /// the open is retried inside it.
  Future<int> recordFailedLaunch() async {
    final next = await failedLaunches() + 1;
    try {
      await dir.create(recursive: true);
      await _file.writeAsString(
        jsonEncode({
          'failedLaunches': next,
          'at': _clock().toUtc().toIso8601String(),
        }),
        flush: true,
      );
    } catch (_) {
      // Not counted; the next failure tries again.
    }
    return next;
  }

  /// The keystore opened: the count starts over.
  Future<void> clear() async {
    try {
      await _file.delete();
    } on PathNotFoundException {
      // Nothing to clear.
    } catch (_) {}
  }

  /// Whether the explicit reset should be offered now.
  Future<bool> resetOffered() async =>
      await failedLaunches() >= ChatStorageUnavailable.attemptsBeforeReset;
}
