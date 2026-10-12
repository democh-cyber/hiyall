import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:hiyall/core/chat/chat_api.dart';
import 'package:hiyall/core/chat/chat_attachment.dart';
import 'package:hiyall/core/chat/chat_blob_cache.dart';
import 'package:hiyall/core/chat/chat_blob_codec.dart';
import 'package:hiyall/core/chat/chat_blob_transport.dart';
import 'package:hiyall/core/chat/chat_engine.dart';
import 'package:hiyall/core/chat/chat_history.dart';
import 'package:hiyall/core/chat/chat_outbox.dart';
import 'package:hiyall/core/chat/chat_store.dart';

const conv = '00000000-0000-4000-8000-0000000000c1';
const meId = '019a4000-0000-7000-8000-000000000001';
const peerId = '019a4000-0000-7000-8000-000000000002';

/// A JPEG header that declares [w] x [h]; enough for the size checks, never
/// decoded.
Uint8List fakeJpeg(int w, int h, {int extra = 0}) => Uint8List.fromList([
  0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, //
  0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
  0xFF, 0xC0, 0x00, 0x11, 0x08, h >> 8, h & 255, w >> 8, w & 255, 0x03, //
  0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01,
  0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00,
  ...List<int>.generate(extra, (i) => i & 255),
]);

/// A deterministic stand-in for the Rust core. It binds the key, role, salt
/// (the id the real core takes as `blobId`), conversation, mime, chunk size and
/// length the way the real one does, so a test that gets one of them wrong
/// fails to decrypt. The ciphertext has the real core's exact length formula.
class FakeCodec implements ChatBlobCodec {
  int keys = 0;
  bool prepareFails = false;
  int fullW = 1536, fullH = 2048, thumbW = 240, thumbH = 320;

  /// Overrides what [prepare] returns for the full image and thumbnail.
  Uint8List? fullBytes, thumbBytes;
  final encrypted = <String>[];

  @override
  Uint8List generateKey() => Uint8List.fromList(List.filled(32, ++keys & 255));

  @override
  Future<PreparedPhoto> prepare(List<int> input) async {
    if (prepareFails) throw Exception('cannot decode');
    return PreparedPhoto(
      full: fullBytes ?? fakeJpeg(fullW, fullH, extra: 900),
      fullW: fullW,
      fullH: fullH,
      thumb: thumbBytes ?? fakeJpeg(thumbW, thumbH, extra: 80),
      thumbW: thumbW,
      thumbH: thumbH,
      preview: Uint8List.fromList(List.generate(21, (i) => i + 1)),
    );
  }

  Uint8List _stream(String context, int length) {
    final out = BytesBuilder();
    for (var counter = 0; out.length < length; counter++) {
      out.add(sha256.convert(utf8.encode('$context#$counter')).bytes);
    }
    return Uint8List.sublistView(out.takeBytes(), 0, length);
  }

  String _context(
    List<int> key,
    String role,
    String salt,
    String conversationId,
    String mime,
    int chunk,
    int plainLen,
  ) =>
      '${base64Encode(key)}|$role|$salt|$conversationId|$mime|$chunk|$plainLen';

  @override
  Future<SealedPart> encrypt({
    required List<int> key,
    required String role,
    required String salt,
    required String conversationId,
    required String mime,
    required int chunkSize,
    required List<int> plaintext,
  }) async {
    encrypted.add('$role $salt');
    final context = _context(
      key,
      role,
      salt,
      conversationId,
      mime,
      chunkSize,
      plaintext.length,
    );
    final total = ciphertextLength(plaintext.length, chunkSize);
    final padded = padme(plaintext.length);
    final body = Uint8List(padded)..setAll(0, plaintext);
    final ks = _stream(context, padded);
    for (var i = 0; i < padded; i++) {
      body[i] ^= ks[i];
    }
    final tag = sha256.convert(utf8.encode(context)).bytes.sublist(0, 16);
    final ciphertext = Uint8List(total)..setAll(0, body);
    for (var i = padded; i < total; i++) {
      ciphertext[i] = tag[(i - padded) % 16];
    }
    return SealedPart(
      ciphertext,
      Uint8List.fromList(sha256.convert(ciphertext).bytes),
      plaintext.length,
    );
  }

