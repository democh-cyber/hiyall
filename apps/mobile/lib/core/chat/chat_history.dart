import 'dart:async';
import 'dart:convert';

import 'chat_attachment.dart';
import 'chat_engine.dart';
import 'chat_store.dart';

/// The decrypted messages of each conversation, kept as JSON in the secure
/// store (the newest 500 per conversation). Every change runs one at a time,
/// so the polling loop and a photo upload can both write without losing an
/// update.
class ChatHistory {
  final ChatStore store;

  /// The store key of one conversation's list.
  final String Function(String conversationId) keyOf;

  /// Called after every change.
  final void Function(String conversationId)? onChange;

  /// Called with messages that fell off the end of a list, so their cached
  /// photos can go with them.
  final void Function(List<ChatMessage> dropped)? onDropped;
  ChatHistory(this.store, this.keyOf, {this.onChange, this.onDropped});

  static const limit = 500;
  final _lists = <String, List<ChatMessage>>{};
  Future<void> _queue = Future.value();

  Future<T> _serial<T>(Future<T> Function() work) {
    final result = _queue.then((_) => work());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<List<ChatMessage>> _load(String conversationId) async {
    final cached = _lists[conversationId];
    if (cached != null) return cached;
    final raw = await store.read(keyOf(conversationId));
    final list = <ChatMessage>[];
    if (raw != null) {
      for (final m in jsonDecode(raw) as List) {
        final message = ChatMessage.fromJson(
          Map<String, dynamic>.from(m as Map),
        );
        // Nothing sends in the background after a restart: what was mid-upload
        // now waits for the person to retry it.
        list.add(
          message.status == SendStatus.sending
              ? message.copyWith(
                  status: SendStatus.failed,
                  failure: 'INTERRUPTED',
                )
              : message,
        );
      }
    }
    return _lists[conversationId] = list;
  }

  Future<List<ChatMessage>> read(String conversationId) =>
      _serial(() async => List.unmodifiable(await _load(conversationId)));

  Future<void> _save(String conversationId, List<ChatMessage> list) async {
    final dropped = <ChatMessage>[];
    var kept = list;
    if (kept.length > limit) {
      dropped.addAll(kept.sublist(0, kept.length - limit));
      kept = kept.sublist(kept.length - limit);
    }
    _lists[conversationId] = kept;
    await store.write(
      keyOf(conversationId),
      jsonEncode([for (final m in kept) m.toJson()]),
    );
    if (dropped.isNotEmpty) onDropped?.call(dropped);
    onChange?.call(conversationId);
  }

  /// Adds [message] unless that id is already there.
  Future<bool> append(String conversationId, ChatMessage message) =>
      _serial(() async {
        final list = [...await _load(conversationId)];
        if (list.any((m) => m.messageId == message.messageId)) return false;
        list.add(message);
        list.sort((a, b) => a.sentAt.compareTo(b.sentAt));
        await _save(conversationId, list);
        return true;
      });

  /// Swaps the message with the same id, if it is still there.
  Future<void> replace(String conversationId, ChatMessage message) =>
      _serial(() async {
        final list = [...await _load(conversationId)];
        final at = list.indexWhere((m) => m.messageId == message.messageId);
        if (at < 0) return;
        list[at] = message;
        await _save(conversationId, list);
      });

  Future<ChatMessage?> remove(String conversationId, String messageId) =>
      _serial(() async {
        final list = [...await _load(conversationId)];
        final at = list.indexWhere((m) => m.messageId == messageId);
        if (at < 0) return null;
        final gone = list.removeAt(at);
        await _save(conversationId, list);
        return gone;
      });
}
