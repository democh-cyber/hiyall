import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/avatar_upload.dart';
import 'package:hiyall/core/chat/chat_api.dart';
import 'package:hiyall/core/chat/chat_attachment.dart';
import 'package:hiyall/core/chat/chat_av.dart';
import 'package:hiyall/core/chat/chat_av_outbox.dart';
import 'package:hiyall/core/chat/chat_blob_cache.dart';
import 'package:hiyall/core/chat/chat_blob_codec.dart';
import 'package:hiyall/core/chat/chat_engine.dart';
import 'package:hiyall/core/chat/chat_media.dart';
import 'package:hiyall/core/chat/chat_outbox.dart' show TransferProgress;
import 'package:hiyall/core/chat/chat_recorder.dart' show MicPermission;
import 'package:hiyall/core/chat/chat_store.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/core/theme.dart';
import 'package:hiyall/core/translate/fake_translation_service.dart';
import 'package:hiyall/core/translate/speech_service.dart';
import 'package:hiyall/features/chat.dart';
import 'package:hiyall/features/chat_av_providers.dart';
import 'package:hiyall/features/chat_format.dart';
import 'package:hiyall/features/chat_photo.dart';
import 'package:hiyall/features/chat_translate_ui.dart';
import 'package:hiyall/features/chat_video_ui.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'avatar_helpers.dart' show pngBytes;
import 'chat_av_helpers.dart';
import 'chat_photo_helpers.dart';
import 'widget_test.dart' show SignedIn;

/// Renders the new chat screens with made-up data and writes PNGs to `.runtime/chat-previews-v7/`
/// (git-ignored). Skipped unless run with `--dart-define=CAPTURE_CHAT=true`.
const capturing = bool.fromEnvironment('CAPTURE_CHAT');

class AvUiCloud extends FakeCloud {
  Map<String, dynamic> receipt = {};
  final mutes = <String>[];
  @override
  Future<Map<String, dynamic>> conversation(String id) async => receipt;
  @override
  Future<int> unreadMessages() async => 0;
  @override
  Future<void> muteConversation(
    String id,
    bool muted, {
    DateTime? until,
  }) async => mutes.add('$id ${muted ? 'on' : 'off'}');
}

/// Hands out bytes per role instead of the network and records what was asked for.
class ScriptedAvMedia extends ChatMedia {
  ScriptedAvMedia(FakeCloud cloud, Directory dir)
    : super(
        api: cloud,
        transport: cloud,
        codec: FakeCodec(),
        cache: ChatBlobCache(Directory('${dir.path}/chat_blobs')),
      );
  final requested = <String>[];
  Object Function(BlobSpec spec) respond = (_) => Uint8List.fromList([1, 2, 3]);
  Completer<void>? hold;

  @override
  Future<Uint8List> plaintextBlob(
    String conversationId,
    BlobSpec spec, {
    void Function(double progress)? onProgress,
  }) async {
    requested.add(spec.role);
    onProgress?.call(.5);
    await hold?.future;
    final out = respond(spec);
    if (out is Uint8List) return out;
    throw out;
  }
}

class AvUiEngine extends ChatEngine {
  AvUiEngine(this.cloud, Directory root, ScriptedAvMedia media)
    : super(
        userId: meId,
        api: cloud,
        store: MemoryChatStore(),
        codec: AvCodec(),
        mediaRoot: root,
        media: media,
      );
  final AvUiCloud cloud;
  List<ChatMessage> messages = [];
  final byConversation = <String, List<ChatMessage>>{};
  List<ChatConversation> list = [];
  List<ChatConversation> deleted = [];
  final ctrl = StreamController<String>.broadcast();
  final voices = <VoiceClip>[];
  final videos = <PreparedVideo>[];
  final retried = <String>[], discarded = <String>[];
  final pinned = <String>[], hidden = <String>[], restored = <String>[];
  final progress = <String, TransferProgress>{};
  Object? pinFailure;

  @override
  Stream<String> get changes => ctrl.stream;
  @override
  Future<List<ChatMessage>> history(String id) async =>
      byConversation[id] ?? (id == conv ? messages : const []);
  @override
  Future<List<ChatConversation>> conversations({int limit = 50}) async => list;
  @override
  Future<void> pollNow() async {}
  @override
  Future<void> markRead(String conversationId) async {}

  @override
  Future<ChatMessage> sendVoice(
    String conversationId,
    String peerId,
    VoiceClip clip, {
    ChatMessage? replyTo,
  }) async {
    voices.add(clip);
    return _sent();
  }

  @override
  Future<ChatMessage> sendVideo(
    String conversationId,
    String peerId,
    PreparedVideo video, {
    ChatMessage? replyTo,
  }) async {
    videos.add(video);
    return _sent();
  }

  ChatMessage _sent() => ChatMessage(
    messageId: 'new',
    senderId: meId,
    text: 'x',
    sentAt: DateTime.now().toUtc(),
    mine: true,
  );

  @override
  Future<void> retryAv(String conversationId, String messageId) async =>
      retried.add(messageId);
  @override
  Future<void> discardAv(String conversationId, String messageId) async =>
      discarded.add(messageId);
  @override
  TransferProgress? avProgress(String messageId) => progress[messageId];
  @override
  Uint8List? localPoster(String messageId) => null;

  @override
  Future<void> pinConversation(String id, bool pin) async {
    if (pinFailure != null) throw pinFailure!;
    pinned.add('$id ${pin ? 'on' : 'off'}');
  }

  @override
  Future<void> hideConversation(String id) async => hidden.add(id);
  @override
  Future<void> restoreConversation(String id) async => restored.add(id);
  @override
  Future<List<ChatConversation>> hiddenConversations() async => deleted;
}

final fixedNow = DateTime(2026, 10, 18, 15, 30);
DateTime when(int h, int m, {int daysAgo = 0}) =>
    DateTime(2026, 10, 18 - daysAgo, h, m);

/// A canonical message id for a short name (the menu only acts on delivered messages with real ids).
String fid(String s) {
  final hex = s.codeUnits
      .map((c) => c.toRadixString(16))
      .join()
      .padRight(12, '0');
  return '6d6d0000-0000-4000-8000-${hex.substring(0, 12)}';
}

ChatMessage text(String id, String body, DateTime at, {bool mine = false}) =>
    ChatMessage(
      messageId: fid(id),
      senderId: mine ? meId : peerId,
      text: body,
      sentAt: at,
      serverAt: at.toUtc(),
      mine: mine,
    );

ChatMessage voiceMsg(
  String id, {
  bool mine = false,
  SendStatus status = SendStatus.sent,
  Map<String, dynamic>? descriptor,
  bool unsupported = false,
  String? failure,
}) => ChatMessage(
  messageId: id,
  senderId: mine ? meId : peerId,
  text: voiceFallbackText,
  sentAt: when(9, 0),
  serverAt: status == SendStatus.sent ? when(9, 0).toUtc() : null,
  mine: mine,
  status: status,
  failure: failure,
  voice: unsupported
      ? null
      : VoiceAttachment.parse(descriptor ?? voiceDescriptor()),
  unsupportedKind: unsupported ? 'voice' : null,
);

