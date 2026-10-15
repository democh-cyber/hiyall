import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The shipped app has no development sign-in, fixture accounts or capture
/// helpers. Release, debug and profile builds all compile the same lib/, so
/// proving the symbols are gone from the source proves they are gone from
/// every build.
void main() {
  const forbidden = [
    'devLoginEnabled',
    'ENABLE_DEV_LOGIN',
    'signInDevelopment',
    '/dev/session',
    'Development accounts',
    'Internal profile preview',
    'anjaliId',
    'nikoId',
    'samId',
    'CAPTURE_',
  ];

  test('lib/ contains no development-only code', () {
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));
    expect(files, isNotEmpty);
    final found = <String>[];
    for (final file in files) {
      final text = file.readAsStringSync();
      for (final token in forbidden) {
        if (text.contains(token)) found.add('${file.path}: $token');
      }
    }
    expect(found, isEmpty);
  });
}
