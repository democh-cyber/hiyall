import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api.dart';
import '../core/state.dart';
import '../shared/widgets.dart';
import 'safety.dart';

const _kinds = {
  'community': 'Communities',
  'moment': 'Moments',
  'event': 'Events',
};
String spaceSchedule(SocialSpace s) {
  if (s.startsAt == null) return '${s.memberCount} / ${s.capacity} members';
  final start = s.startsAt!.toLocal(), end = s.endsAt!.toLocal();
  String stamp(DateTime t) =>
      '${t.day}/${t.month}/${t.year} ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  return '${stamp(start)} – ${stamp(end)} (your time)\nHost zone: ${s.timezone}';
}

class SpacesScreen extends ConsumerStatefulWidget {
  final String? parentId;
  const SpacesScreen({super.key, this.parentId});
  @override
  ConsumerState<SpacesScreen> createState() => _SpacesState();
}

class _SpacesState extends ConsumerState<SpacesScreen> {
  String kind = 'community';
  bool mine = false, loading = false;
  String? cursor, error;
  List<SocialSpace> items = [];
  int generation = 0;
  @override
  void initState() {
    super.initState();
    if (widget.parentId != null) kind = 'moment';
    Future.microtask(load);
  }

  Future<void> load({bool more = false}) async {
    final s = ref.read(sessionProvider).asData?.value;
    if (s == null) return;
    if (more && (loading || cursor == null)) return;
    final run = ++generation;
    setState(() {
      loading = true;
      error = null;
      if (!more) {
        items = [];
        cursor = null;
      }
    });
    try {
      final page = await ref
          .read(apiProvider)
          .spaces(
            s,
            kind,
            mine: mine,
            parentId: widget.parentId,
            cursor: more ? cursor : null,
          );
      if (!mounted ||
          run != generation ||
          ref.read(sessionProvider).asData?.value != s) {
        return;
      }
      setState(() {
        final known = items.map((x) => x.spaceId).toSet();
        items = [
          ...items,
          ...page.items.where((x) => !known.contains(x.spaceId)),
        ];
        cursor = page.nextCursor;
      });
    } catch (e) {
      if (mounted && run == generation) setState(() => error = e.toString());
    } finally {
      if (mounted && run == generation) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final signed = ref.watch(sessionProvider).asData?.value != null;
    final canCreate =
        signed &&
        (widget.parentId == null ||
            ref
                    .watch(_editSpaceProvider(widget.parentId!))
                    .asData
                    ?.value
                    .host ==
                true);
    return Scaffold(
      appBar: AppBar(
        systemOverlayStyle: Theme.of(context).brightness == Brightness.dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
        title: Text(
          widget.parentId == null ? 'Find your circle' : 'Community spaces',
        ),
        actions: [
          if (canCreate)
            IconButton(
              key: const Key('new-space'),
              tooltip: 'Create a space',
              icon: const Icon(Icons.add),
              onPressed: () async {
                await context.push(
                  '/spaces/new?kind=$kind${widget.parentId == null ? '' : '&parent=${widget.parentId}'}',
                );
                if (mounted) load();
              },
            ),
        ],
      ),
      body: !signed
          ? const Center(child: Text('Sign in to explore shared spaces'))
          : RefreshIndicator(
              onRefresh: load,
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  const Text(
                    'Small circles. Real conversations.',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Adult-only shared spaces. Join a community, catch a Moment or meet at an event.',
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final k in _kinds.entries)
                        if (widget.parentId == null || k.key != 'community')
                          ChoiceChip(
                            label: Text(k.value),
                            selected: kind == k.key,
                            onSelected: (_) {
                              kind = k.key;
                              load();
                            },
                          ),
                      FilterChip(
                        label: const Text('Joined'),
                        selected: mine,
                        onSelected: (v) {
                          mine = v;
                          load();
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (error != null) ...[
                    Text(error!),
                    TextButton(onPressed: load, child: const Text('Try again')),
                  ],
                  if (loading)
                    const Padding(
                      padding: EdgeInsets.all(20),
                      child: Text('Loading spaces…'),
                    ),
                  if (!loading && items.isEmpty && error == null)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 40),
                      child: Text(
                        'A quiet corner for now. Start something worth joining.',
                      ),
                    ),
                  for (final s in items)
                    Card(
                      child: ListTile(
                        contentPadding: const EdgeInsets.all(16),
                        title: Text(
                          s.title,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: Text(
                          '${s.visibility} · ${s.status}${s.myState.isEmpty ? '' : ' · ${s.myState}'}\n${spaceSchedule(s)}',
                        ),
                        isThreeLine: true,
                        trailing: const Icon(Icons.arrow_forward_rounded),
                        onTap: () async {
                          await context.push('/spaces/${s.spaceId}');
                          if (mounted) load();
                        },
                      ),
                    ),
                  if (cursor != null)
                    TextButton(
                      onPressed: loading ? null : () => load(more: true),
                      child: const Text('Load more'),
                    ),
                ],
              ),
            ),
    );
  }
}

