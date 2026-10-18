import 'package:hiyall/core/chat/chat_engine.dart';
import 'package:hiyall/core/chat/chat_groups.dart';

/// The group side of a test engine that has no groups: the Chats list and a conversation ask for them, and the
/// real engine would ask the relay (a test double must never reach for the network).
mixin NoGroupsEngine on ChatEngine {
  @override
  bool isGroup(String conversationId) => false;
  @override
  Future<List<GroupInfo>> groups() async => const [];
  @override
  Future<List<GroupInfo>> hiddenGroups() async => const [];
  @override
  Future<List<GroupInvite>> groupInvites() async => const [];
}
