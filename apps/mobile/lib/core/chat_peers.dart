import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'state.dart';

/// The people this account already has a conversation with that holds messages, as
/// `peer id -> conversation id`, read from the chat list the last time it was
/// loaded (the Chats screen fills it) and kept for the session. Null until it has
/// been loaded, which callers treat as "no conversation": Discover never makes a
/// request of its own to find out. Cleared when the account changes.
final chatPeersProvider = NotifierProvider<ChatPeers, Map<String, String>?>(
  ChatPeers.new,
);

class ChatPeers extends Notifier<Map<String, String>?> {
  @override
  Map<String, String>? build() {
    ref.watch(sessionProvider.select((s) => s.asData?.value?.userId));
    return null;
  }

  /// Replaces the map with what the chat list just said: only conversations that have a message.
  void load(Map<String, String> peers) => state = Map.unmodifiable(peers);

  /// A conversation with [peer] now holds a message (a hi was just sent).
  void add(String peer, String conversationId) =>
      state = Map.unmodifiable({...?state, peer: conversationId});
}