ChatMessage videoMsg(
  String id, {
  bool mine = false,
  SendStatus status = SendStatus.sent,
  bool unsupported = false,
}) => ChatMessage(
  messageId: id,
  senderId: mine ? meId : peerId,
  text: videoFallbackText,
  sentAt: when(9, 5),
  serverAt: status == SendStatus.sent ? when(9, 5).toUtc() : null,
  mine: mine,
  status: status,
  video: unsupported ? null : VideoAttachment.parse(videoDescriptor()),
  unsupportedKind: unsupported ? 'video' : null,
);

ChatConversation chat(
  int n,
  String name,
  ChatMessage? last, {
  int unread = 0,
  bool pinned = false,
  bool muted = false,
  DateTime? restoreUntil,
}) => ChatConversation(
  '00000000-0000-4000-8000-0000000000${(n + 10).toString().padLeft(2, '0')}',
  '019a4000-0000-7000-8000-0000000001${n.toString().padLeft(2, '0')}',
  name,
  name.toLowerCase(),
  last,
  unreadCount: unread,
  pinnedAt: pinned ? DateTime.utc(2026, 10, 1) : null,
  mutedUntil: muted ? DateTime.now().add(const Duration(days: 1)) : null,
  hiddenAt: restoreUntil == null ? null : DateTime.utc(2026, 10, 10),
  restoreUntil: restoreUntil,
);

class VideoPicker extends ImagePicker {
  String? path = '/tmp/picked.mp4';
  final sources = <ImageSource>[];
  Duration? maxDuration;
  @override
  Future<XFile?> pickVideo({
    required ImageSource source,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    Duration? maxDuration,
  }) async {
    sources.add(source);
    this.maxDuration = maxDuration;
    return path == null ? null : XFile(path!);
  }
}

