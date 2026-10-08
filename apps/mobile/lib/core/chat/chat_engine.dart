import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../../src/rust/api/e2ee.dart';
import 'chat_api.dart';
import 'chat_store.dart';

/// Signed statements; byte-for-byte identical to the server's domain/chat.go.
String deviceStatement(
  String user,
  String device,
  String identity,
  String signing,
) => ['kairova-device-v1', user, device, identity, signing].join('\n');
String oneTimeKeyStatement(
  String user,
  String device,
  String keyId,
  String key,
) => ['kairova-otk-v1', user, device, keyId, key].join('\n');

class ChatMessage {
  final String messageId, senderId, text;

  /// The sender's clock, for display.
  final DateTime sentAt;

  /// The relay's clock, for read pointers and receipts. Null for local notices.
  final DateTime? serverAt;
  final bool mine, notice;
  const ChatMessage({
    required this.messageId,
    required this.senderId,
    required this.text,
    required this.sentAt,
    required this.mine,
    this.serverAt,
    this.notice = false,
  });
  Map<String, dynamic> toJson() => {
    'id': messageId,
    'from': senderId,
    'text': text,
    'at': sentAt.toIso8601String(),
    if (serverAt != null) 'srv': serverAt!.toIso8601String(),
    'mine': mine,
    'notice': notice,
  };
  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
    messageId: j['id'] as String,
    senderId: j['from'] as String,
    text: j['text'] as String,
    sentAt: DateTime.parse(j['at'] as String),
    serverAt: DateTime.tryParse(j['srv'] as String? ?? ''),
    mine: j['mine'] as bool,
    notice: j['notice'] as bool? ?? false,
  );
}

class ChatConversation {
  final String id, peerId, peerName, peerUsername;
  final ChatMessage? last;
  final int unreadCount;

  /// When the peer last read, on the relay's clock; null unless both people
  /// have read receipts on.
  final DateTime? peerReadAt;
  const ChatConversation(
    this.id,
    this.peerId,
    this.peerName,
    this.peerUsername,
    this.last, {
    this.unreadCount = 0,
    this.peerReadAt,
  });
}

class _Device {
  final String id, identityKey, signingKey;
  const _Device(this.id, this.identityKey, this.signingKey);
}

String _uuid4(Random random) {
  final b = List<int>.generate(16, (_) => random.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
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
  final _history = <String, List<ChatMessage>>{};
  Timer? _timer;
  bool _started = false;
  Duration _pollEvery = Duration.zero;

  ChatEngine({
    required this.userId,
    required this.api,
    required this.store,
    this.platform = 'unknown',
  });

  /// Emits a conversation id whenever its messages change.
  Stream<String> get changes => _changes.stream;
  String get identityKey => _account.identityKey();
  String _k(String name) => 'kairova.chat.$userId.$name';

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
        deviceId = await store.read(_k('deviceId')) ?? _uuid4(_random);
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
        final messageId = _uuid4(_random);
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
        DateTime? serverAt;
        for (var attempt = 0; ; attempt++) {
          final targets = [
            for (final d in await _devices(
              peerId,
              conversationId: conversationId,
            ))
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
            serverAt = await api.send(conversationId, {
              'messageId': messageId,
              'senderDeviceId': deviceId,
              'envelopes': envelopes,
            });
            break;
          } on ChatFailure catch (failure) {
            if (failure.code != 'DEVICES_CHANGED' || attempt > 0) rethrow;
          }
        }
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
    for (final item in items) {
      final conversationId = item['conversationId'] as String;
      final senderId = item['senderId'] as String;
      final messageId = item['messageId'] as String;
      try {
        final senderDevice = item['senderDeviceId'] as String;
        var device = (await _devices(
          senderId,
          conversationId: conversationId,
        )).where((d) => d.id == senderDevice).firstOrNull;
        if (device == null || device.identityKey != item['senderIdentityKey']) {
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
        // Bind the decrypted content to the relay metadata so the server cannot
        // replay a ciphertext into another conversation or as another sender.
        if (body['v'] != 1 ||
            body['conversationId'] != conversationId ||
            body['senderId'] != senderId ||
            body['messageId'] != messageId ||
            body['text'] is! String) {
          throw const ChatFailure(
            'MISMATCH',
            'Message metadata did not match.',
          );
        }
        await _append(
          conversationId,
          ChatMessage(
            messageId: messageId,
            senderId: senderId,
            text: body['text'] as String,
            sentAt:
                DateTime.tryParse(body['sentAt'] as String? ?? '') ??
                DateTime.now().toUtc(),
            serverAt: DateTime.tryParse(item['createdAt'] as String? ?? ''),
            mine: senderId == userId,
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
    if (delivered.isNotEmpty) {
      await api.ack(deviceId, delivered);
      await _replenishKeys();
    }
    return items.length;
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

  Future<List<ChatMessage>> history(String conversationId) async {
    final cached = _history[conversationId];
    if (cached != null) return List.unmodifiable(cached);
    final raw = await store.read(_k('history.$conversationId'));
    final list = raw == null
        ? <ChatMessage>[]
        : [
            for (final m in jsonDecode(raw) as List)
              ChatMessage.fromJson(Map<String, dynamic>.from(m as Map)),
          ];
    _history[conversationId] = list;
    return List.unmodifiable(list);
  }

  Future<void> _append(String conversationId, ChatMessage message) async {
    final list = [...await history(conversationId)];
    if (list.any((m) => m.messageId == message.messageId)) return;
    list.add(message);
    list.sort((a, b) => a.sentAt.compareTo(b.sentAt));
    final kept = list.length > 500 ? list.sublist(list.length - 500) : list;
    _history[conversationId] = kept;
    await store.write(
      _k('history.$conversationId'),
      jsonEncode([for (final m in kept) m.toJson()]),
    );
    if (!_changes.isClosed) _changes.add(conversationId);
  }

  /// When the peer last read this conversation, if both share receipts.
  Future<DateTime?> peerReadAt(String conversationId) async =>
      DateTime.tryParse(
        (await api.conversation(conversationId))['peerReadAt'] as String? ?? '',
      );

  Future<List<ChatConversation>> conversations() async => [
    for (final c in await api.conversations())
      ChatConversation(
        c['conversationId'] as String,
        (c['peer'] as Map)['userId'] as String,
        (c['peer'] as Map)['displayName'] as String,
        (c['peer'] as Map)['username'] as String,
        (await history(c['conversationId'] as String)).lastOrNull,
        unreadCount: c['unreadCount'] as int? ?? 0,
        peerReadAt: DateTime.tryParse(c['peerReadAt'] as String? ?? ''),
      ),
  ];
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
    final input = utf8.encode('kairova-safety-v1\n$user\n${sorted.join('\n')}');
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
