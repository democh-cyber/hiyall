import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/app.dart';
import 'package:hiyall/core/api.dart' show ApiClient, Session;
import 'package:hiyall/core/avatar_upload.dart';
import 'package:hiyall/core/chat/chat_api.dart';
import 'package:hiyall/core/chat/chat_attachment.dart';
import 'package:hiyall/core/chat/chat_blob_cache.dart';
import 'package:hiyall/core/chat/chat_blob_codec.dart';
import 'package:hiyall/core/chat/chat_engine.dart';
import 'package:hiyall/core/chat/chat_media.dart';
import 'package:hiyall/core/chat/chat_outbox.dart';
import 'package:hiyall/core/chat/chat_reactions.dart';
import 'package:hiyall/core/chat/chat_store.dart';
import 'package:hiyall/core/location_service.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/features/chat.dart';
import 'package:hiyall/features/chat_photo.dart';
import 'package:hiyall/features/chat_format.dart' show chatClockProvider;
import 'package:hiyall/features/live_sync.dart';
import 'package:hiyall/shared/person_avatar.dart';
import 'package:hiyall/shared/presence_dot.dart';

import 'avatar_helpers.dart' show PhotoPicker;
import 'chat_photo_helpers.dart';
import 'widget_test.dart' show FakeApi, SignedIn;

/// Renders the chat screens with realistic fake data and writes PNGs to
/// `.runtime/chat-previews-v4/`, for presence (online dots and last seen) `chat-previews-v5/` and for reactions and replies `chat-previews-v6/` (git-ignored). Skipped unless run with
/// `--dart-define=CAPTURE_CHAT=true`.
const capturing = bool.fromEnvironment('CAPTURE_CHAT');

/// Soft gradient palettes standing in for photos and avatars.
const palettes = <List<Color>>[
  [Color(0xffff9a62), Color(0xffff5c8a), Color(0xff8a4fd6)],
  [Color(0xff2dd4bf), Color(0xff6366f1), Color(0xffa855f7)],
  [Color(0xfffde047), Color(0xfffb923c), Color(0xffef4444)],
  [Color(0xff38bdf8), Color(0xff34d399), Color(0xff166534)],
];

Future<ui.Image> gradientImage(List<Color> colors, int w, int h) {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final rect = Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble());
  canvas.drawRect(
    rect,
    Paint()
      ..shader = ui.Gradient.linear(rect.topLeft, rect.bottomRight, colors, [
        for (var i = 0; i < colors.length; i++) i / (colors.length - 1),
      ]),
  );
  canvas.drawCircle(
    Offset(w * .72, h * .3),
    w * .16,
    Paint()..color = Colors.white.withValues(alpha: .55),
  );
  return recorder.endRecording().toImage(w, h);
}

/// A made-up photo for the screenshots only: a sky, a sun, three layers of hills
/// and film grain, drawn from [seed] so every run is the same. Nothing like it
/// is in the app; the real UI never draws placeholder art over a photo.
Future<ui.Image> scenePhoto(int seed, int w, int h) {
  final rnd = math.Random(seed * 7919 + 13);
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final rect = Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble());
  final skies = <List<Color>>[
    [const Color(0xff1d2b53), const Color(0xfff7a072)],
    [const Color(0xff4a90c8), const Color(0xffdceaf2)],
    [const Color(0xff2a1f3d), const Color(0xffe85d75)],
    [const Color(0xff7ab6d8), const Color(0xfff6e7c1)],
  ];
  final sky = skies[seed % skies.length];
  canvas.drawRect(
    rect,
    Paint()
      ..shader = ui.Gradient.linear(rect.topCenter, rect.bottomCenter, sky),
  );
  canvas.drawCircle(
    Offset(
      w * (.25 + .5 * rnd.nextDouble()),
      h * (.3 + .15 * rnd.nextDouble()),
    ),
    w * .09,
    Paint()
      ..color = const Color(0xfffff3d6).withValues(alpha: .92)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
  );
  final hills = [
    const Color(0xff52667a),
    const Color(0xff2f4a46),
    const Color(0xff16241f),
  ];
  for (var layer = 0; layer < hills.length; layer++) {
    final base = h * (.55 + layer * .13);
    final path = Path()..moveTo(0, h.toDouble());
    path.lineTo(0, base);
    for (var x = 0.0; x <= w; x += w / 6) {
      path.quadraticBezierTo(
        x + w / 12,
        base - h * (.05 + .08 * rnd.nextDouble()),
        x + w / 6,
        base + h * .02 * (rnd.nextDouble() - .5),
      );
    }
    path.lineTo(w.toDouble(), h.toDouble());
    path.close();
    canvas.drawPath(path, Paint()..color = hills[layer]);
  }
  // A few soft shapes (a person-sized dark figure, a window of light) and grain.
  canvas.drawRRect(
    RRect.fromRectAndRadius(
      Rect.fromLTWH(w * .58, h * .66, w * .07, h * .17),
      const Radius.circular(8),
    ),
    Paint()..color = Colors.black.withValues(alpha: .55),
  );
  for (var i = 0; i < w * h ~/ 90; i++) {
    final light = rnd.nextBool();
    canvas.drawRect(
      Rect.fromLTWH(rnd.nextDouble() * w, rnd.nextDouble() * h, 2, 2),
      Paint()
        ..color = (light ? Colors.white : Colors.black).withValues(
          alpha: .04 + .06 * rnd.nextDouble(),
        ),
    );
  }
  return recorder.endRecording().toImage(w, h);
}

/// [src] drawn onto a [w] by [h] canvas: the blurred placeholder's pixels.
Future<ui.Image> shrink(ui.Image src, int w, int h) {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawImageRect(
    src,
    Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
    Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    Paint()..filterQuality = FilterQuality.medium,
  );
  return recorder.endRecording().toImage(w, h);
}

Future<Uint8List> gradientPng(List<Color> colors, int w, int h) async {
  final image = await gradientImage(colors, w, h);
  final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
  image.dispose();
  return Uint8List.view(bytes.buffer);
}

/// Hands out pre-drawn gradients instead of decoding, picking one by the number
/// of extra bytes [PreviewMedia] put in the fake JPEG.
class PreviewImages extends ChatImages {
  final Map<String, ui.Image> pool;
  PreviewImages(this.pool);
  @override
  Future<ui.Image> decodeJpeg(
    Uint8List bytes, {
    required int w,
    required int h,
    required int targetWidth,
  }) async {
    final idx = bytes.length - fakeJpeg(w, h).length;
    return pool['${w >= h ? 'l' : 'p'}$idx']!.clone();
  }

  @override
  Future<ui.Image> decodePixels(PreviewPixels p) async =>
      pool['s${p.rgba[0]}']!.clone();
}

/// The blurred placeholder is a 4x4 picture whose bytes name a palette.
class PreviewCodec extends FakeCodec {
  @override
  Future<PreviewPixels> previewPixels(List<int> preview) async =>
      PreviewPixels(4, 4, Uint8List(64)..fillRange(0, 64, preview[0]));
}

class PreviewMedia extends ChatMedia {
  PreviewMedia(FakeCloud cloud, Directory dir)
    : super(
        api: cloud,
        transport: cloud,
        codec: PreviewCodec(),
        cache: ChatBlobCache(dir),
      );

  /// Photos whose download never finishes, to show the blurred placeholder.
  final stuck = <String>{};

  /// Photos whose download fails, by descriptor salt.
  final failing = <String, MediaProblem>{};
  @override
  Future<Uint8List> plaintext(
    String conversationId,
    ChatAttachment att,
    BlobRole role, {
    void Function(double progress)? onProgress,
  }) async {
    onProgress?.call(.4);
    if (stuck.contains(att.salt)) await Completer<void>().future;
    final problem = failing[att.salt];
    if (problem != null) throw ChatMediaFailure(problem);
    final part = att.part(role);
    return fakeJpeg(part.w, part.h, extra: att.preview[0]);
  }
}