  @override
  Future<Uint8List> decrypt({
    required List<int> key,
    required String role,
    required String salt,
    required String conversationId,
    required String mime,
    required int chunkSize,
    required int plainLen,
    required List<int> ctSha256,
    required List<int> ciphertext,
  }) async {
    if (ciphertext.length != ciphertextLength(plainLen, chunkSize) ||
        !_same(sha256.convert(ciphertext).bytes, ctSha256)) {
      throw Exception('bad ciphertext');
    }
    final context = _context(
      key,
      role,
      salt,
      conversationId,
      mime,
      chunkSize,
      plainLen,
    );
    final padded = padme(plainLen);
    final tag = sha256.convert(utf8.encode(context)).bytes.sublist(0, 16);
    for (var i = padded; i < ciphertext.length; i++) {
      if (ciphertext[i] != tag[(i - padded) % 16]) {
        throw Exception('authentication failed');
      }
    }
    final ks = _stream(context, padded);
    final plain = Uint8List(padded);
    for (var i = 0; i < padded; i++) {
      plain[i] = ciphertext[i] ^ ks[i];
    }
    return Uint8List.sublistView(plain, 0, plainLen);
  }

  bool previewFails = false;
  @override
  Future<PreviewPixels> previewPixels(List<int> preview) async {
    if (previewFails) throw Exception('bad preview');
    return PreviewPixels(4, 4, Uint8List(64)..fillRange(0, 64, 128));
  }
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class BlobSlotRow {
  final String id, role;
  final int size;
  final String hash;
  bool deleted = false, completed = false;
  BlobSlotRow(this.id, this.role, this.size, this.hash);
}

/// The chat relay and the object store in one memory object: it answers the
/// blob API the way the real server does and, as the transport, keeps the
/// uploaded bytes. Failures are queued per operation.
class FakeCloud extends ChatApi implements ChatBlobTransport {
  FakeCloud() : super('http://127.0.0.1:1', 't');
  final slots = <String, BlobSlotRow>{};
  final objects = <String, Uint8List>{};
  final claimed = <String>{};

  /// Every call in order, e.g. `slot thumb`, `upload <id>`, `complete <id>`.
  final calls = <String>[];
  final failures = <String, List<Object>>{};
  final uploadHeaders = <Map<String, String>>[];

  /// Bytes to hand out for a blob instead of what was uploaded.
  final tampered = <String, Uint8List>{};
  final expired = <String>{};
  Completer<void>? gate;
  int _n = 0;

  Iterable<BlobSlotRow> get live => slots.values.where((s) => !s.deleted);
  int count(String prefix) => calls.where((c) => c.startsWith(prefix)).length;

  void failNext(String op, Object error) => (failures[op] ??= []).add(error);

  /// Fails only the [n]th call (counting from 1) of [op].
  void failCall(String op, int n, Object error) =>
      (_failAt[op] ??= {})[n] = error;
  final _failAt = <String, Map<int, Object>>{};
  final _opCalls = <String, int>{};
  void _maybeFail(String op) {
    final n = _opCalls[op] = (_opCalls[op] ?? 0) + 1;
    final at = _failAt[op]?.remove(n);
    if (at != null) throw at;
    final queue = failures[op];
    if (queue != null && queue.isNotEmpty) throw queue.removeAt(0);
  }

  String _id() {
    final h = (++_n).toRadixString(16).padLeft(12, '0');
    return '5b6c0000-0000-4000-8000-$h';
  }

  @override
  Future<BlobSlot> createBlobSlot(
    String conversationId,
    String role,
    int sizeBytes,
    String ctSha256,
  ) async {
    calls.add('slot $role');
    _maybeFail('slot');
    final cap = role == 'full' ? maxFullCiphertext : maxThumbCiphertext;
    if (sizeBytes > cap) {
      throw const ChatFailure('TOO_LARGE', 'That file is too large', 413);
    }
    final id = _id();
    slots[id] = BlobSlotRow(id, role, sizeBytes, ctSha256);
    return BlobSlot(id, 'https://storage.invalid/chat/$id?sig=secret', {
      'Content-Type': 'application/octet-stream',
      'x-amz-checksum-sha256': ctSha256,
    }, null);
  }

