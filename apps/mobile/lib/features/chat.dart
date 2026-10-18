import 'dart:async';
import 'dart:io' show Directory;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart'
    show IOSOptions, KeychainAccessibility;
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';

import '../core/api.dart';
import '../core/app_info.dart';
import '../core/avatar_upload.dart';
import '../core/chat/chat_api.dart';
import '../core/chat/chat_attachment.dart';
import '../core/chat/chat_av_outbox.dart' show PreparedVideo, VoiceClip;
import '../core/chat/chat_voice_capture.dart';
import '../core/chat/chat_voice_player.dart' show VoicePlayback;
import '../core/chat/chat_prefs.dart';
import '../core/translate/speech_service.dart';
import '../core/translate/translation_memory.dart';
import '../core/translate/translation_service.dart';
import '../core/chat/chat_backup_exclusion.dart';
import '../core/chat/chat_engine.dart';
import '../core/chat/chat_local_data.dart';
import '../core/chat/chat_reactions.dart';
import '../core/chat/chat_snapshot.dart';
import '../core/chat/chat_storage_health.dart';
import '../core/chat/chat_store.dart';
import '../core/chat_peers.dart';
import '../core/chat_wipe_hook.dart' show chatOwnerToWipe, chatWipeSettled;
import '../core/presence.dart';
import '../core/secure_storage.dart';
import '../core/state.dart';
import '../shared/chat_tokens.dart';
import '../shared/person_link.dart';
import '../shared/widgets.dart';
import '../src/rust/frb_generated.dart';
import 'chat_av_providers.dart';
import 'chat_format.dart';
import 'chat_list_actions.dart';
import 'chat_list.dart';
import 'chat_menu.dart';
import 'chat_photo.dart';
import 'chat_thread.dart';
import 'chat_translate_ui.dart';
import 'chat_video_ui.dart';
import 'chat_voice_ui.dart';
import 'live_sync.dart';
import 'safety.dart';

/// Keys and ratchet state live in the platform keystore (Android Keystore /
/// iOS Keychain backed), never in plain app storage. On iOS the items are
/// readable after the first unlock and never leave this device (no backup, no
/// move to a new phone). The Keychain does survive deleting the app, which is
/// why the first launch after a reinstall erases what it finds (see
/// [ChatLocalData.eraseAfterReinstall]).
class SecureChatStore implements ChatStore {
  static final _storage = createSecureStorage(
    iOptions: const IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  @override
  Future<String?> read(String key) => _guard(() => _storage.read(key: key));
  @override
  Future<void> write(String key, String value) =>
      _guard(() => _storage.write(key: key, value: value));
  @override
  Future<void> delete(String key) => _guard(() => _storage.delete(key: key));
  @override
  Future<List<String>> keys() =>
      _guard(() async => (await _storage.readAll()).keys.toList());
  @override
  Future<T> batch<T>(Future<T> Function() work) => work();

  /// Any platform failure of the keystore is [ChatStorageUnavailable]: an error to try again, which nothing
  /// above may answer by deleting or regenerating keys (audit CHAT-N4).
  static Future<T> _guard<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } on ChatStorageUnavailable {
      rethrow;
    } catch (error) {
      throw ChatStorageUnavailable(error);
    }
  }
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

/// The previous engine's shutdown (see [ChatEngine.dispose]): the next build waits for it before it wipes
/// anything, so work that was in flight cannot write after the wipe.
Future<void> _previousEngine = Future.value();

/// The chat API for the signed-in account without an engine: the device list
/// and removing a device work even when the engine could not start (for
/// example because the account already has ten devices).
final chatApiProvider = Provider<ChatApi?>((ref) {
  final session = ref.watch(sessionProvider).asData?.value;
  if (session == null || !chatSupported) return null;
  final rest = ref.read(apiProvider);
  return ChatApi(
    apiBaseUrl,
    session.token,
    tokenOf: () => session.token,
    tokenRefresher: () async => rest.tokenRefresher?.call(),
    onUnauthorized: () => rest.onUnauthorized?.call(),
    clientVersion: AppInfo.version,
    clientPlatform: clientPlatform,
    onUpgradeRequired: () => rest.onUpgradeRequired?.call(),
    onAppCheckRequired: () => rest.onAppCheckRequired?.call(),
  );
});

/// This phone's chat device id for the signed-in account, or null.
final thisChatDeviceProvider = FutureProvider<String?>((ref) async {
  final session = ref.watch(sessionProvider).asData?.value;
  if (session == null || !chatSupported) return null;
  return SecureChatStore().read(
    '${ChatLocalData.prefix(session.userId)}deviceId',
  );
});

/// Set when [ChatStorageUnavailable] stopped the engine on enough launches in a row that the person may
/// choose "Reset chat on this phone" (see [ChatStorageHealth]).
final chatStorageResetOfferedProvider =
    NotifierProvider<ChatResetOffered, bool>(ChatResetOffered.new);

/// Holds whether the explicit reset is offered; public so tests can stand in for it.
class ChatResetOffered extends Notifier<bool> {
  @override
  bool build() => false;
  void set(bool value) => state = value;
}

/// Waits before the engine is opened again after the keystore could not be opened; after the last one the
/// person's "Try again" is what retries.
const chatStorageRetryDelays = [
  Duration(seconds: 3),
  Duration(seconds: 10),
  Duration(seconds: 30),
  Duration(seconds: 60),
  Duration(minutes: 2),
];
bool _storageFailureCounted = false;
int _storageRetries = 0;

/// The notice the next engine starts with, set by the explicit reset ([resetChatOnThisPhone]).
DeviceNoticeKind? _nextStartNotice;

/// "Reset chat on this phone", the explicit, destructive way out when the platform keystore cannot be opened
/// launch after launch: this account's chat data goes (snapshot, photos, keys; the chat entries are removed by
/// name when the keystore cannot list them, and nothing else the app keeps there is touched), a new chat identity is made, and a notice says so. The old device stays on
/// the account's device list until it is removed there or goes stale.
Future<void> resetChatOnThisPhone(WidgetRef ref) async {
  final session = ref.read(sessionProvider).asData?.value;
  if (session == null) return;
  final root = await getApplicationSupportDirectory();
  await _previousEngine;
  await ChatLocalData.resetAfterStorageFailure(
    root: root,
    store: SecureChatStore(),
    userId: session.userId,
  );
  await ChatStorageHealth(root).clear();
  _nextStartNotice = DeviceNoticeKind.storage;
  _storageFailureCounted = false;
  _storageRetries = 0;
  ref.read(chatStorageResetOfferedProvider.notifier).set(false);
  ref.invalidate(chatEngineProvider);
}

final chatEngineProvider = FutureProvider<ChatEngine?>((ref) async {
  try {
    final engine = await _openChatEngine(ref);
    if (engine != null) {
      _storageFailureCounted = false;
      _storageRetries = 0;
      ref.read(chatStorageResetOfferedProvider.notifier).set(false);
      try {
        await ChatStorageHealth(await getApplicationSupportDirectory()).clear();
      } catch (_) {}
    }
    return engine;
  } on ChatStorageUnavailable {
    await _noteStorageFailure(ref);
    rethrow;
  }
}, retry: _chatEngineRetry);

/// Riverpod retries a failed provider on its own. A keystore that cannot be opened is retried by
/// [_noteStorageFailure] instead (growing waits, counted once per launch, the error stays on screen while it
/// waits); everything else keeps Riverpod's default.
Duration? _chatEngineRetry(int attempt, Object error) =>
    error is ChatStorageUnavailable
    ? null
    : ProviderContainer.defaultRetry(attempt, error);

