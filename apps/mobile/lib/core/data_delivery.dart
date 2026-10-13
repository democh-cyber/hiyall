import 'dart:ui' show Rect;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data_delivery_io.dart'
    if (dart.library.js_interop) 'data_delivery_web.dart';

/// What happened to a downloaded export.
enum Delivery {
  /// Handed to the browser as a file download.
  downloaded,

  /// Saved in the app's folder and offered to the system share sheet.
  shared,
}

/// Puts the member's data export where they can use it: a browser download on
/// the web, the system share sheet (after saving a copy in the app's documents
/// folder) on a phone. [origin] anchors the sheet on iPad. Replaced by a fake in tests.
typedef DataDelivery = Future<Delivery> Function(
  String filename,
  List<int> bytes, {
  Rect? origin,
});

final dataDeliveryProvider = Provider<DataDelivery>((ref) => deliverData);
