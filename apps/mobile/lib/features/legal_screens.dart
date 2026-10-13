import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/legal_documents.dart';
import '../shared/chat_tokens.dart';
import '../shared/press_scale.dart';
import '../shared/widgets.dart';

/// The bundled text of one legal document.
final legalTextProvider = FutureProvider.family<String, LegalDoc>(
  (ref, doc) => rootBundle.loadString(doc.asset, cache: false),
);

/// Opens a legal document above whatever is showing, so Back returns to it.
/// The routes sit outside the sign-in redirect, so they work signed out too.
void openLegal(BuildContext context, LegalDoc doc) => context.push(doc.path);

/// A tappable document name for use inside a sentence: bold and underlined,
/// with a hit area at least 48 dp tall.
class LegalLink extends StatelessWidget {
  final LegalDoc doc;

  /// Shown instead of the document's title (for example "Terms").
  final String? label;
  final TextStyle? style;
  const LegalLink(this.doc, {super.key, this.label, this.style});
  @override
  Widget build(BuildContext context) => PressScale(
    key: Key('legal-link-${doc.name}'),
    minHeight: 48,
    borderRadius: BorderRadius.circular(8),
    semanticLabel: 'Read the ${doc.title}',
    onTap: () => openLegal(context, doc),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Center(
        widthFactor: 1,
        child: Text(
          label ?? doc.title,
          style: (style ?? const TextStyle()).copyWith(
            fontWeight: FontWeight.w700,
            decoration: TextDecoration.underline,
          ),
        ),
      ),
    ),
  );
}

/// Footer for the welcome, login and sign-up pages: who the app is for, and the
/// four documents a new member should read.
class LegalFooter extends StatelessWidget {
  const LegalFooter({super.key});
  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: 12.5,
      height: 1.6,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return Column(
      key: const Key('legal-footer'),
      children: [
        Text(
          'Hiyall is for people 13 and over.',
          textAlign: TextAlign.center,
          style: style,
        ),
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 10,
          children: [
            LegalLink(LegalDoc.terms, label: 'Terms', style: style),
            LegalLink(LegalDoc.privacy, label: 'Privacy Policy', style: style),
            LegalLink(
              LegalDoc.guidelines,
              label: 'Community Guidelines',
              style: style,
            ),
            LegalLink(LegalDoc.teens, label: 'Teens and safety', style: style),
          ],
        ),
      ],
    );
  }
}

