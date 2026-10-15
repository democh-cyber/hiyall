import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:hiyall/app.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/avatar_upload.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/features/profile_editor.dart';
import 'package:hiyall/shared/person_avatar.dart';

import 'avatar_helpers.dart';
import 'widget_test.dart' show FakeApi, SignedIn;
import 'support/fixtures.dart';

const photoUrl = 'https://cdn.test/avatars/anjali/a.webp?sig=1';

/// A server that keeps the profile photo, and moves the version on with it.
class AvatarApi extends FakeApi {
  String? avatar;
  int version = 1;
  Object? uploadFailure;
  Object? attachFailure;
  Completer<void>? uploadGate;
  final versionsSeen = <String>[];
  final saves = <Map<String, dynamic>>[];

  Profile get current => Profile(
    userId: anjaliId,
    username: 'anjali',
    displayName: 'Anjali',
    bio: 'hello',
    profession: '',
    version: '$version',
    avatarUrl: avatar,
    avatarFullUrl: avatar,
  );

  @override
  Future<Profile> profile(Session s) async {
    profileReads++;
    return current;
  }

  @override
  Future<Profile> updateProfile(
    Session s,
    Profile p,
    Map<String, dynamic> patch,
  ) async {
    versionsSeen.add(p.version);
    if (p.version != '$version') {
      throw const ApiFailure('Your settings changed.', 412);
    }
    if (patch.containsKey('avatarMediaId')) {
      if (attachFailure != null) throw attachFailure!;
      calls.add('attach ${patch['avatarMediaId']}');
      avatar = patch['avatarMediaId'] == null ? null : photoUrl;
    } else {
      saves.add(patch);
    }
    version++;
    return current;
  }

