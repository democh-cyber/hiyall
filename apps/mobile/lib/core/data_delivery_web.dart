import 'dart:js_interop';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:web/web.dart' as web;

import 'data_delivery.dart' show Delivery;

/// A browser download: a Blob behind a temporary link that is clicked once.
Future<Delivery> deliverData(
  String filename,
  List<int> bytes, {
  Rect? origin,
}) async {
  final blob = web.Blob(
    [Uint8List.fromList(bytes).toJS].toJS,
    web.BlobPropertyBag(type: 'application/json'),
  );
  final url = web.URL.createObjectURL(blob);
  final link = web.document.createElement('a') as web.HTMLAnchorElement
    ..href = url
    ..download = filename;
  web.document.body?.append(link);
  link.click();
  link.remove();
  web.URL.revokeObjectURL(url);
  return Delivery.downloaded;
}

/// Nothing is ever written on the web: the browser handles the download.
Future<void> wipeExports() async {}
