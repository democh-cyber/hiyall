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
import 'chat_media.dart';
import 'chat_outbox.dart';
import 'chat_store.dart';

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

  /// The sender's clock, for display.
  final DateTime sentAt;

  /// The relay's clock, for read pointers and receipts. Null for local notices.
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
  });

  bool get isPhoto => attachment != null || unsupportedPhoto;

  /// One line for the chat list.
  String get preview => attachment != null
      ? (attachment!.caption.isEmpty ? 'Photo' : attachment!.caption)
      : unsupportedPhoto
      ? 'Photo'
      : text;

  ChatMessage copyWith({
    SendStatus? status,
    String? failure,
    bool clearFailure = false,
  }) => ChatMessage(
    messageId: messageId,
    senderId: senderId,
    text: text,
    sentAt: sentAt,
    mine: mine,
    serverAt: serverAt,
    notice: notice,
    attachment: attachment,
    unsupportedPhoto: unsupportedPhoto,
    status: status ?? this.status,
    failure: clearFailure ? null : failure ?? this.failure,
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
      text: j['text'] as String,
      sentAt: DateTime.parse(j['at'] as String),
      serverAt: DateTime.tryParse(j['srv'] as String? ?? ''),
      mine: j['mine'] as bool,
      notice: j['notice'] as bool? ?? false,
      attachment: attachment,
      unsupportedPhoto: unsupported,
      status: SendStatus.values.asNameMap()[j['st']] ?? SendStatus.sent,
      failure: j['err'] as String?,
    );
  }
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

class _Device {
  final String id, identityKey, signingKey;
  const _Device(this.id, this.identityKey, this.signingKey);
}

/// One device's end-to-end encrypted chat client. All Olm operations are
/// serialized, and ratchet state is persisted before ciphertext leaves the
/// device or a delivery is acknowledged, so message keys are never reused.
class ChatEngine {
  final String userId, platform;
  final ChatApi api;
  final ChatStore store;
  final _random = Random.secure();
  final _changes = StreamController<String>.broadcast();
  Future<void> _queue = Future.value();
  late List<int> _pickleKey;
  late OlmAccount _account;
  late String deviceId;
  final _sessions = <String, OlmSession>{};
  Map<String, Map<String, dynamic>> _trust = {};
  late final ChatHistory _log;
  Timer? _timer;
  bool _started = false;
  Duration _pollEvery = Duration.zero;