  @override
  Future<String> uploadPhoto(
    Session s,
    Uint8List bytes, {
    required String contentType,
    required String purpose,
    void Function(double progress)? onProgress,
  }) async {
    onProgress?.call(.5);
    await uploadGate?.future;
    if (uploadFailure != null) throw uploadFailure!;
    calls.add('upload $purpose $contentType ${bytes.length}');
    return 'media-${calls.length}';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    for (final family in ['SpaceGrotesk', 'Manrope']) {
      await (FontLoader(
        family,
      )..addFont(rootBundle.load('assets/fonts/$family.ttf'))).load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  tearDown(AvatarRequests.restore);

  late ProviderContainer container;
  Future<void> open(
    WidgetTester tester,
    AvatarApi api,
    PhotoPicker picker, [
    String at = '/profile/edit',
  ]) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    container = ProviderContainer(
      overrides: [
        apiProvider.overrideWithValue(api),
        sessionProvider.overrideWith(SignedIn.new),
        imagePickerProvider.overrideWithValue(picker),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const HiyallApp()),
    );
    container.read(routerProvider).go(at);
    await tester.pumpAndSettle();
  }

  PersonAvatar editorAvatar(WidgetTester tester) => tester.widget<PersonAvatar>(
    find.descendant(
      of: find.byKey(const Key('edit-avatar')),
      matching: find.byType(PersonAvatar),
    ),
  );

  Future<void> chooseFromGallery(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('edit-avatar')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('avatar-gallery')));
    await tester.pumpAndSettle();
  }

  testWidgets('The editor starts with a tappable avatar and a camera badge', (
    tester,
  ) async {
    await open(tester, AvatarApi(), PhotoPicker());
    expect(find.byKey(const Key('edit-avatar')), findsOneWidget);
    expect(find.byIcon(Icons.photo_camera_rounded), findsOneWidget);
    expect(editorAvatar(tester).avatarUrl, isNull);
    // With no photo there is nothing to remove.
    await tester.tap(find.byKey(const Key('edit-avatar')));
    await tester.pumpAndSettle();
    expect(find.text('Choose from gallery'), findsOneWidget);
    expect(find.text('Take a photo'), findsOneWidget);
    expect(find.text('Remove photo'), findsNothing);
  });

  testWidgets('The camera is offered on phones only', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final picker = PhotoPicker();
    try {
      await open(tester, AvatarApi(), picker);
      // With only the gallery to offer, a tap goes straight to it.
      await tester.tap(find.byKey(const Key('edit-avatar')));
      await tester.pumpAndSettle();
      expect(find.text('Take a photo'), findsNothing);
      expect(picker.sources, [ImageSource.gallery]);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
    'Choosing a photo uploads it, attaches it and refreshes the profile',
    (tester) async {
      final requests = AvatarRequests(() => const BrokenImage());
      final api = AvatarApi();
      await open(tester, api, PhotoPicker()..bytes = pngBytes);
      final reads = api.profileReads;
      await chooseFromGallery(tester);
      expect(api.calls, [
        'upload avatar image/png ${pngBytes.length}',
        'attach media-1',
      ]);
      expect(find.text('Photo updated.'), findsOneWidget);
      // The profile was read again, so every screen sees the new photo.
      expect(api.profileReads, greaterThan(reads));
      expect(container.read(profileProvider).asData!.value.avatarUrl, photoUrl);
      expect(editorAvatar(tester).avatarUrl, photoUrl);
      expect(editorAvatar(tester).bytes, isNull);
      expect(
        requests.keys,
        everyElement('avatar:$anjaliId:/avatars/anjali/a.webp'),
      );
      expect(find.byKey(const Key('avatar-error')), findsNothing);
    },
  );

  testWidgets('Progress shows while uploading and Cancel drops the photo', (
    tester,
  ) async {
    final api = AvatarApi()..uploadGate = Completer();
    await open(tester, api, PhotoPicker()..bytes = pngBytes);
    await tester.tap(find.byKey(const Key('edit-avatar')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('avatar-gallery')));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('avatar-progress')), findsOneWidget);
    // The local preview shows at once.
    expect(editorAvatar(tester).bytes, pngBytes);
    await tester.tap(find.byKey(const Key('avatar-cancel')));
    await tester.pump();
    expect(find.byKey(const Key('avatar-progress')), findsNothing);
    expect(editorAvatar(tester).bytes, isNull);
    api.uploadGate!.complete();
    await tester.pumpAndSettle();
    // The bytes may already be on the wire, but the photo is never attached.
    expect(api.calls.where((c) => c.startsWith('attach')), isEmpty);
    expect(api.avatar, isNull);
  });

  testWidgets('A failed upload is explained inline and can be retried', (
    tester,
  ) async {
    final api = AvatarApi()
      ..uploadFailure = const ApiFailure(
        'That photo didn’t upload. Check your connection and try again.',
      );
    await open(tester, api, PhotoPicker()..bytes = pngBytes);
    await chooseFromGallery(tester);
    expect(find.byKey(const Key('avatar-error')), findsOneWidget);
    expect(find.textContaining('didn’t upload'), findsOneWidget);
    expect(api.avatar, isNull);
    // The picked photo stays on screen for the retry.
    expect(editorAvatar(tester).bytes, pngBytes);
    api.uploadFailure = null;
    await tester.tap(find.byKey(const Key('avatar-retry')));
    await tester.pumpAndSettle();
    expect(api.avatar, photoUrl);
    expect(find.byKey(const Key('avatar-error')), findsNothing);
  });

  for (final (label, failure, shown, hint)
      in <(String, ApiFailure, String, bool)>[
        (
          'the day’s upload limit',
          const ApiFailure(
            'You’ve reached today’s photo upload limit. Try again later.',
            429,
            'QUOTA',
            Duration(hours: 5),
          ),
          'You’ve reached today’s photo upload limit. Try again in about 5 hours.',
          true,
        ),
        (
          'a full storage',
          const ApiFailure(
            'Your photo storage is full. Delete some posts or stories to free space.',
            429,
            'QUOTA',
          ),
          'Your photo storage is full. Delete some posts or stories to free space.',
          false,
        ),
      ]) {
    testWidgets(
      'A photo refused for $label shows the server’s words, no retry',
      (tester) async {
        final api = AvatarApi()..uploadFailure = failure;
        await open(tester, api, PhotoPicker()..bytes = pngBytes);
        await chooseFromGallery(tester);
        expect(find.byKey(const Key('avatar-error')), findsOneWidget);
        expect(find.text(shown), findsOneWidget);
        expect(hint, shown.contains('Try again in about'));
        // Sending the same photo again would be refused the same way, so no retry is offered.
        expect(find.byKey(const Key('avatar-retry')), findsNothing);
        expect(api.avatar, isNull);
        expect(api.calls.where((c) => c.startsWith('upload')), isEmpty);
      },
    );
  }

  testWidgets(
    'A failed attach keeps the upload, so retrying does not resend it',
    (tester) async {
      final api = AvatarApi()..attachFailure = const ApiFailure('Offline', 500);
      await open(tester, api, PhotoPicker()..bytes = pngBytes);
      await chooseFromGallery(tester);
      expect(find.byKey(const Key('avatar-error')), findsOneWidget);
      api.attachFailure = null;
      await tester.tap(find.byKey(const Key('avatar-retry')));
      await tester.pumpAndSettle();
      expect(api.calls.where((c) => c.startsWith('upload')), hasLength(1));
      expect(api.calls.last, 'attach media-1');
      expect(api.avatar, photoUrl);
    },
  );

  testWidgets('Refused photos never reach the server', (tester) async {
    final api = AvatarApi();
    final picker = PhotoPicker()
      ..bytes = Uint8List.fromList('GIF89a........'.codeUnits);
    await open(tester, api, picker);
    await chooseFromGallery(tester);
    expect(find.text('Use a JPEG, PNG or WebP photo.'), findsOneWidget);
    expect(find.byKey(const Key('avatar-retry')), findsNothing);
    picker
      ..bytes = jpegBytes
      ..failure = photoAccessDenied();
    await chooseFromGallery(tester);
    expect(find.textContaining('device settings'), findsOneWidget);
    expect(api.calls, isEmpty);
  });

  testWidgets('Remove photo clears it and every screen follows', (
    tester,
  ) async {
    AvatarRequests(() => const BrokenImage());
    final api = AvatarApi()..avatar = photoUrl;
    await open(tester, api, PhotoPicker());
    expect(editorAvatar(tester).avatarUrl, photoUrl);
    await tester.tap(find.byKey(const Key('edit-avatar')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('avatar-remove')));
    await tester.pumpAndSettle();
    expect(api.calls, ['attach null']);
    expect(api.avatar, isNull);
    expect(find.text('Photo removed.'), findsOneWidget);
    expect(editorAvatar(tester).avatarUrl, isNull);
    expect(container.read(profileProvider).asData!.value.avatarUrl, isNull);
  });

  testWidgets(
    'A photo change keeps typed edits and the next Save carries the new version',
    (tester) async {
      final api = AvatarApi();
      await open(tester, api, PhotoPicker()..bytes = pngBytes);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Headline'),
        'Mid-edit',
      );
      await chooseFromGallery(tester);
      expect(find.text('Mid-edit'), findsOneWidget);
      await tester.ensureVisible(find.text('Save profile'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save profile'));
      await tester.pumpAndSettle();
      expect(api.saves.single['headline'], 'Mid-edit');
      // The upload's attach moved the profile to version 2; Save used it.
      expect(api.versionsSeen, ['1', '2']);
      expect(find.text('Profile saved.'), findsOneWidget);
    },
  );

  testWidgets('Saving is held while a photo is on its way', (tester) async {
    final api = AvatarApi()..uploadGate = Completer();
    await open(tester, api, PhotoPicker()..bytes = pngBytes);
    await tester.tap(find.byKey(const Key('edit-avatar')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('avatar-gallery')));
    await tester.pump();
    await tester.pump();
    await tester.scrollUntilVisible(
      find.text('Save profile'),
      500,
      scrollable: find
          .descendant(
            of: find.byType(ProfileForm),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Save profile'),
          )
          .onPressed,
      isNull,
    );
    api.uploadGate!.complete();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Save profile'),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('Settings shows the member’s photo once there is one', (
    tester,
  ) async {
    final requests = AvatarRequests(() => const BrokenImage());
    final api = AvatarApi();
    await open(tester, api, PhotoPicker(), '/profile/settings');
    expect(find.byKey(const Key('settings-avatar')), findsNothing);
    api.avatar = photoUrl;
    container.invalidate(profileProvider);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-avatar')), findsOneWidget);
    expect(requests.urls, contains(photoUrl));
  });

  testWidgets('Post authors and the header show photos where they have them', (
    tester,
  ) async {
    final requests = AvatarRequests(() => const BrokenImage());
    final api = AvatarApi()
      ..avatar = photoUrl
      ..posts = [
        Post(
          postId: 'p1',
          author: const Person(
            nikoId,
            'niko',
            'Niko',
            avatarUrl: 'https://cdn.test/avatars/niko/n.webp?sig=9',
          ),
          body: 'hello',
          audience: 'public',
          createdAt: DateTime.now().subtract(const Duration(hours: 1)),
        ),
      ];
    await open(tester, api, PhotoPicker(), '/home');
    await tester.scrollUntilVisible(
      find.text('hello'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(requests.keys, contains('avatar:$nikoId:/avatars/niko/n.webp'));
    // The header avatar for "me" asks for the member's own photo too.
    expect(requests.keys, contains('avatar:$anjaliId:/avatars/anjali/a.webp'));
  });
}
