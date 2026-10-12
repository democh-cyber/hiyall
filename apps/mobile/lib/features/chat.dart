import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';

import '../core/api.dart';
import '../core/avatar_upload.dart';
import '../core/chat/chat_api.dart';
import '../core/chat/chat_attachment.dart';
import '../core/chat/chat_engine.dart';
import '../core/chat/chat_store.dart';
import '../core/chat_peers.dart';
import '../core/presence.dart';
import '../core/state.dart';
import '../shared/chat_tokens.dart';
import '../shared/person_link.dart';
import '../shared/widgets.dart';
import '../src/rust/frb_generated.dart';
import 'chat_format.dart';
import 'chat_list.dart';
import 'chat_menu.dart';
import 'chat_photo.dart';
import 'chat_thread.dart';
import 'live_sync.dart';
import 'safety.dart';

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

/// The account whose photos this device last held, so signing out (or into
/// another account) removes the first account's cache and unsent uploads.
String? _mediaOwner;

final chatEngineProvider = FutureProvider<ChatEngine?>((ref) async {
  final session = ref.watch(sessionProvider).asData?.value;
  if (!chatSupported) return null;
  final previous = _mediaOwner;
  if (session == null && previous == null) return null;
  final root = await getApplicationSupportDirectory();
  if (previous != null && previous != session?.userId) {
    _mediaOwner = null;
    await ChatEngine.wipeLocalMedia(
      root: root,
      store: SecureChatStore(),
      userId: previous,
    );
  }
  if (session == null) return null;
  _mediaOwner = session.userId;
  await (_rust ??= RustLib.init());
  // The same refresh-then-expire handling as every other API call.
  final rest = ref.read(apiProvider);
  final engine = ChatEngine(
    userId: session.userId,
    api: ChatApi(
      apiBaseUrl,
      session.token,
      tokenOf: () => session.token,
      tokenRefresher: () async => rest.tokenRefresher?.call(),
      onUnauthorized: () => rest.onUnauthorized?.call(),
    ),
    store: SecureChatStore(),
    platform: defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android',
    mediaRoot: root,
  );
  ref.onDispose(engine.dispose);
  await engine.start();
  return engine;
});

/// Words for the reasons a photo could not be sent, or null for any other code.
String? photoFailureText(String? code) => switch (code) {
  'ATTACHMENTS_NOT_ALLOWED' => 'You can send photos once they reply.',
  'PHOTO_TOO_LARGE' ||
  'TOO_LARGE' => 'That photo is too large to send. Try a smaller one.',
  'QUOTA' => 'You’ve sent a lot of photos today. Try again later.',
  'CHAT_MEDIA_UNAVAILABLE' =>
    'Photos aren’t available right now. Try again later.',
  'BLOB_NOT_READY' ||
  'BLOB_SIZE_MISMATCH' ||
  'BLOB_EXPIRED' => 'The upload didn’t finish. Try again.',
  'CANCELED' => 'Upload canceled.',
  'INTERRUPTED' => 'Sending was interrupted.',
  'NETWORK' => 'Couldn’t reach the chat service. Check your connection.',
  'PHOTOS_UNAVAILABLE' => 'Photos can only be sent from the Hiyall app.',
  'LOCAL_DATA_LOST' =>
    'This photo can’t be sent again. Delete it and choose it again.',
  _ => null,
};

String chatError(Object error) =>
    (error is ChatFailure ? photoFailureText(error.code) : null) ??
    switch (error) {
      ChatFailure(code: 'MESSAGES_NOT_ALLOWED') =>
        'They aren’t accepting messages from you right now.',
      ChatFailure(code: 'CONVERSATION_CLOSED' || 'NOT_FOUND') =>
        'This conversation isn’t available.',
      ChatFailure(code: 'KEY_CHANGED') =>
        'Their security keys changed unexpectedly, so sending is paused.',
      ChatFailure(code: 'RATE_LIMITED') =>
        'You’re sending a lot. Wait a moment.',
      ChatFailure(:final message) => message,
      _ => 'Something went wrong with encryption on this device.',
    };

class ChatsScreen extends ConsumerStatefulWidget {
  const ChatsScreen({super.key});
  @override
  ConsumerState<ChatsScreen> createState() => _ChatsScreenState();
}

/// How long typing in the search field waits before the list filters.
const chatSearchDebounce = Duration(milliseconds: 200);

