import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/pulse7.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/core/voice.dart';
import 'package:hiyall/features/pulse/story_extras.dart';
import 'package:hiyall/features/pulse/voice_recorder.dart';

import 'support/scripted_api.dart';
import 'voice_note_test.dart' show FakeFiles, FakePlayer, FakeRecorder;
import 'widget_test.dart' show SignedIn;

// The recorder panel and the voice note on a story, with no microphone, files, audio device or server.

class FakePulse7 extends Pulse7Client {
  FakePulse7() : super(ScriptedApi());
  final uploaded = <Uint8List>[];
  Object? failWith;
  @override
  Future<VoiceUpload> uploadVoice(
    Session s,
    Uint8List bytes, {
    void Function(double progress)? onProgress,
  }) async {
    uploaded.add(bytes);
    final error = failWith;
    if (error != null) {
      failWith = null;
      throw error;
    }
    return const VoiceUpload('m1', 3000, 'https://cdn.test/voice.m4a');
  }
}

Future<(FakeRecorder, FakePulse7, List<VoiceUpload>)> pumpPanel(
  WidgetTester tester, {
  MicAccess access = MicAccess.granted,
  double textScale = 1,
  TextDirection direction = TextDirection.ltr,
}) async {
  final recorder = FakeRecorder()..access = access;
  final server = FakePulse7();
  final attached = <VoiceUpload>[];
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(320, 640);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        noteRecorderProvider.overrideWithValue(recorder),
        noteFilesProvider.overrideWithValue(FakeFiles()),
        notePathProvider.overrideWithValue(() async => '/tmp/note.m4a'),
        clipPlayerFactoryProvider.overrideWithValue(FakePlayer.new),
        pulse7Provider.overrideWithValue(server),
        sessionProvider.overrideWith(SignedIn.new),
        appSettingsOpenerProvider.overrideWithValue(() async {}),
      ],
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: Directionality(textDirection: direction, child: child!),
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: VoiceRecorderPanel(onAttached: attached.add, onClose: () {}),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (recorder, server, attached);
}

void main() {
  testWidgets(
    'record, stop, then use it: the clip is uploaded and handed back',
    (tester) async {
      final (recorder, server, attached) = await pumpPanel(tester);
      await tester.tap(find.byKey(const Key('voice-record')));
      await tester.pump();
      expect(recorder.started, isTrue);
      expect(find.byKey(const Key('voice-countdown')), findsOneWidget);
      // A real second must pass: a recording under one second is refused.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1150)),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.byKey(const Key('voice-stop')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('voice-use')), findsOneWidget);
      await tester.tap(find.byKey(const Key('voice-use')));
      await tester.pumpAndSettle();
      expect(server.uploaded.single, [1, 2, 3]);
      expect(attached.single.mediaId, 'm1');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a denied microphone is explained and offers the settings', (
    tester,
  ) async {
    await pumpPanel(tester, access: MicAccess.denied);
    await tester.tap(find.byKey(const Key('voice-record')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('voice-open-settings')), findsOneWidget);
    expect(find.textContaining('microphone'), findsWidgets);
  });

  testWidgets('a failed upload keeps the recording and Try again sends it', (
    tester,
  ) async {
    final (_, server, attached) = await pumpPanel(tester);
    server.failWith = const ApiFailure(
      'That voice note is longer than a minute.',
      422,
      'VOICE_TOO_LONG',
    );
    await tester.tap(find.byKey(const Key('voice-record')));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1150)),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byKey(const Key('voice-stop')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('voice-use')));
    await tester.pumpAndSettle();
    expect(find.textContaining('longer than a minute'), findsOneWidget);
    expect(attached, isEmpty);
    await tester.tap(find.byKey(const Key('voice-retry')));
    await tester.pumpAndSettle();
    expect(server.uploaded.length, 2);
    expect(attached.single.mediaId, 'm1');
  });

  for (final (name, scale, direction) in [
    ('at text scale 2.0 on a 320 px screen', 2.0, TextDirection.ltr),
    ('right to left', 1.0, TextDirection.rtl),
  ]) {
    testWidgets('the recorder lays out $name', (tester) async {
      await pumpPanel(tester, textScale: scale, direction: direction);
      expect(tester.takeException(), isNull);
      final box = tester.getRect(find.byKey(const Key('voice-record')));
      expect(box.height, greaterThanOrEqualTo(48));
      expect(box.right, lessThanOrEqualTo(320));
      expect(box.left, greaterThanOrEqualTo(0));
    });
  }

  testWidgets(
    'a story with a voice note and a topic shows the player and the label',
    (tester) async {
      final story = Story(
        storyId: 's1',
        body: '',
        background: 'lime',
        audience: 'public',
        createdAt: DateTime.now(),
        expiresAt: DateTime.now().add(const Duration(hours: 5)),
        topic: 'music',
        voice: const PostVoice('m1', 'https://cdn.test/voice.m4a', 12000),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            clipPlayerFactoryProvider.overrideWithValue(FakePlayer.new),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: StoryExtras(story: story, author: 'Niko'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('voice-play-m1')), findsOneWidget);
      expect(find.byKey(const Key('story-topic-s1')), findsOneWidget);
      // Nothing plays until it is tapped.
      expect(FakePlayer.made.where((p) => p.playing), isEmpty);
      await tester.tap(find.byKey(const Key('voice-play-m1')));
      await tester.pump();
      await tester.pump();
      expect(FakePlayer.made.last.playing, isTrue);
    },
  );
}