/// The legal group of Settings: one row per document.
class LegalSettingsGroup extends StatelessWidget {
  const LegalSettingsGroup({super.key});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 22),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Semantics(
            header: true,
            child: Text(
              'LEGAL',
              style: TextStyle(
                fontSize: 12,
                letterSpacing: 1.2,
                fontWeight: FontWeight.w800,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        VibePanel(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            children: [
              for (final (doc, icon, hint) in const [
                (
                  LegalDoc.terms,
                  Icons.description_outlined,
                  'The rules for using Hiyall',
                ),
                (
                  LegalDoc.privacy,
                  Icons.privacy_tip_outlined,
                  'What we collect and who sees it',
                ),
                (
                  LegalDoc.guidelines,
                  Icons.favorite_border_rounded,
                  'How we treat each other',
                ),
                (
                  LegalDoc.teens,
                  Icons.shield_outlined,
                  'How members 13 to 17 are protected',
                ),
                (
                  LegalDoc.retention,
                  Icons.history_toggle_off_rounded,
                  'How long we keep things',
                ),
              ])
                ListTile(
                  key: Key('settings-legal-${doc.name}'),
                  minTileHeight: 56,
                  leading: Icon(icon),
                  title: Text(
                    doc.title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: Text(hint),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => openLegal(context, doc),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// One legal document, rendered from the bundled markdown.
class LegalScreen extends ConsumerWidget {
  final LegalDoc doc;
  const LegalScreen({super.key, required this.doc});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = ChatTokens.of(context);
    final text = ref.watch(legalTextProvider(doc));
    return Scaffold(
      key: Key('legal-${doc.name}'),
      backgroundColor: tokens.bg,
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
                child: IconButton(
                  key: const Key('legal-back'),
                  tooltip: 'Back',
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  color: tokens.text,
                  onPressed: () =>
                      context.canPop() ? context.pop() : context.go('/home'),
                  icon: const Icon(Icons.arrow_back_rounded),
                ),
              ),
            ),
            Expanded(
              child: text.when(
                data: (markdown) => _Body(doc: doc, markdown: markdown),
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (_, _) => Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'This page couldn’t be opened.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: tokens.text),
                        ),
                        const SizedBox(height: 12),
                        FilledButton(
                          key: const Key('legal-retry'),
                          onPressed: () =>
                              ref.invalidate(legalTextProvider(doc)),
                          child: const Text('Try again'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  final LegalDoc doc;
  final String markdown;
  const _Body({required this.doc, required this.markdown});

  @override
  Widget build(BuildContext context) {
    final tokens = ChatTokens.of(context);
    final blocks = parseLegal(markdown);
    final others = [
      for (final other in LegalDoc.values)
        if (other != doc) other,
    ];
    return ReadingWidth(
      child: SingleChildScrollView(
        key: const Key('legal-scroll'),
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 40),
        child: SelectionArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final block in blocks) _block(context, tokens, block),
              const SizedBox(height: 28),
              Semantics(
                header: true,
                child: Text(
                  'More from Hiyall',
                  style: TextStyle(
                    fontSize: 13,
                    letterSpacing: 1,
                    fontWeight: FontWeight.w800,
                    color: tokens.textSecondary,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              for (final other in others)
                PressScale(
                  key: Key('legal-more-${other.name}'),
                  minHeight: 56,
                  borderRadius: BorderRadius.circular(14),
                  semanticLabel: other.title,
                  highlight: tokens.hairline,
                  onTap: () => context.pushReplacement(other.path),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            other.title,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: tokens.text,
                            ),
                          ),
                        ),
                        Icon(
                          Icons.chevron_right_rounded,
                          color: tokens.textSecondary,
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _rich(
    String text,
    TextStyle style, {
    TextAlign align = TextAlign.start,
  }) => Text.rich(
    TextSpan(
      children: [
        for (final span in legalSpans(text))
          TextSpan(
            text: span.text,
            style: span.bold
                ? const TextStyle(fontWeight: FontWeight.w800)
                : null,
          ),
      ],
    ),
    style: style,
    textAlign: align,
  );

  Widget _block(BuildContext context, ChatTokens tokens, LegalBlock block) {
    final body = TextStyle(fontSize: 15, height: 1.65, color: tokens.text);
    final theme = Theme.of(context).textTheme;
    switch (block) {
      case LegalHeading(:final level, :final text):
        final style = switch (level) {
          1 => (theme.headlineMedium ?? const TextStyle()).copyWith(
            color: tokens.text,
            height: 1.15,
          ),
          2 => (theme.titleLarge ?? const TextStyle()).copyWith(
            color: tokens.text,
            fontWeight: FontWeight.w800,
            height: 1.25,
          ),
          _ => (theme.titleMedium ?? const TextStyle()).copyWith(
            color: tokens.text,
            fontWeight: FontWeight.w800,
          ),
        };
        return Padding(
          padding: EdgeInsets.only(top: level == 1 ? 8 : 26, bottom: 10),
          child: Semantics(header: true, child: Text(text, style: style)),
        );
      case LegalParagraph(:final text):
        final meta =
            text.startsWith('Version:') || text.startsWith('Effective date:');
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _rich(
            text,
            meta
                ? body.copyWith(fontSize: 13, color: tokens.textSecondary)
                : body,
          ),
        );
      case LegalBullets(:final items):
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final item in items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 22,
                        child: Text(
                          '•',
                          style: body.copyWith(color: tokens.textSecondary),
                        ),
                      ),
                      Expanded(child: _rich(item, body)),
                    ],
                  ),
                ),
            ],
          ),
        );
      case LegalCallout(:final text):
        return Container(
          key: const Key('legal-callout'),
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: tokens.elevated,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: tokens.hairline),
          ),
          child: _rich(text, body.copyWith(fontSize: 14)),
        );
      case LegalTable(:final headers, :final rows):
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final row in rows)
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: tokens.surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: tokens.hairline),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _rich(
                        row.first,
                        body.copyWith(fontWeight: FontWeight.w800),
                      ),
                      for (var c = 1; c < row.length; c++)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: headers.length == 2
                              ? _rich(row[c], body)
                              : _rich(
                                  '**${c < headers.length ? headers[c] : ''}:** ${row[c]}',
                                  body,
                                ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        );
    }
  }
}
