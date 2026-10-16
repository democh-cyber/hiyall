/// Durable key-value storage for a device's encrypted chat state. The app uses
/// the platform keystore (flutter_secure_storage); tests use memory.
abstract class ChatStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);

  /// Every key held, for wiping by prefix (sign-out, a fresh install).
  Future<List<String>> keys();

  /// Runs [work]; a store that can make several writes land together (see
  /// SnapshotChatStore) commits everything [work] wrote as one unit, or none
  /// of it. Others just run it.
  Future<T> batch<T>(Future<T> Function() work);
}

/// Deletes every key that starts with [prefix] and returns how many went.
Future<int> deleteKeysWithPrefix(ChatStore store, String prefix) async {
  var count = 0;
  for (final key in await store.keys()) {
    if (key.startsWith(prefix)) {
      await store.delete(key);
      count++;
    }
  }
  return count;
}

class MemoryChatStore implements ChatStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
  @override
  Future<List<String>> keys() async => values.keys.toList();
  @override
  Future<T> batch<T>(Future<T> Function() work) => work();
}

/// A [ChatStore] that stops accepting writes once [closed] says so, and can wait for the writes that were
/// already running. The engine hands it to everything that writes (history, outbox, its own notes), so a
/// late write from work that was in flight when the engine was disposed can never put a file or an entry
/// back after the account's data was wiped. Reads stay open.
class GuardedChatStore implements ChatStore {
  final ChatStore inner;
  final bool Function() closed;
  GuardedChatStore(this.inner, this.closed);

  final _running = <Future<void>>{};

  /// Completes when every write that had started has finished (or failed).
  Future<void> drain() async {
    while (_running.isNotEmpty) {
      await Future.wait(_running.toList());
    }
  }

  Never _refuse() => throw const ChatStoreClosed();

  Future<T> _track<T>(Future<T> work) {
    final done = work.then<void>((_) {}, onError: (_) {});
    _running.add(done);
    done.whenComplete(() => _running.remove(done));
    return work;
  }

  @override
  Future<String?> read(String key) => inner.read(key);
  @override
  Future<List<String>> keys() => inner.keys();
  @override
  Future<void> write(String key, String value) {
    if (closed()) _refuse();
    return _track(inner.write(key, value));
  }

  @override
  Future<void> delete(String key) {
    if (closed()) _refuse();
    return _track(inner.delete(key));
  }

  @override
  Future<T> batch<T>(Future<T> Function() work) {
    if (closed()) _refuse();
    return _track(inner.batch(work));
  }
}

/// A write was refused because the engine it belongs to was disposed (sign-out).
class ChatStoreClosed implements Exception {
  const ChatStoreClosed();
  @override
  String toString() => 'The chat was closed.';
}

/// The platform keystore could not be read or written (it is locked, busy or briefly unavailable). This is
/// never a reason to throw away what is stored: nothing is deleted or regenerated because of it. The app says
/// "Couldn't open secure storage", tries again with growing waits, and only after [attemptsBeforeReset]
/// launches in a row have failed offers the person the explicit "Reset chat on this phone" action (see
/// `ChatStorageHealth`).
class ChatStorageUnavailable implements Exception {
  /// What the platform said, for the log only; never shown.
  final Object? cause;
  const ChatStorageUnavailable([this.cause]);

  /// Launches in a row that must fail before the reset is offered.
  static const attemptsBeforeReset = 3;

  @override
  String toString() => 'Couldn’t open secure storage.';
}
