import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/api.dart';
import 'package:hiyall/core/state.dart';
import 'package:hiyall/core/story_draft.dart';
import 'package:hiyall/core/theme.dart';
import 'package:hiyall/features/pulse.dart';
import 'package:hiyall/shared/story_canvas.dart';
import 'package:image_picker/image_picker.dart';

import 'pulse_test.dart' as pt;
import 'widget_test.dart' show SignedIn;
import 'support/fixtures.dart';

/// A 1x1 PNG: a photo the story composer can decode, upload and draw.
final png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

class PngPicker extends ImagePicker {
  final sources = <ImageSource>[];
  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) async {
    sources.add(source);
    return XFile.fromData(png, name: 'story.png');
  }
}

/// The composer on top of a "home" route, as the app pushes it, with a draft store we can look into.
class Composer {
  final WidgetTester tester;
  final pt.PulseApi api;
  final MemoryStoryDraftStore drafts;
  final PngPicker picker = PngPicker();
  final nav = GlobalKey<NavigatorState>();
  Composer(this.tester, this.api, this.drafts);

  Future<void> start({
    Size size = const Size(390, 844),
    Brightness brightness = Brightness.dark,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiProvider.overrideWithValue(api),
          sessionProvider.overrideWith(SignedIn.new),
          storyDraftStoreProvider.overrideWithValue(drafts),
        ],
        child: MaterialApp(
          navigatorKey: nav,
          theme: hiyallTheme(brightness),
          home: const Scaffold(body: Text('home')),
        ),
      ),
    );
    await open();
  }

  Future<void> open() async {
    nav.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => StoryComposerScreen(picker: picker),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder key(String name) => find.byKey(Key(name));

  /// Taps a control that may be scrolled out of a row.
  Future<void> tap(String name) async {
    await tester.ensureVisible(key(name));
    await tester.pumpAndSettle();
    await tester.tap(key(name));
    await tester.pumpAndSettle();
  }

  Future<void> type(String words) async {
    await tester.enterText(key('story-text'), words);
    await tester.pump();
  }

  TextField get field => tester.widget<TextField>(key('story-text'));
  StoryCanvas get canvas => tester.widget<StoryCanvas>(key('story-canvas'));
  String get typed => field.controller!.text;

  /// Lets the debounced draft save run.
  Future<void> settleDraft() => tester.pump(const Duration(milliseconds: 300));
}

Story oldStory({
  String body = 'gm',
  String background = 'pink',
  String textStyle = 'clean',
}) => Story(
  storyId: 's',
  body: body,
  background: background,
  textStyle: textStyle,
  audience: 'public',
  createdAt: DateTime.now(),
  expiresAt: DateTime.now().add(const Duration(hours: 6, minutes: 30)),
);