class CreateSpaceScreen extends ConsumerStatefulWidget {
  final String kind;
  final String? parentId;
  final SocialSpace? initial;
  const CreateSpaceScreen({
    super.key,
    this.kind = 'community',
    this.parentId,
    this.initial,
  });
  @override
  ConsumerState<CreateSpaceScreen> createState() => _CreateSpaceState();
}

class _CreateSpaceState extends ConsumerState<CreateSpaceScreen> {
  final title = TextEditingController(),
      description = TextEditingController(),
      rules = TextEditingController(),
      capacity = TextEditingController(text: '50'),
      zone = TextEditingController(text: 'UTC'),
      location = TextEditingController();
  String visibility = 'public';
  late DateTime start, end;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    start = DateTime.now().add(const Duration(hours: 1));
    end = start.add(const Duration(hours: 1));
    if (widget.parentId != null) visibility = 'private';
    final x = widget.initial;
    if (x != null) {
      title.text = x.title;
      description.text = x.description;
      rules.text = x.rules;
      capacity.text = '${x.capacity}';
      zone.text = x.timezone;
      location.text = x.location;
      visibility = x.visibility;
      start = x.startsAt?.toLocal() ?? start;
      end = x.endsAt?.toLocal() ?? end;
    }
  }

  @override
  void dispose() {
    for (final c in [title, description, rules, capacity, zone, location]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> pick(bool first) async {
    final initial = first ? start : end;
    final date = await showDatePicker(
      context: context,
      initialDate:
          initial.isBefore(DateTime.now().subtract(const Duration(days: 1)))
          ? DateTime.now()
          : initial,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;
    final clock = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (clock == null || !mounted) return;
    setState(() {
      final d = DateTime(
        date.year,
        date.month,
        date.day,
        clock.hour,
        clock.minute,
      );
      if (first) {
        start = d;
        if (!end.isAfter(start)) end = start.add(const Duration(hours: 1));
      } else {
        end = d;
      }
    });
  }

  Future<void> save() async {
    final s = ref.read(sessionProvider).asData?.value;
    if (s == null) return;
    final n = int.tryParse(capacity.text);
    if (title.text.trim().isEmpty || n == null || n < 2 || n > 10000) {
      showMessage(context, 'Add a title and capacity of 2–10000.');
      return;
    }
    setState(() => busy = true);
    try {
      final body = <String, dynamic>{
        'kind': widget.kind,
        'title': title.text.trim(),
        'description': description.text.trim(),
        'rules': rules.text.trim(),
        'visibility': visibility,
        'capacity': n,
        'timezone': zone.text.trim(),
        'location': location.text.trim(),
        if (widget.parentId != null) 'parentId': widget.parentId,
        if (widget.kind != 'community')
          'startsAt': start.toUtc().toIso8601String(),
        if (widget.kind != 'community') 'endsAt': end.toUtc().toIso8601String(),
      };
      final a = ref.read(apiProvider);
      final x = widget.initial == null
          ? await a.createSpace(s, body)
          : await a.updateSpace(s, widget.initial!.spaceId, body);
      if (mounted) {
        if (widget.initial != null) {
          context.pop();
        } else {
          context.replace('/spaces/${x.spaceId}');
        }
      }
    } catch (e) {
      if (mounted) showMessage(context, e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      systemOverlayStyle: Theme.of(context).brightness == Brightness.dark
          ? SystemUiOverlayStyle.light
          : SystemUiOverlayStyle.dark,
      title: Text('${widget.initial == null ? 'New' : 'Edit'} ${widget.kind}'),
    ),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        TextField(
          key: const Key('space-title'),
          controller: title,
          maxLength: 80,
          decoration: const InputDecoration(labelText: 'Give it a name'),
        ),
        TextField(
          controller: description,
          maxLength: 2000,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: 'What brings people here?',
          ),
        ),
        TextField(
          controller: rules,
          maxLength: 2000,
          maxLines: 2,
          decoration: const InputDecoration(labelText: 'Rules for your circle'),
        ),
        DropdownButtonFormField<String>(
          initialValue: visibility,
          decoration: const InputDecoration(labelText: 'Who can join?'),
          items: const [
            DropdownMenuItem(
              value: 'public',
              child: Text('Public · join instantly'),
            ),
            DropdownMenuItem(
              value: 'private',
              child: Text('Private · host approves'),
            ),
            DropdownMenuItem(value: 'invite', child: Text('Invite only')),
          ],
          onChanged: busy || widget.initial != null
              ? null
              : (v) => setState(() => visibility = v!),
        ),
        TextField(
          controller: capacity,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Capacity (includes the host)',
          ),
        ),
        if (widget.kind != 'community') ...[
          const SizedBox(height: 12),
          const Text(
            'Pick dates in your device’s local time. The host zone is saved alongside UTC.',
          ),
          ListTile(
            title: Text('Starts: ${start.toString().substring(0, 16)}'),
            trailing: const Icon(Icons.calendar_today),
            onTap: busy ? null : () => pick(true),
          ),
          ListTile(
            title: Text('Ends: ${end.toString().substring(0, 16)}'),
            trailing: const Icon(Icons.calendar_today),
            onTap: busy ? null : () => pick(false),
          ),
          TextField(
            controller: zone,
            decoration: const InputDecoration(
              labelText: 'Host IANA zone (e.g. Asia/Kolkata)',
            ),
          ),
          if (widget.kind == 'event')
            TextField(
              controller: location,
              maxLength: 240,
              decoration: const InputDecoration(
                labelText: 'Online link or meeting place',
              ),
            ),
        ],
        const SizedBox(height: 12),
        const Text(
          'Discussion boards are shared content readable by members and the service. Use encrypted chat for private conversations.',
        ),
        const SizedBox(height: 20),
        FilledButton(
          key: const Key('publish-space'),
          onPressed: busy ? null : save,
          child: Text(
            busy
                ? 'Saving…'
                : widget.initial == null
                ? 'Create space'
                : 'Save changes',
          ),
        ),
      ],
    ),
  );
}

