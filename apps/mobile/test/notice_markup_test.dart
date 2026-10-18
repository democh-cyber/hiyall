import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiyall/features/notice_markup.dart';

List<TextSpan> leaves(WidgetTester tester, Finder paragraph) {
  final rich = tester.widget<Text>(paragraph);
  final out = <TextSpan>[];
  rich.textSpan!.visitChildren((s) {
    if (s is TextSpan && s.text != null) out.add(s);
    return true;
  });
  return out;
}

void main() {
  group('parseNoticeMarkup', () {
    test('paragraphs split on a blank line', () {
      final p = parseNoticeMarkup('One\nstill one\n\nTwo\n\n\nThree');
      expect(p, hasLength(3));
      expect(p[0], [const NoticeText('One\nstill one')]);
    });

    test('bold and links', () {
      final p = parseNoticeMarkup(
        'Read **this** now: [our rules](https://hiyall.example/rules).',
      );
      expect(p.single, [
        const NoticeText('Read '),
        const NoticeText('this', bold: true),
        const NoticeText(' now: '),
        NoticeLink('our rules', Uri.parse('https://hiyall.example/rules')),
        const NoticeText('.'),
      ]);
    });

    test('unbalanced bold stays as typed', () {
      expect(parseNoticeMarkup('a **b c').single, [
        const NoticeText('a **b c'),
      ]);
    });

    test('HTML is plain text, never markup', () {
      expect(
        parseNoticeMarkup('<b>hi</b> <img src=x onerror=alert(1)>').single,
        [const NoticeText('<b>hi</b> <img src=x onerror=alert(1)>')],
      );
    });

    test('only https links are links', () {
      for (final bad in [
        'http://example.com',
        'javascript:alert(1)',
        'JAVASCRIPT:alert(1)',
        'mailto:a@b.c',
        'data:text/html,hi',
        '/relative',
        'https://user:pw@example.com',
        'https:///nohost',
        'https://exa mple.com',
        '',
      ]) {
        expect(safeNoticeLink(bad), isNull, reason: bad);
        final spans = parseNoticeMarkup('[tap]($bad)').single;
        expect(spans.whereType<NoticeLink>(), isEmpty, reason: bad);
        expect((spans.first as NoticeText).text, startsWith('tap'));
      }
      expect(safeNoticeLink('https://example.com/a?b=1'), isNotNull);
      expect(safeNoticeLink('HTTPS://example.com'), isNotNull);
    });

    test('a link inside bold keeps both', () {
      final p = parseNoticeMarkup('**see [this](https://example.com)**');
      expect(p.single, [
        const NoticeText('see ', bold: true),
        NoticeLink('this', Uri.parse('https://example.com'), bold: true),
      ]);
    });
  });

  group('NoticeBody', () {
    final opened = <Uri>[];
    setUp(() {
      opened.clear();
      noticeLinkLauncher = (uri) async {
        opened.add(uri);
        return true;
      };
    });

    testWidgets('an https link opens, an http one is not tappable', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: NoticeBody(
              '[good](https://example.com/x) and [bad](http://example.com) '
              'and [evil](javascript:alert(1))',
            ),
          ),
        ),
      );
      final spans = leaves(tester, find.byKey(const Key('notice-paragraph-0')));
      final tappable = spans.where((s) => s.recognizer != null).toList();
      expect(tappable.map((s) => s.text), ['good']);
      (tappable.single.recognizer! as TapGestureRecognizer).onTap!();
      await tester.pump();
      expect(opened, [Uri.parse('https://example.com/x')]);
      // The words of the refused links are still readable.
      expect(find.textContaining('bad', findRichText: true), findsOneWidget);
    });

    testWidgets('openNoticeLink refuses a non-https address', (tester) async {
      expect(await openNoticeLink(Uri.parse('http://example.com')), isFalse);
      expect(await openNoticeLink(Uri.parse('javascript:alert(1)')), isFalse);
      expect(opened, isEmpty);
    });
  });
}
