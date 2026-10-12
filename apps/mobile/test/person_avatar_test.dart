import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/avatar_upload.dart';
import 'package:hiyall/shared/person_avatar.dart';

import 'avatar_helpers.dart';
import 'widget_test.dart' show FakeApi;

const session = Session('test-only-token', 'u1');

Widget host(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

void main() {
  tearDown(AvatarRequests.restore);

  group('models', () {
    final base = {'userId': 'u1', 'username': 'sam', 'displayName': 'Sam'};

    test('Profile reads avatar URLs and treats absent ones as null', () {
      final none = Profile.fromJson(base);
      expect(none.avatarUrl, isNull);
      expect(none.avatarFullUrl, isNull);
      expect(none.avatarFor(112), isNull);
      final has = Profile.fromJson({
        ...base,
        'avatarUrl': 'https://cdn.test/a/thumb.webp?sig=1',
        'avatarFullUrl': 'https://cdn.test/a/full.webp?sig=1',
      });
      expect(has.avatarUrl, endsWith('thumb.webp?sig=1'));
      // Big circles use the full size, small ones the thumbnail.
      expect(has.avatarFor(112), endsWith('full.webp?sig=1'));
      expect(has.avatarFor(48), endsWith('thumb.webp?sig=1'));
      expect(
        Profile.fromJson({...base, 'avatarUrl': 'https://cdn.test/t.webp'})
            .avatarFor(112),
        'https://cdn.test/t.webp',
      );
      expect(Profile.fromJson({...base, 'avatarUrl': null}).avatarUrl, isNull);
    });

    test('Everyone shown as a person carries a nullable avatar', () {
      expect(Person.fromJson(base).avatarUrl, isNull);
      expect(
        Person.fromJson({...base, 'avatarUrl': 'https://cdn.test/t.webp'})
            .avatarUrl,
        'https://cdn.test/t.webp',
      );
      final post = Post.fromJson({
        'postId': 'p',
        'author': {...base, 'avatarUrl': 'https://cdn.test/t.webp'},
        'createdAt': '2026-10-10T10:00:00Z',
      });
      expect(post.author.avatarUrl, 'https://cdn.test/t.webp');
      final comment = PostComment.fromJson({
        'commentId': 'c',
        'postId': 'p',
        'body': 'hi',
        'author': {...base, 'avatarUrl': null},
        'createdAt': '2026-10-10T10:00:00Z',
      });
      expect(comment.author.avatarUrl, isNull);
      final member = SpaceMember.fromJson({
        'user': {...base, 'avatarUrl': 'https://cdn.test/t.webp'},
        'role': 'member',
        'state': 'active',
        'rsvp': '',
      });
      expect(member.user.avatarUrl, 'https://cdn.test/t.webp');
    });
  });

  test(
    'The cache key ignores the signature, so refreshed URLs hit the cache',
    () {
      final first = avatarCacheKey(
        'u1',
        'https://cdn.test/avatars/u1/a.webp?sig=1&exp=5',
      );
      final later = avatarCacheKey(
        'u1',
        'https://cdn.test/avatars/u1/a.webp?sig=2&exp=9',
      );
      expect(first, later);
      expect(first, 'avatar:u1:/avatars/u1/a.webp');
      expect(
        avatarCacheKey('u1', 'https://cdn.test/avatars/u1/b.webp?sig=1'),
        isNot(first),
      );
      expect(avatarProvider('u1', null), isNull);
      expect(avatarProvider('u1', ''), isNull);
    },
  );

  group('PersonAvatar', () {
    testWidgets('Without a photo it shows the initial on the tint', (
      tester,
    ) async {
      final requests = AvatarRequests(() => const BrokenImage());
      await tester.pumpWidget(
        host(const PersonAvatar(name: 'sam', radius: 20)),
      );
      expect(find.text('S'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      expect(requests.urls, isEmpty);
      expect(tester.getSize(find.byType(PersonAvatar)), const Size(40, 40));
      await tester.pumpWidget(
        host(const PersonAvatar(name: '@kai', avatarUrl: '')),
      );
      expect(find.text('K'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('With a photo it asks for it by its stable key and shows it', (
      tester,
    ) async {
      final image = (await tester.runAsync(() => createTestImage()))!;
      final requests = AvatarRequests(() => StaticImage(image));
      await tester.pumpWidget(
        host(
          const PersonAvatar(
            name: 'Sam',
            userId: 'u1',
            avatarUrl: 'https://cdn.test/avatars/u1/a.webp?sig=1',
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(RawImage), findsOneWidget);
      expect(requests.keys, ['avatar:u1:/avatars/u1/a.webp']);
      expect(requests.urls.single, contains('sig=1'));
      // The same photo under a fresh signature is the same cache entry.
      await tester.pumpWidget(
        host(
          const PersonAvatar(
            name: 'Sam',
            userId: 'u1',
            avatarUrl: 'https://cdn.test/avatars/u1/a.webp?sig=2',
          ),
        ),
      );
      expect(requests.keys.toSet(), {'avatar:u1:/avatars/u1/a.webp'});
    });

    testWidgets('While the photo loads the initial stays, quietly', (
      tester,
    ) async {
      AvatarRequests(() => const BrokenImage());
      await tester.pumpWidget(
        host(
          const PersonAvatar(name: 'Sam', avatarUrl: 'https://cdn.test/a.webp'),
        ),
      );
      // Not yet resolved: nothing flashes, the fallback is what's on screen.
      expect(find.text('S'), findsOneWidget);
    });

    testWidgets('A photo that fails leaves the initial, with no error', (
      tester,
    ) async {
      AvatarRequests(() => const BrokenImage());
      await tester.pumpWidget(
        host(
          const PersonAvatar(name: 'Sam', avatarUrl: 'https://cdn.test/a.webp'),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('S'), findsOneWidget);
      expect(find.byType(RawImage), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'Custom artwork replaces the initial, and a picked photo wins over a URL',
      (tester) async {
        final requests = AvatarRequests(() => const BrokenImage());
        await tester.pumpWidget(
          host(
            PersonAvatar(
              name: 'Sam',
              bytes: pngBytes,
              avatarUrl: 'https://cdn.test/a.webp',
              fallback: const SizedBox(key: Key('art')),
            ),
          ),
        );
        expect(find.byKey(const Key('art')), findsOneWidget);
        expect(find.text('S'), findsNothing);
        expect(requests.urls, isEmpty);
        final image = tester.widget<Image>(find.byType(Image));
        expect((image.image as ResizeImage).imageProvider, isA<MemoryImage>());
      },
    );
  });

  group('AvatarUploadController', () {
    late PhotoPicker picker;
    late UploadApi api;
    setUp(() {
      picker = PhotoPicker();
      api = UploadApi();
    });

    test(
      'Picking keeps the bytes for a preview, resized by the picker',
      () async {
        final c = AvatarUploadController(picker);
        final photo = await c.pick(AvatarSource.gallery);
        expect(photo!.contentType, 'image/jpeg');
        expect(c.photo, same(photo));
        expect(c.error, isNull);
        expect(picker.maxWidth, 2048);
        expect(picker.quality, 85);
        await c.pick(AvatarSource.camera);
        expect(picker.sources.last, ImageSource.camera);
      },
    );

    test('Backing out changes nothing', () async {
      final c = AvatarUploadController(picker);
      await c.pick(AvatarSource.gallery);
      picker.bytes = null;
      expect(await c.pick(AvatarSource.gallery), isNull);
      expect(c.photo, isNotNull);
      expect(c.error, isNull);
    });

    test('Unsupported, oversized and refused picks say why', () async {
      final c = AvatarUploadController(picker);
      picker.bytes = Uint8List.fromList('GIF89a........'.codeUnits);
      await c.pick(AvatarSource.gallery);
      expect(c.error!.problem, AvatarProblem.unsupportedType);
      expect(c.error!.message, 'Use a JPEG, PNG or WebP photo.');
      expect(c.photo, isNull);
      picker.bytes = Uint8List(maxPhotoBytes + 1)..setAll(0, jpegBytes);
      await c.pick(AvatarSource.gallery);
      expect(c.error!.problem, AvatarProblem.tooLarge);
      expect(c.error!.message, contains('15 MB'));
      picker.failure = photoAccessDenied();
      await c.pick(AvatarSource.gallery);
      expect(c.error!.problem, AvatarProblem.noPermission);
      expect(c.error!.message, contains('settings'));
    });

    test(
      'Upload reports progress, returns the id and sends the avatar purpose',
      () async {
        final c = AvatarUploadController(picker);
        await c.pick(AvatarSource.gallery);
        final seen = <double>[];
        c.addListener(() => seen.add(c.progress));
        final id = await c.upload(api, session);
        expect(id, 'media-1');
        expect(api.calls, ['upload avatar image/jpeg 8']);
        expect(seen, contains(1.0));
        expect(c.uploading, isFalse);
        expect(c.error, isNull);
      },
    );

    test(
      'A failed upload keeps the photo, explains, and can be retried',
      () async {
        final c = AvatarUploadController(picker);
        await c.pick(AvatarSource.gallery);
        api.failure = const ApiFailure(
          'Could not connect. Check your connection and retry.',
        );
        expect(await c.upload(api, session), isNull);
        expect(c.error!.problem, AvatarProblem.network);
        expect(c.photo, isNotNull);
        api.failure = null;
        expect(await c.upload(api, session), 'media-1');
        expect(c.error, isNull);
      },
    );

    test('Server refusals map to their own messages', () {
      expect(
        AvatarError.from(const ApiFailure('x', 413, 'TOO_LARGE')).problem,
        AvatarProblem.tooLarge,
      );
      expect(
        AvatarError.from(const ApiFailure('x', 415, 'UNSUPPORTED_MEDIA'))
            .problem,
        AvatarProblem.unsupportedType,
      );
      expect(
        AvatarError.from(const ApiFailure('x', 429)).problem,
        AvatarProblem.network,
      );
      expect(AvatarError.from(StateError('x')).problem, AvatarProblem.other);
    });

    test('Clearing during an upload drops its result', () async {
      final c = AvatarUploadController(picker);
      await c.pick(AvatarSource.gallery);
      api.gate = Completer();
      final pending = c.upload(api, session);
      expect(c.uploading, isTrue);
      c.clear();
      expect(c.uploading, isFalse);
      expect(c.photo, isNull);
      api.gate!.complete();
      expect(await pending, isNull);
      expect(c.uploading, isFalse);
    });
  });
}

class UploadApi extends FakeApi {
  Object? failure;
  Completer<void>? gate;
  @override
  Future<String> uploadPhoto(
    Session s,
    Uint8List bytes, {
    required String contentType,
    required String purpose,
    void Function(double progress)? onProgress,
  }) async {
    await gate?.future;
    if (failure != null) throw failure!;
    calls.add('upload $purpose $contentType ${bytes.length}');
    onProgress?.call(1);
    return 'media-${calls.length}';
  }
}
