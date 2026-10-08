import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:go_router/go_router.dart';

import '../core/api.dart';
import '../core/chat/chat_api.dart';
import '../core/chat/chat_engine.dart';
import '../core/chat/chat_store.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../shared/widgets.dart';
import '../src/rust/frb_generated.dart';
import 'live_sync.dart';

/// Keys and ratchet state live in the platform keystore (Android Keystore /
/// iOS Keychain backed), never in plain app storage.
class SecureChatStore implements ChatStore {
  static const _storage = FlutterSecureStorage();
  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Encrypted chat runs only where keys can be held by the platform keystore.
final chatSupported =
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

Future<void>? _rust;
final chatEngineProvider = FutureProvider<ChatEngine?>((ref) async {
  final session = ref.watch(sessionProvider).asData?.value;
  if (!chatSupported || session == null) return null;
  await (_rust ??= RustLib.init());
  final engine = ChatEngine(
    userId: session.userId,
    api: ChatApi(apiBaseUrl, session.token),
    store: SecureChatStore(),
    platform: defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android',
  );
  ref.onDispose(engine.dispose);
  await engine.start();
  return engine;
});

String chatError(Object error) => switch (error) {
  ChatFailure(code: 'MESSAGES_NOT_ALLOWED') =>
    'They aren’t accepting messages from you right now.',
  ChatFailure(code: 'CONVERSATION_CLOSED' || 'NOT_FOUND') =>
    'This conversation isn’t available.',
  ChatFailure(code: 'KEY_CHANGED') =>
    'Their security keys changed unexpectedly, so sending is paused.',
  ChatFailure(code: 'RATE_LIMITED') => 'You’re sending a lot. Wait a moment.',
  ChatFailure(:final message) => message,
  _ => 'Something went wrong with encryption on this device.',
};

class EncryptedBadge extends StatelessWidget {
  const EncryptedBadge({super.key});
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(
        Icons.lock_rounded,
        size: 12,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      const SizedBox(width: 4),
      Text(
        'End-to-end encrypted',
        style: TextStyle(
          fontSize: 11,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ],
  );
}

class ChatsScreen extends ConsumerStatefulWidget {
  const ChatsScreen({super.key});
  @override
  ConsumerState<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends ConsumerState<ChatsScreen> {
  List<ChatConversation>? items;
  Object? error;
  StreamSubscription<String>? changes;
  ChatEngine? engine;

  Future<void> load() async {
    final current = engine;
    if (current == null) return;
    try {
      final next = await current.conversations();
      if (mounted) {
        setState(() {
          items = next;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = e);
    }
  }

  void attach(ChatEngine? next) {
    if (identical(next, engine)) return;
    changes?.cancel();
    engine = next;
    changes = next?.changes.listen((_) => load());
    load();
  }

  @override
  void dispose() {
    changes?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (!chatSupported) {
      return const _ChatNotice(
        icon: Icons.phone_iphone_rounded,
        title: 'Chats live in the app',
        body: 'Private chats are end-to-end encrypted with keys kept in your phone’s secure storage. Open Kairova on Android or iOS to chat.',
      );
    }
    final state = ref.watch(chatEngineProvider);
    state.whenData(
      (value) =>
          WidgetsBinding.instance.addPostFrameCallback((_) => attach(value)),
    );
    ref.listen(chatSignalProvider, (_, _) => load());
    final typing = ref.watch(typingProvider);
    if (state.isLoading) {
      return const Center(child: Text('Setting up encryption…'));
    }
    if (state.hasError) {
      return _ChatNotice(
        icon: Icons.lock_reset_rounded,
        title: 'Couldn’t set up encryption',
        body: chatError(state.error!),
        action: () => ref.invalidate(chatEngineProvider),
      );
    }
    return RefreshIndicator(
      onRefresh: () async {
        await engine?.pollNow();
        await load();
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(0, 12, 0, 32),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
            child: Text(
              'Chats',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: EncryptedBadge(),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.all(20),
              child: Text(chatError(error!)),
            ),
          if (items == null && error == null)
            const Padding(
              padding: EdgeInsets.all(40),
              child: Center(child: Text('Loading chats…')),
            ),
          if (items?.isEmpty ?? false)
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'No chats yet',
                    style: TextStyle(
                      fontFamily: 'SpaceGrotesk',
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Open someone’s profile and tap Message.',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                  const SizedBox(height: 14),
                  OutlinedButton(
                    onPressed: () => context.go('/discover'),
                    child: const Text('Find people'),
                  ),
                ],
              ),
            ),
          for (final c in items ?? <ChatConversation>[])
            ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 4,
              ),
              leading: CircleAvatar(
                radius: 24,
                backgroundColor: VibeColors.lilac,
                foregroundColor: VibeColors.ink,
                child: Text(
                  c.peerName.characters.firstOrNull?.toUpperCase() ?? '?',
                ),
              ),
              title: Text(
                c.peerName,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              subtitle: typing[c.id]?.isAfter(DateTime.now()) ?? false
                  ? const Text(
                      'typing…',
                      style: TextStyle(fontStyle: FontStyle.italic),
                    )
                  : Text(
                      c.last == null
                          ? '@${c.peerUsername}'
                          : (c.last!.mine ? 'You: ' : '') + c.last!.text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: c.unreadCount > 0
                          ? TextStyle(
                              fontWeight: FontWeight.w700,
                              color: scheme.onSurface,
                            )
                          : null,
                    ),
              trailing: c.unreadCount == 0
                  ? null
                  : Semantics(
                      label: '${c.unreadCount} unread',
                      child: Container(
                        constraints: const BoxConstraints(minWidth: 24),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: VibeColors.lime,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          c.unreadCount > 99 ? '99+' : '${c.unreadCount}',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: VibeColors.ink,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
              onTap: () => context.go(
                '/chats/${c.id}?peer=${Uri.encodeQueryComponent(c.peerId)}&name=${Uri.encodeQueryComponent(c.peerName)}',
              ),
            ),
        ],
      ),
    );
  }
}

class _ChatNotice extends StatelessWidget {
  final IconData icon;
  final String title, body;
  final VoidCallback? action;
  const _ChatNotice({
    required this.icon,
    required this.title,
    required this.body,
    this.action,
  });
  @override
  Widget build(BuildContext context) => ReadingWidth(
    child: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Icon(icon, size: 40),
        const SizedBox(height: 12),
        Text(title, style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(body),
        if (action != null) ...[
          const SizedBox(height: 16),
          OutlinedButton(onPressed: action, child: const Text('Try again')),
        ],
      ],
    ),
  );
}

class ConversationScreen extends ConsumerStatefulWidget {
  final String id, peerId, peerName;
  const ConversationScreen({
    super.key,
    required this.id,
    required this.peerId,
    required this.peerName,
  });
  @override
  ConsumerState<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends ConsumerState<ConversationScreen> {
  final input = TextEditingController();
  final scroll = ScrollController();
  List<ChatMessage> messages = [];
  StreamSubscription<String>? changes;
  ChatEngine? engine;
  bool sending = false;
  DateTime? peerReadAt;
  DateTime lastTyping = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> reload() async {
    final list = await engine!.history(widget.id);
    if (!mounted) return;
    setState(() => messages = list);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (scroll.hasClients) scroll.jumpTo(scroll.position.maxScrollExtent);
    });
    markRead();
  }

