import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../src/rust/api/e2ee.dart';
import '../presence.dart';
import 'chat_api.dart';
import 'chat_attachment.dart';
import 'chat_blob_cache.dart';
import 'chat_blob_codec.dart';
import 'chat_blob_transport.dart';
import 'chat_history.dart';
import 'chat_key_upload.dart';
import 'chat_local_data.dart';
import 'chat_media.dart';
import 'chat_padding.dart';
import 'chat_outbox.dart';
import 'chat_reactions.dart';
import 'chat_snapshot.dart' show SnapshotChatStore;
import 'chat_store.dart';
import 'chat_text.dart';

/// Errors worth retrying later: the relay was unreachable, throttled us, the
/// token needs refreshing or the server failed. Anything else is final.
bool isTransientChatFailure(Object error) =>
    error is ChatFailure &&
    (error.code == 'NETWORK' ||
        error.code == 'RATE_LIMITED' ||
        error.status == 401 ||
        error.status == 408 ||
        error.status == 429 ||
        (error.status ?? 0) >= 500);

/// Signed statements; byte-for-byte identical to the server's domain/chat.go.
String deviceStatement(
  String user,
  String device,
  String identity,
  String signing,
) => ['hiyall-device-v1', user, device, identity, signing].join('\n');
String oneTimeKeyStatement(
  String user,
  String device,
  String keyId,
  String key,
) => ['hiyall-otk-v1', user, device, keyId, key].join('\n');

class ChatMessage {
  final String messageId, senderId, text;

  /// The sender's clock. It is the sender's claim, so it only decides what
  /// time is shown (see [shownAt]), never the order.
  final DateTime sentAt;

  /// The relay's clock: it orders the conversation, evicts old history and
  /// drives read pointers and receipts. Null for local notices and for a
  /// message of this account that the relay has not accepted yet.
  final DateTime? serverAt;
  final bool mine, notice;

  /// The photo of an image message, or null.
  final ChatAttachment? attachment;

  /// An image message whose descriptor did not pass validation.
  final bool unsupportedPhoto;

  /// Where an outgoing message is; received ones are always sent.
  final SendStatus status;

  /// Why a failed message failed: a stable code, never a message with details.
  final String? failure;

  /// The message this one answers, as quoted inside its encrypted payload.
  final ChatReply? reply;

  /// Each member's latest reaction event to this message (see
  /// [ReactionState]); [reactions] is the part that is still on.
  final Map<String, ReactionState> reactionStates;
  const ChatMessage({
    required this.messageId,
    required this.senderId,
    required this.text,
    required this.sentAt,
    required this.mine,
    this.serverAt,
    this.notice = false,
    this.attachment,
    this.unsupportedPhoto = false,
    this.status = SendStatus.sent,
    this.failure,
    this.reply,
    this.reactionStates = const {},
  });

  /// Sender id to emoji for every reaction that is currently set.
  Map<String, String> get reactions => {
    for (final e in reactionStates.entries)
      if (e.value.emoji != null) e.key: e.value.emoji!,
  };

  bool get isPhoto => attachment != null || unsupportedPhoto;

  /// Where the message sits in the conversation: the relay's time when there is
  /// one, so a peer's clock cannot move a message around or evict history.
  DateTime get at => serverAt ?? sentAt;

  /// How far a sender's clock may differ from the relay's before it is not
  /// believed.
  static const clockTrust = Duration(minutes: 10);

  /// The time to show: the sender's own, but only within [clockTrust] of the
  /// relay's; otherwise the relay's. Messages with no relay time show theirs.
  DateTime get shownAt {
    final relay = serverAt;
    if (relay == null) return sentAt;
    return sentAt.difference(relay).abs() <= clockTrust ? sentAt : relay;
  }

  /// This message with its text cleaned of bidirectional and zero-width
  /// controls, for drawing.
  ChatMessage get display {
    final clean = displayText(text);
    return identical(clean, text) ? this : copyWith(text: clean);
  }

  /// One line for the chat list.
  String get preview => attachment != null
      ? (attachment!.caption.isEmpty ? 'Photo' : attachment!.caption)
      : unsupportedPhoto
      ? 'Photo'
      : text;

  ChatMessage copyWith({
    String? text,
    DateTime? serverAt,
    SendStatus? status,
    String? failure,
    bool clearFailure = false,
    ChatReply? reply,
    Map<String, ReactionState>? reactionStates,
  }) => ChatMessage(
    messageId: messageId,
    senderId: senderId,
    text: text ?? this.text,
    sentAt: sentAt,
    mine: mine,
    serverAt: serverAt ?? this.serverAt,
    notice: notice,
    attachment: attachment,
    unsupportedPhoto: unsupportedPhoto,
    status: status ?? this.status,
    failure: clearFailure ? null : failure ?? this.failure,
    reply: reply ?? this.reply,
    reactionStates: reactionStates ?? this.reactionStates,
  );

  Map<String, dynamic> toJson() => {
    'id': messageId,
    'from': senderId,
    'text': text,
    'at': sentAt.toIso8601String(),
    if (serverAt != null) 'srv': serverAt!.toIso8601String(),
    'mine': mine,
    'notice': notice,
    if (attachment != null) 'att': attachment!.toLocalJson(),
    if (unsupportedPhoto) 'bad': true,
    if (status != SendStatus.sent) 'st': status.name,
    'err': ?failure,
    if (reply != null) 're': reply!.toJson(),
    if (reactionStates.isNotEmpty)
      'rx': {for (final e in reactionStates.entries) e.key: e.value.toJson()},
  };
  factory ChatMessage.fromJson(Map<String, dynamic> j) {
    ChatAttachment? attachment;
    var unsupported = j['bad'] as bool? ?? false;
    if (j['att'] != null) {
      try {
        attachment = ChatAttachment.fromLocal(j['att']);
      } on FormatException {
        unsupported = true;
      }
    }
    return ChatMessage(
      messageId: j['id'] as String,
      senderId: j['from'] as String,
      text: displayText(j['text'] as String),
      sentAt: DateTime.parse(j['at'] as String),
      serverAt: DateTime.tryParse(j['srv'] as String? ?? ''),
      mine: j['mine'] as bool,
      notice: j['notice'] as bool? ?? false,
      attachment: attachment,
      unsupportedPhoto: unsupported,
      status: SendStatus.values.asNameMap()[j['st']] ?? SendStatus.sent,
      failure: j['err'] as String?,
      // Both are optional: history written before replies and reactions has
      // neither, and an entry this app did not write is skipped, not fatal.
      reply: ChatReply.parse(j['re']),
      reactionStates: _reactionStatesFrom(j['rx']),
    );
  }

  static Map<String, ReactionState> _reactionStatesFrom(Object? raw) {
    if (raw is! Map) return const {};
    final out = <String, ReactionState>{};
    for (final e in raw.entries) {
      final state = ReactionState.fromJson(e.value);
      if (e.key is String && state != null) out[e.key as String] = state;
    }
    return out.isEmpty ? const {} : out;
  }
}

/// Conversation order: the relay's time, then the id (so equal times are
/// stable). Used for the history and its eviction.
int chatOrder(ChatMessage a, ChatMessage b) {
  final byTime = a.at.compareTo(b.at);
  return byTime != 0 ? byTime : a.messageId.compareTo(b.messageId);
}

/// The server's `sharedInterests` as a list of non-empty strings: a missing,
/// null or malformed value is an empty list, and nothing beyond three is kept.
List<String> parseSharedInterests(Object? raw) {
  if (raw is! List) return const [];
  return [
    for (final v in raw)
      if (v is String && v.trim().isNotEmpty) v,
  ].take(3).toList(growable: false);
}

class ChatConversation {
  final String id, peerId, peerName, peerUsername;

  /// Signed thumbnail URL of the peer's photo, or null.
  final String? peerAvatarUrl;
  final ChatMessage? last;
  final int unreadCount;

  /// When the peer last read, on the relay's clock; null unless both people
  /// have read receipts on.
  final DateTime? peerReadAt;

  /// Set while this account has the chat muted.
  final DateTime? mutedUntil;

  /// Up to three interests both people list, as decided by the server (it
  /// applies the peer's audience for interests). Empty when nothing is shared
  /// or the server sent none.
  final List<String> sharedInterests;

  /// Whether the peer is online right now and lets this account see it, and
  /// otherwise when they were last seen (UTC, a five-minute bucket). The
  /// server sends neither when it must not tell, so a hidden peer is simply
  /// "not online, never seen".
  final bool online;
  final DateTime? lastSeenAt;
  const ChatConversation(
    this.id,
    this.peerId,
    this.peerName,
    this.peerUsername,
    this.last, {
    this.peerAvatarUrl,
    this.unreadCount = 0,
    this.peerReadAt,
    this.mutedUntil,
    this.sharedInterests = const [],
    this.online = false,
    this.lastSeenAt,
  });

  bool get muted => mutedUntil?.isAfter(DateTime.now()) ?? false;
}

/// The saved account cannot be opened; see [ChatEngine._loadIdentity].
class _StateLocked implements Exception {
  const _StateLocked();
}

class _Device {
  final String id, identityKey, signingKey;
  const _Device(this.id, this.identityKey, this.signingKey);
}

/// What a [DeviceNotice] says happened.
enum DeviceNoticeKind {
  /// A device was added to this account since this phone last looked.
  added,

  /// This phone had no record of the account's devices (a new install, a sign-in, a reset) and found
  /// others on the relay: the person is asked to look at them, nothing is pinned silently.
  review,

  /// A device this phone knew of was removed by another session (the relay's record, or it vanished).
  removed,

  /// This phone's own chat identity was replaced because the relay had removed this device (by another
  /// session) and would not take its keys back. (A device removed only for not being used comes back with the
  /// same identity and says nothing.)
  reset,

  /// This phone's encrypted data could not be unlocked, so it started again with a new identity.
  locked,

  /// The person chose "Reset chat on this phone" after the platform keystore could not be opened on several
  /// launches in a row: this phone's chat data was erased and a new identity made.
  storage,

  /// The relay removed a device of this account that had not been used for days while its undelivered
  /// messages piled up (so it would not stop other people's messages reaching the account).
  inactive,

  /// The relay signed a device of this account out of chat because it had not been used for a long time (or
  /// sat idle while one person's messages filled it). Nothing is wrong: opening Hiyall on it brings it back
  /// with the same keys. A calm note, never an alarm.
  idle,
}

