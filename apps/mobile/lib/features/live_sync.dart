import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/activity_state.dart';
import '../core/realtime/realtime_client.dart';
import '../core/state.dart';
import 'chat.dart';
import 'notification_settings.dart' show PushHost;

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

  /// How often everything is re-read when there is no live socket.
  static const fallbackSync = Duration(seconds: 30);

  /// How often open chat screens re-read conversation state while the socket
  /// is live, so a peer's online dot and last-seen text stay current. (Without
  /// a socket the 30 s sync below already does it.) Presence only moves in
  /// steps of minutes, so this is deliberately slow.
  static const presenceRefresh = Duration(seconds: 60);

  RealtimeClient? client;
  StreamSubscription<RealtimeEvent>? events;
  Timer? fallback, presence;
  AppLifecycleListener? lifecycle;

  bool get live => client?.connected.value ?? false;

  /// The safety-net poll and the presence refresh run only while the app is in
  /// the foreground; [startTimers] and [stopTimers] pair with pause and resume.
  void startTimers() {
    fallback?.cancel();
    presence?.cancel();
    fallback = Timer.periodic(fallbackSync, (_) {
      if (!live) syncAll();
    });
    presence = Timer.periodic(presenceRefresh, (_) {
      if (live) ref.read(chatSignalProvider.notifier).bump();
    });
  }

  void stopTimers() {
    fallback?.cancel();
    presence?.cancel();
    fallback = presence = null;
  }

  @override
  void initState() {
    super.initState();
    startTimers();
    lifecycle = AppLifecycleListener(
      onResume: () {
        client?.start();
        startTimers();
        syncAll();
      },
      onPause: () {
        client?.stop();
        stopTimers();
      },
    );
  }

  @override
  void dispose() {
    fallback?.cancel();
    presence?.cancel();
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
      case 'device':
        // A chat device was added to or removed from this account: look at the
        // list again (a new one raises the banner) and fetch what is waiting
        // (this phone's own removal makes it start over).
        quietly(() async {
          final engine = await ref.read(chatEngineProvider.future);
          await engine?.refreshOwnDevices();
          await engine?.pollNow();
        });
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
    // PushHost starts push notifications and shows their explainer sheet.
    return PushHost(child: widget.child);
  }
}