/// The keystore could not be opened. Nothing is deleted or regenerated. The launch is counted once (however
/// often it is retried), the engine is opened again after a growing wait, and once enough launches in a row
/// have failed the reset is offered.
Future<void> _noteStorageFailure(Ref ref) async {
  try {
    final health = ChatStorageHealth(await getApplicationSupportDirectory());
    if (!_storageFailureCounted) {
      _storageFailureCounted = true;
      await health.recordFailedLaunch();
    }
    if (!ref.mounted) return;
    ref
        .read(chatStorageResetOfferedProvider.notifier)
        .set(await health.resetOffered());
    if (_storageRetries < chatStorageRetryDelays.length && ref.mounted) {
      final timer = Timer(chatStorageRetryDelays[_storageRetries++], () {
        if (ref.mounted) ref.invalidateSelf();
      });
      ref.onDispose(timer.cancel);
    }
  } catch (_) {
    // Only the bookkeeping failed; the error itself is still shown.
  }
}

Future<ChatEngine?> _openChatEngine(Ref ref) async {
  final sessionState = ref.watch(sessionProvider);
  final session = sessionState.asData?.value;
  if (!chatSupported) return null;
  // A sign-out wipe that is still running (it may have outlived its hook's time limit) finishes before
  // anything is opened, so it cannot delete what this engine writes.
  await chatWipeSettled();
  final secure = SecureChatStore();
  var previous = _mediaOwner;
  // Signed out for certain (not still starting up): whatever this device
  // holds, even from a run before this one, goes.
  final signedOut = sessionState is AsyncData<Session?> && session == null;
  if (session == null && previous == null && !signedOut) return null;
  // Data of another account is erased before this one's engine opens. A fresh process has no previous
  // owner of its own, so the owner recorded in the keystore stands in for it.
  previous = await chatOwnerToWipe(
    store: secure,
    lastSeen: previous,
    sessionUser: session?.userId,
  );
  if (session == null && previous == null) return null;
  final root = await getApplicationSupportDirectory();
  await _previousEngine;
  if (previous != null && previous != session?.userId) {
    _mediaOwner = null;
    await ChatLocalData.wipeAccount(
      root: root,
      store: secure,
      userId: previous,
    );
  }
  if (session == null) return null;
  _mediaOwner = session.userId;
  await ChatLocalData.eraseAfterReinstall(root: root, store: secure);
  // iOS: the chat folders are flagged out of backups before anything is written to them.
  await ChatBackupExclusion.apply(root);
  await (_rust ??= RustLib.init());
  // Everything the engine keeps lives in one encrypted file per account,
  // committed atomically (see SnapshotChatStore); entries an earlier build
  // wrote one by one into the keystore are moved into it here.
  final store = await SnapshotChatStore.open(
    secure: secure,
    userId: session.userId,
    files: DirectorySnapshotFiles(Directory('${root.path}/chat_state')),
  );
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
      clientVersion: AppInfo.version,
      clientPlatform: clientPlatform,
      onUpgradeRequired: () => rest.onUpgradeRequired?.call(),
      onAppCheckRequired: () => rest.onAppCheckRequired?.call(),
    ),
    store: store,
    platform: defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android',
    mediaRoot: root,
    startNotice: _nextStartNotice,
  );
  _nextStartNotice = null;
  // Signing out removes this phone's chat device on the server while the
  // credential still works; if that fails the id is remembered and removed on a
  // later launch. The server also drops the device when the session ends.
  final notifier = ref.read(sessionProvider.notifier);
  Future<void> removeDevice() async {
    try {
      await engine.revokeThisDevice().timeout(const Duration(seconds: 4));
    } catch (_) {
      // Remembered by the wipe that follows.
    }
  }

  notifier.signOutHooks.add(removeDevice);
  // The inbox timer runs only in the foreground, like the rest of LiveSync's
  // timers; a push or the next resume brings what arrived meanwhile.
  final lifecycle = AppLifecycleListener(
    onPause: engine.pause,
    onResume: engine.resume,
  );
  ref.onDispose(() {
    notifier.signOutHooks.remove(removeDevice);
    lifecycle.dispose();
    _previousEngine = engine.dispose();
  });
  await engine.start();
  if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused) {
    engine.pause();
  }
  return engine;
}

/// Words for the reasons a photo could not be sent, or null for any other code.
String? photoFailureText(String? code) => switch (code) {
  'ATTACHMENTS_NOT_ALLOWED' =>
    'You can send photos, voice messages and videos once they reply.',
  'PHOTO_TOO_LARGE' ||
  'TOO_LARGE' => 'That photo is too large to send. Try a smaller one.',
  'QUOTA' => 'You’ve sent a lot of media today. Try again later.',
  'CHAT_MEDIA_UNAVAILABLE' => 'Photos, voice messages and videos aren’t available right now. Try again later.',
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

/// What a failed chat call says. [peerName] is the other person in the conversation the call was about, when
/// the caller knows it, for the refusals that are about them (`PEER_NO_DEVICES`).
String chatError(Object error, {String? peerName}) =>
    (error is ChatFailure ? photoFailureText(error.code) : null) ??
    switch (error) {
      ChatStorageUnavailable() => 'Couldn’t open secure storage. Nothing was deleted. We’ll try again in a moment.',
      ChatFailure(code: 'MESSAGES_NOT_ALLOWED') =>
        'They aren’t accepting messages from you right now.',
      ChatFailure(code: 'CONVERSATION_CLOSED' || 'NOT_FOUND') =>
        'This conversation isn’t available.',
      ChatFailure(code: 'KEY_CHANGED') =>
        'Their security keys changed unexpectedly, so sending is paused.',
      ChatFailure(code: 'AWAITING_REPLY') =>
        'You can send more once they reply. Give them a little time.',
      ChatFailure(code: 'TOO_MANY_DEVICES') => 'This account has too many chat devices. Remove one in Profile, Chat devices.',
      ChatFailure(code: 'RATE_LIMITED') =>
        'You’re sending a lot. Wait a moment.',
      ChatFailure(code: 'RECIPIENT_BACKLOG') =>
        'They haven’t caught up on earlier messages yet. Try again later.',
      ChatFailure(code: 'PEER_NO_DEVICES') =>
        '${peerName == null || peerName.trim().isEmpty ? 'They haven’t' : '${peerName.trim()} hasn’t'} opened Hiyall in a while. Your message can’t be delivered yet.',
      ChatFailure(code: 'OWN_BACKLOG') => 'One of your other devices has too many unread messages. Open Chat devices (Profile, Chat devices), open Hiyall on that device or remove it.',
      ChatFailure(code: 'CHAT_DAILY_LIMIT') =>
        'You’ve sent a lot of messages in this chat today. Try again later.',
      ChatFailure(:final message) => message,
      _ => 'Something went wrong with encryption on this device.',
    };

/// The relay refused a send because one of the sender's own other devices holds too many unread messages
/// (`OWN_BACKLOG`): the words say to open Chat devices, and the button goes there. The message stays "Not
/// sent" and can be tried again once that device picked its messages up or was removed.
void showOwnBacklogMessage(BuildContext context) =>
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          key: const Key('own-backlog-message'),
          content: Text(chatError(const ChatFailure('OWN_BACKLOG', ''))),
          duration: const Duration(seconds: 10),
          action: SnackBarAction(
            label: 'Chat devices',
            onPressed: () => context.go('/profile/devices'),
          ),
        ),
      );