/// Something about this account's devices that the person should see, noticed by this phone. Kept until
/// dismissed, across restarts.
class DeviceNotice {
  /// The device it is about; empty for [DeviceNoticeKind.review], [reset], [locked] and [storage].
  final String deviceId;
  final DateTime at;
  final DeviceNoticeKind kind;
  const DeviceNotice(
    this.deviceId,
    this.at, [
    this.kind = DeviceNoticeKind.added,
  ]);
  Map<String, dynamic> toJson() => {
    'id': deviceId,
    'at': at.toUtc().toIso8601String(),
    if (kind != DeviceNoticeKind.added) 'k': kind.name,
  };
  static DeviceNotice? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'], at = DateTime.tryParse('${raw['at']}');
    final kind =
        DeviceNoticeKind.values.asNameMap()[raw['k']] ?? DeviceNoticeKind.added;
    return id is String && at != null ? DeviceNotice(id, at, kind) : null;
  }
}

/// What the safety-number screen shows. Reading it never pins anything.
class SafetyInfo {
  final String number;

  /// The person has compared this exact number (and nothing has changed since).
  final bool verified;

  /// They had verified before, and the keys changed since: shown first.
  final bool changedSinceVerified;

  /// Devices the relay lists for the peer that this phone has not pinned yet
  /// (added since the last message). They are in [number].
  final int newDevices;
  final String peerFingerprint, myFingerprint;
  const SafetyInfo({
    required this.number,
    required this.verified,
    required this.changedSinceVerified,
    required this.newDevices,
    required this.peerFingerprint,
    required this.myFingerprint,
  });

  bool get changed => changedSinceVerified || newDevices > 0;
}

/// A decrypted message on its way into the history, with the way back: if the
/// history cannot be written, the ratchet goes back to where it was and the
/// message stays on the relay to be delivered again.
class _Opened {
  final String plaintext;
  final void Function() undo;
  const _Opened(this.plaintext, this.undo);
}

/// One device's end-to-end encrypted chat client. All Olm operations are
/// serialized, and ratchet state is persisted before ciphertext leaves the
/// device or a delivery is acknowledged, so message keys are never reused.
class ChatEngine {
  /// Olm sessions kept per peer device, newest first. A peer that starts a
  /// session while we start one (two people waving at once) leaves two live
  /// sessions; messages are tried against each, and the one that last worked
  /// is the one used for sending.
  static const maxSessionsPerDevice = 5;

  /// At most one fresh session, with its quiet "noop" message, per peer device
  /// in this long, however many messages fail.
  static const unwedgeEvery = Duration(hours: 1);

  final String userId, platform;
  final ChatApi api;
  final ChatStore store;
  final _random = Random.secure();
  final _changes = StreamController<String>.broadcast();
  final _ownDeviceChanges = StreamController<void>.broadcast();
  Future<void> _queue = Future.value();
  late List<int> _pickleKey;
  late OlmAccount _account;
  late String deviceId;
  final _sessions = <String, List<OlmSession>>{};
  Map<String, Map<String, dynamic>> _trust = {};
  final _unwedged = <String, DateTime>{};
  final _peerNotices = <String, List<DeviceNotice>>{};
  List<DeviceNotice> _ownNotices = [];
  final _verified = <String, Map<String, dynamic>>{};
  final _verifyChanged = <String>{};

  /// Message ids opened in this run, oldest first (a bounded memory of what
  /// the history and the saved ratchet already have).
  final _processed = <String>{};
  late final ChatHistory _log;
  final DateTime Function() _clock;
  Timer? _timer;
  bool _started = false;

  /// Set by [dispose]: nothing new starts, and no write reaches the store any more.
  bool _disposed = false;
  Future<void>? _drained;

  /// How long [dispose] waits for work that was in flight (a poll, a send, an upload) before it lets the
  /// caller go on; whatever is still running after that can no longer write anything.
  static const drainTimeout = Duration(seconds: 5);

  /// Every write the engine and what it owns (history, outbox) make goes through this, so [dispose] can
  /// close it and wait for what already started.
  late final GuardedChatStore _store = GuardedChatStore(store, () => _disposed);

  /// The app is in the background: the inbox timer is stopped (see [pause]).
  bool _paused = false;
  Duration _pollEvery = Duration.zero;

  /// Fallback key rotation (audit F11). The fallback key is what a peer uses
  /// when every one-time key is claimed. It is replaced every
  /// [fallbackRotateEvery]; the key it replaced is forgotten [fallbackGrace]
  /// after the new one was published, once the inbox has been read to the end
  /// (so a pre-key message made for the old key that is still waiting on the
  /// relay is opened first). Both times are kept with the account.
  static const fallbackRotateEvery = Duration(days: 7);
  static const fallbackGrace = Duration(hours: 24);
  DateTime? _fbRotated, _fbForgetAt;

  /// Set when a poll left a message on the relay for the next poll.
  bool _leftBehind = false;

  /// Photos: the codec and transport behind the native core and object
  /// storage, and the app's private folder for the outbox and the ciphertext
  /// cache. Without a folder the engine handles text only.
  final ChatBlobCodec? codec;
  final ChatBlobTransport? transport;
  final Directory? mediaRoot;
  final int cacheLimit;

  /// Waits between the attempts a reaction makes after a transient failure
  /// (the message id stays the same, so a retry never duplicates). Tests pass
  /// zeros.
  final List<Duration> reactionRetryDelays;

  /// Waits between the attempts to top up this device's keys on the relay after one failed (the engine starts
  /// and sends from the keys it already has meanwhile). The last wait repeats. Tests pass short ones.
  final List<Duration> keyRetryDelays;

  /// Called after this device registered again following a removal by the relay (an idle sign-out, or a new
  /// identity): the relay dropped its push token then, so whoever holds the token sends it again.
  void Function()? onReregistered;

  /// Waits between the attempts to register this device again after the relay removed it and that did not
  /// work (the account is full, the relay is out of reach): the wait grows, the last one repeats, and nothing
  /// is rewritten meanwhile (audit CHAT-N5). Tests pass short ones.
  final List<Duration> reregisterDelays;

  /// A notice to show once this engine has started with a fresh identity: the explicit reset the person chose
  /// after the keystore could not be opened ([DeviceNoticeKind.storage]).
  final DeviceNoticeKind? startNotice;
  Timer? _keyRetry;
  int _keyFailures = 0;
  int _reregisterFailures = 0;
  DateTime? _reregisterNotBefore;

  /// The relay does not hold this device and registering it again has not worked yet (see [_recoverRemoved]):
  /// nothing that needs the relay (keys, fallback rotation) is attempted meanwhile.
  bool _awaitingRegistration = false;
  ChatMedia? _media;
  PhotoOutbox? _outbox;

  ChatEngine({
    required this.userId,
    required this.api,
    required this.store,
    this.platform = 'unknown',
    this.codec,
    this.transport,
    this.mediaRoot,
    this.cacheLimit = 200 * 1024 * 1024,
    this.reactionRetryDelays = const [
      Duration(milliseconds: 800),
      Duration(seconds: 2),
    ],
    this.keyRetryDelays = const [
      Duration(seconds: 5),
      Duration(seconds: 15),
      Duration(minutes: 1),
      Duration(minutes: 5),
      Duration(minutes: 15),
    ],
    this.reregisterDelays = const [
      Duration(seconds: 30),
      Duration(minutes: 1),
      Duration(minutes: 2),
      Duration(minutes: 5),
      Duration(minutes: 15),
    ],
    this.startNotice,
    DateTime Function()? clock,
    ChatMedia? media,
  }) : _clock = clock ?? DateTime.now {
    final root = mediaRoot;
    final blobCodec = codec ?? const RustChatBlobCodec();
    final blobTransport = transport ?? DioBlobTransport();
    ChatBlobCache? cache;
    if (root != null) {
      cache = ChatBlobCache(
        Directory('${root.path}/chat_blobs'),
        maxBytes: cacheLimit,
      );
      _media = ChatMedia(
        api: api,
        transport: blobTransport,
        codec: blobCodec,
        cache: cache,
      );
    }
    // Tests may stand in for the downloader.
    _media = media ?? _media;
    _log = ChatHistory(
      _store,
      (id) => _k('history.$id'),
      clock: _clock,
      onChange: (id) {
        if (!_changes.isClosed) _changes.add(id);
      },
      onDropped: (conversationId, dropped, kept) {
        Iterable<String> keysOf(List<ChatMessage> messages) sync* {
          for (final m in messages) {
            final a = m.attachment;
            if (a == null) continue;
            for (final part in [a.full, a.thumb]) {
              final id = part.blobId;
              if (id != null) {
                yield blobCacheKey(conversationId, id, part.ctSha256);
              }
            }
          }
        }

        // A cached file stays while a message that is kept still names it.
        final stay = keysOf(kept).toSet();
        final gone = [
          for (final key in keysOf(dropped))
            if (!stay.contains(key)) key,
        ];
        if (gone.isNotEmpty) unawaited(cache?.deleteAll(gone));
      },
    );
    if (root != null) {
      _outbox = PhotoOutbox(
        userId: userId,
        api: api,
        transport: blobTransport,
        codec: blobCodec,
        store: _store,
        history: _log,
        cache: cache!,
        dir: Directory('${root.path}/chat_outbox'),
        storeKey: _k('outbox'),
        deliver: (conversation, peer, id, payload, blobIds) => _locked(
          () => _deliver(conversation, peer, id, jsonEncode(payload), blobIds),
        ),
      );
    }
  }

  /// Fetching, verifying and decrypting received photos; null without a media folder.
  ChatMedia? get media => _media;
  ChatBlobCodec get blobCodec => codec ?? const RustChatBlobCodec();

  /// Removes one account's chat data without an engine (sign-out: the engine
  /// for that account no longer exists): every `hiyall.chat.<userId>.*` entry,
  /// the photo cache and unsent uploads. See [ChatLocalData.wipeAccount] for
  /// the server-side removal of the device.
  static Future<void> wipeLocalMedia({
    required Directory root,
    required ChatStore store,
    required String userId,
  }) => ChatLocalData.wipeAccount(root: root, store: store, userId: userId);

  /// Emits a conversation id whenever its messages change.
  Stream<String> get changes => _changes.stream;
  String get identityKey => _account.identityKey();
  String _k(String name) => 'hiyall.chat.$userId.$name';

