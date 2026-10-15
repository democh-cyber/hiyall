import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/data_delivery.dart';

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
}