/// What the small notice says when a reaction could not be sent.
String reactionFailureText(Object error) {
  if (error is ChatFailure) {
    if (error.code == 'NETWORK') {
      return 'Couldn’t send your reaction. Check your connection.';
    }
    if (error.code == 'RATE_LIMITED') {
      return 'You’re reacting a lot. Wait a moment, then try again.';
    }
    // The engine's own refusals (not delivered yet) carry their own words.
    if (error.status == null &&
        (error.code == 'NOT_FOUND' || error.code == 'BAD_REACTION')) {
      return error.message;
    }
  }
  return 'Couldn’t send your reaction. ${chatError(error)}';
}

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

  /// Edit mode: the chats ticked for a bulk pin, mute or delete.
  bool editing = false;
  final selected = <String>{};

  /// Chats whose decrypted history on this phone matches [query] (never asked of the server), with the newest
  /// matching message.
  Map<String, ChatSearchHit> hits = const {};
  int _searchRun = 0;
  bool _closedChecked = false;

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
        _wipeExpired();
        if (query.trim().isNotEmpty) unawaited(_searchHistory());
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
    _closedChecked = false;
    load();
  }

  /// Chats deleted from the list more than 30 days ago lose this phone's copy of their history. The engine
  /// does it as it reads the Deleted chats list; once per start is enough.
  void _wipeExpired() {
    final current = engine;
    if (current == null || _closedChecked) return;
    _closedChecked = true;
    unawaited(current.hiddenConversations().then((_) {}, onError: (_) {}));
  }

  Future<void> _searchHistory() async {
    final current = engine, all = items;
    final text = query.trim();
    final run = ++_searchRun;
    if (current == null || all == null || text.isEmpty) {
      if (hits.isNotEmpty) setState(() => hits = const {});
      return;
    }
    final found = await current.searchHistory(text, [
      for (final c in all) c.id,
    ]);
    if (mounted && run == _searchRun) setState(() => hits = found);
  }

  void toggleEdit() => setState(() {
    editing = !editing;
    selected.clear();
  });

  void toggleSelected(ChatConversation c) => setState(() {
    if (!selected.add(c.id)) selected.remove(c.id);
  });

  List<ChatConversation> get _selectedChats => [
    for (final c in items ?? const <ChatConversation>[])
      if (selected.contains(c.id)) c,
  ];

  Future<void> _refreshAfterChange() async {
    ref.read(chatSignalProvider.notifier).bump();
    await ref.read(chatUnreadProvider.notifier).refresh();
    await load();
  }

  /// Pins or unpins one chat; says why when the limit of five stops it.
  Future<bool> pinChat(ChatConversation c, {bool refresh = true}) async {
    try {
      await engine!.pinConversation(c.id, !c.pinned);
      if (refresh) await _refreshAfterChange();
      return true;
    } catch (e) {
      if (mounted) {
        showMessage(
          context,
          e is ChatFailure && e.code == 'PIN_LIMIT'
              ? 'You can pin up to 5 chats. Unpin one first.'
              : chatError(e),
        );
      }
      return false;
    }
  }

  Future<void> muteChat(
    ChatConversation c, {
    DateTime? until,
    bool refresh = true,
  }) async {
    try {
      await engine!.api.muteConversation(c.id, !c.muted, until: until);
      if (refresh) await _refreshAfterChange();
    } catch (e) {
      if (mounted) showMessage(context, chatError(e));
    }
  }

  Future<void> toggleMute(ChatConversation c) async {
    DateTime? until;
    if (!c.muted) {
      final picked = await pickMuteDuration(
        context,
        title: 'Mute ${c.peerName}',
      );
      if (picked == null) return;
      until = picked.until;
    }
    await muteChat(c, until: until);
  }

  Future<void> deleteChats(List<ChatConversation> chats) async {
    if (chats.isEmpty) return;
    final one = chats.length == 1;
    final yes = await confirmChatAction(
      context,
      title: one ? 'Delete this chat?' : 'Delete ${chats.length} chats?',
      body: 'They leave your list. You can bring them back from Deleted chats for 30 days; after that this phone’s copy is removed. Nobody is told.',
      action: 'Delete',
    );
    if (!yes || !mounted) return;
    try {
      for (final c in chats) {
        await engine!.hideConversation(c.id);
      }
      selected.clear();
      if (mounted) {
        showMessage(
          context,
          one ? 'Chat deleted.' : '${chats.length} chats deleted.',
        );
      }
    } catch (e) {
      if (mounted) showMessage(context, chatError(e));
    }
    await _refreshAfterChange();
  }

  Future<void> bulkPin() async {
    final chats = _selectedChats;
    final unpin = chats.isNotEmpty && chats.every((c) => c.pinned);
    for (final c in chats) {
      if (c.pinned == unpin) {
        if (!await pinChat(c, refresh: false)) break;
      }
    }
    await _refreshAfterChange();
  }

  Future<void> bulkMute() async {
    final chats = _selectedChats;
    final unmute = chats.isNotEmpty && chats.every((c) => c.muted);
    DateTime? until;
    if (!unmute) {
      final picked = await pickMuteDuration(context, title: 'Mute these chats');
      if (picked == null) return;
      until = picked.until;
    }
    for (final c in chats) {
      if (c.muted == unmute) await muteChat(c, until: until, refresh: false);
    }
    await _refreshAfterChange();
  }

  Future<void> openDeleted() async {
    final current = engine;
    if (current == null) return;
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => DeletedChatsScreen(
          engine: current,
          clock: ref.read(chatClockProvider),
          onRestored: () => unawaited(_refreshAfterChange()),
        ),
      ),
    );
    if (mounted) await load();
  }

  /// Filters 200 ms after the last keystroke; emptying the field is immediate.
  void onSearch(String text) {
    _debounce?.cancel();
    if (text.trim().isEmpty) {
      if (query.isNotEmpty) {
        setState(() {
          query = '';
          hits = const {};
        });
      }
      return;
    }
    _debounce = Timer(chatSearchDebounce, () {
      if (mounted) {
        setState(() => query = text);
        unawaited(_searchHistory());
      }
    });
  }

  void clearSearch() {
    _debounce?.cancel();
    search.clear();
    setState(() {
      query = '';
      hits = const {};
    });
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
      final storage = state.error is ChatStorageUnavailable;
      return _ChatNotice(
        icon: Icons.lock_reset_rounded,
        title: storage
            ? 'Couldn’t open secure storage'
            : 'Couldn’t set up encryption',
        body: chatError(state.error!),
        action: () => ref.invalidate(chatEngineProvider),
        // Only after several launches in a row have failed, and only on purpose: it erases the chats on
        // this phone.
        secondaryLabel: storage && ref.watch(chatStorageResetOfferedProvider)
            ? 'Reset chat on this phone'
            : null,
        onSecondary: () => confirmChatReset(context, ref),
      );
    }
    final now = ref.watch(chatClockProvider)();
    final all = items;
    final shown = all == null
        ? null
        : filterChats(
            all,
            query: query,
            filter: filter,
            textHits: hits.keys.toSet(),
          );
    // The app shell already prints "Chats" above wide layouts.
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final hasChats = all != null && all.isNotEmpty;
    final narrowed = query.trim().isNotEmpty || filter != ChatFilter.all;
    final list = RefreshIndicator(
      onRefresh: () async {
        await engine?.pollNow();
        await load();
      },
      child: LayoutBuilder(
        builder: (context, box) {
          final side = math.max(0.0, (box.maxWidth - chatListMaxWidth) / 2);
          final empty = all != null && all.isEmpty;
          // Only what is on screen is built: the header and notices are a
          // few widgets, the rows are built lazily.
          final leading = <Widget>[
            ChatsHeading(subtitle: chatsSubtitle(all), showTitle: !wide),
            if (engine != null)
              ChatListToolbar(
                editing: editing,
                canEdit: hasChats,
                onToggleEdit: toggleEdit,
                onDeleted: openDeleted,
              ),
            if (engine != null) NewDeviceBanner(engine: engine!),
            if (hasChats) ...[
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: ChatMetrics.pagePadding,
                ),
                child: ChatSearchField(controller: search, onChanged: onSearch),
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
                      onPrimary: () => setState(() => filter = ChatFilter.all),
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
          ];
          final rows = shown ?? const <ChatConversation>[];
          final hasFooter = rows.isNotEmpty;
          return ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(side, wide ? 0 : 6, side, 32),
            itemCount: leading.length + rows.length + (hasFooter ? 1 : 0),
            itemBuilder: (context, index) {
              if (index < leading.length) return leading[index];
              final row = index - leading.length;
              if (row >= rows.length) {
                return const Padding(
                  padding: EdgeInsets.only(top: 18),
                  child: Center(child: EncryptedChip()),
                );
              }
              final chat = rows[row];
              final hit = hits[chat.id];
              final line = ChatRow(
                key: ValueKey(chat.id),
                chat: chat,
                now: now,
                typing: typing[chat.id]?.isAfter(DateTime.now()) ?? false,
                showDivider: row < rows.length - 1,
                selecting: editing,
                selected: selected.contains(chat.id),
                snippet: hit == null || query.trim().isEmpty
                    ? null
                    : _snippetFor(hit, query),
                onTap: () => editing ? toggleSelected(chat) : open(chat),
                onLongPress: editing
                    ? null
                    : () => setState(() {
                        editing = true;
                        selected
                          ..clear()
                          ..add(chat.id);
                      }),
              );
              return SwipeActionRow(
                key: ValueKey('swipe-${chat.id}'),
                enabled: !editing,
                leading: [
                  SwipeAction(
                    key: Key('swipe-pin-${chat.id}'),
                    label: chat.pinned ? 'Unpin' : 'Pin',
                    icon: chat.pinned
                        ? Icons.push_pin_outlined
                        : Icons.push_pin,
                    color: ChatTokens.of(context).lime,
                    onColor: ChatTokens.of(context).onLime,
                    onTap: () => unawaited(pinChat(chat)),
                  ),
                ],
                trailing: [
                  SwipeAction(
                    key: Key('swipe-mute-${chat.id}'),
                    label: chat.muted ? 'Unmute' : 'Mute',
                    icon: chat.muted
                        ? Icons.notifications_active_outlined
                        : Icons.notifications_off_outlined,
                    color: ChatTokens.of(context).surface,
                    onColor: ChatTokens.of(context).text,
                    onTap: () => unawaited(toggleMute(chat)),
                  ),
                  SwipeAction(
                    key: Key('swipe-delete-${chat.id}'),
                    label: 'Delete',
                    icon: Icons.delete_outline_rounded,
                    color: ChatTokens.of(context).error,
                    onColor: ChatTokens.of(context).onError,
                    onTap: () => unawaited(deleteChats([chat])),
                  ),
                ],
                child: line,
              );
            },
          );
        },
      ),
    );
    if (!editing) return list;
    final picked = _selectedChats;
    return Column(
      children: [
        Expanded(child: list),
        ChatEditBar(
          selected: picked.length,
          total: items?.length ?? 0,
          allPinned: picked.isNotEmpty && picked.every((c) => c.pinned),
          allMuted: picked.isNotEmpty && picked.every((c) => c.muted),
          onPin: () => unawaited(bulkPin()),
          onMute: () => unawaited(bulkMute()),
          onDelete: () => unawaited(deleteChats(picked)),
          onSelectAll: () => setState(() {
            final all = items ?? const <ChatConversation>[];
            if (selected.length == all.length) {
              selected.clear();
            } else {
              selected
                ..clear()
                ..addAll(all.map((c) => c.id));
            }
          }),
        ),
      ],
    );
  }
}