  @override
  Future<void> upload(
    BlobSlot slot,
    Uint8List bytes, {
    void Function(int sent, int total)? onProgress,
    CancelToken? cancel,
  }) async {
    calls.add('upload ${slot.blobId}');
    uploadHeaders.add(slot.headers);
    final pending = gate;
    if (pending != null) {
      await Future.any([
        pending.future,
        if (cancel != null) cancel.whenCancel.then((_) {}),
      ]);
    }
    if (cancel?.isCancelled ?? false) {
      throw const ChatFailure('CANCELED', 'Canceled.');
    }
    _maybeFail('upload');
    // The object store refuses a body that is not the signed checksum.
    if (base64Encode(sha256.convert(bytes).bytes) !=
        slot.headers['x-amz-checksum-sha256']) {
      throw const ChatFailure('STORAGE_REFUSED', 'BadDigest', 400);
    }
    onProgress?.call(bytes.length ~/ 2, bytes.length);
    onProgress?.call(bytes.length, bytes.length);
    objects[slot.blobId] = bytes;
  }

  @override
  Future<void> completeBlob(String blobId) async {
    calls.add('complete $blobId');
    _maybeFail('complete');
    final s = slots[blobId];
    if (s == null || s.deleted) {
      throw const ChatFailure('BLOB_EXPIRED', 'gone', 410);
    }
    final stored = objects[blobId];
    if (stored == null) {
      throw const ChatFailure('BLOB_NOT_READY', 'Finish uploading', 409);
    }
    if (stored.length != s.size) {
      s.deleted = true;
      objects.remove(blobId);
      throw const ChatFailure('BLOB_SIZE_MISMATCH', 'size', 409);
    }
    s.completed = true;
  }

  @override
  Future<void> deleteBlob(String blobId) async {
    calls.add('delete $blobId');
    slots[blobId]?.deleted = true;
    objects.remove(blobId);
  }

  @override
  Future<({String url, int? sizeBytes})> blobDownloadUrl(
    String conversationId,
    String blobId,
  ) async {
    calls.add('url $blobId');
    _maybeFail('url');
    final s = slots[blobId];
    if (expired.contains(blobId)) {
      throw const ChatFailure('BLOB_EXPIRED', 'expired', 410);
    }
    if (s == null || s.deleted || !objects.containsKey(blobId)) {
      throw const ChatFailure('NOT_FOUND', 'not found', 404);
    }
    return (
      url: 'https://storage.invalid/get/$blobId?sig=secret',
      sizeBytes: s.size,
    );
  }

  @override
  Future<Uint8List> download(
    String url, {
    required int maxBytes,
    void Function(int received, int total)? onProgress,
    CancelToken? cancel,
  }) async {
    final id = Uri.parse(url).pathSegments.last;
    calls.add('download $id');
    _maybeFail('download');
    final bytes = tampered[id] ?? objects[id]!;
    onProgress?.call(bytes.length, bytes.length);
    return bytes;
  }

  // The rest of the relay, never reached in these tests.
  @override
  Future<void> markRead(String conversationId, DateTime upTo) async {}
  @override
  Future<Map<String, dynamic>> conversation(String id) async => {};
  @override
  Future<int> unreadMessages() async => 0;
}

/// What the relay does with a message that claims blobs, for the outbox tests:
/// the same claim rules as the server and idempotence by message id.
class FakeRelay {
  final FakeCloud cloud;
  FakeRelay(this.cloud);
  final stored = <String, Map<String, dynamic>>{};
  final blobIdsOf = <String, List<String>>{};
  final failures = <Object>[];

  /// Throws after storing, like a response lost on the way back.
  bool loseReply = false;
  int calls = 0;

