import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/chat/chat_api.dart';
import 'package:hiyall/core/chat/chat_blob_transport.dart';

/// Plays back one scripted answer per request.
class ScriptedAdapter implements HttpClientAdapter {
  final script = <Object Function(RequestOptions)>[];
  final seen = <RequestOptions>[];
  final bodies = <int>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    seen.add(options);
    var length = 0;
    if (requestStream != null) {
      await for (final part in requestStream) {
        length += part.length;
      }
    }
    bodies.add(length);
    final answer = script.removeAt(0)(options);
    if (answer is DioException) throw answer;
    return answer as ResponseBody;
  }

  @override
  void close({bool force = false}) {}
}

DioException failure(RequestOptions o, DioExceptionType type, [int? status]) =>
    DioException(
      requestOptions: o,
      type: type,
      response: status == null
          ? null
          : Response(requestOptions: o, statusCode: status),
    );

ResponseBody ok(List<int> bytes, {int? length}) => ResponseBody.fromBytes(
  bytes,
  200,
  headers: {
    Headers.contentLengthHeader: ['${length ?? bytes.length}'],
  },
);

void main() {
  late ScriptedAdapter adapter;
  late List<Duration> waits;
  late DioBlobTransport transport;
  final slot = BlobSlot(
    '5b6c0000-0000-4000-8000-000000000001',
    'https://storage.invalid/chat/x?X-Amz-Signature=secret',
    const {
      'Content-Type': 'application/octet-stream',
      'x-amz-checksum-sha256': 'abc=',
    },
    null,
  );

  setUp(() {
    adapter = ScriptedAdapter();
    waits = [];
    transport = DioBlobTransport(
      dio: Dio()..httpClientAdapter = adapter,
      wait: (d) async => waits.add(d),
    );
  });

  test('uploads with exactly the slot headers and reports progress', () async {
    adapter.script.add((_) => ok(const []));
    final progress = <int>[];
    await transport.upload(
      slot,
      Uint8List(5000),
      onProgress: (sent, total) => progress.add(sent),
    );
    final request = adapter.seen.single;
    expect(request.method, 'PUT');
    expect(request.uri.toString(), slot.uploadUrl);
    expect(request.headers['Content-Type'], 'application/octet-stream');
    expect(request.headers['x-amz-checksum-sha256'], 'abc=');
    expect(request.headers.containsKey('Authorization'), isFalse);
    expect(adapter.bodies.single, 5000);
    // The body is the ciphertext itself and its length is the declared one; the transport sets no
    // Content-Length of its own (Dio derives it from the body) and no encoding.
    expect(request.data, isA<Uint8List>());
    expect(request.headers['Content-Length'].toString(), '5000');
    expect(request.headers.containsKey('Transfer-Encoding'), isFalse);
    expect(request.headers.containsKey('Content-Encoding'), isFalse);
    expect(progress, isNotEmpty);
  });

  test('retries network errors with a growing, capped pause', () async {
    for (var i = 0; i < 3; i++) {
      adapter.script.add((o) => failure(o, DioExceptionType.connectionError));
    }
    adapter.script.add((_) => ok(const []));
    transport = DioBlobTransport(
      dio: Dio()..httpClientAdapter = adapter,
      attempts: 5,
      maxDelay: const Duration(seconds: 3),
      wait: (d) async => waits.add(d),
    );
    await transport.upload(slot, Uint8List(10));
    expect(adapter.seen, hasLength(4));
    expect(waits, [
      const Duration(seconds: 1),
      const Duration(seconds: 2),
      const Duration(seconds: 3),
    ]);
  });

  test('gives up after the attempts with a NETWORK failure', () async {
    for (var i = 0; i < 4; i++) {
      adapter.script.add((o) => failure(o, DioExceptionType.receiveTimeout));
    }
    await expectLater(
      transport.upload(slot, Uint8List(10)),
      throwsA(isA<ChatFailure>().having((e) => e.code, 'code', 'NETWORK')),
    );
    expect(adapter.seen, hasLength(4));
  });

  test('retries server faults but not refusals', () async {
    adapter.script
      ..add((o) => failure(o, DioExceptionType.badResponse, 503))
      ..add((_) => ok(const []));
    await transport.upload(slot, Uint8List(10));
    expect(adapter.seen, hasLength(2));

    adapter.seen.clear();
    adapter.script.add((o) => failure(o, DioExceptionType.badResponse, 403));
    await expectLater(
      transport.upload(slot, Uint8List(10)),
      throwsA(
        isA<ChatFailure>()
            .having((e) => e.code, 'code', 'STORAGE_REFUSED')
            .having((e) => e.status, 'status', 403),
      ),
    );
    expect(adapter.seen, hasLength(1));
  });

  test('errors never contain the signed URL', () async {
    adapter.script.add((o) => failure(o, DioExceptionType.badResponse, 403));
    try {
      await transport.upload(slot, Uint8List(10));
      fail('should throw');
    } catch (e) {
      expect('$e', isNot(contains('storage.invalid')));
      expect('$e', isNot(contains('Signature')));
    }
  });

  test('cancel stops without a retry', () async {
    final cancel = CancelToken();
    adapter.script.add((o) {
      cancel.cancel();
      return failure(o, DioExceptionType.cancel);
    });
    await expectLater(
      transport.upload(slot, Uint8List(10), cancel: cancel),
      throwsA(isA<ChatFailure>().having((e) => e.code, 'code', 'CANCELED')),
    );
    expect(adapter.seen, hasLength(1));
    expect(waits, isEmpty);
  });

  test('downloads the bytes and reports progress', () async {
    adapter.script.add((_) => ok(List.generate(300, (i) => i & 255)));
    final progress = <double>[];
    final bytes = await transport.download(
      'https://storage.invalid/get/x?sig=secret',
      maxBytes: 300,
      onProgress: (got, total) => progress.add(got / total),
    );
    expect(bytes, hasLength(300));
    expect(progress.last, 1);
    expect(adapter.seen.single.method, 'GET');
  });

  test('refuses more bytes than the descriptor allows', () async {
    adapter.script.add((_) => ok(Uint8List(500)));
    await expectLater(
      transport.download('https://storage.invalid/get/x', maxBytes: 300),
      throwsA(isA<ChatFailure>().having((e) => e.code, 'code', 'CORRUPT')),
    );
    // A server that announces too much is refused before reading.
    adapter.script.add((_) => ok(Uint8List(10), length: 9999));
    await expectLater(
      transport.download('https://storage.invalid/get/x', maxBytes: 300),
      throwsA(isA<ChatFailure>().having((e) => e.code, 'code', 'CORRUPT')),
    );
  });
}
