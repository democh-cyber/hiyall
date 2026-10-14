import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/licenses.dart';

/// The crate names under [dependencies] in rust/Cargo.toml.
Set<String> cargoDependencies() {
  final toml = File('rust/Cargo.toml').readAsLinesSync();
  final names = <String>{};
  var inDeps = false;
  for (final line in toml) {
    final t = line.trim();
    if (t.startsWith('[')) {
      inDeps = t == '[dependencies]';
      continue;
    }
    if (inDeps) {
      final m = RegExp(r'^([A-Za-z0-9_-]+)\s*=').firstMatch(t);
      if (m != null) names.add(m.group(1)!);
    }
  }
  return names;
}

void main() {
  test('every direct Rust dependency has a licence entry', () {
    final listed = {for (final (name, _, _) in rustCrates) name};
    final missing = cargoDependencies().difference(listed);
    expect(missing, isEmpty, reason: 'add them to lib/core/licenses.dart');
    expect(
      listed.difference(cargoDependencies()),
      isEmpty,
      reason: 'stale entries',
    );
  });

  test('every licence text is bundled and non-empty', () {
    for (final (name, licence, asset) in rustCrates) {
      final file = File(asset);
      expect(file.existsSync(), isTrue, reason: '$name: $asset');
      expect(file.readAsStringSync().trim(), isNotEmpty, reason: name);
      expect(licence, isNotEmpty);
    }
    for (final family in fontFamilies) {
      expect(File('assets/fonts/$family-OFL.txt').existsSync(), isTrue);
    }
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('- assets/licenses/'));
  });

  test(
    'vodozemac is Apache-2.0 and its notice reaches the licence page',
    () async {
      LicenseRegistry.reset();
      registerAppLicenses(load: (path) async => File(path).readAsString());
      final entries = <LicenseEntry>[];
      await for (final e in LicenseRegistry.licenses) {
        entries.add(e);
      }
      final names = [for (final e in entries) ...e.packages];
      expect(names, contains('SpaceGrotesk'));
      expect(names, contains('Manrope'));
      final vodozemac = entries.firstWhere(
        (e) => e.packages.any((p) => p.startsWith('vodozemac')),
      );
      final text = vodozemac.paragraphs.map((p) => p.text).join('\n');
      expect(text, contains('Licence: Apache-2.0'));
      expect(text, contains('Apache License'));
      for (final (name, _, _) in rustCrates) {
        expect(names.any((n) => n.startsWith(name)), isTrue, reason: name);
      }
    },
  );
}
