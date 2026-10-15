import 'dart:io';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/services.dart';

import 'chat_local_data.dart';

/// Keeps the chat's three folders (`chat_state`, `chat_blobs`, `chat_outbox`) out of iCloud and iTunes
/// backups. On iOS only: the folders are created here and flagged by a small native handler
/// (`ios/Runner/AppDelegate.swift`, channel `app.hiyall/backup`, which sets `isExcludedFromBackup` on each).
/// Android excludes them through its backup rules. Call it after the folders may have been deleted (a
/// sign-out wipe removes them) and before anything is written into them. Never throws: a phone that cannot
/// set the flag still chats, and the keys that open the files stay this-device-only either way.
class ChatBackupExclusion {
  const ChatBackupExclusion._();

  static const channel = MethodChannel('app.hiyall/backup');

  static Future<void> apply(Directory root) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    try {
      final paths = <String>[];
      for (final name in ChatLocalData.folders) {
        final dir = Directory('${root.path}/$name');
        await dir.create(recursive: true);
        paths.add(dir.path);
      }
      await channel.invokeMethod<void>('excludeFromBackup', paths);
    } on MissingPluginException {
      // A build without the handler.
    } on PlatformException {
      // Flagged next launch.
    } on FileSystemException {
      // The engine creates the folders itself later.
    }
  }
}
