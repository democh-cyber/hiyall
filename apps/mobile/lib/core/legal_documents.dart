/// The terms revision this build presents. It must equal the server's
/// `domain.TermsVersion` (services/api/internal/domain/onboarding.go), and the
/// `Version:` line at the top of every bundled legal document. `test/legal_test.dart`
/// fails when any of them diverge; bump all of them together.
const kTermsVersion = '2026-10-01';

/// The documents bundled in `assets/legal/`. Their source of truth for review is
/// `docs/legal/`; the two folders hold identical files.
enum LegalDoc {
  terms('/legal/terms', 'assets/legal/terms-of-service.md', 'Terms of Service'),
  privacy('/legal/privacy', 'assets/legal/privacy-policy.md', 'Privacy Policy'),
  guidelines(
    '/legal/guidelines',
    'assets/legal/community-guidelines.md',
    'Community Guidelines',
  ),
  teens(
    '/legal/teens',
    'assets/legal/children-and-teens.md',
    'Children and Teens',
  ),
  retention(
    '/legal/retention',
    'assets/legal/data-retention.md',
    'Data Retention',
  );

  final String path, asset, title;
  const LegalDoc(this.path, this.asset, this.title);

  static LegalDoc? forPath(String path) {
    for (final doc in values) {
      if (doc.path == path) return doc;
    }
    return null;
  }
}

/// The value of the `Version:` line of a legal document, or null when it has none.
String? legalVersionOf(String markdown) => RegExp(
  r'^Version:[ \t]*(\S+)[ \t]*$',
  multiLine: true,
).firstMatch(markdown)?.group(1);

/// One block of a legal document, after [parseLegal].
sealed class LegalBlock {
  const LegalBlock();
}

class LegalHeading extends LegalBlock {
  /// 1 for the document title, 2 and 3 for sections.
  final int level;
  final String text;
  const LegalHeading(this.level, this.text);
}

class LegalParagraph extends LegalBlock {
  /// May contain `**bold**` and line breaks.
  final String text;
  const LegalParagraph(this.text);
}

class LegalBullets extends LegalBlock {
  final List<String> items;
  const LegalBullets(this.items);
}

/// A `>` quote, used for the draft banner.
class LegalCallout extends LegalBlock {
  final String text;
  const LegalCallout(this.text);
}

class LegalTable extends LegalBlock {
  final List<String> headers;
  final List<List<String>> rows;
  const LegalTable(this.headers, this.rows);
}

/// A markdown subset: `#`, `##` and `###` headings, paragraphs (line breaks are
/// kept), `-` bullets, `>` quotes and pipe tables. Inline, only `**bold**`
/// is understood; see [legalSpans].
List<LegalBlock> parseLegal(String markdown) {
  final blocks = <LegalBlock>[];
  final lines = markdown.replaceAll('\r\n', '\n').split('\n');
  var i = 0;
  List<String> cells(String line) {
    var text = line.trim();
    if (text.startsWith('|')) text = text.substring(1);
    if (text.endsWith('|')) text = text.substring(0, text.length - 1);
    return [for (final cell in text.split('|')) cell.trim()];
  }

  bool isSeparator(String line) =>
      RegExp(r'^\|?[\s:|-]+\|?$').hasMatch(line.trim()) && line.contains('-');
  bool special(String line) {
    final t = line.trimLeft();
    return t.startsWith('#') ||
        t.startsWith('- ') ||
        t.startsWith('> ') ||
        t.startsWith('|');
  }

  while (i < lines.length) {
    final line = lines[i];
    final trimmed = line.trim();
    if (trimmed.isEmpty) {
      i++;
    } else if (trimmed.startsWith('#')) {
      final level =
          trimmed.length - trimmed.replaceFirst(RegExp(r'^#+'), '').length;
      blocks.add(
        LegalHeading(level.clamp(1, 3), trimmed.substring(level).trim()),
      );
      i++;
    } else if (trimmed.startsWith('> ')) {
      final quote = <String>[];
      while (i < lines.length && lines[i].trim().startsWith('> ')) {
        quote.add(lines[i].trim().substring(2).trim());
        i++;
      }
      blocks.add(LegalCallout(quote.join('\n')));
    } else if (trimmed.startsWith('- ')) {
      final items = <String>[];
      while (i < lines.length && lines[i].trim().isNotEmpty) {
        final t = lines[i].trim();
        if (t.startsWith('- ')) {
          items.add(t.substring(2).trim());
        } else if (items.isNotEmpty && !special(t)) {
          items[items.length - 1] = '${items.last} $t';
        } else {
          break;
        }
        i++;
      }
      blocks.add(LegalBullets(items));
    } else if (trimmed.startsWith('|')) {
      final rows = <List<String>>[];
      while (i < lines.length && lines[i].trim().startsWith('|')) {
        if (!isSeparator(lines[i])) rows.add(cells(lines[i]));
        i++;
      }
      if (rows.isNotEmpty) blocks.add(LegalTable(rows.first, rows.sublist(1)));
    } else {
      final text = <String>[];
      while (i < lines.length &&
          lines[i].trim().isNotEmpty &&
          !special(lines[i])) {
        text.add(lines[i].trim());
        i++;
      }
      blocks.add(LegalParagraph(text.join('\n')));
    }
  }
  return blocks;
}

/// Splits [text] at `**` into runs, each flagged bold or not. An unclosed `**`
/// is kept as literal text.
List<({String text, bool bold})> legalSpans(String text) {
  final parts = text.split('**');
  // An odd number of markers leaves the last run unclosed: put the marker back.
  if (parts.length.isEven) {
    final tail = '**${parts.removeLast()}';
    parts[parts.length - 1] = '${parts.last}$tail';
  }
  return [
    for (var n = 0; n < parts.length; n++)
      if (parts[n].isNotEmpty) (text: parts[n], bold: n.isOdd),
  ];
}
