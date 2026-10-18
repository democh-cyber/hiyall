import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;

import '../core/api.dart';
import '../core/profile_labels.dart';
import '../core/theme.dart';
import '../shared/person_avatar.dart';
import '../shared/presence_dot.dart';
import '../shared/press_scale.dart';
import 'chat_parts.dart' show clampedChrome;
import 'discover_chips.dart';
import 'discover_header.dart';
import 'discover_style.dart';

String countryLabel(String? code) =>
    countryNames[code?.toUpperCase()] ?? 'Other country';

/// Distances are rounded-up buckets from the server, never exact.
String distanceLabel(int km) => km <= 1 ? 'Within 1 km' : 'Within $km km';

/// The one line that says why this person might be worth a hello, in natural
/// words: what the two have in common first ("You both love Travel", "You both
/// like Music and Travel", "3 in common · Music, Travel"), otherwise their own
/// top interests ("Music · Photography"), otherwise nothing. Nothing is made up:
/// it is empty when the server sent neither. Interests keep the casing they came
/// with, and every shared one is "loved" (there is no per-interest verb list).
class ContextLine {
  final String text;

  /// True when the line is about what the two share (shown in the accent).
  final bool shared;
  const ContextLine(this.text, {required this.shared});

  /// The shared-interest phrase on its own ("You both love Travel").
  static String? sharedPhrase(List<String> sharedInterests) {
    final shared = [
      for (final i in sharedInterests)
        if (i.trim().isNotEmpty) i.trim(),
    ];
    return switch (shared.length) {
      0 => null,
      1 => 'You both love ${shared[0]}',
      2 => 'You both like ${shared[0]} and ${shared[1]}',
      _ => '${shared.length} in common · ${shared[0]}, ${shared[1]}',
    };
  }

  static ContextLine? of(Profile person) {
    // Possible matches say why the person was suggested, from what the row carries.
    final reason = possibleReasonLine(person);
    if (reason != null) return ContextLine(reason, shared: true);
    final phrase = sharedPhrase(person.sharedInterests);
    if (phrase != null) return ContextLine(phrase, shared: true);
    final own = [
      for (final i in person.interests)
        if (i.trim().isNotEmpty) i.trim(),
    ].take(3).toList();
    if (own.isEmpty) return null;
    return ContextLine(own.join(' · '), shared: false);
  }
}

/// "Shares your interest in Music and Travel · Similar personality": why a possible match was suggested, in at
/// most two parts, built only from what the row carries (the server's `reasons` and the interests both share).
/// Null when the row has no reasons (every list but Possible matches).
String? possibleReasonLine(Profile person) {
  if (person.reasons.isEmpty) return null;
  final shared = [
    for (final i in person.sharedInterests)
      if (i.trim().isNotEmpty) i.trim(),
  ].take(3).toList();
  String interests() {
    if (shared.isEmpty) return 'Shares your interests';
    final list = shared.length == 1
        ? shared.first
        : '${shared.take(shared.length - 1).join(', ')} and ${shared.last}';
    return 'Shares your interest in $list';
  }

  final parts = <String>[];
  for (final reason in person.reasons) {
    final part = switch (reason) {
      'interests' => interests(),
      'personality' => 'Similar personality',
      'languages' => 'Good language match',
      'country' => 'Same country',
      _ => null,
    };
    if (part != null && !parts.contains(part)) parts.add(part);
  }
  return parts.isEmpty ? null : parts.take(2).join(' · ');
}

/// What a secondary line of a row is, which decides how it is drawn.
enum RowLineKind { shared, interests, blurb, languages }

/// One secondary line under a person's name.
class RowLine {
  final String text;
  final RowLineKind kind;
  const RowLine(this.text, this.kind);

  /// True for the "why hello" line (shared or own interests).
  bool get isContext =>
      kind == RowLineKind.shared || kind == RowLineKind.interests;
}

/// The secondary lines of a row: at most two, always.
///
/// Line 1 is the context (what you share, else their top interests), line 2 the
/// one-line headline, bio or vibe. Languages are not a default line (the full
/// detail is on the profile); they appear only when they add something:
/// [languagesFocus] (the Languages category or a language filter is on, so the
/// row says which languages it matched; they then take the place of the bio), or
/// when the row would otherwise have no context and no bio and be empty.
List<RowLine> discoverRowLines(Profile p, {bool languagesFocus = false}) {
  final context = ContextLine.of(p);
  final blurb = personBlurb(p);
  final languages = languageSummary(p.languages);
  final lines = <RowLine>[
    if (context != null)
      RowLine(
        context.text,
        context.shared ? RowLineKind.shared : RowLineKind.interests,
      ),
    if (languages != null && languagesFocus)
      RowLine(languages, RowLineKind.languages),
    if (blurb.isNotEmpty) RowLine(blurb, RowLineKind.blurb),
    if (languages != null &&
        !languagesFocus &&
        context == null &&
        blurb.isEmpty)
      RowLine(languages, RowLineKind.languages),
  ];
  return lines.take(2).toList();
}

