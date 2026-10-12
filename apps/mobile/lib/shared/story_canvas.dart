import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/theme.dart';

/// What a story is drawn on: a solid colour or a gradient. Names are what the server stores; a name
/// this app does not know (a newer server added one) is drawn as lime, so old apps never break.
class StoryBackground {
  final String name, label;

  /// One colour for a solid, two or three for a gradient (top to bottom).
  final List<Color> colors;
  const StoryBackground(this.name, this.label, this.colors);
  bool get isGradient => colors.length > 1;

  /// Solids are two equal stops so that fading between any two backgrounds is one gradient lerp.
  LinearGradient get gradient => LinearGradient(
    begin: const Alignment(-.5, -1),
    end: const Alignment(.5, 1),
    colors: isGradient ? colors : [colors.first, colors.first],
  );
}

const storyBackgrounds = [
  StoryBackground('lime', 'Lime', [VibeColors.lime]),
  StoryBackground('lilac', 'Lilac', [VibeColors.lilac]),
  StoryBackground('pink', 'Pink', [VibeColors.pink]),
  StoryBackground('mint', 'Mint', [VibeColors.mint]),
  StoryBackground('peach', 'Peach', [VibeColors.peach]),
  StoryBackground('ink', 'Ink', [VibeColors.ink]),
  StoryBackground('sunset', 'Sunset', [
    Color(0xffff9a62),
    Color(0xffff5c8a),
    Color(0xff8a4fd6),
  ]),
  StoryBackground('bubblegum', 'Bubblegum', [
    Color(0xfff9a8d4),
    Color(0xffc4b5fd),
  ]),
  StoryBackground('aurora', 'Aurora', [
    Color(0xff2dd4bf),
    Color(0xff6366f1),
    Color(0xffa855f7),
  ]),
  StoryBackground('ocean', 'Ocean', [Color(0xff0284c7), Color(0xff1e3a8a)]),
  StoryBackground('grape', 'Grape', [Color(0xff8b5cf6), Color(0xff3b0764)]),
  StoryBackground('mango', 'Mango', [Color(0xfffde047), Color(0xfffb923c)]),
  StoryBackground('midnight', 'Midnight', [
    Color(0xff0f172a),
    Color(0xff312e81),
  ]),
  StoryBackground('freshmint', 'Fresh mint', [
    Color(0xffa7f3d0),
    Color(0xffd2f65a),
  ]),
];

/// The background for a stored name, lime when the name is not known here.
StoryBackground storyBackgroundFor(String name) => storyBackgrounds.firstWhere(
  (b) => b.name == name,
  orElse: () => storyBackgrounds.first,
);

double _contrast(double a, double b) =>
    (math.max(a, b) + .05) / (math.min(a, b) + .05);

/// The text colour that reads best on a backdrop of these colours: ink or cream, whichever keeps the
/// better contrast against the worst of the colours (every stop of a gradient has to work).
Color storyInkFor(Iterable<Color> backdrop) {
  double worst(Color ink) => backdrop
      .map((c) => _contrast(c.computeLuminance(), ink.computeLuminance()))
      .reduce(math.min);
  return worst(VibeColors.ink) >= worst(VibeColors.cream)
      ? VibeColors.ink
      : VibeColors.cream;
}

/// How a story's words are drawn. Only the bundled fonts: Space Grotesk and Manrope.
class StoryTextSpec {
  final String name, label;
  final String family;
  final FontWeight weight;
  final double spacing, height, size;
  final bool caps, glow, highlight;
  final List<FontFeature> features;
  const StoryTextSpec(
    this.name,
    this.label, {
    this.family = 'SpaceGrotesk',
    this.weight = FontWeight.w700,
    this.spacing = 0,
    this.height = 1.2,
    this.size = 1,
    this.caps = false,
    this.glow = false,
    this.highlight = false,
    this.features = const [],
  });

  /// [px] is the size at this canvas width and [k] its scale against the 360 px design width, so
  /// shadows and spacing shrink with the text.
  TextStyle style({
    required Color ink,
    required double px,
    required double k,
    bool photo = false,
  }) {
    final onDark = ink.computeLuminance() > .5;
    Color color = ink;
    Color? mark;
    List<Shadow>? shadows;
    if (highlight) {
      mark = ink;
      color = onDark ? VibeColors.ink : VibeColors.lime;
    } else if (glow) {
      final halo = onDark ? VibeColors.lime : Colors.white;
      shadows = [
        Shadow(color: halo, blurRadius: 10 * k),
        Shadow(color: halo.withValues(alpha: .65), blurRadius: 26 * k),
      ];
    } else if (photo) {
      shadows = [Shadow(color: const Color(0x66000000), blurRadius: 8 * k)];
    }
    return TextStyle(
      fontFamily: family,
      fontSize: px * size,
      fontWeight: weight,
      letterSpacing: spacing * k,
      height: height,
      color: color,
      backgroundColor: mark,
      shadows: shadows,
      fontFeatures: features,
    );
  }
}

const storyTextStyles = [
  StoryTextSpec('clean', 'Clean', spacing: -.3),
  StoryTextSpec(
    'loud',
    'Loud',
    family: 'Manrope',
    weight: FontWeight.w800,
    caps: true,
    spacing: .6,
    height: 1.1,
    size: .88,
  ),
  StoryTextSpec(
    'soft',
    'Soft',
    family: 'Manrope',
    weight: FontWeight.w500,
    spacing: .2,
    height: 1.35,
    size: .92,
  ),
  StoryTextSpec('glow', 'Glow', glow: true),
  StoryTextSpec(
    'stamp',
    'Stamp',
    caps: true,
    highlight: true,
    spacing: 2,
    height: 1.45,
    size: .78,
  ),
  StoryTextSpec(
    'type',
    'Type',
    family: 'Manrope',
    weight: FontWeight.w600,
    spacing: 1.1,
    height: 1.4,
    size: .8,
    features: [FontFeature.tabularFigures()],
  ),
];

