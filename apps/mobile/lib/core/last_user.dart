import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// The id of the account that was signed in last on this phone, kept across launches so that the
/// clean-up of a sign-out that has no session left to name it (a start-up the server refused with a dead
/// credential) still knows whose drafts and choices to remove (see `accountResidueHook`).
///
/// Not a secret: an opaque account id in a small file in the app's private folder, which goes with the
/// app. Written when a session is established, removed when the account's local clean-up is done.
abstract class LastUserStore {
  Future<String?> read();
  Future<void> write(String userId);
  Future<void> clear();
}

class FileLastUserStore implements LastUserStore {
  final Future<Directory> Function() root;
  FileLastUserStore(this.root);

  static const fileName = 'last_user.json';

  Future<File> _file() async => File('${(await root()).path}/$fileName');

  @override
  Future<String?> read() async {
    try {
      final file = await _file();
      if (!await file.exists()) return null;
      final json = jsonDecode(await file.readAsString());
      final id = json is Map ? json['userId'] : null;
      return id is String && id.isNotEmpty ? id : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String userId) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode({'userId': userId}), flush: true);
  }

  @override
  Future<void> clear() async {
    final file = await _file();
    if (await file.exists()) await file.delete();
  }
}

class MemoryLastUserStore implements LastUserStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String userId) async => value = userId;
  @override
  Future<void> clear() async => value = null;
}

/// Where the last signed-in account is remembered. Replaced by memory in tests.
final lastUserStoreProvider = Provider<LastUserStore>(
  (ref) => FileLastUserStore(getApplicationSupportDirectory),
);
