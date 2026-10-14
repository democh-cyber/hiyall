import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../shared/story_canvas.dart';

/// The server's limit on a story's words, counted in characters (code points), not UTF-16 units.
const storyMaxChars = 280;

/// Keeps at most [max] characters (code points), the way the server counts them.
class StoryRuneLimit extends TextInputFormatter {
  final int max;
  const StoryRuneLimit(this.max);
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (newValue.text.runes.length <= max) return newValue;
    final cut = String.fromCharCodes(newValue.text.runes.take(max));
    return TextEditingValue(
      text: cut,
      selection: TextSelection.collapsed(offset: cut.length),
    );
  }
}

/// Shows upper-case styles in capitals without changing what was typed.
class StoryTextController extends TextEditingController {
  StoryTextSpec spec = storyTextStyles.first;
  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final shown = storyDisplayText(text, spec);
    if (shown == text) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    return TextSpan(style: style, text: shown);
  }
}
