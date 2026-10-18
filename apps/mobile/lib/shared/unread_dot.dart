import 'package:flutter/material.dart';

import 'chat_tokens.dart';

/// A small filled dot for "something new here". Pass [label] when the dot is the only thing that says
/// so, so a screen reader hears "New" too.
class UnreadDot extends StatelessWidget {
  final double size;
  final String? label;
  const UnreadDot({super.key, this.size = 10, this.label});

  @override
  Widget build(BuildContext context) {
    final dot = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: ChatTokens.of(context).badgeFill,
        shape: BoxShape.circle,
      ),
    );
    return label == null
        ? ExcludeSemantics(child: dot)
        : Semantics(label: label, child: dot);
  }
}