/// A readable line about the languages someone speaks: names rather than codes,
/// no dots. "Speaks English", "Speaks English, Hindi", "Speaks English, Hindi +1"
/// and, for a single language with a stated level, "English · Native". Null when
/// there is nothing to say.
String? languageSummary(List<ProfileLanguage> languages) {
  final names = <String>[];
  String? level;
  for (final l in languages) {
    final name = languageLabel(l.code);
    if (names.contains(name)) continue;
    names.add(name);
    if (names.length == 1 &&
        l.level >= minLanguageLevel &&
        l.level <= maxLanguageLevel) {
      level = languageLevelName(l.level);
    }
  }
  if (names.isEmpty) return null;
  if (names.length == 1) {
    return level == null ? 'Speaks ${names.first}' : '${names.first} · $level';
  }
  final shown = names.take(2).join(', ');
  final more = names.length - 2;
  return more > 0 ? 'Speaks $shown +$more' : 'Speaks $shown';
}

/// What the screen reader says about a row (Say hi is its own control). Unlike
/// the visible row it can always include the languages: it is spoken once, on
/// demand, and the full detail is what a screen reader user would ask for.
String personSemantics(Profile p) {
  final context = ContextLine.of(p);
  final blurb = personBlurb(p);
  final languages = languageSummary(p.languages);
  return [
    p.displayName,
    if (context != null)
      context.shared
          ? context.text
          : 'Into ${p.interests.where((i) => i.trim().isNotEmpty).map((i) => i.trim()).take(3).join(', ')}',
    if (p.online == true) PresenceDot.label,
    if (DiscoverStyle.showCountryBadge && p.country != null)
      countryLabel(p.country),
    if (p.distanceKm != null) distanceLabel(p.distanceKm!),
    if (blurb.isNotEmpty) blurb,
    ?languages,
  ].join(', ');
}

/// The single muted line under the name: headline, else bio, else vibe.
String personBlurb(Profile p) => [
  p.headline,
  p.bio,
  p.currentVibe,
].firstWhere((v) => v.trim().isNotEmpty, orElse: () => '').trim();

/// How the Say hi control looks. The screen decides; the control only shows it.
///
/// - [idle]: the wave, ready to send one;
/// - [pending]: a wave is on its way (a small spinner);
/// - [done]: sent (a check), for 24 hours;
/// - [message]: a conversation with messages exists, so it opens it (a chat bubble);
/// - [notAllowed]: the person does not accept messages from this member;
/// - [retry]: sending failed and can be tried again;
/// - [disabled]: another wave is on its way, or a rate limit asked for a rest.
enum SayHiState { idle, pending, done, message, notAllowed, retry, disabled }

/// One person in the Discover list: a flat row with the avatar (photo or
/// gradient, online dot), the name (with a green "online" beside it when the
/// server said so), at most two lines under it ([discoverRowLines]) and the
/// icon-only Say hi control ([sayHi], see `SayHiSlot`), with a note under the row when the
/// control has something to say ([note]). Tapping the row opens their profile;
/// Say hi is only ever triggered by tapping its control; a long press (or the
/// "More options" action for a screen reader) opens View profile, Report and Block.
class DiscoverPersonTile extends StatelessWidget {
  final Profile person;

  /// The Say hi control and the note beneath the row; they follow their own
  /// state, so the row itself never rebuilds when a wave is sent.
  final Widget sayHi;
  final Widget? note;

  /// The Languages category or a language filter is on: see [discoverRowLines].
  final bool languagesFocus;
  final VoidCallback onOpen, onMore;
  final bool showDivider;
  const DiscoverPersonTile({
    super.key,
    required this.person,
    required this.sayHi,
    required this.onOpen,
    required this.onMore,
    this.note,
    this.languagesFocus = false,
    this.showDivider = true,
  });

  static const _gap = 14.0, _inset = 8.0, _pad = 12.0, _avatar = 26.0;

