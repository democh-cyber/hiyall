import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/api.dart';
import '../core/chat/chat_attachment.dart';
import '../core/chat/chat_engine.dart';
import '../core/state.dart';
import '../shared/person_avatar.dart';
import '../shared/widgets.dart';
import '../core/user_error.dart';

/// Reasons offered when reporting, in the order people look for them. Keys
/// match the server's reason codes.
const reportReasons = <String, String>{
  'harassment': 'Bullying or harassment',
  'threats': 'Threats or violence',
  'hate': 'Hate speech or symbols',
  'sexual_content': 'Nudity or sexual content',
  'self_harm': 'Self-harm or suicide',
  'underage': 'They may be too young (under 13)',
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
                'Their posts and stories leave your Pulse, and their activity arrives without notifications. They won’t know.',
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
  // The profile that opened these options may be gone when the server
  // answers; the container outlives it.
  final container = ProviderScope.containerOf(context, listen: false);
  Future<void> apply(Future<void> Function() action, String done) async {
    try {
      await action();
      container.invalidate(otherProfileProvider(profile.userId));
      if (context.mounted) showMessage(context, done);
    } catch (e) {
      if (context.mounted) showFailure(context, e);
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
        container.invalidate(profileProvider);
        container.invalidate(otherProfileProvider(profile.userId));
        if (context.mounted) context.go('/discover');
      }
    case 'block':
      if (await confirmBlock(context, name)) onBlock();
  }
}

/// The question every "Block" asks first (the person's profile menu and the
/// chat's): what blocking does, and that they are not told. True on "Block".
Future<bool> confirmBlock(BuildContext context, String name) async =>
    await showDialog<bool>(
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
    ) ??
    false;

/// Asks first ([confirmBlock]), then blocks [userId] and says so, for screens
/// that stay where they are afterwards (Discover's row menu): the caller drops
/// the person from its own list. True only when the server accepted the block;
/// a refusal or a failure says why and returns false, and "Account blocked." is
/// never shown otherwise. Screens that also leave (the profile, a chat) keep
/// their own flow and navigation.
Future<bool> blockAccount(
  BuildContext context,
  WidgetRef ref, {
  required String userId,
  required String name,
}) async {
  final session = ref.read(sessionProvider).asData?.value;
  if (session == null) return false;
  if (!await confirmBlock(context, name) || !context.mounted) return false;
  final api = ref.read(apiProvider);
  final container = ProviderScope.containerOf(context, listen: false);
  try {
    await api.block(session, userId, true);
  } catch (e) {
    if (context.mounted) {
      showMessage(
        context,
        e is ApiFailure
            ? e.displayMessage
            : 'That didn’t go through. Try again.',
      );
    }
    return false;
  }
  container.invalidate(otherProfileProvider(userId));
  // Block changes also change the owner's derived connection counts.
  container.invalidate(profileProvider);
  if (context.mounted) showMessage(context, 'Account blocked.');
  return true;
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
        // Local notices and photos that never went out have nothing to share.
        if (!m.notice && m.status == SendStatus.sent) m,
    ].take(30).toList(),
    submit: (reason, details, evidence, consent, block, sharePhotos) async {
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
                  // The key to open a photo leaves the device only when the
                  // reporter ticked the photo consent as well.
                  if (sharePhotos && evidenceAttachment(m) != null)
                    'attachments': [evidenceAttachment(m)!],
                },
            ],
            disclosureConsent: consent,
            block: block,
          );
    },
  ),
);

/// The attachment of a photo, a voice message or a video that went out, as a report carries it: the blob ids
/// and the decrypted descriptor (which holds the key). Null for text and for anything not uploaded.
Map<String, dynamic>? evidenceAttachment(ChatMessage m) {
  final photo = m.attachment, voice = m.voice, video = m.video;
  if (photo != null && photo.uploaded) {
    return {
      'blobIds': [photo.full.blobId, photo.thumb.blobId],
      'descriptor': photo.toJson(),
    };
  }
  if (voice != null && voice.uploaded) {
    return {
      'blobIds': [voice.part.blobId],
      'descriptor': voice.toJson(),
    };
  }
  if (video != null && video.uploaded) {
    return {
      'blobIds': [video.video.blobId, video.poster.blobId],
      'descriptor': video.toJson(),
    };
  }
  return null;
}

