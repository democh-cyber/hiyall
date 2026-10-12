import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/avatar_upload.dart';
import 'package:hiyall/core/chat/chat_api.dart';
import 'package:hiyall/core/chat/chat_attachment.dart';
import 'package:hiyall/core/chat/chat_blob_cache.dart';
import 'package:hiyall/core/chat/chat_blob_codec.dart';
import 'package:hiyall/core/chat/chat_engine.dart';
import 'package:hiyall/core/chat/chat_media.dart';
import 'package:hiyall/core/chat/chat_outbox.dart';
import 'package:hiyall/core/chat/chat_store.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/features/chat.dart';
import 'package:hiyall/features/chat_photo.dart';
import 'package:hiyall/features/safety.dart';
import 'package:image_picker/image_picker.dart';

import 'avatar_helpers.dart';
import 'chat_photo_helpers.dart';
import 'widget_test.dart' show FakeApi, SignedIn;

/// An engine whose photo operations are recorded instead of run.
class EngineSpy extends ChatEngine {
  EngineSpy(MemoryChatStore store, FakeCloud cloud, ChatMedia? media)
    : super(
        userId: meId,
        api: cloud,
        store: store,
        media: media,
        codec: FakeCodec(),
      );
  final sent = <({Uint8List bytes, String caption})>[];
  final retried = <String>[], discarded = <String>[], canceled = <String>[];
  final progress = <String, TransferProgress>{};
  final thumbs = <String, Uint8List>{};
  Object? failSend;
  List<ChatMessage> messages = [];

  @override
  Future<List<ChatMessage>> history(String conversationId) async => messages;

  @override
  Future<ChatMessage> sendPhoto(
    String conversationId,
    String peerId,
    Uint8List input, {
    String caption = '',
  }) async {
    if (failSend != null) throw failSend!;
    sent.add((bytes: input, caption: caption));
    return ChatMessage(
      messageId: 'new',
      senderId: meId,
      text: photoFallbackText,
      sentAt: DateTime.now().toUtc(),
      mine: true,
    );
  }

  @override
  Future<void> retryPhoto(String conversationId, String messageId) async =>
      retried.add(messageId);
  @override
  Future<void> discardPhoto(String conversationId, String messageId) async =>
      discarded.add(messageId);
  @override
  void cancelPhoto(String messageId) => canceled.add(messageId);
  @override
  TransferProgress? photoProgress(String messageId) => progress[messageId];
  @override
  Uint8List? localThumb(String messageId) => thumbs[messageId];
}

/// Answers photo downloads from a script instead of the network.
class ScriptedMedia extends ChatMedia {
  ScriptedMedia(FakeCloud cloud, Directory dir)
    : super(
        api: cloud,
        transport: cloud,
        codec: FakeCodec(),
        cache: ChatBlobCache(dir),
      );
  final requested = <BlobRole>[];
  Object Function(BlobRole role) respond = (_) => Uint8List(0);
  Completer<void>? hold;

  @override
  Future<Uint8List> plaintext(
    String conversationId,
    ChatAttachment att,
    BlobRole role, {
    void Function(double progress)? onProgress,
  }) async {
    requested.add(role);
    onProgress?.call(.5);
    await hold?.future;
    final out = respond(role);
    if (out is Uint8List) return out;
    throw out;
  }
}