  Widget _distance(DiscoverStyle s) => Text(
    distanceLabel(person.distanceKm!),
    key: Key('distance-${person.userId}'),
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(
      fontSize: 12.5,
      height: 1.3,
      fontWeight: FontWeight.w800,
      color: s.distanceInk,
    ),
  );

  Widget _line(
    BuildContext context,
    DiscoverStyle s,
    RowLine line, {
    required bool first,
  }) {
    final t = s.t;
    final text = Text(
      line.text,
      key: line.isContext
          ? Key('context-${person.userId}')
          : Key('${line.kind.name}-${person.userId}'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: switch (line.kind) {
        RowLineKind.shared => TextStyle(
          fontSize: 12.5,
          height: 1.3,
          fontWeight: FontWeight.w700,
          color: s.sharedInk,
        ),
        RowLineKind.interests => TextStyle(
          fontSize: 12.5,
          height: 1.3,
          fontWeight: FontWeight.w600,
          color: t.textSecondary,
        ),
        RowLineKind.blurb => TextStyle(
          fontSize: 13.5,
          height: 1.3,
          color: t.textSecondary,
        ),
        RowLineKind.languages => TextStyle(
          fontSize: 12.5,
          height: 1.3,
          color: t.textSecondary,
        ),
      },
    );
    final distance = first ? person.distanceKm : null;
    if (distance == null) return text;
    // Nearby: the distance bucket leads the first line.
    return Row(
      children: [
        Flexible(child: _distance(s)),
        // A small dot, not a text separator, so the bucket can shrink and
        // ellipsize at large text without the separator overflowing.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5),
          child: Container(
            width: 3,
            height: 3,
            decoration: BoxDecoration(
              color: t.textTertiary,
              shape: BoxShape.circle,
            ),
          ),
        ),
        Expanded(child: text),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = DiscoverStyle.of(context);
    final t = s.t;
    final lines = discoverRowLines(person, languagesFocus: languagesFocus);
    final scheme = Theme.of(context).colorScheme;
    final online = person.online == true;

    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                person.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'SpaceGrotesk',
                  fontSize: 16.5,
                  height: 1.25,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -.25,
                  color: t.text,
                ),
              ),
            ),
            // Only when the server said they are online and let this account
            // see it; there is no "offline" word.
            if (online) ...[
              const SizedBox(width: 6),
              // Capped at 1.3x so it never crowds the name at large text.
              clampedChrome(
                context,
                Text(
                  PresenceDot.label,
                  key: Key('online-text-${person.userId}'),
                  maxLines: 1,
                  softWrap: false,
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.25,
                    fontWeight: FontWeight.w700,
                    color: s.onlineInk,
                  ),
                ),
              ),
            ],
          ],
        ),
        for (final (i, line) in lines.indexed) ...[
          const SizedBox(height: 2),
          _line(context, s, line, first: i == 0),
        ],
        // Nearby with nothing else to say: the distance bucket alone.
        if (lines.isEmpty && person.distanceKm != null) ...[
          const SizedBox(height: 2),
          _distance(s),
        ],
      ],
    );

    final avatar = SizedBox(
      width: _avatar * 2,
      height: _avatar * 2,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          PersonAvatar(
            name: person.displayName,
            avatarUrl: person.avatarUrl,
            userId: person.userId,
            radius: _avatar,
            initialStyle: const TextStyle(
              fontFamily: 'SpaceGrotesk',
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (online)
            PositionedDirectional(
              // Bottom right, where presence lives elsewhere in the app; the
              // top left only when a country badge takes that corner.
              end: DiscoverStyle.showCountryBadge ? null : -3,
              bottom: DiscoverStyle.showCountryBadge ? null : -3,
              start: DiscoverStyle.showCountryBadge ? -3 : null,
              top: DiscoverStyle.showCountryBadge ? -3 : null,
              child: PresenceDot(
                key: Key('online-dot-${person.userId}'),
                ringColor: t.bg,
                size: 18,
                ringWidth: 2.5,
              ),
            ),
          if (DiscoverStyle.showCountryBadge && person.country != null)
            PositionedDirectional(
              end: -3,
              bottom: -2,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: t.bg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: t.hairline),
                ),
                child: Text(
                  person.country!.toUpperCase(),
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    letterSpacing: .4,
                    color: scheme.onSurface,
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: _inset),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: PressScale(
                  key: Key('person-${person.userId}'),
                  onTap: onOpen,
                  onLongPress: onMore,
                  semanticActions: {
                    const CustomSemanticsAction(label: 'More options'): onMore,
                  },
                  semanticLabel: personSemantics(person),
                  semanticHint: 'Opens profile',
                  borderRadius: BorderRadius.circular(18),
                  pressedScale: .98,
                  minHeight: 68,
                  child: Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(
                      _pad,
                      8,
                      4,
                      8,
                    ),
                    child: Row(
                      children: [
                        avatar,
                        const SizedBox(width: _gap),
                        Expanded(child: info),
                      ],
                    ),
                  ),
                ),
              ),
              sayHi,
              const SizedBox(width: 2),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsetsDirectional.only(
            start: _inset + _pad + _avatar * 2 + _gap,
          ),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: DiscoverRowExtras(person: person),
          ),
        ),
        if (note != null)
          Padding(
            padding: const EdgeInsetsDirectional.only(
              start: _inset + _pad + _avatar * 2 + _gap,
              end: discoverPad,
            ),
            child: note,
          ),
        if (showDivider)
          Padding(
            padding: const EdgeInsetsDirectional.only(
              start: _inset + _pad + _avatar * 2 + _gap,
              end: discoverPad,
            ),
            child: Divider(
              height: 1,
              thickness: 1,
              color: t.hairline.withValues(alpha: .5),
            ),
          ),
      ],
    );
  }
}