void main() {
  late AvUiCloud cloud;
  late AvUiEngine engine;
  late ScriptedAvMedia media;
  late Directory root;
  late FakeRecorder recorder;
  late List<FakePlayer> players;
  late FakeVideoPlayer videoPlayer;
  late FakePreparer preparer;
  late FakeTranslationService translator;
  late FakeSpeechService speech;
  late VideoPicker picker;
  late ui.Image base;
  final captureKey = GlobalKey();

  setUpAll(() async {
    await initializeDateFormatting('de');
  });

  void spec(String name, Future<void> Function(WidgetTester tester) body) =>
      testWidgets(name, (tester) async {
        cloud = AvUiCloud();
        root = Directory.systemTemp.createTempSync('hiyall_av_ui');
        media = ScriptedAvMedia(cloud, root);
        engine = AvUiEngine(cloud, root, media);
        recorder = FakeRecorder();
        players = [];
        videoPlayer = FakeVideoPlayer();
        preparer = FakePreparer();
        translator = FakeTranslationService();
        speech = FakeSpeechService();
        picker = VideoPicker();
        addTearDown(() => root.deleteSync(recursive: true));
        await body(tester);
      });

  void bothWays(
    String name,
    Future<void> Function(WidgetTester tester, bool rtl) body,
  ) {
    spec('$name (left to right)', (tester) => body(tester, false));
    spec('$name (right to left)', (tester) => body(tester, true));
  }

  Future<void> pump(
    WidgetTester tester,
    Widget screen, {
    Size size = const Size(390, 844),
    bool dark = true,
    double textScale = 1,
    bool rtl = false,
    Locale? locale,
    bool settle = true,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    base = (await tester.runAsync(() => decodeImageFromList(pngBytes)))!;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatEngineProvider.overrideWith((ref) async => engine),
          sessionProvider.overrideWith(SignedIn.new),
          chatImagesProvider.overrideWithValue(_Images(base)),
          chatClockProvider.overrideWithValue(() => fixedNow),
          voiceRecorderProvider.overrideWithValue(recorder),
          voicePlayerFactoryProvider.overrideWithValue(() {
            final p = FakePlayer();
            players.add(p);
            return p;
          }),
          chatVideoPlayerFactoryProvider.overrideWithValue(() => videoPlayer),
          videoPreparerProvider.overrideWithValue(preparer),
          translationServiceProvider.overrideWithValue(translator),
          speechServiceProvider.overrideWithValue(speech),
          imagePickerProvider.overrideWithValue(picker),
        ],
        child: RepaintBoundary(
          key: captureKey,
          child: MaterialApp(
            locale: locale,
            supportedLocales: const [Locale('en', 'US'), Locale('de')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            theme: hiyallTheme(dark ? Brightness.dark : Brightness.light),
            builder: (context, child) => Directionality(
              textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
              child: MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(textScale),
                  disableAnimations: true,
                ),
                child: child!,
              ),
            ),
            home: Scaffold(body: screen),
          ),
        ),
      ),
    );
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }
  }

  Future<void> openConversation(
    WidgetTester tester,
    List<ChatMessage> messages, {
    Size size = const Size(390, 844),
    double textScale = 1,
    bool rtl = false,
    bool dark = true,
    Locale? locale,
    bool settle = true,
  }) async {
    engine.messages = messages;
    await pump(
      tester,
      const ConversationScreen(id: conv, peerId: peerId, peerName: 'Niko'),
      size: size,
      textScale: textScale,
      rtl: rtl,
      dark: dark,
      locale: locale,
      settle: settle,
    );
  }

  Future<void> openList(
    WidgetTester tester,
    List<ChatConversation> list, {
    Size size = const Size(390, 844),
    double textScale = 1,
    bool rtl = false,
  }) async {
    engine.list = list;
    await pump(
      tester,
      const ChatsScreen(),
      size: size,
      textScale: textScale,
      rtl: rtl,
    );
  }

  /// Lets real file and platform futures (the temp files, the fake plugins) finish.
  Future<void> realWork(WidgetTester tester, [int ms = 240]) async {
    await tester.pump(const Duration(milliseconds: 350));
    // Each real file operation completes on the real clock and its continuation runs on the next pump.
    for (var i = 0; i < ms ~/ 4; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 6)),
      );
      await tester.pump(const Duration(milliseconds: 5));
    }
  }

  Future<void> shoot(WidgetTester tester, String name) async {
    if (!capturing) return;
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 250)),
    );
    await tester.pumpAndSettle();
    void repaint(RenderObject render) {
      render.markNeedsPaint();
      render.visitChildren(repaint);
    }

    repaint(captureKey.currentContext!.findRenderObject()!);
    await tester.pump();
    await tester.runAsync(() async {
      final boundary =
          captureKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final img = await boundary.toImage(pixelRatio: 2);
      final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
      final file = File('../../.runtime/chat-previews-v7/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    });
  }

  const v1 = '6d6d0000-0000-4000-8000-000000000011';
  const v2 = '6d6d0000-0000-4000-8000-000000000012';
  const vd = '6d6d0000-0000-4000-8000-000000000013';

  // -------------------------------------------------------------- voice

  group('voice messages', () {
    spec('a received voice message shows its length and plays on tap', (
      tester,
    ) async {
      await openConversation(tester, [voiceMsg(v1)]);
      expect(find.byKey(const Key('voice-play-$v1')), findsOneWidget);
      expect(find.text('0:23'), findsWidgets);
      expect(find.byKey(const Key('voice-speed-$v1')), findsNothing);
      await shoot(tester, 'voice-incoming');
      await tester.tap(find.byKey(const Key('voice-play-$v1')));
      await realWork(tester);
      expect(media.requested, ['voice']);
      expect(players.single.isPlaying, isTrue);
      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
      // The time counts up while it plays.
      players.single.tickTo(const Duration(seconds: 7));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('voice-time-$v1')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('voice-time-$v1'))).data,
        '0:07',
      );
      await shoot(tester, 'voice-playing');
      await tester.tap(find.byKey(const Key('voice-play-$v1')));
      await tester.pump();
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      expect(players.single.isPlaying, isFalse);
    });

    spec('speed cycles 1x, 1.5x, 2x and the label says so', (tester) async {
      await openConversation(tester, [voiceMsg(v1)]);
      await tester.tap(find.byKey(const Key('voice-play-$v1')));
      await realWork(tester);
      expect(find.text('1x'), findsOneWidget);
      await tester.tap(find.byKey(const Key('voice-speed-$v1')));
      await tester.pump();
      expect(find.text('1.5x'), findsOneWidget);
      await tester.tap(find.byKey(const Key('voice-speed-$v1')));
      await tester.pump();
      expect(find.text('2x'), findsOneWidget);
      expect(players.single.speeds, containsAllInOrder([1.5, 2.0]));
      await tester.tap(find.byKey(const Key('voice-speed-$v1')));
      await tester.pump();
      expect(find.text('1x'), findsOneWidget);
    });

    spec('only one plays at a time', (tester) async {
      await openConversation(tester, [voiceMsg(v1), voiceMsg(v2)]);
      await tester.tap(find.byKey(const Key('voice-play-$v1')));
      await realWork(tester, 400);
      await tester.tap(find.byKey(const Key('voice-play-$v2')));
      await realWork(tester, 400);
      expect(players, hasLength(2));
      expect(players.first.disposed, isTrue);
      expect(players.last.isPlaying, isTrue);
      expect(find.byKey(const Key('voice-speed-$v1')), findsNothing);
      expect(find.byKey(const Key('voice-speed-$v2')), findsOneWidget);
    });

    spec('the system taking the audio away leaves it paused', (tester) async {
      await openConversation(tester, [voiceMsg(v1)]);
      await tester.tap(find.byKey(const Key('voice-play-$v1')));
      await realWork(tester);
      players.single.interrupt();
      await tester.pump();
      await tester.pump();
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    });

    spec(
      'an expired or damaged voice message says so, and a network error can be tried again',
      (tester) async {
        await openConversation(tester, [voiceMsg(v1)]);
        media.respond = (_) => const ChatMediaFailure(MediaProblem.unavailable);
        await tester.tap(find.byKey(const Key('voice-play-$v1')));
        await realWork(tester);
        expect(find.text('This voice message has expired'), findsOneWidget);
        media.respond = (_) => const ChatMediaFailure(MediaProblem.corrupt);
        await tester.tap(find.byKey(const Key('voice-problem-$v1')));
        await realWork(tester);
        expect(find.text('Can’t play this voice message'), findsOneWidget);
        media.respond = (_) => const ChatMediaFailure(MediaProblem.network);
        await tester.tap(find.byKey(const Key('voice-problem-$v1')));
        await realWork(tester);
        expect(find.textContaining('Tap to try again'), findsOneWidget);
        media.respond = (_) => Uint8List.fromList([1, 2, 3]);
        await tester.tap(find.byKey(const Key('voice-problem-$v1')));
        await realWork(tester);
        expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
      },
    );

    spec(
      'your own voice message: sending shows progress and cannot play, a failed one can be retried or deleted',
      (tester) async {
        engine.progress[v1] = TransferProgress()..update(.4);
        await openConversation(tester, [
          voiceMsg(v1, mine: true, status: SendStatus.sending),
          voiceMsg(
            v2,
            mine: true,
            status: SendStatus.failed,
            failure: 'ATTACHMENTS_NOT_ALLOWED',
          ),
        ], settle: false);
        await tester.tap(
          find.byKey(const Key('voice-play-$v1')),
          warnIfMissed: false,
        );
        await tester.pump();
        expect(media.requested, isEmpty);
        expect(
          find.text(
            'You can send photos, voice messages and videos once they reply.',
          ),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('av-send-retry-$v2')));
        await tester.pump();
        expect(engine.retried, [v2]);
        await tester.tap(find.byKey(const Key('av-delete-$v2')));
        await tester.pump();
        expect(engine.discarded, [v2]);
      },
    );

    spec('a voice message this app cannot read is shown as unsupported', (
      tester,
    ) async {
      await openConversation(tester, [voiceMsg(v1, unsupported: true)]);
      expect(find.byKey(const Key('voice-unsupported')), findsOneWidget);
      expect(find.text('Unsupported voice message'), findsOneWidget);
    });

    spec(
      'long-pressing a voice message offers reply but not copy, read aloud or translate',
      (tester) async {
        await openConversation(tester, [voiceMsg(v1)]);
        await tester.longPress(find.byKey(const Key('voice-wave-$v1')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('menu-reply')), findsOneWidget);
        expect(find.byKey(const Key('menu-copy')), findsNothing);
        expect(find.byKey(const Key('menu-read-aloud')), findsNothing);
        expect(find.byKey(const Key('menu-translate')), findsNothing);
      },
    );
  });

  // ---------------------------------------------------------- recording

  group('recording', () {
    spec(
      'the microphone shows when the field is empty and gives way to send when typing',
      (tester) async {
        await openConversation(tester, [text('a', 'hi', when(9, 0))]);
        expect(find.byKey(const Key('chat-mic')), findsOneWidget);
        await tester.enterText(find.byKey(const Key('chat-input')), 'hello');
        await tester.pump();
        expect(find.byKey(const Key('chat-mic')), findsNothing);
        expect(find.byKey(const Key('chat-send')), findsOneWidget);
        await tester.enterText(find.byKey(const Key('chat-input')), '');
        await tester.pump();
        expect(find.byKey(const Key('chat-mic')), findsOneWidget);
      },
    );

    spec('a tap starts a recording that goes on; send posts it', (
      tester,
    ) async {
      await openConversation(tester, [text('a', 'hi', when(9, 0))]);
      await tester.tap(find.byKey(const Key('chat-mic')));
      await realWork(tester);
      expect(find.byKey(const Key('recording-bar')), findsOneWidget);
      expect(find.byKey(const Key('record-dot')), findsOneWidget);
      expect(find.byKey(const Key('chat-input')), findsNothing);
      expect(find.byKey(const Key('record-send')), findsOneWidget);
      recorder
        ..level(.3)
        ..level(.8);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1250)),
      );
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.byKey(const Key('record-time')), findsOneWidget);
      await shoot(tester, 'recording-locked');
      await tester.tap(find.byKey(const Key('record-send')));
      await realWork(tester);
      expect(engine.voices, hasLength(1));
      expect(engine.voices.single.durationMs, greaterThanOrEqualTo(1000));
      expect(engine.voices.single.bytes, recorder.audio);
      expect(find.byKey(const Key('recording-bar')), findsNothing);
      expect(find.byKey(const Key('chat-input')), findsOneWidget);
    });

    spec('the bin cancels and nothing is sent', (tester) async {
      await openConversation(tester, [text('a', 'hi', when(9, 0))]);
      await tester.tap(find.byKey(const Key('chat-mic')));
      await realWork(tester);
      await tester.tap(find.byKey(const Key('record-cancel')));
      await realWork(tester);
      expect(engine.voices, isEmpty);
      expect(recorder.cancels, 1);
      expect(find.byKey(const Key('recording-bar')), findsNothing);
    });

    spec('hold to record, let go to send', (tester) async {
      await openConversation(tester, [text('a', 'hi', when(9, 0))]);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('chat-mic'))),
      );
      await tester.pump(const Duration(milliseconds: 700));
      await realWork(tester);
      expect(find.byKey(const Key('recording-bar')), findsOneWidget);
      expect(find.byKey(const Key('record-hint')), findsOneWidget);
      expect(find.text('Slide to cancel'), findsOneWidget);
      expect(find.byKey(const Key('record-send')), findsNothing);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1200)),
      );
      await gesture.up();
      // The file work runs on the real clock: under load it takes longer, so wait for the result.
      for (var i = 0; i < 20 && engine.voices.isEmpty; i++) {
        await realWork(tester);
      }
      expect(engine.voices, hasLength(1));
      expect(find.byKey(const Key('recording-bar')), findsNothing);
    });

    spec('hold and slide away cancels; hold and slide up locks', (
      tester,
    ) async {
      await openConversation(tester, [text('a', 'hi', when(9, 0))]);
      var gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('chat-mic'))),
      );
      await tester.pump(const Duration(milliseconds: 700));
      await realWork(tester);
      await gesture.moveBy(const Offset(-60, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(-80, 0));
      await realWork(tester);
      await gesture.up();
      await realWork(tester);
      expect(engine.voices, isEmpty);
      expect(find.byKey(const Key('recording-bar')), findsNothing);
      // Up: locked, the finger can lift.
      gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('chat-mic'))),
      );
      await tester.pump(const Duration(milliseconds: 700));
      await realWork(tester);
      await gesture.moveBy(const Offset(0, -50));
      await gesture.moveBy(const Offset(0, -40));
      await tester.pump();
      await gesture.up();
      await realWork(tester);
      expect(find.byKey(const Key('recording-bar')), findsOneWidget);
      expect(find.byKey(const Key('record-send')), findsOneWidget);
      await tester.tap(find.byKey(const Key('record-cancel')));
      await realWork(tester);
    });

    spec('in a right-to-left language sliding right cancels', (tester) async {
      await openConversation(tester, [text('a', 'hi', when(9, 0))], rtl: true);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const Key('chat-mic'))),
      );
      await tester.pump(const Duration(milliseconds: 700));
      await realWork(tester);
      await gesture.moveBy(const Offset(60, 0));
      await gesture.moveBy(const Offset(80, 0));
      await realWork(tester);
      await gesture.up();
      await realWork(tester);
      expect(engine.voices, isEmpty);
      expect(find.byKey(const Key('recording-bar')), findsNothing);
    });

    spec(
      'a quick tap-and-release that records under a second says how to use it',
      (tester) async {
        await openConversation(tester, [text('a', 'hi', when(9, 0))]);
        final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(const Key('chat-mic'))),
        );
        await tester.pump(const Duration(milliseconds: 700));
        await realWork(tester);
        await gesture.up();
        await realWork(tester);
        expect(engine.voices, isEmpty);
        expect(find.textContaining('Hold the microphone'), findsOneWidget);
      },
    );

    spec('a refused microphone says where to allow it', (tester) async {
      recorder.permissionAnswer = MicPermission.denied;
      await openConversation(tester, [text('a', 'hi', when(9, 0))]);
      await tester.tap(find.byKey(const Key('chat-mic')));
      await realWork(tester);
      expect(find.textContaining('needs the microphone'), findsOneWidget);
      expect(find.byKey(const Key('recording-bar')), findsNothing);
    });

    bothWays('the recording bar fits 320 px at text x2.0', (tester, rtl) async {
      {
        await openConversation(
          tester,
          [text('a', 'hi', when(9, 0))],
          size: const Size(320, 640),
          textScale: 2,
          rtl: rtl,
        );
        await tester.tap(find.byKey(const Key('chat-mic')));
        await realWork(tester);
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('recording-bar')), findsOneWidget);
        for (final key in ['record-cancel', 'record-send']) {
          final size = tester.getSize(find.byKey(Key(key)));
          expect(size.width, greaterThanOrEqualTo(48), reason: key);
          expect(size.height, greaterThanOrEqualTo(48), reason: key);
        }
        await tester.tap(find.byKey(const Key('record-cancel')));
        await realWork(tester);
      }
    });
  });

  // -------------------------------------------------------------- video

  group('videos', () {
    spec('a received video shows its poster, length and a play badge', (
      tester,
    ) async {
      await openConversation(tester, [videoMsg(vd)]);
      await realWork(tester);
      expect(find.byKey(const Key('video-$vd')), findsOneWidget);
      expect(find.byKey(const Key('video-length-$vd')), findsOneWidget);
      expect(find.text('0:12'), findsWidgets);
      expect(find.byKey(const Key('video-play-badge')), findsOneWidget);
      expect(media.requested, [
        'thumb',
      ], reason: 'only the poster until it is opened');
      await shoot(tester, 'video-bubble');
    });

    spec(
      'tapping opens the player, which fetches the video and plays it; close removes the file',
      (tester) async {
        await openConversation(tester, [videoMsg(vd)]);
        await realWork(tester);
        await tester.tap(find.byKey(const Key('video-$vd')));
        await tester.pumpAndSettle();
        await realWork(tester, 480);
        expect(media.requested, ['thumb', 'video']);
        expect(find.byKey(const Key('fake-video-surface')), findsOneWidget);
        expect(videoPlayer.playing, isTrue);
        expect(videoPlayer.opened, isNotNull);
        expect(
          videoPlayer.opened!.existsSync(),
          isTrue,
          reason: 'the decrypted file exists while the viewer is open',
        );
        await shoot(tester, 'video-viewer');
        await tester.tap(find.byKey(const Key('video-play-pause')));
        await tester.pump();
        expect(videoPlayer.playing, isFalse);
        await tester.tap(find.byKey(const Key('video-surface')));
        await tester.pump();
        expect(videoPlayer.playing, isTrue);
        videoPlayer.end();
        await tester.pump();
        expect(find.byIcon(Icons.replay_rounded), findsOneWidget);
        final file = videoPlayer.opened!;
        await tester.tap(find.byKey(const Key('video-viewer-close')));
        await tester.pumpAndSettle();
        await realWork(tester);
        expect(
          file.existsSync(),
          isFalse,
          reason: 'closing the viewer deletes the plaintext',
        );
      },
    );

    spec(
      'an expired or damaged video says so in the viewer and offers retry for network errors',
      (tester) async {
        await openConversation(tester, [videoMsg(vd)]);
        await realWork(tester);
        media.respond = (spec) => spec.role == 'video'
            ? const ChatMediaFailure(MediaProblem.unavailable)
            : Uint8List(3);
        await tester.tap(find.byKey(const Key('video-$vd')));
        await tester.pumpAndSettle();
        await realWork(tester);
        expect(find.byKey(const Key('video-viewer-note')), findsOneWidget);
        expect(find.textContaining('expired'), findsOneWidget);
        await tester.tap(find.byKey(const Key('video-viewer-close')));
        await tester.pumpAndSettle();
        media.respond = (spec) => spec.role == 'video'
            ? const ChatMediaFailure(MediaProblem.network)
            : Uint8List(3);
        await tester.tap(find.byKey(const Key('video-$vd')));
        await tester.pumpAndSettle();
        await realWork(tester);
        expect(find.byKey(const Key('video-viewer-retry')), findsOneWidget);
        media.respond = (_) => Uint8List.fromList([1, 2, 3]);
        await tester.tap(find.byKey(const Key('video-viewer-retry')));
        await realWork(tester, 480);
        expect(videoPlayer.playing, isTrue);
      },
    );

    spec(
      'your own video: sending shows the cancel ring; failed shows retry and delete',
      (tester) async {
        engine.progress[vd] = TransferProgress()..update(.5);
        const failed = '6d6d0000-0000-4000-8000-000000000014';
        await openConversation(tester, [
          videoMsg(vd, mine: true, status: SendStatus.sending),
          videoMsg(failed, mine: true, status: SendStatus.failed),
        ], settle: false);
        expect(find.byKey(const Key('video-sending-$vd')), findsOneWidget);
        expect(find.byKey(const Key('video-failed-$failed')), findsOneWidget);
        await tester.tap(find.byKey(const Key('av-send-retry-$failed')));
        await tester.pump();
        expect(engine.retried, [failed]);
      },
    );

    spec('an unsupported video is a plain line', (tester) async {
      await openConversation(tester, [videoMsg(vd, unsupported: true)]);
      expect(find.byKey(const Key('video-unsupported')), findsOneWidget);
    });

    spec(
      'the attach menu offers videos; picking one prepares it and sends it',
      (tester) async {
        await openConversation(tester, [text('a', 'hi', when(9, 0))]);
        await tester.tap(find.byKey(const Key('chat-attach')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('attach-video-gallery')), findsOneWidget);
        expect(find.text('Up to 1 minute'), findsWidgets);
        await tester.tap(find.byKey(const Key('attach-video-gallery')));
        await tester.pumpAndSettle();
        await realWork(tester);
        expect(picker.sources, [ImageSource.gallery]);
        expect(picker.maxDuration, const Duration(minutes: 1));
        expect(preparer.paths, ['/tmp/picked.mp4']);
        expect(engine.videos, hasLength(1));
        expect(engine.videos.single.w, 1280);
      },
    );

    spec(
      'while a video is prepared a calm dialog shows, and a failure is explained',
      (tester) async {
        await openConversation(tester, [text('a', 'hi', when(9, 0))]);
        preparer.gate = Completer<void>();
        await tester.tap(find.byKey(const Key('chat-attach')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('attach-video-gallery')));
        await tester.pumpAndSettle();
        await realWork(tester);
        expect(find.byKey(const Key('preparing-video')), findsOneWidget);
        expect(find.text('Preparing your video'), findsOneWidget);
        await shoot(tester, 'video-preparing');
        preparer.failure = const ChatFailure(
          'VIDEO_LENGTH',
          'Videos can be up to 1 minute long. Pick a shorter one.',
        );
        preparer.gate!.complete();
        await realWork(tester);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('preparing-video')), findsNothing);
        expect(
          find.text('Videos can be up to 1 minute long. Pick a shorter one.'),
          findsOneWidget,
        );
        expect(engine.videos, isEmpty);
      },
    );

    spec('backing out of the picker does nothing', (tester) async {
      picker.path = null;
      await openConversation(tester, [text('a', 'hi', when(9, 0))]);
      await tester.tap(find.byKey(const Key('chat-attach')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('attach-video-gallery')));
      await tester.pumpAndSettle();
      expect(preparer.paths, isEmpty);
    });

    bothWays(
      'voice, video and photo bubbles fit 320 px at text x2.0, left to right and right to left',
      (tester, rtl) async {
        {
          await openConversation(
            tester,
            [
              voiceMsg(v1),
              voiceMsg(v2, mine: true),
              videoMsg(vd),
              videoMsg('6d6d0000-0000-4000-8000-000000000015', mine: true),
            ],
            size: const Size(320, 700),
            textScale: 2,
            rtl: rtl,
          );
          await realWork(tester);
          expect(tester.takeException(), isNull, reason: 'rtl $rtl');
          await tester.tap(find.byKey(const Key('voice-play-$v1')));
          await realWork(tester);
          expect(tester.takeException(), isNull, reason: 'playing, rtl $rtl');
          for (final key in ['voice-play-$v1', 'voice-speed-$v1']) {
            final size = tester.getSize(find.byKey(Key(key)));
            expect(size.shortestSide, greaterThanOrEqualTo(44), reason: key);
          }
          await shoot(tester, rtl ? 'bubbles-rtl-320-x2' : 'bubbles-320-x2');
        }
      },
    );
  });

  // ------------------------------------------- translate and read aloud

  group('message actions', () {
    const hola = 'Hola, ¿quedamos a las ocho?';
    final incoming = text('m1', hola, when(9, 0));

    spec('the menu offers Copy, Read aloud and Translate on a text message', (
      tester,
    ) async {
      await openConversation(tester, [incoming]);
      await tester.longPress(find.text(hola));
      await tester.pumpAndSettle();
      for (final key in [
        'menu-reply',
        'menu-copy',
        'menu-read-aloud',
        'menu-translate',
      ]) {
        expect(find.byKey(Key(key)), findsOneWidget, reason: key);
      }
      await shoot(tester, 'message-menu');
    });

    spec(
      'translate: the first use explains the pack, downloads it on the phone and shows the translation',
      (tester) async {
        translator = FakeTranslationService(detects: {hola: 'es'});
        await openConversation(tester, [incoming]);
        await tester.longPress(find.text(hola));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('menu-translate')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('translate-consent')), findsOneWidget);
        expect(find.textContaining('runs on your phone'), findsOneWidget);
        expect(find.textContaining('never leave it'), findsOneWidget);
        expect(find.textContaining('about 30 MB'), findsOneWidget);
        expect(
          translator.downloads,
          isEmpty,
          reason: 'nothing is downloaded before the person agrees',
        );
        await shoot(tester, 'translate-consent');
        await tester.tap(find.byKey(const Key('translate-download')));
        await tester.pumpAndSettle();
        await realWork(tester);
        expect(translator.downloads, ['es']);
        expect(find.byKey(const Key('translation-text')), findsOneWidget);
        expect(find.text('[en] $hola'), findsOneWidget);
        expect(
          find.textContaining('Translated from Spanish on your phone'),
          findsOneWidget,
        );
        expect(
          await engine.prefs.read().then((p) => p.translateConsent),
          isTrue,
        );
        await shoot(tester, 'translated-message');
        // The text of the chat reached no network call.
        expect(cloud.calls, isEmpty);
        // The menu now offers to hide it.
        await tester.longPress(find.text(hola));
        await tester.pumpAndSettle();
        expect(find.text('Hide translation'), findsOneWidget);
        await tester.tap(find.byKey(const Key('menu-translate')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('translation-text')), findsNothing);
      },
    );

    spec('declining the download translates nothing', (tester) async {
      translator = FakeTranslationService(detects: {hola: 'es'});
      await openConversation(tester, [incoming]);
      await tester.longPress(find.text(hola));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('menu-translate')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('translate-not-now')));
      await tester.pumpAndSettle();
      expect(translator.translated, isEmpty);
      expect(find.byKey(const Key('translation-text')), findsNothing);
    });

    spec('a failed download says so and can be retried', (tester) async {
      translator = FakeTranslationService(detects: {hola: 'es'})
        ..failDownloads = true;
      await openConversation(tester, [incoming]);
      await tester.longPress(find.text(hola));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('menu-translate')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('translate-download')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('translate-failed')), findsOneWidget);
      translator.failDownloads = false;
      await tester.tap(find.byKey(const Key('translate-download')));
      await tester.pumpAndSettle();
      await realWork(tester);
      expect(find.byKey(const Key('translation-text')), findsOneWidget);
    });

    spec(
      'already in the target language, or unreadable, says so; no pack is needed for English text',
      (tester) async {
        translator = FakeTranslationService();
        await openConversation(tester, [
          text('m2', 'good evening', when(9, 0)),
        ]);
        await tester.longPress(find.text('good evening'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('menu-translate')));
        await tester.pumpAndSettle();
        expect(find.textContaining('already in English'), findsOneWidget);
        expect(translator.downloads, isEmpty);
      },
    );

    spec('a phone that cannot translate says so', (tester) async {
      translator = FakeTranslationService(isSupported: false);
      await openConversation(tester, [incoming]);
      await tester.longPress(find.text(hola));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('menu-translate')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Android and iOS apps'), findsOneWidget);
    });

    spec('read aloud speaks the text in its detected language, on the phone', (
      tester,
    ) async {
      translator = FakeTranslationService(detects: {hola: 'es'});
      await openConversation(tester, [incoming]);
      await tester.longPress(find.text(hola));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('menu-read-aloud')));
      await tester.pumpAndSettle();
      await realWork(tester);
      expect(speech.spoken.single.text, hola);
      expect(speech.spoken.single.language, 'es');
    });

    spec(
      'read aloud with no voice that works on the phone explains what to install',
      (tester) async {
        speech = FakeSpeechService(offlineVoice: false);
        translator = FakeTranslationService(detects: {hola: 'es'});
        await openConversation(tester, [incoming]);
        await tester.longPress(find.text(hola));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('menu-read-aloud')));
        await tester.pumpAndSettle();
        await realWork(tester);
        expect(find.textContaining('No voice for Spanish'), findsOneWidget);
        expect(
          find.textContaining(
            'only reads aloud with voices that work on the phone',
          ),
          findsOneWidget,
        );
      },
    );

    spec('copy still copies', (tester) async {
      await openConversation(tester, [incoming]);
      await tester.longPress(find.text(hola));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('menu-copy')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('reaction-pill')), findsNothing);
    });

    spec('auto-translate is a per-chat switch kept on this phone only', (
      tester,
    ) async {
      translator = FakeTranslationService(
        installed: {'es'},
        detects: {hola: 'es', 'Vale, nos vemos': 'es'},
      );
      final mine = text('m3', 'Vale, nos vemos', when(9, 5), mine: true);
      await openConversation(tester, [incoming, mine]);
      expect(find.byKey(const Key('translation-line')), findsNothing);
      await tester.tap(find.byKey(const Key('chat-options')));
      await tester.pumpAndSettle();
      expect(find.text('Auto-translate'), findsOneWidget);
      await tester.tap(find.byKey(const Key('chat-auto-translate')));
      await tester.pumpAndSettle();
      await realWork(tester, 480);
      await tester.pumpAndSettle();
      // The incoming message is translated, your own is not.
      expect(find.text('[en] $hola'), findsOneWidget);
      expect(translator.translated, [hola]);
      // It is stored in the local sealed store, and sent nowhere.
      final prefs = await engine.prefs.read();
      expect(prefs.autoTranslate, {conv});
      expect(cloud.calls, isEmpty);
      expect(cloud.mutes, isEmpty);
      // Turning it off removes the lines.
      await tester.tap(find.byKey(const Key('chat-options')));
      await tester.pumpAndSettle();
      expect(find.text('Turn off auto-translate'), findsOneWidget);
      await tester.tap(find.byKey(const Key('chat-auto-translate')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('translation-line')), findsNothing);
      expect((await engine.prefs.read()).autoTranslate, isEmpty);
    });

    spec(
      'auto-translate asks before downloading a missing pack, and stays off if declined',
      (tester) async {
        translator = FakeTranslationService(detects: {hola: 'es'});
        await openConversation(tester, [incoming]);
        // The target is English (built in) so no pack is needed to switch it on; switching to German needs one.
        await engine.prefs.setTranslateTo('de');
        await tester.tap(find.byKey(const Key('chat-options')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('chat-auto-translate')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('translate-consent')), findsOneWidget);
        await tester.tap(find.byKey(const Key('translate-not-now')));
        await tester.pumpAndSettle();
        expect((await engine.prefs.read()).autoTranslate, isEmpty);
        expect(translator.translated, isEmpty);
      },
    );

    spec('the room menu: pin, clear history and delete chat', (tester) async {
      await openConversation(tester, [incoming]);
      await tester.tap(find.byKey(const Key('chat-options')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('chat-pin')));
      await tester.pumpAndSettle();
      expect(engine.pinned, ['$conv on']);
      await tester.tap(find.byKey(const Key('chat-options')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('chat-delete')));
      await tester.tap(find.byKey(const Key('chat-delete')));
      await tester.pumpAndSettle();
      expect(find.text('Delete this chat?'), findsOneWidget);
      expect(find.textContaining('30 days'), findsWidgets);
      await tester.tap(find.byKey(const Key('confirm-cancel')));
      await tester.pumpAndSettle();
      expect(engine.hidden, isEmpty);
      await tester.tap(find.byKey(const Key('chat-options')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('chat-clear')));
      await tester.tap(find.byKey(const Key('chat-clear')));
      await tester.pumpAndSettle();
      expect(find.text('Clear history on this phone?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm-cancel')));
      await tester.pumpAndSettle();
    });

    spec('pin limit: the sixth is refused with the reason', (tester) async {
      engine.pinFailure = const ChatFailure(
        'PIN_LIMIT',
        'You can pin up to 5 chats',
        409,
      );
      await openConversation(tester, [incoming]);
      await tester.tap(find.byKey(const Key('chat-options')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('chat-pin')));
      await tester.pumpAndSettle();
      expect(
        find.text('You can pin up to 5 chats. Unpin one first.'),
        findsOneWidget,
      );
    });
  });

  // ------------------------------------------------- thread: dates, receipts

  group('the thread', () {
    spec('date chips say Today, Yesterday and the date', (tester) async {
      await openConversation(tester, [
        text('a', 'old', when(9, 0, daysAgo: 9)),
        text('b', 'yesterday', when(20, 0, daysAgo: 1)),
        text('c', 'now', when(9, 0)),
      ]);
      expect(find.text('9 Oct'), findsOneWidget);
      expect(find.text('Yesterday'), findsOneWidget);
      expect(find.text('Today'), findsOneWidget);
      await shoot(tester, 'date-chips');
    });

    spec(
      'in another locale the date is written the way that locale writes it',
      (tester) async {
        await openConversation(tester, [
          text('a', 'old', when(9, 0, daysAgo: 9)),
          text('c', 'now', when(9, 0)),
        ], locale: const Locale('de'));
        expect(find.text('9. Okt.'), findsOneWidget);
        expect(find.text('9 Oct'), findsNothing);
      },
    );

    spec(
      'no read time from the relay (receipts off or never read): nothing is claimed',
      (tester) async {
        await openConversation(tester, [
          text('s1', 'on my way', when(9, 0), mine: true),
        ]);
        expect(find.byKey(const Key('receipt-seen')), findsNothing);
        expect(find.byKey(const Key('receipt-unread')), findsNothing);
      },
    );

    spec('shared receipts, peer read earlier: "Not read yet"', (tester) async {
      cloud.receipt = {'peerReadAt': when(8, 0).toUtc().toIso8601String()};
      await openConversation(tester, [
        text('s1', 'on my way', when(9, 0), mine: true),
      ]);
      expect(find.byKey(const Key('receipt-unread')), findsOneWidget);
      expect(find.text('Not read yet'), findsOneWidget);
    });

    spec('shared receipts, peer read after: "Seen"', (tester) async {
      cloud.receipt = {'peerReadAt': when(9, 30).toUtc().toIso8601String()};
      await openConversation(tester, [
        text('s1', 'on my way', when(9, 0), mine: true),
      ]);
      expect(find.byKey(const Key('receipt-seen')), findsOneWidget);
      expect(find.text('Seen'), findsOneWidget);
    });
  });

  // --------------------------------------------------------------- list

  group('chat list', () {
    final a = chat(
      1,
      'Mira',
      text('a', 'see you at the café at eight', when(9, 0)),
      pinned: true,
    );
    final b = chat(2, 'Niko', text('b', 'sounds good', when(8, 0)), unread: 2);
    final c = chat(3, 'Sam', voiceMsg('c'));
    final d = chat(4, 'Lee', videoMsg('d'));

    spec('pinned chats are marked, voice and video get their own preview', (
      tester,
    ) async {
      await openList(tester, [a, b, c, d]);
      expect(find.byKey(Key('pinned-${a.id}')), findsOneWidget);
      expect(find.byKey(Key('pinned-${b.id}')), findsNothing);
      expect(find.text('Voice message (0:23)'), findsOneWidget);
      expect(find.text('Video (0:12)'), findsOneWidget);
      expect(find.byIcon(Icons.mic_none_rounded), findsOneWidget);
      expect(find.byIcon(Icons.videocam_outlined), findsOneWidget);
      // The order is the server's: pinned first.
      final tops = [
        for (final x in [a, b, c, d])
          tester.getTopLeft(find.byKey(ValueKey(x.id))).dy,
      ];
      expect(tops, orderedEquals([...tops]..sort()));
      await shoot(tester, 'chat-list');
    });

    spec('search reads names and the decrypted history on this phone', (
      tester,
    ) async {
      engine.byConversation[b.id] = [
        text('b1', 'did you get the tickets for friday', when(8, 0)),
      ];
      engine.byConversation[a.id] = [
        text('a1', 'see you at the café at eight', when(9, 0)),
      ];
      await openList(tester, [a, b, c]);
      await tester.enterText(find.byKey(const Key('chat-search')), 'tickets');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      // Niko's last message is "sounds good": the match is older, found in the local history.
      expect(find.byKey(ValueKey(b.id)), findsOneWidget);
      expect(find.textContaining('tickets for friday'), findsOneWidget);
      expect(find.byKey(ValueKey(a.id)), findsNothing);
      expect(cloud.calls, isEmpty, reason: 'the search never leaves the phone');
      await shoot(tester, 'chat-search-history');
      // A name still works, and clearing brings everything back.
      await tester.enterText(find.byKey(const Key('chat-search')), 'mira');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey(a.id)), findsOneWidget);
      expect(find.byKey(ValueKey(b.id)), findsNothing);
    });

    spec(
      'swiping a row to the left reveals Mute and Delete; Delete asks first and hides the chat',
      (tester) async {
        await openList(tester, [a, b]);
        await tester.drag(find.byKey(ValueKey(b.id)), const Offset(-170, 0));
        await tester.pumpAndSettle();
        expect(find.byKey(Key('swipe-mute-${b.id}')), findsOneWidget);
        expect(find.byKey(Key('swipe-delete-${b.id}')), findsOneWidget);
        await shoot(tester, 'chat-swipe');
        await tester.tap(find.byKey(Key('swipe-mute-${b.id}')));
        await tester.pumpAndSettle();
        expect(find.text('Mute Niko'), findsWidgets);
        await tester.tapAt(const Offset(10, 10));
        await tester.pumpAndSettle();
        await tester.drag(find.byKey(ValueKey(b.id)), const Offset(-170, 0));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('swipe-delete-${b.id}')));
        await tester.pumpAndSettle();
        expect(find.text('Delete this chat?'), findsOneWidget);
        await tester.tap(find.byKey(const Key('confirm-yes')));
        await tester.pumpAndSettle();
        expect(engine.hidden, [b.id]);
      },
    );

    spec('swiping to the right pins or unpins', (tester) async {
      await openList(tester, [a, b]);
      await tester.drag(find.byKey(ValueKey(b.id)), const Offset(120, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('swipe-pin-${b.id}')));
      await tester.pumpAndSettle();
      expect(engine.pinned, ['${b.id} on']);
      await tester.drag(find.byKey(ValueKey(a.id)), const Offset(120, 0));
      await tester.pumpAndSettle();
      expect(find.text('Unpin'), findsOneWidget);
      await tester.tap(find.byKey(Key('swipe-pin-${a.id}')));
      await tester.pumpAndSettle();
      expect(engine.pinned, ['${b.id} on', '${a.id} off']);
    });

    spec('the pin limit is explained', (tester) async {
      engine.pinFailure = const ChatFailure(
        'PIN_LIMIT',
        'You can pin up to 5 chats',
        409,
      );
      await openList(tester, [a, b]);
      await tester.drag(find.byKey(ValueKey(b.id)), const Offset(120, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('swipe-pin-${b.id}')));
      await tester.pumpAndSettle();
      expect(
        find.text('You can pin up to 5 chats. Unpin one first.'),
        findsOneWidget,
      );
    });

    spec('only one row is open at a time, and a tap on an open row closes it', (
      tester,
    ) async {
      await openList(tester, [a, b]);
      await tester.drag(find.byKey(ValueKey(a.id)), const Offset(-170, 0));
      await tester.pumpAndSettle();
      expect(find.byKey(Key('swipe-delete-${a.id}')), findsOneWidget);
      await tester.drag(find.byKey(ValueKey(b.id)), const Offset(-170, 0));
      await tester.pumpAndSettle();
      expect(find.byKey(Key('swipe-delete-${a.id}')), findsNothing);
      expect(find.byKey(Key('swipe-delete-${b.id}')), findsOneWidget);
    });

    spec('edit mode: select chats, then pin, mute or delete them together', (
      tester,
    ) async {
      await openList(tester, [a, b, c]);
      await tester.tap(find.byKey(const Key('chats-edit')));
      await tester.pumpAndSettle();
      expect(find.text('Done'), findsOneWidget);
      expect(find.byKey(const Key('edit-count')), findsOneWidget);
      expect(find.text('Select chats'), findsOneWidget);
      await tester.tap(find.byKey(ValueKey(b.id)));
      await tester.tap(find.byKey(ValueKey(c.id)));
      await tester.pumpAndSettle();
      expect(find.text('2 selected'), findsOneWidget);
      await shoot(tester, 'chat-edit-mode');
      // Rows do not open or swipe while editing.
      await tester.drag(find.byKey(ValueKey(b.id)), const Offset(-170, 0));
      await tester.pumpAndSettle();
      expect(find.byKey(Key('swipe-delete-${b.id}')), findsNothing);
      await tester.tap(find.byKey(const Key('edit-pin')));
      await tester.pumpAndSettle();
      expect(engine.pinned, ['${b.id} on', '${c.id} on']);
      await tester.tap(find.byKey(const Key('edit-delete')));
      await tester.pumpAndSettle();
      expect(find.text('Delete 2 chats?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm-yes')));
      await tester.pumpAndSettle();
      expect(engine.hidden, [b.id, c.id]);
    });

    spec(
      'edit mode: select all and none, and nothing happens with nothing selected',
      (tester) async {
        await openList(tester, [a, b, c]);
        await tester.tap(find.byKey(const Key('chats-edit')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('edit-pin')),
          warnIfMissed: false,
        );
        await tester.tap(
          find.byKey(const Key('edit-delete')),
          warnIfMissed: false,
        );
        await tester.pumpAndSettle();
        expect(engine.pinned, isEmpty);
        expect(engine.hidden, isEmpty);
        await tester.tap(find.byKey(const Key('edit-select-all')));
        await tester.pumpAndSettle();
        expect(find.text('3 selected'), findsOneWidget);
        await tester.tap(find.byKey(const Key('edit-select-all')));
        await tester.pumpAndSettle();
        expect(find.text('Select chats'), findsOneWidget);
        await tester.tap(find.byKey(const Key('chats-edit')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('edit-count')), findsNothing);
      },
    );

    spec('a long press starts edit mode with that chat selected', (
      tester,
    ) async {
      await openList(tester, [a, b]);
      await tester.longPress(find.byKey(ValueKey(b.id)));
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);
    });

    spec('Deleted chats lists what can be restored, with the days left', (
      tester,
    ) async {
      final until = fixedNow.add(const Duration(days: 12, hours: 3));
      engine.deleted = [
        chat(5, 'Ana', null, restoreUntil: until),
        chat(
          6,
          'Bo',
          null,
          restoreUntil: fixedNow.add(const Duration(hours: 5)),
        ),
      ];
      await openList(tester, [a]);
      await tester.tap(find.byKey(const Key('chats-deleted-link')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('deleted-chats')), findsOneWidget);
      expect(find.text('Ana'), findsOneWidget);
      expect(find.text('Restorable for 12 more days'), findsOneWidget);
      expect(find.text('Restorable for 5 more hours'), findsOneWidget);
      await shoot(tester, 'deleted-chats');
      final ana = engine.deleted.first;
      engine.deleted = [engine.deleted.last];
      await tester.tap(find.byKey(Key('restore-${ana.id}')));
      await tester.pumpAndSettle();
      expect(engine.restored, [ana.id]);
      expect(find.text('Ana'), findsNothing);
      expect(find.text('Bo'), findsOneWidget);
    });

    spec('Deleted chats with nothing in it says so', (tester) async {
      await openList(tester, [a]);
      await tester.tap(find.byKey(const Key('chats-deleted-link')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('deleted-empty')), findsOneWidget);
    });

    bothWays(
      'the list, edit mode and Deleted chats fit 320 px at text x2.0, in both directions',
      (tester, rtl) async {
        {
          await openList(
            tester,
            [a, b, c],
            size: const Size(320, 1600),
            textScale: 2,
            rtl: rtl,
          );
          expect(tester.takeException(), isNull, reason: 'list rtl $rtl');
          await tester.drag(
            find.byKey(ValueKey(b.id)),
            Offset(rtl ? 200 : -200, 0),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: 'swipe rtl $rtl');
          expect(
            find.byKey(Key('swipe-delete-${b.id}')),
            findsOneWidget,
            reason: 'rtl $rtl',
          );
          await tester.tap(
            find.byKey(const Key('chats-edit')),
            warnIfMissed: false,
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(ValueKey(a.id)), warnIfMissed: false);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: 'edit rtl $rtl');
          for (final key in [
            'edit-pin',
            'edit-mute',
            'edit-delete',
            'edit-select-all',
            'chats-edit',
          ]) {
            final f = find.byKey(Key(key));
            if (f.evaluate().isEmpty) continue;
            expect(
              tester.getSize(f).height,
              greaterThanOrEqualTo(44),
              reason: key,
            );
          }
          if (rtl) await shoot(tester, 'chat-edit-rtl-320');
        }
      },
    );
  });

  group('settings', () {
    spec(
      'Chat language: choose the language and manage the packs on the phone',
      (tester) async {
        translator = FakeTranslationService(installed: {'es', 'de'});
        await pump(tester, const ChatLanguageScreen());
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('chat-language-screen')), findsOneWidget);
        expect(find.byKey(const Key('pack-es')), findsOneWidget);
        expect(find.byKey(const Key('pack-de')), findsOneWidget);
        expect(find.textContaining('never goes to a server'), findsOneWidget);
        await shoot(tester, 'chat-language');
        // Deleting a pack removes it from the phone.
        await tester.tap(find.byKey(const Key('pack-delete-es')));
        await tester.pumpAndSettle();
        expect(translator.deletions, ['es']);
        expect(find.byKey(const Key('pack-es')), findsNothing);
        // Choosing a language stores it locally and offers the pack when it is missing.
        await tester.tap(find.byKey(const Key('translate-to')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('language-search')),
          'fren',
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('language-fr')));
        await tester.pumpAndSettle();
        expect((await engine.prefs.read()).translateTo, 'fr');
        expect(find.byKey(const Key('translate-consent')), findsOneWidget);
        await tester.tap(find.byKey(const Key('translate-download')));
        await tester.pumpAndSettle();
        await realWork(tester);
        expect(translator.downloads, ['fr']);
        expect(find.byKey(const Key('pack-fr')), findsOneWidget);
      },
    );

    spec('with no packs it explains English is built in', (tester) async {
      await pump(tester, const ChatLanguageScreen());
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('translate-no-packs')), findsOneWidget);
      expect(find.textContaining('English is built in'), findsOneWidget);
    });

    spec('on a phone that cannot translate it says so', (tester) async {
      translator = FakeTranslationService(isSupported: false);
      await pump(tester, const ChatLanguageScreen());
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('translate-unsupported')), findsOneWidget);
    });

    spec('the language screen fits 320 px at text x2.0', (tester) async {
      translator = FakeTranslationService(installed: {'es', 'de'});
      await pump(
        tester,
        const ChatLanguageScreen(),
        size: const Size(320, 640),
        textScale: 2,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}

class _Images extends ChatImages {
  final ui.Image base;
  _Images(this.base);
  @override
  Future<ui.Image> decodeJpeg(
    Uint8List bytes, {
    required int w,
    required int h,
    required int targetWidth,
  }) async => base.clone();
  @override
  Future<ui.Image> decodePixels(PreviewPixels p) async => base.clone();
}