/// Decoding stays out of the way: every image is the same 1x1 picture.
class StaticImages extends ChatImages {
  final ui.Image base;
  StaticImages(this.base);
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

ChatMessage received({
  String id = 'm1',
  ChatAttachment? att,
  bool unsupported = false,
  bool mine = false,
  SendStatus status = SendStatus.sent,
  String? failure,
}) => ChatMessage(
  messageId: id,
  senderId: mine ? meId : peerId,
  text: photoFallbackText,
  sentAt: DateTime.utc(2026, 10, 12, 9),
  serverAt: status == SendStatus.sent ? DateTime.utc(2026, 10, 12, 9) : null,
  mine: mine,
  attachment: unsupported ? null : att ?? ChatAttachment.parse(descriptor()),
  unsupportedPhoto: unsupported,
  status: status,
  failure: failure,
);

void main() {
  late FakeCloud cloud;
  late MemoryChatStore store;
  late ScriptedMedia media;
  late EngineSpy engine;
  late PhotoPicker picker;
  late StaticImages images;
  late Directory dir;
  final thumbJpeg = fakeJpeg(240, 320);
  final fullJpeg = fakeJpeg(1536, 2048);

  setUp(() {
    cloud = FakeCloud();
    store = MemoryChatStore();
    dir = Directory.systemTemp.createTempSync('hiyall_widget_test');
    media = ScriptedMedia(cloud, dir);
    media.respond = (role) => role == BlobRole.thumb ? thumbJpeg : fullJpeg;
    picker = PhotoPicker()..bytes = pngBytes;
  });
  tearDown(() => dir.delete(recursive: true));

  /// A widget test whose engine is made inside the test's own zone: its
  /// queues must run on the fake clock the test pumps.
  void spec(String name, Future<void> Function(WidgetTester tester) body) =>
      testWidgets(name, (tester) async {
        engine = EngineSpy(store, cloud, media);
        await body(tester);
      });

  Future<void> open(WidgetTester tester, List<ChatMessage> messages) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(800, 1200);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final base = (await tester.runAsync(() => decodeImageFromList(pngBytes)))!;
    images = StaticImages(base);
    engine.messages = messages;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatEngineProvider.overrideWith((ref) async => engine),
          sessionProvider.overrideWith(SignedIn.new),
          imagePickerProvider.overrideWithValue(picker),
          chatImagesProvider.overrideWithValue(images),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: ConversationScreen(
              id: conv,
              peerId: peerId,
              peerName: 'Niko',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder rawImages(String messageId) => find.descendant(
    of: find.byKey(Key('photo-$messageId')),
    matching: find.byType(RawImage),
  );

  group('image bubble', () {
    spec('shows the blurred preview, then the thumbnail and caption', (
      tester,
    ) async {
      media.hold = Completer<void>();
      await open(tester, [received()]);
      // Placeholder at the descriptor's shape while the thumbnail loads.
      expect(find.byKey(const Key('photo-m1')), findsOneWidget);
      expect(find.byKey(const Key('photo-loading-m1')), findsOneWidget);
      // A ring and words, over the blurred preview of the real photo.
      expect(find.text('Loading photo…'), findsOneWidget);
      expect(find.byKey(const Key('photo-loading-ring')), findsOneWidget);
      expect(rawImages('m1'), findsOneWidget);
      final size = tester.getSize(find.byKey(const Key('photo-m1')));
      expect(size.width / size.height, closeTo(1536 / 2048, .01));

      media.hold!.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('photo-loading-m1')), findsNothing);
      expect(rawImages('m1'), findsNWidgets(2));
      expect(find.text('hello'), findsOneWidget);
      // Only the thumbnail was fetched; the full image waits to be opened.
      expect(media.requested, [BlobRole.thumb]);
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Semantics && w.properties.label == 'Photo from Niko. hello',
        ),
        findsOneWidget,
      );
    });