  Future<T> _locked<T>(Future<T> Function() work) {
    if (_disposed) return Future.error(const ChatStoreClosed());
    final result = _queue.then((_) => work());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<void> start({Duration poll = const Duration(seconds: 2)}) => _locked(
    () async {
      if (_started) return;
      await _loadNotes();
      // The snapshot files existed and none opened (the key is gone, or they are damaged), or only the
      // previous generation did (an older state than the one last committed: its ratchets may be behind what
      // peers already saw). Neither is an identity to carry on with: start a new one and say so, never
      // silently (audit CHAT-N8). Also checked for the keystore that was wiped with files left behind.
      final opened = store;
      if (opened is SnapshotChatStore && opened.info.identityUntrusted) {
        await _resetIdentity(because: DeviceNoticeKind.locked);
      }
      try {
        await _loadIdentity();
      } on _StateLocked {
        // The saved account cannot be opened (its key is gone or unusable, or the entry is damaged). Nothing
        // here can be recovered: start again with a new identity and say so (re-audit CHAT-5).
        await _resetIdentity(because: DeviceNoticeKind.locked);
        await _loadIdentity();
      }
      try {
        await _register();
      } on ChatFailure catch (failure) {
        // The relay says this device id or key belongs to something else, or
        // was revoked by someone (removed from the device list, signed out
        // elsewhere). The old identity is of no use: make a new one. (A device
        // removed only for being unused is taken back with its keys by the
        // registration above, so it never gets here.)
        if (failure.code != 'DEVICE_CONFLICT') rethrow;
        await _resetIdentity(because: DeviceNoticeKind.reset);
        await _loadIdentity();
        await _register();
      }
      final reason = startNotice;
      if (reason != null) {
        _addOwnNotice(DeviceNotice('', _clock().toUtc(), reason));
        await _saveNotes();
        if (!_ownDeviceChanges.isClosed) _ownDeviceChanges.add(null);
      }
      _started = true;
      // A wipe (sign-out) closes this engine first and waits for what it was doing.
      ChatLocalData.registerDrain(userId, dispose);
      await ChatLocalData.markOwner(_store, userId);
      await _afterStart();
      if (poll > Duration.zero) {
        _pollEvery = poll;
        _startTimer();
      }
    },
  );

  /// Housekeeping that must never stop chat from starting.
  Future<void> _afterStart() async {
    try {
      // A removal of an earlier device (sign-out or reinstall offline) that
      // was waiting for a connection.
      final pending = await ChatLocalData.pendingRevoke(store, userId);
      if (pending != null) {
        if (pending != deviceId) {
          try {
            await api.revokeDevice(pending);
          } on ChatFailure catch (failure) {
            // Already gone is as good as removed.
            if (failure.status != 404) rethrow;
          }
        }
        await ChatLocalData.clearPendingRevoke(store, userId);
      }
    } catch (_) {
      // Tried again next launch.
    }
    try {
      // Pin this account's own devices, so a later one is noticed.
      await _devices(userId);
      await _noticeRemoved();
    } catch (_) {}
  }

  /// Stops the engine for good: the inbox timer and uploads stop, nothing new starts, and no write reaches the
  /// store from now on. The returned future completes when the work that was in flight has finished (at most
  /// [drainTimeout]), so a caller that wipes the account's files next can be sure nothing writes them again.
  /// Safe to call twice and to ignore.
  Future<void> dispose() => _drained ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _keyRetry?.cancel();
    _keyRetry = null;
    final outbox = _outbox;
    outbox?.dispose();
    _media?.cache.close();
    _changes.close();
    _ownDeviceChanges.close();
    ChatLocalData.unregisterDrain(userId, dispose);
    try {
      await Future.wait<void>([_queue, ?outbox?.drain(), _store.drain()])
          .timeout(drainTimeout);
    } catch (_) {
      // Whatever is still running can no longer write.
    }
  }

  /// Opens (or creates) the key, account, sessions and device id from the
  /// store. Account and sessions live in one entry, written in one call, so a
  /// crash cannot leave one newer than the other. Entries written by earlier
  /// builds (`account`, `sessions`) are read once and moved.
  Future<void> _loadIdentity() async {
    final savedKey = await store.read(_k('pickleKey'));
    try {
      _pickleKey = savedKey == null
          ? List<int>.generate(32, (_) => _random.nextInt(256))
          : base64Decode(savedKey);
    } on FormatException {
      throw const _StateLocked();
    }
    if (savedKey == null) {
      await _store.write(_k('pickleKey'), base64Encode(_pickleKey));
    }
    _sessions.clear();
    _fbRotated = _fbForgetAt = null;
    final combined = await store.read(_k('state'));
    var legacy = false;
    Object? sessionData;
    // Storage reads come first and may fail on their own (a keystore that is not ready): that is an error
    // to retry later, never a reason to throw an identity away. Only bytes that were read and cannot be
    // opened (a missing or different pickle key, a damaged entry) make [_StateLocked]; a device with no
    // account at all simply makes one.
    final savedAccount = combined == null
        ? await store.read(_k('account'))
        : null;
    final old = combined == null ? await store.read(_k('sessions')) : null;
    try {
      if (combined != null) {
        final j = jsonDecode(combined) as Map;
        _account = OlmAccount.restore(
          pickle: j['account'] as String,
          pickleKey: _pickleKey,
        );
        sessionData = j['sessions'];
        final fb = j['fb'];
        if (fb is Map) {
          _fbRotated = DateTime.tryParse('${fb['rot']}');
          _fbForgetAt = DateTime.tryParse('${fb['forget']}');
        }
      } else {
        _account = savedAccount == null
            ? OlmAccount.create()
            : OlmAccount.restore(pickle: savedAccount, pickleKey: _pickleKey);
        sessionData = old == null ? null : jsonDecode(old);
        legacy = savedAccount != null || old != null;
      }
    } catch (_) {
      throw const _StateLocked();
    }
    if (sessionData is Map) {
      sessionData.forEach((device, value) {
        final list = <OlmSession>[];
        for (final pickle in value is List ? value : [value]) {
          try {
            list.add(
              OlmSession.restore(
                pickle: pickle as String,
                pickleKey: _pickleKey,
              ),
            );
          } catch (_) {
            // A session that cannot be opened is as good as lost; the others
            // and the unwedging below carry on.
          }
        }
        if (list.isNotEmpty) _sessions[device as String] = list;
      });
    }
    deviceId = await store.read(_k('deviceId')) ?? newUuid4(_random);
    await _saveState();
    await _store.write(_k('deviceId'), deviceId);
    if (legacy) {
      await _store.delete(_k('account'));
      await _store.delete(_k('sessions'));
    }
  }

  Future<void> _register() async {
    await api.registerDevice({
      'deviceId': deviceId,
      'identityKey': _account.identityKey(),
      'signingKey': _account.signingKey(),
      'platform': platform,
      'signature': _account.sign(
        message: deviceStatement(
          userId,
          deviceId,
          _account.identityKey(),
          _account.signingKey(),
        ),
      ),
    });
    // The device is registered; topping up its keys is housekeeping that never stops chat from starting: a
    // failure is retried with growing waits, and sends that need keys work from the ones already on the
    // relay (audit CHAT-N5).
    await _replenishQuietly();
  }

  /// [_replenishKeys] that never throws: a failure schedules another attempt (see [keyRetryDelays]).
  Future<void> _replenishQuietly() async {
    try {
      await _replenishKeys();
      _keyFailures = 0;
    } on ChatStoreClosed {
      // Disposed meanwhile.
    } catch (_) {
      _scheduleKeyRetry();
    }
  }

  void _scheduleKeyRetry() {
    if (_disposed || _keyRetry != null || keyRetryDelays.isEmpty) return;
    final delay = keyRetryDelays[min(_keyFailures, keyRetryDelays.length - 1)];
    _keyFailures++;
    _keyRetry = Timer(delay, () {
      _keyRetry = null;
      if (_disposed) return;
      unawaited(_locked(_replenishQuietly).catchError((_) {}));
    });
  }

  /// Forgets this device's identity (account, sessions, id) so a new one is
  /// made, and says why with [because] (a notice the person sees until they
  /// dismiss it). Only this device's own state goes, plus the verification
  /// marks, which depend on the identity being replaced. History stays, and so
  /// does every pin: other people's devices, and this account's OTHER devices.
  /// Keeping those is what lets the relay's list be compared afterwards, so a
  /// device added by someone else while this one was being reset is announced,
  /// never pinned silently (re-audit CHAT-2).
  ///
  /// The order matters and survives a kill between any two steps: the account
  /// state goes first and the key that opens it last, so a stop in the middle
  /// leaves at worst a key with nothing to open, never state with no key
  /// (which would be a lock-out on the next start).
  Future<void> _resetIdentity({DeviceNoticeKind? because}) async {
    final oldDevice = await store.read(_k('deviceId'));
    // The old identity may still be listed on the relay (its keys are lost here, so nothing can use it):
    // ask for it to be removed at the next start, so it does not stay among the account's devices.
    if (oldDevice != null) {
      await ChatLocalData.rememberRevoke(_store, userId, oldDevice);
    }
    for (final name in [
      'state',
      'account',
      'sessions',
      'deviceId',
      'pickleKey',
    ]) {
      await _store.delete(_k(name));
    }
    _sessions.clear();
    _fbRotated = _fbForgetAt = null;
    _unwedged.clear();
    final own = _trust[userId];
    if (own != null && oldDevice != null) {
      own.remove(oldDevice);
      if (own.isEmpty) _trust.remove(userId);
    }
    await _store.write(_k('trust'), jsonEncode(_trust));
    _verified.clear();
    _verifyChanged.clear();
    if (because != null) {
      _addOwnNotice(DeviceNotice('', _clock().toUtc(), because));
    }
    await _saveNotes();
    if (because != null && !_ownDeviceChanges.isClosed) {
      _ownDeviceChanges.add(null);
    }
  }

  /// Adds a notice for the person to see; one about the same thing is not added twice.
  void _addOwnNotice(DeviceNotice notice) {
    final exists = _ownNotices.any(
      (n) => n.kind == notice.kind && n.deviceId == notice.deviceId,
    );
    if (exists) return;
    final all = [..._ownNotices, notice];
    _ownNotices = all.length > 10 ? all.sublist(all.length - 10) : all;
  }

  /// Account and every session in one write.
  Future<void> _saveState() => _store.write(
    _k('state'),
    jsonEncode({
      'v': 2,
      'account': _account.pickle(pickleKey: _pickleKey),
      'sessions': {
        for (final e in _sessions.entries)
          e.key: [for (final s in e.value) s.pickle(pickleKey: _pickleKey)],
      },
      if (_fbRotated != null || _fbForgetAt != null)
        'fb': {
          'rot': ?_fbRotated?.toUtc().toIso8601String(),
          'forget': ?_fbForgetAt?.toUtc().toIso8601String(),
        },
    }),
  );