class SpaceScreen extends ConsumerStatefulWidget {
  final String id;
  const SpaceScreen({super.key, required this.id});
  @override
  ConsumerState<SpaceScreen> createState() => _SpaceState();
}

class _SpaceState extends ConsumerState<SpaceScreen>
    with WidgetsBindingObserver {
  SocialSpace? space;
  List<SpaceEntry> entries = [];
  String? cursor, error;
  bool busy = false, loading = false;
  final text = TextEditingController();
  Timer? timer;
  int generation = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Future.microtask(load);
    timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted &&
          !busy &&
          !loading &&
          entries.length <= 20 &&
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        load();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) load();
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    text.dispose();
    super.dispose();
  }

  Future<void> load({bool more = false}) async {
    if (loading) return;
    final session = ref.read(sessionProvider).asData?.value;
    if (session == null) return;
    final run = ++generation;
    setState(() => loading = true);
    try {
      final api = ref.read(apiProvider);
      final x = await api.space(session, widget.id);
      final page = x.joined
          ? await api.spaceEntries(session, widget.id, more ? cursor : null)
          : null;
      if (!mounted ||
          run != generation ||
          ref.read(sessionProvider).asData?.value != session) {
        return;
      }
      setState(() {
        space = x;
        entries = more ? [...entries, ...?page?.items] : page?.items ?? [];
        cursor = page?.nextCursor;
        error = null;
      });
    } catch (e) {
      if (mounted && run == generation) {
        setState(() {
          error = e.toString();
          space = null;
          entries = [];
          cursor = null;
        });
      }
    } finally {
      if (mounted && run == generation) setState(() => loading = false);
    }
  }

  Future<void> act(Future<void> Function(ApiClient, Session) work) async {
    if (busy || loading) return;
    final session = ref.read(sessionProvider).asData?.value;
    if (session == null) return;
    setState(() => busy = true);
    try {
      await work(ref.read(apiProvider), session);
      if (mounted) await load();
    } catch (e) {
      if (mounted) showMessage(context, e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final x = ref.watch(sessionProvider).asData?.value == null ? null : space;
    return Scaffold(
      appBar: AppBar(
        systemOverlayStyle: Theme.of(context).brightness == Brightness.dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
        title: Text(x?.title ?? 'Your circle'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: loading ? null : load,
            icon: const Icon(Icons.refresh),
          ),
          if (x != null &&
              x.owner.userId !=
                  ref.watch(sessionProvider).asData?.value?.userId)
            IconButton(
              tooltip: 'Report space',
              icon: const Icon(Icons.flag_outlined),
              onPressed: () => showReportSheet(
                context,
                ref,
                targetType: 'space',
                targetId: x.spaceId,
                name: x.title,
              ),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: load,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (error != null) ...[
              Text(error!),
              TextButton(onPressed: load, child: const Text('Try again')),
            ],
            if (x == null && loading) const Text('Loading your circle…'),
            if (x != null) ...[
              Text(
                '${_kinds[x.kind]} · ${x.visibility} · ${x.status}',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 8),
              Text(x.description),
              const SizedBox(height: 12),
              Text(spaceSchedule(x)),
              if (x.location.isNotEmpty) SelectableText(x.location),
              if (x.rules.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  'Circle rules',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                Text(x.rules),
              ],
              const SizedBox(height: 16),
              if (!x.joined)
                FilledButton(
                  key: const Key('join-space'),
                  onPressed:
                      busy ||
                          loading ||
                          x.myState == 'pending' ||
                          x.status != 'open'
                      ? null
                      : () => act((a, s) async {
                          await a.spaceMembership(s, x.spaceId);
                        }),
                  child: Text(
                    x.myState == 'pending'
                        ? 'Waiting for approval'
                        : x.myState == 'invited'
                        ? 'Accept invitation'
                        : x.visibility == 'private'
                        ? 'Request to join'
                        : x.kind == 'event'
                        ? 'RSVP · Going'
                        : 'Join this circle',
                  ),
                ),
              if (x.joined) ...[
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton(
                      onPressed: () =>
                          context.push('/spaces/${x.spaceId}/members'),
                      child: Text('${x.memberCount} participants'),
                    ),
                    if (x.myRole != 'owner')
                      TextButton(
                        onPressed: busy
                            ? null
                            : () => act((a, s) async {
                                await a.spaceMembership(
                                  s,
                                  x.spaceId,
                                  join: false,
                                );
                                if (context.mounted) context.pop();
                              }),
                        child: const Text('Leave'),
                      ),
                    if (x.kind == 'event')
                      DropdownButton<String>(
                        value: x.myRsvp,
                        items: const [
                          DropdownMenuItem(
                            value: 'going',
                            child: Text('Going'),
                          ),
                          DropdownMenuItem(
                            value: 'interested',
                            child: Text('Interested'),
                          ),
                        ],
                        onChanged: busy
                            ? null
                            : (v) => act((a, s) async {
                                await a.spaceMembership(s, x.spaceId, rsvp: v!);
                              }),
                      ),
                  ],
                ),
                if (x.host)
                  TextButton.icon(
                    onPressed: () => context.push('/spaces/${x.spaceId}/edit'),
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('Edit details & schedule'),
                  ),
                if (x.host)
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final status in ['open', 'closed', 'archived'])
                        if (status != x.status)
                          TextButton(
                            onPressed: busy
                                ? null
                                : () => act((a, s) async {
                                    await a.spaceStatus(s, x.spaceId, status);
                                  }),
                            child: Text(
                              status == 'open'
                                  ? 'Reopen'
                                  : status == 'closed'
                                  ? 'Close'
                                  : 'Archive',
                            ),
                          ),
                    ],
                  ),
                if (x.kind == 'community')
                  OutlinedButton.icon(
                    onPressed: () =>
                        context.push('/spaces?parent=${x.spaceId}'),
                    icon: const Icon(Icons.bolt),
                    label: const Text('Moments & events'),
                  ),
                const Divider(height: 32),
                const Text(
                  'Shared discussion',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Readable by members and the service. Private conversations belong in encrypted chat.',
                ),
                const SizedBox(height: 16),
                if (x.canDiscuss)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: TextField(
                          key: const Key('space-entry'),
                          controller: text,
                          maxLength: 2000,
                          maxLines: 3,
                          minLines: 1,
                          decoration: const InputDecoration(
                            hintText: 'Add to the conversation',
                          ),
                        ),
                      ),
                      IconButton(
                        key: const Key('send-space-entry'),
                        tooltip: 'Post',
                        onPressed: busy || loading
                            ? null
                            : () => act((a, s) async {
                                await a.addSpaceEntry(s, x.spaceId, text.text);
                                text.clear();
                              }),
                        icon: const Icon(Icons.arrow_upward),
                      ),
                    ],
                  )
                else
                  const Text(
                    'This discussion is read-only outside its scheduled time or while closed.',
                  ),
                if (entries.isEmpty && !loading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Text('Be the first to share a thought.'),
                  ),
                for (final e in entries)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: TextButton(
                                  style: TextButton.styleFrom(
                                    alignment: Alignment.centerLeft,
                                  ),
                                  onPressed: () => context.push(
                                    '/discover/person/${e.author.userId}',
                                  ),
                                  child: Text(e.author.name),
                                ),
                              ),
                              PopupMenuButton<String>(
                                onSelected: (v) {
                                  if (v == 'delete') {
                                    act(
                                      (a, s) => a.deleteSpaceEntry(
                                        s,
                                        x.spaceId,
                                        e.entryId,
                                      ),
                                    );
                                  } else {
                                    showReportSheet(
                                      context,
                                      ref,
                                      targetType: 'space_entry',
                                      targetId: e.entryId,
                                      name: e.author.name,
                                    );
                                  }
                                },
                                itemBuilder: (_) => [
                                  if (e.canDelete)
                                    const PopupMenuItem(
                                      value: 'delete',
                                      child: Text('Delete'),
                                    ),
                                  if (e.author.userId !=
                                      ref
                                          .read(sessionProvider)
                                          .asData
                                          ?.value
                                          ?.userId)
                                    const PopupMenuItem(
                                      value: 'report',
                                      child: Text('Report'),
                                    ),
                                ],
                              ),
                            ],
                          ),
                          SelectableText(e.body),
                        ],
                      ),
                    ),
                  ),
                if (cursor != null)
                  TextButton(
                    onPressed: loading ? null : () => load(more: true),
                    child: const Text('Older thoughts'),
                  ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class SpaceMembersScreen extends ConsumerStatefulWidget {
  final String id;
  const SpaceMembersScreen({super.key, required this.id});
  @override
  ConsumerState<SpaceMembersScreen> createState() => _MembersState();
}

class _MembersState extends ConsumerState<SpaceMembersScreen> {
  SocialSpace? space;
  List<SpaceMember> members = [];
  String state = 'active';
  String? cursor, error;
  bool busy = false;
  final invite = TextEditingController();
  @override
  void initState() {
    super.initState();
    Future.microtask(load);
  }

  @override
  void dispose() {
    invite.dispose();
    super.dispose();
  }

  Future<void> load({bool more = false}) async {
    if (busy) return;
    final s = ref.read(sessionProvider).asData?.value;
    if (s == null) return;
    setState(() => busy = true);
    try {
      final a = ref.read(apiProvider);
      final x = await a.space(s, widget.id);
      final p = await a.spaceMembers(
        s,
        widget.id,
        state: state,
        cursor: more ? cursor : null,
      );
      if (mounted && ref.read(sessionProvider).asData?.value == s) {
        setState(() {
          space = x;
          members = more ? [...members, ...p.items] : p.items;
          cursor = p.nextCursor;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e.toString();
          members = [];
          space = null;
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> action(String user, String action) async {
    if (busy) return;
    final s = ref.read(sessionProvider).asData?.value;
    if (s == null) return;
    setState(() => busy = true);
    try {
      if (action == 'invite') {
        await ref.read(apiProvider).inviteSpaceUser(s, widget.id, user);
      } else {
        await ref
            .read(apiProvider)
            .spaceMemberAction(s, widget.id, user, action);
      }
      if (mounted) {
        setState(() => busy = false);
        await load();
      }
    } catch (e) {
      if (mounted) showMessage(context, e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(sessionProvider).asData?.value == null) {
      return const Scaffold(
        body: Center(child: Text('Sign in to view participants')),
      );
    }
    final x = space;
    return Scaffold(
      appBar: AppBar(
        systemOverlayStyle: Theme.of(context).brightness == Brightness.dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
        title: const Text('Circle participants'),
      ),
      body: RefreshIndicator(
        onRefresh: load,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (x?.moderate == true)
              Wrap(
                spacing: 8,
                children: [
                  for (final k in ['active', 'pending', 'invited', 'banned'])
                    ChoiceChip(
                      label: Text(k),
                      selected: k == state,
                      onSelected: busy
                          ? null
                          : (_) {
                              state = k;
                              load();
                            },
                    ),
                ],
              ),
            if (x?.host == true)
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: invite,
                      decoration: const InputDecoration(
                        labelText: 'Invite by @username',
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Invite',
                    onPressed: busy
                        ? null
                        : () => action(invite.text.trim(), 'invite'),
                    icon: const Icon(Icons.person_add_outlined),
                  ),
                ],
              ),
            if (error != null) Text(error!),
            if (busy) const Text('Loading participants…'),
            if (!busy && members.isEmpty)
              const Text('No participants in this list.'),
            for (final m in members)
              ListTile(
                title: Text(m.user.name),
                subtitle: Text(
                  '${m.role} · ${m.state}${x?.kind == 'event' ? ' · ${m.rsvp}' : ''}',
                ),
                onTap: () => context.push('/discover/person/${m.user.userId}'),
                trailing:
                    x?.moderate == true &&
                        m.role != 'owner' &&
                        m.user.userId !=
                            ref.read(sessionProvider).asData?.value?.userId
                    ? PopupMenuButton<String>(
                        onSelected: (v) => action(m.user.userId, v),
                        itemBuilder: (_) => [
                          if (m.state == 'pending')
                            const PopupMenuItem(
                              value: 'approve',
                              child: Text('Approve'),
                            ),
                          if (m.state == 'banned')
                            const PopupMenuItem(
                              value: 'unban',
                              child: Text('Unban'),
                            )
                          else ...[
                            const PopupMenuItem(
                              value: 'remove',
                              child: Text('Remove'),
                            ),
                            const PopupMenuItem(
                              value: 'ban',
                              child: Text('Ban'),
                            ),
                          ],
                          if (x?.host == true && m.state == 'active') ...[
                            const PopupMenuItem(
                              value: 'moderator',
                              child: Text('Make moderator'),
                            ),
                            const PopupMenuItem(
                              value: 'member',
                              child: Text('Make member'),
                            ),
                            if (x?.myRole == 'owner')
                              const PopupMenuItem(
                                value: 'admin',
                                child: Text('Make admin'),
                              ),
                          ],
                        ],
                      )
                    : null,
              ),
            if (cursor != null)
              TextButton(
                onPressed: busy ? null : () => load(more: true),
                child: const Text('Load more'),
              ),
          ],
        ),
      ),
    );
  }
}

final _editSpaceProvider = FutureProvider.autoDispose
    .family<SocialSpace, String>((ref, id) async {
      final s = ref.watch(sessionProvider).asData?.value;
      if (s == null) throw const ApiFailure('Sign in to edit a space');
      return ref.watch(apiProvider).space(s, id);
    });

class EditSpaceScreen extends ConsumerWidget {
  final String id;
  const EditSpaceScreen({super.key, required this.id});
  @override
  Widget build(BuildContext context, WidgetRef ref) => ref
      .watch(_editSpaceProvider(id))
      .when(
        data: (x) => x.host
            ? CreateSpaceScreen(kind: x.kind, parentId: x.parentId, initial: x)
            : const Scaffold(
                body: Center(child: Text('Only hosts can edit this space')),
              ),
        loading: () =>
            const Scaffold(body: Center(child: Text('Loading details…'))),
        error: (e, _) => Scaffold(
          appBar: AppBar(
            systemOverlayStyle: Theme.of(context).brightness == Brightness.dark
                ? SystemUiOverlayStyle.light
                : SystemUiOverlayStyle.dark,
            title: const Text('Edit space'),
          ),
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(e.toString()),
                TextButton(
                  onPressed: () => ref.invalidate(_editSpaceProvider(id)),
                  child: const Text('Try again'),
                ),
              ],
            ),
          ),
        ),
      );
}