/// The text style for a stored name; stories from before text styles, and names this app does not
/// know, are clean.
StoryTextSpec storyTextSpecFor(String name) => storyTextStyles.firstWhere(
  (s) => s.name == name,
  orElse: () => storyTextStyles.first,
);

/// The words as drawn: upper case for the styles that shout. Only when the case change keeps the
/// length (ß becomes SS), so an editor's cursor never lands in the wrong place.
String storyDisplayText(String text, StoryTextSpec spec) {
  if (!spec.caps) return text;
  final upper = text.toUpperCase();
  return upper.length == text.length ? upper : text;
}

/// The size, in px at the 360 px design width, that lets the words fill the canvas without
/// overflowing: big for a few words, shrinking as the text gets longer or taller.
double storyFontSize(String text, {bool photo = false}) {
  final load = text.runes.length + '\n'.allMatches(text).length * 18;
  final size = load <= 18
      ? 44.0
      : load <= 45
      ? 36.0
      : load <= 90
      ? 30.0
      : load <= 150
      ? 26.0
      : load <= 220
      ? 23.0
      : 20.0;
  return photo ? math.min(size, 30) : size;
}

/// What an editor placed on a [StoryCanvas] needs to look exactly like the finished story.
class StoryTextLook {
  final TextStyle style;
  final Color ink;
  final TextAlign align;
  final double scale;
  final StoryTextSpec spec;
  const StoryTextLook({
    required this.style,
    required this.ink,
    required this.align,
    required this.scale,
    required this.spec,
  });
  Color get hint => ink.withValues(alpha: .5);
}

/// One story, drawn the same wherever it appears: the composer, the viewer and the My stories
/// thumbnails. A background (or a [photo] full-bleed on a soft scrim), the words on top with the
/// chosen text style, size fitted to the length, and a colour picked for contrast.
///
/// It lays itself out against a 360 px wide design, so a thumbnail is a faithful miniature. Pass
/// [editor] to put a text field where the words go; it is given the [StoryTextLook] to match.
class StoryCanvas extends StatelessWidget {
  final String background, textStyle, body;
  final Widget? photo;
  final TextAlign align;
  final Widget Function(BuildContext context, StoryTextLook look)? editor;

  /// Fades between backgrounds (composer); off for a viewer that swaps whole stories.
  final bool animate;

  /// Thumbnails repeat what the row beside them says, so they are hidden from screen readers.
  final bool decorative;
  const StoryCanvas({
    super.key,
    required this.background,
    this.textStyle = 'clean',
    this.body = '',
    this.photo,
    this.align = TextAlign.center,
    this.editor,
    this.animate = false,
    this.decorative = false,
  });

  Alignment get _alignment => switch (align) {
    TextAlign.left || TextAlign.start => Alignment.centerLeft,
    TextAlign.right || TextAlign.end => Alignment.centerRight,
    _ => Alignment.center,
  };

  @override
  Widget build(BuildContext context) {
    final bg = storyBackgroundFor(background);
    final spec = storyTextSpecFor(textStyle);
    final hasPhoto = photo != null;
    final slow = animate && !MediaQuery.disableAnimationsOf(context);
    final duration = slow ? const Duration(milliseconds: 380) : Duration.zero;
    final ink = hasPhoto ? Colors.white : storyInkFor(bg.colors);

    final canvas = LayoutBuilder(
      builder: (context, box) {
        final width = box.hasBoundedWidth ? box.maxWidth : 360.0;
        final k = (width / 360).clamp(.12, 1.6);
        final pad = 28 * k;
        return Stack(
          fit: StackFit.expand,
          children: [
            AnimatedContainer(
              key: const Key('story-backdrop'),
              duration: duration,
              curve: Curves.easeOutCubic,
              decoration: BoxDecoration(gradient: bg.gradient),
            ),
            if (hasPhoto) ...[
              Positioned.fill(child: photo!),
              const Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Color(0x33000000),
                          Color(0x00000000),
                          Color(0x99000000),
                        ],
                        stops: [0, .45, 1],
                      ),
                    ),
                  ),
                ),
              ),
            ],
            Positioned.fill(
              child: Padding(
                // Room for the viewer's header and the author's "Seen by" button.
                padding: EdgeInsets.fromLTRB(pad, 64 * k, pad, 64 * k),
                child: Align(
                  alignment: hasPhoto
                      ? const Alignment(0, .62)
                      : Alignment.center,
                  child: TweenAnimationBuilder<Color?>(
                    tween: ColorTween(end: ink),
                    duration: duration,
                    builder: (context, color, _) {
                      final px = storyFontSize(body, photo: hasPhoto) * k;
                      final style = spec.style(
                        ink: color ?? ink,
                        px: px,
                        k: k,
                        photo: hasPhoto,
                      );
                      if (editor != null) {
                        return editor!(
                          context,
                          StoryTextLook(
                            style: style,
                            ink: color ?? ink,
                            align: align,
                            scale: k,
                            spec: spec,
                          ),
                        );
                      }
                      if (body.isEmpty) return const SizedBox.shrink();
                      return FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: _alignment,
                        child: SizedBox(
                          width: math.max(1, width - pad * 2),
                          child: Text(
                            storyDisplayText(body, spec),
                            textAlign: align,
                            // Story text is art sized by the layout, not by the reader's text size.
                            textScaler: TextScaler.noScaling,
                            style: style,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
    return decorative ? ExcludeSemantics(child: canvas) : canvas;
  }
}
