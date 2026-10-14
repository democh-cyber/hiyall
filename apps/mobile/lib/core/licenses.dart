import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Open-source notices shown by Settings → Open-source licences (Flutter's
/// own licence page lists every Dart and Flutter package automatically).
/// This adds what Flutter cannot see: the fonts and the Rust crates linked
/// into the chat encryption library (`apps/mobile/rust/Cargo.toml`).
///
/// Keep [rustCrates] in step with Cargo.toml; `test/licenses_test.dart`
/// fails when a dependency there is missing here.
const rustCrates = <(String name, String licence, String text)>[
  ('vodozemac', 'Apache-2.0', 'assets/licenses/Apache-2.0.txt'),
  ('flutter_rust_bridge', 'MIT', 'assets/licenses/MIT.txt'),
  (
    'x25519-dalek',
    'BSD-3-Clause',
    'assets/licenses/x25519-dalek-BSD-3-Clause.txt',
  ),
  ('rand_core', 'MIT OR Apache-2.0', 'assets/licenses/Apache-2.0.txt'),
  ('zeroize', 'Apache-2.0 OR MIT', 'assets/licenses/Apache-2.0.txt'),
  ('aead-stream', 'Apache-2.0 OR MIT', 'assets/licenses/Apache-2.0.txt'),
  ('chacha20poly1305', 'Apache-2.0 OR MIT', 'assets/licenses/Apache-2.0.txt'),
  ('hkdf', 'MIT OR Apache-2.0', 'assets/licenses/Apache-2.0.txt'),
  ('sha2', 'MIT OR Apache-2.0', 'assets/licenses/Apache-2.0.txt'),
  ('image', 'MIT OR Apache-2.0', 'assets/licenses/MIT.txt'),
  ('thumbhash', 'MIT', 'assets/licenses/MIT.txt'),
];

const fontFamilies = ['SpaceGrotesk', 'Manrope'];

/// Registers the fonts and Rust crates with Flutter's [LicenseRegistry].
/// [load] reads a bundled asset; tests pass a fake.
void registerAppLicenses({Future<String> Function(String path)? load}) {
  final read = load ?? rootBundle.loadString;
  LicenseRegistry.addLicense(() async* {
    for (final family in fontFamilies) {
      yield LicenseEntryWithLineBreaks([
        family,
      ], await read('assets/fonts/$family-OFL.txt'));
    }
    for (final (name, licence, asset) in rustCrates) {
      final text = await read(asset);
      yield LicenseEntryWithLineBreaks([
        '$name (Rust, chat encryption)',
      ], 'Licence: $licence\n\n$text');
    }
  });
}