/// The line a chat row shows for a message found by the search of the local history.
String? _snippetFor(ChatSearchHit hit, String query) {
  final m = hit.newest;
  final text = m.attachment != null ? m.attachment!.caption : m.text;
  final line = searchSnippet(text, query);
  return line.isEmpty ? null : (m.mine ? 'You: $line' : line);
}

class _ChatNotice extends StatelessWidget {
  final IconData icon;
  final String title, body;
  final VoidCallback? action, onSecondary;
  final String? secondaryLabel;
  const _ChatNotice({
    required this.icon,
    required this.title,
    required this.body,
    this.action,
    this.secondaryLabel,
    this.onSecondary,
  });
  @override
  Widget build(BuildContext context) => ChatMessageCard(
    scrollable: true,
    icon: icon,
    title: title,
    body: body,
    primaryLabel: action == null ? null : 'Try again',
    onPrimary: action,
    secondaryLabel: secondaryLabel,
    onSecondary: onSecondary,
  );
}

/// Asks, in plain words, before "Reset chat on this phone" erases this phone's chats.
Future<void> confirmChatReset(BuildContext context, WidgetRef ref) async {
  final yes = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Reset chat on this phone?'),
      content: const Text(
        'This phone couldn’t open its secure storage several times in a row. Resetting erases the chats stored on this phone and its chat keys, and starts again with a new chat identity. Messages already on this phone can’t be recovered. Chats on your other devices are not affected, and neither are your notification and other app settings.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('chat-reset-confirm'),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Reset chat'),
        ),
      ],
    ),
  );
  if (yes != true) return;
  try {
    await resetChatOnThisPhone(ref);
  } catch (e) {
    if (context.mounted) showMessage(context, chatError(e));
  }
}

/// What the new-device banner says for the most pressing notice in [notices]: this phone's own data could
/// not be unlocked, this phone was reset, a device was added, one was removed, or the devices were never
/// reviewed on this phone. Returns the title, the body and the label of the button.
({String title, String body, String action}) deviceBannerText(
  List<DeviceNotice> notices,
) {
  final kind =
      [
        DeviceNoticeKind.locked,
        DeviceNoticeKind.storage,
        DeviceNoticeKind.reset,
        DeviceNoticeKind.added,
        DeviceNoticeKind.removed,
        DeviceNoticeKind.inactive,
        DeviceNoticeKind.review,
        DeviceNoticeKind.idle,
      ].firstWhere(
        (k) => notices.any((n) => n.kind == k),
        orElse: () => DeviceNoticeKind.added,
      );
  return switch (kind) {
    DeviceNoticeKind.locked => (
      title:
          'Couldn’t unlock your encrypted data on this device. Starting fresh.',
      body: 'Chats you had on this phone are gone, and earlier encrypted messages can’t be opened here. New chats work as usual.',
      action: 'Manage devices',
    ),
    DeviceNoticeKind.storage => (
      title: 'Chat was reset on this phone',
      body: 'Secure storage couldn’t be opened, so you started chat again here. Chats that were on this phone are gone and earlier encrypted messages can’t be opened here. New chats work as usual.',
      action: 'Manage devices',
    ),
    DeviceNoticeKind.inactive => (
      title: 'A device you hadn’t used for a while was removed',
      body: 'Its messages had piled up, which would have held back messages to your account. If it was yours, sign in on it again. If it wasn’t, review your devices.',
      action: 'Review devices',
    ),
    DeviceNoticeKind.idle => (
      title: 'A device you haven’t used for a while was signed out of chat',
      body: 'Nothing is wrong. Open Hiyall on it and it will connect again, with the same keys.',
      action: 'See devices',
    ),
    DeviceNoticeKind.reset => (
      title: 'This phone started a new secure chat identity',
      body: 'It was removed from your account, so its chat keys were replaced. If that wasn’t you, review your devices and sign in again.',
      action: 'Review devices',
    ),
    DeviceNoticeKind.removed => (
      title: 'A device was removed from your account',
      body: 'If it wasn’t you, someone else may have your sign-in. Review your devices and sign in again.',
      action: 'Review devices',
    ),
    DeviceNoticeKind.review => (
      title: 'Review your devices',
      body: 'Other devices are signed in to your account. They can read your new chats. If one isn’t yours, remove it and sign in again.',
      action: 'Review devices',
    ),
    DeviceNoticeKind.added => (
      title: 'A new device was added to your account',
      body: 'It can read your new chats. If it wasn’t you, remove it and sign in again.',
      action: 'Manage devices',
    ),
  };
}

/// Tells the person that something changed about their account's devices (one was added or removed, this
/// phone was reset, or there are devices to review), with a way to look at them. It stays until dismissed.
/// Nothing else about chat is hidden because of it: it is a heads-up, since a device that is not yours can
/// read new messages.
class NewDeviceBanner extends StatefulWidget {
  final ChatEngine engine;
  const NewDeviceBanner({super.key, required this.engine});
  @override
  State<NewDeviceBanner> createState() => _NewDeviceBannerState();
}

