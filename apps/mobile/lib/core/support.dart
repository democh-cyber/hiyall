import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api.dart';
import 'state.dart';

/// In-app support (docs/api/27-stories-notices-support.md, section 7). Messages are plain text on the
/// server and the Hiyall team reads them: they are not end-to-end encrypted, and the app says so.
enum SupportCategory {
  account,
  safety,
  bug,
  other;

  /// A category this app does not know (a newer server) reads as Other.
  static SupportCategory parse(Object? value) => values.firstWhere(
    (c) => c.name == value,
    orElse: () => SupportCategory.other,
  );
}

/// The most a support message may hold; the server counts characters the same way.
const supportBodyMax = 2000;

class SupportThread {
  final String id;
  final SupportCategory category;
  final bool open;
  final DateTime createdAt, lastMessageAt;

  /// The team wrote last and the member has not opened the thread since.
  final bool unread;

  /// `member` or `staff`.
  final String lastAuthor;
  final String preview;
  const SupportThread({
    required this.id,
    required this.category,
    required this.open,
    required this.createdAt,
    required this.lastMessageAt,
    this.unread = false,
    this.lastAuthor = 'member',
    this.preview = '',
  });
  factory SupportThread.fromJson(Map<String, dynamic> json) {
    final created =
        DateTime.tryParse(json['createdAt'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    return SupportThread(
      id: json['threadId'] as String,
      category: SupportCategory.parse(json['category']),
      open: json['status'] != 'closed',
      createdAt: created,
      lastMessageAt:
          DateTime.tryParse(json['lastMessageAt'] as String? ?? '') ?? created,
      unread: json['unread'] as bool? ?? false,
      lastAuthor: json['lastAuthor'] as String? ?? 'member',
      preview: json['preview'] as String? ?? '',
    );
  }

  SupportThread copyWith({bool? open, bool? unread}) => SupportThread(
    id: id,
    category: category,
    open: open ?? this.open,
    createdAt: createdAt,
    lastMessageAt: lastMessageAt,
    unread: unread ?? this.unread,
    lastAuthor: lastAuthor,
    preview: preview,
  );
}

class SupportMessage {
  final String id;

  /// True for the member's own message, false for "Hiyall team". A team member is never named.
  final bool mine;
  final String body;
  final DateTime createdAt;
  const SupportMessage({
    required this.id,
    required this.mine,
    required this.body,
    required this.createdAt,
  });
  factory SupportMessage.fromJson(Map<String, dynamic> json) => SupportMessage(
    id: json['messageId'] as String,
    mine: json['author'] != 'staff',
    body: json['body'] as String? ?? '',
    createdAt:
        DateTime.tryParse(json['createdAt'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  );
}

List<T> _list<T>(Object? json, T Function(Map<String, dynamic>) parse) => [
  for (final item in (json as List? ?? const []))
    parse(Map<String, dynamic>.from(item as Map)),
];

/// Bumped when the server says the team wrote ("support" realtime event). An open conversation reads
/// again when it changes.
final supportSignalProvider = NotifierProvider<SupportSignal, int>(
  SupportSignal.new,
);

class SupportSignal extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

/// How many conversations have a team reply the member has not opened: the dot on Help & Safety. A
/// failed read stays quiet and shows no dot.
final supportUnreadProvider = FutureProvider.autoDispose<int>((ref) async {
  final session = requireSession(ref);
  ref.watch(supportSignalProvider);
  final data =
      await ref.watch(apiProvider).send(session, 'GET', '/v1/support/unread')
          as Map<String, dynamic>;
  return (data['unreadCount'] as num?)?.toInt() ?? 0;
}, retry: (_, _) => null);

class SupportThreads {
  final List<SupportThread> items;
  final String? nextCursor;
  final bool loadingMore;
  const SupportThreads(this.items, {this.nextCursor, this.loadingMore = false});

  /// The open conversation about [category], if there is one.
  SupportThread? openIn(SupportCategory category) => items
      .where((t) => t.open && t.category == category)
      .cast<SupportThread?>()
      .firstOrNull;
}

/// The member's conversations with the team, most recent first.
final supportThreadsProvider =
    AsyncNotifierProvider.autoDispose<SupportThreadsController, SupportThreads>(
      SupportThreadsController.new,
      retry: apiReadRetry,
    );

class SupportThreadsController extends AsyncNotifier<SupportThreads> {
  ApiClient get _api => ref.read(apiProvider);
  int _epoch = 0;

  Future<SupportThreads> _first() async {
    final data = await _api.send(
      requireSession(ref),
      'GET',
      '/v1/support/threads',
    ) as Map<String, dynamic>;
    return SupportThreads(
      _list(data['items'], SupportThread.fromJson),
      nextCursor: data['nextCursor'] as String?,
    );
  }

  @override
  Future<SupportThreads> build() {
    // A reply from the team changes the list.
    ref.watch(supportSignalProvider);
    _epoch++;
    return _first();
  }

  Future<void> refresh() async {
    final fresh = await _first();
    _epoch++;
    if (ref.mounted) state = AsyncData(fresh);
  }

  Future<void> loadMore() async {
    final current = state.asData?.value;
    if (current == null || current.nextCursor == null || current.loadingMore) {
      return;
    }
    final epoch = _epoch;
    state = AsyncData(
      SupportThreads(
        current.items,
        nextCursor: current.nextCursor,
        loadingMore: true,
      ),
    );
    try {
      final data = await _api.send(
        requireSession(ref),
        'GET',
        '/v1/support/threads?cursor=${Uri.encodeQueryComponent(current.nextCursor!)}',
      ) as Map<String, dynamic>;
      if (epoch != _epoch || !ref.mounted) return;
      final known = {for (final t in current.items) t.id};
      state = AsyncData(
        SupportThreads([
          ...current.items,
          ..._list(
            data['items'],
            SupportThread.fromJson,
          ).where((t) => !known.contains(t.id)),
        ], nextCursor: data['nextCursor'] as String?),
      );
    } catch (_) {
      if (epoch == _epoch && ref.mounted) {
        state = AsyncData(
          SupportThreads(current.items, nextCursor: current.nextCursor),
        );
      }
      rethrow;
    }
  }

  /// The open conversation about [category] from a fresh read of the list, or null. Used when the
  /// server says one already exists, so the member can carry on there.
  Future<SupportThread?> findOpen(SupportCategory category) async {
    await refresh();
    return state.asData?.value.openIn(category);
  }

  /// Opens a conversation with its first message. Throws the server's refusal (a conversation about
  /// this topic is already open, the day's limit, a message that is not accepted).
  Future<SupportThread> create(SupportCategory category, String body) async {
    final data = await _api.send(
      requireSession(ref),
      'POST',
      '/v1/support/threads',
      body: {'category': category.name, 'body': body},
    ) as Map<String, dynamic>;
    final thread = SupportThread.fromJson(data);
    if (ref.mounted) {
      final latest = state.asData?.value;
      if (latest != null) {
        state = AsyncData(
          SupportThreads([
            thread,
            ...latest.items.where((t) => t.id != thread.id),
          ], nextCursor: latest.nextCursor),
        );
      }
    }
    return thread;
  }
}

/// One conversation as the screen shows it.
class SupportConversation {
  final SupportThread thread;

  /// Oldest first.
  final List<SupportMessage> messages;
  final bool sending;
  const SupportConversation(this.thread, this.messages, {this.sending = false});
  SupportConversation copyWith({
    SupportThread? thread,
    List<SupportMessage>? messages,
    bool? sending,
  }) => SupportConversation(
    thread ?? this.thread,
    messages ?? this.messages,
    sending: sending ?? this.sending,
  );
}

final supportConversationProvider = AsyncNotifierProvider.autoDispose
    .family<SupportConversationController, SupportConversation, String>(
      SupportConversationController.new,
      retry: apiReadRetry,
    );

class SupportConversationController extends AsyncNotifier<SupportConversation> {
  final String threadId;
  SupportConversationController(this.threadId);
  ApiClient get _api => ref.read(apiProvider);

  /// A conversation is short (twenty messages a day at most), so it is read whole: page after page.
  static const _pageCap = 40;

  Future<SupportConversation> _load() async {
    final session = requireSession(ref);
    final base = '/v1/support/threads/${Uri.encodeComponent(threadId)}';
    final thread = SupportThread.fromJson(
      await _api.send(session, 'GET', base) as Map<String, dynamic>,
    );
    final messages = <SupportMessage>[];
    String? cursor;
    for (var page = 0; page < _pageCap; page++) {
      // The first page marks the conversation read.
      final data = await _api.send(
        session,
        'GET',
        cursor == null
            ? '$base/messages'
            : '$base/messages?cursor=${Uri.encodeQueryComponent(cursor)}',
      ) as Map<String, dynamic>;
      messages.addAll(_list(data['items'], SupportMessage.fromJson));
      cursor = data['nextCursor'] as String?;
      if (cursor == null) break;
    }
    return SupportConversation(thread.copyWith(unread: false), messages);
  }

  @override
  Future<SupportConversation> build() async {
    final conversation = await _load();
    _readElsewhere();
    return conversation;
  }

  /// Opening the conversation read it: the dot and the list's row follow.
  void _readElsewhere() {
    ref.invalidate(supportUnreadProvider);
    ref.invalidate(supportThreadsProvider);
  }

  /// Reads again without a spinner (a reply arrived, or the quiet poll); a failure keeps what is shown.
  Future<void> refresh() async {
    try {
      final fresh = await _load();
      if (!ref.mounted) return;
      final sending = state.asData?.value.sending ?? false;
      state = AsyncData(fresh.copyWith(sending: sending));
      _readElsewhere();
    } catch (_) {}
  }

  void _update(SupportConversation Function(SupportConversation) change) {
    final latest = state.asData?.value;
    if (latest != null) state = AsyncData(change(latest));
  }

  /// Sends a message. Throws the server's refusal: when the conversation turns out to be closed the
  /// screen switches to its closed state first.
  Future<void> send(String body) async {
    final current = state.asData?.value;
    if (current == null || current.sending) return;
    state = AsyncData(current.copyWith(sending: true));
    try {
      final data = await _api.send(
        requireSession(ref),
        'POST',
        '/v1/support/threads/${Uri.encodeComponent(threadId)}/messages',
        body: {'body': body},
      ) as Map<String, dynamic>;
      final message = SupportMessage.fromJson(data);
      if (!ref.mounted) return;
      _update(
        (c) => c.copyWith(
          sending: false,
          messages: [...c.messages.where((m) => m.id != message.id), message],
        ),
      );
      ref.invalidate(supportThreadsProvider);
    } catch (error) {
      if (!ref.mounted) rethrow;
      _update((c) => c.copyWith(sending: false));
      if (error is ApiFailure && error.code == 'SUPPORT_THREAD_CLOSED') {
        _update((c) => c.copyWith(thread: c.thread.copyWith(open: false)));
        ref.invalidate(supportThreadsProvider);
      }
      rethrow;
    }
  }

  /// The member closes their own conversation (the team can reopen it).
  Future<void> close() async {
    await _api.send(
      requireSession(ref),
      'POST',
      '/v1/support/threads/${Uri.encodeComponent(threadId)}/close',
    );
    if (!ref.mounted) return;
    _update((c) => c.copyWith(thread: c.thread.copyWith(open: false)));
    ref.invalidate(supportThreadsProvider);
  }
}