    spec('a tap opens the viewer, which loads the full image', (tester) async {
      await open(tester, [received()]);
      await tester.tap(find.byKey(const Key('photo-m1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('photo-zoom')), findsOneWidget);
      expect(find.byKey(const Key('photo-viewer-caption')), findsOneWidget);
      expect(media.requested, [BlobRole.thumb, BlobRole.full]);
      expect(find.byKey(const Key('photo-viewer-loading')), findsNothing);
      // No save or share in this version.
      expect(find.byIcon(Icons.download), findsNothing);
      expect(find.byIcon(Icons.share), findsNothing);

      await tester.tap(find.byKey(const Key('photo-viewer-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('photo-zoom')), findsNothing);
      expect(find.byKey(const Key('photo-m1')), findsOneWidget);
    });

    spec('the viewer shows a progress ring while the full image loads', (
      tester,
    ) async {
      await open(tester, [received()]);
      media.hold = Completer<void>();
      await tester.tap(find.byKey(const Key('photo-m1')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('photo-viewer-loading')), findsOneWidget);
      // The thumbnail is already there to look at.
      expect(find.byKey(const Key('photo-zoom')), findsOneWidget);
      media.hold!.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('photo-viewer-loading')), findsNothing);
    });

    spec('an unavailable photo says so and cannot be opened', (tester) async {
      media.respond = (_) => const ChatMediaFailure(MediaProblem.unavailable);
      await open(tester, [received()]);
      expect(find.byKey(const Key('photo-unavailable-m1')), findsOneWidget);
      expect(find.text('Photo expired'), findsOneWidget);
      // It says why, and there is nothing to retry.
      expect(find.textContaining('30 days'), findsOneWidget);
      expect(find.byKey(const Key('photo-retry-m1')), findsNothing);
      await tester.tap(find.byKey(const Key('photo-m1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('photo-zoom')), findsNothing);
    });

    spec('a failed download offers Retry and recovers', (tester) async {
      media.respond = (_) => const ChatMediaFailure(MediaProblem.network);
      await open(tester, [received()]);
      expect(find.byKey(const Key('photo-retry-m1')), findsOneWidget);
      expect(find.text('Couldn’t load photo'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      // The retry target is a real 44 dp button.
      expect(
        tester.getSize(find.byKey(const Key('photo-retry-m1'))).height,
        greaterThanOrEqualTo(44),
      );
      media.respond = (_) => thumbJpeg;
      await tester.tap(find.byKey(const Key('photo-retry-m1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('photo-retry-m1')), findsNothing);
      expect(rawImages('m1'), findsNWidgets(2));
    });

    spec('a damaged photo is not retried forever', (tester) async {
      media.respond = (_) => const ChatMediaFailure(MediaProblem.corrupt);
      await open(tester, [received()]);
      expect(find.byKey(const Key('photo-damaged-m1')), findsOneWidget);
      expect(find.byKey(const Key('photo-retry-m1')), findsNothing);
    });

    spec('a descriptor that failed validation is an unsupported photo', (
      tester,
    ) async {
      await open(tester, [received(unsupported: true)]);
      expect(find.byKey(const Key('photo-unsupported')), findsOneWidget);
      expect(find.text('Unsupported photo'), findsOneWidget);
      expect(find.byKey(const Key('photo-m1')), findsNothing);
      expect(media.requested, isEmpty);
    });

    spec('a failing preview still shows the thumbnail', (tester) async {
      await open(tester, [received()]);
      expect(rawImages('m1'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });

    spec('my photo while uploading shows progress and can be stopped', (
      tester,
    ) async {
      final att = ChatAttachment.parse(descriptor()).withBlobs();
      final progress = TransferProgress()..update(.25);
      engine.progress['m2'] = progress;
      engine.thumbs['m2'] = thumbJpeg;
      await open(tester, [
        received(id: 'm2', att: att, mine: true, status: SendStatus.sending),
      ]);
      expect(find.byKey(const Key('photo-sending-m2')), findsOneWidget);
      expect(find.text('Sending…'), findsOneWidget);
      // The thumbnail of my own photo needs no download.
      expect(media.requested, isEmpty);
      expect(rawImages('m2'), findsNWidgets(2));
      var ring = tester.widget<CircularProgressIndicator>(
        find.descendant(
          of: find.byKey(const Key('photo-sending-m2')),
          matching: find.byType(CircularProgressIndicator),
        ),
      );
      expect(ring.value, .25);
      progress.update(.75);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      ring = tester.widget<CircularProgressIndicator>(
        find.descendant(
          of: find.byKey(const Key('photo-sending-m2')),
          matching: find.byType(CircularProgressIndicator),
        ),
      );
      expect(ring.value, .75);

      await tester.tap(find.byKey(const Key('photo-stop-m2')));
      expect(engine.canceled, ['m2']);
      // Opening is not possible before the photo is on the server.
      await tester.tap(find.byKey(const Key('photo-m2')), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('photo-zoom')), findsNothing);
    });

    spec('a failed photo explains why and can retry or be deleted', (
      tester,
    ) async {
      final att = ChatAttachment.parse(descriptor()).withBlobs();
      await open(tester, [
        received(
          id: 'm3',
          att: att,
          mine: true,
          status: SendStatus.failed,
          failure: 'ATTACHMENTS_NOT_ALLOWED',
        ),
      ]);
      expect(find.byKey(const Key('photo-failed-m3')), findsOneWidget);
      expect(find.text('Not sent'), findsOneWidget);
      expect(find.text('You can send photos once they reply.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('photo-send-retry-m3')));
      await tester.pump();
      expect(engine.retried, ['m3']);
      await tester.tap(find.byKey(const Key('photo-delete-m3')));
      await tester.pump();
      expect(engine.discarded, ['m3']);
    });

    spec('a network failure says to check the connection', (tester) async {
      final att = ChatAttachment.parse(descriptor()).withBlobs();
      await open(tester, [
        received(
          id: 'm3',
          att: att,
          mine: true,
          status: SendStatus.failed,
          failure: 'NETWORK',
        ),
      ]);
      expect(find.textContaining('Check your connection'), findsOneWidget);
    });
  });

  group('viewer problems', () {
    spec('an unavailable full image says so without a retry', (tester) async {
      await open(tester, [received()]);
      media.respond = (role) => role == BlobRole.full
          ? const ChatMediaFailure(MediaProblem.unavailable)
          : thumbJpeg;
      await tester.tap(find.byKey(const Key('photo-m1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('photo-viewer-note')), findsOneWidget);
      expect(find.byKey(const Key('photo-viewer-retry')), findsNothing);
      // The thumbnail stays visible meanwhile.
      expect(find.byKey(const Key('photo-zoom')), findsOneWidget);
    });

    spec('a network failure offers Retry', (tester) async {
      await open(tester, [received()]);
      media.respond = (role) => role == BlobRole.full
          ? const ChatMediaFailure(MediaProblem.network)
          : thumbJpeg;
      await tester.tap(find.byKey(const Key('photo-m1')));
      await tester.pumpAndSettle();
      media.respond = (_) => fullJpeg;
      await tester.tap(find.byKey(const Key('photo-viewer-retry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('photo-viewer-note')), findsNothing);
    });
  });

  group('composer', () {
    Future<void> choose(WidgetTester tester, String key) async {
      await tester.tap(find.byKey(const Key('chat-attach')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key(key)));
      await tester.pumpAndSettle();
    }

    spec('choose, preview with a caption, send', (tester) async {
      await open(tester, []);
      await tester.tap(find.byKey(const Key('chat-attach')));
      await tester.pumpAndSettle();
      expect(find.text('Choose photo'), findsOneWidget);
      expect(find.text('Take photo'), findsOneWidget);
      await tester.tap(find.byKey(const Key('attach-gallery')));
      await tester.pumpAndSettle();
      expect(picker.sources, [ImageSource.gallery]);
      // The picker is asked for a downscaled image: Rust refuses over 40 MP.
      expect(picker.maxWidth, 4096);

      expect(find.byKey(const Key('photo-preview')), findsOneWidget);
      expect(find.text('Send to Niko'), findsOneWidget);
      // Nothing is sent until the person says so.
      expect(engine.sent, isEmpty);
      await tester.enterText(find.byKey(const Key('photo-caption')), 'hi  ');
      await tester.tap(find.byKey(const Key('photo-send')));
      await tester.pumpAndSettle();
      expect(engine.sent, hasLength(1));
      expect(engine.sent.single.bytes, pngBytes);
      expect(engine.sent.single.caption, 'hi');
    });

    spec('the camera is offered on phones', (tester) async {
      await open(tester, []);
      await choose(tester, 'attach-camera');
      expect(picker.sources, [ImageSource.camera]);
      await tester.tap(find.byKey(const Key('photo-send')));
      await tester.pumpAndSettle();
      expect(engine.sent.single.caption, isEmpty);
    });

    spec('cancelling the preview sends nothing', (tester) async {
      await open(tester, []);
      await choose(tester, 'attach-gallery');
      await tester.tap(find.byKey(const Key('photo-cancel')));
      await tester.pumpAndSettle();
      expect(engine.sent, isEmpty);
      expect(find.byKey(const Key('photo-preview')), findsNothing);
    });

    spec('backing out of the picker does nothing', (tester) async {
      picker.bytes = null;
      await open(tester, []);
      await choose(tester, 'attach-gallery');
      expect(find.byKey(const Key('photo-preview')), findsNothing);
      expect(engine.sent, isEmpty);
    });

    spec('denied photo access is explained', (tester) async {
      picker.failure = photoAccessDenied();
      await open(tester, []);
      await choose(tester, 'attach-gallery');
      expect(
        find.text(
          'Hiyall can’t reach your photos. Allow access in your device settings.',
        ),
        findsOneWidget,
      );
      expect(engine.sent, isEmpty);
    });

    spec('a photo over 64 MiB is refused before the preview', (tester) async {
      picker.bytes = Uint8List(maxPhotoInput + 1);
      await open(tester, []);
      await choose(tester, 'attach-gallery');
      expect(find.text('That photo is too large to send.'), findsOneWidget);
      expect(find.byKey(const Key('photo-preview')), findsNothing);
    });

    spec('a refused send shows the calm reason', (tester) async {
      engine.failSend = const ChatFailure(
        'ATTACHMENTS_NOT_ALLOWED',
        'raw',
        403,
      );
      await open(tester, []);
      await choose(tester, 'attach-gallery');
      await tester.tap(find.byKey(const Key('photo-send')));
      await tester.pumpAndSettle();
      expect(find.text('You can send photos once they reply.'), findsOneWidget);
    });

    spec('the text composer is unchanged', (tester) async {
      await open(tester, []);
      expect(find.byKey(const Key('chat-input')), findsOneWidget);
      expect(find.byKey(const Key('chat-send')), findsOneWidget);
      expect(find.byTooltip('Attach photo'), findsOneWidget);
    });
  });

  group('decoding is checked', () {
    final decoder = ChatImages();
    for (final (name, bytes) in <(String, Uint8List)>[
      ('not a JPEG', Uint8List.fromList([1, 2, 3, 4, 5, 6])),
      ('a PNG', pngBytes),
      ('a different size than declared', fakeJpeg(100, 100)),
      ('a canvas bigger than declared', fakeJpeg(12000, 12000)),
      ('an empty file', Uint8List(0)),
    ]) {
      test('refuses $name before decoding', () async {
        await expectLater(
          decoder.decodeJpeg(bytes, w: 240, h: 320, targetWidth: 640),
          throwsFormatException,
        );
      });
    }

    test('refuses a preview that is not 32 px or smaller', () async {
      await expectLater(
        Future(
          () => decoder.decodePixels(
            PreviewPixels(64, 64, Uint8List(64 * 64 * 4)),
          ),
        ),
        throwsFormatException,
      );
      await expectLater(
        Future(() => decoder.decodePixels(PreviewPixels(4, 4, Uint8List(10)))),
        throwsFormatException,
      );
    });

    spec('keeps the most recently used images within its budget', (
      tester,
    ) async {
      final base = (await tester.runAsync(
        () => decodeImageFromList(pngBytes),
      ))!;
      // Room for two 1x1 images (4 bytes each).
      final lru = ChatImages(maxBytes: 8);
      Future<ui.Image> put(String key) =>
          lru.obtain(key, () async => base.clone());
      (await put('a')).dispose();
      (await put('b')).dispose();
      lru.peek('a')!.dispose();
      (await put('c')).dispose();
      expect(lru.count, 2);
      expect(lru.peek('b'), isNull);
      lru.peek('a')!.dispose();
      lru.peek('c')!.dispose();
      lru.clear();
      expect(lru.count, 0);
    });
  });

  group('reporting a chat with photos', () {
    late List<Map<String, dynamic>> reports;
    late FakeApi api;

    Future<void> openReport(WidgetTester tester) async {
      reports = [];
      api = _ReportApi(reports);
      final messages = [
        ChatMessage(
          messageId: 'm1',
          senderId: peerId,
          text: 'look at this',
          sentAt: DateTime.utc(2026, 10, 12, 9),
          serverAt: DateTime.utc(2026, 10, 12, 9, 0, 1),
          mine: false,
        ),
        received(id: 'm2'),
        received(id: 'm3', unsupported: true),
        received(
          id: 'm4',
          mine: true,
          status: SendStatus.failed,
          att: ChatAttachment.parse(descriptor()).withBlobs(),
        ),
      ];
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(800, 1200);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      late WidgetRef widgetRef;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiProvider.overrideWithValue(api),
            sessionProvider.overrideWith(SignedIn.new),
          ],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                widgetRef = ref;
                return const Scaffold(body: SizedBox());
              },
            ),
          ),
        ),
      );
      unawaited(
        showReportSheet(
          tester.element(find.byType(Scaffold)),
          widgetRef,
          targetType: 'conversation',
          targetId: conv,
          name: 'Niko',
          messages: messages,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('reason-scam')));
      await tester.pumpAndSettle();
    }

    Future<void> tick(WidgetTester tester, String key) async {
      final finder = find.byKey(Key(key));
      await tester.scrollUntilVisible(
        finder,
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    Future<void> submit(WidgetTester tester) async {
      final button = find.byKey(const Key('report-submit'));
      await tester.scrollUntilVisible(
        button,
        200,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.tap(button);
      await tester.pumpAndSettle();
    }

    spec('photos that never went out are not offered', (tester) async {
      await openReport(tester);
      expect(find.byKey(const Key('evidence-m4')), findsNothing);
      await tester.scrollUntilVisible(
        find.byKey(const Key('evidence-m2')),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.byKey(const Key('evidence-m2')), findsOneWidget);
      expect(find.text('Niko · Photo'), findsWidgets);
    });

    spec('the photo and its key leave only with their own consent', (
      tester,
    ) async {
      await openReport(tester);
      await tick(tester, 'evidence-m2');
      await tick(tester, 'report-consent');
      // A separate, clearly worded consent line for the photo itself.
      await tester.scrollUntilVisible(
        find.byKey(const Key('report-photo-consent')),
        200,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('Also share the photo itself'), findsOneWidget);
      expect(find.textContaining('key to open the photo'), findsOneWidget);
      await tick(tester, 'report-photo-consent');
      await submit(tester);

      final evidence = (reports.single['evidence'] as List).single as Map;
      expect(evidence['messageId'], 'm2');
      expect(evidence['text'], photoFallbackText);
      final attachments = evidence['attachments'] as List;
      expect(attachments, hasLength(1));
      final a = attachments.single as Map;
      expect(a['blobIds'], [fullId, thumbId]);
      final descriptor = a['descriptor'] as Map;
      expect(descriptor['key'], isNotEmpty);
      expect(ChatAttachment.parse(descriptor).full.blobId, fullId);
      expect(jsonEncode(descriptor).length, lessThan(4096));
    });

    spec('without the photo consent only the text is shared', (tester) async {
      await openReport(tester);
      await tick(tester, 'evidence-m2');
      await tick(tester, 'report-consent');
      await submit(tester);
      final evidence = (reports.single['evidence'] as List).single as Map;
      expect(evidence.containsKey('attachments'), isFalse);
      expect(jsonEncode(evidence), isNot(contains('"key"')));
    });

    spec('an unsupported photo can only be reported as text', (tester) async {
      await openReport(tester);
      await tick(tester, 'evidence-m3');
      expect(find.byKey(const Key('report-photo-consent')), findsNothing);
      await tick(tester, 'report-consent');
      await submit(tester);
      final evidence = (reports.single['evidence'] as List).single as Map;
      expect(evidence.containsKey('attachments'), isFalse);
    });

    spec('text-only reports are unchanged', (tester) async {
      await openReport(tester);
      await tick(tester, 'evidence-m1');
      expect(find.byKey(const Key('report-photo-consent')), findsNothing);
      await tick(tester, 'report-consent');
      await submit(tester);
      expect((reports.single['evidence'] as List).single, {
        'messageId': 'm1',
        'text': 'look at this',
        'sentAt': '2026-10-12T09:00:01.000Z',
        'fromMe': false,
      });
    });

    spec('unticking the photo drops its consent', (tester) async {
      await openReport(tester);
      await tick(tester, 'evidence-m2');
      await tick(tester, 'report-consent');
      await tick(tester, 'report-photo-consent');
      await tick(tester, 'evidence-m2');
      expect(find.byKey(const Key('report-photo-consent')), findsNothing);
    });
  });
}

class _ReportApi extends FakeApi {
  final List<Map<String, dynamic>> reports;
  _ReportApi(this.reports);
  @override
  Future<ReportReceipt> report(
    Session s, {
    required String targetType,
    required String targetId,
    required String reasonCode,
    String description = '',
    List<Map<String, dynamic>> evidence = const [],
    bool disclosureConsent = false,
    bool block = false,
  }) async {
    reports.add({
      'targetType': targetType,
      'evidence': evidence,
      'consent': disclosureConsent,
    });
    return const ReportReceipt();
  }
}
