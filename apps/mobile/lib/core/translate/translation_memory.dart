import 'translation_service.dart';

/// Translations of messages already shown, kept in memory only. A message's text lives in the sealed local
/// history; a translation of it is a second plaintext, and storing that anywhere on disk would put message
/// content outside the sealed snapshot. So translations are never written: closing the app, signing out or
/// switching accounts forgets them, and opening a chat translates again from the (cheap) on-device model.
class TranslationMemory {
  TranslationMemory({this.capacity = 400});
  final int capacity;
  final _entries = <String, TranslationResult>{};

  static String keyOf(String conversationId, String messageId, String to) =>
      '$conversationId|$messageId|$to';

  TranslationResult? get(String key) {
    final hit = _entries.remove(key);
    if (hit != null) _entries[key] = hit;
    return hit;
  }

  void put(String key, TranslationResult value) {
    _entries.remove(key);
    _entries[key] = value;
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
  }

  /// Forgets everything of one conversation (it was cleared or deleted) or everything.
  void clear({String? conversationId}) {
    if (conversationId == null) {
      _entries.clear();
    } else {
      _entries.removeWhere((k, _) => k.startsWith('$conversationId|'));
    }
  }

  int get length => _entries.length;
}
