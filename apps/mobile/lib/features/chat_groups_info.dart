import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/chat/chat_api.dart' show ChatFailure;
import '../core/chat/chat_engine.dart';
import '../core/chat/chat_groups.dart';
import '../core/chat/chat_text.dart' show sanitizeText;
import '../shared/chat_tokens.dart';
import '../shared/person_avatar.dart';
import '../shared/person_link.dart';
import '../shared/press_scale.dart';
import '../shared/widgets.dart' show showMessage;
import 'chat.dart'
    show
        chatEngineProvider,
        chatError,
        confirmChatAction,
        showSafetyNumberDialog;
import 'chat_groups_data.dart';
import 'chat_groups_list.dart';
import 'chat_groups_new.dart';
import 'chat_parts.dart';
import 'live_sync.dart' show chatSignalProvider, chatUnreadProvider;
import 'safety.dart' show pickMuteDuration;

/// Group info: the name, the members (their photo, name and role; a tap opens their profile), people invited and
/// not yet in, and what the person can do: rename, add and remove people (the owner), mute, pin, safety numbers,
/// delete from the list and leave. Opens from the thread's header or menu.
class GroupInfoScreen extends ConsumerStatefulWidget {
  final String id;

  /// Opens a member's profile; replaced in tests (the default pushes the app's profile route).
  final void Function(BuildContext context, String userId)? openProfile;
  const GroupInfoScreen({super.key, required this.id, this.openProfile});
  @override
  ConsumerState<GroupInfoScreen> createState() => _GroupInfoState();
}

class _GroupInfoState extends ConsumerState<GroupInfoScreen> {
  /// A call is running: the buttons wait for it.
  bool busy = false;

  ChatEngine? get engine => ref.read(chatEngineProvider).value;
  String get me => engine?.userId ?? '';

  /// Reads the group again here and in the lists behind this screen.
  void refresh() {
    ref.invalidate(groupInfoProvider(widget.id));
    ref.read(chatSignalProvider.notifier).bump();
  }

