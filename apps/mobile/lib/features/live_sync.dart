import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/activity_state.dart';
import '../core/realtime/realtime_client.dart';
import '../core/state.dart';
import 'chat.dart';

/// The signed-in account's socket. Null on web and when signed out.
final realtimeProvider = Provider<RealtimeClient?>((ref) {
  final session = ref.watch(sessionProvider).asData?.value;
  if (session == null) return null;
  final client = ref.watch(apiProvider).realtime(session);
  if (client != null) ref.onDispose(client.dispose);
  return client;
});

/// Unread chat messages across conversations, for the Chats badge.
final chatUnreadProvider = NotifierProvider<ChatUnread, int>(ChatUnread.new);

class ChatUnread extends Notifier<int> {
  @override
  int build() {
    ref.watch(sessionProvider);
    return 0;
  }

  Future<void> refresh() async {
    final engine = await ref.read(chatEngineProvider.future);
    if (engine == null) return;
    state = await engine.api.unreadMessages();
  }
}

/// Bumped whenever conversation metadata (unread, read receipts) may have
/// changed, so open chat screens reload it.
final chatSignalProvider = NotifierProvider<ChatSignal, int>(ChatSignal.new);

class ChatSignal extends Notifier<int> {
  @override
  int build() => 0;
  void bump() => state++;
}

/// Conversations where the peer is typing, until when.
final typingProvider = NotifierProvider<Typing, Map<String, DateTime>>(
  Typing.new,
);

class Typing extends Notifier<Map<String, DateTime>> {
  static const shownFor = Duration(seconds: 5);
  final _expiry = <String, Timer>{};

  @override
  Map<String, DateTime> build() {
    ref.onDispose(() {
      for (final t in _expiry.values) {
        t.cancel();
      }
    });
    return const {};
  }

  /// Shows the indicator for a few seconds; each new signal extends it.
  void mark(String conversationId) {
    _expiry[conversationId]?.cancel();
    _expiry[conversationId] = Timer(shownFor, () => clear(conversationId));
    state = {...state, conversationId: DateTime.now().add(shownFor)};
  }

  void clear(String conversationId) {
    _expiry.remove(conversationId)?.cancel();
    if (!state.containsKey(conversationId)) return;
    state = {...state}..remove(conversationId);
  }
}

/// Keeps chat and activity current while mounted. With a live socket, server
/// signals drive updates and polling drops to a slow safety net; without one
/// (web, offline, gateway at capacity) polling carries everything. The socket
/// closes in the background and reconnects, with a full resync, on resume.
class LiveSync extends ConsumerStatefulWidget {
  final Widget child;
  const LiveSync({super.key, required this.child});
  @override
  ConsumerState<LiveSync> createState() => _LiveSyncState();
}

class _LiveSyncState extends ConsumerState<LiveSync> {
  static const connectedPoll = Duration(seconds: 60);
  static const fallbackPoll = Duration(seconds: 10);

  RealtimeClient? client;
  StreamSubscription<RealtimeEvent>? events;
  Timer? fallback;
  AppLifecycleListener? lifecycle;

  bool get live => client?.connected.value ?? false;

  @override
  void initState() {
    super.initState();
    fallback = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!live) syncAll();
    });
    lifecycle = AppLifecycleListener(
      onResume: () {
        client?.start();
        syncAll();
      },
      onPause: () => client?.stop(),
    );
  }

  @override
  void dispose() {
    fallback?.cancel();
    lifecycle?.dispose();
    events?.cancel();
    client?.connected.removeListener(onConnection);
    super.dispose();
  }

  void attach(RealtimeClient? next) {
    if (identical(next, client)) return;
    events?.cancel();
    client?.connected.removeListener(onConnection);
    client = next;
    if (next == null) return;
    next.connected.addListener(onConnection);
    events = next.events.listen(handle);
    next.start();
  }

  Future<void> onConnection() async {
    final engine = ref.read(chatEngineProvider).asData?.value;
    engine?.setPollInterval(live ? connectedPoll : fallbackPoll);
  }

  void quietly(Future<void> Function() work) => work().catchError((_) {});

  void syncAll() {
    if (ref.read(sessionProvider).asData?.value == null) return;
    quietly(() => ref.read(activityProvider.notifier).syncUnread());
    quietly(() async {
      final engine = await ref.read(chatEngineProvider.future);
      engine?.setPollInterval(live ? connectedPoll : fallbackPoll);
      await engine?.pollNow();
      await ref.read(chatUnreadProvider.notifier).refresh();
      ref.read(chatSignalProvider.notifier).bump();
    });
  }

  void handle(RealtimeEvent e) {
    switch (e.type) {
      case 'ready' || 'resync':
        syncAll();
      case 'inbox':
        quietly(() async {
          final engine = await ref.read(chatEngineProvider.future);
          await engine?.pollNow();
          await ref.read(chatUnreadProvider.notifier).refresh();
          ref.read(chatSignalProvider.notifier).bump();
        });
        final id = e.data['conversationId'];
        if (id != null) ref.read(typingProvider.notifier).clear(id);
      case 'read':
        quietly(() => ref.read(chatUnreadProvider.notifier).refresh());
        ref.read(chatSignalProvider.notifier).bump();
      case 'typing':
        final id = e.data['conversationId'];
        if (id != null) ref.read(typingProvider.notifier).mark(id);
      case 'activity':
        quietly(() => ref.read(activityProvider.notifier).refresh());
    }
  }

  @override
  Widget build(BuildContext context) {
    final next = ref.watch(realtimeProvider);
    if (!identical(next, client)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) attach(next);
      });
    }
    return widget.child;
  }
}
