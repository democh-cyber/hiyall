import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/profile_labels.dart';
import 'chat_tokens.dart';
import 'press_scale.dart';

/// The semantic label of a language with its level: "English, fluent". Level names are lower-cased inside a
/// sentence; a language with no readable level is just its name.
String languageSemantics(ProfileLanguage language) {
  final name = languageLabel(language.code);
  if (language.level < minLanguageLevel || language.level > maxLanguageLevel) {
    return name;
  }
  return '$name, ${languageLevelName(language.level).toLowerCase()}';
}

/// A small meter of a language level: six bars that rise from left to right, filled up to [level]. Filled bars
/// are solid, the rest are outlined, so the level reads without colour. It is decoration: whoever uses it
/// describes the level in text (see [languageSemantics]).
class LevelMeter extends StatelessWidget {
  final int level;
  final double height;
  const LevelMeter({super.key, required this.level, this.height = 12});

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    return ExcludeSemantics(
      child: CustomPaint(
        size: Size(maxLanguageLevel * 4.0 - 1, height),
        painter: _MeterPainter(
          level: level,
          filled: t.accent,
          outline: t.textTertiary,
        ),
      ),
    );
  }
}

class _MeterPainter extends CustomPainter {
  final int level;
  final Color filled, outline;
  _MeterPainter({
    required this.level,
    required this.filled,
    required this.outline,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const width = 3.0, gap = 1.0;
    for (var i = 0; i < maxLanguageLevel; i++) {
      final barHeight = size.height * (.38 + .62 * i / (maxLanguageLevel - 1));
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(
          i * (width + gap),
          size.height - barHeight,
          width,
          barHeight,
        ),
        const Radius.circular(1),
      );
      if (i < level) {
        canvas.drawRRect(rect, Paint()..color = filled);
      } else {
        canvas.drawRRect(
          rect.deflate(.5),
          Paint()
            ..color = outline
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_MeterPainter old) =>
      old.level != level || old.filled != filled || old.outline != outline;
}

/// A language as a chip: its name and the level meter. Tapping it (when [onTap] is set) is the tag drill-down:
/// the caller opens Discover filtered by the language. The whole chip is one semantic node, "English, fluent".
/// At least 48 dp tall to hit; [dense] (a Discover row) drops the padding around it but keeps the hit area.
class LanguageChip extends StatelessWidget {
  final ProfileLanguage language;
  final VoidCallback? onTap;
  final bool dense;
  const LanguageChip({
    super.key,
    required this.language,
    this.onTap,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = ChatTokens.of(context);
    final chip = Container(
      constraints: BoxConstraints(minHeight: dense ? 28 : 34),
      padding: EdgeInsetsDirectional.symmetric(
        horizontal: dense ? 9 : 12,
        vertical: dense ? 4 : 6,
      ),
      decoration: BoxDecoration(
        color: t.elevated,
        borderRadius: BorderRadius.circular(100),
        border: Border.all(color: t.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              languageLabel(language.code),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: dense ? 12.5 : 13.5,
                fontWeight: FontWeight.w600,
                color: t.text,
              ),
            ),
          ),
          const SizedBox(width: 7),
          LevelMeter(level: language.level, height: dense ? 10 : 12),
        ],
      ),
    );
    if (onTap == null) {
      return Semantics(
        label: languageSemantics(language),
        container: true,
        child: ExcludeSemantics(child: chip),
      );
    }
    return PressScale(
      onTap: onTap,
      minHeight: 48,
      semanticLabel: languageSemantics(language),
      semanticHint: 'Find people who speak it',
      child: ExcludeSemantics(child: chip),
    );
  }
}