class _ChatsScreenState extends ConsumerState<ChatsScreen> {
  List<ChatConversation>? items;
  Object? error;
  StreamSubscription<String>? changes;
  ChatEngine? engine;
  final search = TextEditingController();
  Timer? _debounce;

  /// The search text the list is filtered by (after the debounce).
  String query = '';
  ChatFilter filter = ChatFilter.all;

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
        // Discover reads this to show Message instead of Say hi.
        ref.read(chatPeersProvider.notifier).load({
          for (final c in next)
            if (c.last != null) c.peerId: c.id,
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

  /// Filters 200 ms after the last keystroke; emptying the field is immediate.
  void onSearch(String text) {
    _debounce?.cancel();
    if (text.trim().isEmpty) {
      if (query.isNotEmpty) setState(() => query = '');
      return;
    }
    _debounce = Timer(chatSearchDebounce, () {
      if (mounted) setState(() => query = text);
    });
  }

  void clearSearch() {
    _debounce?.cancel();
    search.clear();
    setState(() => query = '');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    changes?.cancel();
    search.dispose();
    super.dispose();
  }

  void open(ChatConversation c) => context.go(
    '/chats/${c.id}?peer=${Uri.encodeQueryComponent(c.peerId)}&name=${Uri.encodeQueryComponent(c.peerName)}',
  );

  @override
  Widget build(BuildContext context) {
    if (!chatSupported) {
      return const _ChatNotice(
        icon: Icons.phone_iphone_rounded,
        title: 'Chats live in the app',
        body: 'Private chats are end-to-end encrypted with keys kept in your phone’s secure storage. Open Hiyall on Android or iOS to chat.',
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
      return const _ChatNotice(
        icon: Icons.lock_outline_rounded,
        title: 'Setting up encryption…',
        body: 'Creating the keys that keep your chats private. This only takes a moment.',
      );
    }
    if (state.hasError) {
      return _ChatNotice(
        icon: Icons.lock_reset_rounded,
        title: 'Couldn’t set up encryption',
        body: chatError(state.error!),
        action: () => ref.invalidate(chatEngineProvider),
      );
    }
    final now = ref.watch(chatClockProvider)();
    final all = items;
    final shown = all == null
        ? null
        : filterChats(all, query: query, filter: filter);
    // The app shell already prints "Chats" above wide layouts.
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final hasChats = all != null && all.isNotEmpty;
    final narrowed = query.trim().isNotEmpty || filter != ChatFilter.all;
    return RefreshIndicator(
      onRefresh: () async {
        await engine?.pollNow();
        await load();
      },
      child: LayoutBuilder(
        builder: (context, box) {
          final side = math.max(0.0, (box.maxWidth - chatListMaxWidth) / 2);
          final empty = all != null && all.isEmpty;
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(side, wide ? 0 : 6, side, 32),
            children: [
              ChatsHeading(subtitle: chatsSubtitle(all), showTitle: !wide),
              if (hasChats) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: ChatMetrics.pagePadding,
                  ),
                  child: ChatSearchField(
                    controller: search,
                    onChanged: onSearch,
                  ),
                ),
                ChatFilterChips(
                  filter: filter,
                  unread: unreadChatCount(all),
                  onChanged: (f) => setState(() => filter = f),
                ),
                if (!narrowed)
                  MeetSomeoneCard(onTap: () => context.go('/discover'))
                else
                  const SizedBox(height: 6),
              ],
              if (error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: ChatMessageCard(
                    icon: Icons.cloud_off_rounded,
                    title: 'Couldn’t load your chats',
                    body: chatError(error!),
                    primaryLabel: 'Try again',
                    onPrimary: load,
                  ),
                ),
              if (all == null && error == null) const ChatListSkeleton(),
              if (empty)
                ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: math.max(420, box.maxHeight - 120),
                  ),
                  child: ChatMessageCard(
                    key: const Key('chats-empty'),
                    art: const HelloArt(height: 150),
                    title: 'No conversations yet',
                    body: 'Someone interesting is one hello away.',
                    primaryLabel: 'Meet someone new',
                    onPrimary: () => context.go('/discover'),
                    secondaryLabel: 'Say hi to your followers',
                    onSecondary: () => context.go('/profile/followers'),
                  ),
                ),
              if (shown != null && shown.isEmpty && !empty)
                query.trim().isEmpty
                    ? ChatMessageCard(
                        key: const Key('chats-no-unread'),
                        icon: Icons.done_all_rounded,
                        title: 'No unread conversations',
                        body: 'You’re all caught up.',
                        primaryLabel: 'Show all chats',
                        onPrimary: () =>
                            setState(() => filter = ChatFilter.all),
                      )
                    : ChatMessageCard(
                        key: const Key('chats-no-match'),
                        icon: Icons.search_off_rounded,
                        title: 'No conversations found',
                        body:
                            'Nothing matches “${query.trim()}”. Try a name, a @username or something they said.',
                        primaryLabel: 'Clear search',
                        onPrimary: clearSearch,
                        secondaryLabel: 'Meet someone new',
                        onSecondary: () => context.go('/discover'),
                      ),
              if (shown != null)
                for (var i = 0; i < shown.length; i++)
                  ChatRow(
                    key: ValueKey(shown[i].id),
                    chat: shown[i],
                    now: now,
                    typing:
                        typing[shown[i].id]?.isAfter(DateTime.now()) ?? false,
                    showDivider: i < shown.length - 1,
                    onTap: () => open(shown[i]),
                  ),
              if (shown != null && shown.isNotEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 18),
                  child: Center(child: EncryptedChip()),
                ),
            ],
          );
        },
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
  Widget build(BuildContext context) => ChatMessageCard(
    scrollable: true,
    icon: icon,
    title: title,
    body: body,
    primaryLabel: action == null ? null : 'Try again',
    onPrimary: action,
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
  final focus = FocusNode();
  final scroll = ScrollController();
  List<ChatMessage> messages = [];
  StreamSubscription<String>? changes;
  ChatEngine? engine;
  bool sending = false, attaching = false;
  DateTime? peerReadAt;
  DateTime? mutedUntil;

  /// History has been read at least once, so "empty" is a fact.
  bool loaded = false;

  /// Messages already on screen; later arrivals pop in, history does not.
  final known = <String>{}, fresh = <String>{}, played = <String>{};

  /// How many of the peer's messages were unread when this chat was opened,
  /// and the first of them once history is there. Taken once: reading them
  /// as the screen opens does not move the divider.
  int unreadAtOpen = 0, unreadTries = 0;
  bool unreadCaptured = false, unreadResolved = false;
  String? unreadFrom;
  bool _typingShown = false;

  /// From the route when opened from the chat list; otherwise loaded below.
  late String peerId = widget.peerId, peerName = widget.peerName;
  String? peerAvatarUrl;
  DateTime lastTyping = DateTime.fromMillisecondsSinceEpoch(0);

  /// The person is reading the bottom of the thread (or there is nothing to
  /// scroll yet). Updated as they scroll, and decides whether new messages
  /// move the view and whether the "latest" button shows.
  bool atBottom = true;

  /// Messages that arrived while they were reading further up.
  int newWhileAway = 0;

  /// The first-time card was dismissed.
  bool introDismissed = false;

  /// What the server says both people list (its audience rules already
  /// applied), and whether the first look at the conversation has come back:
  /// the new-chat card waits for it so its icebreakers do not change under
  /// the person's thumb.
  List<String> sharedInterests = const [];
  bool receiptLoaded = false;

  /// The peer's presence as the server last said it (see [ChatHeader]). Read
  /// with the rest of the server-held state in [loadReceipt], which already
  /// reruns on every chat signal and on the slow presence refresh.
  bool peerOnline = false;
  DateTime? peerLastSeenAt;

  bool get _nearBottom =>
      !scroll.hasClients ||
      isNearBottom(
        pixels: scroll.position.pixels,
        maxExtent: scroll.position.maxScrollExtent,
      );

  void _onScroll() {
    final near = _nearBottom;
    if (near == atBottom) return;
    setState(() {
      atBottom = near;
      if (near) newWhileAway = 0;
    });
  }

  /// Moves to the newest message. Rows below are only estimated until they are
  /// built, so the end can move while jumping: look again for a few frames.
  void _stickToBottom([int tries = 4]) =>
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!scroll.hasClients) return;
        final end = scroll.position.maxScrollExtent;
        if (scroll.position.pixels < end - 1) {
          scroll.jumpTo(end);
          if (tries > 1) _stickToBottom(tries - 1);
        }
      });

  /// The "latest" button: down to the newest message, gently unless motion is
  /// reduced, and the count of what came in meanwhile starts again.
  Future<void> jumpToLatest() async {
    setState(() => newWhileAway = 0);
    if (!scroll.hasClients) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _stickToBottom();
      return;
    }
    await scroll.animateTo(
      scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
    // Rows below were only estimated until they were built.
    _stickToBottom();
  }

  Future<void> reload() async {
    final List<ChatMessage> list;
    try {
      list = await engine!.history(widget.id);
    } catch (_) {
      if (mounted) setState(() => loaded = true);
      rethrow;
    }
    if (!mounted) return;
    var arrived = 0;
    final firstLoad = !loaded;
    final stick = shouldAutoScroll(
      firstLoad: firstLoad,
      nearBottom: _nearBottom,
      sentNewOwnMessage:
          loaded && list.any((m) => m.mine && !known.contains(m.messageId)),
    );
    setState(() {
      if (!loaded) {
        known.addAll(list.map((m) => m.messageId));
      } else {
        for (final m in list) {
          if (known.add(m.messageId)) {
            fresh.add(m.messageId);
            if (!m.mine && !m.notice) arrived++;
          }
        }
      }
      loaded = true;
      messages = list;
      // Reading older messages: keep the place and count what came in.
      if (!stick && arrived > 0) newWhileAway += arrived;
      _resolveUnread();
    });
    if (stick) _stickToBottom();
    markRead();
  }

  /// Finds the first message the person had not read, once both the unread
  /// count and enough of the history are here.
  void _resolveUnread() {
    if (unreadResolved || !unreadCaptured || !loaded) return;
    if (unreadAtOpen <= 0) {
      unreadResolved = true;
      return;
    }
    final incoming = [
      for (final m in messages)
        if (!m.mine && !m.notice) m,
    ];
    // A message still in the inbox is not in history yet; wait a little.
    if (incoming.length < unreadAtOpen && unreadTries++ < 3) return;
    unreadResolved = true;
    if (incoming.isEmpty) return;
    final index = math.max(0, incoming.length - unreadAtOpen);
    unreadFrom = incoming[index].messageId;
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

  /// Reloads the server-held state: the peer's read pointer and our mute.
  Future<void> loadReceipt() async {
    try {
      final c = await engine?.api.conversation(widget.id);
      if (c == null || !mounted) return;
      final shared = parseSharedInterests(c['sharedInterests']);
      if (!receiptLoaded || !listEquals(shared, sharedInterests)) {
        setState(() {
          receiptLoaded = true;
          sharedInterests = shared;
        });
      }
      final at = DateTime.tryParse(c['peerReadAt'] as String? ?? '');
      final muted = DateTime.tryParse(c['mutedUntil'] as String? ?? '');
      final peer = c['peer'] as Map? ?? const {};
      final avatar = peer['avatarUrl'] as String?;
      if (!unreadCaptured) {
        setState(() {
          unreadCaptured = true;
          unreadAtOpen = (c['unreadCount'] as num?)?.toInt() ?? 0;
          _resolveUnread();
        });
      }
      if (avatar != peerAvatarUrl) setState(() => peerAvatarUrl = avatar);
      final presence = parsePresence(peer);
      if (presence.online != peerOnline ||
          presence.lastSeenAt != peerLastSeenAt) {
        setState(() {
          peerOnline = presence.online;
          peerLastSeenAt = presence.lastSeenAt;
        });
      }
      if (peerId.isEmpty && peer['userId'] is String) {
        final display = (peer['displayName'] as String? ?? '').trim();
        setState(() {
          peerId = peer['userId'] as String;
          peerName = display.isEmpty ? '@${peer['username']}' : display;
        });
      }
      if (at != peerReadAt || muted != mutedUntil) {
        setState(() {
          peerReadAt = at;
          mutedUntil = muted;
        });
      }
    } catch (_) {
      // Without the first look the card simply waits less: show it as it is.
      if (mounted && !receiptLoaded) setState(() => receiptLoaded = true);
    }
  }

  bool get muted => mutedUntil?.isAfter(DateTime.now()) ?? false;

  Future<void> options() async {
    final choice = await showChatSafetyMenu(
      context,
      muted: muted,
      peerName: peerName,
    );
    if (!mounted || choice == null || engine == null) return;
    switch (choice) {
      case ChatMenuAction.mute:
        DateTime? until;
        if (!muted) {
          final picked = await pickMuteDuration(
            context,
            title: 'Mute this chat',
          );
          if (picked == null) return;
          until = picked.until;
        }
        try {
          await engine!.api.muteConversation(widget.id, !muted, until: until);
          await loadReceipt();
          await ref.read(chatUnreadProvider.notifier).refresh();
          ref.read(chatSignalProvider.notifier).bump();
          if (mounted) {
            showMessage(context, muted ? 'Chat muted.' : 'Chat unmuted.');
          }
        } catch (e) {
          if (mounted) showMessage(context, chatError(e));
        }
      case ChatMenuAction.profile:
        openPerson(context, peerId);
      case ChatMenuAction.report:
        await reportPeer();
      case ChatMenuAction.block:
        await blockPeer();
    }
  }

  /// The report flow (its sheet can also block). The menu and the new-chat
  /// card both call this.
  Future<void> reportPeer() async {
    final receipt = await showReportSheet(
      context,
      ref,
      targetType: 'conversation',
      targetId: widget.id,
      name: peerName,
      messages: messages,
    );
    if ((receipt?.blocked ?? false) && mounted) context.go('/chats');
  }

  /// Asks first, then blocks and leaves the chat. The menu and the new-chat
  /// card both call this.
  Future<void> blockPeer() async {
    final session = ref.read(sessionProvider).asData?.value;
    if (peerId.isEmpty || session == null) return;
    if (!await confirmBlock(context, peerName) || !mounted) return;
    final api = ref.read(apiProvider);
    try {
      await api.block(session, peerId, true);
      ref.invalidate(otherProfileProvider(peerId));
      ref.invalidate(profileProvider);
      ref.read(chatSignalProvider.notifier).bump();
      if (!mounted) return;
      showMessage(context, 'Account blocked.');
      context.go('/chats');
    } catch (e) {
      if (mounted) showMessage(context, chatError(e));
    }
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
      number = await current.safetyNumber(peerId);
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
              Text(
                'Messages and photos in this chat are end-to-end encrypted: only you and $peerName can read them.',
              ),
              const SizedBox(height: 12),
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
                'Compare these numbers with $peerName in person or on a call. If they match, nobody is intercepting your chat. They change when either of you adds or removes a device.',
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
    // The receipt first: its unread count must be read before opening the
    // chat marks everything read.
    loadReceipt();
    reload();
    next.pollNow().catchError((_) {});
  }

  Future<void> send() async {
    final text = input.text.trim();
    if (text.isEmpty || sending || engine == null || peerId.isEmpty) return;
    unawaited(sendHaptic());
    setState(() => sending = true);
    try {
      await engine!.send(widget.id, peerId, text);
      input.clear();
    } catch (e) {
      if (mounted) showMessage(context, chatError(e));
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  /// A conversation starter goes into the composer for the person to edit or
  /// send; nothing is sent for them.
  void starter(String text) {
    input.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    focus.requestFocus();
  }

  /// Choose or take a photo, preview it with an optional caption, then send.
  /// The message appears at once; the upload carries on in the background.
  Future<void> attachPhoto() async {
    final current = engine;
    if (current == null || peerId.isEmpty || attaching) return;
    final source = await showAttachSheet(context);
    if (source == null || !mounted) return;
    setState(() => attaching = true);
    Uint8List? bytes;
    try {
      bytes = await pickChatPhoto(ref.read(imagePickerProvider), source);
    } catch (e) {
      if (mounted) showMessage(context, photoPickError(e));
      return;
    } finally {
      if (mounted) setState(() => attaching = false);
    }
    if (bytes == null || !mounted) return;
    final caption = await showPhotoPreview(context, bytes, peerName);
    if (caption == null || !mounted) return;
    try {
      await current.sendPhoto(widget.id, peerId, bytes, caption: caption);
    } catch (e) {
      if (mounted) showMessage(context, chatError(e));
    }
  }

  Future<void> retryPhoto(ChatMessage message) async {
    try {
      await engine?.retryPhoto(widget.id, message.messageId);
    } catch (e) {
      if (mounted) showMessage(context, chatError(e));
    }
  }

  Future<void> deletePhoto(ChatMessage message) async {
    try {
      await engine?.discardPhoto(widget.id, message.messageId);
    } catch (e) {
      if (mounted) showMessage(context, chatError(e));
    }
  }

  @override
  void initState() {
    super.initState();
    scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    changes?.cancel();
    scroll.removeListener(_onScroll);
    input.dispose();
    focus.dispose();
    scroll.dispose();
    super.dispose();
  }

  bool _seen(ChatMessage m) =>
      m.mine &&
      m.serverAt != null &&
      peerReadAt != null &&
      !peerReadAt!.isBefore(m.serverAt!);

  Widget _row(
    BuildContext context,
    ThreadRow row,
    DateTime now,
    String? newestMine,
  ) {
    switch (row) {
      case DayRow(:final day):
        return DayChip(chatDayLabel(day, now), key: ValueKey('day-$day'));
      case NoticeRow(:final message):
        return NoticeChip(message.text, key: ValueKey(message.messageId));
      case UnreadRow():
        return const NewMessagesDivider();
      case TypingRow():
        return TypingBubble(
          peerName: peerName,
          peerId: peerId,
          peerAvatarUrl: peerAvatarUrl,
        );
      case MessageRow():
        final m = row.message;
        Widget bubble = ChatBubble(
          row: row,
          engine: engine,
          conversationId: widget.id,
          peerName: peerName,
          peerId: peerId,
          peerAvatarUrl: peerAvatarUrl,
          seen: _seen(m),
          newestMine: m.messageId == newestMine,
        );
        if (fresh.contains(m.messageId)) {
          bubble = BubbleEntrance(
            key: ValueKey('enter-${m.messageId}'),
            mine: m.mine,
            animate: !played.contains(m.messageId),
            onDone: () => played.add(m.messageId),
            child: bubble,
          );
        }
        return Column(
          key: ValueKey(m.messageId),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            bubble,
            if (m.mine && m.attachment != null && m.status == SendStatus.failed)
              FailedPhotoActions(
                message: m,
                error: photoFailureText(m.failure) ?? 'This photo wasn’t sent.',
                onRetry: () => retryPhoto(m),
                onDelete: () => deletePhoto(m),
              ),
          ],
        );
    }
  }

  @override
  Widget build(BuildContext context) {
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
    if (typing != _typingShown) {
      _typingShown = typing;
      if (typing && _nearBottom) _stickToBottom();
    }
    final now = ref.watch(chatClockProvider)();
    final newestMine = messages
        .where((m) => m.mine && !m.notice)
        .map((m) => m.messageId)
        .lastOrNull;
    final rows = buildThread(messages, unreadFrom: unreadFrom, typing: typing);
    final showJump = loaded && messages.isNotEmpty && !atBottom;
    return ChatAtmosphere(
      child: Column(
        children: [
          ChatHeader(
            name: peerName,
            userId: peerId,
            avatarUrl: peerAvatarUrl,
            typing: typing,
            online: peerOnline,
            lastSeenAt: peerLastSeenAt,
            now: now,
            muted: muted,
            canAct: engine != null,
            onBack: () => context.go('/chats'),
            onSafety: showSafetyNumber,
            onOptions: options,
            onProfile: peerId.isEmpty
                ? null
                : () => openPerson(context, peerId),
          ),
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                !loaded || (messages.isEmpty && !receiptLoaded)
                    ? const Align(
                        alignment: Alignment.topCenter,
                        child: ThreadLoading(),
                      )
                    : messages.isEmpty
                    ? (introDismissed
                          ? const QuietNewChat()
                          : NewChatCard(
                              name: peerName,
                              userId: peerId,
                              conversationId: widget.id,
                              avatarUrl: peerAvatarUrl,
                              sharedInterests: sharedInterests,
                              onPick: starter,
                              onDismiss: () =>
                                  setState(() => introDismissed = true),
                              onReport: reportPeer,
                              onBlock: blockPeer,
                            ))
                    : LayoutBuilder(
                        builder: (context, box) {
                          final side = math.max(
                            12.0,
                            (box.maxWidth - conversationMaxWidth) / 2 + 12,
                          );
                          return ListView.builder(
                            controller: scroll,
                            padding: EdgeInsets.fromLTRB(side, 8, side, 12),
                            itemCount: rows.length,
                            itemBuilder: (context, i) =>
                                _row(context, rows[i], now, newestMine),
                          );
                        },
                      ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 6,
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: conversationMaxWidth,
                      ),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ScrollToLatestButton(
                            visible: showJump,
                            count: newWhileAway,
                            onTap: jumpToLatest,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          ChatComposer(
            controller: input,
            focus: focus,
            sending: sending,
            canSend: !sending && engine != null,
            canAttach: engine != null && peerId.isNotEmpty && !attaching,
            showAttach: chatSupported,
            onChanged: typed,
            onSend: send,
            onAttach: attachPhoto,
          ),
        ],
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
        body: 'Open Hiyall on Android or iOS to manage the devices that can read your chats.',
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