  Future<void> _loadNotes() async {
    final trust = await store.read(_k('trust'));
    if (trust != null) {
      _trust = (jsonDecode(trust) as Map).map(
        (k, v) => MapEntry(k as String, Map<String, dynamic>.from(v as Map)),
      );
    }
    try {
      final wedge = await store.read(_k('unwedge'));
      if (wedge != null) {
        (jsonDecode(wedge) as Map).forEach((k, v) {
          final at = DateTime.tryParse('$v');
          if (at != null) _unwedged['$k'] = at;
        });
      }
      final notes = await store.read(_k('devnotes'));
      if (notes != null) {
        final j = jsonDecode(notes) as Map;
        _ownNotices = [
          for (final n in (j['own'] as List? ?? const []))
            ?DeviceNotice.fromJson(n),
        ];
        _peerNotices.clear();
        ((j['peers'] as Map?) ?? const {}).forEach((peer, list) {
          final parsed = [
            for (final n in list as List) ?DeviceNotice.fromJson(n),
          ];
          if (parsed.isNotEmpty) _peerNotices['$peer'] = parsed;
        });
      }
      final marks = await store.read(_k('verified'));
      if (marks != null) {
        final j = jsonDecode(marks) as Map;
        _verified.clear();
        ((j['ok'] as Map?) ?? const {}).forEach((peer, entry) {
          if (entry is Map) {
            _verified['$peer'] = Map<String, dynamic>.from(entry);
          }
        });
        _verifyChanged
          ..clear()
          ..addAll([for (final p in (j['changed'] as List? ?? const [])) '$p']);
      }
    } catch (_) {
      // These are conveniences around the keys; unreadable means start empty.
    }
  }

  /// The three note entries as one commit.
  Future<void> _saveNotes() => _store.batch(() async {
    await _store.write(
      _k('unwedge'),
      jsonEncode({
        for (final e in _unwedged.entries)
          e.key: e.value.toUtc().toIso8601String(),
      }),
    );
    await _store.write(
      _k('devnotes'),
      jsonEncode({
        'own': [for (final n in _ownNotices) n.toJson()],
        'peers': {
          for (final e in _peerNotices.entries)
            e.key: [for (final n in e.value) n.toJson()],
        },
      }),
    );
    await _store.write(
      _k('verified'),
      jsonEncode({'ok': _verified, 'changed': _verifyChanged.toList()}),
    );
  });

  bool _noKeys = false;

  bool get _fallbackDue {
    if (_noKeys) return false;
    final rotated = _fbRotated;
    return rotated == null ||
        _clock().toUtc().difference(rotated) >= fallbackRotateEvery;
  }

  /// The relay is topped up when it holds fewer than [oneTimeLow] of this
  /// device's one-time keys, back to [oneTimeTarget]; it takes at most
  /// [uploadChunk] keys per request and holds at most 100.
  static const oneTimeLow = 20, oneTimeTarget = 60, uploadChunk = 50;

  /// Tops up one-time keys when the relay holds few, and replaces the fallback
  /// key when it is due. The private halves are saved before the public halves
  /// become claimable, and the rotation is only recorded once the relay has the
  /// new fallback key (the old one keeps working until then).
  ///
  /// Keys go up in requests of at most [uploadChunk] (see [publishOneTimeKeys]).
  /// The core makes only the shortfall, so after any failure the unpublished
  /// keys are those that did not arrive, and the retry sends exactly them: it
  /// can never exceed what the relay accepts, so a failed upload (offline, a
  /// refusal) cannot wedge every later start (re-audit CHAT-1). Everything the
  /// core holds unpublished is uploaded, also when an older build left more than
  /// one request's worth, and is marked published only after the relay has it
  /// all (audit CHAT-N9). The fallback key travels with the first request, so it
  /// is not held back by the one-time keys, and when only the fallback is due it
  /// goes alone.
  Future<void> _replenishKeys() async {
    final count = await api.keyCount(deviceId);
    final rotate = _fallbackDue;
    if (count >= oneTimeLow && !rotate) return;
    final want = count >= oneTimeLow ? 0 : max(0, oneTimeTarget - count);
    // A fallback key made by an attempt that did not reach the relay is
    // offered again; making another would push the published one out.
    final fallback = rotate
        ? _account.unpublishedFallbackKey() ?? _account.generateFallbackKey()
        : null;
    await publishOneTimeKeys(
      onRelay: count,
      want: want,
      fallback: fallback,
      generate: (n) => _account.generateOneTimeKeys(count: n),
      sign: (k) => {
        'keyId': k.keyId,
        'publicKey': k.publicKey,
        'signature': _account.sign(
          message: oneTimeKeyStatement(userId, deviceId, k.keyId, k.publicKey),
        ),
      },
      save: _saveState,
      upload: (keys, fallbackKey) =>
          api.uploadKeys(deviceId, keys, fallbackKey),
      markPublished: _account.markKeysAsPublished,
      fallbackPublished: () async {
        final now = _clock().toUtc();
        _fbRotated = now;
        _fbForgetAt = now.add(fallbackGrace);
      },
    );
  }

  /// Rotates the fallback key if it is due and forgets the previous one once
  /// its grace period is over. Called after the inbox was read to the end;
  /// never throws.
  Future<void> _maintainFallback() async {
    try {
      if (_fallbackDue) await _replenishKeys();
      final forgetAt = _fbForgetAt;
      if (forgetAt != null && !_clock().toUtc().isBefore(forgetAt)) {
        _account.forgetOldFallbackKey();
        _fbForgetAt = null;
        await _saveState();
      }
    } catch (_) {
      // Tried again after the next poll.
    }
  }

  /// A stable summary of a person's device keys, to notice that they changed.
  String _fingerprint(String user, List<_Device> devices) {
    final keys = [for (final d in devices) d.identityKey]..sort();
    return base64Encode(
      sha256
          .convert(utf8.encode('hiyall-devices-v1\n$user\n${keys.join('\n')}'))
          .bytes,
    );
  }

  /// Fetches a user's devices and checks them: signatures, contributory keys,
  /// and the keys pinned on first use (a known device id with other keys stops
  /// everything with `KEY_CHANGED`). Pins nothing: the caller decides.
  Future<({List<_Device> list, Set<String> unpinned})> _fetchDevices(
    String user,
  ) async {
    final known = _trust[user] ?? {};
    final list = <_Device>[];
    final unpinned = <String>{};
    for (final d in await api.devices(user)) {
      final id = d['deviceId'] as String;
      final identity = d['identityKey'] as String,
          signing = d['signingKey'] as String;
      if (!verifySignature(
            signingKey: signing,
            message: deviceStatement(user, id, identity, signing),
            signature: d['signature'] as String,
          ) ||
          !isContributoryKey(key: identity)) {
        continue;
      }
      final pinned = known[id];
      if (pinned != null &&
          (pinned['identityKey'] != identity ||
              pinned['signingKey'] != signing)) {
        await _keysChanged(user);
        throw const ChatFailure(
          'KEY_CHANGED',
          'A device presented changed keys. Messages to it are blocked.',
        );
      }
      if (pinned == null) unpinned.add(id);
      list.add(_Device(id, identity, signing));
    }
    return (list: list, unpinned: unpinned);
  }

  /// Fetches a user's devices and pins new ones on first use. A new device on
  /// a known account is recorded: for this account's own devices as a notice
  /// the owner sees (and a realtime signal told them), for a peer as a notice
  /// in every conversation with them, shown when it is next opened (and in
  /// [conversationId] at once).
  ///
  /// The pins and the notices about them are one commit, and the engine's memory follows the store, never
  /// leads it: everything is worked out on copies, written together (the notice in the conversation included),
  /// and only a commit that landed changes what the engine remembers. A write that fails (the history cannot be
  /// written) leaves the device unpinned, in memory and on disk alike, so the next look announces it again
  /// instead of pinning it silently (audit CHAT-N6).
  Future<List<_Device>> _devices(String user, {String? conversationId}) async {
    final wasKnown = _trust.containsKey(user);
    final before = _trust[user];
    final firstContact = before == null || before.isEmpty;
    final fetched = await _fetchDevices(user);
    final known = {
      for (final e
          in (before ?? const <String, Map<String, dynamic>>{}).entries)
        e.key: Map<String, dynamic>.of(e.value),
    };
    final ownBefore = _ownNotices;
    final peersBefore = Map<String, List<DeviceNotice>>.of(_peerNotices);
    final verifiedBefore = Map<String, Map<String, dynamic>>.of(_verified);
    final changedBefore = Set<String>.of(_verifyChanged);
    var notes = false, pinsChanged = false, signal = false;
    final appends = <ChatMessage>[];
    // This phone knows of none of this account's devices (a new install, a sign-in, a reset) and the relay
    // lists others: they are pinned (they have to be, to send to them) but never silently. The person is asked
    // to review them, and the notice stays until dismissed (re-audit CHAT-2).
    if (user == userId &&
        firstContact &&
        fetched.list.any((d) => d.id != deviceId)) {
      _addOwnNotice(
        DeviceNotice('', _clock().toUtc(), DeviceNoticeKind.review),
      );
      notes = signal = true;
    }
    for (final d in fetched.list) {
      final pin = known[d.id];
      if (pin != null && pin['idle'] == true) {
        // A device the relay had signed out as idle is back with the keys that are pinned: nothing is new, the
        // note about its absence goes.
        pin.remove('idle');
        pinsChanged = true;
        if (user == userId) {
          final kept = [
            for (final n in _ownNotices)
              if (!(n.kind == DeviceNoticeKind.idle && n.deviceId == d.id)) n,
          ];
          if (kept.length != _ownNotices.length) {
            _ownNotices = kept;
            notes = signal = true;
          }
        }
      }
      if (!fetched.unpinned.contains(d.id)) continue;
      known[d.id] = {'identityKey': d.identityKey, 'signingKey': d.signingKey};
      pinsChanged = true;
      if (firstContact || d.id == deviceId) continue;
      final notice = DeviceNotice(d.id, _clock().toUtc());
      notes = true;
      if (user == userId) {
        _addOwnNotice(notice);
        signal = true;
      } else {
        final kept = [...?_peerNotices[user], notice];
        _peerNotices[user] = kept.length > 10
            ? kept.sublist(kept.length - 10)
            : kept;
        if (conversationId != null) appends.add(_deviceNotice(user, notice));
      }
    }
    try {
      await _log.transaction(() async {
        for (final notice in appends) {
          await _append(conversationId!, notice);
        }
        _trust[user] = known;
        // Nothing new to pin is the usual case: do not rewrite the store for it.
        if (!wasKnown || pinsChanged) {
          await _store.write(_k('trust'), jsonEncode(_trust));
        }
        await _checkVerified(user, fetched.list, saveNotes: notes);
      });
    } catch (_) {
      _ownNotices = ownBefore;
      _peerNotices
        ..clear()
        ..addAll(peersBefore);
      if (before == null) {
        _trust.remove(user);
      } else {
        _trust[user] = before;
      }
      _verified
        ..clear()
        ..addAll(verifiedBefore);
      _verifyChanged
        ..clear()
        ..addAll(changedBefore);
      rethrow;
    }
    if (signal && !_ownDeviceChanges.isClosed) _ownDeviceChanges.add(null);
    return fetched.list;
  }

  ChatMessage _deviceNotice(String user, DeviceNotice notice) => ChatMessage(
    messageId: 'notice-${notice.deviceId}',
    senderId: user,
    text: 'A new device was added to this account.',
    sentAt: notice.at,
    mine: false,
    notice: true,
  );

