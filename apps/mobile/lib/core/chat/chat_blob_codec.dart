import 'dart:typed_data';

import '../../src/rust/api/blob.dart' as rust;

/// A photo ready to send: re-encoded JPEGs without metadata, and a tiny preview.
class PreparedPhoto {
  final Uint8List full, thumb, preview;
  final int fullW, fullH, thumbW, thumbH;
  const PreparedPhoto({
    required this.full,
    required this.fullW,
    required this.fullH,
    required this.thumb,
    required this.thumbW,
    required this.thumbH,
    required this.preview,
  });
}

class SealedPart {
  final Uint8List ciphertext;

  /// Raw SHA-256 of [ciphertext].
  final Uint8List ctSha256;
  final int plainLen;
  const SealedPart(this.ciphertext, this.ctSha256, this.plainLen);
}

class PreviewPixels {
  final int w, h;

  /// `w * h * 4` straight RGBA bytes.
  final Uint8List rgba;
  const PreviewPixels(this.w, this.h, this.rgba);
}

/// Everything the chat does with photos that needs the native Rust core. It
/// sits behind this interface so tests can run without the compiled library.
abstract class ChatBlobCodec {
  Uint8List generateKey();
  Future<PreparedPhoto> prepare(List<int> input);
  Future<SealedPart> encrypt({
    required List<int> key,
    required String role,
    required String salt,
    required String conversationId,
    required String mime,
    required int chunkSize,
    required List<int> plaintext,
  });
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
  });
  Future<PreviewPixels> previewPixels(List<int> preview);
}

/// The real codec: flutter_rust_bridge calls into `rust/src/api/blob.rs`.
class RustChatBlobCodec implements ChatBlobCodec {
  const RustChatBlobCodec();
  @override
  Uint8List generateKey() => rust.generateBlobKey();

  @override
  Future<PreparedPhoto> prepare(List<int> input) async {
    final p = await rust.prepareChatImage(input: input);
    return PreparedPhoto(
      full: p.full,
      fullW: p.fullW,
      fullH: p.fullH,
      thumb: p.thumb,
      thumbW: p.thumbW,
      thumbH: p.thumbH,
      preview: p.preview,
    );
  }

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
    final s = await rust.encryptBlob(
      key: key,
      role: role,
      blobId: salt,
      conversationId: conversationId,
      mime: mime,
      chunkSize: chunkSize,
      plaintext: plaintext,
    );
    return SealedPart(s.ciphertext, s.ctSha256, s.plainLen);
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
  }) => rust.decryptBlob(
    key: key,
    role: role,
    blobId: salt,
    conversationId: conversationId,
    mime: mime,
    chunkSize: chunkSize,
    plainLen: plainLen,
    ctSha256: ctSha256,
    ciphertext: ciphertext,
  );

  @override
  Future<PreviewPixels> previewPixels(List<int> preview) async {
    final p = await rust.previewToRgba(preview: preview);
    return PreviewPixels(p.w, p.h, p.rgba);
  }
}
