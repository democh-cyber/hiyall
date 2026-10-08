/// Durable key-value storage for a device's encrypted chat state. The app uses
/// the platform keystore (flutter_secure_storage); tests use memory.
abstract class ChatStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class MemoryChatStore implements ChatStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}
