import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../shared/chat_tokens.dart';
import '../shared/presence_dot.dart';

/// Colours of the Discover screen, derived from [ChatTokens] so it follows the
/// same "Midnight Social Club" palette as Home and Chats in both themes. Every
/// foreground/background pair here is checked for WCAG AA in
/// `discover_redesign_test.dart` through [pairs].
class DiscoverStyle {
  final ChatTokens t;
  const DiscoverStyle(this.t);

  /// Whether a row's avatar carries a corner badge with the country code ("IN",
  /// "KR"). Off: the badge says nothing about why someone is worth a hello and can
  /// read as a precise location. The country stays on the profile, and distance
  /// buckets show only in the Nearby category. This is the one switch to bring the
  /// badge back (rows then move the online dot to the top left, as before).
  static const showCountryBadge = false;

  factory DiscoverStyle.of(BuildContext context) =>
      DiscoverStyle(ChatTokens.of(context));

  Color _over(Color base, Color tint, double alpha) =>
      Color.alphaBlend(tint.withValues(alpha: alpha), base);

  /// A selected category chip: a lime tint with strong text.
  Color get chipSelectedFill => _over(t.bg, t.lime, t.isDark ? .22 : .6);
  Color get chipSelectedInk => t.isDark ? t.text : VibeColors.ink;
  Color get chipFill => t.surface;
  Color get chipInk => t.textSecondary;

  /// The Say hi control: a clean outlined square, no pill. A very faint tonal
  /// fill, a hairline edge and the primary ink for the wave, so the row's name
  /// and what it says stay the loudest thing in it.
  Color get hiFill => _over(t.bg, t.text, .035);
  Color get hiInk => t.text;
  Color get hiEdge => t.hairline;

  /// A wave that was sent: the same square with the check in the accent colour
  /// (lime on dark, the deep green on light).
  Color get hiDoneFill => hiFill;
  Color get hiDoneInk => t.accent;

  /// A control that cannot be used for now (another wave is on its way, a rest,
  /// or the person does not take messages): a neutral fill and the secondary ink.
  Color get hiOffFill => _over(t.bg, t.text, .07);
  Color get hiOffInk => t.textSecondary;

  /// The note under a row, and the toast at the bottom of the list.
  Color get noteInk => t.textSecondary;
  Color get toastFill => t.elevated;
  Color get toastInk => t.text;

  /// The Surprise card: two close tints on the raised surface, and the CTA.
  Color get cardFrom => _over(t.surface, t.lime, t.isDark ? .13 : .42);
  Color get cardTo => _over(t.surface, t.lavender, t.isDark ? .1 : .16);
  Color get ctaFill => t.lime;
  Color get ctaInk => t.onLime;

  /// What two people have in common.
  Color get sharedInk => t.lavender;

  /// The word "online" beside a name.
  Color get onlineInk =>
      PresenceDot.textColor(t.isDark ? Brightness.dark : Brightness.light);

  /// The active-filter count and the distance.
  Color get badgeFill => t.lime;
  Color get badgeInk => t.onLime;
  Color get distanceInk => t.isDark ? VibeColors.mint : t.accent;

  /// Foreground, background and a name, for the contrast test.
  List<(String, Color, Color)> get pairs => [
    ('selected chip', chipSelectedInk, chipSelectedFill),
    ('chip', chipInk, chipFill),
    ('chip on page', chipInk, t.bg),
    ('say hi', hiInk, hiFill),
    ('say hi on page', hiInk, t.bg),
    ('say hi sent', hiDoneInk, hiDoneFill),
    ('say hi sent on page', hiDoneInk, t.bg),
    ('say hi disabled', hiOffInk, hiOffFill),
    ('say hi note', noteInk, t.bg),
    ('say hi toast', toastInk, toastFill),
    ('online', onlineInk, t.bg),
    ('card title (from)', t.text, cardFrom),
    ('card title (to)', t.text, cardTo),
    ('card line (from)', t.textSecondary, cardFrom),
    ('card line (to)', t.textSecondary, cardTo),
    ('card cta', ctaInk, ctaFill),
    ('in common', sharedInk, t.bg),
    ('name', t.text, t.bg),
    ('bio', t.textSecondary, t.bg),
    ('languages', t.textTertiary, t.bg),
    ('count badge', badgeInk, badgeFill),
    ('distance', distanceInk, t.bg),
    ('skeleton text on page', t.textSecondary, t.bg),
  ];
}
