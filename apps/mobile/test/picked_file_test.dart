import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/picked_file.dart';
import 'package:image_picker/image_picker.dart' show XFile;

const _uuid = '3f2b1c9e-4d5a-4e6f-8a7b-9c0d1e2f3a4b';
const _uuid2 = '0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d';

void main() {
  late Directory cache, tmp;
  setUp(() {
    cache = Directory.systemTemp.createTempSync('hiyall-cache');
    tmp = Directory.systemTemp.createTempSync('hiyall-tmp');
  });
  tearDown(() {
    for (final d in [cache, tmp]) {
      try {
        d.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  File put(Directory root, String rel, [List<int> bytes = const [1, 2, 3]]) {
    final f = File('${root.path}/$rel')..createSync(recursive: true);
    f.writeAsBytesSync(bytes);
    return f;
  }

  group('readAndDeletePick', () {
    test('returns the bytes and deletes the file and its empty uuid folder (Android gallery copy)', () async {
      final f = put(cache, '$_uuid/holiday.jpg', [9, 8, 7]);
      expect(await readAndDeletePick(XFile(f.path)), [9, 8, 7]);
      expect(f.existsSync(), isFalse);
      expect(Directory('${cache.path}/$_uuid').existsSync(), isFalse);
      expect(cache.existsSync(), isTrue);
    });

    test('leaves a folder that is not a uuid folder, and one that holds other files', () async {
      final a = put(cache, 'photos/a.jpg');
      await readAndDeletePick(XFile(a.path));
      expect(a.existsSync(), isFalse);
      expect(Directory('${cache.path}/photos').existsSync(), isTrue);
      final b = put(cache, '$_uuid/b.jpg');
      put(cache, '$_uuid/other.db');
      await readAndDeletePick(XFile(b.path));
      expect(Directory('${cache.path}/$_uuid').existsSync(), isTrue);
    });

    test('deletes the file even when the read fails, and the failure is the read\'s', () async {
      final f = put(cache, 'gone.jpg');
      final pick = _Unreadable(f.path);
      await expectLater(readAndDeletePick(pick), throwsA(isA<StateError>()));
      expect(f.existsSync(), isFalse);
    });

    test('a pick with no file behind it (in memory) reads fine', () async {
      final pick = XFile.fromData(
        Uint8List.fromList([4, 5]),
        name: 'x.jpg',
        path: '',
      );
      expect(await readAndDeletePick(pick), [4, 5]);
    });
  });

  group('sweepPickerTemp', () {
    test(
      'removes what image_picker leaves, on both layouts, and nothing else',
      () async {
        // Android: cache folder.
        final gallery = put(cache, '$_uuid/photo.jpg');
        final scaled = put(cache, 'scaled_photo.jpg');
        final capture = put(cache, '${_uuid2}8123456789.jpg');
        // iOS: tmp folder.
        final ios = put(tmp, 'image_picker_ABC-123.jpg');
        final ios2 = put(tmp, 'image_picker_ABC-124.png');
        // Bystanders.
        final share = put(cache, 'share_plus/hiyall-data-2026-01-01.json');
        final images = put(cache, 'libCachedImageData/abc.jpg');
        final plain = put(cache, 'photo.jpg');
        final foreignUuid = put(cache, '$_uuid2/state.db');
        final scaledText = put(cache, 'scaled_notes.txt');
        final other = put(tmp, 'flutter_tools.log');

        final removed = await sweepPickerTemp(roots: [cache, tmp]);

        expect(removed, 5);
        for (final gone in [gallery.parent, scaled, capture, ios, ios2]) {
          expect(gone.existsSync(), isFalse, reason: gone.path);
        }
        for (final kept in [
          share,
          images,
          plain,
          foreignUuid,
          scaledText,
          other,
        ]) {
          expect(kept.existsSync(), isTrue, reason: kept.path);
        }
      },
    );

    test(
      'is idempotent, and a missing or unreadable folder is not an error',
      () async {
        put(cache, 'scaled_a.jpg');
        expect(await sweepPickerTemp(roots: [cache]), 1);
        expect(await sweepPickerTemp(roots: [cache]), 0);
        expect(
          await sweepPickerTemp(roots: [Directory('${cache.path}/nope')]),
          0,
        );
      },
    );

    test('the same folder listed twice is swept once', () async {
      put(cache, 'scaled_a.jpg');
      expect(await sweepPickerTemp(roots: [cache, cache]), 1);
    });
  });
}

/// A pick whose read fails after the file exists.
class _Unreadable extends XFile {
  _Unreadable(super.path);
  @override
  Future<Uint8List> readAsBytes() async => throw StateError('unreadable');
}
