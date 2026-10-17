import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/avatar_upload.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/features/pulse.dart';
import 'package:image_picker/image_picker.dart';

import 'avatar_helpers.dart' show jpegBytes, pngBytes;
import 'pulse_test.dart' show PulseApi;
import 'widget_test.dart' show SignedIn;

/// Hands back the files a platform picker would have copied into its temporary folder.
class FilePicker extends ImagePicker {
  FilePicker(this.paths);
  final List<String> paths;
  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) async => XFile(paths.first);

  @override
  Future<List<XFile>> pickMultiImage({
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    int? limit,
    bool requestFullMetadata = true,
  }) async => [for (final p in paths) XFile(p)];
}

void main() {
  late Directory cache;
  setUp(() => cache = Directory.systemTemp.createTempSync('hiyall-picks'));
  tearDown(() {
    try {
      cache.deleteSync(recursive: true);
    } catch (_) {}
  });

  List<String> makePicks(int n) => [
    for (var i = 0; i < n; i++)
      (File('${cache.path}/3f2b1c9e-4d5a-4e6f-8a7b-9c0d1e2f3a4$i/photo$i.jpg')
            ..createSync(recursive: true)
            ..writeAsBytesSync(jpegBytes))
          .path,
  ];

  test(
    'the avatar picker deletes the picked file once it has its bytes',
    () async {
      final paths = makePicks(1);
      final controller = AvatarUploadController(FilePicker(paths));
      final photo = await controller.pick(AvatarSource.gallery);
      expect(photo, isNotNull);
      expect(photo!.bytes, jpegBytes);
      expect(File(paths.single).existsSync(), isFalse);
      expect(File(paths.single).parent.existsSync(), isFalse);
    },
  );

  testWidgets('the post composer deletes every picked file', (tester) async {
    final paths = makePicks(2);
    final container = ProviderContainer(
      overrides: [
        apiProvider.overrideWithValue(PulseApi()),
        sessionProvider.overrideWith(SignedIn.new),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: ComposePostScreen(picker: FilePicker(paths))),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('add-photos')));
      // The reads are real file IO: give them time to finish.
      for (var i = 0; i < 200; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        await tester.pump();
        if (paths.every((p) => !File(p).existsSync())) break;
      }
    });
    for (final p in paths) {
      expect(File(p).existsSync(), isFalse, reason: p);
    }
  });

  testWidgets('the story composer deletes the picked file', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final file =
        File('${cache.path}/0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d/s.png')
          ..createSync(recursive: true)
          ..writeAsBytesSync(pngBytes);
    final container = ProviderContainer(
      overrides: [
        apiProvider.overrideWithValue(PulseApi()),
        sessionProvider.overrideWith(SignedIn.new),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: StoryComposerScreen(picker: FilePicker([file.path])),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('story-gallery')));
      for (var i = 0; i < 200; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        await tester.pump();
        if (!file.existsSync()) break;
      }
    });
    expect(file.existsSync(), isFalse);
    expect(file.parent.existsSync(), isFalse);
  });
}
