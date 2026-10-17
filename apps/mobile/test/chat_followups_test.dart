import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/chat/chat_api.dart';
import 'package:hiyall/features/chat_photo.dart';
import 'package:image_picker/image_picker.dart';

import 'avatar_helpers.dart' show jpegBytes;

/// Answers every request with [status] and an error envelope carrying [code] (none when null).
class _Failing implements HttpClientAdapter {
  _Failing(this.status, this.code);
  final int status;
  final String? code;
  int requests = 0;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests++;
    return ResponseBody.fromString(
      jsonEncode(
        code == null
            ? {}
            : {
                'error': {'code': code, 'message': 'x'},
              },
      ),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class _OnePick extends ImagePicker {
  _OnePick(this.path);
  final String path;
  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) async => XFile(path);
}

void main() {
  group('a 401 from the chat relay', () {
    Future<(int, int, Object?)> call(String? code) async {
      final adapter = _Failing(401, code);
      var signedOut = 0, appCheck = 0;
      final api = ChatApi(
        'https://chat.example.com',
        't',
        onUnauthorized: () => signedOut++,
        onAppCheckRequired: () => appCheck++,
        tokenRefresher: () async => null,
        dio: Dio(BaseOptions(baseUrl: 'https://chat.example.com'))
          ..httpClientAdapter = adapter,
      );
      Object? failure;
      try {
        await api.keyCount('d');
      } catch (e) {
        failure = e;
      }
      return (signedOut, appCheck, failure);
    }

    test(
      'APP_CHECK_REQUIRED never signs out; it calls the app-check hook',
      () async {
        final (signedOut, appCheck, failure) = await call('APP_CHECK_REQUIRED');
        expect(signedOut, 0);
        expect(appCheck, 1);
        expect(
          failure,
          isA<ChatFailure>().having(
            (f) => f.code,
            'code',
            'APP_CHECK_REQUIRED',
          ),
        );
      },
    );

    test('only UNAUTHENTICATED ends the session', () async {
      expect((await call('UNAUTHENTICATED')).$1, 1);
      expect(
        (await call(null)).$1,
        0,
        reason: 'a 401 with no error envelope proves nothing',
      );
      expect((await call('SOMETHING_ELSE')).$1, 0);
      expect((await call('UNAUTHENTICATED')).$2, 0);
    });
  });

  test('a picked chat photo is read and its plaintext copy deleted', () async {
    final dir = Directory.systemTemp.createTempSync('hiyall-chatpick');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file =
        File('${dir.path}/3f2b1c9e-4d5a-4e6f-8a7b-9c0d1e2f3a40/photo.jpg')
          ..createSync(recursive: true)
          ..writeAsBytesSync(jpegBytes);
    final bytes = await pickChatPhoto(_OnePick(file.path), PhotoSource.gallery);
    expect(bytes, jpegBytes);
    expect(file.existsSync(), isFalse);
    expect(file.parent.existsSync(), isFalse);
  });
}