  /// Puts the "new device" notices for [peerId] into [conversationId]. Call it
  /// when a conversation is opened: a device added to the peer's account is
  /// announced in every conversation with them, not only the one that happened
  /// to see it first. Safe to repeat (a notice is added once).
  Future<void> showDeviceNotices(String conversationId, String peerId) async {
    final cutoff = _clock().toUtc().subtract(const Duration(days: 30));
    for (final n in [...?_peerNotices[peerId]]) {
      if (n.at.isAfter(cutoff)) {
        await _append(conversationId, _deviceNotice(peerId, n));
      }
    }
  }

  /// Devices added to this account that the person has not seen yet.
  List<DeviceNotice> get ownDeviceNotices => List.unmodifiable(_ownNotices);

  /// Emits when [ownDeviceNotices] changes.
  Stream<void> get ownDeviceChanges => _ownDeviceChanges.stream;

  DateTime? _ownRefreshed;

  /// Looks at this account's devices again: on a realtime signal (one was added or removed), when the socket
  /// is ready or resynchronises, and when the app comes back to the foreground, so a signal that was missed
  /// is still found. New devices raise a notice, and so does a device this phone knew of that another
  /// session removed (the relay keeps that record for 30 days). With [minAge], a look that was made less
  /// than that ago is not repeated.
  Future<void> refreshOwnDevices({Duration minAge = Duration.zero}) =>
      _locked(() async {
        if (!_started) return;
        final last = _ownRefreshed;
        if (minAge > Duration.zero &&
            last != null &&
            _clock().difference(last) < minAge) {
          return;
        }
        await _devices(userId);
        _ownRefreshed = _clock();
        await _noticeRemoved();
      });

  /// The relay's record of devices of this account that another session or the relay itself removed: each one
  /// this phone had pinned becomes a notice. A removal by another session also drops its pin; an idle one (the
  /// relay signed a device out that nobody had used for a long time) keeps it, marked, so that the same device
  /// coming back with the same keys is not announced as a new one, and the note appears once, not at every
  /// look. Best effort; a failure is tried again next time.
  Future<void> _noticeRemoved() async {
    final List<Map<String, dynamic>> removed;
    try {
      removed = await api.removedDevices();
    } catch (_) {
      return;
    }
    final before = _trust[userId];
    if (before == null) return;
    final pins = {
      for (final e in before.entries) e.key: Map<String, dynamic>.of(e.value),
    };
    final ownBefore = _ownNotices;
    var changed = false;
    for (final r in removed) {
      final id = r['deviceId'];
      if (id is! String || id == deviceId) continue;
      final pin = pins[id];
      if (pin == null) continue;
      final idle = r['reason'] == 'idle';
      if (idle && pin['idle'] == true) continue;
      if (idle) {
        pin['idle'] = true;
      } else {
        pins.remove(id);
      }
      _addOwnNotice(
        DeviceNotice(
          id,
          DateTime.tryParse('${r['removedAt']}') ?? _clock().toUtc(),
          idle
              ? DeviceNoticeKind.idle
              : r['reason'] == 'inactive'
              ? DeviceNoticeKind.inactive
              : DeviceNoticeKind.removed,
        ),
      );
      changed = true;
    }
    if (!changed) return;
    // The dropped pins and their notices land together (audit CHAT-N6), and the memory follows the commit.
    _trust[userId] = pins;
    try {
      await _store.batch(() async {
        await _store.write(_k('trust'), jsonEncode(_trust));
        await _saveNotes();
      });
    } catch (_) {
      _trust[userId] = before;
      _ownNotices = ownBefore;
      rethrow;
    }
    if (!_ownDeviceChanges.isClosed) _ownDeviceChanges.add(null);
  }

  /// The person saw the "new device" banner.
  Future<void> dismissOwnDeviceNotices() async {
    if (_ownNotices.isEmpty) return;
    _ownNotices = [];
    await _saveNotes();
    if (!_ownDeviceChanges.isClosed) _ownDeviceChanges.add(null);
  }

  Future<void> _keysChanged(String user) async {
    if (_verified.remove(user) != null) {
      _verifyChanged.add(user);
      await _saveNotes();
    }
  }

  /// A person's verification holds only while their devices (and this
  /// account's) are the ones that were compared: a change clears it.
  Future<void> _checkVerified(
    String user,
    List<_Device> devices, {
    bool saveNotes = false,
  }) async {
    final fp = _fingerprint(user, devices);
    var changed = saveNotes;
    if (user == userId) {
      for (final peer in _verified.keys.toList()) {
        if (_verified[peer]!['myFp'] != fp) {
          _verified.remove(peer);
          _verifyChanged.add(peer);
          changed = true;
        }
      }
    } else {
      final entry = _verified[user];
      if (entry != null && entry['peerFp'] != fp) {
        _verified.remove(user);
        _verifyChanged.add(user);
        changed = true;
      }
    }
    if (changed) await _saveNotes();
  }

  /// Whether the person compared this peer's safety number and nothing has
  /// changed since.
  bool isVerified(String peerId) => _verified.containsKey(peerId);

  /// Records that the person compared [info]'s number with [peerId].
  Future<void> markVerified(String peerId, SafetyInfo info) async {
    _verified[peerId] = {
      'number': info.number,
      'peerFp': info.peerFingerprint,
      'myFp': info.myFingerprint,
      'at': _clock().toUtc().toIso8601String(),
    };
    _verifyChanged.remove(peerId);
    await _saveNotes();
  }

  /// A new session to [device] at the front of its list, newest first; the
  /// oldest beyond [maxSessionsPerDevice] go.
  void _addSession(String deviceId, OlmSession session) {
    final list = _sessions[deviceId] ??= [];
    list.insert(0, session);
    if (list.length > maxSessionsPerDevice) {
      list.removeRange(maxSessionsPerDevice, list.length);
    }
  }

  /// Puts the session that just worked first, so sending uses it.
  void _promote(String deviceId, OlmSession session) {
    final list = _sessions[deviceId];
    if (list == null || list.isEmpty || identical(list.first, session)) return;
    if (list.remove(session)) list.insert(0, session);
  }

  /// The session used to send to [device]: the one that last worked, else the
  /// newest. With [fresh] (or no session at all) a new one is started from a
  /// claimed one-time key.
  Future<OlmSession> _outbound(
    String user,
    _Device device, {
    bool fresh = false,
  }) async {
    final existing = _sessions[device.id];
    if (!fresh && existing != null && existing.isNotEmpty) {
      return existing.first;
    }
    final claim = await api.claim(user, device.id);
    final key = claim['publicKey'] as String, keyId = claim['keyId'] as String;
    if (!verifySignature(
      signingKey: device.signingKey,
      message: oneTimeKeyStatement(user, device.id, keyId, key),
      signature: claim['signature'] as String,
    )) {
      throw const ChatFailure(
        'BAD_KEY',
        'Couldn’t verify a chat key. Try again.',
      );
    }
    final session = _account.createOutbound(
      identityKey: device.identityKey,
      oneTimeKey: key,
    );
    _addSession(device.id, session);
    return session;
  }

  /// Decrypts [ciphertext] from [device]. A pre-key message goes to the session
  /// it belongs to; if it belongs to none, a new session is created from it and
  /// added, and no existing session is replaced. Any other message is tried
  /// against each session, newest first. The session that worked moves to the
  /// front.
  _Opened _open(_Device device, int type, String ciphertext) {
    final list = _sessions[device.id] ??= [];
    if (type == 0) {
      for (final session in list.toList()) {
        if (!session.matchesPreKey(ciphertext: ciphertext)) continue;
        final before = session.pickle(pickleKey: _pickleKey);
        final text = session.decrypt(messageType: 0, ciphertext: ciphertext);
        final order = list.toList();
        _promote(device.id, session);
        return _Opened(
          text,
          () => _restoreSession(device.id, session, before, order),
        );
      }
      final accountBefore = _account.pickle(pickleKey: _pickleKey);
      final (session, text) = _account.createInbound(
        theirIdentityKey: device.identityKey,
        ciphertext: ciphertext,
      );
      final order = list.toList();
      _addSession(device.id, session);
      return _Opened(text, () {
        list
          ..clear()
          ..addAll(order);
        _account = OlmAccount.restore(
          pickle: accountBefore,
          pickleKey: _pickleKey,
        );
      });
    }
    Object? failure;
    for (final session in list.toList()) {
      final before = session.pickle(pickleKey: _pickleKey);
      try {
        final text = session.decrypt(messageType: type, ciphertext: ciphertext);
        final order = list.toList();
        _promote(device.id, session);
        return _Opened(
          text,
          () => _restoreSession(device.id, session, before, order),
        );
      } catch (error) {
        failure = error;
        // A failed decrypt must leave the session as it was; make sure.
        _restoreSession(device.id, session, before, list.toList());
      }
    }
    if (failure != null) throw failure;
    throw const ChatFailure('NO_SESSION', 'Sign in to continue.');
  }

  /// Puts [session] back to the state it was pickled in, at its old place.
  void _restoreSession(
    String deviceId,
    OlmSession session,
    String pickle,
    List<OlmSession> order,
  ) {
    final restored = OlmSession.restore(pickle: pickle, pickleKey: _pickleKey);
    final list = _sessions[deviceId] ??= [];
    final next = [for (final s in order) identical(s, session) ? restored : s];
    list
      ..clear()
      ..addAll(next);
  }

  Future<String> open(String peerId) async =>
      (await api.openConversation(peerId))['conversationId'] as String;

  /// Sends a text message. [replyTo] quotes a message of this conversation: a
  /// short plain snippet of that message's own text (never of what it quotes,
  /// so quotes do not nest) travels inside the encrypted payload.
  ///
  /// The message is written to the history as "sending" with its final id
  /// before anything goes over the network, so it survives a crash (it comes
  /// back as "not sent", ready for [retryText]) and a retry reuses the id, which
  /// the relay answers idempotently. If it cannot be sent the error is thrown:
  /// a transient one (offline, throttled, server trouble) leaves the message as
  /// "not sent" with a retry; a refusal (they do not accept messages, the chat
  /// is closed, a key changed) removes it, since sending it again cannot help.
  Future<void> send(
    String conversationId,
    String peerId,
    String text, {
    ChatMessage? replyTo,
  }) async {
    // The same rules the API applies to every free-text field, and NFC.
    final clean = sanitizeText(text);
    if (clean.trim().isEmpty) {
      throw const ChatFailure(
        'INVALID_TEXT',
        'That message has nothing this app can send.',
      );
    }
    final messageId = newUuid4(_random);
    final sentAt = _clock().toUtc();
    final reply = replyTo == null ? null : replyOf(replyTo, userId);
    await _append(
      conversationId,
      ChatMessage(
        messageId: messageId,
        senderId: userId,
        text: clean,
        sentAt: sentAt,
        mine: true,
        status: SendStatus.sending,
        reply: reply,
      ),
    );
    await _transmitText(conversationId, peerId, messageId);
  }

