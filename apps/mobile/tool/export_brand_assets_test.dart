// Generates platform icon assets from the same native Flutter vector brand mark.
// Run: flutter test tool/export_brand_assets_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/theme.dart';
import 'package:hiyall/shared/widgets.dart';

void main() {
  testWidgets('Export Hiyall vector mark to platform icon sizes', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final iconDir = Directory('ios/Runner/Assets.xcassets/AppIcon.appiconset');
    final metadata = jsonDecode(
      File('${iconDir.path}/Contents.json').readAsStringSync(),
    ) as Map;
    final exports = <String, int>{};
    for (final entry in metadata['images'] as List) {
      final size = double.parse((entry['size'] as String).split('x').first);
      final scale = double.parse(
        (entry['scale'] as String).replaceAll('x', ''),
      );
      exports['${iconDir.path}/${entry['filename']}'] = (size * scale).round();
    }
    for (final entry in {
      'mdpi': 48,
      'hdpi': 72,
      'xhdpi': 96,
      'xxhdpi': 144,
      'xxxhdpi': 192,
    }.entries) {
      exports['android/app/src/main/res/mipmap-${entry.key}/ic_launcher.png'] =
          entry.value;
    }
    for (var scale = 1; scale <= 3; scale++) {
      exports['ios/Runner/Assets.xcassets/LaunchImage.imageset/LaunchImage${scale == 1 ? '' : '@${scale}x'}.png'] =
          96 * scale;
    }
    for (final entry in exports.entries) {
      final pixels = entry.value.toDouble();
      tester.view.physicalSize = Size(pixels, pixels);
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: ColoredBox(
            color: VibeColors.lime,
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: BrandMark(size: pixels),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final img = await boundary.toImage(pixelRatio: 1);
        final bytes = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
        await File(entry.key)
            .writeAsBytes(rgbPng(bytes!.buffer.asUint8List(), entry.value));
        img.dispose();
      });
      expect(tester.takeException(), isNull);
    }
  });
}

// Encode the opaque vector canvas as RGB PNG. iOS icons must not carry alpha.
Uint8List rgbPng(Uint8List rgba, int width) {
  final rows = Uint8List(width * (width * 3 + 1));
  var target = 0;
  for (var y = 0; y < width; y++) {
    rows[target++] = 0;
    for (var x = 0; x < width; x++) {
      final source = (y * width + x) * 4;
      for (var channel = 0; channel < 3; channel++) {
        rows[target++] = rgba[source + channel];
      }
    }
  }
  final out = BytesBuilder()..add([137, 80, 78, 71, 13, 10, 26, 10]);
  void chunk(String name, List<int> content) {
    final length = ByteData(4)..setUint32(0, content.length);
    final data = Uint8List.fromList([...ascii.encode(name), ...content]);
    var crc = 0xffffffff;
    for (final byte in data) {
      crc ^= byte;
      for (var bit = 0; bit < 8; bit++) {
        crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
      }
    }
    final checksum = ByteData(4)..setUint32(0, (crc ^ 0xffffffff) & 0xffffffff);
    out.add(length.buffer.asUint8List());
    out.add(data);
    out.add(checksum.buffer.asUint8List());
  }

  final header = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, width)
    ..setUint8(8, 8)
    ..setUint8(9, 2);
  chunk('IHDR', header.buffer.asUint8List());
  chunk('IDAT', ZLibEncoder().convert(rows));
  chunk('IEND', []);
  return out.toBytes();
}
