import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/chat/chat_groups.dart';
import '../core/chat/chat_text.dart' show sanitizeText;
import '../shared/chat_tokens.dart';
import '../shared/person_avatar.dart';
import '../shared/press_scale.dart';
import 'chat.dart' show chatEngineProvider, chatError;
import 'chat_groups_data.dart';
import 'chat_parts.dart';
import 'people_lists/people_lists_actions.dart';

// Choosing people for a group: the New group screen (2 to 9 people and an optional name) and, with the same
// picker, Add people in Group info (as many as the group has room for). Only people this account already chats
// with or follows are listed; the relay decides who can really be added and the screen never says why not.

/// How many pages of the Following list the picker reads at most (the relay pages by 20).
const _followingPages = 10;

/// One person in the picker.
class PickPerson {
  final String id, name, username;
  final String? avatarUrl;
  const PickPerson(this.id, this.name, this.username, [this.avatarUrl]);
}

/// The New group screen: pick people, optionally name the group, Create. Pops with the new [GroupInfo].
class NewGroupScreen extends ConsumerWidget {
  const NewGroupScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => GroupPickerScreen(
    title: 'New group',
    actionLabel: 'Create group',
    minPick: 2,
    maxPick: groupMembersMax - 1,
    askName: true,
    onSubmit: (ids, name) async {
      final engine = await ref.read(chatEngineProvider.future);
      if (engine == null) throw StateError('no chat engine');
      return engine.createGroup(name: name, memberIds: ids);
    },
  );
}

/// Add people to a group: the same picker, without the ones already in or invited, limited to the room left.
class AddToGroupScreen extends ConsumerWidget {
  final String groupId;

  /// Members and people already invited, who are not offered again.
  final Set<String> exclude;

  /// How many more people fit: 10 minus members, minus pending invites.
  final int room;
  const AddToGroupScreen({
    super.key,
    required this.groupId,
    required this.exclude,
    required this.room,
  });
  @override
  Widget build(BuildContext context, WidgetRef ref) => GroupPickerScreen(
    title: 'Add people',
    actionLabel: 'Add to group',
    minPick: 1,
    maxPick: room,
    exclude: exclude,
    onSubmit: (ids, _) async {
      final engine = await ref.read(chatEngineProvider.future);
      if (engine == null) throw StateError('no chat engine');
      return engine.inviteToGroup(groupId, ids);
    },
  );
}

class GroupPickerScreen extends ConsumerStatefulWidget {
  final String title, actionLabel;
  final int minPick, maxPick;
  final bool askName;
  final Set<String> exclude;

  /// Creates or invites; its [GroupInfo] is what the screen pops with. A [ChatFailure] is worded on the screen.
  final Future<GroupInfo> Function(List<String> ids, String name) onSubmit;
  const GroupPickerScreen({
    super.key,
    required this.title,
    required this.actionLabel,
    required this.minPick,
    required this.maxPick,
    required this.onSubmit,
    this.askName = false,
    this.exclude = const {},
  });
  @override
  ConsumerState<GroupPickerScreen> createState() => _GroupPickerState();
}