  /// Photos: the codec and transport behind the native core and object
  /// storage, and the app's private folder for the outbox and the ciphertext
  /// cache. Without a folder the engine handles text only.
  final ChatBlobCodec? codec;
  final ChatBlobTransport? transport;
  final Directory? mediaRoot;
  final int cacheLimit;
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
    ChatMedia? media,
  }) {
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
      store,
      (id) => _k('history.$id'),
      onChange: (id) {
        if (!_changes.isClosed) _changes.add(id);
      },
      onDropped: (dropped) {
        final ids = [
          for (final m in dropped)
            if (m.attachment != null) ...[
              ?m.attachment!.full.blobId,
              ?m.attachment!.thumb.blobId,
            ],
        ];
        if (ids.isNotEmpty) unawaited(cache?.deleteAll(ids));
      },
    );
    if (root != null) {
      _outbox = PhotoOutbox(
        userId: userId,
        api: api,
        transport: blobTransport,
        codec: blobCodec,
        store: store,
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

  /// Removes one account's photo cache and unsent uploads without an engine
  /// (sign-out: the engine for that account no longer exists).
  static Future<void> wipeLocalMedia({
    required Directory root,
    required ChatStore store,
    required String userId,
  }) async {
    await store.delete('hiyall.chat.$userId.outbox');
    for (final name in ['chat_blobs', 'chat_outbox']) {
      try {
        final dir = Directory('${root.path}/$name');
        if (await dir.exists()) await dir.delete(recursive: true);
      } on FileSystemException {
        // Best effort.
      }
    }
  }

  /// Emits a conversation id whenever its messages change.
  Stream<String> get changes => _changes.stream;
  String get identityKey => _account.identityKey();
  String _k(String name) => 'hiyall.chat.$userId.$name';

  Future<T> _locked<T>(Future<T> Function() work) {
    final result = _queue.then((_) => work());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<void> start({Duration poll = const Duration(seconds: 2)}) =>
      _locked(() async {
        if (_started) return;
        final savedKey = await store.read(_k('pickleKey'));
        _pickleKey = savedKey == null
            ? List<int>.generate(32, (_) => _random.nextInt(256))
            : base64Decode(savedKey);
        if (savedKey == null) {
          await store.write(_k('pickleKey'), base64Encode(_pickleKey));
        }
        final savedAccount = await store.read(_k('account'));
        _account = savedAccount == null
            ? OlmAccount.create()
            : OlmAccount.restore(pickle: savedAccount, pickleKey: _pickleKey);
        deviceId = await store.read(_k('deviceId')) ?? newUuid4(_random);
        await _saveAccount();
        await store.write(_k('deviceId'), deviceId);
        final sessions = await store.read(_k('sessions'));
        if (sessions != null) {
          (jsonDecode(sessions) as Map).forEach((device, pickle) {
            _sessions[device as String] = OlmSession.restore(
              pickle: pickle as String,
              pickleKey: _pickleKey,
            );
          });
        }
        final trust = await store.read(_k('trust'));
        if (trust != null) {
          _trust = (jsonDecode(trust) as Map).map(
            (k, v) =>
                MapEntry(k as String, Map<String, dynamic>.from(v as Map)),
          );
        }
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
        await _replenishKeys();
        _started = true;
        if (poll > Duration.zero) {
          _pollEvery = poll;
          _timer = Timer.periodic(poll, (_) => pollNow().catchError((_) {}));
        }
      });

  void dispose() {
    _timer?.cancel();
    _outbox?.dispose();
    _changes.close();
  }

  Future<void> _saveAccount() =>
      store.write(_k('account'), _account.pickle(pickleKey: _pickleKey));
  Future<void> _saveSessions() => store.write(
    _k('sessions'),
    jsonEncode({
      for (final e in _sessions.entries)
        e.key: e.value.pickle(pickleKey: _pickleKey),
    }),
  );

  Future<void> _replenishKeys() async {
    if (await api.keyCount(deviceId) >= 20) return;
    final keys = _account.generateOneTimeKeys(count: 40);
    final fallback = _account.generateFallbackKey();
    Map<String, String> signed(PublicKeyEntry k) => {
      'keyId': k.keyId,
      'publicKey': k.publicKey,
      'signature': _account.sign(
        message: oneTimeKeyStatement(userId, deviceId, k.keyId, k.publicKey),
      ),
    };
    // Persist the private halves before the public halves become claimable.
    await _saveAccount();
    await api.uploadKeys(
      deviceId,
      keys.map(signed).toList(),
      fallback == null ? null : signed(fallback),
    );
    _account.markKeysAsPublished();
    await _saveAccount();
  }

  /// Fetches and verifies a user's devices. Keys are pinned on first use: a known
  /// device id presenting different keys is refused, and a new device for a known
  /// user is announced in the conversation.
  Future<List<_Device>> _devices(String user, {String? conversationId}) async {
    final known = _trust[user] ?? {};
    final firstContact = known.isEmpty;
    final result = <_Device>[];
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
        throw const ChatFailure(
          'KEY_CHANGED',
          'A device presented changed keys. Messages to it are blocked.',
        );
      }
      if (pinned == null) {
        known[id] = {'identityKey': identity, 'signingKey': signing};
        if (!firstContact && user != userId && conversationId != null) {
          await _append(
            conversationId,
            ChatMessage(
              messageId: 'notice-$id',
              senderId: user,
              text: 'A new device was added to this account.',
              sentAt: DateTime.now().toUtc(),
              mine: false,
              notice: true,
            ),
          );
        }
      }
      result.add(_Device(id, identity, signing));
    }
    _trust[user] = known;
    await store.write(_k('trust'), jsonEncode(_trust));
    return result;
  }

  Future<OlmSession> _outbound(String user, _Device device) async {
    final existing = _sessions[device.id];
    if (existing != null) return existing;
    final claim = await api.claim(user, device.id);
    final key = claim['publicKey'] as String, keyId = claim['keyId'] as String;
    if (!verifySignature(
      signingKey: device.signingKey,
      message: oneTimeKeyStatement(user, device.id, keyId, key),
      signature: claim['signature'] as String,
    )) {
      throw const ChatFailure('BAD_KEY', 'A device key failed verification.');
    }
    return _sessions[device.id] = _account.createOutbound(
      identityKey: device.identityKey,
      oneTimeKey: key,
    );
  }

  Future<String> open(String peerId) async =>
      (await api.openConversation(peerId))['conversationId'] as String;

  Future<void> send(String conversationId, String peerId, String text) =>
      _locked(() async {
        final messageId = newUuid4(_random);
        final sentAt = DateTime.now().toUtc();
        final payload = jsonEncode({
          'v': 1,
          'kind': 'text',
          'text': text,
          'messageId': messageId,
          'conversationId': conversationId,
          'senderId': userId,
          'sentAt': sentAt.toIso8601String(),
        });
        final serverAt = await _deliver(
          conversationId,
          peerId,
          messageId,
          payload,
          const [],
        );
        await _append(
          conversationId,
          ChatMessage(
            messageId: messageId,
            senderId: userId,
            text: text,
            sentAt: sentAt,
            serverAt: serverAt,
            mine: true,
          ),
        );
      });

  /// Seals [payload] for every device of both people and hands it to the
  /// relay. Must run inside [_locked]: it advances the Olm ratchets.
  Future<DateTime?> _deliver(
    String conversationId,
    String peerId,
    String messageId,
    String payload,
    List<String> blobIds,
  ) async {
    for (var attempt = 0; ; attempt++) {
      final targets = [
        for (final d in await _devices(peerId, conversationId: conversationId))
          (peerId, d),
        for (final d in await _devices(userId))
          if (d.id != deviceId) (userId, d),
      ];
      final envelopes = <Map<String, dynamic>>[];
      for (final (user, device) in targets) {
        final sealed = (await _outbound(
          user,
          device,
        )).encrypt(plaintext: payload);
        envelopes.add({
          'deviceId': device.id,
          'type': sealed.messageType,
          'ciphertext': sealed.ciphertext,
        });
      }
      await _saveSessions();
      try {
        return await api.send(conversationId, {
          'messageId': messageId,
          'senderDeviceId': deviceId,
          'envelopes': envelopes,
        }, blobIds: blobIds);
      } on ChatFailure catch (failure) {
        if (failure.code != 'DEVICES_CHANGED' || attempt > 0) rethrow;
      }
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
  }) => _photos.enqueue(conversationId, peerId, input, caption: caption);

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
    // Drain a backlog page by page, bounded so one call never runs unchecked.
    for (var page = 0; page < 10; page++) {
      if (await _pollPage() < 100) break;
    }
  });

  Future<int> _pollPage() async {
    final items = await api.inbox(deviceId);
    final delivered = <String>[];
    // Each sender's devices are fetched once per page. A failure here is kept
    // per sender so it never turns into a decryption error for every message.
    final senders = <String, Future<List<_Device>>>{};
    try {
      for (final item in items) {
        final conversationId = item['conversationId'] as String;
        final senderId = item['senderId'] as String;
        final messageId = item['messageId'] as String;
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
        try {
          final senderDevice = item['senderDeviceId'] as String;
          var device = (await devices)
              .where((d) => d.id == senderDevice)
              .firstOrNull;
          if (device == null ||
              device.identityKey != item['senderIdentityKey']) {
            throw const ChatFailure(
              'UNKNOWN_DEVICE',
              'Sent from an unverified device.',
            );
          }
          final type = item['type'] as int,
              ciphertext = item['ciphertext'] as String;
          final existing = _sessions[device.id];
          String plaintext;
          if (type == 0 &&
              (existing == null ||
                  !existing.matchesPreKey(ciphertext: ciphertext))) {
            final (session, opened) = _account.createInbound(
              theirIdentityKey: device.identityKey,
              ciphertext: ciphertext,
            );
            _sessions[device.id] = session;
            plaintext = opened;
            await _saveAccount();
          } else {
            if (existing == null) {
              throw const ChatFailure('NO_SESSION', 'Missing session.');
            }
            plaintext = existing.decrypt(
              messageType: type,
              ciphertext: ciphertext,
            );
          }
          await _saveSessions();
          final body = jsonDecode(plaintext) as Map<String, dynamic>;
          await _append(
            conversationId,
            messageFromBody(
              body,
              messageId: messageId,
              conversationId: conversationId,
              senderId: senderId,
              serverAt: DateTime.tryParse(item['createdAt'] as String? ?? ''),
              me: userId,
            ),
          );
        } catch (_) {
          await _append(
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
        }
        delivered.add(messageId);
      }
    } finally {
      // Whatever was handled is acknowledged even when the page stops early,
      // since its ratchet state has already moved on.
      if (delivered.isNotEmpty) {
        await api.ack(deviceId, delivered);
        await _replenishKeys();
      }
    }
    return items.length;
  }

  /// Tests only: lets [pollNow] run without the native encryption core. Only
  /// paths that never reach Olm may be exercised this way. (No Flutter import,
  /// so the command-line peer keeps running under plain `dart run`.)
  void debugStartWithoutKeys(String device) {
    deviceId = device;
    _started = true;
  }

  /// Changes how often the inbox is checked. A live socket signals new mail,
  /// so the timer becomes a slow safety net while connected.
  void setPollInterval(Duration every) {
    if (!_started || _pollEvery == every) return;
    _pollEvery = every;
    _timer?.cancel();
    _timer = Timer.periodic(every, (_) => pollNow().catchError((_) {}));
  }

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
  /// device on both accounts as the server lists them now, each checked
  /// against the keys pinned on first contact, so a substituted or added
  /// device changes it.
  Future<String> safetyNumber(String peerId) async {
    final mine = [
      _account.identityKey(),
      for (final d in await _devices(userId))
        if (d.id != deviceId) d.identityKey,
    ];
    final theirs = [for (final d in await _devices(peerId)) d.identityKey];
    return computeSafetyNumber(userId, mine, peerId, theirs);
  }

  /// This account's devices as the server lists them, newest first.
  Future<List<Map<String, dynamic>>> myDevices() async =>
      (await api.myDevices()).reversed.toList();

  Future<void> revokeDevice(String id) async {
    if (id == deviceId) {
      throw const ChatFailure('THIS_DEVICE', 'Sign out to remove this phone.');
    }
    await api.revokeDevice(id);
  }

  Future<List<ChatMessage>> history(String conversationId) =>
      _log.read(conversationId);

  Future<void> _append(String conversationId, ChatMessage message) =>
      _log.append(conversationId, message);

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

/// Turns a decrypted payload into a message, after binding it to the relay's
/// metadata so the server cannot replay a ciphertext into another conversation
/// or as another sender. A photo's descriptor is checked strictly; a bad one
/// still shows, as a photo this app cannot open.
ChatMessage messageFromBody(
  Map<String, dynamic> body, {
  required String messageId,
  required String conversationId,
  required String senderId,
  required String me,
  DateTime? serverAt,
}) {
  if (body['v'] != 1 ||
      body['conversationId'] != conversationId ||
      body['senderId'] != senderId ||
      body['messageId'] != messageId ||
      body['text'] is! String) {
    throw const ChatFailure('MISMATCH', 'Message metadata did not match.');
  }
  ChatAttachment? attachment;
  var unsupported = false;
  if (body['kind'] == 'image') {
    try {
      attachment = ChatAttachment.parse(body['att']);
    } on FormatException {
      unsupported = true;
    }
  }
  return ChatMessage(
    messageId: messageId,
    senderId: senderId,
    text: body['text'] as String,
    sentAt:
        DateTime.tryParse(body['sentAt'] as String? ?? '') ??
        DateTime.now().toUtc(),
    serverAt: serverAt,
    mine: senderId == me,
    attachment: attachment,
    unsupportedPhoto: unsupported,
  );
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