  /// Sends a text message that did not go out ("not sent"), with the same id.
  Future<void> retryText(
    String conversationId,
    String peerId,
    String messageId,
  ) async {
    final m = (await history(conversationId))
        .where(
          (m) =>
              m.messageId == messageId &&
              m.mine &&
              !m.notice &&
              !m.isPhoto &&
              m.status == SendStatus.failed,
        )
        .firstOrNull;
    if (m == null) {
      throw const ChatFailure('NOT_FOUND', 'That message can’t be sent again.');
    }
    await _log.replace(
      conversationId,
      m.copyWith(status: SendStatus.sending, clearFailure: true),
    );
    await _transmitText(conversationId, peerId, messageId);
  }

  /// Deletes a text message that was never sent.
  Future<void> discardText(String conversationId, String messageId) async {
    final m = (await history(conversationId))
        .where((m) => m.messageId == messageId)
        .firstOrNull;
    if (m == null || !m.mine || m.status == SendStatus.sent) return;
    await _log.remove(conversationId, messageId);
  }

  Future<void> _transmitText(
    String conversationId,
    String peerId,
    String messageId,
  ) async {
    final m = (await history(conversationId))
        .where((m) => m.messageId == messageId)
        .firstOrNull;
    if (m == null) return;
    // The same content on every attempt: the receiver binds it to the id. It
    // is padded to a size bucket so the relay cannot read the length off the
    // envelope (the filler differs between attempts; nothing reads it).
    final payload = encodePadded({
      'v': 1,
      'kind': 'text',
      'text': m.text,
      'messageId': messageId,
      'conversationId': conversationId,
      'senderId': userId,
      'sentAt': m.sentAt.toUtc().toIso8601String(),
      if (m.reply != null) 're': m.reply!.toJson(),
    }, _random);
    try {
      final serverAt = await _locked(
        () => _deliver(conversationId, peerId, messageId, payload, const []),
      );
      await _log.replace(
        conversationId,
        m.copyWith(
          status: SendStatus.sent,
          serverAt: serverAt ?? _clock().toUtc(),
          clearFailure: true,
        ),
      );
    } catch (error) {
      final keep = error is! ChatFailure || isTransientChatFailure(error);
      if (keep) {
        await _log.replace(
          conversationId,
          m.copyWith(
            status: SendStatus.failed,
            failure: error is ChatFailure ? error.code : 'FAILED',
          ),
        );
      } else {
        await _log.remove(conversationId, messageId);
      }
      rethrow;
    }
  }

  /// Sets (or, with a null [emoji], clears) this account's reaction to
  /// [messageId], which must be a delivered message of this conversation.
  ///
  /// The reaction shows at once; if it cannot be sent it is taken back and the
  /// failure is thrown for the screen to show. It goes through the same
  /// delivery as [send] (one envelope per device, the relay's idempotency by
  /// message id) with the relay-visible `aux` hint, so the peer's unread count,
  /// push and chat list order are untouched. A transient failure is retried a
  /// couple of times with the same id.
  Future<void> react(
    String conversationId,
    String peerId,
    String messageId,
    String? emoji,
  ) async {
    if (emoji != null && !isAllowedReaction(emoji)) {
      throw const ChatFailure('BAD_REACTION', 'That reaction isn’t available.');
    }
    final target = (await history(conversationId))
        .where((m) => m.messageId == messageId && !m.notice)
        .firstOrNull;
    if (target == null || target.status != SendStatus.sent) {
      throw const ChatFailure(
        'NOT_FOUND',
        'You can react once the message has been delivered.',
      );
    }
    final previous = target.reactionStates[userId];
    final current = previous?.emoji;
    if (emoji == current) return;
    // Removal names the emoji being removed (the receiver validates it too).
    final named = emoji ?? current!;
    var at = _clock().toUtc();
    // Two quick taps in one millisecond must still order: later wins.
    if (previous != null && !at.isAfter(previous.at)) {
      at = previous.at.add(const Duration(milliseconds: 1));
    }
    final id = newUuid4(_random);
    final state = ReactionState(emoji: emoji, at: at, id: id);
    final payload = jsonEncode({
      'v': 1,
      'kind': 'reaction',
      'text': '',
      'to': messageId,
      'emoji': named,
      'op': emoji == null ? 'remove' : 'add',
      'messageId': id,
      'conversationId': conversationId,
      'senderId': userId,
      'sentAt': at.toIso8601String(),
    });
    await _log.applyReaction(
      conversationId,
      ReactionEvent(target: messageId, sender: userId, state: state),
    );
    try {
      for (var attempt = 0; ; attempt++) {
        try {
          await _locked(
            () => _deliver(
              conversationId,
              peerId,
              id,
              payload,
              const [],
              aux: true,
            ),
          );
          return;
        } catch (error) {
          if (attempt >= reactionRetryDelays.length ||
              !isTransientChatFailure(error) ||
              (error is ChatFailure &&
                  (error.retryAfter ?? Duration.zero) >
                      const Duration(seconds: 3))) {
            rethrow;
          }
          await Future<void>.delayed(reactionRetryDelays[attempt]);
        }
      }
    } catch (_) {
      await _log.revertReaction(
        conversationId,
        messageId,
        userId,
        sent: state,
        previous: previous,
      );
      rethrow;
    }
  }

  /// Seals [payload] for every device of both people and hands it to the
  /// relay. Must run inside [_locked]: it advances the Olm ratchets. Devices
  /// named in [fresh] get a brand-new session (see [_unwedge]).
  Future<DateTime?> _deliver(
    String conversationId,
    String peerId,
    String messageId,
    String payload,
    List<String> blobIds, {
    bool aux = false,
    Set<String> fresh = const {},
  }) async {
    final startFresh = {...fresh};
    for (var attempt = 0; ; attempt++) {
      final peerDevices = await _devices(
        peerId,
        conversationId: conversationId,
      );
      // Nobody to encrypt for: every device of theirs was signed out as idle (or none was ever registered).
      // The relay says the same (`PEER_NO_DEVICES`); asking it with an empty envelope list would only be refused.
      if (peerDevices.isEmpty) {
        throw const ChatFailure(
          'PEER_NO_DEVICES',
          'They haven’t opened Hiyall in a while. Your message can’t be delivered yet.',
          409,
        );
      }
      final targets = [
        for (final d in peerDevices) (peerId, d),
        for (final d in await _devices(userId))
          if (d.id != deviceId) (userId, d),
      ];
      final envelopes = <Map<String, dynamic>>[];
      for (final (user, device) in targets) {
        final sealed = (await _outbound(
          user,
          device,
          fresh: startFresh.remove(device.id),
        )).encrypt(plaintext: payload);
        envelopes.add({
          'deviceId': device.id,
          'type': sealed.messageType,
          'ciphertext': sealed.ciphertext,
        });
      }
      await _saveState();
      try {
        return await api.send(
          conversationId,
          {
            'messageId': messageId,
            'senderDeviceId': deviceId,
            'envelopes': envelopes,
          },
          blobIds: blobIds,
          aux: aux,
        );
      } on ChatFailure catch (failure) {
        if (failure.code != 'DEVICES_CHANGED' || attempt > 0) rethrow;
      }
    }
  }

  /// A peer device's messages stopped decrypting (its session with us and ours
  /// with it no longer match). Start a fresh session to that device and send a
  /// quiet empty message ("noop", flagged as auxiliary so it is not unread and
  /// not pushed) on it, so the peer builds a matching one. At most once per
  /// device per [unwedgeEvery]. Runs inside [_locked]; never throws.
  Future<void> _unwedge(
    String conversationId,
    String senderId,
    _Device device,
  ) async {
    final now = _clock().toUtc();
    final last = _unwedged[device.id];
    if (last != null && now.difference(last) < unwedgeEvery) return;
    _unwedged[device.id] = now;
    try {
      await _saveNotes();
      var peer = senderId;
      if (senderId == userId) {
        final c = await api.conversation(conversationId);
        peer = (c['peer'] as Map)['userId'] as String;
      }
      final id = newUuid4(_random);
      await _deliver(
        conversationId,
        peer,
        id,
        jsonEncode({
          'v': 1,
          'kind': 'noop',
          'text': '',
          'messageId': id,
          'conversationId': conversationId,
          'senderId': userId,
          'sentAt': now.toIso8601String(),
        }),
        const [],
        aux: true,
        fresh: {device.id},
      );
    } catch (_) {
      // Quiet by design; the next failure after the interval tries again.
    }
  }

  PhotoOutbox get _photos {
    final outbox = _outbox;
    if (outbox == null) {
      throw const ChatFailure(
        'PHOTOS_UNAVAILABLE',
        'Photos can only be sent from the Hiyall app on a phone.',
      );
    }
    return outbox;
  }

  /// Prepares, encrypts and sends [input] (a picked JPEG, PNG or WebP). The
  /// message shows at once as sending; the upload continues in the
  /// background, and a failure leaves it failed, ready for [retryPhoto].
  Future<ChatMessage> sendPhoto(
    String conversationId,
    String peerId,
    Uint8List input, {
    String caption = '',
    ChatMessage? replyTo,
  }) => _photos.enqueue(
    conversationId,
    peerId,
    input,
    caption: caption,
    replyTo: replyTo,
  );

  Future<void> retryPhoto(String conversationId, String messageId) =>
      _photos.retry(conversationId, messageId);
  void cancelPhoto(String messageId) => _outbox?.cancel(messageId);

  /// Deletes an unsent photo and its message.
  Future<void> discardPhoto(String conversationId, String messageId) =>
      _photos.discard(conversationId, messageId);
  TransferProgress? photoProgress(String messageId) =>
      _outbox?.progress(messageId);

  /// The thumbnail of a photo sent in this session, so it appears at once.
  Uint8List? localThumb(String messageId) => _outbox?.localThumb(messageId);

  /// Removes every photo file and unsent upload of this account from the
  /// device; called on sign-out.
  Future<void> wipeMedia() async {
    await _outbox?.wipe();
    await _media?.cache.wipe();
  }

  /// Fetches, verifies and decrypts pending envelopes, then acknowledges them.
  Future<void> pollNow() => _locked(() async {
    if (!_started) return;
    _leftBehind = false;
    var drained = false;
    // Drain a backlog page by page, bounded so one call never runs unchecked.
    for (var page = 0; page < 10; page++) {
      if (await _pollPage() < 100) {
        drained = true;
        break;
      }
    }
    // Only with nothing left waiting: a message made for the old fallback key
    // must be opened before that key is forgotten.
    if (drained && !_leftBehind && !_awaitingRegistration) {
      await _maintainFallback();
    }
  });