/// The words a screen reader and the tooltip give a Say hi control in each state.
String sayHiLabel(SayHiState state, String name) => switch (state) {
  SayHiState.pending => 'Sending hi to $name',
  SayHiState.done => 'Hi sent to $name',
  SayHiState.message => 'Message $name',
  SayHiState.retry => 'Try again: say hi to $name',
  _ => 'Say hi to $name',
};

/// The "Say hi" control: the wave alone in a clean 40 px rounded square (radius
/// 12) with a faint tonal fill, a 1 px hairline and the primary ink, never a
/// text pill. It is a 48 dp touch target, named "Say hi to" plus the name for
/// screen readers and in its tooltip. Its icon changes with [state]
/// ([SayHiState]): a spinner while a wave is on its way, a check in the accent
/// colour once it was sent (both disabled), a chat bubble when a conversation
/// exists, a refresh arrow after a failure. The change is a short fade and scale
/// (none with reduced motion). Rows and the profile page share it.
class SayHiButton extends StatelessWidget {
  final String name;
  final SayHiState state;
  final VoidCallback onTap;
  const SayHiButton({
    super.key,
    required this.name,
    required this.state,
    required this.onTap,
  });

  /// The visible square and the smallest touch target around it.
  static const visual = 40.0, target = 48.0, radius = 12.0;

  @override
  Widget build(BuildContext context) {
    final s = DiscoverStyle.of(context);
    final enabled =
        state == SayHiState.idle ||
        state == SayHiState.message ||
        state == SayHiState.retry;
    final (fill, ink) = switch (state) {
      SayHiState.done => (s.hiDoneFill, s.hiDoneInk),
      SayHiState.notAllowed || SayHiState.disabled => (s.hiOffFill, s.hiOffInk),
      _ => (s.hiFill, s.hiInk),
    };
    final Widget icon = switch (state) {
      SayHiState.pending => SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2, color: ink),
      ),
      SayHiState.done => Icon(Icons.check_rounded, size: 20, color: ink),
      SayHiState.message => Icon(
        Icons.chat_bubble_outline_rounded,
        size: 18,
        color: ink,
      ),
      SayHiState.retry => Icon(Icons.refresh_rounded, size: 19, color: ink),
      _ => Icon(Icons.waving_hand_rounded, size: 18, color: ink),
    };
    final label = sayHiLabel(state, name);
    final duration = VibeMotion.duration(context);
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: PressScale(
        onTap: enabled ? onTap : null,
        semanticLabel: label,
        borderRadius: BorderRadius.circular(radius),
        pressedScale: .94,
        minHeight: target,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: target),
          child: Center(
            widthFactor: 1,
            heightFactor: 1,
            child: AnimatedContainer(
              key: const Key('say-hi-square'),
              duration: duration,
              width: visual,
              height: visual,
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(radius),
                border: Border.all(color: s.hiEdge),
              ),
              alignment: Alignment.center,
              child: AnimatedSwitcher(
                duration: duration,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: ScaleTransition(
                    scale: Tween(begin: .6, end: 1.0).animate(animation),
                    child: child,
                  ),
                ),
                child: KeyedSubtree(key: ValueKey(state), child: icon),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
