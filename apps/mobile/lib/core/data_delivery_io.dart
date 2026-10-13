import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'data_delivery.dart' show Delivery;

/// Saves the export in the app's documents folder (replacing any earlier one,
/// so personal data does not pile up) and opens the system share sheet.
Future<Delivery> deliverData(
  String filename,
  List<int> bytes, {
  Rect? origin,
}) async {
  final dir = await getApplicationDocumentsDirectory();
  await for (final entry in dir.list()) {
    final name = entry.path.split(Platform.pathSeparator).last;
    if (entry is File &&
        name.startsWith('hiyall-data-') &&
        name.endsWith('.json')) {
      try {
        await entry.delete();
      } catch (_) {}
    }
  }
  final file = File('${dir.path}${Platform.pathSeparator}$filename');
  await file.writeAsBytes(bytes, flush: true);
  await SharePlus.instance.share(
    ShareParams(
      files: [
        XFile(
          file.path,
          mimeType: 'application/json',
          bytes: Uint8List.fromList(bytes),
        ),
      ],
      subject: 'My Hiyall data',
      sharePositionOrigin: origin,
    ),
  );
  return Delivery.shared;
}