  /// Reading happens while this screen is open and the app is in front.
  Future<void> markRead() async {
    if (engine == null ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    try {
      await engine!.markRead(widget.id);
      await ref.read(chatUnreadProvider.notifier).refresh();
    } catch (_) {
      // Next open or signal retries.
    }
  }

  Future<void> loadReceipt() async {
    try {
      final at = await engine?.peerReadAt(widget.id);
      if (mounted && at != peerReadAt) setState(() => peerReadAt = at);
    } catch (_) {}
  }

  /// At most one typing signal every three seconds while composing.
  void typed(String text) {
    if (text.isEmpty) return;
    final now = DateTime.now();
    if (now.difference(lastTyping) < const Duration(seconds: 3)) return;
    lastTyping = now;
    ref.read(realtimeProvider)?.sendTyping(widget.id);
  }

  Future<void> showSafetyNumber() async {
    final current = engine;
    if (current == null) return;
    String? number;
    Object? failure;
    try {
      number = await current.safetyNumber(widget.peerId);
    } catch (e) {
      failure = e;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Verify safety number'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (number != null) ...[
              SelectableText(
                [
                  for (var i = 0; i < number.length; i += 5)
                    number.substring(i, i + 5),
                ].join('  '),
                key: const Key('safety-number'),
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 18,
                  height: 1.8,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Compare these numbers with ${widget.peerName} in person or on a call. If they match, nobody is intercepting your chat. They change when either of you adds or removes a device.',
              ),
            ] else
              Text(chatError(failure!)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  void attach(ChatEngine? next) {
    if (next == null || identical(next, engine)) return;
    engine = next;
    changes = next.changes
        .where((id) => id == widget.id)
        .listen((_) => reload());
    reload();
    loadReceipt();
    next.pollNow().catchError((_) {});
  }

  Future<void> send() async {
    final text = input.text.trim();
    if (text.isEmpty || sending || engine == null) return;
    setState(() => sending = true);
    try {
      await engine!.send(widget.id, widget.peerId, text);
      input.clear();
    } catch (e) {
      if (mounted) showMessage(context, chatError(e));
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  @override
  void dispose() {
    changes?.cancel();
    input.dispose();
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    ref
        .watch(chatEngineProvider)
        .whenData(
          (value) => WidgetsBinding.instance.addPostFrameCallback(
            (_) => attach(value),
          ),
        );
    ref.listen(chatSignalProvider, (_, _) => loadReceipt());
    final until = ref.watch(typingProvider)[widget.id];
    final typing = until != null && until.isAfter(DateTime.now());
    final lastMine = messages.lastWhere(
      (m) => m.mine && !m.notice,
      orElse: () => ChatMessage(
        messageId: '',
        senderId: '',
        text: '',
        sentAt: DateTime(0),
        mine: true,
      ),
    );
    final seen =
        lastMine.serverAt != null &&
        peerReadAt != null &&
        !peerReadAt!.isBefore(lastMine.serverAt!);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 16, 8),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Back to chats',
                onPressed: () => context.go('/chats'),
                icon: const Icon(Icons.arrow_back_rounded),
              ),
              CircleAvatar(
                radius: 18,
                backgroundColor: VibeColors.lilac,
                foregroundColor: VibeColors.ink,
                child: Text(
                  widget.peerName.characters.firstOrNull?.toUpperCase() ?? '?',
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.peerName,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (typing)
                      Text(
                        'typing…',
                        style: TextStyle(
                          fontSize: 11,
                          fontStyle: FontStyle.italic,
                          color: scheme.onSurfaceVariant,
                        ),
                      )
                    else
                      const EncryptedBadge(),
                  ],
                ),
              ),
              IconButton(
                key: const Key('safety-number-button'),
                tooltip: 'Verify safety number',
                onPressed: engine == null ? null : showSafetyNumber,
                icon: const Icon(Icons.verified_user_outlined),
              ),
            ],
          ),
        ),
        Divider(height: 1, color: scheme.outlineVariant),
        Expanded(
          child: messages.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      'Messages are encrypted on this phone and only readable on your and ${widget.peerName}’s devices.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ),
                )
              : ListView.builder(
                  controller: scroll,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 16,
                  ),
                  itemCount: messages.length,
                  itemBuilder: (context, i) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _Bubble(message: messages[i]),
                      if (seen && messages[i].messageId == lastMine.messageId)
                        Padding(
                          padding: const EdgeInsets.only(right: 6, top: 2),
                          child: Text(
                            'Seen',
                            key: const Key('seen'),
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              fontSize: 11,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('chat-input'),
                    controller: input,
                    minLines: 1,
                    maxLines: 5,
                    maxLength: 4000,
                    textInputAction: TextInputAction.send,
                    onChanged: typed,
                    onSubmitted: (_) => send(),
                    decoration: InputDecoration(
                      hintText: 'Message',
                      counterText: '',
                      filled: true,
                      fillColor: scheme.surface,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 12,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  key: const Key('chat-send'),
                  tooltip: 'Send',
                  onPressed: sending || engine == null ? null : send,
                  style: IconButton.styleFrom(
                    backgroundColor: VibeColors.lime,
                    foregroundColor: VibeColors.ink,
                    minimumSize: const Size(48, 48),
                  ),
                  icon: sending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.arrow_upward_rounded),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Bubble extends StatelessWidget {
  final ChatMessage message;
  const _Bubble({required this.message});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (message.notice) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: Text(
            message.text,
            style: TextStyle(
              fontSize: 11,
              fontStyle: FontStyle.italic,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    final time = TimeOfDay.fromDateTime(message.sentAt.toLocal())
        .format(context);
    return Align(
      alignment: message.mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * .75,
        ),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.fromLTRB(14, 9, 14, 7),
          decoration: BoxDecoration(
            color: message.mine ? VibeColors.lime : scheme.surface,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(18),
              topRight: const Radius.circular(18),
              bottomLeft: Radius.circular(message.mine ? 18 : 4),
              bottomRight: Radius.circular(message.mine ? 4 : 18),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                message.text,
                style: TextStyle(
                  color: message.mine ? VibeColors.ink : scheme.onSurface,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                time,
                style: TextStyle(
                  fontSize: 10,
                  color: message.mine
                      ? VibeColors.ink.withValues(alpha: .6)
                      : scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Devices that can read this account's chats. Removing one stops new
/// messages reaching it and deletes anything still waiting for it.
class ChatDevicesScreen extends ConsumerStatefulWidget {
  const ChatDevicesScreen({super.key});
  @override
  ConsumerState<ChatDevicesScreen> createState() => _ChatDevicesState();
}

class _ChatDevicesState extends ConsumerState<ChatDevicesScreen> {
  List<Map<String, dynamic>>? devices;
  Object? error;
  String? busy;

  Future<void> load(ChatEngine engine) async {
    try {
      final next = await engine.myDevices();
      if (mounted) {
        setState(() {
          devices = next;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = e);
    }
  }

  Future<void> remove(ChatEngine engine, Map<String, dynamic> d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove this device?'),
        content: const Text(
          'It will stop receiving your chats, and messages waiting for it are deleted. This can’t be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => busy = d['deviceId'] as String);
    try {
      await engine.revokeDevice(d['deviceId'] as String);
      await load(engine);
      if (mounted) showMessage(context, 'Device removed.');
    } catch (e) {
      if (mounted) showMessage(context, chatError(e));
    } finally {
      if (mounted) setState(() => busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (!chatSupported) {
      return const _ChatNotice(
        icon: Icons.phone_iphone_rounded,
        title: 'Chat devices',
        body: 'Open Kairova on Android or iOS to manage the devices that can read your chats.',
      );
    }
    final engine = ref.watch(chatEngineProvider).asData?.value;
    if (engine != null && devices == null && error == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => load(engine));
    }
    String label(String platform) => switch (platform) {
      'android' => 'Android phone',
      'ios' => 'iPhone',
      'web' => 'Browser',
      'linux' => 'Computer',
      _ => 'Other device',
    };
    String date(String? raw) {
      final at = DateTime.tryParse(raw ?? '')?.toLocal();
      return at == null
          ? ''
          : MaterialLocalizations.of(context).formatMediumDate(at);
    }

    return ReadingWidth(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => context.go('/profile'),
              icon: const Icon(Icons.arrow_back),
              label: const Text('Profile'),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            child: Text(
              'Chat devices',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
            child: Text(
              'Each of these can read your chats. Remove any you don’t recognise.',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(chatError(error!)),
            ),
          if (devices == null && error == null)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('Loading devices…'),
            ),
          for (final d in devices ?? <Map<String, dynamic>>[])
            ListTile(
              leading: Icon(
                d['platform'] == 'ios' || d['platform'] == 'android'
                    ? Icons.phone_iphone_rounded
                    : Icons.computer_rounded,
              ),
              title: Text(
                d['deviceId'] == engine?.deviceId
                    ? '${label(d['platform'] as String)} · This phone'
                    : label(d['platform'] as String),
              ),
              subtitle: Text(
                'Added ${date(d['createdAt'] as String?)} · active ${date(d['lastSeenAt'] as String?)}',
              ),
              trailing: d['deviceId'] == engine?.deviceId || engine == null
                  ? null
                  : TextButton(
                      onPressed: busy == null ? () => remove(engine, d) : null,
                      child: Text(
                        busy == d['deviceId'] ? 'Removing…' : 'Remove',
                      ),
                    ),
            ),
        ],
      ),
    );
  }
}