  Future<DateTime?> deliver(
    String conversationId,
    String peer,
    String messageId,
    Map<String, dynamic> payload,
    List<String> blobIds,
  ) async {
    calls++;
    if (failures.isNotEmpty) throw failures.removeAt(0);
    if (!stored.containsKey(messageId)) {
      for (final id in blobIds) {
        final s = cloud.slots[id];
        if (s == null ||
            s.deleted ||
            !s.completed ||
            cloud.claimed.contains(id)) {
          throw const ChatFailure('BLOB_NOT_READY', 'Finish uploading', 409);
        }
      }
      cloud.claimed.addAll(blobIds);
      stored[messageId] = payload;
      blobIdsOf[messageId] = blobIds;
      if (loseReply) {
        loseReply = false;
        throw const ChatFailure('NETWORK', 'offline');
      }
    }
    return DateTime.utc(2026, 10, 12, 9);
  }
}

/// An outbox over memory and a temp folder. [restart] builds a second one over
/// the same store and folder, as after the app was closed.
class Harness {
  final cloud = FakeCloud();
  final codec = FakeCodec();
  final store = MemoryChatStore();
  late final Directory root;
  late final FakeRelay relay;
  late ChatHistory history;
  late PhotoOutbox outbox;
  late ChatBlobCache cache;

  Harness() {
    relay = FakeRelay(cloud);
    root = Directory.systemTemp.createTempSync('hiyall_chat_test');
    _build();
  }

  void _build() {
    history = ChatHistory(store, (id) => 'history.$id');
    cache = ChatBlobCache(Directory('${root.path}/chat_blobs'));
    outbox = PhotoOutbox(
      userId: meId,
      api: cloud,
      transport: cloud,
      codec: codec,
      store: store,
      history: history,
      cache: cache,
      dir: Directory('${root.path}/chat_outbox'),
      storeKey: 'outbox',
      deliver: relay.deliver,
    );
  }

  /// The app closing and opening again.
  void restart() {
    outbox.dispose();
    _build();
  }

  Directory get outboxDir => Directory('${root.path}/chat_outbox');

  Future<ChatMessage> messageOf(String id) async =>
      (await history.read(conv)).firstWhere((m) => m.messageId == id);

  Future<void> dispose() async {
    outbox.dispose();
    if (root.existsSync()) await root.delete(recursive: true);
  }
}

/// A transport that forwards to a [FakeCloud]; tests subclass it to observe or
/// change one call.
class FakeCloudProxy implements ChatBlobTransport {
  final FakeCloud inner;
  FakeCloudProxy(this.inner);
  @override
  Future<void> upload(
    BlobSlot slot,
    Uint8List bytes, {
    void Function(int sent, int total)? onProgress,
    CancelToken? cancel,
  }) => inner.upload(slot, bytes, onProgress: onProgress, cancel: cancel);
  @override
  Future<Uint8List> download(
    String url, {
    required int maxBytes,
    void Function(int received, int total)? onProgress,
    CancelToken? cancel,
  }) => inner.download(
    url,
    maxBytes: maxBytes,
    onProgress: onProgress,
    cancel: cancel,
  );
}

const fullId = '5b6c0000-0000-4000-8000-000000000001';
const thumbId = '5b6c0000-0000-4000-8000-000000000002';
const saltId = '5b6c0000-0000-4000-8000-000000000003';

Map<String, dynamic> descriptor() => {
  'v': 1,
  'key': base64Encode(List.generate(32, (i) => i)),
  'salt': saltId,
  'mime': 'image/jpeg',
  'w': 1536,
  'h': 2048,
  'chunk': 65536,
  'plainLen': 1000,
  'ctSize': ciphertextLength(1000, 65536),
  'ctSha256': base64Encode(List.filled(32, 7)),
  'blobs': {'full': fullId},
  'thumb': {
    'blob': thumbId,
    'w': 240,
    'h': 320,
    'plainLen': 100,
    'ctSize': ciphertextLength(100, 65536),
    'ctSha256': base64Encode(List.filled(32, 9)),
  },
  'preview': {'t': 'thumbhash', 'd': base64Encode(List.filled(21, 3))},
  'caption': 'hello',
};
