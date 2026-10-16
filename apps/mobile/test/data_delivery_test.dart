import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/data_delivery.dart';
import 'package:hiyall/core/data_delivery_io.dart' show TempExportFiles;

/// A file system in memory: a map of path to bytes, with the folders named in
/// the path (`tmp/...`, `documents/...`).
class FakeExportFiles implements ExportFiles {
  final files = <String, List<int>>{};
  final deleted = <String>[];
  bool failDelete = false, failList = false;

  @override
  Future<String> write(String filename, List<int> bytes) async {
    final path = 'tmp/$filename';
    files[path] = bytes;
    return path;
  }

  @override
  Future<void> delete(String path) async {
    if (failDelete) throw StateError('locked');
    files.remove(path);
    deleted.add(path);
  }

  @override
  Future<List<String>> list() async {
    if (failList) throw StateError('no folder');
    return [
      for (final path in files.keys)
        if (isExportFilename(path.split('/').last)) path,
    ];
  }
}

void main() {
  const name = 'hiyall-data-2026-10-16.json';

  test(
    'the file is written to the temporary folder, shared, then deleted',
    () async {
      final fs = FakeExportFiles();
      String? seen;
      List<int>? whileShared;
      final how = await deliverThroughFile(
        fs,
        (path) async {
          seen = path;
          whileShared = fs.files[path];
        },
        name,
        [1, 2, 3],
      );
      expect(how, Delivery.shared);
      expect(seen, 'tmp/$name');
      expect(seen, startsWith('tmp/'), reason: 'never the documents folder');
      expect(whileShared, [1, 2, 3], reason: 'present while the sheet is open');
      expect(fs.files, isEmpty, reason: 'gone once it closed');
    },
  );

  test('a failed or cancelled share still deletes the file', () async {
    final fs = FakeExportFiles();
    await expectLater(
      deliverThroughFile(
        fs,
        (_) async => throw StateError('no share target'),
        name,
        [9],
      ),
      throwsStateError,
    );
    expect(fs.files, isEmpty);
    expect(fs.deleted, ['tmp/$name']);
  });

  test('earlier leftovers, including one in documents from an older build, are removed first', () async {
    final fs = FakeExportFiles()
      ..files['tmp/hiyall-data-2026-01-01.json'] = [1]
      ..files['documents/hiyall-data-2025-12-31.json'] = [2]
      ..files['documents/notes.txt'] = [3];
    await deliverThroughFile(fs, (_) async {}, name, [4]);
    expect(fs.files.keys, ['documents/notes.txt'], reason: 'only exports go');
  });

  test(
    'a wipe removes every export and nothing else, and never throws',
    () async {
      final fs = FakeExportFiles()
        ..files['tmp/hiyall-data-a.json'] = [1]
        ..files['tmp/photo.jpg'] = [2];
      await wipeExportFiles(fs);
      expect(fs.files.keys, ['tmp/photo.jpg']);

      fs
        ..files['tmp/hiyall-data-b.json'] = [1]
        ..failDelete = true;
      await wipeExportFiles(fs);
      fs
        ..failDelete = false
        ..failList = true;
      await wipeExportFiles(fs);
      expect(
        fs.files.keys,
        contains('tmp/hiyall-data-b.json'),
        reason: 'left for next time',
      );
    },
  );

  test('a wipe on app resume leaves the file being shared alone', () async {
    final fs = FakeExportFiles();
    final done = deliverThroughFile(
      fs,
      (path) async {
        // The app comes back to the foreground while the share sheet is still open.
        await wipeExportFiles(fs);
        expect(fs.files.containsKey(path), isTrue);
      },
      name,
      [1],
    );
    await done;
    expect(fs.files, isEmpty);
  });

  test('the sign-out wipe does nothing, and touches no folder, when no export was written this run', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    // No platform plugin exists here: reaching for a folder would hang or throw.
    await container
        .read(exportWipeProvider)()
        .timeout(const Duration(seconds: 2));
  });

  test('a delete that fails after sharing is not an error and the next wipe gets it', () async {
    final fs = FakeExportFiles();
    await deliverThroughFile(fs, (_) async => fs.failDelete = true, name, [1]);
    expect(fs.files, isNotEmpty);
    fs.failDelete = false;
    await wipeExportFiles(fs);
    expect(fs.files, isEmpty);
  });

  group('the Android share library copy (APP-N1)', () {
    late Directory root;
    late TempExportFiles files;
    setUp(() {
      // cache/ is what path_provider calls the temporary folder on Android
      // and what share_plus calls cacheDir; it keeps its copy in cache/share_plus.
      root = Directory.systemTemp.createTempSync('hiyall-share');
      Directory('${root.path}/cache/share_plus').createSync(recursive: true);
      Directory('${root.path}/documents').createSync();
      files = TempExportFiles(
        temporary: () async => Directory('${root.path}/cache'),
        documents: () async => Directory('${root.path}/documents'),
      );
    });
    tearDown(() => root.deleteSync(recursive: true));

    File put(String relative) =>
        File('${root.path}/$relative')..writeAsStringSync('x');

    test(
      'a wipe removes the copy in cache/share_plus and keeps other files',
      () async {
        final copy = put('cache/share_plus/hiyall-data-2026-10-16.json');
        final other = put('cache/share_plus/photo.jpg');
        final temp = put('cache/hiyall-data-2026-10-15.json');
        final old = put('documents/hiyall-data-2025-01-01.json');
        final notes = put('documents/notes.txt');
        await wipeExportFiles(files);
        expect(copy.existsSync(), isFalse);
        expect(temp.existsSync(), isFalse);
        expect(old.existsSync(), isFalse);
        expect(other.existsSync(), isTrue);
        expect(notes.existsSync(), isTrue);
      },
    );

    test('sharing deletes the file and the library copy made while the sheet was open', () async {
      late String sharedPath;
      await deliverThroughFile(
        files,
        (path) async {
          sharedPath = path;
          // What share_plus does: copy by name into its own folder.
          put('cache/share_plus/${path.split('/').last}');
          // A resume wipe while the sheet is open leaves both alone.
          await wipeExportFiles(files);
          expect(File(path).existsSync(), isTrue);
          expect(
            File('${root.path}/cache/share_plus/$name').existsSync(),
            isTrue,
          );
        },
        name,
        [1, 2],
      );
      expect(File(sharedPath).existsSync(), isFalse);
      expect(File('${root.path}/cache/share_plus/$name').existsSync(), isFalse);
    });

    test('a failed share still removes the library copy', () async {
      await expectLater(
        deliverThroughFile(
          files,
          (path) async {
            put('cache/share_plus/$name');
            throw StateError('no target');
          },
          name,
          [1],
        ),
        throwsStateError,
      );
      expect(File('${root.path}/cache/share_plus/$name').existsSync(), isFalse);
    });

    test(
      'a missing share_plus folder (iOS, or never shared) is not an error',
      () async {
        Directory('${root.path}/cache/share_plus').deleteSync();
        expect(await files.list(), isEmpty);
        await wipeExportFiles(files);
      },
    );
  });
}
