import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api.dart';
import '../core/chat/chat_engine.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../shared/widgets.dart';

/// Reasons offered when reporting, in the order people look for them. Keys
/// match the server's reason codes.
const reportReasons = <String, String>{
  'harassment': 'Bullying or harassment',
  'threats': 'Threats or violence',
  'hate': 'Hate speech or symbols',
  'sexual_content': 'Nudity or sexual content',
  'self_harm': 'Self-harm or suicide',
  'underage': 'They may be under 18',
  'scam': 'Scam or fraud',
  'spam': 'Spam',
  'impersonation': 'Pretending to be someone else',
  'violence': 'Graphic violence',
  'copyright': 'Intellectual property',
  'other': 'Something else',
};

/// Asks how long to mute for. Returns null if dismissed; otherwise a record
/// whose until is null for "until I turn it back on".
Future<({DateTime? until})?> pickMuteDuration(
  BuildContext context, {
  required String title,
}) => showModalBottomSheet<({DateTime? until})>(
  context: context,
  useRootNavigator: true,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (context) {
    final now = DateTime.now();
    Widget option(String label, DateTime? until, String key) => ListTile(
      key: Key('mute-$key'),
      title: Text(label),
      onTap: () => Navigator.pop(context, (until: until)),
    );
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(title, style: Theme.of(context).textTheme.titleLarge),
            ),
            option('For 1 hour', now.add(const Duration(hours: 1)), '1h'),
            option('For 8 hours', now.add(const Duration(hours: 8)), '8h'),
            option('For 1 week', now.add(const Duration(days: 7)), '1w'),
            option('Until I turn it back on', null, 'forever'),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  },
);

/// Mute, restrict, report and block for someone else's profile. [onBlock]
/// runs the screen's own block flow so navigation stays with the caller.
Future<void> showPersonOptions(
  BuildContext context,
  WidgetRef ref,
  Profile profile, {
  required VoidCallback onBlock,
}) async {
  final rel = profile.relationship ?? const Relationship();
  final name = profile.displayName;
  final choice = await showModalBottomSheet<String>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const Key('person-mute'),
              leading: Icon(
                rel.muted
                    ? Icons.notifications_active_outlined
                    : Icons.notifications_off_outlined,
              ),
              title: Text(rel.muted ? 'Unmute $name' : 'Mute $name'),
              subtitle: const Text(
                'Their activity arrives quietly, with no notifications. They won’t know.',
              ),
              onTap: () => Navigator.pop(context, 'mute'),
            ),
            ListTile(
              key: const Key('person-restrict'),
              leading: const Icon(Icons.do_not_disturb_on_outlined),
              title: Text(
                rel.restricted ? 'Unrestrict $name' : 'Restrict $name',
              ),
              subtitle: const Text(
                'Their chats skip your badge, and neither of you sees read receipts or typing. They won’t know.',
              ),
              onTap: () => Navigator.pop(context, 'restrict'),
            ),
            ListTile(
              key: const Key('person-report'),
              leading: const Icon(Icons.flag_outlined),
              title: Text('Report $name'),
              onTap: () => Navigator.pop(context, 'report'),
            ),
            ListTile(
              key: const Key('person-block'),
              leading: Icon(
                Icons.block_rounded,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                'Block $name',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              onTap: () => Navigator.pop(context, 'block'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
  if (choice == null || !context.mounted) return;
  final api = ref.read(apiProvider);
  final session = ref.read(sessionProvider).asData?.value;
  if (session == null) return;
  Future<void> apply(Future<void> Function() action, String done) async {
    try {
      await action();
      ref.invalidate(otherProfileProvider(profile.userId));
      if (context.mounted) showMessage(context, done);
    } catch (e) {
      if (context.mounted) showMessage(context, e.toString());
    }
  }

  switch (choice) {
    case 'mute' when rel.muted:
      await apply(
        () => api.setMuted(session, profile.userId, false),
        '$name is unmuted.',
      );
    case 'mute':
      final picked = await pickMuteDuration(context, title: 'Mute $name');
      if (picked == null) return;
      await apply(
        () => api.setMuted(session, profile.userId, true, until: picked.until),
        '$name is muted.',
      );
    case 'restrict':
      await apply(
        () => api.setRestricted(session, profile.userId, !rel.restricted),
        rel.restricted ? '$name is unrestricted.' : '$name is restricted.',
      );
    case 'report':
      if (!context.mounted) return;
      final receipt = await showReportSheet(
        context,
        ref,
        targetType: 'user',
        targetId: profile.userId,
        name: name,
      );
      if (receipt?.blocked ?? false) {
        ref.invalidate(profileProvider);
        if (context.mounted) context.go('/discover');
      }
    case 'block':
      final sure = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Block $name?'),
          content: const Text(
            'They won’t be able to find your profile, follow you or message you. Your follows and friendship end, and your chat closes. They won’t be told.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              key: const Key('confirm-block'),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Block'),
            ),
          ],
        ),
      );
      if (sure ?? false) onBlock();
  }
}

