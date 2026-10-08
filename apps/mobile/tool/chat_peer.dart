// A command-line encrypted chat device for local testing, using the same Rust
// core and ChatEngine as the app. Development only: it signs in with the local
// development login and keeps its keys in a local file (mode 600).
//
//   dart run tool/chat_peer.dart --as niko --to anjali --send "hi"
//   dart run tool/chat_peer.dart --as niko --listen 60
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:kairova/core/chat/chat_api.dart';
import 'package:kairova/core/chat/chat_engine.dart';
import 'package:kairova/core/chat/chat_store.dart';
import 'package:kairova/src/rust/frb_generated.dart';

const accounts = {
  'anjali': '019a4000-0000-7000-8000-000000000001',
  'niko': '019a4000-0000-7000-8000-000000000002',
};

class FileChatStore implements ChatStore {
  final File file;
  late final Map<String, String> values = file.existsSync()
      ? Map<String, String>.from(jsonDecode(file.readAsStringSync()) as Map)
      : {};
  FileChatStore(this.file);
  void _flush() {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode(values));
    Process.runSync('chmod', ['600', file.path]);
  }

  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
    _flush();
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
    _flush();
  }
}

String? option(List<String> args, String name) {
  final i = args.indexOf('--$name');
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
}

Future<void> main(List<String> args) async {
  final me = option(args, 'as') ?? 'niko';
  final base = option(args, 'api') ?? 'http://127.0.0.1:8080';
  final userId = accounts[me]!;
  await RustLib.init(externalLibrary: ExternalLibrary.open('rust/target/release/libkairova_e2ee.so'));
  final token = (await Dio().post('$base/dev/session', data: {'userId': userId})).data['data']['accessToken'] as String;
  final engine = ChatEngine(
    userId: userId,
    api: ChatApi(base, token),
    store: FileChatStore(File('../../.runtime/chat-peer-$me.json')),
    // Not 'linux': the live test removes its own linux devices.
    platform: 'unknown',
  );
  await engine.start(poll: Duration.zero);
  String name(String id) => accounts.entries.firstWhere((e) => e.value == id, orElse: () => MapEntry(id, id)).key;
  final printed = <String>{};
  Future<void> show() async {
    for (final c in await engine.conversations()) {
      for (final m in await engine.history(c.id)) {
        if (printed.add(m.messageId)) {
          stdout.writeln('[${m.sentAt.toLocal().toIso8601String().substring(11, 19)}] ${m.notice ? '*' : name(m.senderId)}: ${m.text}');
        }
      }
    }
  }

  await engine.pollNow();
  final to = option(args, 'to'), text = option(args, 'send');
  if (to != null && text != null) {
    final conversation = await engine.open(accounts[to]!);
    await engine.send(conversation, accounts[to]!, text);
  }
  await show();
  final listen = int.tryParse(option(args, 'listen') ?? '0') ?? 0;
  final end = DateTime.now().add(Duration(seconds: listen));
  while (DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(seconds: 2));
    await engine.pollNow();
    await show();
  }
  engine.dispose();
}