  /// This device is gone from the relay (the inbox answered 404). Registers it again, with the same keys first:
  /// a device the relay removed only for not being used (35 days, or one sender's messages filling it while it
  /// sat idle) is taken back as the same device, so nothing about its identity changes for anyone (CHAT-N1). A
  /// device somebody removed is refused (`DEVICE_CONFLICT`); then, and only then, the identity is replaced and
  /// the person is told. Returns whether the device is registered now.
  ///
  /// When it cannot be registered (the account holds ten devices, the relay is unreachable) nothing is touched
  /// and the next attempt waits longer, up to the last of [reregisterDelays]: this phone's saved state is not
  /// rewritten again and again, and the relay is not asked every poll (audit CHAT-N5). A failure is thrown the
  /// first time and quietly skipped while waiting.
  Future<bool> _recoverRemoved() async {
    final notBefore = _reregisterNotBefore;
    if (notBefore != null && _clock().isBefore(notBefore)) {
      _awaitingRegistration = true;
      return false;
    }
    try {
      try {
        await _register();
      } on ChatFailure catch (failure) {
        if (failure.code != 'DEVICE_CONFLICT') rethrow;
        await _resetIdentity(because: DeviceNoticeKind.reset);
        await _loadIdentity();
        await _register();
      }
    } catch (_) {
      _awaitingRegistration = true;
      if (reregisterDelays.isNotEmpty) {
        _reregisterNotBefore = _clock().add(
          reregisterDelays[min(
            _reregisterFailures,
            reregisterDelays.length - 1,
          )],
        );
      }
      _reregisterFailures++;
      rethrow;
    }
    _reregisterFailures = 0;
    _reregisterNotBefore = null;
    _awaitingRegistration = false;
    try {
      onReregistered?.call();
    } catch (_) {}
    return true;
  }

  /// One page of the inbox. For each message the order is: decrypt (in memory),
  /// then write the history (and any waiting reactions) and the account and
  /// sessions as ONE commit of the encrypted snapshot (see [ChatHistory.transaction]
  /// and docs/security/13), and only then acknowledge. A crash or a failed
  /// commit before the acknowledgement leaves the message on the relay and
  /// the saved ratchet and history where they were, so it is delivered and
  /// decrypted again. The ratchet is rolled back in memory on a failure.
  Future<int> _pollPage() async {
    final List<Map<String, dynamic>> items;
    try {
      items = await api.inbox(deviceId);
    } on ChatFailure catch (failure) {
      // The relay no longer has this device: it was removed. See [_recoverRemoved].
      if (failure.status == 404 && failure.code == 'NOT_FOUND') {
        if (!await _recoverRemoved()) return 0;
        try {
          // The account's other devices, compared with the pins this phone kept: whatever appeared while
          // it was away is announced now.
          await _devices(userId);
          await _noticeRemoved();
        } catch (_) {}
        return 0;
      }
      rethrow;
    }
    final delivered = <String>[];
    // A one-time key is only used up by a message that starts a session (a pre-key message), so the relay's
    // key count only needs a look after one arrived.
    var sawPreKey = false;
    // Each sender's devices are fetched once per page. A failure here is kept
    // per sender so it never turns into a decryption error for every message.
    final senders = <String, Future<List<_Device>>>{};
    try {
      for (final item in items) {
        final conversationId = item['conversationId'] as String;
        final senderId = item['senderId'] as String;
        final messageId = item['messageId'] as String;
        if (item['type'] == 0) sawPreKey = true;
        final devices = senders[senderId] ??= _devices(
          senderId,
          conversationId: conversationId,
        );
        try {
          await devices;
        } catch (error) {
          // Offline, throttled or a server fault: leave the envelope on the
          // relay for the next poll instead of discarding it as unreadable.
          if (isTransientChatFailure(error)) rethrow;
        }
        // Already handled (the acknowledgement was lost after the history and
        // the ratchet were saved): do not open it again, just acknowledge.
        if (_processed.contains(messageId) ||
            (await history(conversationId))
                .any((m) => m.messageId == messageId)) {
          delivered.add(messageId);
          continue;
        }
        Future<void> undecryptable() => _append(
          conversationId,
          ChatMessage(
            messageId: messageId,
            senderId: senderId,
            text: 'This message couldn’t be decrypted on this device.',
            sentAt: DateTime.now().toUtc(),
            mine: senderId == userId,
            notice: true,
          ),
        );
        _Device? device;
        try {
          final senderDevice = item['senderDeviceId'] as String;
          device = (await devices)
              .where((d) => d.id == senderDevice)
              .firstOrNull;
          if (device == null ||
              device.identityKey != item['senderIdentityKey']) {
            throw const ChatFailure(
              'UNKNOWN_DEVICE',
              'Sent from an unverified device.',
            );
          }
        } catch (_) {
          await undecryptable();
          delivered.add(messageId);
          continue;
        }
        final _Opened opened;
        try {
          opened = _open(
            device,
            item['type'] as int,
            item['ciphertext'] as String,
          );
        } catch (_) {
          await undecryptable();
          delivered.add(messageId);
          await _unwedge(conversationId, senderId, device);
          continue;
        }
        Incoming incoming;
        try {
          final Set<String>? members;
          try {
            members = await _quoteMembers(conversationId, senderId);
          } catch (_) {
            opened.undo();
            _leftBehind = true;
            continue; // history unreadable: left on the relay
          }
          incoming = parseIncoming(
            jsonDecode(opened.plaintext) as Map<String, dynamic>,
            messageId: messageId,
            conversationId: conversationId,
            senderId: senderId,
            serverAt: DateTime.tryParse(item['createdAt'] as String? ?? ''),
            me: userId,
            members: members,
            aux: item['aux'] == true,
          );
        } catch (_) {
          // Decrypted, but not a message this app understands. The ratchet has
          // moved on, so keep it and say so.
          await _log.transaction(() async {
            await _saveState();
            await undecryptable();
          });
          delivered.add(messageId);
          continue;
        }
        try {
          // The message (or reaction) and the ratchet that opened it land
          // together or not at all.
          await _log.transaction(() async {
            await _ingest(conversationId, incoming);
            await _saveState();
          });
        } catch (_) {
          opened.undo();
          _leftBehind = true;
          continue; // not acknowledged: delivered again
        }
        _processed.add(messageId);
        if (_processed.length > 400) _processed.remove(_processed.first);
        delivered.add(messageId);
      }
    } finally {
      // Whatever was handled is acknowledged even when the page stops early,
      // since its ratchet state has already been saved.
      if (delivered.isNotEmpty) {
        await api.ack(deviceId, delivered);
        if (sawPreKey) await _replenishQuietly();
      }
    }
    return items.length;
  }

  /// Tests only: how many Olm sessions are held for a peer device.
  int debugSessionCount(String deviceId) => _sessions[deviceId]?.length ?? 0;

  /// Tests only: the session ids held for a peer device, in sending order.
  List<String> debugSessionIds(String deviceId) => [
    for (final s in _sessions[deviceId] ?? const <OlmSession>[]) s.sessionId(),
  ];

  /// Tests only: lets [pollNow] run without the native encryption core. Only
  /// paths that never reach Olm may be exercised this way. (No Flutter import,
  /// so the command-line peer keeps running under plain `dart run`.)
  void debugStartWithoutKeys(String device) {
    deviceId = device;
    _noKeys = true;
    _started = true;
  }

  /// Changes how often the inbox is checked. A live socket signals new mail,
  /// so the timer becomes a slow safety net while connected.
  void setPollInterval(Duration every) {
    if (!_started || _pollEvery == every) return;
    _pollEvery = every;
    _timer?.cancel();
    _timer = null;
    _startTimer();
  }

  void _startTimer() {
    if (_paused || _pollEvery <= Duration.zero) return;
    _timer?.cancel();
    _timer = Timer.periodic(_pollEvery, (_) => pollNow().catchError((_) {}));
  }

  /// The app went to the background: stop checking the inbox on a timer (a
  /// push or the next [resume] brings new mail). Safe to repeat.
  void pause() {
    _paused = true;
    _timer?.cancel();
    _timer = null;
  }

  /// The app is back in the foreground: start the timer again and look at
  /// the inbox at once.
  void resume() {
    if (!_paused) return;
    _paused = false;
    if (!_started) return;
    _startTimer();
    pollNow().catchError((_) {});
  }

  /// Whether the inbox timer is running (tests).
  bool get polling => _timer != null;

  final _markedRead = <String, DateTime>{};

  /// Moves the server read pointer to the newest message from the peer.
  Future<void> markRead(String conversationId) async {
    final latest = (await history(conversationId))
        .where((m) => !m.mine && !m.notice && m.serverAt != null)
        .map((m) => m.serverAt!)
        .fold<DateTime?>(null, (a, b) => a == null || b.isAfter(a) ? b : a);
    if (latest == null) return;
    final done = _markedRead[conversationId];
    if (done != null && !latest.isAfter(done)) return;
    await api.markRead(conversationId, latest);
    _markedRead[conversationId] = latest;
  }

  /// A 60-digit number both people can compare in person. It covers every
  /// device on both accounts as the relay lists them now, each checked
  /// against the keys pinned on first contact, so a substituted or added
  /// device changes it. Reading it pins nothing: see [safetyInfo].
  Future<String> safetyNumber(String peerId) async =>
      (await safetyInfo(peerId)).number;

  /// The safety number with what the person should see first: whether the
  /// keys changed since they verified, and whether the peer has devices this
  /// phone has not pinned yet. It never pins anything (a device is pinned, with
  /// a notice in the chat, when a message is next sent); a device that
  /// presents other keys than the ones pinned stops it with `KEY_CHANGED`.
  Future<SafetyInfo> safetyInfo(String peerId) => _locked(() async {
    final mineNow = await _fetchDevices(userId);
    final theirsNow = await _fetchDevices(peerId);
    final mine = [
      _account.identityKey(),
      for (final d in mineNow.list)
        if (d.id != deviceId) d.identityKey,
    ];
    final theirs = [for (final d in theirsNow.list) d.identityKey];
    final number = computeSafetyNumber(userId, mine, peerId, theirs);
    final myFp = _fingerprint(userId, mineNow.list);
    final peerFp = _fingerprint(peerId, theirsNow.list);
    // Seeing a change clears the mark, whichever screen sees it first.
    await _checkVerified(userId, mineNow.list);
    await _checkVerified(peerId, theirsNow.list);
    final entry = _verified[peerId];
    final verified = entry != null && entry['number'] == number;
    return SafetyInfo(
      number: number,
      verified: verified,
      changedSinceVerified: !verified && _verifyChanged.contains(peerId),
      newDevices: theirsNow.unpinned.length,
      peerFingerprint: peerFp,
      myFingerprint: myFp,
    );
  });