/// The report flow. For chats, [messages] are the decrypted messages on this
/// device; the reporter picks which, if any, to share, and must confirm before
/// any text leaves the device. Returns null if cancelled.
Future<ReportReceipt?> showReportSheet(
  BuildContext context,
  WidgetRef ref, {
  required String targetType,
  required String targetId,
  required String name,
  List<ChatMessage> messages = const [],
}) => showModalBottomSheet<ReportReceipt>(
  context: context,
  useRootNavigator: true,
  isScrollControlled: true,
  showDragHandle: true,
  useSafeArea: true,
  builder: (context) => _ReportSheet(
    targetType: targetType,
    targetId: targetId,
    name: name,
    messages: [
      for (final m in messages.reversed)
        if (!m.notice) m,
    ].take(30).toList(),
    submit: (reason, details, evidence, consent, block) async {
      final session = ref.read(sessionProvider).asData!.value!;
      return ref
          .read(apiProvider)
          .report(
            session,
            targetType: targetType,
            targetId: targetId,
            reasonCode: reason,
            description: details,
            evidence: [
              for (final m in evidence)
                {
                  'messageId': m.messageId,
                  'text': m.text,
                  'sentAt': (m.serverAt ?? m.sentAt).toUtc().toIso8601String(),
                  'fromMe': m.mine,
                },
            ],
            disclosureConsent: consent,
            block: block,
          );
    },
  ),
);

typedef _Submit = Future<ReportReceipt> Function(
  String reason,
  String details,
  List<ChatMessage> evidence,
  bool consent,
  bool block,
);

class _ReportSheet extends StatefulWidget {
  final String targetType, targetId, name;
  final List<ChatMessage> messages;
  final _Submit submit;
  const _ReportSheet({
    required this.targetType,
    required this.targetId,
    required this.name,
    required this.messages,
    required this.submit,
  });
  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  String? reason;
  final details = TextEditingController();
  final selected = <String>{};
  bool consent = false, block = false, sending = false;
  String? error;

  @override
  void dispose() {
    details.dispose();
    super.dispose();
  }

  bool get ready => reason != null && !sending && (selected.isEmpty || consent);

