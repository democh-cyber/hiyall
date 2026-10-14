import 'dart:async';
import 'dart:convert';

import 'chat_attachment.dart';
import 'chat_engine.dart';
import 'chat_reactions.dart';
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

  /// Called with messages that fell off the start of a list (the oldest by the
  /// relay's clock), and with the messages that stay, so their cached photos
  /// can go with them unless a message that stays still needs them.
  final void Function(
    String conversationId,
    List<ChatMessage> dropped,
    List<ChatMessage> kept,
  )?
  onDropped;

  /// "Now", for how long a waiting reaction is kept.
  final DateTime Function() clock;
  ChatHistory(
    this.store,
    this.keyOf, {
    this.onChange,
    this.onDropped,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

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
      // One entry this app cannot read (written by another version, damaged)
      // is skipped; it never stops the rest of the conversation from loading.
      Object? decoded;
      try {
        decoded = jsonDecode(raw);
      } catch (_) {
        decoded = null;
      }
      for (final m in decoded is List ? decoded : const []) {
        final ChatMessage message;
        try {
          message = ChatMessage.fromJson(Map<String, dynamic>.from(m as Map));
        } catch (_) {
          continue;
        }
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
      list.sort(chatOrder);
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
    // Written first: if the store refuses, the list in memory stays as it was,
    // so what the screen shows is what a restart would show.
    await store.write(
      keyOf(conversationId),
      jsonEncode([for (final m in kept) m.toJson()]),
    );
    _lists[conversationId] = kept;
    if (dropped.isNotEmpty) onDropped?.call(conversationId, dropped, kept);
    onChange?.call(conversationId);
  }

  /// Adds [message] unless that id is already there. Reactions that arrived
  /// before it are applied to it now.
  Future<bool> append(String conversationId, ChatMessage message) =>
      _serial(() async {
        final list = [...await _load(conversationId)];
        if (list.any((m) => m.messageId == message.messageId)) return false;
        var added = message;
        if (!message.notice) {
          final waiting = await _loadPending(conversationId);
          final states = waiting.remove(message.messageId);
          if (states != null) {
            var merged = added.reactionStates;
            for (final e in states.entries) {
              merged = mergeReaction(merged, e.key, e.value.state);
            }
            added = added.copyWith(reactionStates: merged);
            await _savePending(conversationId, waiting);
          }
        }
        list.add(added);
        list.sort(chatOrder);
        await _save(conversationId, list);
        return true;
      });

  // ---------------------------------------------------------- reactions

  /// Reactions that arrived before the message they are for (two devices'
  /// messages can reach this one in any order): per conversation, by target id
  /// then by sender. At most [pendingReactionCap] targets, each kept for
  /// [pendingReactionLife] from when it arrived, then forgotten. Kept in the
  /// store beside the history so a restart does not lose them.
  final _pending = <String, Map<String, Map<String, _Waiting>>>{};

  String _pendingKey(String conversationId) =>
      '${keyOf(conversationId)}.reactions';

  Future<Map<String, Map<String, _Waiting>>> _loadPending(
    String conversationId,
  ) async {
    final cached = _pending[conversationId];
    if (cached != null) return cached;
    final out = <String, Map<String, _Waiting>>{};
    final raw = await store.read(_pendingKey(conversationId));
    if (raw != null) {
      try {
        final cutoff = clock().subtract(pendingReactionLife);
        for (final target in (jsonDecode(raw) as Map).entries) {
          final senders = <String, _Waiting>{};
          for (final sender in (target.value as Map).entries) {
            final w = _Waiting.fromJson(sender.value);
            if (w != null && w.received.isAfter(cutoff)) {
              senders[sender.key as String] = w;
            }
          }
          if (senders.isNotEmpty) out[target.key as String] = senders;
        }
      } catch (_) {
        // Unreadable: start empty, they are only a convenience.
      }
    }
    return _pending[conversationId] = out;
  }

  Future<void> _savePending(
    String conversationId,
    Map<String, Map<String, _Waiting>> waiting,
  ) async {
    final cutoff = clock().subtract(pendingReactionLife);
    waiting.removeWhere((_, senders) {
      senders.removeWhere((_, w) => !w.received.isAfter(cutoff));
      return senders.isEmpty;
    });
    if (waiting.length > pendingReactionCap) {
      // The oldest arrivals go first.
      DateTime newest(Map<String, _Waiting> s) => s.values
          .map((w) => w.received)
          .reduce((a, b) => a.isAfter(b) ? a : b);
      final byAge = waiting.keys.toList()
        ..sort((a, b) => newest(waiting[a]!).compareTo(newest(waiting[b]!)));
      for (final id in byAge.take(waiting.length - pendingReactionCap)) {
        waiting.remove(id);
      }
    }
    _pending[conversationId] = waiting;
    if (waiting.isEmpty) {
      await store.delete(_pendingKey(conversationId));
      return;
    }
    await store.write(
      _pendingKey(conversationId),
      jsonEncode({
        for (final t in waiting.entries)
          t.key: {for (final s in t.value.entries) s.key: s.value.toJson()},
      }),
    );
  }

  /// How many messages have a reaction waiting (for tests and diagnostics).
  Future<int> pendingReactionCount(String conversationId) =>
      _serial(() async => (await _loadPending(conversationId)).length);

  /// Applies a reaction to its message, last writer wins per sender. If the
  /// message is not in this conversation's history it waits (see [_pending]);
  /// the return value is whether it was applied to a message now.
  Future<bool> applyReaction(
    String conversationId,
    ReactionEvent event,
  ) => _serial(() async {
    final list = [...await _load(conversationId)];
    final at = list.indexWhere((m) => m.messageId == event.target && !m.notice);
    if (at >= 0) {
      final m = list[at];
      final merged = mergeReaction(m.reactionStates, event.sender, event.state);
      if (!identical(merged, m.reactionStates)) {
        list[at] = m.copyWith(reactionStates: merged);
        await _save(conversationId, list);
      }
      return true;
    }
    final waiting = await _loadPending(conversationId);
    final senders = waiting.putIfAbsent(event.target, () => {});
    final held = senders[event.sender];
    if (held == null || event.state.beats(held.state)) {
      senders[event.sender] = _Waiting(event.state, clock().toUtc());
    }
    await _savePending(conversationId, waiting);
    return false;
  });

  /// Takes back a reaction that could not be sent: puts [previous] (or nothing)
  /// back for [sender], unless a newer event has replaced [sent] meanwhile.
  Future<void> revertReaction(
    String conversationId,
    String target,
    String sender, {
    required ReactionState sent,
    required ReactionState? previous,
  }) => _serial(() async {
    final list = [...await _load(conversationId)];
    final at = list.indexWhere((m) => m.messageId == target);
    if (at < 0) return;
    final m = list[at];
    if (m.reactionStates[sender] != sent) return;
    final states = {...m.reactionStates};
    if (previous == null) {
      states.remove(sender);
    } else {
      states[sender] = previous;
    }
    list[at] = m.copyWith(reactionStates: states);
    await _save(conversationId, list);
  });

  /// Swaps the message with the same id, if it is still there.
  Future<void> replace(String conversationId, ChatMessage message) =>
      _serial(() async {
        final list = [...await _load(conversationId)];
        final at = list.indexWhere((m) => m.messageId == message.messageId);
        if (at < 0) return;
        list[at] = message;
        // The relay's time may have arrived with this version.
        list.sort(chatOrder);
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

/// A reaction held for a message that has not arrived, and when it did.
class _Waiting {
  final ReactionState state;
  final DateTime received;
  const _Waiting(this.state, this.received);

  Map<String, dynamic> toJson() => {
    ...state.toJson(),
    'rcv': received.toUtc().toIso8601String(),
  };

  static _Waiting? fromJson(Object? raw) {
    final state = ReactionState.fromJson(raw);
    final rcv = raw is Map && raw['rcv'] is String
        ? DateTime.tryParse(raw['rcv'] as String)
        : null;
    return state == null || rcv == null ? null : _Waiting(state, rcv);
  }
}
