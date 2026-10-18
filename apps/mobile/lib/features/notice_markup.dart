import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../shared/chat_tokens.dart';

/// The notice board's body markup is exactly three things: paragraphs (a blank line between them),
/// `**bold**` and `[label](https://address)`. This file draws that and nothing else. It never builds
/// HTML or a web view: anything else (angle brackets, images, a stray `*`) stays plain text, and a
/// link opens only when it is https with a host and no credentials.
sealed class NoticeSpan {
  const NoticeSpan();
}

class NoticeText extends NoticeSpan {
  final String text;
  final bool bold;
  const NoticeText(this.text, {this.bold = false});
  @override
  bool operator ==(Object other) =>
      other is NoticeText && other.text == text && other.bold == bold;
  @override
  int get hashCode => Object.hash(text, bold);
  @override
  String toString() => 'NoticeText($text${bold ? ', bold' : ''})';
}

/// A tappable link: [uri] has already passed [safeNoticeLink].
class NoticeLink extends NoticeSpan {
  final String label;
  final Uri uri;
  final bool bold;
  const NoticeLink(this.label, this.uri, {this.bold = false});
  @override
  bool operator ==(Object other) =>
      other is NoticeLink &&
      other.label == label &&
      other.uri == uri &&
      other.bold == bold;
  @override
  int get hashCode => Object.hash(label, uri, bold);
  @override
  String toString() => 'NoticeLink($label -> $uri)';
}

/// The address behind a link if the app may open it: `https`, a host, no user or password, no
/// spaces or control characters. Null for everything else (`http:`, `javascript:`, `mailto:`, a
/// relative path).
Uri? safeNoticeLink(String raw) {
  final text = raw.trim();
  if (text.isEmpty || text.length > 2000) return null;
  if (RegExp(r'[\s\u0000-\u001f\u007f]').hasMatch(text)) return null;
  final uri = Uri.tryParse(text);
  if (uri == null ||
      uri.scheme.toLowerCase() != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty) {
    return null;
  }
  return uri;
}

final _inline = RegExp(r'\*\*(.+?)\*\*|\[([^\]\n]+)\]\(([^)\n]*)\)');

List<NoticeSpan> _spans(String text, {bool bold = false}) {
  final out = <NoticeSpan>[];
  void plain(String s) {
    if (s.isEmpty) return;
    final last = out.isEmpty ? null : out.last;
    if (last is NoticeText && last.bold == bold) {
      out[out.length - 1] = NoticeText(last.text + s, bold: bold);
    } else {
      out.add(NoticeText(s, bold: bold));
    }
  }

  var at = 0;
  for (final m in _inline.allMatches(text)) {
    plain(text.substring(at, m.start));
    at = m.end;
    final boldBody = m.group(1);
    if (boldBody != null) {
      // Bold may hold a link; bold inside bold is just text.
      for (final s in _spans(boldBody, bold: true)) {
        if (s is NoticeText) {
          final last = out.isEmpty ? null : out.last;
          if (last is NoticeText && last.bold == s.bold) {
            out[out.length - 1] = NoticeText(last.text + s.text, bold: s.bold);
            continue;
          }
        }
        out.add(s);
      }
    } else {
      final label = m.group(2)!;
      final uri = safeNoticeLink(m.group(3)!);
      // A link that may not be opened shows its words and nothing to tap.
      if (uri == null) {
        plain(label);
      } else {
        out.add(NoticeLink(label, uri, bold: bold));
      }
    }
  }
  plain(text.substring(at));
  return out;
}

/// Splits [body] into paragraphs of spans. Unbalanced `**` stays as typed.
List<List<NoticeSpan>> parseNoticeMarkup(String body) => [
  for (final paragraph in body.trim().split(RegExp(r'\n[ \t]*\n+')))
    if (paragraph.trim().isNotEmpty) _spans(paragraph.trim()),
];

/// Opens a link outside the app. Replaced in tests, which have no browser.
@visibleForTesting
Future<bool> Function(Uri uri) noticeLinkLauncher = (uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

/// Opens [uri] if (and only if) it is a safe link. True when something was opened.
Future<bool> openNoticeLink(Uri uri) async {
  if (safeNoticeLink(uri.toString()) == null) return false;
  try {
    return await noticeLinkLauncher(uri);
  } catch (_) {
    return false;
  }
}

/// A notice body, drawn from the markup above.
class NoticeBody extends StatefulWidget {
  final String body;
  final TextStyle? style;
  const NoticeBody(this.body, {super.key, this.style});
  @override
  State<NoticeBody> createState() => _NoticeBodyState();
}

class _NoticeBodyState extends State<NoticeBody> {
  final _recognizers = <TapGestureRecognizer>[];

  @override
  void dispose() {
    _free();
    super.dispose();
  }

  void _free() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  Widget build(BuildContext context) {
    _free();
    final tokens = ChatTokens.of(context);
    final base = (widget.style ?? Theme.of(context).textTheme.bodyMedium)!
        .copyWith(height: 1.55, color: widget.style?.color ?? tokens.text);
    final paragraphs = parseNoticeMarkup(widget.body);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < paragraphs.length; i++)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : 12),
            child: Text.rich(
              key: Key('notice-paragraph-$i'),
              TextSpan(
                style: base,
                children: [
                  for (final span in paragraphs[i])
                    switch (span) {
                      NoticeText() => TextSpan(
                        text: span.text,
                        style: span.bold
                            ? const TextStyle(fontWeight: FontWeight.w800)
                            : null,
                      ),
                      NoticeLink() => TextSpan(
                        text: span.label,
                        style: TextStyle(
                          color: tokens.accent,
                          decoration: TextDecoration.underline,
                          decorationColor: tokens.accent,
                          fontWeight: span.bold
                              ? FontWeight.w800
                              : FontWeight.w600,
                        ),
                        recognizer: _recognize(span.uri),
                        semanticsLabel: '${span.label}, opens a web page',
                      ),
                    },
                ],
              ),
            ),
          ),
      ],
    );
  }

  TapGestureRecognizer _recognize(Uri uri) {
    final recognizer = TapGestureRecognizer()
      ..onTap = () => openNoticeLink(uri);
    _recognizers.add(recognizer);
    return recognizer;
  }
}