  Future<void> send() async {
    setState(() {
      sending = true;
      error = null;
    });
    try {
      final receipt = await widget.submit(
        reason!,
        details.text,
        [
          for (final m in widget.messages)
            if (selected.contains(m.messageId)) m,
        ],
        consent,
        block,
      );
      if (!mounted) return;
      Navigator.pop(context, receipt);
      showMessage(
        context,
        receipt.duplicate
            ? 'You already reported this. We’re on it.'
            : receipt.blocked
            ? 'Thanks for reporting. ${widget.name} is blocked.'
            : 'Thanks for reporting. Our safety team will review it.',
      );
    } on ApiFailure catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (_) {
      if (mounted) setState(() => error = 'That didn’t send. Try again.');
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(color: scheme.onSurfaceVariant, height: 1.4);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        children: [
          Text(
            widget.targetType == 'user'
                ? 'Report ${widget.name}'
                : 'Report this chat',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 6),
          Text('${widget.name} won’t know who reported them.', style: muted),
          const SizedBox(height: 16),
          RadioGroup<String>(
            groupValue: reason,
            onChanged: (v) => setState(() => reason = v),
            child: Column(
              children: [
                for (final entry in reportReasons.entries)
                  RadioListTile<String>(
                    key: Key('reason-${entry.key}'),
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: entry.key,
                    title: Text(entry.value),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('report-details'),
            controller: details,
            maxLength: 1000,
            minLines: 2,
            maxLines: 5,
            decoration: const InputDecoration(
              labelText: 'Anything else we should know? (optional)',
              border: OutlineInputBorder(),
            ),
          ),
          if (widget.messages.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              'Share messages (optional)',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Your chat is end-to-end encrypted, so we can only see messages you choose here.',
              style: muted,
            ),
            const SizedBox(height: 8),
            VibePanel(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                children: [
                  for (final m in widget.messages)
                    CheckboxListTile(
                      key: Key('evidence-${m.messageId}'),
                      dense: true,
                      value: selected.contains(m.messageId),
                      onChanged: (on) => setState(() {
                        on!
                            ? selected.add(m.messageId)
                            : selected.remove(m.messageId);
                        if (selected.isEmpty) consent = false;
                      }),
                      title: Text(
                        m.text,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(m.mine ? 'You' : widget.name),
                    ),
                ],
              ),
            ),
            if (selected.isNotEmpty)
              CheckboxListTile(
                key: const Key('report-consent'),
                contentPadding: EdgeInsets.zero,
                value: consent,
                onChanged: (v) => setState(() => consent = v!),
                title: Text(
                  selected.length == 1
                      ? 'Share this message with Kairova’s safety team'
                      : 'Share these ${selected.length} messages with Kairova’s safety team',
                ),
                subtitle: const Text(
                  'Only the messages you picked leave your device’s encryption.',
                ),
              ),
          ],
          SwitchListTile(
            key: const Key('report-block'),
            contentPadding: EdgeInsets.zero,
            value: block,
            onChanged: (v) => setState(() => block = v),
            title: Text('Also block ${widget.name}'),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(error!, style: TextStyle(color: scheme.error)),
            ),
          const SizedBox(height: 8),
          FilledButton(
            key: const Key('report-submit'),
            onPressed: ready ? send : null,
            child: Text(sending ? 'Sending…' : 'Submit report'),
          ),
        ],
      ),
    );
  }
}

/// Blocked, muted and restricted accounts, each undoable in place.
class ControlsScreen extends ConsumerStatefulWidget {
  const ControlsScreen({super.key});
  @override
  ConsumerState<ControlsScreen> createState() => _ControlsScreenState();
}

class _ControlsScreenState extends ConsumerState<ControlsScreen> {
  static const kinds = {
    'blocked': 'Blocked',
    'muted': 'Muted',
    'restricted': 'Restricted',
  };
  String kind = 'blocked';
  final lists = <String, List<Map<String, dynamic>>>{};
  final cursors = <String, String?>{};
  Object? error;
  bool loading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => load());
  }

  Session get session => ref.read(sessionProvider).asData!.value!;

  Future<void> load({bool more = false}) async {
    if (loading) return;
    final current = kind;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final page = await ref
          .read(apiProvider)
          .controls(session, current, more ? cursors[current] : null);
      if (!mounted) return;
      setState(() {
        lists[current] = [
          ...more ? lists[current] ?? const [] : const [],
          ...page.items,
        ];
        cursors[current] = page.nextCursor;
      });
    } catch (e) {
      if (mounted) setState(() => error = e);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> undo(Map<String, dynamic> item) async {
    final user = item['user'] as Map<String, dynamic>;
    final id = user['userId'] as String;
    final api = ref.read(apiProvider);
    final previous = lists[kind]!;
    setState(
      () => lists[kind] = [
        for (final i in previous)
          if ((i['user'] as Map)['userId'] != id) i,
      ],
    );
    try {
      switch (kind) {
        case 'blocked':
          await api.block(session, id, false);
        case 'muted':
          await api.setMuted(session, id, false);
        case 'restricted':
          await api.setRestricted(session, id, false);
      }
      ref.invalidate(otherProfileProvider(id));
    } catch (e) {
      if (!mounted) return;
      setState(() => lists[kind] = previous);
      showMessage(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = lists[kind];
    final scheme = Theme.of(context).colorScheme;
    final verb = {
      'blocked': 'Unblock',
      'muted': 'Unmute',
      'restricted': 'Unrestrict',
    }[kind]!;
    return ReadingWidth(
      child: RefreshIndicator(
        onRefresh: load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
          children: [
            TextButton.icon(
              onPressed: () => context.go('/profile/privacy'),
              icon: const Icon(Icons.arrow_back),
              label: const Text('Privacy'),
              style: TextButton.styleFrom(alignment: Alignment.centerLeft),
            ),
            Text(
              'People you’ve limited',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 6),
            Text(
              'Only you can see these lists.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            SegmentedButton<String>(
              segments: [
                for (final e in kinds.entries)
                  ButtonSegment(value: e.key, label: Text(e.value)),
              ],
              selected: {kind},
              onSelectionChanged: (s) {
                setState(() => kind = s.single);
                if (!lists.containsKey(kind)) load();
              },
            ),
            const SizedBox(height: 16),
            if (error != null)
              FailureCard(error: error!, retry: load)
            else if (items == null)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (items.isEmpty)
              EmptyCard(
                icon: Icons.verified_user_outlined,
                title: 'Nobody here',
                description: switch (kind) {
                  'blocked' => 'People you block can’t find you, follow you or message you.',
                  'muted' => 'Muting someone quiets their notifications without telling them.',
                  _ => 'Restricting someone keeps their chats out of your badge, quietly.',
                },
              )
            else
              VibePanel(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  children: [
                    for (final item in items)
                      ListTile(
                        key: Key('control-${(item['user'] as Map)['userId']}'),
                        leading: CircleAvatar(
                          backgroundColor: VibeColors.lilac,
                          foregroundColor: VibeColors.ink,
                          child: Text(
                            ((item['user'] as Map)['displayName'] as String)
                                    .characters
                                    .firstOrNull
                                    ?.toUpperCase() ??
                                '?',
                          ),
                        ),
                        title: Text(
                          (item['user'] as Map)['displayName'] as String,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        subtitle: Text(
                          item['until'] == null
                              ? '@${(item['user'] as Map)['username']}'
                              : 'Until ${_when(DateTime.parse(item['until'] as String).toLocal())}',
                        ),
                        trailing: OutlinedButton(
                          onPressed: () => undo(item),
                          child: Text(verb),
                        ),
                      ),
                  ],
                ),
              ),
            if (cursors[kind] != null)
              TextButton(
                onPressed: loading ? null : () => load(more: true),
                child: const Text('Show more'),
              ),
          ],
        ),
      ),
    );
  }
}

String _when(DateTime t) {
  final now = DateTime.now();
  final time =
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  if (t.year == now.year && t.month == now.month && t.day == now.day) {
    return time;
  }
  return '${t.day}/${t.month} $time';
}
