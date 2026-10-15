import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'chat_api.dart';

/// Moves ciphertext between the device and object storage. It never talks to
/// the chat API and never sees a key; the signed URLs it is handed are
/// credentials and appear in no log or error.
abstract class ChatBlobTransport {
  /// PUTs [bytes] to the slot's URL with exactly the slot's headers.
  Future<void> upload(
    BlobSlot slot,
    Uint8List bytes, {
    void Function(int sent, int total)? onProgress,
    CancelToken? cancel,
  });

  /// GETs the object. More than [maxBytes] is refused as it arrives.
  Future<Uint8List> download(
    String url, {
    required int maxBytes,
    void Function(int received, int total)? onProgress,
    CancelToken? cancel,
  });
}

/// Dio against the storage host, with capped exponential backoff on network
/// errors and server faults (never on a refusal, which a retry cannot fix).
class DioBlobTransport implements ChatBlobTransport {
  final Dio _dio;
  final int attempts;
  final Duration firstDelay, maxDelay;
  final Future<void> Function(Duration) _wait;
  DioBlobTransport({
    Dio? dio,
    this.attempts = 4,
    this.firstDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 8),
    Future<void> Function(Duration)? wait,
  }) : _dio =
           dio ??
           Dio(
             BaseOptions(
               connectTimeout: const Duration(seconds: 15),
               sendTimeout: const Duration(minutes: 2),
               receiveTimeout: const Duration(minutes: 2),
             ),
           ),
       _wait = wait ?? Future.delayed;

  static bool _retryable(DioException e) {
    final status = e.response?.statusCode;
    if (status != null) return status >= 500 || status == 408;
    return e.type == DioExceptionType.connectionError ||
        e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.sendTimeout ||
        e.type == DioExceptionType.receiveTimeout;
  }

  /// Runs [attempt] again after a pause while the failure is a transient one.
  Future<T> _retrying<T>(
    Future<T> Function() attempt,
    CancelToken? cancel,
  ) async {
    var delay = firstDelay;
    for (var n = 1; ; n++) {
      try {
        return await attempt();
      } on DioException catch (e) {
        if (CancelToken.isCancel(e)) {
          throw const ChatFailure('CANCELED', 'Canceled.');
        }
        if (!_retryable(e) || n >= attempts) {
          final status = e.response?.statusCode;
          throw ChatFailure(
            status == null ? 'NETWORK' : 'STORAGE_REFUSED',
            status == null
                ? 'Could not reach the chat service. Check your connection.'
                : 'The photo storage refused the transfer.',
            status,
          );
        }
        await _wait(delay);
        if (cancel?.isCancelled ?? false) {
          throw const ChatFailure('CANCELED', 'Canceled.');
        }
        delay = delay * 2 > maxDelay ? maxDelay : delay * 2;
      }
    }
  }

  @override
  Future<void> upload(
    BlobSlot slot,
    Uint8List bytes, {
    void Function(int sent, int total)? onProgress,
    CancelToken? cancel,
  }) => _retrying(
    () => _dio.put<void>(
      slot.uploadUrl,
      // The ciphertext itself, so the body is exactly the declared size: Dio derives the
      // Content-Length from it and the signed URL refuses any other length.
      data: bytes,
      cancelToken: cancel,
      options: Options(headers: slot.headers),
      onSendProgress: onProgress,
    ),
    cancel,
  );

  @override
  Future<Uint8List> download(
    String url, {
    required int maxBytes,
    void Function(int received, int total)? onProgress,
    CancelToken? cancel,
  }) => _retrying(() async {
    final response = await _dio.get<ResponseBody>(
      url,
      cancelToken: cancel,
      options: Options(responseType: ResponseType.stream),
    );
    final out = BytesBuilder(copy: false);
    final declared = response.data!.contentLength;
    if (declared > maxBytes) {
      throw const ChatFailure(
        'CORRUPT',
        'The photo didn’t arrive intact. Try again.',
      );
    }
    await for (final part in response.data!.stream) {
      out.add(part);
      if (out.length > maxBytes) {
        throw const ChatFailure(
          'CORRUPT',
          'The photo didn’t arrive intact. Try again.',
        );
      }
      onProgress?.call(out.length, declared > 0 ? declared : maxBytes);
    }
    return out.takeBytes();
  }, cancel);
}
