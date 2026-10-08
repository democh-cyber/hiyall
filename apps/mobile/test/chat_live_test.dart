import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kairova/core/chat/chat_api.dart';
import 'package:kairova/core/chat/chat_engine.dart';
import 'package:kairova/core/chat/chat_store.dart';
import 'package:kairova/core/state.dart';
import 'package:kairova/src/rust/frb_generated.dart';

const base = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://127.0.0.1:8080',
);

/// End-to-end: three real encrypted clients (Anjali's phone and laptop, Niko's
/// phone) talk through the live API using the compiled Rust core.
/// Run: flutter test test/chat_live_test.dart --dart-define=RUN_LIVE_CHAT_TEST=true
void main() {
  final dio = Dio(BaseOptions(baseUrl: base, contentType: 'application/json'));
  Future<String> login(String id) async =>
      (await dio.post(
            '/dev/session',
            data: {'userId': id},
          )).data['data']['accessToken']
          as String;
  Future<void> call(String token, String method, String path) => dio.request(
    path,
    options: Options(
      method: method,
      headers: {'Authorization': 'Bearer $token'},
    ),
  );

  setUpAll(() async {
    await RustLib.init(
      externalLibrary: ExternalLibrary.open(
        'rust/target/release/libkairova_e2ee.so',
      ),
    );
  });

  test(
    'Anjali and Niko exchange end-to-end encrypted messages across devices',
    () async {
      final anjaliToken = await login(anjaliId),
          nikoToken = await login(nikoId);
      // Remove devices left by earlier test runs (platform "linux"); app devices stay.
      Future<void> revokeTestDevices(String token) async {
        final mine = await dio.get(
          '/v1/me/devices',
          options: Options(headers: {'Authorization': 'Bearer $token'}),
        );
        for (final d in mine.data['data']['items'] as List) {
          if (d['platform'] == 'linux') {
            await call(token, 'DELETE', '/v1/devices/${d['deviceId']}');
          }
        }
      }

      await revokeTestDevices(anjaliToken);
      await revokeTestDevices(nikoToken);
      addTearDown(() async {
        await revokeTestDevices(anjaliToken);
        await revokeTestDevices(nikoToken);
      });
      // Start from a clean, friends-only relationship so the default messagesFrom applies.
      await call(anjaliToken, 'POST', '/v1/users/$nikoId/block');
      await call(anjaliToken, 'DELETE', '/v1/users/$nikoId/block');
      await call(anjaliToken, 'POST', '/v1/users/$nikoId/friend-requests');
      await call(nikoToken, 'POST', '/v1/users/$anjaliId/friend-requests');

      // Every byte the clients send to the server is captured and checked below.
      final wire = <String>[];
      ChatEngine engine(String user, String token, ChatStore store) {
        final client =
            Dio(BaseOptions(baseUrl: base, contentType: 'application/json'))
              ..interceptors.add(
                InterceptorsWrapper(
                  onRequest: (options, handler) {
                    wire.add('${options.path} ${jsonEncode(options.data)}');
                    handler.next(options);
                  },
                  onResponse: (response, handler) {
                    wire.add(jsonEncode(response.data));
                    handler.next(response);
                  },
                ),
              );
        return ChatEngine(
          userId: user,
          api: ChatApi(base, token, dio: client),
          store: store,
          platform: 'linux',
        );
      }

      final phoneStore = MemoryChatStore();
      final anjali = engine(anjaliId, anjaliToken, phoneStore);
      final laptop = engine(anjaliId, await login(anjaliId), MemoryChatStore());
      final niko = engine(nikoId, nikoToken, MemoryChatStore());
      for (final e in [anjali, laptop, niko]) {
        await e.start(poll: Duration.zero);
      }
      final conversation = await anjali.open(nikoId);
      expect(await niko.open(anjaliId), conversation);

      await anjali.send(conversation, nikoId, 'hey niko 👋 this is encrypted');
      await niko.pollNow();
      await laptop.pollNow();
      final nikoView = await niko.history(conversation);
      expect(nikoView.single.text, 'hey niko 👋 this is encrypted');
      expect(nikoView.single.mine, isFalse);
      // Anjali's other device receives her own sent message as hers.
      expect((await laptop.history(conversation)).single.mine, isTrue);

      await niko.send(conversation, anjaliId, 'got it! replying from my side');
      for (final e in [anjali, laptop]) {
        await e.pollNow();
      }
      expect((await anjali.history(conversation)).map((m) => m.text), [
        'hey niko 👋 this is encrypted',
        'got it! replying from my side',
      ]);
      expect(
        (await laptop.history(conversation)).last.text,
        'got it! replying from my side',
      );

      // A burst in both directions keeps ratchets in sync.
      for (var i = 0; i < 5; i++) {
        await anjali.send(conversation, nikoId, 'ping $i');
        await niko.send(conversation, anjaliId, 'pong $i');
      }
      await niko.pollNow();
      await anjali.pollNow();
      final texts = (await niko.history(conversation))
          .map((m) => m.text)
          .toList();
      expect(texts.where((t) => t.startsWith('ping')).length, 5);
      expect(
        (await anjali.history(conversation))
            .where((m) => m.text.startsWith('pong'))
            .length,
        5,
      );
      expect(texts.any((t) => t.contains('couldn’t be decrypted')), isFalse);

      // Restarting the phone from its stored state keeps the session working.
      anjali.dispose();
      final restarted = engine(anjaliId, anjaliToken, phoneStore);
      await restarted.start(poll: Duration.zero);
      expect(restarted.deviceId, anjali.deviceId);
      await restarted.send(conversation, nikoId, 'after restart');
      await niko.pollNow();
      expect((await niko.history(conversation)).last.text, 'after restart');

      // Unread counts come from the relay and clear once Niko reads.
      Future<int> nikoUnread() async => (await niko.conversations())
          .firstWhere((c) => c.id == conversation)
          .unreadCount;
      expect(await nikoUnread(), greaterThan(0));
      await niko.markRead(conversation);
      expect(await nikoUnread(), 0);
      expect(await niko.api.unreadMessages(), 0);
      // Messages carry the relay's time, so read pointers ignore clock skew.
      expect((await niko.history(conversation)).last.serverAt, isNotNull);

      // Every device on both accounts derives the same safety number.
      final fromNiko = await niko.safetyNumber(anjaliId);
      expect(fromNiko, matches(RegExp(r'^\d{60}$')));
      expect(await restarted.safetyNumber(nikoId), fromNiko);
      expect(await laptop.safetyNumber(nikoId), fromNiko);

      // Stored state is encrypted: the pickles never contain the account's keys in clear.
      final pickled = phoneStore.values.entries
          .where((e) => e.key.endsWith('.account'))
          .single
          .value;
      expect(pickled.contains(restarted.identityKey), isFalse);
      // Measured check: no request or response carried any message text.
      expect(wire.length, greaterThan(20));
      for (final text in [
        'hey niko',
        'got it!',
        'ping 3',
        'pong 4',
        'after restart',
      ]) {
        expect(
          wire.where((w) => w.contains(text)),
          isEmpty,
          reason: '"$text" crossed the network in clear',
        );
      }
      for (final e in [restarted, laptop, niko]) {
        e.dispose();
      }
    },
    skip: !const bool.fromEnvironment('RUN_LIVE_CHAT_TEST'),
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
