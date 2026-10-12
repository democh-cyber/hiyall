import 'package:flutter/material.dart';

import '../core/theme.dart';

/// Design tokens of the chat surfaces ("Midnight Social Club") and the floating
/// dock: olive-tinted charcoal layers in the dark theme, warm paper in the
/// light one, lime kept for the few things that should call for attention.
///
/// Registered on both themes in [hiyallTheme]. [ChatTokens.of] also works under
/// a plain [ThemeData] (previews, tests), where it picks by brightness.
@immutable
class ChatTokens extends ThemeExtension<ChatTokens> {
  final Brightness brightness;

  /// The page, a slightly raised page, a card-like surface and the most
  /// raised surface (composer, incoming bubbles, search), lowest to highest.
  final Color bg, bg2, surface, elevated;

  /// A one pixel divider or an edge that should barely be there.
  final Color hairline;

  /// Primary, secondary and tertiary text. Every one passes WCAG AA (4.5:1)
  /// on [bg], [surface] and [elevated] (see `chat_tokens_test.dart`).
  final Color text, textSecondary, textTertiary;

  /// Lime where it is a fill; [accent] where lime would be text (it is a deep
  /// green in the light theme, where lime text is unreadable).
  final Color lime, accent, onLime;
  final Color lavender;

  /// Incoming bubble fill, its text, its meta line and its (optional) edge.
  final Color incoming, incomingInk, incomingMeta, incomingBorder;

  /// Outgoing bubbles: a very close pair of softened limes (tonal variation,
  /// not a gradient to another hue) with dark ink on top.
  final Color outgoingTop, outgoingBottom, outgoingInk, outgoingMeta;
  final Color outgoingSeen;

  /// The brighter fill of a row with unread messages.
  final Color unreadRow;

  /// Unread counter and the quieter one for a muted chat.
  final Color badgeFill, badgeInk, mutedBadgeFill, mutedBadgeInk;

  /// A soft ring around a focused field.
  final Color focusRing;
  final Color error;

  /// The floating navigation dock.
  final Color dockSurface;
  final Color shadow;

  const ChatTokens({
    required this.brightness,
    required this.bg,
    required this.bg2,
    required this.surface,
    required this.elevated,
    required this.hairline,
    required this.text,
    required this.textSecondary,
    required this.textTertiary,
    required this.lime,
    required this.accent,
    required this.onLime,
    required this.lavender,
    required this.incoming,
    required this.incomingInk,
    required this.incomingMeta,
    required this.incomingBorder,
    required this.outgoingTop,
    required this.outgoingBottom,
    required this.outgoingInk,
    required this.outgoingMeta,
    required this.outgoingSeen,
    required this.unreadRow,
    required this.badgeFill,
    required this.badgeInk,
    required this.mutedBadgeFill,
    required this.mutedBadgeInk,
    required this.focusRing,
    required this.error,
    required this.dockSurface,
    required this.shadow,
  });

  static const dark = ChatTokens(
    brightness: Brightness.dark,
    bg: Color(0xff171b17),
    bg2: Color(0xff1d221d),
    surface: Color(0xff242a24),
    elevated: Color(0xff2d342d),
    hairline: Color(0xff394238),
    text: Color(0xfff5f6ef),
    textSecondary: Color(0xffadb5a8),
    textTertiary: Color(0xff949f91),
    lime: VibeColors.lime,
    accent: VibeColors.lime,
    onLime: VibeColors.ink,
    lavender: Color(0xffdccbff),
    incoming: Color(0xff2d342d),
    incomingInk: Color(0xfff5f6ef),
    incomingMeta: Color(0xffadb5a8),
    incomingBorder: Color(0x0fffffff),
    outgoingTop: Color(0xffc1ee8d),
    outgoingBottom: Color(0xffb7e67c),
    outgoingInk: VibeColors.ink,
    outgoingMeta: Color(0xff3f4739),
    outgoingSeen: VibeColors.success,
    unreadRow: Color(0xff1f251f),
    badgeFill: VibeColors.lime,
    badgeInk: VibeColors.ink,
    mutedBadgeFill: Color(0xff3a423a),
    mutedBadgeInk: Color(0xfff5f6ef),
    focusRing: Color(0x8cd2f65a),
    error: Color(0xffffb4bf),
    dockSurface: Color(0xff20251f),
    shadow: Color(0x66000000),
  );

