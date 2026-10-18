import 'dart:async';
import 'dart:convert';

import 'chat_store.dart';

/// Chat choices that live only on this phone, inside the account's sealed local store (the same encrypted
/// snapshot as the history, so they go with it on sign-out). Nothing here is ever sent to the server: which
/// chats this person auto-translates, and into which language, is nobody else's business.
class ChatPrefsData {
  /// The language (a translation language code such as `de`) incoming messages are translated into; null means
  /// the phone's own language.
  final String? translateTo;

  /// Conversation ids that translate incoming text by themselves.
  final Set<String> autoTranslate;

  /// The person saw and accepted the explanation of the on-device translation language packs.
  final bool translateConsent;
  const ChatPrefsData({
    this.translateTo,
    this.autoTranslate = const {},
    this.translateConsent = false,
  });

  ChatPrefsData copyWith({
    String? translateTo,
    bool clearTranslateTo = false,
    Set<String>? autoTranslate,
    bool? translateConsent,
  }) => ChatPrefsData(
    translateTo: clearTranslateTo ? null : translateTo ?? this.translateTo,
    autoTranslate: autoTranslate ?? this.autoTranslate,
    translateConsent: translateConsent ?? this.translateConsent,
  );

  Map<String, dynamic> toJson() => {
    'to': ?translateTo,
    if (autoTranslate.isNotEmpty) 'auto': autoTranslate.toList()..sort(),
    if (translateConsent) 'consent': true,
  };

  static ChatPrefsData fromJson(Object? raw) {
    if (raw is! Map) return const ChatPrefsData();
    final to = raw['to'];
    final auto = raw['auto'];
    return ChatPrefsData(
      translateTo: to is String && to.length <= 8 ? to : null,
      autoTranslate: {
        if (auto is List)
          for (final id in auto)
            if (id is String && id.length <= 64) id,
      },
      translateConsent: raw['consent'] == true,
    );
  }
}

/// Reads and writes [ChatPrefsData] in [store] under [key]. Writes run one at a time; [changes] fires after each.
class ChatPrefs {
  final ChatStore store;
  final String key;
  ChatPrefs(this.store, this.key);

  ChatPrefsData? _cached;
  Future<void> _queue = Future.value();
  final _changes = StreamController<ChatPrefsData>.broadcast();
  Stream<ChatPrefsData> get changes => _changes.stream;

  Future<ChatPrefsData> read() async {
    final cached = _cached;
    if (cached != null) return cached;
    final raw = await store.read(key);
    Object? decoded;
    try {
      decoded = raw == null ? null : jsonDecode(raw);
    } catch (_) {
      decoded = null;
    }
    return _cached = ChatPrefsData.fromJson(decoded);
  }

  Future<ChatPrefsData> update(
    ChatPrefsData Function(ChatPrefsData current) change,
  ) {
    final done = _queue.then((_) async {
      final next = change(await read());
      await store.write(key, jsonEncode(next.toJson()));
      _cached = next;
      if (!_changes.isClosed) _changes.add(next);
      return next;
    });
    _queue = done.then((_) {}, onError: (_) {});
    return done;
  }

  Future<void> setAutoTranslate(String conversationId, bool on) => update(
    (p) => p.copyWith(
      autoTranslate: {
        ...p.autoTranslate.where((id) => id != conversationId),
        if (on) conversationId,
      },
    ),
  );

  Future<void> setTranslateTo(String? code) => update(
    (p) => code == null
        ? p.copyWith(clearTranslateTo: true)
        : p.copyWith(translateTo: code),
  );

  Future<void> acceptTranslateConsent() =>
      update((p) => p.copyWith(translateConsent: true));

  void dispose() => _changes.close();
}
