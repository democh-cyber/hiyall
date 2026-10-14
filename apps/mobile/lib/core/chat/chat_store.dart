/// Durable key-value storage for a device's encrypted chat state. The app uses
/// the platform keystore (flutter_secure_storage); tests use memory.
abstract class ChatStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);

  /// Every key held, for wiping by prefix (sign-out, a fresh install).
  Future<List<String>> keys();
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
}
