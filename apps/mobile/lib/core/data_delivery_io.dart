import 'dart:io';
import 'dart:ui' show Rect;

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'data_delivery.dart';

/// The export file in the system temporary folder (not backed up, cleared by
/// the system), plus the places a copy can end up:
///
/// - the documents folder, where older builds saved it;
/// - `<temporary>/share_plus`, where the Android share library keeps its own
///   copy of every file it shares (share_plus copies the file, under the same
///   name, into `<cacheDir>/share_plus`, and only clears that folder at the
///   start of its next share). On Android the temporary folder from
///   path_provider is `cacheDir`, so the folder is a child of it. Nothing
///   creates the folder on iOS, where listing it finds nothing.
///
/// The folders are looked up through [temporary] and [documents] so a test can
/// point them at a fake layout.
class TempExportFiles implements ExportFiles {
  const TempExportFiles({
    this.temporary = getTemporaryDirectory,
    this.documents = getApplicationDocumentsDirectory,
  });

  final Future<Directory> Function() temporary;
  final Future<Directory> Function() documents;

  /// Folder name share_plus uses inside the Android cache folder.
  static const sharePlusFolder = 'share_plus';

  @override
  Future<String> write(String filename, List<int> bytes) async {
    final dir = await temporary();
    final file = File('${dir.path}${Platform.pathSeparator}$filename');
    await file.writeAsBytes(bytes, flush: true);
    return file.path;
  }

  @override
  Future<void> delete(String path) async {
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  @override
  Future<List<String>> list() async {
    final found = <String>[];
    final folders = <Directory>[];
    try {
      final temp = await temporary();
      folders
        ..add(temp)
        ..add(
          Directory('${temp.path}${Platform.pathSeparator}$sharePlusFolder'),
        );
    } catch (_) {
      // No temporary folder, nothing to look through there.
    }
    try {
      folders.add(await documents());
    } catch (_) {
      // Same for documents.
    }
    for (final dir in folders) {
      try {
        await for (final entry in dir.list()) {
          final name = entry.path.split(Platform.pathSeparator).last;
          if (entry is File && isExportFilename(name)) found.add(entry.path);
        }
      } on FileSystemException {
        // A folder that cannot be read (or is not there) has nothing to wipe.
      }
    }
    return found;
  }
}

/// Writes the export to the temporary folder, opens the system share sheet and
/// deletes the file when the sheet closes, whatever the outcome.
Future<Delivery> deliverData(
  String filename,
  List<int> bytes, {
  Rect? origin,
}) => deliverThroughFile(
  const TempExportFiles(),
  (path) async {
    await SharePlus.instance.share(
      ShareParams(
        // By path only: handing over the bytes too would make share_plus
        // write another copy. On Android it still copies the file into its
        // own cache folder; [TempExportFiles] deletes that copy too.
        files: [XFile(path, mimeType: 'application/json')],
        subject: 'My Hiyall data',
        sharePositionOrigin: origin,
      ),
    );
  },
  filename,
  bytes,
);

/// Removes leftover export files from this device.
Future<void> wipeExports() => wipeExportFiles(const TempExportFiles());