class _GroupPickerState extends ConsumerState<GroupPickerScreen> {
  final search = TextEditingController();
  final nameField = TextEditingController();
  final picked = <String>[];
  List<PickPerson>? chatting;
  List<PickPerson> following = const [];
  bool followingDone = false;
  Object? loadError;
  bool busy = false;
  String? error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    search.dispose();
    nameField.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => loadError = null);
    try {
      final engine = await ref.read(chatEngineProvider.future);
      if (engine == null) throw StateError('no chat engine');
      final chats = await engine.conversations(limit: 200);
      if (!mounted) return;
      final skip = {engine.userId, ...widget.exclude};
      setState(() {
        chatting = [
          for (final c in chats)
            if (c.peerId.isNotEmpty && !skip.contains(c.peerId))
              PickPerson(
                c.peerId,
                displayName(c.peerName),
                c.peerUsername,
                c.peerAvatarUrl,
              ),
        ];
      });
      await _loadFollowing(skip);
    } catch (e) {
      if (mounted) setState(() => loadError = e);
    }
  }

  /// Everyone this account follows, a page at a time, in the background of the list.
  Future<void> _loadFollowing(Set<String> skip) async {
    String? cursor;
    for (var page = 0; page < _followingPages; page++) {
      final result = await ref
          .read(peopleListsActionsProvider)
          .connections('following', cursor: cursor);
      if (!mounted) return;
      final known = {for (final p in chatting ?? const <PickPerson>[]) p.id};
      setState(() {
        following = [
          ...following,
          for (final c in result.items)
            if (!skip.contains(c.user.userId) &&
                !known.contains(c.user.userId) &&
                !following.any((p) => p.id == c.user.userId))
              PickPerson(
                c.user.userId,
                displayName(c.user.name),
                c.user.username,
                c.user.avatarUrl,
              ),
        ];
      });
      cursor = result.nextCursor;
      if (cursor == null) break;
    }
    if (mounted) setState(() => followingDone = true);
  }

  PickPerson? _person(String id) {
    for (final p in [...?chatting, ...following]) {
      if (p.id == id) return p;
    }
    return null;
  }

  bool get _full => picked.length >= widget.maxPick;

  void _toggle(PickPerson p) {
    setState(() {
      error = null;
      if (!picked.remove(p.id) && !_full) picked.add(p.id);
    });
  }

  Future<void> _submit() async {
    if (busy || picked.length < widget.minPick) return;
    setState(() {
      busy = true;
      error = null;
    });
    final name = sanitizeText(nameField.text, multiline: false).trim();
    try {
      final group = await widget.onSubmit(List.of(picked), name);
      if (mounted) Navigator.of(context).pop(group);
    } catch (e) {
      if (!mounted) return;
      final who = cannotAddUserId(e);
      setState(
        () => error =
            groupFailureText(
              e,
              name: who == null ? null : _person(who)?.name,
            ) ??
            chatError(e),
      );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  bool _matches(PickPerson p, String q) =>
      q.isEmpty ||
      p.name.toLowerCase().contains(q) ||
      p.username.toLowerCase().contains(q);

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final q = search.text.trim().toLowerCase().replaceFirst(RegExp(r'^@'), '');
    final chats = [
      for (final p in chatting ?? const <PickPerson>[])
        if (_matches(p, q)) p,
    ];
    final follows = [
      for (final p in following)
        if (_matches(p, q)) p,
    ];
    final loading = chatting == null && loadError == null;
    final pad = ChatMetrics.pagePadding;
    return Scaffold(
      backgroundColor: t.bg,
      appBar: AppBar(title: Text(widget.title)),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: conversationMaxWidth,
                  ),
                  child: Column(
                    children: [
                      // What is picked stays in view while the list scrolls under it.
                      Padding(
                        padding: EdgeInsetsDirectional.fromSTEB(pad, 4, pad, 0),
                        child: clampedChrome(
                          context,
                          _Selected(
                            picked: [for (final id in picked) ?_person(id)],
                            min: widget.minPick,
                            max: widget.maxPick,
                            onRemove: _toggle,
                          ),
                        ),
                      ),
                      Padding(
                        padding: EdgeInsetsDirectional.fromSTEB(pad, 8, pad, 0),
                        child: clampedChrome(
                          context,
                          TextField(
                            key: const Key('group-picker-search'),
                            controller: search,
                            onChanged: (_) => setState(() {}),
                            textInputAction: TextInputAction.search,
                            decoration: const InputDecoration(
                              labelText: 'Search people',
                              prefixIcon: Icon(Icons.search_rounded),
                            ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: ListView(
                          key: const Key('group-picker-list'),
                          padding: EdgeInsetsDirectional.fromSTEB(
                            pad,
                            8,
                            pad,
                            16,
                          ),
                          children: [
                            if (widget.askName)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: TextField(
                                  key: const Key('group-name-field'),
                                  controller: nameField,
                                  maxLength: groupNameMax,
                                  textInputAction: TextInputAction.next,
                                  inputFormatters: [
                                    FilteringTextInputFormatter.deny(
                                      RegExp(r'[\r\n]'),
                                    ),
                                  ],
                                  decoration: const InputDecoration(
                                    labelText: 'Group name (optional)',
                                    hintText: 'Leave empty to show the members’ names',
                                  ),
                                ),
                              ),
                            if (loading)
                              const Padding(
                                padding: EdgeInsets.all(24),
                                child: Center(
                                  child: CircularProgressIndicator(),
                                ),
                              ),
                            if (loadError != null)
                              _LoadError(onRetry: () => unawaited(_load())),
                            if (chatting != null) ...[
                              _Heading(
                                'Chatting',
                                key: const Key('picker-chatting'),
                              ),
                              if (chats.isEmpty)
                                _Empty(
                                  q.isEmpty
                                      ? 'No one yet. Start a chat with someone first.'
                                      : 'No one here matches “${search.text.trim()}”.',
                                ),
                              for (final p in chats) _row(p),
                              _Heading(
                                'Following',
                                key: const Key('picker-following'),
                              ),
                              if (follows.isEmpty && followingDone)
                                _Empty(
                                  q.isEmpty
                                      ? 'No one else you follow.'
                                      : 'No one here matches “${search.text.trim()}”.',
                                ),
                              for (final p in follows) _row(p),
                              if (!followingDone && loadError == null)
                                const Padding(
                                  padding: EdgeInsets.all(12),
                                  child: Center(
                                    child: CircularProgressIndicator(),
                                  ),
                                ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            _Bottom(
              error: error,
              busy: busy,
              label: widget.actionLabel,
              onPressed: picked.length >= widget.minPick && !busy
                  ? () => unawaited(_submit())
                  : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(PickPerson p) {
    final on = picked.contains(p.id);
    return _PersonRow(
      key: Key('pick-${p.id}'),
      person: p,
      selected: on,
      // Once the limit is reached only the ones picked can still be changed.
      enabled: on || !_full,
      onTap: () => _toggle(p),
    );
  }
}

class _Heading extends StatelessWidget {
  final String text;
  const _Heading(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(0, 14, 0, 4),
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

class _Empty extends StatelessWidget {
  final String text;
  const _Empty(this.text);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Text(
      text,
      style: TextStyle(
        color: ChatTokens.of(context).textTertiary,
        fontSize: 14,
        height: 1.35,
      ),
    ),
  );
}

class _LoadError extends StatelessWidget {
  final VoidCallback onRetry;
  const _LoadError({required this.onRetry});
  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Couldn’t load your people.',
            key: const Key('picker-load-error'),
            style: TextStyle(color: t.error, fontSize: 14),
          ),
          TextButton(
            key: const Key('picker-retry'),
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
}

/// "3 of 9" and the people picked so far, each a chip that takes the person out again. Below the minimum the
/// line also says how many are needed.
class _Selected extends StatelessWidget {
  final List<PickPerson> picked;
  final int min, max;
  final void Function(PickPerson) onRemove;
  const _Selected({
    required this.picked,
    required this.min,
    required this.max,
    required this.onRemove,
  });
  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final need = picked.length < min;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          liveRegion: true,
          child: Wrap(
            spacing: 8,
            children: [
              Text(
                '${picked.length} of $max',
                key: const Key('picker-count'),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: picked.length >= max ? t.accent : t.textSecondary,
                ),
              ),
              if (need)
                Text(
                  min == 1 ? 'Pick at least 1' : 'Pick at least $min',
                  key: const Key('picker-need'),
                  style: TextStyle(fontSize: 14, color: t.textTertiary),
                ),
            ],
          ),
        ),
        if (picked.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 104),
              child: SingleChildScrollView(
                child: Wrap(
                  key: const Key('picker-chips'),
                  spacing: 8,
                  children: [
                    for (final p in picked)
                      _Chip(
                        key: Key('chip-${p.id}'),
                        person: p,
                        onRemove: () => onRemove(p),
                      ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  final PickPerson person;
  final VoidCallback onRemove;
  const _Chip({super.key, required this.person, required this.onRemove});
  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    return PressScale(
      onTap: onRemove,
      semanticLabel: 'Remove ${person.name}',
      minHeight: ChatMetrics.hit,
      child: Center(
        widthFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 220),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: t.surface,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: t.hairline.withValues(alpha: .6)),
            ),
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(4, 4, 10, 4),
              child: ExcludeSemantics(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    PersonAvatar(
                      name: person.name,
                      avatarUrl: person.avatarUrl,
                      userId: person.id,
                      radius: 14,
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        firstName(person.name),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: t.text,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(Icons.close_rounded, size: 16, color: t.textSecondary),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PersonRow extends StatelessWidget {
  final PickPerson person;
  final bool selected, enabled;
  final VoidCallback onTap;
  const _PersonRow({
    super.key,
    required this.person,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final handle = person.username.isEmpty ? null : '@${person.username}';
    return Semantics(
      container: true,
      checked: selected,
      enabled: enabled,
      inMutuallyExclusiveGroup: false,
      label: [person.name, ?handle].join(', '),
      hint: enabled ? null : 'You can’t pick more people',
      onTap: enabled ? onTap : null,
      excludeSemantics: true,
      child: PressScale(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(16),
        minHeight: 56,
        pressedScale: .98,
        child: Opacity(
          opacity: enabled ? 1 : .45,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Row(
              children: [
                PersonAvatar(
                  name: person.name,
                  avatarUrl: person.avatarUrl,
                  userId: person.id,
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
                        person.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: t.text,
                        ),
                      ),
                      if (handle != null)
                        Text(
                          handle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            color: t.textSecondary,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: selected ? t.lime : Colors.transparent,
                    border: Border.all(
                      color: selected ? t.lime : t.textTertiary,
                      width: 1.6,
                    ),
                  ),
                  child: selected
                      ? Icon(Icons.check_rounded, size: 16, color: t.onLime)
                      : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The error line and the main button, kept at the bottom whatever the list does.
class _Bottom extends StatelessWidget {
  final String? error;
  final bool busy;
  final String label;
  final VoidCallback? onPressed;
  const _Bottom({
    required this.error,
    required this.busy,
    required this.label,
    required this.onPressed,
  });
  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    return Material(
      color: t.elevated,
      elevation: 4,
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: conversationMaxWidth),
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(
              ChatMetrics.pagePadding,
              10,
              ChatMetrics.pagePadding,
              10,
            ),
            child: clampedChrome(
              context,
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          error!,
                          key: const Key('picker-error'),
                          style: TextStyle(
                            color: t.error,
                            fontSize: 14,
                            height: 1.3,
                          ),
                        ),
                      ),
                    ),
                  FilledButton(
                    key: const Key('group-create'),
                    onPressed: onPressed,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(ChatMetrics.hit),
                    ),
                    child: busy
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2.4),
                          )
                        : Text(label, textAlign: TextAlign.center),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
