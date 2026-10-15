import 'dart:io';
import 'dart:ui' show Rect;

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'data_delivery.dart';

/// The export file in the system temporary folder (not backed up, cleared by
/// the system), plus a look in documents for files an older build left there.
class TempExportFiles implements ExportFiles {
  const TempExportFiles();

  @override
  Future<String> write(String filename, List<int> bytes) async {
    final dir = await getTemporaryDirectory();
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
    for (final dir in [
      await getTemporaryDirectory(),
      await getApplicationDocumentsDirectory(),
    ]) {
      try {
        await for (final entry in dir.list()) {
          final name = entry.path.split(Platform.pathSeparator).last;
          if (entry is File && isExportFilename(name)) found.add(entry.path);
        }
      } on FileSystemException {
        // A folder that cannot be read has nothing to wipe.
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
        // write a second copy that nothing here deletes.
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
