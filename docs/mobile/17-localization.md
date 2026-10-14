# Localization and right-to-left layout (app)

Status, 14 October 2026: groundwork only. The app ships in English. One screen, Help & Safety, reads its words
from the localization system as a proof; every other string is still written in the code. No second language
exists yet.

## What is set up

| Piece | Where |
| --- | --- |
| Tooling | `flutter_localizations` and `intl` in `apps/mobile/pubspec.yaml`, `generate: true` under `flutter:` |
| Config | `apps/mobile/l10n.yaml` (template `app_en.arb`, class `AppLocalizations`) |
| Strings | `apps/mobile/lib/l10n/app_en.arb` (the English template) |
| Generated code | `apps/mobile/lib/l10n/app_localizations.dart` and `app_localizations_en.dart`, checked in |
| Access | `import '../l10n/l10n.dart';` then `context.l10n.someKey` |
| Wiring | `MaterialApp.router` in `lib/app.dart` takes `AppLocalizations.localizationsDelegates` and `supportedLocales` (English only) |

`context.l10n` falls back to English when no localization scope exists above the widget (a screen pumped under a
bare `MaterialApp` in a test), so such tests keep working without delegates.

## Moving a screen to localized strings

1. Pick one screen. Do not half-migrate a screen: every user-visible string on it moves, including tooltips,
   semantics labels, snackbars and error text produced by the screen.
2. Add each string to `app_en.arb`. Key names are `<screen><Thing>` in camelCase (`helpBlockTitle`). Add an
   `@key` entry with a `description` for anything a translator could misread (what the button does, where the
   text shows, whether it is shown in capitals). Use `{placeholders}` for values and declare each under
   `placeholders` with a `type` and an `example`. Use ICU `plural`/`select` for counts and genders, never
   string concatenation (`"$n unread"` becomes `{count, plural, ...}`).
3. Run `flutter gen-l10n` in `apps/mobile` (`flutter pub get`, `flutter run` and `flutter test` also run it).
   Commit the regenerated `lib/l10n/*.dart`.
4. In the widget, replace the literal with `context.l10n.key` (or `context.l10n.key(value)`). Words that build a
   widget `Key` (`Key('help-contact-Safety concerns')`) stay as fixed identifiers; tests and analytics rely on
   them and they must not change with the language.
5. Strings that are data, not interface copy (names, usernames, addresses, user content, legal documents,
   server text) are not put in the ARB. Server error messages are mapped in `core/user_error.dart`; move that
   mapping as its own step.
6. Add or extend a widget test that pumps the screen and finds the text. `test/l10n_test.dart` shows the pattern.

Order suggested for the rest: Settings, Welcome and onboarding, Discover, Chats (after the chat work settles),
Home, Activity, Profile, Spaces. Do the screens people see first before the long tail.

## Adding a language

1. Copy `app_en.arb` to `app_<code>.arb` (`app_ar.arb`), set `@@locale`, translate the values, keep the keys and
   placeholders. Leave out `@key` metadata; only the template needs it.
2. `flutter gen-l10n`. The generated `supportedLocales` now lists it; nothing else to wire.
3. Anything still in code is still English. Pick the languages for launch by the screens already moved.
4. Dates and relative times (`timeAgo`, `whenLabel`) are English strings today; they must go through `intl`
   (`DateFormat`, plural messages) before a second language ships.
5. Check every moved screen at text scale 2.0 and 320 px in the new language: translations are longer.

## Right-to-left

Layouts use the start/end forms so a right-to-left language mirrors correctly:
`EdgeInsetsDirectional`, `AlignmentDirectional`, `PositionedDirectional`, `BorderRadiusDirectional`,
`BorderDirectional`, `TextAlign.start/end`. They are pixel-identical in left-to-right. Rules for new code:

- Never write `left:`/`right:` for something that belongs at the start or end of a line. Use `start:`/`end:`.
- Leave left and right alone only when they are physical on purpose: story tap zones (left half back, right half
  next), canvases and painters, shadow offsets, scroll and drag maths. Add `// RTL: physical` where it is not
  obvious.
- Directional icons (back arrow, chevron) are mirrored by Flutter for the Material icons that carry
  `matchTextDirection`; check a custom icon.
- Chat code (`core/chat`, `features/chat*.dart`) has not been converted yet.

Tests force a direction with `textDirectionOverrideProvider` (`lib/app.dart`, `@visibleForTesting`), because the
app has no RTL locale to switch to. `test/rtl_test.dart` checks the Home header, a Settings row, Help & Safety and a
Discover row in both directions.