  static const light = ChatTokens(
    brightness: Brightness.light,
    bg: Color(0xfff7f8f2),
    bg2: Color(0xfff0f2e8),
    surface: Color(0xffffffff),
    elevated: Color(0xffffffff),
    hairline: Color(0xffe1e5d6),
    text: VibeColors.ink,
    textSecondary: Color(0xff555c50),
    textTertiary: Color(0xff66705f),
    lime: VibeColors.lime,
    accent: VibeColors.success,
    onLime: VibeColors.ink,
    lavender: Color(0xff675391),
    // A touch cooler and greyer than the warm paper, so a bubble reads as a
    // shape on the page (the old white was a 1.07:1 step from it); the edge
    // is a hairline, not a frame.
    incoming: Color(0xffe4e9e8),
    incomingInk: VibeColors.ink,
    incomingMeta: Color(0xff555c50),
    incomingBorder: Color(0xffd3d9d6),
    outgoingTop: Color(0xffc1ee8d),
    outgoingBottom: Color(0xffb7e67c),
    outgoingInk: VibeColors.ink,
    outgoingMeta: Color(0xff3f4739),
    outgoingSeen: VibeColors.success,
    unreadRow: Color(0xffffffff),
    badgeFill: VibeColors.ink,
    badgeInk: VibeColors.lime,
    mutedBadgeFill: Color(0xffdde1d2),
    mutedBadgeInk: VibeColors.ink,
    focusRing: Color(0x99246846),
    error: VibeColors.error,
    dockSurface: Color(0xfffcfdf8),
    shadow: Color(0x1a20231f),
  );

  bool get isDark => brightness == Brightness.dark;

  /// The outgoing bubble's two tones, top to bottom.
  List<Color> get outgoing => [outgoingTop, outgoingBottom];

  static ChatTokens of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<ChatTokens>() ??
        (theme.brightness == Brightness.dark ? dark : light);
  }

  @override
  ChatTokens copyWith({Color? bg}) => ChatTokens(
    brightness: brightness,
    bg: bg ?? this.bg,
    bg2: bg2,
    surface: surface,
    elevated: elevated,
    hairline: hairline,
    text: text,
    textSecondary: textSecondary,
    textTertiary: textTertiary,
    lime: lime,
    accent: accent,
    onLime: onLime,
    lavender: lavender,
    incoming: incoming,
    incomingInk: incomingInk,
    incomingMeta: incomingMeta,
    incomingBorder: incomingBorder,
    outgoingTop: outgoingTop,
    outgoingBottom: outgoingBottom,
    outgoingInk: outgoingInk,
    outgoingMeta: outgoingMeta,
    outgoingSeen: outgoingSeen,
    unreadRow: unreadRow,
    badgeFill: badgeFill,
    badgeInk: badgeInk,
    mutedBadgeFill: mutedBadgeFill,
    mutedBadgeInk: mutedBadgeInk,
    focusRing: focusRing,
    error: error,
    dockSurface: dockSurface,
    shadow: shadow,
  );

  /// Themes switch instantly between the two fixed sets; blending them would
  /// only produce colours nobody designed.
  @override
  ChatTokens lerp(ThemeExtension<ChatTokens>? other, double t) =>
      other is ChatTokens && t >= .5 ? other : this;
}

/// Sizes and rhythm shared by the chat list, the conversation and the dock
/// (a 4/8 px system).
abstract final class ChatMetrics {
  static const pagePadding = 20.0;
  static const rowMinHeight = 80.0;
  static const avatarRadius = 26.0;
  static const searchHeight = 52.0;
  static const headerHeight = 56.0;
  static const bubbleRadius = 22.0;
  static const bubbleJoin = 6.0;
  static const bubbleTail = 4.0;

  /// Space above the first bubble of a run, and between bubbles inside one.
  static const runGap = 11.0;
  static const bubbleGap = 2.0;
  static const composerMinHeight = 56.0;
  static const hit = 48.0;
}