class _NewDeviceBannerState extends State<NewDeviceBanner> {
  StreamSubscription<void>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.engine.ownDeviceChanges.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(NewDeviceBanner old) {
    super.didUpdateWidget(old);
    if (!identical(old.engine, widget.engine)) {
      _sub?.cancel();
      _sub = widget.engine.ownDeviceChanges.listen((_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.engine.ownDeviceNotices.isEmpty) return const SizedBox.shrink();
    final t = ChatTokens.of(context);
    final words = deviceBannerText(widget.engine.ownDeviceNotices);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        ChatMetrics.pagePadding,
        4,
        ChatMetrics.pagePadding,
        8,
      ),
      child: Semantics(
        container: true,
        liveRegion: true,
        child: Container(
          key: const Key('new-device-banner'),
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
          decoration: BoxDecoration(
            color: t.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: t.error.withValues(alpha: .55)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.devices_other_rounded, size: 20, color: t.error),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      words.title,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: t.text,
                      ),
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(30, 4, 8, 0),
                child: Text(
                  words.body,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.35,
                    color: t.textSecondary,
                  ),
                ),
              ),
              Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  TextButton(
                    key: const Key('new-device-dismiss'),
                    onPressed: () => widget.engine.dismissOwnDeviceNotices(),
                    child: const Text('Dismiss'),
                  ),
                  FilledButton(
                    key: const Key('new-device-manage'),
                    onPressed: () => context.go('/profile/devices'),
                    child: Text(words.action),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
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
  bool attaching = false;

  /// The relay refused a send with AWAITING_REPLY (the first-contact cap), which
  /// this phone could not know from its own history (after a reinstall).
  bool serverAwaiting = false;
  DateTime? peerReadAt;
  DateTime? mutedUntil, pinnedAt;

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

  /// The message a reply is being written to; null for none.
  ChatMessage? replyingTo;

  /// A reaction that could not be sent: the words and how to try again. It
  /// clears itself after a few seconds.
  String? reactionNotice;
  VoidCallback? _retryReaction;
  Timer? _noticeTimer, _litTimer;

  /// The message a tapped quote brought into view, lit for a moment.
  String? litId;

  /// Voice recording for the composer (made once the engine is there), the one playing message and the
  /// choices this phone keeps for the chat.
  VoiceCapture? capture;
  VoicePlayback? _playback;
  StreamSubscription<ChatPrefsData>? _prefsSub;
  ChatPrefsData chatPrefs = const ChatPrefsData();

  /// Translations shown under messages (by message id), in memory only: a translation is a second copy of a
  /// message's text and is never written anywhere. Pending and failed ones are tracked too.
  final translations = <String, TranslationResult>{};
  final _translating = <String>{}, _translateFailed = <String>{};
  bool _autoRunning = false;

  /// The message being read aloud, if any.
  String? speakingId;

  /// A global key per message row built so far, to scroll to a quoted one.
  final _rowKeys = <String, GlobalKey>{};
  List<ThreadRow> _rows = const [];

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

  /// Keeps the newest message in view for the next [frames] frames, while the
  /// space under the thread changes size (a bar growing above the composer).
  void _followBottom(int frames) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !scroll.hasClients) return;
      final end = scroll.position.maxScrollExtent;
      if (scroll.position.pixels < end - 1) scroll.jumpTo(end);
      if (frames > 1) _followBottom(frames - 1);
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

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
      messages = [for (final m in list) m.display];
      // A reply from them lifts the first-contact cap.
      if (messages.any((m) => !m.mine && !m.notice)) serverAwaiting = false;
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
        engine?.showDeviceNotices(widget.id, peerId).catchError((_) {});
      }
      final pinned = DateTime.tryParse(c['pinnedAt'] as String? ?? '');
      if (at != peerReadAt || muted != mutedUntil || pinned != pinnedAt) {
        setState(() {
          peerReadAt = at;
          mutedUntil = muted;
          pinnedAt = pinned;
        });
      }
    } catch (_) {
      // Without the first look the card simply waits less: show it as it is.
      if (mounted && !receiptLoaded) setState(() => receiptLoaded = true);
    }
  }

  bool get muted => mutedUntil?.isAfter(DateTime.now()) ?? false;

  /// How many messages a person may send before the other has written back.
  /// The relay enforces it; this only keeps the composer honest.
  static const firstContactMessages = 3;

  /// Waiting for the peer: they have not written, and the cap is used up.
  bool get awaitingReply {
    if (messages.any((m) => !m.mine && !m.notice)) return false;
    final mine = messages.where(
      (m) => m.mine && !m.notice && m.status != SendStatus.failed,
    );
    return serverAwaiting || mine.length >= firstContactMessages;
  }

  Future<void> options() async {
    final choice = await showChatSafetyMenu(
      context,
      muted: muted,
      peerName: peerName,
      verified: engine?.isVerified(peerId) ?? false,
      pinned: pinnedAt != null,
      autoTranslate: chatPrefs.autoTranslate.contains(widget.id),
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
      case ChatMenuAction.pin:
        await togglePin();
      case ChatMenuAction.autoTranslate:
        await setAutoTranslate(!chatPrefs.autoTranslate.contains(widget.id));
      case ChatMenuAction.clearHistory:
        await clearHistory();
      case ChatMenuAction.deleteChat:
        await deleteChat();
      case ChatMenuAction.profile:
        openPerson(context, peerId);
      case ChatMenuAction.safety:
        await showSafetyNumber();
      case ChatMenuAction.report:
        await reportPeer();
      case ChatMenuAction.block:
        await blockPeer();
    }
  }

  /// Pins or unpins this chat (the relay enforces five).
  Future<void> togglePin() async {
    final current = engine;
    if (current == null) return;
    try {
      await current.pinConversation(widget.id, pinnedAt == null);
      await loadReceipt();
      ref.read(chatSignalProvider.notifier).bump();
      if (mounted) {
        showMessage(
          context,
          pinnedAt == null ? 'Chat unpinned.' : 'Chat pinned.',
        );
      }
    } catch (e) {
      if (!mounted) return;
      showMessage(
        context,
        e is ChatFailure && e.code == 'PIN_LIMIT'
            ? 'You can pin up to 5 chats. Unpin one first.'
            : chatError(e),
      );
    }
  }

  /// Removes this phone's copy of the messages, after asking. The relay and the other person are untouched.
  Future<void> clearHistory() async {
    final current = engine;
    if (current == null) return;
    final yes = await confirmChatAction(
      context,
      title: 'Clear history on this phone?',
      body:
          'The messages, photos, voice messages and videos of this chat are removed from this phone. $peerName keeps theirs, and new messages still arrive.',
      action: 'Clear history',
    );
    if (!yes || !mounted) return;
    try {
      await current.clearHistory(widget.id);
      ref.read(translationMemoryProvider).clear(conversationId: widget.id);
      if (mounted) {
        setState(() {
          translations.clear();
          messages = [];
        });
        showMessage(context, 'History cleared on this phone.');
      }
    } catch (e) {
      if (mounted) showMessage(context, chatError(e));
    }
  }

  /// Takes the chat out of the list. The history stays on this phone for the 30 days it can be restored.
  Future<void> deleteChat() async {
    final current = engine;
    if (current == null) return;
    final yes = await confirmChatAction(
      context,
      title: 'Delete this chat?',
      body:
          'It leaves your list. You can bring it back from Deleted chats for 30 days; after that this phone’s copy is removed. $peerName isn’t told, and a new message from them brings it back.',
      action: 'Delete chat',
    );
    if (!yes || !mounted) return;
    try {
      await current.hideConversation(widget.id);
      ref.read(chatSignalProvider.notifier).bump();
      await ref.read(chatUnreadProvider.notifier).refresh();
      if (mounted) {
        showMessage(
          context,
          'Chat deleted. You can restore it from Deleted chats.',
        );
        context.go('/chats');
      }
    } catch (e) {
      if (mounted) showMessage(context, chatError(e));
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
    SafetyInfo? info;
    Object? failure;
    try {
      info = await current.safetyInfo(peerId);
    } catch (e) {
      failure = e;
    }
    if (!mounted) return;
    var verified = info?.verified ?? false;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setInner) => AlertDialog(
          title: const Text('Verify safety number'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (info != null) ...[
                  // A change comes first, before the number it changed.
                  if (info.changedSinceVerified)
                    Padding(
                      key: const Key('safety-changed'),
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        '$peerName’s safety number changed since you verified it. That happens when they add, remove or reset a device. Compare it again before you trust it.',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  if (info.newDevices > 0)
                    Padding(
                      key: const Key('safety-new-device'),
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        '$peerName has a device that was added since your last message. Their number below already includes it, and it can read new messages you send them.',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  Text(
                    'Messages and photos in this chat are end-to-end encrypted: only you and $peerName can read them.',
                  ),
                  const SizedBox(height: 12),
                  SelectableText(
                    [
                      for (var i = 0; i < info.number.length; i += 5)
                        info.number.substring(i, i + 5),
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
                  const SizedBox(height: 8),
                  Text(
                    verified
                        ? 'Verified. This mark goes away if either of you changes devices.'
                        : 'Not verified yet.',
                    key: const Key('safety-verified'),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ] else
                  Text(chatError(failure!)),
              ],
            ),
          ),
          actions: [
            if (info != null && !verified)
              TextButton(
                key: const Key('safety-mark'),
                onPressed: () async {
                  await current.markVerified(peerId, info!);
                  setInner(() => verified = true);
                },
                child: const Text('They match'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
          ],
        ),
      ),
    );
  }

  void attach(ChatEngine? next) {
    if (next == null || identical(next, engine)) return;
    engine = next;
    final files = next.playFiles;
    if (files != null) {
      capture = VoiceCapture(
        recorder: ref.read(voiceRecorderProvider),
        files: files,
      )..onLimit = _sendClip;
      capture!.onLimitFailed = _voiceProblem;
    }
    _playback = ref.read(voicePlaybackProvider);
    unawaited(
      next.prefs.read().then((p) {
        if (mounted) setState(() => chatPrefs = p);
        _autoTranslate();
      }),
    );
    _prefsSub = next.prefs.changes.listen((p) {
      if (mounted) setState(() => chatPrefs = p);
      _autoTranslate();
    });
    changes = next.changes
        .where((id) => id == widget.id)
        .listen((_) => reload());
    // The receipt first: its unread count must be read before opening the
    // chat marks everything read.
    loadReceipt();
    reload();
    // A device added to the peer's account is announced in every chat with
    // them, not only the one that happened to see it first.
    if (peerId.isNotEmpty) {
      next.showDeviceNotices(widget.id, peerId).catchError((_) {});
    }
    next.pollNow().catchError((_) {});
  }

  /// The message is written to the thread as "sending" at once and goes out in
  /// the background. Offline or throttled, it stays as "Not sent" with a retry;
  /// a refusal puts the text back in the composer and says why.
  Future<void> send() async {
    final text = input.text.trim();
    if (text.isEmpty || engine == null || peerId.isEmpty || awaitingReply) {
      return;
    }
    unawaited(sendHaptic());
    final reply = replyingTo;
    input.clear();
    setState(() => replyingTo = null);
    try {
      await engine!.send(widget.id, peerId, text, replyTo: reply);
    } catch (e) {
      if (!mounted) return;
      if (e is ChatFailure && e.code == 'AWAITING_REPLY') {
        setState(() => serverAwaiting = true);
      }
      if (e is ChatFailure && e.code == 'OWN_BACKLOG') {
        showOwnBacklogMessage(context);
      }
      if (!isTransientChatFailure(e)) {
        if (input.text.isEmpty) {
          input.value = TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: text.length),
          );
        }
        showMessage(context, chatError(e, peerName: peerName));
      }
    }
  }

  Future<void> retryText(ChatMessage message) async {
    try {
      await engine?.retryText(widget.id, peerId, message.messageId);
    } catch (e) {
      if (!mounted) return;
      if (e is ChatFailure && e.code == 'AWAITING_REPLY') {
        setState(() => serverAwaiting = true);
      }
      if (e is ChatFailure && e.code == 'OWN_BACKLOG') {
        showOwnBacklogMessage(context);
      }
      if (!isTransientChatFailure(e)) {
        showMessage(context, chatError(e, peerName: peerName));
      }
    }
  }

  Future<void> deleteText(ChatMessage message) async {
    try {
      await engine?.discardText(widget.id, message.messageId);
    } catch (e) {
      if (mounted) showMessage(context, chatError(e));
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

  /// Choose or take a photo or a video. A photo is previewed with an optional caption first; a video is
  /// prepared (scaled to 720p at most, re-encoded, its location and other tags removed) and then sent. The
  /// message appears at once; the upload carries on in the background.
  Future<void> attachPhoto() async {
    final current = engine;
    if (current == null || peerId.isEmpty || attaching) return;
    final choice = await showAttachSheet(context);
    if (choice == null || !mounted) return;
    switch (choice) {
      case AttachChoice.photoGallery:
        await _sendPickedPhoto(current, PhotoSource.gallery);
      case AttachChoice.photoCamera:
        await _sendPickedPhoto(current, PhotoSource.camera);
      case AttachChoice.videoGallery:
        await _sendPickedVideo(current, PhotoSource.gallery);
      case AttachChoice.videoCamera:
        await _sendPickedVideo(current, PhotoSource.camera);
    }
  }

  Future<void> _sendPickedPhoto(ChatEngine current, PhotoSource source) async {
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
      await current.sendPhoto(
        widget.id,
        peerId,
        bytes,
        caption: caption,
        replyTo: replyingTo,
      );
      if (mounted) setState(() => replyingTo = null);
    } catch (e) {
      if (mounted) showMessage(context, chatError(e, peerName: peerName));
    }
  }

  Future<void> _sendPickedVideo(ChatEngine current, PhotoSource source) async {
    final preparer = ref.read(videoPreparerProvider);
    if (preparer == null) {
      showMessage(context, 'Videos can only be sent from the Hiyall app.');
      return;
    }
    setState(() => attaching = true);
    String? path;
    try {
      path = await pickChatVideo(ref.read(imagePickerProvider), source);
    } catch (e) {
      if (mounted) showMessage(context, videoFailureText(e));
      return;
    } finally {
      if (mounted) setState(() => attaching = false);
    }
    if (path == null || !mounted) return;
    final progress = ValueNotifier<double>(0);
    final navigator = Navigator.of(context, rootNavigator: true);
    // A calm, modal "Preparing video": re-encoding takes a few seconds.
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        useRootNavigator: true,
        builder: (_) =>
            PopScope(canPop: false, child: PreparingVideo(progress: progress)),
      ),
    );
    PreparedVideo? prepared;
    Object? failure;
    try {
      prepared = await preparer.prepare(
        path,
        onProgress: (v) => progress.value = v,
      );
    } catch (e) {
      failure = e;
    }
    if (navigator.mounted && navigator.canPop()) navigator.pop();
    progress.dispose();
    if (!mounted) return;
    if (prepared == null) {
      showMessage(context, videoFailureText(failure ?? ''));
      return;
    }
    try {
      await current.sendVideo(widget.id, peerId, prepared, replyTo: replyingTo);
      if (mounted) setState(() => replyingTo = null);
    } catch (e) {
      if (mounted) showMessage(context, chatError(e, peerName: peerName));
    }
  }

  // ------------------------------------------------------- voice messages

  void _voiceProblem(Object error) {
    if (!mounted) return;
    showMessage(
      context,
      error is ChatFailure
          ? chatError(error, peerName: peerName)
          : 'That recording couldn’t be sent.',
    );
  }

  /// Sends a finished recording; the message is in the thread as sending at once.
  Future<void> _sendClip(VoiceClip clip) async {
    final current = engine;
    if (current == null || peerId.isEmpty) return;
    unawaited(sendHaptic());
    final reply = replyingTo;
    setState(() => replyingTo = null);
    try {
      await current.sendVoice(widget.id, peerId, clip, replyTo: reply);
    } catch (e) {
      if (mounted) showMessage(context, chatError(e, peerName: peerName));
    }
  }

  /// Letting go of the microphone, or tapping send: stops the recording and sends it.
  Future<void> finishVoice() async {
    final c = capture;
    if (c == null) return;
    try {
      final clip = await c.finish();
      if (clip != null) await _sendClip(clip);
    } catch (e) {
      _voiceProblem(e);
    }
  }

  VoiceControls? get voiceControls {
    final c = capture;
    if (c == null || engine == null || peerId.isEmpty) return null;
    return VoiceControls(
      capture: c,
      onFinish: finishVoice,
      onProblem: (m) {
        if (mounted) showMessage(context, m);
      },
    );
  }

  // -------------------------------------------- translation, reading aloud

  /// Translates one message on the phone and shows the result under it; or hides it when it is shown.
  Future<void> translateMessage(ChatMessage message) async {
    final current = engine;
    if (current == null) return;
    if (translations.containsKey(message.messageId)) {
      setState(() => translations.remove(message.messageId));
      return;
    }
    final service = ref.read(translationServiceProvider);
    if (!service.supported) {
      showMessage(context, 'Translation works in the Android and iOS apps.');
      return;
    }
    final to = translationTarget(chatPrefs);
    final from = await service.detectLanguage(message.text);
    if (!mounted) return;
    if (from == null) {
      showMessage(context, 'Couldn’t tell which language that is.');
      return;
    }
    if (from == to) {
      showMessage(context, 'That message is already in ${languageName(to)}.');
      return;
    }
    if (!await ensureTranslationPacks(context, ref, current, [from, to]) ||
        !mounted) {
      return;
    }
    await _translateOne(message, to: to, from: from, announce: true);
  }

  Future<void> _translateOne(
    ChatMessage message, {
    required String to,
    String? from,
    bool announce = false,
  }) async {
    final service = ref.read(translationServiceProvider);
    final memory = ref.read(translationMemoryProvider);
    final key = TranslationMemory.keyOf(widget.id, message.messageId, to);
    final hit = memory.get(key);
    if (hit != null) {
      if (mounted) setState(() => translations[message.messageId] = hit);
      return;
    }
    setState(() {
      _translating.add(message.messageId);
      _translateFailed.remove(message.messageId);
    });
    try {
      final result = await service.translate(message.text, to: to, from: from);
      memory.put(key, result);
      if (mounted) setState(() => translations[message.messageId] = result);
    } on TranslationException catch (e) {
      if (!mounted) return;
      if (e.problem != TranslationProblem.nothingToTranslate) {
        setState(() => _translateFailed.add(message.messageId));
        if (announce) showMessage(context, 'Couldn’t translate that message.');
      }
    } finally {
      if (mounted) setState(() => _translating.remove(message.messageId));
    }
  }

  /// With auto-translate on for this chat, incoming text is translated as it arrives, when the language packs
  /// are already on the phone (nothing is downloaded by surprise). At most the newest 30 incoming messages.
  void _autoTranslate() {
    if (_autoRunning || !chatPrefs.autoTranslate.contains(widget.id)) return;
    final service = ref.read(translationServiceProvider);
    if (!service.supported) return;
    _autoRunning = true;
    unawaited(() async {
      try {
        final to = translationTarget(chatPrefs);
        final todo = [
          for (final m in messages.reversed.take(60))
            if (!m.mine &&
                !m.notice &&
                !m.isMedia &&
                m.text.trim().isNotEmpty &&
                m.text.length <= 1000 &&
                !isEmojiOnly(m.text) &&
                !translations.containsKey(m.messageId) &&
                !_translateFailed.contains(m.messageId))
              m,
        ].take(30).toList();
        for (final m in todo) {
          if (!mounted || !chatPrefs.autoTranslate.contains(widget.id)) break;
          final from = await service.detectLanguage(m.text);
          if (from == null || from == to) {
            _translateFailed.add(m.messageId);
            continue;
          }
          if ((await service.missingPacks(from, to)).isNotEmpty) {
            continue;
          }
          await _translateOne(m, to: to, from: from);
        }
      } finally {
        _autoRunning = false;
      }
    }());
  }

  /// Turns auto-translate for this chat on or off. Switching it on makes sure the language pack is there
  /// (asking first); the choice is kept only on this phone.
  Future<void> setAutoTranslate(bool on) async {
    final current = engine;
    if (current == null) return;
    if (on) {
      final service = ref.read(translationServiceProvider);
      if (!service.supported) {
        showMessage(context, 'Translation works in the Android and iOS apps.');
        return;
      }
      final to = translationTarget(chatPrefs);
      if (!await ensureTranslationPacks(context, ref, current, [to]) ||
          !mounted) {
        return;
      }
    } else if (mounted) {
      setState(() {
        translations.clear();
        _translateFailed.clear();
      });
    }
    await current.prefs.setAutoTranslate(widget.id, on);
  }

  Future<void> readAloud(ChatMessage message) async {
    final speech = ref.read(speechServiceProvider);
    if (speakingId == message.messageId) {
      await speech.stop();
      if (mounted) setState(() => speakingId = null);
      return;
    }
    if (!speech.supported) {
      showMessage(context, 'Reading aloud works in the Android and iOS apps.');
      return;
    }
    await speech.stop();
    final translated = translations[message.messageId];
    final text = translated?.text ?? message.text;
    final service = ref.read(translationServiceProvider);
    final language =
        translated?.to ?? await service.detectLanguage(message.text);
    if (!mounted) return;
    setState(() => speakingId = message.messageId);
    try {
      await speech.speak(text, language: language);
    } on SpeechException catch (e) {
      if (mounted) {
        showMessage(
          context,
          e.problem == SpeechProblem.noOfflineVoice
              ? 'No voice for ${language == null ? 'that language' : languageName(language)} is installed on this phone. Add one in your phone’s text-to-speech settings. Hiyall only reads aloud with voices that work on the phone.'
              : 'Couldn’t read that aloud.',
        );
      }
    } finally {
      if (mounted && speakingId == message.messageId) {
        setState(() => speakingId = null);
      }
    }
  }

  // ------------------------------------------------ reactions and replies

  /// Sets or clears this account's reaction. The engine shows it at once and
  /// takes it back if it cannot be sent; the screen only says so.
  Future<void> reactTo(ChatMessage message, String? emoji) async {
    final current = engine;
    if (current == null || peerId.isEmpty) return;
    try {
      await current.react(widget.id, peerId, message.messageId, emoji);
      if (mounted && reactionNotice != null) {
        setState(() => reactionNotice = null);
      }
    } catch (e) {
      if (!mounted) return;
      _noticeTimer?.cancel();
      _noticeTimer = Timer(const Duration(seconds: 6), () {
        if (mounted) setState(() => reactionNotice = null);
      });
      if (atBottom) _followBottom(14);
      setState(() {
        reactionNotice = reactionFailureText(e);
        _retryReaction = isTransientChatFailure(e)
            ? () {
                setState(() => reactionNotice = null);
                reactTo(message, emoji);
              }
            : null;
      });
    }
  }

  void startReply(ChatMessage message) {
    if (!canInteract(message)) return;
    setState(() => replyingTo = message);
    focus.requestFocus();
    // The bar takes room from the thread: stay on the newest message.
    if (atBottom) _followBottom(14);
  }

  Future<void> copyMessage(ChatMessage message) async {
    await Clipboard.setData(ClipboardData(text: message.text));
    if (mounted) showMessage(context, 'Copied.');
  }

  /// The original of a quote when it is in this device's history.
  ChatMessage? _original(String id) {
    for (final m in messages) {
      if (m.messageId == id && !m.notice) return m;
    }
    return null;
  }

  /// The quote of [m] as drawn: the local original's author and text win over
  /// what the sender wrote.
  QuoteData? quoteFor(ChatMessage m) {
    final reply = m.reply;
    if (reply == null) return null;
    final me = engine?.userId ?? '';
    final original = _original(reply.id);
    final shown = original == null ? reply : resolveReply(reply, original, me);
    return QuoteData(
      who: shown.by == me ? 'You' : peerName,
      line: quoteLine(shown),
      image: shown.isImage,
      jumpTo: original?.messageId,
    );
  }

  /// Scrolls the quoted message into view and lights it for a moment. Rows
  /// far away are only built once the list is near them, so it walks there a
  /// viewport at a time; if it cannot get there, nothing happens.
  void showOriginal(String id, [int attempt = 0]) {
    final index = _rows.indexWhere(
      (r) => r is MessageRow && r.message.messageId == id,
    );
    if (index < 0 || !scroll.hasClients) return;
    final context = _rowKeys[id]?.currentContext;
    if (context != null && context.mounted) {
      Scrollable.ensureVisible(
        context,
        alignment: .35,
        duration: MediaQuery.disableAnimationsOf(this.context)
            ? Duration.zero
            : const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
      _light(id);
      return;
    }
    if (attempt >= 14) return;
    final built = <int>[];
    for (var i = 0; i < _rows.length; i++) {
      final r = _rows[i];
      if (r is MessageRow &&
          _rowKeys[r.message.messageId]?.currentContext != null) {
        built.add(i);
      }
    }
    final position = scroll.position;
    final step = position.viewportDimension * .85;
    double to;
    if (built.isEmpty) {
      to = _rows.length <= 1
          ? 0
          : position.maxScrollExtent * index / (_rows.length - 1);
    } else {
      to = index < built.first
          ? position.pixels - step
          : position.pixels + step;
    }
    scroll.jumpTo(to.clamp(position.minScrollExtent, position.maxScrollExtent));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) showOriginal(id, attempt + 1);
    });
    // A jump that changes nothing schedules no frame of its own.
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _light(String id) {
    _litTimer?.cancel();
    setState(() => litId = id);
    _litTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => litId = null);
    });
  }

  Future<void> retryAv(ChatMessage message) async {
    try {
      await engine?.retryAv(widget.id, message.messageId);
    } catch (e) {
      if (mounted) showMessage(context, chatError(e));
    }
  }

  Future<void> deleteAv(ChatMessage message) async {
    try {
      await engine?.discardAv(widget.id, message.messageId);
    } catch (e) {
      if (mounted) showMessage(context, chatError(e));
    }
  }

  /// What the bubble of [m] draws under its text: a translation that is shown, or on its way, or failed.
  BubbleTranslation? _translationFor(ChatMessage m) {
    final done = translations[m.messageId];
    if (done != null) {
      return BubbleTranslation(
        text: done.text,
        from: done.from,
        onHide: () => setState(() => translations.remove(m.messageId)),
      );
    }
    if (_translating.contains(m.messageId)) {
      return const BubbleTranslation(pending: true);
    }
    // A failure is only drawn for a message the person asked about, never for an automatic attempt.
    return null;
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
    _noticeTimer?.cancel();
    _litTimer?.cancel();
    changes?.cancel();
    _prefsSub?.cancel();
    unawaited(_playback?.stop());
    capture?.dispose();
    scroll.removeListener(_onScroll);
    input.dispose();
    focus.dispose();
    scroll.dispose();
    super.dispose();
  }

  late final BubbleActions _actions = BubbleActions(
    onReact: reactTo,
    onReply: startReply,
    onQuoteTap: showOriginal,
    onCopy: copyMessage,
    onReadAloud: readAloud,
    onTranslate: translateMessage,
    isTranslated: (m) => translations.containsKey(m.messageId),
  );

  /// The bar and the notice above the composer.
  Widget? _aboveComposer() {
    final reply = replyingTo, notice = reactionNotice;
    if (reply == null && notice == null) return null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (notice != null)
          ChatInlineNotice(
            text: notice,
            onRetry: _retryReaction,
            onDismiss: () => setState(() => reactionNotice = null),
          ),
        if (reply != null)
          ReplyBar(
            who: reply.mine ? 'You' : peerName,
            line: reply.isPhoto
                ? 'Photo'
                : reply.isVoice
                ? 'Voice message'
                : reply.isVideo
                ? 'Video'
                : snippetOf(reply.text),
            image: reply.isMedia,
            onCancel: () => setState(() => replyingTo = null),
          ),
      ],
    );
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
        return DayChip(
          chatDayLabel(
            day,
            now,
            locale: Localizations.localeOf(context).toString(),
          ),
          key: ValueKey('day-$day'),
        );
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
          selfId: engine?.userId ?? '',
          actions: engine == null || peerId.isEmpty ? null : _actions,
          quote: quoteFor(m),
          highlight: litId == m.messageId,
          translation: _translationFor(m),
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
        return KeyedSubtree(
          key: _rowKeys.putIfAbsent(m.messageId, GlobalKey.new),
          child: Column(
            key: ValueKey(m.messageId),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              bubble,
              if (m.messageId == newestMine &&
                  m.mine &&
                  m.status == SendStatus.sent &&
                  peerReadAt != null)
                ReceiptLine(seen: _seen(m)),
              if (m.mine &&
                  (m.voice != null || m.video != null) &&
                  m.status == SendStatus.failed)
                FailedPhotoActions(
                  keyPrefix: 'av',
                  message: m,
                  error:
                      photoFailureText(m.failure) ??
                      (m.voice != null
                          ? 'This voice message wasn’t sent.'
                          : 'This video wasn’t sent.'),
                  onRetry: () => retryAv(m),
                  onDelete: () => deleteAv(m),
                )
              else if (m.mine &&
                  m.attachment != null &&
                  m.status == SendStatus.failed)
                FailedPhotoActions(
                  message: m,
                  error:
                      photoFailureText(m.failure) ?? 'This photo wasn’t sent.',
                  onRetry: () => retryPhoto(m),
                  onDelete: () => deletePhoto(m),
                )
              else if (m.mine &&
                  !m.isMedia &&
                  !m.notice &&
                  m.status == SendStatus.failed)
                FailedPhotoActions(
                  keyPrefix: 'text',
                  message: m,
                  error:
                      photoFailureText(m.failure) ??
                      'This message wasn’t sent.',
                  onRetry: () => retryText(m),
                  onDelete: () => deleteText(m),
                ),
            ],
          ),
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
    _rows = rows;
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
            sending: false,
            canSend: engine != null,
            waitingFor: awaitingReply ? peerName : null,
            canAttach: engine != null && peerId.isNotEmpty && !attaching,
            showAttach: chatSupported,
            onChanged: typed,
            onSend: send,
            onAttach: attachPhoto,
            above: _aboveComposer(),
            voice: voiceControls,
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

  Future<void> load(ChatApi api) async {
    try {
      final next = (await api.myDevices()).reversed.toList();
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

  Future<void> remove(ChatApi api, Map<String, dynamic> d) async {
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
      await api.revokeDevice(d['deviceId'] as String);
      await load(api);
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
    // The list and removal need only the account's credential, not a started
    // engine: they must work when chat could not set itself up.
    final api = ref.watch(chatApiProvider);
    final thisDevice = ref.watch(thisChatDeviceProvider).asData?.value;
    if (api != null && devices == null && error == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => load(api));
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
                d['deviceId'] == thisDevice
                    ? '${label(d['platform'] as String)} · This phone'
                    : label(d['platform'] as String),
              ),
              subtitle: Text(
                'Added ${date(d['createdAt'] as String?)} · active ${date(d['lastSeenAt'] as String?)}',
              ),
              trailing: d['deviceId'] == thisDevice || api == null
                  ? null
                  : TextButton(
                      onPressed: busy == null ? () => remove(api, d) : null,
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

/// A plain yes/no before something that removes data from this phone or from the list.
Future<bool> confirmChatAction(
  BuildContext context, {
  required String title,
  required String body,
  required String action,
}) async {
  final yes = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          key: const Key('confirm-cancel'),
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('confirm-yes'),
          onPressed: () => Navigator.pop(context, true),
          child: Text(action),
        ),
      ],
    ),
  );
  return yes ?? false;
}