Widget hosted(Widget child, {Size size = const Size(360, 640)}) => MaterialApp(
  home: Center(
    child: SizedBox(width: size.width, height: size.height, child: child),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Contrast and fitting', () {
    test('the ink on every background reads well', () {
      for (final b in storyBackgrounds) {
        final ink = storyInkFor(b.colors);
        for (final c in b.colors) {
          final hi = c.computeLuminance() > ink.computeLuminance()
              ? c.computeLuminance()
              : ink.computeLuminance();
          final lo = c.computeLuminance() > ink.computeLuminance()
              ? ink.computeLuminance()
              : c.computeLuminance();
          expect(
            (hi + .05) / (lo + .05),
            greaterThan(3),
            reason: '${b.name} $c with $ink',
          );
        }
      }
    });

    test('light backgrounds get ink and dark ones get cream', () {
      for (final light in ['lime', 'lilac', 'pink', 'mint', 'peach', 'mango']) {
        expect(
          storyInkFor(storyBackgroundFor(light).colors),
          VibeColors.ink,
          reason: light,
        );
      }
      for (final dark in ['ink', 'midnight', 'grape', 'ocean']) {
        expect(
          storyInkFor(storyBackgroundFor(dark).colors),
          VibeColors.cream,
          reason: dark,
        );
      }
      expect(storyInkFor(const [Colors.white]), VibeColors.ink);
      expect(storyInkFor(const [Colors.black]), VibeColors.cream);
      // A gradient is judged by its worst stop: dark text on a stop this dark would not read.
      expect(
        storyInkFor(const [Color(0xffffffff), Color(0xff101010)]),
        isIn([VibeColors.ink, VibeColors.cream]),
      );
    });

    test('text shrinks as it gets longer and never grows back', () {
      var last = double.infinity;
      for (var n = 0; n <= 280; n += 5) {
        final size = storyFontSize('x' * n);
        expect(size, lessThanOrEqualTo(last), reason: '$n characters');
        last = size;
      }
      expect(storyFontSize('gm'), greaterThan(storyFontSize('x' * 280)));
      expect(storyFontSize('x' * 280), greaterThanOrEqualTo(18));
      // Line breaks take room too, and a photo caption stays modest.
      expect(
        storyFontSize('a\nb\nc\nd\ne\nf'),
        lessThan(storyFontSize('abcdef')),
      );
      expect(storyFontSize('gm', photo: true), lessThanOrEqualTo(30));
    });

    test('names this app does not know fall back instead of failing', () {
      expect(storyBackgroundFor('neon').name, 'lime');
      expect(storyBackgroundFor('').name, 'lime');
      expect(storyTextSpecFor('comic').name, 'clean');
      expect(storyTextSpecFor('').name, 'clean');
      expect(storyBackgrounds, hasLength(14));
      expect(storyBackgrounds.where((b) => b.isGradient), hasLength(8));
      expect(storyTextStyles, hasLength(6));
    });

    test('upper-case styles shout', () {
      expect(storyDisplayText('gm', storyTextSpecFor('loud')), 'GM');
      expect(storyDisplayText('gm', storyTextSpecFor('clean')), 'gm');
    });
  });

  group('Parsing and drafts', () {
    test('a story from before text styles is clean', () {
      final old = Story.fromJson({
        'storyId': 's',
        'body': 'hi',
        'background': 'pink',
        'audience': 'public',
        'createdAt': '2026-10-12T10:00:00Z',
        'expiresAt': '2026-10-13T10:00:00Z',
      });
      expect(old.textStyle, 'clean');
      final styled = Story.fromJson({
        'storyId': 's',
        'body': 'hi',
        'background': 'sunset',
        'textStyle': 'glow',
        'audience': 'public',
        'createdAt': '2026-10-12T10:00:00Z',
        'expiresAt': '2026-10-13T10:00:00Z',
      });
      expect((styled.background, styled.textStyle), ('sunset', 'glow'));
    });

    test('a draft survives a round trip and forgives bad data', () {
      const draft = StoryDraft(
        text: 'hello',
        background: 'ocean',
        textStyle: 'type',
        align: 'right',
        audience: 'public',
        lifetimeHours: 12,
      );
      final back = StoryDraft.decode(draft.encode())!;
      expect(back.encode(), draft.encode());
      expect(back.hasContent, isTrue);
      expect(const StoryDraft(text: '  ').hasContent, isFalse);
      expect(StoryDraft.decode(null), isNull);
      expect(StoryDraft.decode('not json'), isNull);
      expect(StoryDraft.decode('[1]'), isNull);
      final odd = StoryDraft.decode(
        jsonEncode({
          'text': 'x',
          'background': 'from-the-future',
          'textStyle': 'comic',
          'align': 'up',
          'audience': 'nobody',
          'lifetimeHours': 48,
        }),
      )!;
      expect(
        (
          odd.background,
          odd.textStyle,
          odd.align,
          odd.audience,
          odd.lifetimeHours,
        ),
        ('lime', 'clean', 'center', null, 24),
      );
    });
  });

  group('StoryCanvas', () {
    testWidgets('draws a story from before text styles as clean', (
      tester,
    ) async {
      await tester.pumpWidget(
        hosted(StoryCanvas(background: 'pink', body: oldStory().body)),
      );
      final text = tester.widget<Text>(find.text('gm'));
      expect(text.style!.fontFamily, 'SpaceGrotesk');
      expect(text.style!.color, VibeColors.ink);
      expect(text.style!.backgroundColor, isNull);
    });

    testWidgets('an unknown background is lime and an unknown style clean', (
      tester,
    ) async {
      await tester.pumpWidget(
        hosted(
          const StoryCanvas(
            background: 'from-the-future',
            textStyle: 'comic',
            body: 'hello',
          ),
        ),
      );
      final box = tester.widget<AnimatedContainer>(
        find.byKey(const Key('story-backdrop')),
      );
      final gradient =
          (box.decoration! as BoxDecoration).gradient! as LinearGradient;
      expect(gradient.colors, [VibeColors.lime, VibeColors.lime]);
      expect(
        tester.widget<Text>(find.text('hello')).style!.fontFamily,
        'SpaceGrotesk',
      );
    });

    testWidgets('every style draws its own look', (tester) async {
      Future<TextStyle> styleOf(String name, String background) async {
        await tester.pumpWidget(
          hosted(
            StoryCanvas(
              background: background,
              textStyle: name,
              body: 'Hi there',
            ),
          ),
        );
        return tester.widget<Text>(find.byType(Text)).style!;
      }

      final loud = await styleOf('loud', 'lime');
      expect(tester.widget<Text>(find.text('HI THERE')).data, 'HI THERE');
      expect(loud.fontFamily, 'Manrope');
      expect(loud.fontWeight, FontWeight.w800);
      expect((await styleOf('soft', 'lime')).fontWeight, FontWeight.w500);
      // Glow is a halo: on a dark backdrop it is lime.
      final glow = await styleOf('glow', 'midnight');
      expect(glow.shadows, isNotEmpty);
      expect(glow.shadows!.first.color, VibeColors.lime);
      expect(glow.color, VibeColors.cream);
      // Stamp is a solid label behind the words, in the ink colour.
      final stamp = await styleOf('stamp', 'lime');
      expect(stamp.backgroundColor, VibeColors.ink);
      expect(stamp.color, VibeColors.lime);
      final type = await styleOf('type', 'lime');
      expect(type.fontFeatures, isNotEmpty);
    });

    testWidgets('a photo story puts its caption over a scrim in white', (
      tester,
    ) async {
      await tester.pumpWidget(
        hosted(
          const StoryCanvas(
            background: 'lime',
            body: 'caption',
            photo: ColoredBox(key: Key('the-photo'), color: Colors.teal),
          ),
        ),
      );
      expect(find.byKey(const Key('the-photo')), findsOneWidget);
      expect(
        tester.widget<Text>(find.text('caption')).style!.color,
        Colors.white,
      );
    });

    testWidgets('a thumbnail is a miniature, not a clipped crop', (
      tester,
    ) async {
      await tester.pumpWidget(
        hosted(
          StoryCanvas(background: 'pink', body: 'x' * 280, decorative: true),
          size: const Size(64, 88),
        ),
      );
      expect(tester.takeException(), isNull);
      final style = tester.widget<Text>(find.byType(Text)).style!;
      expect(style.fontSize!, lessThan(6));
    });

    testWidgets(
      'fades between backgrounds, or switches at once without motion',
      (tester) async {
        Duration duration() => tester
            .widget<AnimatedContainer>(find.byKey(const Key('story-backdrop')))
            .duration;
        Widget canvas() => const StoryCanvas(background: 'pink', animate: true);
        await tester.pumpWidget(hosted(canvas()));
        expect(duration(), greaterThan(Duration.zero));
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(disableAnimations: true);
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
        await tester.pumpWidget(hosted(canvas()));
        await tester.pump();
        expect(duration(), Duration.zero);
      },
    );
  });

  group('The composer', () {
    testWidgets('Share stays idle until there are words, then is ready', (
      tester,
    ) async {
      final api = pt.PulseApi();
      final c = Composer(tester, api, MemoryStoryDraftStore());
      await c.start();
      expect(c.key('share-idle'), findsOneWidget);
      await tester.tap(c.key('share-story'));
      await tester.pumpAndSettle();
      expect(api.storySent, isNull, reason: 'a disabled Share sends nothing');
      await c.type('   ');
      expect(c.key('share-idle'), findsOneWidget);
      await c.type('hi');
      expect(c.key('share-ready'), findsOneWidget);
      expect(c.key('share-idle'), findsNothing);
    });

    testWidgets('sharing buzzes once and sends everything chosen', (
      tester,
    ) async {
      final buzzes = <Object?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            buzzes.add(call.arguments);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final api = pt.PulseApi();
      final c = Composer(tester, api, MemoryStoryDraftStore());
      await c.start();
      await c.type('  hello there  ');
      await c.tap('swatch-ocean');
      await c.tap('tool-text');
      await c.tap('style-stamp');
      await c.tap('tool-time');
      await c.tap('hours-12');
      await c.tap('tool-who');
      await c.tap('audience-public');
      buzzes.clear();
      await c.tap('share-story');
      expect(buzzes, ['HapticFeedbackType.lightImpact']);
      // Every field is always sent, so what the server stores never depends on its defaults.
      expect(api.storySent, {
        'body': 'hello there',
        'background': 'ocean',
        'textStyle': 'stamp',
        'lifetimeHours': 12,
        'mediaId': null,
        'audience': 'public',
      });
      expect(find.text('Added to your story.'), findsOneWidget);
      expect(find.text('home'), findsOneWidget, reason: 'the composer closed');
    });

    testWidgets(
      'the defaults are lime, clean, 24 hours and the privacy audience',
      (tester) async {
        final api = pt.PulseApi();
        final c = Composer(tester, api, MemoryStoryDraftStore());
        await c.start();
        await c.type('hi');
        await c.tap('share-story');
        expect(api.storySent, {
          'body': 'hi',
          'background': 'lime',
          'textStyle': 'clean',
          'lifetimeHours': 24,
          'mediaId': null,
          // The fixture's privacy setting: stories go to friends.
          'audience': 'friends',
        });
      },
    );

    testWidgets('choosing a background and a style changes the preview', (
      tester,
    ) async {
      final c = Composer(tester, pt.PulseApi(), MemoryStoryDraftStore());
      await c.start();
      await c.type('night owl');
      expect(c.canvas.background, 'lime');
      expect(c.field.style!.color, VibeColors.ink);
      await c.tap('swatch-midnight');
      expect(c.canvas.background, 'midnight');
      // The ink is picked for contrast: cream on a dark gradient.
      expect(c.field.style!.color, VibeColors.cream);
      await c.tap('swatch-mango');
      expect(c.field.style!.color, VibeColors.ink);
      await c.tap('tool-text');
      for (final name in storyTextStyles.map((s) => s.name)) {
        await c.tap('style-$name');
        expect(c.canvas.textStyle, name);
        expect(c.field.style!.fontFamily, storyTextSpecFor(name).family);
      }
      await c.tap('style-loud');
      expect(c.field.style!.fontWeight, FontWeight.w800);
      // Typing keeps its case; the style only changes how it is drawn.
      expect(c.typed, 'night owl');
    });

    testWidgets('the colour row scrolls through every swatch', (tester) async {
      final c = Composer(tester, pt.PulseApi(), MemoryStoryDraftStore());
      await c.start();
      for (final b in storyBackgrounds) {
        await c.tap('swatch-${b.name}');
        expect(c.canvas.background, b.name);
      }
    });

    testWidgets('text alignment is left, centre or right', (tester) async {
      final c = Composer(tester, pt.PulseApi(), MemoryStoryDraftStore());
      await c.start();
      expect(c.field.textAlign, TextAlign.center);
      await c.tap('tool-text');
      await c.tap('align-right');
      expect(c.field.textAlign, TextAlign.right);
      expect(c.canvas.align, TextAlign.right);
      await c.tap('align-left');
      expect(c.field.textAlign, TextAlign.left);
    });

    testWidgets('tapping anywhere on the canvas focuses the text', (
      tester,
    ) async {
      final c = Composer(tester, pt.PulseApi(), MemoryStoryDraftStore());
      await c.start();
      expect(c.field.focusNode!.hasFocus, isFalse);
      final box = tester.getRect(c.key('story-canvas'));
      await tester.tapAt(box.topLeft + const Offset(20, 40));
      await tester.pump();
      expect(c.field.focusNode!.hasFocus, isTrue);
      expect(c.field.cursorWidth, greaterThanOrEqualTo(2));
      expect(find.text('Type your vibe…'), findsOneWidget);
    });

    testWidgets('the counter ring follows the words up to 280', (tester) async {
      final c = Composer(tester, pt.PulseApi(), MemoryStoryDraftStore());
      await c.start();
      final label = find.bySemanticsLabel('0 of 280 characters used');
      final semantics = tester.ensureSemantics();
      expect(label, findsOneWidget);
      await c.type('abc');
      expect(find.bySemanticsLabel('3 of 280 characters used'), findsOneWidget);
      expect(c.key('story-counter-left'), findsNothing);
      await c.type('a' * 250);
      expect(c.key('story-counter-left'), findsOneWidget);
      expect(find.text('30'), findsOneWidget);
      // More cannot be typed, counted in characters the way the server counts.
      await c.type('a' * 400);
      expect(c.typed.runes, hasLength(280));
      expect(
        find.bySemanticsLabel('280 of 280 characters used'),
        findsOneWidget,
      );
      await c.type('😀' * 300);
      expect(c.typed.runes, hasLength(280));
      semantics.dispose();
    });

    testWidgets('vibe chips add their words and respect the limit', (
      tester,
    ) async {
      final c = Composer(tester, pt.PulseApi(), MemoryStoryDraftStore());
      await c.start();
      await c.tap('tool-vibes');
      await c.tap('vibe-sleepy');
      expect(c.typed, '😴 sleepy');
      await c.tap('vibe-on fire');
      expect(c.typed, '😴 sleepy 🔥 on fire');
      expect(c.key('share-ready'), findsOneWidget);
      // Fill it to 270 characters: another vibe of 10 does not fit by one, and nothing is added.
      await c.type('a' * 275);
      await c.tap('vibe-sleepy');
      expect(c.typed, 'a' * 275);
      expect(find.text('Not enough room left for that.'), findsOneWidget);
      // Exactly enough room is enough.
      await c.type('a' * (280 - '😴 sleepy'.runes.length - 1));
      await c.tap('vibe-sleepy');
      expect(c.typed.runes, hasLength(280));
      expect(c.typed.endsWith('😴 sleepy'), isTrue);
    });

    testWidgets('three duration chips, 24 hours to begin with', (tester) async {
      final api = pt.PulseApi();
      final c = Composer(tester, api, MemoryStoryDraftStore());
      await c.start();
      await c.tap('tool-time');
      expect(find.text('Gone 24 hours after you share'), findsOneWidget);
      for (final h in [6, 12, 24]) {
        expect(c.key('hours-$h'), findsOneWidget);
        expect(find.byIcon(Icons.schedule_rounded), findsNWidgets(3));
      }
      await c.tap('hours-6');
      expect(find.text('Gone 6 hours after you share'), findsOneWidget);
      // The tab shows the choice, so it is visible from the other panels.
      expect(find.text('6h'), findsNWidgets(2));
      await c.type('quick one');
      await c.tap('share-story');
      expect(api.storySent!['lifetimeHours'], 6);
    });

    testWidgets('the audience hint follows the choice', (tester) async {
      final api = pt.PulseApi();
      final c = Composer(tester, api, MemoryStoryDraftStore());
      await c.start();
      await c.tap('tool-who');
      // The fixture's privacy setting is friends.
      expect(find.text('Only your friends'), findsOneWidget);
      expect(find.text('💚 Friends'), findsWidgets);
      await c.tap('audience-public');
      expect(find.text('Anyone on Hiyall can watch'), findsOneWidget);
      expect(find.text('Only your friends'), findsNothing);
      await c.tap('audience-followers');
      expect(find.text('Only your followers'), findsOneWidget);
      await c.type('for my people');
      await c.tap('share-story');
      expect(api.storySent!['audience'], 'followers');
    });

    testWidgets('a daily limit is explained in the server’s words', (
      tester,
    ) async {
      final api = pt.PulseApi()
        ..storyFailure = const ApiFailure(
          'You’ve reached today’s limit of 30 stories. Try again later.',
          429,
          'QUOTA',
          Duration(hours: 5),
        );
      final drafts = MemoryStoryDraftStore();
      final c = Composer(tester, api, drafts);
      await c.start();
      await c.type('one more');
      await c.settleDraft();
      await c.tap('share-story');
      expect(
        find.text(
          'You’ve reached today’s limit of 30 stories. Try again in about 5 hours.',
        ),
        findsOneWidget,
      );
      // Nothing was lost: the words are still here, saved, and Share can be tried again.
      expect(c.typed, 'one more');
      expect(find.text('home'), findsNothing);
      expect(c.key('share-ready'), findsOneWidget);
      expect(drafts.drafts[anjaliId], isNotNull);
    });

    testWidgets('another failure does not show raw errors', (tester) async {
      final api = pt.PulseApi()..storyFailure = StateError('boom');
      final c = Composer(tester, api, MemoryStoryDraftStore());
      await c.start();
      await c.type('hi');
      await c.tap('share-story');
      expect(find.text('Couldn’t share. Try again.'), findsOneWidget);
      expect(find.textContaining('boom'), findsNothing);
    });
  });

  group('Drafts', () {
    testWidgets('every change is saved and restored when it reopens', (
      tester,
    ) async {
      final drafts = MemoryStoryDraftStore();
      final c = Composer(tester, pt.PulseApi(), drafts);
      await c.start();
      await c.type('half a thought');
      await c.tap('swatch-grape');
      await c.tap('tool-text');
      await c.tap('style-glow');
      await c.tap('align-left');
      await c.tap('tool-time');
      await c.tap('hours-12');
      await c.tap('tool-who');
      await c.tap('audience-followers');
      await c.settleDraft();
      final saved = StoryDraft.decode(drafts.drafts[anjaliId])!;
      expect(
        (
          saved.text,
          saved.background,
          saved.textStyle,
          saved.align,
          saved.audience,
          saved.lifetimeHours,
        ),
        ('half a thought', 'grape', 'glow', 'left', 'followers', 12),
      );
      // Leave without any dialog by choosing "Save draft", then come back.
      await c.tap('story-close');
      await c.tap('save-draft');
      expect(find.text('home'), findsOneWidget);
      await c.open();
      expect(c.typed, 'half a thought');
      expect(c.canvas.background, 'grape');
      expect(c.canvas.textStyle, 'glow');
      expect(c.field.textAlign, TextAlign.left);
      expect(find.text('Picked up where you left off.'), findsOneWidget);
      await c.tap('tool-time');
      expect(find.text('Gone 12 hours after you share'), findsOneWidget);
      await c.tap('tool-who');
      expect(find.text('Only your followers'), findsOneWidget);
    });

    testWidgets('a draft that loads late never overwrites new typing', (
      tester,
    ) async {
      final drafts = _SlowDrafts()
        ..drafts[anjaliId] = const StoryDraft(text: 'old words').encode();
      final c = Composer(tester, pt.PulseApi(), drafts);
      await c.start();
      await c.type('new words');
      drafts.gate.complete();
      await tester.pumpAndSettle();
      expect(c.typed, 'new words');
    });

    testWidgets('sharing clears the draft', (tester) async {
      final drafts = MemoryStoryDraftStore();
      final c = Composer(tester, pt.PulseApi(), drafts);
      await c.start();
      await c.type('about to share');
      await c.settleDraft();
      expect(drafts.drafts[anjaliId], isNotNull);
      await c.tap('share-story');
      expect(drafts.drafts, isEmpty);
      await c.open();
      expect(c.typed, isEmpty);
      expect(find.text('Picked up where you left off.'), findsNothing);
    });

    testWidgets('closing an empty composer asks nothing', (tester) async {
      final drafts = MemoryStoryDraftStore();
      final c = Composer(tester, pt.PulseApi(), drafts);
      await c.start();
      await c.tap('story-close');
      expect(find.text('Discard draft?'), findsNothing);
      expect(find.text('home'), findsOneWidget);
      expect(drafts.drafts, isEmpty);
    });

    testWidgets('closing with words asks first; keep editing stays', (
      tester,
    ) async {
      final c = Composer(tester, pt.PulseApi(), MemoryStoryDraftStore());
      await c.start();
      await c.type('do not lose me');
      await c.tap('story-close');
      expect(find.text('Discard draft?'), findsOneWidget);
      await c.tap('keep-editing');
      expect(find.text('Discard draft?'), findsNothing);
      expect(c.typed, 'do not lose me');
      expect(find.text('home'), findsNothing);
    });

    testWidgets('discarding throws the draft away', (tester) async {
      final drafts = MemoryStoryDraftStore();
      final c = Composer(tester, pt.PulseApi(), drafts);
      await c.start();
      await c.type('never mind');
      await c.settleDraft();
      expect(drafts.drafts[anjaliId], isNotNull);
      await c.tap('story-close');
      await c.tap('discard-draft');
      expect(find.text('home'), findsOneWidget);
      expect(drafts.drafts, isEmpty);
      await c.open();
      expect(c.typed, isEmpty);
    });

    testWidgets('the system back gesture asks the same question', (
      tester,
    ) async {
      final c = Composer(tester, pt.PulseApi(), MemoryStoryDraftStore());
      await c.start();
      await c.type('words');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Discard draft?'), findsOneWidget);
      await c.tap('keep-editing');
      await c.tap('story-close');
      await c.tap('discard-draft');
      expect(find.text('home'), findsOneWidget);
    });

    testWidgets(
      'leaving by any route still saves what was typed a moment ago',
      (tester) async {
        final drafts = MemoryStoryDraftStore();
        final c = Composer(tester, pt.PulseApi(), drafts);
        await c.start();
        await c.type('typed just now');
        // No time for the debounce: the screen goes away.
        c.nav.currentState!.pop();
        await tester.pumpAndSettle();
        expect(
          StoryDraft.decode(drafts.drafts[anjaliId])!.text,
          'typed just now',
        );
      },
    );
  });

  group('Photos', () {
    testWidgets('a photo replaces the colours and carries the caption', (
      tester,
    ) async {
      final api = pt.PulseApi();
      final c = Composer(tester, api, MemoryStoryDraftStore());
      await c.start();
      expect(c.key('tool-colour'), findsOneWidget);
      expect(c.key('story-gallery'), findsOneWidget);
      expect(c.key('story-camera'), findsOneWidget);
      await c.tap('story-gallery');
      expect(
        api.calls.where((x) => x.startsWith('upload story image/png')),
        hasLength(1),
      );
      expect(c.picker.sources, [ImageSource.gallery]);
      // No background row for a photo; the text tab opens instead.
      expect(c.key('tool-colour'), findsNothing);
      expect(c.key('swatches'), findsNothing);
      expect(c.key('style-clean'), findsOneWidget);
      expect(find.text('Change photo'), findsOneWidget);
      expect(find.text('Remove'), findsOneWidget);
      expect(c.key('story-gallery'), findsNothing);
      // The caption is optional, still styled, and sits over the photo.
      expect(c.key('share-ready'), findsOneWidget);
      await c.type('look at this');
      await c.tap('style-loud');
      expect(c.field.style!.color, Colors.white);
      await c.tap('share-story');
      expect(api.storySent!['mediaId'], startsWith('media-'));
      expect(api.storySent!['body'], 'look at this');
      expect(api.storySent!['textStyle'], 'loud');
    });

    testWidgets(
      'the camera button opens the camera, and a photo can be removed',
      (tester) async {
        final c = Composer(tester, pt.PulseApi(), MemoryStoryDraftStore());
        await c.start();
        await c.tap('story-camera');
        expect(c.picker.sources, [ImageSource.camera]);
        expect(c.key('story-remove-photo'), findsOneWidget);
        await c.tap('story-remove-photo');
        expect(c.key('story-gallery'), findsOneWidget);
        expect(c.key('tool-colour'), findsOneWidget);
        expect(c.key('share-idle'), findsOneWidget);
      },
    );

    testWidgets('Share waits for the upload, and a refused one says why', (
      tester,
    ) async {
      final api = pt.PulseApi()
        ..uploadFailure = const ApiFailure(
          'Your photo storage is full. Delete some posts or stories to free space.',
          429,
          'QUOTA',
        );
      final c = Composer(tester, api, MemoryStoryDraftStore());
      await c.start();
      await c.tap('story-gallery');
      expect(
        find.text(
          'Your photo storage is full. Delete some posts or stories to free space.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Photo limit reached'), findsOneWidget);
      expect(c.key('share-idle'), findsOneWidget);
      expect(
        c.key('story-retry'),
        findsNothing,
        reason: 'a limit is not retried',
      );
    });

    testWidgets('a failed upload offers to try again', (tester) async {
      final api = pt.PulseApi()..uploadFailure = const ApiFailure('Offline');
      final c = Composer(tester, api, MemoryStoryDraftStore());
      await c.start();
      await c.tap('story-gallery');
      expect(c.key('story-retry'), findsOneWidget);
      expect(c.key('share-idle'), findsOneWidget);
      api.uploadFailure = null;
      await tester.tap(c.key('story-retry'));
      await tester.pumpAndSettle();
      expect(c.key('share-ready'), findsOneWidget);
    });

    testWidgets(
      'closing with only a photo still asks, without offering a draft',
      (tester) async {
        final c = Composer(tester, pt.PulseApi(), MemoryStoryDraftStore());
        await c.start();
        await c.tap('story-gallery');
        await c.tap('story-close');
        expect(find.text('Discard draft?'), findsOneWidget);
        expect(c.key('save-draft'), findsNothing);
        await c.tap('discard-draft');
        expect(find.text('home'), findsOneWidget);
      },
    );
  });

  group('Layout and access', () {
    testWidgets('every control has a name for screen readers', (tester) async {
      final semantics = tester.ensureSemantics();
      final c = Composer(tester, pt.PulseApi(), MemoryStoryDraftStore());
      await c.start();
      for (final label in [
        'Close',
        'Share story',
        'Photo',
        'Camera',
        'Colour',
        'Text style',
        'Vibes',
        'Lasts 24 hours',
        'Who can see this: Friends',
        'lime background',
        'sunset background',
        '0 of 280 characters used',
      ]) {
        expect(find.bySemanticsLabel(label), findsOneWidget, reason: label);
      }
      await c.tap('tool-text');
      for (final label in [
        'Align left',
        'Align centre',
        'Align right',
        'Clean text style',
        'Loud text style',
        'Soft text style',
        'Glow text style',
        'Stamp text style',
        'Type text style',
      ]) {
        expect(find.bySemanticsLabel(label), findsOneWidget, reason: label);
      }
      await c.tap('tool-time');
      expect(find.bySemanticsLabel('Lasts 6 hours'), findsOneWidget);
      await c.tap('tool-who');
      for (final label in ['Everyone', 'Followers', 'Friends']) {
        expect(find.bySemanticsLabel(label), findsOneWidget, reason: label);
      }
      await c.tap('tool-vibes');
      expect(find.bySemanticsLabel('😴 sleepy'), findsOneWidget);
      expect(find.bySemanticsLabel('Story text'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('every control is at least 48 by 48', (tester) async {
      final c = Composer(tester, pt.PulseApi(), MemoryStoryDraftStore());
      await c.start();
      void checkAll(Iterable<String> keys) {
        for (final k in keys) {
          final size = tester.getSize(c.key(k));
          expect(size.width, greaterThanOrEqualTo(48), reason: k);
          expect(size.height, greaterThanOrEqualTo(48), reason: k);
        }
      }

      checkAll([
        'story-close',
        'share-story',
        'story-gallery',
        'story-camera',
        'tool-colour',
        'tool-text',
        'tool-vibes',
        'tool-time',
        'tool-who',
        'swatch-lime',
        'swatch-sunset',
      ]);
      await c.tap('tool-text');
      checkAll(['align-left', 'align-center', 'style-clean', 'style-stamp']);
      await c.tap('tool-time');
      checkAll(['hours-6', 'hours-12', 'hours-24']);
      await c.tap('tool-who');
      checkAll(['audience-public', 'audience-followers', 'audience-friends']);
      await c.tap('tool-vibes');
      checkAll(['vibe-sleepy', 'vibe-gaming']);
    });

    testWidgets('pressed controls scale instead of showing ink', (
      tester,
    ) async {
      final c = Composer(tester, pt.PulseApi(), MemoryStoryDraftStore());
      await c.start();
      expect(find.byType(InkWell), findsNothing);
      double scaleOf() => tester
          .widget<AnimatedScale>(
            find.descendant(
              of: c.key('story-camera'),
              matching: find.byType(AnimatedScale),
            ),
          )
          .scale;
      expect(scaleOf(), 1);
      final press = await tester.startGesture(
        tester.getCenter(c.key('story-camera')),
      );
      await tester.pump();
      expect(scaleOf(), lessThan(1));
      await press.cancel();
      await tester.pump();
      expect(scaleOf(), 1);
    });

    testWidgets(
      'without motion the swatches and the share button do not animate',
      (tester) async {
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(disableAnimations: true);
        addTearDown(
          tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
        );
        final c = Composer(tester, pt.PulseApi(), MemoryStoryDraftStore());
        await c.start();
        expect(
          tester
              .widget<AnimatedContainer>(
                find.byKey(const Key('story-backdrop')),
              )
              .duration,
          Duration.zero,
        );
        final swatch = find.descendant(
          of: c.key('swatch-lime'),
          matching: find.byType(AnimatedScale),
        );
        // The tap target's own press scale is first, the swatch's grow-and-bounce last.
        expect(
          tester.widget<AnimatedScale>(swatch.last).duration,
          Duration.zero,
        );
        await tester.tap(c.key('story-camera'));
        await tester.pump();
        await c.type('hi');
        final press = await tester.startGesture(
          tester.getCenter(c.key('share-story')),
        );
        await tester.pump();
        expect(
          tester
              .widget<AnimatedScale>(
                find.descendant(
                  of: c.key('share-story'),
                  matching: find.byType(AnimatedScale),
                ),
              )
              .scale,
          1,
        );
        await press.cancel();
      },
    );

    testWidgets(
      'with the keyboard open the canvas, text and Share stay usable',
      (tester) async {
        final c = Composer(tester, pt.PulseApi(), MemoryStoryDraftStore());
        await c.start();
        await c.tap('tool-text');
        tester.view.viewInsets = const FakeViewPadding(bottom: 320);
        addTearDown(tester.view.resetViewInsets);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final screen = tester.view.physicalSize.height - 320;
        final canvas = tester.getRect(c.key('story-canvas'));
        expect(canvas.bottom, lessThanOrEqualTo(screen));
        expect(canvas.height, greaterThan(200));
        expect(canvas.width / canvas.height, closeTo(9 / 16, .01));
        expect(tester.getRect(c.key('share-story')).bottom, lessThan(screen));
        expect(
          tester.getRect(c.key('tool-text')).bottom,
          lessThanOrEqualTo(screen),
        );
        // Only the tabs stay; the photo buttons and the panel make room.
        expect(c.key('story-gallery'), findsNothing);
        expect(c.key('style-clean'), findsNothing);
        await c.type('typing with the keyboard up');
        expect(c.key('share-ready'), findsOneWidget);
        // Opening a tab closes the keyboard and shows its panel.
        tester.view.resetViewInsets();
        await c.tap('tool-vibes');
        expect(c.key('vibe-sleepy'), findsOneWidget);
      },
    );

    testWidgets('a short window scrolls instead of overflowing', (
      tester,
    ) async {
      final c = Composer(tester, pt.PulseApi(), MemoryStoryDraftStore());
      await c.start(size: const Size(700, 360));
      expect(tester.takeException(), isNull);
      await c.type('landscape');
      expect(c.key('share-ready'), findsOneWidget);
    });

    for (final size in [
      const Size(1440, 900),
      const Size(320, 568),
      const Size(390, 844),
    ]) {
      for (final brightness in [Brightness.dark, Brightness.light]) {
        testWidgets('lays out on $size in $brightness without overflow', (
          tester,
        ) async {
          final c = Composer(tester, pt.PulseApi(), MemoryStoryDraftStore());
          await c.start(size: size, brightness: brightness);
          final canvas = tester.getRect(c.key('story-canvas'));
          expect(canvas.width / canvas.height, closeTo(9 / 16, .01));
          expect(canvas.left, greaterThanOrEqualTo(0));
          expect(canvas.right, lessThanOrEqualTo(size.width));
          await c.type('a' * 280);
          await c.tap('swatch-aurora');
          await c.tap('tool-text');
          await c.tap('style-type');
          await c.tap('tool-who');
          await c.tap('tool-time');
          expect(tester.takeException(), isNull);
        });
      }
    }

    testWidgets('the same at double text size', (tester) async {
      final c = Composer(tester, pt.PulseApi(), MemoryStoryDraftStore());
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await c.start();
      await c.type('big text day');
      await c.tap('tool-text');
      await c.tap('tool-who');
      await c.tap('story-camera');
      expect(tester.takeException(), isNull);
      // The story's own text does not grow with the setting: it is art sized by the canvas.
      expect(c.field.style!.fontSize, lessThan(60));
    });
  });

  group('Stories elsewhere', () {
    testWidgets('the viewer draws a story in its text style', (tester) async {
      final now = DateTime.now();
      final groups = [
        StoryGroup(pt.niko, [
          Story(
            storyId: 'n1',
            body: 'gm',
            background: 'sunset',
            textStyle: 'loud',
            audience: 'public',
            createdAt: now,
            expiresAt: now.add(const Duration(hours: 5, minutes: 30)),
          ),
          Story(
            storyId: 'n2',
            body: 'from a newer server',
            background: 'from-the-future',
            textStyle: 'from-the-future',
            audience: 'public',
            createdAt: now,
            expiresAt: now.add(const Duration(hours: 5)),
          ),
        ]),
      ];
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiProvider.overrideWithValue(pt.PulseApi()),
            sessionProvider.overrideWith(SignedIn.new),
          ],
          child: MaterialApp(navigatorKey: nav, home: const Text('home')),
        ),
      );
      nav.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => StoryViewer(groups: groups, start: 0),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('GM'), findsOneWidget);
      var canvas = tester.widget<StoryCanvas>(find.byType(StoryCanvas));
      expect((canvas.background, canvas.textStyle), ('sunset', 'loud'));
      await tester.tapAt(const Offset(700, 300));
      await tester.pump(const Duration(milliseconds: 100));
      canvas = tester.widget<StoryCanvas>(find.byType(StoryCanvas));
      expect(find.text('from a newer server'), findsOneWidget);
      // Unknown names are drawn with the defaults, not an error.
      expect(tester.takeException(), isNull);
      expect(
        tester.widget<Text>(find.text('from a newer server')).style!.fontFamily,
        'SpaceGrotesk',
      );
      await tester.tap(find.byKey(const Key('close-stories')));
      await tester.pumpAndSettle();
    });

    testWidgets('your own story in the viewer shows how long it has left', (
      tester,
    ) async {
      final now = DateTime.now();
      final groups = [
        StoryGroup(pt.me, [
          Story(
            storyId: 'm1',
            body: 'mine',
            background: 'ocean',
            textStyle: 'glow',
            audience: 'public',
            createdAt: now,
            expiresAt: now.add(const Duration(hours: 5, minutes: 30)),
            viewCount: 1,
          ),
        ], mine: true),
      ];
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiProvider.overrideWithValue(pt.PulseApi()),
            sessionProvider.overrideWith(SignedIn.new),
          ],
          child: MaterialApp(navigatorKey: nav, home: const Text('home')),
        ),
      );
      nav.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => StoryViewer(groups: groups, start: 0),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('5h left'), findsOneWidget);
      await tester.tap(find.byKey(const Key('close-stories')));
      await tester.pumpAndSettle();
    });
  });
}

/// A draft store whose first read waits, as a slow keystore does.
class _SlowDrafts extends MemoryStoryDraftStore {
  final gate = Completer<void>();
  @override
  Future<StoryDraft?> read(String userId) async {
    await gate.future;
    return super.read(userId);
  }
}