  /// This account's devices as the server lists them, newest first.
  Future<List<Map<String, dynamic>>> myDevices() async =>
      (await api.myDevices()).reversed.toList();

  Future<void> revokeDevice(String id) async {
    if (id == deviceId) {
      throw const ChatFailure('THIS_DEVICE', 'Sign out to remove this phone.');
    }
    await api.revokeDevice(id);
    // Removed by this person from this phone: not something to announce later as a removal.
    await _locked(() async {
      final pins = _trust[userId];
      if (pins != null && pins.remove(id) != null) {
        await _store.write(_k('trust'), jsonEncode(_trust));
      }
    });
  }

  /// Removes this phone's chat device on the server (sign-out). The local
  /// copy of the id goes too, so nothing retries it.
  Future<void> revokeThisDevice() async {
    await api.revokeDevice(deviceId);
    try {
      await _store.delete(_k('deviceId'));
    } on ChatStoreClosed {
      // The account was wiped meanwhile, id included.
    }
  }

  Future<List<ChatMessage>> history(String conversationId) =>
      _log.read(conversationId);

  Future<void> _append(String conversationId, ChatMessage message) =>
      _log.append(conversationId, message);

  /// Files one decrypted payload: a message joins the history (its quote
  /// corrected from the local original when there is one), a reaction updates
  /// the message it is for (or waits for it), and anything else is dropped.
  Future<void> _ingest(String conversationId, Incoming incoming) async {
    switch (incoming) {
      case IncomingMessage(:final message):
        var reply = message.reply;
        if (reply != null) {
          final original = (await history(conversationId))
              .where((m) => m.messageId == reply!.id && !m.notice)
              .firstOrNull;
          if (original != null) reply = resolveReply(reply, original, userId);
        }
        await _append(
          conversationId,
          reply == message.reply ? message : message.copyWith(reply: reply),
        );
      case IncomingReaction(:final event):
        await _log.applyReaction(conversationId, event);
      case IncomingIgnored():
        break;
    }
  }

  /// The two accounts a quote may name as its author. The sender and this
  /// account are always members; the other one is learnt from history. When a
  /// message from this account's other device arrives before anything from the
  /// peer is known, `by` is only shape-checked.
  Future<Set<String>?> _quoteMembers(
    String conversationId,
    String senderId,
  ) async {
    final members = {userId, senderId};
    if (senderId != userId) return members;
    for (final m in await history(conversationId)) {
      if (!m.mine && !m.notice) {
        members.add(m.senderId);
        return members;
      }
    }
    return null;
  }

  /// When the peer last read this conversation, if both share receipts.
  Future<DateTime?> peerReadAt(String conversationId) async =>
      DateTime.tryParse(
        (await api.conversation(conversationId))['peerReadAt'] as String? ?? '',
      );

  /// Most recent first. Only the returned chats' local history is read.
  Future<List<ChatConversation>> conversations({int limit = 50}) async => [
    for (final c in await api.conversations(limit: limit))
      ChatConversation(
        c['conversationId'] as String,
        (c['peer'] as Map)['userId'] as String,
        (c['peer'] as Map)['displayName'] as String,
        (c['peer'] as Map)['username'] as String,
        (await history(c['conversationId'] as String)).lastOrNull,
        peerAvatarUrl: (c['peer'] as Map)['avatarUrl'] as String?,
        unreadCount: c['unreadCount'] as int? ?? 0,
        peerReadAt: DateTime.tryParse(c['peerReadAt'] as String? ?? ''),
        mutedUntil: DateTime.tryParse(c['mutedUntil'] as String? ?? ''),
        sharedInterests: parseSharedInterests(c['sharedInterests']),
        online: parsePresence(c['peer']).online,
        lastSeenAt: parsePresence(c['peer']).lastSeenAt,
      ),
  ];
}

/// What a decrypted payload turned out to be.
sealed class Incoming {
  const Incoming();
}

/// A text or photo message, to be added to the history.
class IncomingMessage extends Incoming {
  final ChatMessage message;
  const IncomingMessage(this.message);
}

/// A reaction to a message, to be applied to it.
class IncomingReaction extends Incoming {
  final ReactionEvent event;
  const IncomingReaction(this.event);
}

/// A reaction that did not pass validation, or a kind this app does not know
/// (sent by a newer app): dropped without a bubble, a notice or an error.
class IncomingIgnored extends Incoming {
  const IncomingIgnored();
}

/// A message's quote of itself: the reference a reply to [m] carries. Null for
/// local notices and anything without a message id the other side could find.
/// The snippet is of [m]'s own text or caption, never of what [m] quotes.
ChatReply? replyOf(ChatMessage m, String me) {
  if (m.notice || !isCanonicalUuid(m.messageId)) return null;
  final photo = m.isPhoto;
  return ChatReply(
    id: m.messageId,
    by: m.mine ? me : m.senderId,
    snippet: snippetOf(photo ? (m.attachment?.caption ?? '') : m.text),
    kind: photo ? 'image' : 'text',
  );
}

/// [reply] with the author, text and kind of [original], which is in this
/// device's history and so is what the person sees, whatever the sender wrote.
ChatReply resolveReply(ChatReply reply, ChatMessage original, String me) {
  final quoted = replyOf(original, me);
  return quoted == null
      ? reply
      : reply.resolved(
          by: quoted.by,
          snippet: quoted.snippet,
          kind: quoted.kind,
        );
}

/// Turns a decrypted payload into what it is, after binding it to the relay's
/// metadata so the server cannot replay a ciphertext into another conversation
/// or as another sender (a mismatch throws, as it always has). Kinds:
///
/// * `text` (and a payload with no kind, as the first builds wrote them), and
///   `image`, whose descriptor is checked strictly (a bad one still shows, as a
///   photo this app cannot open). Both may carry a quote, `re`, validated by
///   [ChatReply.parse]; a bad one is dropped and the message shows without it.
/// * `reaction`: `to` a message id, an `emoji` from the allow-list and `op`
///   `add` or `remove`. Anything else about it is invalid and it is ignored.
///   A reaction dated more than ten minutes after the relay stored it is
///   ignored too, so nobody can pin their own reaction in the future.
/// * `noop` (the quiet message that sets up a fresh session) and any other
///   kind: ignored.
///
/// [aux] is the relay's flag that the sender marked the message auxiliary. A
/// message carrying it whose kind is not `reaction` or `noop` is ignored, so
/// the hint cannot be used to deliver text or photos the first-contact cap
/// would have stopped.
Incoming parseIncoming(
  Map<String, dynamic> body, {
  required String messageId,
  required String conversationId,
  required String senderId,
  required String me,
  DateTime? serverAt,
  Set<String>? members,
  bool aux = false,
}) {
  if (body['v'] != 1 ||
      body['conversationId'] != conversationId ||
      body['senderId'] != senderId ||
      body['messageId'] != messageId ||
      body['text'] is! String ||
      !isValidPad(body['pad'])) {
    throw const ChatFailure('MISMATCH', 'That message couldn’t be read.');
  }
  final sentAt = DateTime.tryParse(body['sentAt'] as String? ?? '');
  final kind = body['kind'];
  // The relay says the sender marked this message auxiliary (quiet: not unread, not pushed). Only a reaction
  // or the noop is that; anything else carrying the mark is a message dressed up to skip the relay's
  // first-contact cap, and is dropped without a trace (re-audit CHAT-3).
  if (aux && kind != 'reaction' && kind != 'noop') {
    return const IncomingIgnored();
  }
  if (kind == 'reaction') {
    final to = body['to'], emoji = body['emoji'], op = body['op'];
    if (to is! String ||
        !isCanonicalUuid(to) ||
        !isAllowedReaction(emoji) ||
        (op != 'add' && op != 'remove') ||
        sentAt == null ||
        !isCanonicalUuid(messageId) ||
        (serverAt != null &&
            sentAt.isAfter(serverAt.add(const Duration(minutes: 10))))) {
      return const IncomingIgnored();
    }
    return IncomingReaction(
      ReactionEvent(
        target: to,
        sender: senderId,
        state: ReactionState(
          emoji: op == 'add' ? emoji as String : null,
          at: sentAt.toUtc(),
          id: messageId,
        ),
      ),
    );
  }
  if (kind != null && kind != 'text' && kind != 'image') {
    return const IncomingIgnored();
  }
  ChatAttachment? attachment;
  var unsupported = false;
  if (kind == 'image') {
    try {
      attachment = ChatAttachment.parse(body['att']);
    } on FormatException {
      unsupported = true;
    }
  }
  return IncomingMessage(
    ChatMessage(
      messageId: messageId,
      senderId: senderId,
      text: sanitizeText(body['text'] as String),
      sentAt: sentAt ?? DateTime.now().toUtc(),
      serverAt: serverAt,
      mine: senderId == me,
      attachment: attachment,
      unsupportedPhoto: unsupported,
      reply: ChatReply.parse(
        body['re'],
        members: members ?? (senderId == me ? null : {me, senderId}),
      ),
    ),
  );
}

/// Turns a decrypted payload into a message (see [parseIncoming]); throws for
/// a mismatch and for a payload that is not a message (a reaction or an
/// unknown kind), for callers that only ever expect messages.
ChatMessage messageFromBody(
  Map<String, dynamic> body, {
  required String messageId,
  required String conversationId,
  required String senderId,
  required String me,
  DateTime? serverAt,
}) {
  final incoming = parseIncoming(
    body,
    messageId: messageId,
    conversationId: conversationId,
    senderId: senderId,
    me: me,
    serverAt: serverAt,
  );
  if (incoming is IncomingMessage) return incoming.message;
  throw const ChatFailure('NOT_A_MESSAGE', 'That message couldn’t be read.');
}

/// Safety number in the style of Signal's: each side hashes its user id and
/// sorted device identity keys 5200 times with SHA-512, and the two 30-digit
/// halves are ordered by user id so both people see the same 60 digits.
String computeSafetyNumber(
  String userA,
  List<String> keysA,
  String userB,
  List<String> keysB,
) {
  String half(String user, List<String> keys) {
    final sorted = [...keys]..sort();
    final input = utf8.encode('hiyall-safety-v1\n$user\n${sorted.join('\n')}');
    var hash = sha512.convert(input).bytes;
    for (var i = 1; i < 5200; i++) {
      hash = sha512.convert([...hash, ...input]).bytes;
    }
    final out = StringBuffer();
    for (var chunk = 0; chunk < 6; chunk++) {
      var value = 0;
      for (var j = 0; j < 5; j++) {
        value = value * 256 + hash[chunk * 5 + j];
      }
      out.write((value % 100000).toString().padLeft(5, '0'));
    }
    return out.toString();
  }

  final a = half(userA, keysA), b = half(userB, keysB);
  return userA.compareTo(userB) < 0 ? a + b : b + a;
}