typedef _Submit = Future<ReportReceipt> Function(
  String reason,
  String details,
  List<ChatMessage> evidence,
  bool consent,
  bool block,
  bool sharePhotos,
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
  bool consent = false, block = false, sending = false, sharePhotos = false;
  String? error;

  @override
  void dispose() {
    details.dispose();
    super.dispose();
  }

  /// A picked message carries a photo the safety team could open.
  bool get photoPicked => widget.messages.any(
    (m) => selected.contains(m.messageId) && evidenceAttachment(m) != null,
  );

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
        sharePhotos && photoPicked,
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
          Text(switch (widget.targetType) {
            'user' => 'Report ${widget.name}',
            'post' => 'Report this post',
            'comment' => 'Report this comment',
            'story' => 'Report this story',
            'space' => 'Report this space',
            'space_entry' => 'Report this discussion entry',
            _ => 'Report this chat',
          }, style: Theme.of(context).textTheme.headlineSmall),
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
                        if (!photoPicked) sharePhotos = false;
                      }),
                      secondary: m.isPhoto
                          ? const Icon(Icons.photo_outlined)
                          : m.isVoice
                          ? const Icon(Icons.mic_none_rounded)
                          : m.isVideo
                          ? const Icon(Icons.videocam_outlined)
                          : null,
                      title: Text(
                        m.isMedia ? m.preview : m.text,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${m.mine ? 'You' : widget.name}${m.isPhoto
                            ? ' · Photo'
                            : m.isVoice
                            ? ' · Voice message'
                            : m.isVideo
                            ? ' · Video'
                            : ''}',
                      ),
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
                      ? 'Share this message with Hiyall’s safety team'
                      : 'Share these ${selected.length} messages with Hiyall’s safety team',
                ),
                subtitle: const Text(
                  'Only the messages you picked leave your device’s encryption.',
                ),
              ),
            if (photoPicked)
              CheckboxListTile(
                key: const Key('report-photo-consent'),
                contentPadding: EdgeInsets.zero,
                value: sharePhotos,
                onChanged: (v) => setState(() => sharePhotos = v!),
                title: const Text(
                  'Also share the photo, voice message or video itself',
                ),
                subtitle: const Text(
                  'This gives Hiyall’s safety team the key to open the photo, voice message or video you picked. Without it they only see the words that came with it.',
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

  /// Per list, so switching tabs mid-load neither drops nor mixes requests.
  final errors = <String, Object>{};
  final _requests = <String, int>{};
  int _request = 0;
  Object? get error => errors[kind];
  bool get loading => _requests.containsKey(kind);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => load());
  }

  Session get session => ref.read(sessionProvider).asData!.value!;

  Future<void> load({bool more = false}) async {
    final current = kind;
    // Only paging waits; a reload supersedes whatever is in flight.
    if (more && _requests.containsKey(current)) return;
    final run = ++_request;
    setState(() {
      _requests[current] = run;
      errors.remove(current);
    });
    bool latest() => mounted && _requests[current] == run;
    try {
      final page = await ref
          .read(apiProvider)
          .controls(session, current, more ? cursors[current] : null);
      if (!latest()) return;
      setState(() {
        final kept = more ? lists[current] ?? const [] : const [];
        final seen = {for (final i in kept) (i['user'] as Map)['userId']};
        lists[current] = [
          ...kept,
          ...page.items.where((i) => seen.add((i['user'] as Map)['userId'])),
        ];
        cursors[current] = page.nextCursor;
      });
    } catch (e) {
      if (latest()) setState(() => errors[current] = e);
    } finally {
      if (latest()) setState(() => _requests.remove(current));
    }
  }

  Future<void> undo(Map<String, dynamic> item) async {
    final user = item['user'] as Map<String, dynamic>;
    final id = user['userId'] as String;
    final api = ref.read(apiProvider);
    final container = ProviderScope.containerOf(context, listen: false);
    // The list this undo belongs to, even if another tab is open by the time
    // the server answers.
    final which = kind;
    final at = lists[which]!.indexOf(item);
    bool sameUser(Map<String, dynamic> i) => (i['user'] as Map)['userId'] == id;
    setState(
      () => lists[which] = [
        for (final i in lists[which]!)
          if (!sameUser(i)) i,
      ],
    );
    try {
      switch (which) {
        case 'blocked':
          await api.block(session, id, false);
        case 'muted':
          await api.setMuted(session, id, false);
        case 'restricted':
          await api.setRestricted(session, id, false);
      }
      container.invalidate(otherProfileProvider(id));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        final now = [...?lists[which]];
        if (!now.any(sameUser)) now.insert(at.clamp(0, now.length), item);
        lists[which] = now;
      });
      showFailure(context, e);
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
              onPressed: () => context.go('/profile/settings'),
              icon: const Icon(Icons.arrow_back),
              label: const Text('Settings'),
              style: TextButton.styleFrom(
                alignment: AlignmentDirectional.centerStart,
              ),
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
                        leading: PersonAvatar(
                          name: (item['user'] as Map)['displayName'] as String,
                          avatarUrl:
                              (item['user'] as Map)['avatarUrl'] as String?,
                          userId: (item['user'] as Map)['userId'] as String,
                          radius: 20,
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