  /// Runs one call, worded on failure; [name] is the person it is about.
  Future<bool> run(
    Future<void> Function(ChatEngine) call, {
    String? name,
  }) async {
    final current = engine;
    if (current == null || busy) return false;
    setState(() => busy = true);
    try {
      await call(current);
      return true;
    } catch (e) {
      if (mounted) {
        showMessage(context, groupFailureText(e, name: name) ?? chatError(e));
      }
      return false;
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void openMember(String userId) {
    final open = widget.openProfile;
    if (open != null) {
      open(context, userId);
    } else {
      unawaited(openPerson(context, userId));
    }
  }

  Future<void> rename(GroupInfo g) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) =>
          _RenameDialog(current: sanitizeText(g.name, multiline: false)),
    );
    if (name == null || !mounted) return;
    final done = await run((e) => e.renameGroup(g.id, name));
    if (done) {
      refresh();
      if (mounted) showMessage(context, 'Group renamed.');
    }
  }

  Future<void> addPeople(GroupInfo g) async {
    final room = groupMembersMax - g.members.length - g.pending.length;
    if (room <= 0) {
      showMessage(
        context,
        groupFailureText(const ChatFailure('GROUP_FULL', ''))!,
      );
      return;
    }
    final added = await Navigator.of(context, rootNavigator: true)
        .push<GroupInfo>(
          MaterialPageRoute(
            builder: (_) => AddToGroupScreen(
              groupId: g.id,
              exclude: {
                for (final m in g.members) m.userId,
                for (final p in g.pending) p.userId,
              },
              room: room,
            ),
          ),
        );
    if (added != null && mounted) {
      refresh();
      showMessage(context, 'Invites sent.');
    }
  }

  Future<void> remove(
    GroupInfo g,
    String userId,
    String name, {
    required bool pending,
  }) async {
    final yes = await confirmChatAction(
      context,
      title: pending ? 'Cancel the invite to $name?' : 'Remove $name?',
      body: pending
          ? '$name won’t be able to join. They aren’t told.'
          : '$name is taken out of the group and can’t read new messages. Everyone in the group sees that they were removed.',
      action: pending ? 'Cancel invite' : 'Remove',
    );
    if (!yes || !mounted) return;
    final done = await run((e) => e.removeFromGroup(g.id, userId), name: name);
    if (done) {
      refresh();
      if (mounted) {
        showMessage(
          context,
          pending ? 'Invite canceled.' : '$name was removed.',
        );
      }
    }
  }

  Future<void> confirmMember(GroupInfo g, String userId, String name) async {
    final yes = await confirmChatAction(
      context,
      title: 'Confirm $name?',
      body:
          'This phone hasn’t seen $name join, so it isn’t sending them messages; confirm only if you expect them in this group.',
      action: 'Confirm',
    );
    if (!yes || !mounted) return;
    final done = await run(
      (e) => e.confirmGroupMember(g.id, userId),
      name: name,
    );
    if (done) {
      refresh();
      if (mounted) showMessage(context, '$name is confirmed.');
    }
  }

  Future<void> toggleMute(GroupInfo g) async {
    DateTime? until;
    if (!g.muted) {
      final picked = await pickMuteDuration(context, title: 'Mute this group');
      if (picked == null || !mounted) return;
      until = picked.until;
    }
    final done = await run(
      (e) => e.api.muteConversation(g.id, !g.muted, until: until),
    );
    if (done) {
      refresh();
      unawaited(
        ref.read(chatUnreadProvider.notifier).refresh().catchError((_) {}),
      );
    }
  }

  Future<void> togglePin(GroupInfo g) async {
    final current = engine;
    if (current == null || busy) return;
    setState(() => busy = true);
    try {
      await current.pinConversation(g.id, !g.pinned);
      refresh();
    } catch (e) {
      if (mounted) {
        showMessage(
          context,
          e is ChatFailure && e.code == 'PIN_LIMIT'
              ? 'You can pin up to 5 chats. Unpin one first.'
              : chatError(e),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> deleteChat(GroupInfo g) async {
    final yes = await confirmChatAction(
      context,
      title: 'Delete this chat?',
      body: 'It leaves your list. You can bring it back from Deleted chats for 30 days; after that this phone’s copy is removed. Nobody is told.',
      action: 'Delete chat',
    );
    if (!yes || !mounted) return;
    final done = await run((e) => e.hideConversation(g.id));
    if (done && mounted) {
      ref.read(chatSignalProvider.notifier).bump();
      showMessage(
        context,
        'Chat deleted. You can restore it from Deleted chats.',
      );
      _exit();
    }
  }

  Future<void> leave(GroupInfo g) async {
    final others = [
      for (final m in g.members)
        if (m.userId != me) m,
    ];
    String? successor;
    if (g.isOwner(me) && others.length >= 2) {
      // The owner hands the group to someone before going.
      successor = await showDialog<String>(
        context: context,
        builder: (_) => _SuccessorDialog(candidates: others),
      );
      if (successor == null || !mounted) return;
    } else {
      final closes = others.length < 2;
      final yes = await confirmChatAction(
        context,
        title: 'Leave this group?',
        body: closes
            ? 'You’ll stop getting messages, and the group closes because fewer than two people would be left.'
            : 'You’ll stop getting messages, and the others see that you left. You can be invited again.',
        action: 'Leave',
      );
      if (!yes || !mounted) return;
    }
    final owner = successor;
    final done = await run((e) => e.leaveGroup(g.id, newOwnerId: owner));
    if (done && mounted) {
      ref.read(chatSignalProvider.notifier).bump();
      unawaited(
        ref.read(chatUnreadProvider.notifier).refresh().catchError((_) {}),
      );
      showMessage(context, 'You left the group.');
      _exit();
    }
  }

  /// Back to the chat list (or just back when there is no router, as in a preview).
  void _exit() {
    final router = GoRouter.maybeOf(context);
    if (router != null) {
      router.go('/chats');
    } else {
      Navigator.of(context).maybePop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final info = ref.watch(groupInfoProvider(widget.id));
    ref.watch(chatEngineProvider);
    final group = info.value;
    return Scaffold(
      backgroundColor: t.bg,
      appBar: AppBar(title: const Text('Group info')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: conversationMaxWidth),
            child: group != null
                ? _body(context, group)
                : info.hasError
                ? _Failure(
                    text:
                        info.error is ChatFailure &&
                            (info.error as ChatFailure).code == 'NOT_FOUND'
                        ? 'This group isn’t available.'
                        : 'Couldn’t load this group.',
                    onRetry: () => ref.invalidate(groupInfoProvider(widget.id)),
                  )
                : const Center(child: CircularProgressIndicator()),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, GroupInfo g) {
    final t = ChatTokens.of(context);
    final owner = g.isOwner(me);
    final active = !g.readOnly;
    final room = groupMembersMax - g.members.length - g.pending.length;
    final title = groupTitle(g, me);
    return ListView(
      key: const Key('group-info-list'),
      padding: const EdgeInsetsDirectional.fromSTEB(
        ChatMetrics.pagePadding,
        8,
        ChatMetrics.pagePadding,
        32,
      ),
      children: [
        Center(
          child: GroupHeaderBlock(group: g, me: me, title: title),
        ),
        if (owner && active)
          Align(
            child: TextButton.icon(
              key: const Key('group-rename'),
              onPressed: busy ? null : () => unawaited(rename(g)),
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('Rename group'),
              style: TextButton.styleFrom(
                minimumSize: const Size(ChatMetrics.hit, ChatMetrics.hit),
                foregroundColor: t.accent,
              ),
            ),
          ),
        if (!active)
          _Banner(
            key: const Key('group-readonly'),
            icon: Icons.lock_outline_rounded,
            text: g.closed
                ? 'This group has closed. You can read what’s on this phone, but nothing new can be sent.'
                : 'You’re no longer in this group. You can read what’s on this phone, but you can’t send messages.',
          ),
        _Banner(
          key: const Key('group-e2ee'),
          icon: Icons.lock_rounded,
          text: 'Messages in this group are end-to-end encrypted with each member’s devices.',
        ),
        _Heading('Members · ${g.members.length}'),
        for (final m in g.members)
          _MemberRow(
            key: Key('member-${m.userId}'),
            member: m,
            isMe: m.userId == me,
            unconfirmed: g.unconfirmed.contains(m.userId),
            canRemove: owner && active && m.userId != me,
            busy: busy,
            onOpen: () => openMember(m.userId),
            onSafety: () => unawaited(_safety(m.userId, displayName(m.name))),
            onRemove: () => unawaited(
              remove(g, m.userId, displayName(m.name), pending: false),
            ),
            onConfirm: () =>
                unawaited(confirmMember(g, m.userId, displayName(m.name))),
          ),
        if (g.pending.isNotEmpty) ...[
          const _Heading('Invited, waiting'),
          for (final p in g.pending)
            _PendingRow(
              key: Key('pending-${p.userId}'),
              pending: p,
              canCancel: owner && active,
              busy: busy,
              onOpen: () => openMember(p.userId),
              onCancel: () => unawaited(
                remove(g, p.userId, displayName(p.name), pending: true),
              ),
            ),
        ],
        const SizedBox(height: 8),
        if (owner && active)
          _Action(
            key: const Key('group-add-people'),
            icon: Icons.person_add_alt_1_rounded,
            title: 'Add people',
            subtitle: room > 0
                ? (room == 1
                      ? 'Room for 1 more person.'
                      : 'Room for $room more people.')
                : 'This group is full.',
            onTap: busy ? null : () => unawaited(addPeople(g)),
          ),
        if (active)
          _Action(
            key: const Key('group-mute'),
            icon: g.muted
                ? Icons.notifications_active_outlined
                : Icons.notifications_off_outlined,
            title: g.muted ? 'Unmute group' : 'Mute group',
            subtitle:
                'No notifications, and it stays out of your unread count.',
            onTap: busy ? null : () => unawaited(toggleMute(g)),
          ),
        _Action(
          key: const Key('group-pin'),
          icon: g.pinned ? Icons.push_pin : Icons.push_pin_outlined,
          title: g.pinned ? 'Unpin group' : 'Pin group',
          subtitle: g.pinned
              ? 'It goes back to its place by time.'
              : 'Keeps it at the top of your chats. Up to 5.',
          onTap: busy ? null : () => unawaited(togglePin(g)),
        ),
        _Action(
          key: const Key('group-delete'),
          icon: Icons.delete_outline_rounded,
          title: 'Delete chat',
          subtitle:
              'Takes it out of your list. You can restore it for 30 days.',
          onTap: busy ? null : () => unawaited(deleteChat(g)),
        ),
        if (active)
          _Action(
            key: const Key('group-leave'),
            icon: Icons.logout_rounded,
            title: 'Leave group',
            subtitle: owner && g.members.length > 2
                ? 'You choose who takes over.'
                : 'The others see that you left.',
            danger: true,
            onTap: busy ? null : () => unawaited(leave(g)),
          ),
      ],
    );
  }

  Future<void> _safety(String userId, String name) async {
    final current = engine;
    if (current == null) return;
    await showSafetyNumberDialog(context, current, userId: userId, name: name);
  }
}

/// The photo stack, the name and the member count at the top of Group info.
class GroupHeaderBlock extends StatelessWidget {
  final GroupInfo group;
  final String me, title;
  const GroupHeaderBlock({
    super.key,
    required this.group,
    required this.me,
    required this.title,
  });
  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    return Semantics(
      container: true,
      header: true,
      label: '$title, ${memberCountText(group.memberCount)}',
      excludeSemantics: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 8),
          GroupAvatarStack(
            members: stackMembers(group, me),
            size: 84,
            ring: t.bg,
          ),
          const SizedBox(height: 12),
          Text(
            title,
            key: const Key('group-info-title'),
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: 'SpaceGrotesk',
              fontSize: 24,
              height: 1.2,
              fontWeight: FontWeight.w700,
              letterSpacing: -.5,
              color: t.text,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            memberCountText(group.memberCount),
            key: const Key('group-info-count'),
            style: TextStyle(fontSize: 14, color: t.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _Failure extends StatelessWidget {
  final String text;
  final VoidCallback onRetry;
  const _Failure({required this.text, required this.onRetry});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          text,
          key: const Key('group-info-error'),
          textAlign: TextAlign.center,
          style: TextStyle(
            color: ChatTokens.of(context).textSecondary,
            fontSize: 15,
          ),
        ),
        TextButton(
          onPressed: onRetry,
          style: TextButton.styleFrom(
            minimumSize: const Size(ChatMetrics.hit, ChatMetrics.hit),
          ),
          child: const Text('Try again'),
        ),
      ],
    ),
  );
}

class _Heading extends StatelessWidget {
  final String text;
  const _Heading(this.text);
  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(0, 18, 0, 6),
      child: clampedChrome(
        context,
        Text(
          text,
          style: TextStyle(
            fontFamily: 'SpaceGrotesk',
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: ChatTokens.of(context).textSecondary,
          ),
        ),
      ),
    ),
  );
}

class _Banner extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Banner({super.key, required this.icon, required this.text});
  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: t.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: t.hairline.withValues(alpha: .5)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 18, color: t.textSecondary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  text,
                  style: TextStyle(
                    fontSize: 13.5,
                    height: 1.35,
                    color: t.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A small label next to a name: Owner, You, Not confirmed.
class _Tag extends StatelessWidget {
  final String text;
  final Color color;
  const _Tag(this.text, this.color);
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: color.withValues(alpha: .14),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    ),
  );
}

class _MemberRow extends StatelessWidget {
  final GroupMember member;
  final bool isMe, unconfirmed, canRemove, busy;
  final VoidCallback onOpen, onSafety, onRemove, onConfirm;
  const _MemberRow({
    super.key,
    required this.member,
    required this.isMe,
    required this.unconfirmed,
    required this.canRemove,
    required this.busy,
    required this.onOpen,
    required this.onSafety,
    required this.onRemove,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final name = displayName(member.name);
    final label = [
      name,
      if (member.owner) 'Owner',
      if (isMe) 'You',
      if (unconfirmed) 'Not confirmed',
    ].join(', ');
    final tags = [
      if (member.owner) _Tag('Owner', t.accent),
      if (isMe) _Tag('You', t.textSecondary),
      if (unconfirmed) _Tag('Not confirmed', t.error),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: PressScale(
                onTap: isMe ? null : onOpen,
                semanticLabel: isMe ? label : '$label. Opens profile',
                borderRadius: BorderRadius.circular(16),
                minHeight: 56,
                pressedScale: .98,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 6,
                    horizontal: 4,
                  ),
                  child: Row(
                    children: [
                      PersonAvatar(
                        name: name,
                        avatarUrl: member.avatarUrl,
                        userId: member.userId,
                        radius: 22,
                        initialStyle: const TextStyle(
                          fontFamily: 'SpaceGrotesk',
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: t.text,
                              ),
                            ),
                            if (tags.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 3),
                                child: Wrap(
                                  spacing: 6,
                                  runSpacing: 4,
                                  children: tags,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (!isMe)
              PopupMenuButton<String>(
                key: Key('member-menu-${member.userId}'),
                tooltip: 'Options for $name',
                enabled: !busy,
                icon: Icon(Icons.more_vert_rounded, color: t.textSecondary),
                constraints: const BoxConstraints(minWidth: 200),
                onSelected: (v) => switch (v) {
                  'safety' => onSafety(),
                  'confirm' => onConfirm(),
                  'remove' => onRemove(),
                  _ => null,
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    key: Key('member-safety'),
                    value: 'safety',
                    height: ChatMetrics.hit,
                    child: Text('Safety number'),
                  ),
                  if (unconfirmed)
                    const PopupMenuItem(
                      key: Key('member-confirm'),
                      value: 'confirm',
                      height: ChatMetrics.hit,
                      child: Text('Confirm'),
                    ),
                  if (canRemove)
                    PopupMenuItem(
                      key: const Key('member-remove'),
                      value: 'remove',
                      height: ChatMetrics.hit,
                      child: Text(
                        'Remove from group',
                        style: TextStyle(color: t.error),
                      ),
                    ),
                ],
              ),
          ],
        ),
        if (unconfirmed && !isMe)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 60, bottom: 4),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                key: Key('member-confirm-${member.userId}'),
                onPressed: busy ? null : onConfirm,
                style: TextButton.styleFrom(
                  minimumSize: const Size(ChatMetrics.hit, ChatMetrics.hit),
                  foregroundColor: t.accent,
                ),
                child: Semantics(
                  label: 'Confirm $name',
                  excludeSemantics: true,
                  child: const Text('Confirm'),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _PendingRow extends StatelessWidget {
  final GroupPending pending;
  final bool canCancel, busy;
  final VoidCallback onOpen, onCancel;
  const _PendingRow({
    super.key,
    required this.pending,
    required this.canCancel,
    required this.busy,
    required this.onOpen,
    required this.onCancel,
  });
  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final name = displayName(pending.name);
    return Row(
      children: [
        Expanded(
          child: PressScale(
            onTap: onOpen,
            semanticLabel: '$name, invited, waiting. Opens profile',
            borderRadius: BorderRadius.circular(16),
            minHeight: 56,
            pressedScale: .98,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
              child: Row(
                children: [
                  PersonAvatar(
                    name: name,
                    avatarUrl: pending.avatarUrl,
                    userId: pending.userId,
                    radius: 22,
                    initialStyle: const TextStyle(
                      fontFamily: 'SpaceGrotesk',
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: t.text,
                          ),
                        ),
                        Text(
                          'Invited, waiting',
                          style: TextStyle(
                            fontSize: 13,
                            color: t.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (canCancel)
          IconButton(
            key: Key('pending-cancel-${pending.userId}'),
            tooltip: 'Cancel invite to $name',
            onPressed: busy ? null : onCancel,
            constraints: const BoxConstraints(
              minWidth: ChatMetrics.hit,
              minHeight: ChatMetrics.hit,
            ),
            icon: Icon(Icons.close_rounded, color: t.textSecondary),
          ),
      ],
    );
  }
}

/// One thing the person can do in Group info.
class _Action extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final bool danger;
  final VoidCallback? onTap;
  const _Action({
    super.key,
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.danger = false,
  });
  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final ink = danger ? t.error : t.text;
    return PressScale(
      onTap: onTap,
      semanticLabel: [title, ?subtitle].join('. '),
      borderRadius: BorderRadius.circular(18),
      minHeight: 60,
      pressedScale: .98,
      child: Opacity(
        opacity: onTap == null ? .5 : 1,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: danger ? t.error.withValues(alpha: .14) : t.surface,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, size: 21, color: ink),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: ink,
                      ),
                    ),
                    if (subtitle != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          subtitle!,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.3,
                            color: t.textSecondary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Rename: the new name (0 to 40 characters; empty shows the members' names instead). Pops with the name.
class _RenameDialog extends StatefulWidget {
  final String current;
  const _RenameDialog({required this.current});
  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final controller = TextEditingController(text: widget.current);

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Rename group'),
    content: TextField(
      key: const Key('rename-field'),
      controller: controller,
      autofocus: true,
      maxLength: groupNameMax,
      inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r'[\r\n]'))],
      decoration: const InputDecoration(
        labelText: 'Group name',
        helperText: 'Leave empty to show the members’ names.',
        helperMaxLines: 2,
      ),
    ),
    actions: [
      TextButton(
        key: const Key('rename-cancel'),
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const Key('rename-save'),
        onPressed: () => Navigator.pop(
          context,
          sanitizeText(controller.text, multiline: false).trim(),
        ),
        child: const Text('Save'),
      ),
    ],
  );
}

/// The owner leaving picks who takes over: a list of the other members. Pops with the chosen user id.
class _SuccessorDialog extends StatefulWidget {
  final List<GroupMember> candidates;
  const _SuccessorDialog({required this.candidates});
  @override
  State<_SuccessorDialog> createState() => _SuccessorDialogState();
}

class _SuccessorDialogState extends State<_SuccessorDialog> {
  String? chosen;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Who takes over?'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'You started this group. Choose who becomes its owner before you leave.',
          ),
          const SizedBox(height: 8),
          RadioGroup<String>(
            groupValue: chosen,
            onChanged: (v) => setState(() => chosen = v),
            child: Column(
              children: [
                for (final m in widget.candidates)
                  RadioListTile<String>(
                    key: Key('successor-${m.userId}'),
                    contentPadding: EdgeInsets.zero,
                    value: m.userId,
                    title: Text(
                      displayName(m.name),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        key: const Key('successor-cancel'),
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const Key('successor-leave'),
        onPressed: chosen == null ? null : () => Navigator.pop(context, chosen),
        child: const Text('Leave group'),
      ),
    ],
  );
}
