import 'dart:ui' show Rect;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data_delivery_io.dart'
    if (dart.library.js_interop) 'data_delivery_web.dart';

/// What happened to a downloaded export.
enum Delivery {
  /// Handed to the browser as a file download.
  downloaded,

  /// Written to a temporary file, offered to the system share sheet, then deleted.
  shared,
}

/// Puts the member's data export where they can use it: a browser download on
/// the web, the system share sheet on a phone. On a phone the file exists only
/// in the temporary folder, only while the sheet is open, and is deleted when
/// it closes (shared, cancelled or failed); it never goes to the documents
/// folder, which iOS backs up. [origin] anchors the sheet on iPad. Replaced by
/// a fake in tests.
typedef DataDelivery = Future<Delivery> Function(
  String filename,
  List<int> bytes, {
  Rect? origin,
});

final dataDeliveryProvider = Provider<DataDelivery>((ref) => deliverData);

/// Deletes any export file still on this device (an interrupted share, a
/// crash, or an older build that saved it in documents). A no-op on the web.
/// Replaced by a fake in tests.
///
/// The sign-out hook uses this. An export only ever comes from this process
/// ([_wroteExport]); anything an earlier run left is removed at launch (see
/// `main`) and when the app resumes, so a sign-out with nothing written this
/// run has no folder to look through.
final exportWipeProvider = Provider<Future<void> Function()>(
  (ref) =>
      () => _wroteExport ? wipeExports() : Future<void>.value(),
);

bool _wroteExport = false;

/// [wipeExports] for callers outside this library (app start-up).
Future<void> wipeLeftoverExports() => wipeExports();

/// Name pattern of an export file: `hiyall-data-<date>.json`.
bool isExportFilename(String name) =>
    name.startsWith('hiyall-data-') && name.endsWith('.json');

/// The folders export files may be in. A fake in tests.
abstract class ExportFiles {
  /// Writes [bytes] as [filename] in the temporary folder; returns its path.
  Future<String> write(String filename, List<int> bytes);

  Future<void> delete(String path);

  /// Paths of export files in the temporary folder, and in the documents
  /// folder where older builds put them.
  Future<List<String>> list();
}

/// Paths being shared right now; a wipe leaves them alone.
final _inFlight = <String>{};

/// Writes the export to the temporary folder, runs [share], and deletes the
/// file however [share] ends. Earlier leftovers are removed first.
Future<Delivery> deliverThroughFile(
  ExportFiles files,
  Future<void> Function(String path) share,
  String filename,
  List<int> bytes,
) async {
  await wipeExportFiles(files);
  _wroteExport = true;
  final path = await files.write(filename, bytes);
  _inFlight.add(path);
  try {
    await share(path);
  } finally {
    _inFlight.remove(path);
    try {
      await files.delete(path);
    } catch (_) {
      // A locked file is removed by the next wipe.
    }
  }
  return Delivery.shared;
}

/// Deletes every export file in [files] except one being shared. Never throws.
Future<void> wipeExportFiles(ExportFiles files) async {
  final List<String> found;
  try {
    found = await files.list();
  } catch (_) {
    return;
  }
  for (final path in found) {
    if (_inFlight.contains(path)) continue;
    try {
      await files.delete(path);
    } catch (_) {
      // Left for the next wipe.
    }
  }
}