class PreviewCloud extends FakeCloud {
  Map<String, dynamic> receipt = {};
  int unread = 0;
  @override
  Future<Map<String, dynamic>> conversation(String id) async => receipt;
  @override
  Future<int> unreadMessages() async => unread;
}

class PreviewEngine extends ChatEngine {
  PreviewEngine(PreviewCloud cloud, ChatMedia media)
    : super(
        userId: meId,
        api: cloud,
        store: MemoryChatStore(),
        media: media,
        codec: PreviewCodec(),
      );
  List<ChatConversation> list = [];
  List<ChatMessage> messages = [];
  Completer<void>? listGate;
  final ctrl = StreamController<String>.broadcast();
  @override
  Stream<String> get changes => ctrl.stream;
  final progress = <String, TransferProgress>{};
  final thumbs = <String, Uint8List>{};

  @override
  Future<List<ChatConversation>> conversations({int limit = 50}) async {
    await listGate?.future;
    return list;
  }

  @override
  Future<List<ChatMessage>> history(String conversationId) async => messages;
  @override
  Future<void> pollNow() async {}
  @override
  Future<void> markRead(String conversationId) async {}
  @override
  TransferProgress? photoProgress(String messageId) => progress[messageId];
  @override
  Uint8List? localThumb(String messageId) => thumbs[messageId];
}

/// A photo descriptor of its own: distinct ids so nothing is shared in caches,
/// [shade] picks the palette, [wide] makes it landscape.
ChatAttachment photoAtt(
  int n, {
  int shade = 0,
  bool wide = false,
  String caption = '',
  bool uploaded = true,
}) {
  String id(int k) =>
      '5b6c0000-0000-4000-8000-${(n * 10 + k).toString().padLeft(12, '0')}';
  final d = descriptor();
  d['salt'] = id(3);
  d['blobs'] = {'full': id(1)};
  d['w'] = wide ? 2048 : 1536;
  d['h'] = wide ? 1536 : 2048;
  (d['thumb'] as Map)
    ..['blob'] = id(2)
    ..['w'] = wide ? 320 : 240
    ..['h'] = wide ? 240 : 320;
  d['preview'] = {'t': 'thumbhash', 'd': base64Encode(List.filled(21, shade))};
  d['caption'] = caption;
  final a = ChatAttachment.parse(d);
  return uploaded ? a : a.withBlobs();
}

final today = DateTime.now();
DateTime at(int h, int m, {int daysAgo = 0}) =>
    DateTime(today.year, today.month, today.day - daysAgo, h, m);

ChatMessage msg(
  String id,
  String text,
  DateTime when, {
  bool mine = false,
  ChatAttachment? att,
  SendStatus status = SendStatus.sent,
  String? failure,
  bool notice = false,
  bool unsupported = false,
}) => ChatMessage(
  messageId: id,
  senderId: mine ? meId : peerId,
  text: att != null ? photoFallbackText : text,
  sentAt: when,
  serverAt: status == SendStatus.sent && !notice ? when.toUtc() : null,
  mine: mine,
  notice: notice,
  attachment: att,
  unsupportedPhoto: unsupported,
  status: status,
  failure: failure,
);

ChatConversation convo(
  int n,
  String name,
  String username,
  ChatMessage? last, {
  int unread = 0,
  bool muted = false,
  String? avatar,
  bool online = false,
  DateTime? lastSeenAt,
}) => ChatConversation(
  '00000000-0000-4000-8000-0000000000${(n + 10).toString().padLeft(2, '0')}',
  '019a4000-0000-7000-8000-0000000001${n.toString().padLeft(2, '0')}',
  name,
  username,
  last,
  unreadCount: unread,
  peerAvatarUrl: avatar,
  mutedUntil: muted ? DateTime.now().add(const Duration(days: 1)) : null,
  online: online,
  lastSeenAt: lastSeenAt,
);

