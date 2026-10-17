import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/core/theme.dart';
import 'package:hiyall/features/chat_format.dart';
import 'package:hiyall/shared/avatar_gradient.dart';
import 'package:hiyall/shared/chat_tokens.dart';

/// A colour drawn over another, as the screen shows it.
Color over(Color top, Color bottom) => Color.alphaBlend(top, bottom);

void main() {
  group('tokens', () {
    test(
      'both themes register the extension, and a plain theme falls back',
      () {
        expect(
          hiyallTheme(Brightness.dark).extension<ChatTokens>()!.isDark,
          isTrue,
        );
        expect(
          hiyallTheme(Brightness.light).extension<ChatTokens>()!.isDark,
          isFalse,
        );
        expect(
          hiyallTheme(Brightness.dark).scaffoldBackgroundColor,
          ChatTokens.dark.bg,
        );
      },
    );

    testWidgets('ChatTokens.of works under a plain ThemeData', (tester) async {
      late ChatTokens dark, light;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: Brightness.dark),
          home: Builder(
            builder: (context) {
              dark = ChatTokens.of(context);
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: Brightness.light),
          home: Builder(
            builder: (context) {
              light = ChatTokens.of(context);
              return const SizedBox();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(dark.isDark, isTrue);
      expect(light.isDark, isFalse);
    });
  });

  group('contrast (WCAG AA)', () {
    for (final (name, t) in [
      ('dark', ChatTokens.dark),
      ('light', ChatTokens.light),
    ]) {
      test(
        '$name: onError is at least 4.5:1 on error, and the theme agrees',
        () {
          expect(contrastRatio(t.onError, t.error), greaterThanOrEqualTo(4.5));
          final scheme = hiyallTheme(t.brightness).colorScheme;
          expect(scheme.error, t.error);
          expect(scheme.onError, t.onError);
          expect(contrastRatio(scheme.onError, scheme.error), greaterThan(4.5));
        },
      );

      test('$name: text on every surface it sits on is at least 4.5:1', () {
        final surfaces = {
          'bg': t.bg,
          'bg2': t.bg2,
          'surface': t.surface,
          'elevated': t.elevated,
          'unreadRow': over(t.unreadRow, t.bg),
          'dock': t.dockSurface,
        };
        for (final MapEntry(key: label, value: surface) in surfaces.entries) {
          for (final (ink, what) in [
            (t.text, 'text'),
            (t.textSecondary, 'textSecondary'),
            (t.textTertiary, 'textTertiary'),
            (t.accent, 'accent'),
          ]) {
            expect(
              contrastRatio(ink, surface),
              greaterThanOrEqualTo(4.5),
              reason: '$what on $label ($name)',
            );
          }
          expect(
            contrastRatio(t.error, surface),
            greaterThanOrEqualTo(4.5),
            reason: 'error on $label ($name)',
          );
        }
      });

      test('$name: bubbles, badges and the lime button', () {
        expect(
          contrastRatio(t.incomingInk, t.incoming),
          greaterThanOrEqualTo(7),
        );
        expect(
          contrastRatio(t.incomingMeta, t.incoming),
          greaterThanOrEqualTo(4.5),
        );
        for (final c in t.outgoing) {
          expect(contrastRatio(t.outgoingInk, c), greaterThanOrEqualTo(7));
          expect(contrastRatio(t.outgoingMeta, c), greaterThanOrEqualTo(4.5));
          // The seen tick is graphics, not text.
          expect(contrastRatio(t.outgoingSeen, c), greaterThanOrEqualTo(3));
        }
        expect(contrastRatio(t.badgeInk, t.badgeFill), greaterThanOrEqualTo(7));
        expect(
          contrastRatio(t.mutedBadgeInk, t.mutedBadgeFill),
          greaterThanOrEqualTo(7),
        );
        expect(contrastRatio(t.onLime, t.lime), greaterThanOrEqualTo(7));
        // The selected filter chip and the send button.
        expect(contrastRatio(t.onLime, t.lime), greaterThanOrEqualTo(4.5));
      });

      test('$name: the lime unread badge and chip text read on the dock', () {
        // Dock badge: lime with ink in the dark theme, ink with lime in light.
        final fill = t.isDark ? VibeColors.lime : VibeColors.ink;
        final ink = t.isDark ? VibeColors.ink : VibeColors.lime;
        expect(contrastRatio(ink, fill), greaterThanOrEqualTo(7));
        // The selected dock label: lime on the dark dock, ink on the light one.
        final label = t.isDark ? t.accent : VibeColors.ink;
        expect(contrastRatio(label, t.dockSurface), greaterThanOrEqualTo(4.5));
      });
    }

    test('incoming bubbles stand off the page', () {
      expect(
        contrastRatio(ChatTokens.dark.incoming, ChatTokens.dark.bg),
        greaterThan(1.25),
      );
      expect(
        contrastRatio(ChatTokens.light.incomingBorder, ChatTokens.light.bg),
        greaterThan(1.05),
      );
      for (final t in [ChatTokens.dark, ChatTokens.light]) {
        expect(contrastRatio(t.outgoingTop, t.bg), greaterThan(1.1));
      }
    });

    test('incoming bubbles are separated from the page by luminance', () {
      // Absolute relative-luminance steps (0 black, 1 white), measured both
      // ways: the dark bubble is lighter than its page, the light one darker.
      final dark = ChatTokens.dark, light = ChatTokens.light;
      expect(
        dark.incoming.computeLuminance() - dark.bg.computeLuminance(),
        greaterThanOrEqualTo(.02),
      );
      expect(
        light.bg.computeLuminance() - light.incoming.computeLuminance(),
        greaterThanOrEqualTo(.08),
        reason: 'the old white bubble was 0.07 lighter than the page',
      );
      expect(
        contrastRatio(light.incoming, light.bg),
        greaterThanOrEqualTo(1.12),
      );
      // The hairline edge is a step further out, still gentle.
      expect(
        contrastRatio(light.incomingBorder, light.incoming),
        inInclusiveRange(1.1, 1.4),
      );
      // Cooler and greyer than the warm paper: less red than green and blue.
      expect(HSLColor.fromColor(light.incoming).saturation, lessThan(.2));
      // The lime stays unmistakably another thing from the incoming grey: a
      // saturated colour against a nearly neutral one, in both themes.
      for (final t in [dark, light]) {
        expect(
          HSLColor.fromColor(t.outgoingTop).saturation,
          greaterThanOrEqualTo(.6),
        );
        expect(
          HSLColor.fromColor(t.incoming).saturation,
          lessThanOrEqualTo(.2),
        );
      }
    });

    test('light incoming text and meta keep AA on the new bubble fill', () {
      final t = ChatTokens.light;
      expect(contrastRatio(t.incomingInk, t.incoming), greaterThanOrEqualTo(7));
      expect(
        contrastRatio(t.incomingMeta, t.incoming),
        greaterThanOrEqualTo(4.5),
      );
      expect(contrastRatio(t.error, t.incoming), greaterThanOrEqualTo(4.5));
    });

    test('the outgoing bubble is one hue, not a gradient to another', () {
      final a = HSLColor.fromColor(ChatTokens.dark.outgoingTop);
      final b = HSLColor.fromColor(ChatTokens.dark.outgoingBottom);
      expect((a.hue - b.hue).abs(), lessThan(6));
      expect((a.lightness - b.lightness).abs(), lessThan(.06));
    });
  });

  group('avatar gradient', () {
    test('the same id gives the same colours, run after run', () {
      expect(
        avatarColors('019a4000-0000-7000-8000-000000000001'),
        (avatarColors('019a4000-0000-7000-8000-000000000001')),
      );
      final g1 = avatarGradient('u-1');
      final g2 = avatarGradient('u-1');
      expect(g1.colors, g2.colors);
      expect(g1.begin, g2.begin);
    });

    test('the hash is a fixed function (so colours survive a restart)', () {
      // FNV-1a 32-bit reference values.
      expect(stableHash(''), 0x811c9dc5);
      expect(stableHash('a'), 0xe40c292c);
      expect(stableHash('foobar'), 0xbf9cf968);
    });

    test('different people spread over the palette', () {
      final seen = {for (var i = 0; i < 60; i++) avatarColors('user-$i')};
      expect(seen.length, greaterThanOrEqualTo(6));
    });

    test('the initial is readable on both ends of every gradient', () {
      for (final (a, b) in avatarPalettes) {
        expect(contrastRatio(VibeColors.ink, a), greaterThanOrEqualTo(4.5));
        expect(contrastRatio(VibeColors.ink, b), greaterThanOrEqualTo(4.5));
      }
    });
  });
}
