import 'package:flutter/material.dart';

/// The green "online" dot on an avatar, the same on every screen (Discover and Nearby rows, a visitor's
/// profile, the chats list and the conversation header). It is only ever drawn when the server said the
/// person is online and lets this viewer see it; there is no "offline" version, because a person who hides
/// presence and one who is offline look the same.
///
/// The ring is cut out in [ringColor], the colour of the surface the avatar sits on, so the dot reads on any
/// photo or gradient. Callers place it (usually bottom right, or top left where a country badge sits there).
class PresenceDot extends StatelessWidget {
  /// The surface behind the avatar, drawn as the ring around the dot.
  final Color ringColor;
  final double size, ringWidth;
  const PresenceDot({
    super.key,
    required this.ringColor,
    this.size = 14,
    this.ringWidth = 2,
  });

  /// The dot's green.
  static const color = Color(0xff2fbf71);

  /// What screen readers say for the dot, and what the "online" words use.
  static const label = 'online';

  /// The green for the word "online" as text: the dot's own green on a dark surface, a deeper one on a light
  /// surface where it would be too faint to read.
  static Color textColor(Brightness brightness) => brightness == Brightness.dark
      ? const Color(0xff4fd68c)
      : const Color(0xff1f7a4d);

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    child: ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: ringColor, width: ringWidth),
        ),
      ),
    ),
  );
}