List<ChatConversation> busyList() => [
  convo(
    1,
    'Mira Kapoor',
    'mira',
    msg('l1', 'are you still coming tonight? bringing the speaker', at(9, 41)),
    unread: 3,
    avatar: 'https://img.invalid/mira.jpg',
  ),
  convo(
    2,
    'Niko',
    'niko',
    msg('l2', 'sounds good, see you at 8', at(9, 12), mine: true),
    avatar: 'https://img.invalid/niko.jpg',
  ),
  convo(
    3,
    'Dev Malhotra',
    'dev',
    msg('l3', '😂😂 no way that actually happened', at(8, 55)),
    unread: 12,
  ),
  convo(
    4,
    'Anika Rao',
    'anika',
    msg('l4', '', at(23, 30, daysAgo: 1), att: photoAtt(41, shade: 1)),
    muted: true,
    avatar: 'https://img.invalid/anika.jpg',
  ),
  convo(
    5,
    'Tara',
    'tara',
    msg('l5', 'ok see you then!', at(18, 2, daysAgo: 1)),
    unread: 1,
  ),
  convo(
    6,
    'Alexandrina Montgomery-Featherstonehaugh',
    'alexandrina_mf',
    msg(
      'l6',
      'honestly I have been thinking about this all week and I think we should just go for it, but only if everyone else is in, otherwise let us wait',
      at(14, 20, daysAgo: 3),
    ),
  ),
  convo(
    7,
    'Zoya',
    'zoya',
    msg(
      'l7',
      '',
      at(11, 0, daysAgo: 5),
      mine: true,
      att: photoAtt(71, shade: 2, caption: 'the view from yesterday'),
    ),
    muted: true,
    unread: 2,
  ),
  convo(8, 'Rohan Iyer', 'rohan', null),
];

Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final captureKey = GlobalKey();
  late Map<String, ui.Image> pool;
  late Map<String, ImageProvider> avatars;
  late Directory dir;

  setUpAll(() async {
    if (!capturing) return;
    for (final family in ['SpaceGrotesk', 'Manrope']) {
      await (FontLoader(
        family,
      )..addFont(rootBundle.load('assets/fonts/$family.ttf'))).load();
    }
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    // The test runner ships no emoji font; the Mac's own colour font makes the
    // reaction previews readable. Without it (another machine) emoji are boxes.
    final apple = File('/System/Library/Fonts/Apple Color Emoji.ttc');
    if (apple.existsSync()) {
      await (FontLoader('Apple Color Emoji')..addFont(
            Future.value(ByteData.view(apple.readAsBytesSync().buffer)),
          ))
          .load();
    }
  });

  /// Runs a capture scene on a fake Android phone, with decoding ready.
  void scene(String name, Future<void> Function(WidgetTester tester) body) =>
      testWidgets(name, skip: !capturing, (tester) async {
        // Chat is only offered on Android and iOS; this flips `chatSupported`
        // (read lazily, once) and the camera option, then is put back.
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        expect(chatSupported, isTrue);
        dir = Directory.systemTemp.createTempSync('hiyall_chat_preview');
        addTearDown(() => dir.deleteSync(recursive: true));
        pool = (await tester.runAsync(() async {
          final out = <String, ui.Image>{};
          for (var i = 0; i < palettes.length; i++) {
            out['p$i'] = await scenePhoto(i, 480, 640);
            out['l$i'] = await scenePhoto(i, 640, 480);
            final tiny = await scenePhoto(i, 64, 64);
            out['s$i'] = await shrink(tiny, 4, 4);
            tiny.dispose();
          }
          return out;
        }))!;
        avatars = (await tester.runAsync(
          () async => {
            'mira': MemoryImage(await gradientPng(palettes[0], 96, 96)),
            'niko': MemoryImage(await gradientPng(palettes[1], 96, 96)),
            'anika': MemoryImage(await gradientPng(palettes[3], 96, 96)),
          },
        ))!;
        final savedAvatars = PersonAvatar.imageFactory;
        PersonAvatar.imageFactory = (url, key) =>
            avatars[Uri.parse(url).pathSegments.last.split('.').first] ??
            MemoryImage(Uint8List(0));
        addTearDown(() => PersonAvatar.imageFactory = savedAvatars);
        try {
          await body(tester);
        } finally {
          // Must be unset before the framework's end-of-test invariant check.
          debugDefaultTargetPlatformOverride = null;
        }
      });

  /// Mounts the real app at [route] with the chat engine replaced by [engine].
  Future<ProviderContainer> mount(
    WidgetTester tester,
    String route, {
    required Object? Function(Ref ref) engineOf,
    Size size = const Size(390, 844),
    bool dark = true,
    bool still = false,
    double scale = 1,
    double keyboard = 0,
    List<Override> extra = const [],
    ApiClient? api,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = ProviderContainer(
      // A failed engine setup shows its error at once, not after retries.
      retry: (_, _) => null,
      overrides: [
        apiProvider.overrideWithValue(api ?? FakeApi()),
        sessionProvider.overrideWith(SignedIn.new),
        chatEngineProvider.overrideWith((ref) async {
          final value = engineOf(ref);
          if (value is Future) return await value as ChatEngine?;
          return value as ChatEngine?;
        }),
        chatImagesProvider.overrideWithValue(PreviewImages(pool)),
        ...extra,
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MediaQuery(
          // Phones get a notch and a home indicator; the keyboard takes the
          // home-indicator inset with it, as on iOS.
          data: MediaQueryData(
            size: size,
            disableAnimations: still,
            textScaler: TextScaler.linear(scale),
            padding: size.width < 500
                ? EdgeInsets.only(top: 47, bottom: keyboard > 0 ? 0 : 34)
                : EdgeInsets.zero,
            viewPadding: size.width < 500
                ? const EdgeInsets.only(top: 47, bottom: 34)
                : EdgeInsets.zero,
            viewInsets: EdgeInsets.only(bottom: keyboard),
          ),
          child: RepaintBoundary(key: captureKey, child: const HiyallApp()),
        ),
      ),
    );
    container.read(themeProvider.notifier).toggle(dark);
    container.read(routerProvider).go(route);
    await tester.pumpAndSettle();
    // The Chats badge in the dock counts unread messages.
    unawaited(
      container.read(chatUnreadProvider.notifier).refresh().catchError((_) {}),
    );
    await tester.pumpAndSettle();
    return container;
  }

  PreviewEngine newEngine(PreviewCloud cloud) {
    final media = PreviewMedia(cloud, dir);
    return PreviewEngine(cloud, media);
  }

  /// Writes the capture frame as a 2x PNG and prints any exception the frame
  /// raised (an overflow is a finding, not a reason to skip the picture).
  Future<void> shoot(
    WidgetTester tester,
    String name, {
    String folder = 'chat-previews-v4',
  }) async {
    await tester.pumpAndSettle();
    // Gradients and avatars decode on the real clock.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 250)),
    );
    await tester.pumpAndSettle();
    Object? problem;
    while ((problem = tester.takeException()) != null) {
      debugPrint('EXCEPTION in $name: ${problem.toString().split('\n').first}');
    }
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
      final file = File('../../.runtime/$folder/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
      img.dispose();
    });
    debugPrint('WROTE $name.png');
  }

  /// Unmounts the app so timers (typing indicator) do not outlive the test.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6));
  }

  String convRoute(String name) =>
      '/chats/$conv?peer=$peerId&name=${Uri.encodeQueryComponent(name)}';

  PreviewCloud cloudFor({
    String name = 'Niko',
    bool seen = false,
    bool muted = false,
    int unreadHere = 0,
    List<String> shared = const [],
    List<ChatMessage> messages = const [],
  }) {
    final cloud = PreviewCloud()..unread = 15;
    final lastMine = messages.where((m) => m.mine && !m.notice).lastOrNull;
    cloud.receipt = {
      'unreadCount': unreadHere,
      'peerReadAt': seen && lastMine?.serverAt != null
          ? lastMine!.serverAt!
                .add(const Duration(minutes: 1))
                .toIso8601String()
          : null,
      'mutedUntil': muted
          ? DateTime.now().add(const Duration(days: 1)).toIso8601String()
          : null,
      'sharedInterests': shared,
      'peer': {
        'userId': peerId,
        'displayName': name,
        'username': 'niko',
        'avatarUrl': 'https://img.invalid/niko.jpg',
      },
    };
    return cloud;
  }

  // ---------------------------------------------------------------- chats list
  for (final spec in [
    ('dark', true, const Size(390, 844), 1.0),
    ('light', false, const Size(390, 844), 1.0),
    ('dark', true, const Size(320, 640), 1.0),
    ('dark', true, const Size(360, 780), 1.0),
    ('dark', true, const Size(430, 932), 1.0),
    ('light', false, const Size(320, 640), 1.0),
    ('dark', true, const Size(390, 844), 1.3),
    ('dark', true, const Size(390, 844), 2.0),
    ('dark', true, const Size(320, 640), 2.0),
    ('light', false, const Size(390, 844), 1.3),
    ('dark', true, const Size(1280, 800), 1.0),
    ('light', false, const Size(1280, 800), 1.0),
  ]) {
    final (label, dark, size, scale) = spec;
    final tag =
        '$label-${size.width.toInt()}x${size.height.toInt()}${scale == 1 ? '' : '-text$scale'}';
    scene('chats list, $tag', (tester) async {
      final cloud = PreviewCloud()..unread = 18;
      final engine = newEngine(cloud)..list = busyList();
      await mount(
        tester,
        '/chats',
        engineOf: (_) => engine,
        size: size,
        dark: dark,
        scale: scale,
      );
      await shoot(tester, 'chats-list-$tag');
      if (size.height < 700 || scale > 1) {
        // The bottom of the list.
        await tester.drag(find.byType(ListView).first, const Offset(0, -1400));
        await shoot(tester, 'chats-list-$tag-bottom');
      }
      await unmount(tester);
    });
  }

  scene('chats list, unread filter', (tester) async {
    final engine = newEngine(PreviewCloud()..unread = 18)..list = busyList();
    await mount(tester, '/chats', engineOf: (_) => engine);
    await tester.tap(find.byKey(const Key('chat-filter-unread')));
    await tester.pumpAndSettle();
    await shoot(tester, 'chats-filter-unread-dark-390x844');
    await unmount(tester);
  });

  scene('chats list, caught up filter', (tester) async {
    final engine = newEngine(PreviewCloud())
      ..list = busyList().where((c) => c.unreadCount == 0).toList();
    await mount(tester, '/chats', engineOf: (_) => engine, dark: false);
    await tester.tap(find.byKey(const Key('chat-filter-unread')));
    await tester.pumpAndSettle();
    await shoot(tester, 'chats-filter-unread-empty-light-390x844');
    await unmount(tester);
  });

  scene('chats list, typing', (tester) async {
    final cloud = PreviewCloud()..unread = 18;
    final engine = newEngine(cloud)..list = busyList();
    final c = await mount(
      tester,
      '/chats',
      engineOf: (_) => engine,
      still: true,
    );
    c.read(typingProvider.notifier).mark(engine.list.first.id);
    await tester.pump();
    await shoot(tester, 'chats-list-typing-dark-390x844');
    await unmount(tester);
  });

  for (final spec in [
    ('dark', true, const Size(390, 844)),
    ('light', false, const Size(1280, 800)),
  ]) {
    final (label, dark, size) = spec;
    scene('chats list, empty $label', (tester) async {
      final engine = newEngine(PreviewCloud())..list = [];
      await mount(
        tester,
        '/chats',
        engineOf: (_) => engine,
        size: size,
        dark: dark,
      );
      await shoot(
        tester,
        'chats-empty-$label-${size.width.toInt()}x${size.height.toInt()}',
      );
      await unmount(tester);
    });
  }

  scene('chats list, loading chats', (tester) async {
    final engine = newEngine(PreviewCloud())
      ..listGate = Completer<void>()
      ..list = busyList();
    await mount(tester, '/chats', engineOf: (_) => engine);
    await shoot(tester, 'chats-loading-chats-dark-390x844');
    await unmount(tester);
  });

  scene('chats list, setting up encryption', (tester) async {
    final gate = Completer<ChatEngine?>();
    await mount(tester, '/chats', engineOf: (_) => gate.future);
    await shoot(tester, 'chats-setting-up-dark-390x844');
    await unmount(tester);
  });

  scene('chats list, encryption error', (tester) async {
    await mount(
      tester,
      '/chats',
      engineOf: (_) =>
          Future<ChatEngine?>.error(const ChatFailure('NETWORK', 'offline')),
    );
    await shoot(tester, 'chats-error-dark-390x844');
    await unmount(tester);
  });

  // ------------------------------------------------------------- conversation
  List<ChatMessage> textMessages() => [
    msg('y1', 'did you see the new episode??', at(21, 12, daysAgo: 1)),
    msg(
      'y2',
      'no spoilers!! watching tonight',
      at(21, 20, daysAgo: 1),
      mine: true,
    ),
    msg('n0', 'Niko’s security keys changed.', at(9, 0), notice: true),
    msg('t1', 'hey! are you coming to the rooftop thing tonight?', at(9, 30)),
    msg('t2', 'bringing the speaker 🔊', at(9, 30)),
    msg('t3', 'also Dev is bringing his projector', at(9, 31)),
    msg('t4', 'yes!! what time does it start', at(9, 35), mine: true),
    msg(
      't5',
      'I can leave work by 6, so I can pick up snacks on the way.\n\nDo we need cups or is someone else covering that? I would rather not carry twelve of them across the whole city on the metro if I do not have to, honestly.',
      at(9, 36),
      mine: true,
    ),
    msg('t6', '8ish 🙌', at(9, 38)),
    msg(
      't7',
      'cups are covered, just bring yourself and good vibes',
      at(9, 38),
    ),
    msg('t8', 'perfect, see you there 🎉', at(9, 40), mine: true),
    msg('t9', '🔥🔥', at(9, 41)),
  ];

  for (final spec in [
    ('dark', true, const Size(390, 844), 1.0),
    ('light', false, const Size(390, 844), 1.0),
    ('dark', true, const Size(320, 640), 1.0),
    ('light', false, const Size(320, 640), 1.0),
    ('dark', true, const Size(430, 932), 1.0),
    ('dark', true, const Size(390, 844), 1.3),
    ('dark', true, const Size(320, 640), 2.0),
    ('dark', true, const Size(1280, 800), 1.0),
    ('light', false, const Size(1280, 800), 1.0),
  ]) {
    final (label, dark, size, scale) = spec;
    final tag =
        '$label-${size.width.toInt()}x${size.height.toInt()}${scale == 1 ? '' : '-text$scale'}';
    scene('conversation text, $tag', (tester) async {
      final messages = textMessages();
      final cloud = cloudFor(seen: true, unreadHere: 3, messages: messages);
      final engine = newEngine(cloud)..messages = messages;
      await mount(
        tester,
        convRoute('Niko'),
        engineOf: (_) => engine,
        size: size,
        dark: dark,
        scale: scale,
      );
      await shoot(tester, 'conversation-text-$tag');
      if (size.width < 500) {
        await tester.drag(find.byType(ListView).last, const Offset(0, 900));
        await shoot(tester, 'conversation-text-$tag-top');
      }
      await unmount(tester);
    });
  }

  scene('conversation new chat, dark and light', (tester) async {
    final engine = newEngine(cloudFor());
    await mount(tester, convRoute('Niko'), engineOf: (_) => engine);
    await shoot(tester, 'conversation-new-chat-dark-390x844');
    await tester.tap(find.byKey(const Key('new-chat-dismiss')));
    await tester.pumpAndSettle();
    await shoot(tester, 'conversation-new-chat-dismissed-dark-390x844');
    await unmount(tester);
  });

  scene('conversation new chat, light and 320', (tester) async {
    final engine = newEngine(
      cloudFor(name: 'Alexandrina Montgomery-Featherstonehaugh'),
    );
    await mount(
      tester,
      convRoute('Alexandrina Montgomery-Featherstonehaugh'),
      engineOf: (_) => engine,
      size: const Size(320, 640),
      dark: false,
      scale: 1.3,
    );
    await shoot(tester, 'conversation-new-chat-light-320x640-text1.3');
    await unmount(tester);
  });

  scene('conversation new chat, shared interests', (tester) async {
    final engine = newEngine(cloudFor(shared: const ['Music', 'Gaming']));
    await mount(tester, convRoute('Niko'), engineOf: (_) => engine);
    await shoot(tester, 'conversation-new-chat-shared-dark-390x844');
    await unmount(tester);
  });

  scene('conversation new chat, shared interest, light', (tester) async {
    final engine = newEngine(cloudFor(shared: const ['Gaming']));
    await mount(
      tester,
      convRoute('Niko'),
      engineOf: (_) => engine,
      dark: false,
    );
    await shoot(tester, 'conversation-new-chat-shared-light-390x844');
    await unmount(tester);
  });

  scene('conversation new chat, custom interest', (tester) async {
    final engine = newEngine(cloudFor(shared: const ['Skateboarding']));
    await mount(tester, convRoute('Niko'), engineOf: (_) => engine);
    await shoot(tester, 'conversation-new-chat-custom-dark-390x844');
    await unmount(tester);
  });

  scene('conversation new chat, shared, 320 and large text', (tester) async {
    const name = 'Alexandrina Montgomery-Featherstonehaugh';
    final engine = newEngine(
      cloudFor(name: name, shared: const ['Travel', 'Photography']),
    );
    await mount(
      tester,
      convRoute(name),
      engineOf: (_) => engine,
      size: const Size(320, 640),
      dark: false,
      scale: 1.3,
    );
    await shoot(tester, 'conversation-new-chat-shared-light-320x640-text1.3');
    await unmount(tester);
  });

  scene('conversation new chat, 320 dark, no shared', (tester) async {
    final engine = newEngine(cloudFor());
    await mount(
      tester,
      convRoute('Niko'),
      engineOf: (_) => engine,
      size: const Size(320, 640),
    );
    await shoot(tester, 'conversation-new-chat-dark-320x640');
    await unmount(tester);
  });

  List<ChatMessage> groupedMessages() => [
    msg('g1', 'are you free later?', at(17, 2)),
    msg('g2', 'I finally finished the thing', at(17, 2)),
    msg('g3', 'ok', at(17, 3)),
    msg('g4', 'wait really??', at(17, 4), mine: true),
    msg('g5', 'send it', at(17, 4), mine: true),
    msg('g6', 'k', at(17, 5), mine: true),
    msg(
      'g7',
      'ok so basically I rebuilt the whole thing from scratch over the weekend and it is so much faster now, you have to see it, I will send a clip when I get home',
      at(17, 7),
    ),
    msg('g8', 'ok!', at(17, 8), mine: true),
    msg('g9', 'yes', at(17, 8), mine: true),
    msg('g10', 'omg', at(17, 8), mine: true),
    msg('g11', 'that is genuinely so good', at(17, 9), mine: true),
    msg('g12', '😂', at(17, 10)),
    msg('g13', 'lol thanks', at(17, 10)),
  ];

  for (final spec in [
    ('dark', true, const Size(390, 844)),
    ('light', false, const Size(390, 844)),
    ('dark', true, const Size(320, 640)),
    ('light', false, const Size(320, 640)),
  ]) {
    final (label, dark, size) = spec;
    scene('conversation grouped, $label ${size.width.toInt()}', (tester) async {
      final messages = groupedMessages();
      final engine = newEngine(cloudFor(messages: messages, seen: true))
        ..messages = messages;
      await mount(
        tester,
        convRoute('Niko'),
        engineOf: (_) => engine,
        size: size,
        dark: dark,
      );
      await shoot(
        tester,
        'conversation-grouped-$label-${size.width.toInt()}x${size.height.toInt()}',
      );
      await unmount(tester);
    });
  }

  scene('conversation long message', (tester) async {
    final messages = [
      msg('x1', 'did you read it?', at(12, 0)),
      msg(
        'x2',
        'So I read the whole thing on the train and honestly I think they are right about the first two points but the third one just does not hold up at all, because it assumes everyone has the same amount of time, which obviously nobody does, and then the conclusion kind of falls apart',
        at(12, 1),
        mine: true,
      ),
      msg(
        'x3',
        'https://example.com/a/really/long/link/that/has/no/spaces/in/it/at/all/and/keeps/going/and/going',
        at(12, 2),
      ),
    ];
    final engine = newEngine(cloudFor(messages: messages))..messages = messages;
    await mount(
      tester,
      convRoute('Niko'),
      engineOf: (_) => engine,
      dark: false,
    );
    await shoot(tester, 'conversation-long-message-light-390x844');
    await unmount(tester);
  });

  scene('conversation keyboard open', (tester) async {
    final messages = textMessages();
    final engine = newEngine(cloudFor(messages: messages))..messages = messages;
    await mount(
      tester,
      convRoute('Niko'),
      engineOf: (_) => engine,
      keyboard: 300,
    );
    await tester.enterText(
      find.byKey(const Key('chat-input')),
      'omw, two minutes',
    );
    await tester.pump();
    await shoot(tester, 'conversation-keyboard-dark-390x844');
    await unmount(tester);
  });

  scene('conversation keyboard open, light, multi-line', (tester) async {
    final messages = textMessages();
    final engine = newEngine(cloudFor(messages: messages))..messages = messages;
    await mount(
      tester,
      convRoute('Niko'),
      engineOf: (_) => engine,
      keyboard: 300,
      dark: false,
      size: const Size(360, 700),
    );
    await tester.enterText(
      find.byKey(const Key('chat-input')),
      'ok so the plan:\n1. snacks from the corner shop\n2. cups (none, apparently)\n3. the speaker, obviously\nsee you on the roof',
    );
    await tester.pump();
    await shoot(tester, 'conversation-keyboard-light-360x700');
    await unmount(tester);
  });

  scene('conversation safety menu', (tester) async {
    final messages = textMessages();
    final engine = newEngine(cloudFor(messages: messages, muted: false))
      ..messages = messages;
    await mount(tester, convRoute('Niko'), engineOf: (_) => engine);
    await tester.tap(find.byKey(const Key('chat-options')));
    await tester.pumpAndSettle();
    await shoot(tester, 'conversation-safety-menu-dark-390x844');
    await unmount(tester);
  });

  scene('conversation safety menu, light', (tester) async {
    final messages = textMessages();
    final engine = newEngine(cloudFor(messages: messages, muted: true))
      ..messages = messages;
    await mount(
      tester,
      convRoute('Niko'),
      engineOf: (_) => engine,
      dark: false,
    );
    await tester.tap(find.byKey(const Key('chat-options')));
    await tester.pumpAndSettle();
    await shoot(tester, 'conversation-safety-menu-light-390x844');
    await unmount(tester);
  });

  scene('conversation scroll to latest', (tester) async {
    final messages = [
      for (var i = 0; i < 40; i++)
        msg(
          'm$i',
          i.isEven ? 'message number $i, a line of ordinary chat' : 'reply $i',
          at(8, i),
          mine: i % 3 == 0,
        ),
    ];
    final engine = newEngine(cloudFor(messages: messages))..messages = messages;
    await mount(
      tester,
      convRoute('Niko'),
      engineOf: (_) => engine,
      still: true,
    );
    await tester.drag(find.byType(ListView).last, const Offset(0, 700));
    await tester.pumpAndSettle();
    await shoot(tester, 'conversation-scroll-to-latest-dark-390x844');
    engine.messages = [
      ...messages,
      msg('n1', 'are you there?', at(9, 1)),
      msg('n2', 'hello??', at(9, 2)),
      msg('n3', 'ok call me', at(9, 3)),
    ];
    engine.ctrl.add(conv);
    await tester.pump();
    await tester.pump();
    await shoot(tester, 'conversation-scroll-to-latest-count-dark-390x844');
    await unmount(tester);
  });

  scene('conversation scroll to latest, light', (tester) async {
    final messages = [
      for (var i = 0; i < 40; i++)
        msg('m$i', 'message number $i', at(8, i), mine: i % 3 == 0),
    ];
    final engine = newEngine(cloudFor(messages: messages))..messages = messages;
    await mount(
      tester,
      convRoute('Niko'),
      engineOf: (_) => engine,
      dark: false,
      still: true,
    );
    await tester.drag(find.byType(ListView).last, const Offset(0, 700));
    await tester.pumpAndSettle();
    await shoot(tester, 'conversation-scroll-to-latest-light-390x844');
    await unmount(tester);
  });

  scene('conversation empty', (tester) async {
    final engine = newEngine(cloudFor());
    await mount(tester, convRoute('Niko'), engineOf: (_) => engine);
    await shoot(tester, 'conversation-empty-dark-390x844');
    await unmount(tester);
  });

  scene('conversation typing and draft', (tester) async {
    final messages = textMessages();
    final engine = newEngine(cloudFor(messages: messages))..messages = messages;
    final c = await mount(
      tester,
      convRoute('Niko'),
      engineOf: (_) => engine,
      still: true,
    );
    c.read(typingProvider.notifier).mark(conv);
    await tester.enterText(
      find.byKey(const Key('chat-input')),
      'on my way now, grabbing snacks from the corner shop first so give me twenty minutes and I will be up on the roof with everything',
    );
    await tester.pump();
    await shoot(tester, 'conversation-typing-draft-dark-390x844');
    await unmount(tester);
  });

  scene('conversation short draft', (tester) async {
    final messages = textMessages();
    final engine = newEngine(cloudFor(messages: messages))..messages = messages;
    await mount(
      tester,
      convRoute('Niko'),
      engineOf: (_) => engine,
      dark: false,
    );
    await tester.enterText(find.byKey(const Key('chat-input')), 'omw');
    await tester.pump();
    await shoot(tester, 'conversation-draft-light-390x844');
    await unmount(tester);
  });

  scene('conversation long name, muted', (tester) async {
    final messages = textMessages();
    const name = 'Alexandrina Montgomery-Featherstonehaugh';
    final engine = newEngine(
      cloudFor(name: name, muted: true, messages: messages),
    )..messages = messages;
    await mount(tester, convRoute(name), engineOf: (_) => engine);
    await shoot(tester, 'conversation-long-name-muted-dark-390x844');
    await unmount(tester);
  });

  scene('conversation typing dots', (tester) async {
    final messages = textMessages().sublist(0, 6);
    final engine = newEngine(cloudFor(messages: messages))..messages = messages;
    final c = await mount(
      tester,
      convRoute('Niko'),
      engineOf: (_) => engine,
      still: true,
    );
    c.read(typingProvider.notifier).mark(conv);
    await tester.pump();
    await shoot(tester, 'conversation-typing-dots-dark-390x844');
    await unmount(tester);
  });

  scene('conversation multi-line draft, light', (tester) async {
    final messages = textMessages();
    final engine = newEngine(cloudFor(messages: messages))..messages = messages;
    await mount(
      tester,
      convRoute('Niko'),
      engineOf: (_) => engine,
      dark: false,
    );
    await tester.enterText(
      find.byKey(const Key('chat-input')),
      'ok so the plan:\n1. snacks from the corner shop\n2. cups (none, apparently)\n3. the speaker, obviously\nsee you on the roof',
    );
    await tester.pump();
    await shoot(tester, 'conversation-multiline-draft-light-390x844');
    await unmount(tester);
  });

  scene('chats list, search', (tester) async {
    final engine = newEngine(PreviewCloud()..unread = 18)..list = busyList();
    await mount(tester, '/chats', engineOf: (_) => engine);
    await tester.tap(find.byKey(const Key('chat-search')));
    await tester.enterText(find.byKey(const Key('chat-search')), 'an');
    await tester.pump(const Duration(milliseconds: 300));
    await shoot(tester, 'chats-search-dark-390x844');
    await tester.enterText(find.byKey(const Key('chat-search')), 'zzz');
    await tester.pump(const Duration(milliseconds: 300));
    await shoot(tester, 'chats-search-empty-dark-390x844');
    await unmount(tester);
  });

  // ------------------------------------------------------------------- photos
  const loadedId = 'p-loaded';
  List<ChatMessage> photoMessages() => [
    msg('q1', 'look at this view', at(18, 4)),
    msg(
      loadedId,
      '',
      at(18, 5),
      att: photoAtt(11, shade: 3, caption: 'golden hour from the roof'),
    ),
    msg('q2', 'wait that is unreal', at(18, 6), mine: true),
    msg('p-loading', '', at(18, 8), att: photoAtt(12, shade: 1, wide: true)),
    msg('q3', 'and this one is still loading 😅', at(18, 8)),
  ];

  List<ChatMessage> sendingMessages() => [
    msg('r1', 'send me the pics from last weekend', at(18, 10)),
    msg('p-unsupported', '', at(18, 11), unsupported: true),
    msg(
      'p-sending',
      '',
      at(18, 12),
      mine: true,
      att: photoAtt(21, shade: 0, caption: 'one for the road', uploaded: false),
      status: SendStatus.sending,
    ),
    msg(
      'p-failed',
      '',
      at(18, 13),
      mine: true,
      att: photoAtt(22, shade: 2, wide: true, uploaded: false),
      status: SendStatus.failed,
      failure: 'NETWORK',
    ),
  ];

  PreviewEngine photoEngine(List<ChatMessage> messages, {bool stuck = false}) {
    final cloud = cloudFor(messages: messages);
    final media = PreviewMedia(cloud, dir);
    final engine = PreviewEngine(cloud, media)..messages = messages;
    if (stuck) {
      media.stuck.add(photoAtt(12).salt);
    }
    engine.progress['p-sending'] = TransferProgress()..update(.35);
    engine.thumbs['p-sending'] = fakeJpeg(240, 320, extra: 0);
    engine.thumbs['p-failed'] = fakeJpeg(320, 240, extra: 2);
    return engine;
  }

  for (final spec in [
    ('dark', true, const Size(390, 844)),
    ('light', false, const Size(390, 844)),
    ('dark', true, const Size(1280, 800)),
  ]) {
    final (label, dark, size) = spec;
    scene('conversation received photos, $label ${size.width.toInt()}', (
      tester,
    ) async {
      final engine = photoEngine(photoMessages(), stuck: true);
      await mount(
        tester,
        convRoute('Niko'),
        engineOf: (_) => engine,
        size: size,
        dark: dark,
      );
      await shoot(
        tester,
        'conversation-photos-received-$label-${size.width.toInt()}x${size.height.toInt()}',
      );
      if (size.width < 500) {
        // Scrolled up to the captioned photo that loaded.
        await tester.drag(find.byType(ListView).last, const Offset(0, 700));
        await shoot(
          tester,
          'conversation-photos-received-$label-${size.width.toInt()}x${size.height.toInt()}-top',
        );
      }
      await unmount(tester);
    });

    scene('conversation sending photos, $label ${size.width.toInt()}', (
      tester,
    ) async {
      final engine = photoEngine(sendingMessages());
      await mount(
        tester,
        convRoute('Niko'),
        engineOf: (_) => engine,
        size: size,
        dark: dark,
      );
      await shoot(
        tester,
        'conversation-photos-sending-$label-${size.width.toInt()}x${size.height.toInt()}',
      );
      if (size.width < 500) {
        await tester.drag(find.byType(ListView).last, const Offset(0, 400));
        await shoot(
          tester,
          'conversation-photos-sending-$label-${size.width.toInt()}x${size.height.toInt()}-mid',
        );
      }
      await unmount(tester);
    });
  }

  scene('photo viewer', (tester) async {
    final engine = photoEngine(photoMessages(), stuck: true);
    await mount(tester, convRoute('Niko'), engineOf: (_) => engine);
    await tester.drag(find.byType(ListView).last, const Offset(0, 700));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('photo-$loadedId')));
    await tester.pumpAndSettle();
    await shoot(tester, 'photo-viewer-dark-390x844');
    await unmount(tester);
  });

  for (final spec in [
    ('dark', true, const Size(390, 844)),
    ('light', false, const Size(390, 844)),
    ('dark', true, const Size(320, 640)),
  ]) {
    final (label, dark, size) = spec;
    scene('conversation photo states, $label ${size.width.toInt()}', (
      tester,
    ) async {
      final messages = [
        msg('s1', 'photos from the trip', at(18, 0)),
        msg('s-loading', '', at(18, 1), att: photoAtt(31, shade: 3)),
        msg('s-failed', '', at(18, 2), att: photoAtt(32, shade: 1, wide: true)),
        msg('s-expired', '', at(18, 3), att: photoAtt(33, shade: 2)),
      ];
      final cloud = cloudFor(messages: messages);
      final media = PreviewMedia(cloud, dir);
      media.stuck.add(photoAtt(31).salt);
      media.failing[photoAtt(32).salt] = MediaProblem.network;
      media.failing[photoAtt(33).salt] = MediaProblem.unavailable;
      final engine = PreviewEngine(cloud, media)..messages = messages;
      await mount(
        tester,
        convRoute('Niko'),
        engineOf: (_) => engine,
        size: size,
        dark: dark,
        still: true,
      );
      final tag = '$label-${size.width.toInt()}x${size.height.toInt()}';
      await shoot(tester, 'photo-states-$tag');
      await tester.drag(find.byType(ListView).last, const Offset(0, 500));
      await shoot(tester, 'photo-states-$tag-top');
      await unmount(tester);
    });
  }

  // ------------------------------------------------------------------- sheets
  scene('attach sheet and send preview', (tester) async {
    final messages = textMessages();
    final engine = newEngine(cloudFor(messages: messages))..messages = messages;
    final photo = await tester.runAsync(
      () => gradientPng(palettes[0], 900, 1200),
    );
    await mount(
      tester,
      convRoute('Niko'),
      engineOf: (_) => engine,
      extra: [
        imagePickerProvider.overrideWithValue(PhotoPicker()..bytes = photo),
      ],
    );
    await tester.tap(find.byKey(const Key('chat-attach')));
    await tester.pumpAndSettle();
    expect(find.text('Choose photo'), findsOneWidget);
    expect(find.text('Take photo'), findsOneWidget);
    await shoot(tester, 'attach-sheet-dark-390x844');
    await tester.tap(find.byKey(const Key('attach-gallery')));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('photo-caption')),
      'sunset from the roof',
    );
    await tester.pump();
    await shoot(tester, 'photo-preview-sheet-dark-390x844');
    await unmount(tester);
  });

  // ----------------------------------------------------------------- presence
  // Online dots and last seen, in `chat-previews-v5`. The clock is fixed at 15:30 today so "last seen today at
  // 14:20" and the list times are the same on every run.
  const v5 = 'chat-previews-v5';
  final noon = DateTime(today.year, today.month, today.day, 15, 30);
  final fixedClock = chatClockProvider.overrideWithValue(() => noon);

  /// The busy list with some peers online (Mira, Dev, Tara, the long name) and the others away or hidden.
  List<ChatConversation> presenceList() {
    final base = busyList();
    final online = {1, 3, 5, 6};
    return [
      for (var i = 0; i < base.length; i++)
        ChatConversation(
          base[i].id,
          base[i].peerId,
          base[i].peerName,
          base[i].peerUsername,
          base[i].last,
          peerAvatarUrl: base[i].peerAvatarUrl,
          unreadCount: base[i].unreadCount,
          mutedUntil: base[i].mutedUntil,
          online: online.contains(i + 1),
          lastSeenAt: i == 1 ? at(14, 20) : null,
        ),
    ];
  }

  for (final spec in [
    ('dark', true, const Size(390, 844), 1.0),
    ('light', false, const Size(390, 844), 1.0),
    ('dark', true, const Size(320, 640), 1.0),
    ('light', false, const Size(320, 640), 1.0),
    ('dark', true, const Size(390, 844), 2.0),
  ]) {
    final (label, dark, size, scale) = spec;
    final tag =
        '$label-${size.width.toInt()}x${size.height.toInt()}${scale == 1 ? '' : '-text$scale'}';
    scene('presence: chats list, $tag', (tester) async {
      final engine = newEngine(PreviewCloud()..unread = 18)
        ..list = presenceList();
      await mount(
        tester,
        '/chats',
        engineOf: (_) => engine,
        size: size,
        dark: dark,
        scale: scale,
        extra: [fixedClock],
      );
      expect(find.byType(PresenceDot), findsWidgets);
      await shoot(tester, 'chats-list-online-$tag', folder: v5);
      await unmount(tester);
    });
  }

  final headerVariants = <String, Map<String, Object?>>{
    'online': {'online': true},
    'last-seen-minutes': {'lastSeenAt': at(15, 5)},
    'last-seen-today': {'lastSeenAt': at(14, 20)},
    'last-seen-yesterday': {'lastSeenAt': at(21, 5, daysAgo: 1)},
    'last-seen-weekday': {'lastSeenAt': at(9, 0, daysAgo: 4)},
    'last-seen-date': {'lastSeenAt': at(9, 0, daysAgo: 12)},
    'hidden': {},
  };
  for (final spec in [
    ('dark', true, const Size(390, 844), 1.0),
    ('light', false, const Size(390, 844), 1.0),
    ('dark', true, const Size(320, 640), 1.0),
    ('light', false, const Size(320, 640), 1.0),
    ('dark', true, const Size(320, 640), 2.0),
  ]) {
    final (label, dark, size, scale) = spec;
    final tag =
        '$label-${size.width.toInt()}x${size.height.toInt()}${scale == 1 ? '' : '-text$scale'}';
    scene('presence: conversation header, $tag', (tester) async {
      for (final MapEntry(key: variant, value: presence)
          in headerVariants.entries) {
        final messages = textMessages();
        final cloud = cloudFor(messages: messages);
        cloud.receipt['peer'] = {
          ...(cloud.receipt['peer'] as Map),
          if (presence['online'] == true) 'online': true,
          if (presence['lastSeenAt'] case final DateTime seen)
            'lastSeenAt': seen.toUtc().toIso8601String(),
        };
        final engine = newEngine(cloud)..messages = messages;
        await mount(
          tester,
          convRoute('Niko'),
          engineOf: (_) => engine,
          size: size,
          dark: dark,
          scale: scale,
          extra: [fixedClock],
        );
        await shoot(tester, 'conversation-header-$variant-$tag', folder: v5);
        await unmount(tester);
      }
    });
  }

  scene('presence: conversation, typing while online', (tester) async {
    final messages = textMessages();
    final cloud = cloudFor(messages: messages);
    cloud.receipt['peer'] = {...(cloud.receipt['peer'] as Map), 'online': true};
    final engine = newEngine(cloud)..messages = messages;
    final c = await mount(
      tester,
      convRoute('Niko'),
      engineOf: (_) => engine,
      still: true,
      extra: [fixedClock],
    );
    c.read(typingProvider.notifier).mark(conv);
    await tester.pump();
    await shoot(tester, 'conversation-header-typing-dark-390x844', folder: v5);
    await unmount(tester);
  });

  // Discover: the same dot on people rows (an everyone list with some online).
  for (final spec in [
    ('dark', true, const Size(390, 844)),
    ('light', false, const Size(390, 844)),
    ('dark', true, const Size(320, 640)),
  ]) {
    final (label, dark, size) = spec;
    scene('presence: discover rows, $label ${size.width.toInt()}', (
      tester,
    ) async {
      await mount(
        tester,
        '/discover',
        engineOf: (_) => null,
        size: size,
        dark: dark,
        api: _PeopleApi(),
        extra: [locationServiceProvider.overrideWithValue(_NoLocation())],
      );
      expect(find.byType(PresenceDot), findsWidgets);
      await shoot(
        tester,
        'discover-online-$label-${size.width.toInt()}x${size.height.toInt()}',
        folder: v5,
      );
      await unmount(tester);
    });
  }

  // The dot on its own, over every kind of avatar, so the ring and size can be judged.
  scene('presence: dot on avatars', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final dark in [true, false]) {
      final surface = dark ? const Color(0xff171b17) : const Color(0xfff7f8f2);
      tester.view.physicalSize = const Size(390, 200);
      await tester.pumpWidget(
        RepaintBoundary(
          key: captureKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            home: ColoredBox(
              color: surface,
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final (i, size) in [
                      (0, 26.0),
                      (1, 26.0),
                      (2, 20.0),
                      (3, 36.0),
                    ])
                      Padding(
                        padding: const EdgeInsets.all(10),
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            PersonAvatar(
                              name: 'Mira',
                              userId: 'u$i',
                              radius: size,
                              avatarUrl: i == 1
                                  ? 'https://img.invalid/mira.jpg'
                                  : null,
                            ),
                            Positioned(
                              right: -1,
                              bottom: -1,
                              child: PresenceDot(
                                size: size >= 36 ? 18 : 14,
                                ringColor: surface,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await shoot(
        tester,
        'presence-dot-on-avatars-${dark ? 'dark' : 'light'}',
        folder: v5,
      );
    }
    await unmount(tester);
  });

  // ------------------------------------------------- reactions and replies
  const v6 = 'chat-previews-v6';
  String rid(int n) =>
      '6d6d0000-0000-4000-8000-${n.toRadixString(16).padLeft(12, '0')}';
  ReactionState rx(String? emoji, int n) => ReactionState(
    emoji: emoji,
    at: DateTime.utc(2026, 10, 13, 9, n),
    id: rid(900 + n),
  );
  ChatReply quoted(int n, String by, String snippet, {bool image = false}) =>
      ChatReply(
        id: rid(n),
        by: by,
        snippet: snippet,
        kind: image ? 'image' : 'text',
      );

  ChatMessage rmsg(
    int n,
    String text,
    DateTime when, {
    bool mine = false,
    ChatReply? reply,
    Map<String, String?> reactions = const {},
    ChatAttachment? att,
  }) => ChatMessage(
    messageId: rid(n),
    senderId: mine ? meId : peerId,
    text: att != null ? photoFallbackText : text,
    sentAt: when,
    serverAt: when.toUtc(),
    mine: mine,
    attachment: att,
    reply: reply,
    reactionStates: {
      for (final (i, e) in reactions.entries.indexed) e.key: rx(e.value, i + 1),
    },
  );

  List<ChatMessage> reactionThread() => [
    rmsg(
      1,
      'hey! are you coming to the rooftop thing tonight?',
      at(9, 30),
      reactions: {meId: '\u{1F44D}'},
    ),
    rmsg(2, 'bringing the speaker, and Dev has his projector', at(9, 31)),
    rmsg(
      3,
      'yes!! what time does it start?',
      at(9, 35),
      mine: true,
      reactions: {peerId: '❤️', meId: '❤️'},
    ),
    rmsg(
      4,
      '8ish, cups are covered',
      at(9, 38),
      reply: quoted(3, meId, 'yes!! what time does it start?'),
      reactions: {meId: '\u{1F525}'},
    ),
    rmsg(
      5,
      'perfect, see you there',
      at(9, 40),
      mine: true,
      reply: quoted(4, peerId, '8ish, cups are covered'),
      reactions: {peerId: '\u{1F602}'},
    ),
    rmsg(
      6,
      '',
      at(9, 41),
      att: photoAtt(61, shade: 1, caption: 'the view from up here'),
      reactions: {meId: '\u{1F62E}'},
    ),
    rmsg(
      7,
      'that view!! best spot in the city, honestly, I could stay all night',
      at(9, 43),
      mine: true,
      reply: quoted(6, peerId, '', image: true),
      reactions: {peerId: '\u{1F525}', meId: '\u{1F525}'},
    ),
  ];

  /// The preview engine with local reactions and sends, as the real one does.
  ReactPreview reactEngine(PreviewCloud cloud, List<ChatMessage> messages) =>
      ReactPreview(cloud, PreviewMedia(cloud, dir))..messages = messages;

  Future<void> reactionScene(
    WidgetTester tester, {
    required Size size,
    required bool dark,
    double scale = 1,
    required Future<void> Function(
      WidgetTester tester,
      String tag,
      ReactPreview engine,
    )
    shoots,
    List<ChatMessage>? messages,
  }) async {
    final list = messages ?? reactionThread();
    final engine = reactEngine(cloudFor(messages: list), list);
    await mount(
      tester,
      convRoute('Niko'),
      engineOf: (_) => engine,
      size: size,
      dark: dark,
      scale: scale,
      still: true,
    );
    final tag =
        '${dark ? 'dark' : 'light'}-${size.width.toInt()}x${size.height.toInt()}${scale == 1 ? '' : '-text$scale'}';
    await shoots(tester, tag, engine);
    await unmount(tester);
  }

  /// The text of message [n] itself (not a quote of it in a later bubble).
  Finder inBubble(int n, String text) => find.descendant(
    of: find.byKey(ValueKey(rid(n))),
    matching: find.text(text),
  );

  /// Brings a message of the thread into view (the list builds rows lazily).
  Future<void> reveal(WidgetTester tester, Finder target) async {
    final list = find.byType(ListView).last;
    for (var i = 0; i < 12 && target.evaluate().isEmpty; i++) {
      await tester.drag(list, const Offset(0, 250));
      await tester.pumpAndSettle();
    }
    await tester.ensureVisible(target.first);
    await tester.pumpAndSettle();
  }

  final reactionSpecs = [
    (true, const Size(390, 844), 1.0),
    (false, const Size(390, 844), 1.0),
    (true, const Size(320, 640), 1.0),
    (false, const Size(320, 640), 1.0),
    (true, const Size(320, 640), 2.0),
    (false, const Size(320, 640), 2.0),
  ];

  for (final (dark, size, scale) in reactionSpecs) {
    final label =
        '${dark ? 'dark' : 'light'} ${size.width.toInt()}${scale == 1 ? '' : ' text $scale'}';
    scene('reactions: chips and quotes, $label', (tester) async {
      await reactionScene(
        tester,
        size: size,
        dark: dark,
        scale: scale,
        shoots: (tester, tag, engine) async {
          await shoot(tester, 'bubbles-with-chips-$tag', folder: v6);
          await tester.drag(find.byType(ListView).last, const Offset(0, 700));
          await tester.pumpAndSettle();
          await shoot(tester, 'bubbles-with-chips-$tag-top', folder: v6);
        },
      );
    });

    scene('reactions: menu, $label', (tester) async {
      await reactionScene(
        tester,
        size: size,
        dark: dark,
        scale: scale,
        shoots: (tester, tag, engine) async {
          await reveal(tester, inBubble(4, '8ish, cups are covered'));
          await tester.longPress(inBubble(4, '8ish, cups are covered'));
          await tester.pumpAndSettle();
          await shoot(tester, 'reaction-menu-$tag', folder: v6);
          // The same menu over one of your own messages that you reacted to.
          await tester.tapAt(const Offset(10, 300));
          await tester.pumpAndSettle();
          await reveal(tester, inBubble(3, 'yes!! what time does it start?'));
          await tester.longPress(inBubble(3, 'yes!! what time does it start?'));
          await tester.pumpAndSettle();
          await shoot(tester, 'reaction-menu-own-$tag', folder: v6);
        },
      );
    });

    scene('reactions: reply bar, $label', (tester) async {
      await reactionScene(
        tester,
        size: size,
        dark: dark,
        scale: scale,
        shoots: (tester, tag, engine) async {
          await reveal(tester, inBubble(4, '8ish, cups are covered'));
          await tester.longPress(inBubble(4, '8ish, cups are covered'));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('menu-reply')));
          await tester.pumpAndSettle();
          await shoot(tester, 'reply-bar-$tag', folder: v6);
          await tester.enterText(
            find.byKey(const Key('chat-input')),
            'on my way, bringing snacks',
          );
          await tester.pumpAndSettle();
          await shoot(tester, 'reply-bar-typed-$tag', folder: v6);
        },
      );
    });
  }

  scene('reactions: reply bar to a photo and failed reaction', (tester) async {
    await reactionScene(
      tester,
      size: const Size(390, 844),
      dark: true,
      shoots: (tester, tag, engine) async {
        final engine =
            (tester.state(
                  find.byType(ConversationScreen).last,
                ) as dynamic).engine
                as ReactPreview;
        await tester.longPress(find.byKey(Key('photo-${rid(6)}')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('menu-reply')));
        await tester.pumpAndSettle();
        await shoot(tester, 'reply-bar-photo-$tag', folder: v6);
        engine.fail = const ChatFailure('NETWORK', 'offline');
        await tester.tap(find.byKey(const Key('reply-cancel')));
        await tester.pumpAndSettle();
        await reveal(tester, inBubble(4, '8ish, cups are covered'));
        await tester.longPress(inBubble(4, '8ish, cups are covered'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(Key('react-${reactionEmojis[2]}')));
        await tester.pumpAndSettle();
        await shoot(tester, 'reaction-failed-notice-$tag', folder: v6);
      },
    );
  });

  scene('reactions: swipe to reply in progress', (tester) async {
    await reactionScene(
      tester,
      size: const Size(390, 844),
      dark: true,
      shoots: (tester, tag, engine) async {
        final g = await tester.startGesture(
          tester.getCenter(find.textContaining('that view!! best spot')),
        );
        await g.moveBy(const Offset(30, 0));
        await g.moveBy(const Offset(40, 0));
        await tester.pump();
        await shoot(tester, 'swipe-to-reply-$tag', folder: v6);
        await g.up();
        await tester.pumpAndSettle();
      },
    );
  });
}

/// A preview engine whose reactions and replies take effect locally, as the
/// real engine's do.
class ReactPreview extends PreviewEngine {
  ReactPreview(super.cloud, super.media);
  Object? fail;
  int _n = 0;
  @override
  Future<void> react(
    String conversationId,
    String peerId,
    String messageId,
    String? emoji,
  ) async {
    final failure = fail;
    if (failure != null) {
      fail = null;
      throw failure;
    }
    final i = messages.indexWhere((m) => m.messageId == messageId);
    final m = messages[i];
    messages = [...messages]
      ..[i] = m.copyWith(
        reactionStates: mergeReaction(
          m.reactionStates,
          meId,
          ReactionState(
            emoji: emoji,
            at: DateTime.utc(2026, 10, 14).add(Duration(seconds: ++_n)),
            id: '6d6d0000-0000-4000-8000-${(5000 + _n).toRadixString(16).padLeft(12, '0')}',
          ),
        ),
      );
    ctrl.add(conversationId);
  }

  @override
  Future<void> send(
    String conversationId,
    String peerId,
    String text, {
    ChatMessage? replyTo,
  }) async {}
}

/// A people search with some members online, for the Discover capture.
class _PeopleApi extends FakeApi {
  @override
  Future<Map<String, dynamic>> searchPeople(
    Session s,
    Map<String, dynamic> filters,
  ) async => {
    'items': [
      for (final (i, name, online) in [
        (1, 'Mira Kapoor', true),
        (2, 'Niko', false),
        (3, 'Dev Malhotra', true),
        (4, 'Anika Rao', false),
        (5, 'Tara', false),
      ])
        {
          'userId':
              '019a4000-0000-7000-8000-0000000002${i.toString().padLeft(2, '0')}',
          'username': name.split(' ').first.toLowerCase(),
          'displayName': name,
          'headline': 'Into music, late walks and good coffee',
          'country': i.isEven ? 'IN' : 'GB',
          'languages': [
            {'code': 'en', 'level': 'fluent'},
          ],
          'interests': ['Music', 'Travel'],
          if (online) 'online': true,
        },
    ],
    'nextCursor': null,
  };
}

class _NoLocation implements LocationService {
  @override
  Future<LocationFix> current() async => const LocationFix(12.9716, 77.5946);
  @override
  Future<void> openSettings(LocationProblem problem) async {}
}
